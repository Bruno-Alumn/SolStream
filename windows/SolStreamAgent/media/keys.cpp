#include "keys.h"

namespace solstream::media {
namespace {

/// The SDK's VK_IME_ON and VK_IME_OFF, which older headers do not define.
constexpr WORD kVkImeOn = 0x16;
constexpr WORD kVkImeOff = 0x1A;

/// Set-1 codes with no PC key behind them, given the Mac's meaning instead.
constexpr unsigned char kScanKeypadEquals = 0x59;
constexpr unsigned char kScanKeypadComma = 0x7E;  // JIS
constexpr unsigned char kScanLang1 = 0xF2;  // Kana
constexpr unsigned char kScanLang2 = 0xF1;  // Eisu

/// Control's place, left and, behind 0xE0, right.
constexpr unsigned char kScanControl = 0x1D;

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
    // Control by virtual key, so that it is Control whatever the layout here
    // makes of its place; the scan code is still given, as for the keypad.
    if (scan == kScanControl) {
        const bool right = prefix == 0xE0;
        input.ki.wVk = right ? VK_RCONTROL : VK_LCONTROL;
        input.ki.wScan = scan;
        input.ki.dwFlags = up | (right ? KEYEVENTF_EXTENDEDKEY : 0);
        *out = input;
        return true;
    }
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
        if (scan == kScanKeypadEquals || scan == kScanKeypadComma) {
            input.ki.wScan = scan == kScanKeypadEquals ? L'=' : L',';
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

size_t BuildTextCharInput(const unsigned char* body, size_t length, size_t at,
                          INPUT out[4], int* count) {
    *count = 0;
    if (at >= length) {
        return 0;
    }
    if (length - at < 2) {
        return length - at;
    }
    const auto unitAt = [body](size_t i) {
        return (WORD) (((WORD) body[i] << 8) | body[i + 1]);
    };
    const auto isHigh = [](WORD unit) { return unit >= 0xD800 && unit <= 0xDBFF; };
    const auto isLow = [](WORD unit) { return unit >= 0xDC00 && unit <= 0xDFFF; };
    const WORD first = unitAt(at);
    WORD units[2] = {first, 0};
    int unitCount = 1;
    size_t used = 2;
    if (isHigh(first)) {
        if (length - at < 4 || !isLow(unitAt(at + 2))) {
            return used;
        }
        units[1] = unitAt(at + 2);
        unitCount = 2;
        used = 4;
    } else if (isLow(first)) {
        return used;
    }
    // A press and a release for each half, in order: what Windows' own
    // remoting and every other injector of text sends, and what an
    // application reading WM_CHAR puts back together.
    for (int i = 0; i < unitCount; ++i) {
        for (int up = 0; up < 2; ++up) {
            INPUT& input = out[(*count)++];
            input = INPUT{};
            input.type = INPUT_KEYBOARD;
            input.ki.wScan = units[i];
            input.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
        }
    }
    return used;
}

bool CapsLockNeedsReading(const CapsLockBelief& belief, uint64_t nowMs) {
    // A clock that has gone backwards says nothing about how old the belief
    // is, so it is asked again rather than trusted for ever.
    return !belief.known || nowMs < belief.atMs || nowMs - belief.atMs >= kCapsLockTrustMs;
}

void CapsLockNoted(CapsLockBelief& belief, bool on, uint64_t nowMs) {
    belief.known = true;
    belief.on = on;
    belief.atMs = nowMs;
}

bool CapsLockPressNeeded(CapsLockBelief& belief,
                         const std::function<std::optional<bool>()>& read,
                         bool wanted, uint64_t nowMs) {
    if (CapsLockNeedsReading(belief, nowMs)) {
        const std::optional<bool> on = read();
        if (!on) {
            belief = CapsLockBelief{};
            return false;
        }
        CapsLockNoted(belief, *on, nowMs);
    }
    return belief.on != wanted;
}

void BuildCapsLockToggle(INPUT out[2]) {
    for (int i = 0; i < 2; ++i) {
        out[i] = INPUT{};
        out[i].type = INPUT_KEYBOARD;
        out[i].ki.wVk = VK_CAPITAL;
        out[i].ki.wScan = (WORD) kScanCapsLock;
    }
    out[1].ki.dwFlags = KEYEVENTF_KEYUP;
}

uint32_t HoldTarget(unsigned char kind, const unsigned char* body, size_t length) {
    // kInputButton, kInputKey and kInputKeyScan in input.h, which this file
    // does not include so the tests can build it alone.
    switch (kind) {
        case 3:
            return length >= 2 ? (uint32_t) kind << 16 | body[0] : 0;
        case 6:
        case 8:
            return length >= 3 ? (uint32_t) kind << 16 | (uint32_t) body[0] << 8 | body[1] : 0;
        default:
            return 0;
    }
}

bool HoldEventIsNewest(HoldOrder& order, uint32_t target, uint32_t seq) {
    if (target == 0) {
        return true;
    }
    int oldest = 0;
    for (int i = 0; i < order.count; ++i) {
        if (order.target[i] == target) {
            if (seq < order.seq[i]) {
                return false;
            }
            order.seq[i] = seq;
            return true;
        }
        if (order.seq[i] < order.seq[oldest]) {
            oldest = i;
        }
    }
    const int slot = order.count < kHoldOrderSlots ? order.count++ : oldest;
    order.target[slot] = target;
    order.seq[slot] = seq;
    return true;
}

}  // namespace solstream::media
