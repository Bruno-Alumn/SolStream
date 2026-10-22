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

}  // namespace solstream::media
