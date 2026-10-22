#include "keys.h"

namespace solstream::media {
namespace {

/// The SDK's VK_IME_ON and VK_IME_OFF, which older headers do not define.
constexpr WORD kVkImeOn = 0x16;
constexpr WORD kVkImeOff = 0x1A;

/// Set-1 codes with no PC key behind them, given the Mac's meaning instead.
constexpr unsigned char kScanKeypadEquals = 0x59;
constexpr unsigned char kScanLang1 = 0xF2;  // Kana
constexpr unsigned char kScanLang2 = 0xF1;  // Eisu

/// The keypad's digits and point, as the virtual keys they always mean on a
/// Mac. Zero for any other code.
WORD KeypadVirtualKey(unsigned char scan) {
    switch (scan) {
        case 0x47: return VK_NUMPAD7;
        case 0x48: return VK_NUMPAD8;
        case 0x49: return VK_NUMPAD9;
        case 0x4B: return VK_NUMPAD4;
        case 0x4C: return VK_NUMPAD5;
        case 0x4D: return VK_NUMPAD6;
        case 0x4F: return VK_NUMPAD1;
        case 0x50: return VK_NUMPAD2;
        case 0x51: return VK_NUMPAD3;
        case 0x52: return VK_NUMPAD0;
        case 0x53: return VK_DECIMAL;
        default: return 0;
    }
}

}  // namespace

bool BuildScanKeyInput(uint16_t code, bool down, INPUT* out) {
    const unsigned prefix = code >> 8;
    const unsigned char scan = (unsigned char) (code & 0xFF);
    if ((prefix != 0 && prefix != 0xE0) || scan == 0) {
        return false;
    }
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    const DWORD up = down ? 0 : KEYEVENTF_KEYUP;
    if (prefix == 0) {
        // By virtual key, with the scan code still given: what the PC's own
        // keyboard driver would report for the key, so a game reading raw
        // input sees the keypad key it expects.
        if (const WORD vk = KeypadVirtualKey(scan)) {
            input.ki.wVk = vk;
            input.ki.wScan = scan;
            input.ki.dwFlags = up;
            *out = input;
            return true;
        }
        if (scan == kScanKeypadEquals) {
            input.ki.wScan = L'=';
            input.ki.dwFlags = KEYEVENTF_UNICODE | up;
            *out = input;
            return true;
        }
        if (scan == kScanLang1 || scan == kScanLang2) {
            input.ki.wVk = scan == kScanLang1 ? kVkImeOn : kVkImeOff;
            input.ki.dwFlags = up;
            *out = input;
            return true;
        }
    }
    // Set 1's make codes stop at 0x7F; the high bit is what makes a break
    // code, and a release is said with KEYEVENTF_KEYUP instead.
    if (scan >= 0x80) {
        return false;
    }
    input.ki.wScan = scan;
    input.ki.dwFlags = KEYEVENTF_SCANCODE | up | (prefix == 0xE0 ? KEYEVENTF_EXTENDEDKEY : 0);
    *out = input;
    return true;
}

}  // namespace solstream::media
