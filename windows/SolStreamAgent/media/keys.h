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

#include <cstdint>

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
/// what it means. Four kinds do not, because there it is the Mac's meaning
/// that is wanted and no position on a PC keyboard carries it:
///
///   - The keypad's digits and point go in by virtual key. A Mac keypad has no
///     Num Lock and always types digits, while the same scan codes on a PC
///     with Num Lock off are Home, End and the arrows.
///   - The keypad's '=' (0x59), which a PC keypad does not have, goes in as
///     the character.
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

/// The press and release that toggle Caps Lock.
///
/// By virtual key rather than by Caps Lock's scan code: on a Japanese layout
/// the key at that place is 英数, which switches the IME and leaves Caps Lock
/// as it was, and every key typed would go on trying to fix it.
void BuildCapsLockToggle(INPUT out[2]);

}  // namespace solstream::media
