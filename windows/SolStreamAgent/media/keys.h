// keys.h — how a key the Mac sends by position becomes a keystroke here.
//
// The Mac used to name every key by the Windows virtual key that sits at that
// spot on a US keyboard, and Windows reads a virtual key by its LABEL in this
// PC's own layout. So on a German PC the key marked Z arrived as VK_Y and typed
// 'y', and on a French one A typed 'q' -- even with the same layout on both
// machines. A scan code names the physical key instead, and Windows then does
// exactly what it does for a keyboard plugged into this PC: this PC's layout
// decides the character, and a game reading scan codes sees the key that was
// pressed.
//
// Kept apart from input.cpp, which owns the session's state and calls
// SendInput, so that the decisions can be tested without injecting anything.
// updater_tests.cpp carries their tests, and this file needs nothing from the
// media path to build.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>

namespace solstream::media {

/// The scan-code half of a key event: a set-1 make code, with 0xE0 in the high
/// byte for an extended key -- 0xE04B is the arrow left of the keypad, 0x004B
/// the keypad's 4.
///
/// Turned into the one INPUT that presses (`down`) or releases that key. False
/// for a code that names no key this can press: a prefix other than none or
/// 0xE0, a zero, or a break code.
///
/// Almost every key goes in as KEYEVENTF_SCANCODE, so this PC's layout decides
/// what it means. A few do not, because there it is the Mac's meaning that is
/// wanted and no position on a PC keyboard is sure to carry it:
///
///   - Control (0x1D, and 0xE01D on the right) goes in as VK_LCONTROL and
///     VK_RCONTROL. The Mac's Command arrives as Control for what Control
///     does, and some layouts put another key at its place: Korean's 101-key
///     Type 1 has Hanja on the right one, so right-Command-C opened the Hanja
///     window instead of copying.
///   - The keypad's digits and point go in by virtual key. A Mac keypad has no
///     Num Lock and always types digits, while the same scan codes on a PC
///     with Num Lock off are Home, End and the arrows.
///   - The keypad's '=' (0x59) and the JIS keypad's comma (0x7E), which a
///     PC keypad does not have, go in as the character. 0x7E is a keypad
///     key only a Brazilian layout makes a character of; on a Japanese or US
///     one it typed nothing.
///   - The JIS keyboard's Kana (0xF2, LANG1) and Eisu (0xF1, LANG2) go in as
///     VK_IME_ON and VK_IME_OFF, which switch the IME on and off: the keys a
///     Japanese PC keyboard does that with are not on an Apple one.
bool BuildScanKeyInput(uint16_t code, bool down, INPUT* out);

// ── Caps Lock ────────────────────────────────────────────────────────────────
//
// Caps Lock is a toggle, and the Mac used to keep it in step by sending a
// press whenever its own changed, on top of a guess at what the PC's was. One
// press lost -- sent before the session was running, or to a PC whose Caps Lock
// had been set at the PC -- and the two were inverted for good: every later
// press flipped both. So a scan-code key event carries the Mac's Caps Lock
// STATE in its modifiers byte, and this side presses Caps Lock only when the
// PC's differs, just before a key goes down. A lost event then costs nothing:
// the next key brings the two back together.

/// The modifiers byte's Caps Lock bit, on a `kInputKeyScan` event.
constexpr unsigned char kModifierCapsLock = 0x10;

/// Caps Lock's own scan code. From the Mac it is not a press to pass on but a
/// report that its Caps Lock has changed, carrying the new state like any
/// other key event; it is answered by bringing the PC's into line.
constexpr uint16_t kScanCapsLock = 0x3A;

/// What this side believes the PC's Caps Lock is, and since when.
struct CapsLockBelief {
    bool known = false;
    bool on = false;
    uint64_t atMs = 0;
};

/// How long a belief is trusted over asking Windows again.
///
/// Not for the cost of asking. Windows answers from the input queue of the
/// window taking the keys, which learns of a press only when that window reads
/// it -- so asked just after this side pressed Caps Lock, it can still say the
/// old state, and pressing again on that answer would put the inversion back.
/// A second is far longer than any window that is reading its input takes,
/// and short enough that Caps Lock changed at the PC itself is noticed by the
/// next word typed.
constexpr uint64_t kCapsLockTrustMs = 1000;

/// Whether Windows has to be asked before the belief can be acted on.
bool CapsLockNeedsReading(const CapsLockBelief& belief, uint64_t nowMs);

/// Record the PC's Caps Lock: what Windows said, or what a press from here has
/// just made it.
void CapsLockNoted(CapsLockBelief& belief, bool on, uint64_t nowMs);

/// Whether Caps Lock has to be pressed for the PC's to be `wanted`.
///
/// `read` asks Windows, and is asked only when the belief needs it. It answers
/// nothing when it cannot be asked -- see CapsLockIsOn in input.cpp -- and then
/// nothing is pressed and nothing believed, so the next key asks again. After
/// a press that Windows took, the caller notes `wanted` as what the PC now is.
bool CapsLockPressNeeded(CapsLockBelief& belief,
                         const std::function<std::optional<bool>()>& read,
                         bool wanted, uint64_t nowMs);

/// The press and release that toggle Caps Lock.
///
/// By virtual key rather than by Caps Lock's scan code: on a Japanese layout
/// the key at that place is 英数, which switches the IME and leaves Caps Lock
/// as it was, and every key typed would go on trying to fix it.
void BuildCapsLockToggle(INPUT out[2]);

// ── One key's events in order ────────────────────────────────────────────────
//
// The host applies an event the first time any copy of it arrives, whatever
// came before, so two datagrams that swap places on the way -- a Wi-Fi roam,
// a relay switch -- can put a key's events in the wrong order. The Mac carries
// a release for up to five seconds while the PC has not acknowledged it, and
// stops as soon as the key is pressed again; a datagram from before that press
// arriving after it let go of the key the hand had gone back to. So each key
// and button keeps the sequence of its newest event applied, and an older one
// for the same key or button is passed over: it has been overtaken.

/// What a key or button event presses or lets go of: its kind in the high
/// half and its key or button in the low, so a key by virtual key and the
/// same key by scan code differ, as they do on the Mac. Zero for an event
/// that holds nothing -- a move, a scroll, text -- or one too short to say.
uint32_t HoldTarget(unsigned char kind, const unsigned char* body, size_t length);

/// How many keys and buttons have their order kept. More than every key a
/// keyboard has, by virtual key and by scan code, and every button.
constexpr int kHoldOrderSlots = 512;

/// The sequence of the newest event applied for each key and button. Bounded:
/// a key not seen for longest makes way when it is full. Cleared each session,
/// with the sequence numbers.
struct HoldOrder {
    uint32_t target[kHoldOrderSlots] = {};
    uint32_t seq[kHoldOrderSlots] = {};
    int count = 0;
};

/// Whether the event with sequence `seq` for `target` is newer than any
/// applied for it, which notes it as the newest; false for one overtaken.
/// True for an event that holds nothing (`target` zero), which is not noted.
bool HoldEventIsNewest(HoldOrder& order, uint32_t target, uint32_t seq);

}  // namespace solstream::media
