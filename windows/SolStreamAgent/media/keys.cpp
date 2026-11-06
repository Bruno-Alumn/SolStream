#include "keys.h"

#include <atomic>

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

/// Whether the keyboard layout of the window in front types a character at
/// `scan`. A virtual key alone is not enough: Windows' base tables give 0x7E
/// one, VK_ABNT_C2, on every layout, and only Brazil's makes it type.
bool ForegroundLayoutHasKey(unsigned char scan) {
    const HWND front = GetForegroundWindow();
    const DWORD thread = front ? GetWindowThreadProcessId(front, nullptr) : 0;
    const HKL layout = GetKeyboardLayout(thread);
    const UINT vk = MapVirtualKeyExW(scan, MAPVK_VSC_TO_VK, layout);
    return vk != 0 && MapVirtualKeyExW(vk, MAPVK_VK_TO_CHAR, layout) != 0;
}

/// Control's place, left and, behind 0xE0, right.
constexpr unsigned char kScanControl = 0x1D;
/// Alt's place; behind 0xE0, right Alt (AltGr).
constexpr unsigned char kScanAlt = 0x38;

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
    // Right Alt by virtual key too, for the same reason: Korean's Type 1 puts
    // Hangul/English at its place, so right-Option-F4 switched the input
    // language instead of closing a window. VK_RMENU is still AltGr on the
    // layouts that have one.
    if (scan == kScanAlt && prefix == 0xE0) {
        input.ki.wVk = VK_RMENU;
        input.ki.wScan = scan;
        input.ki.dwFlags = up | KEYEVENTF_EXTENDEDKEY;
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
        // The JIS keypad comma's place is a key of its own on Brazil's ABNT2
        // keyboard -- its keypad's '.' -- which a Mac reports as this same
        // code. Where the PC's layout has a key there, it is that key, by its
        // scan code like any other; only where it has none is it a ','.
        // Decided when the key goes down and kept for its release: asked
        // again, a layout switched while it was held made the release a ','
        // and left the key itself down.
        static std::atomic<bool> commaIsKey{false};
        if (scan == kScanKeypadComma && down) {
            commaIsKey.store(ForegroundLayoutHasKey(scan));
        }
        if (scan == kScanKeypadComma && commaIsKey.load()) {
            input.ki.wScan = scan;
            input.ki.dwFlags = KEYEVENTF_SCANCODE | up;
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

namespace {

INPUT KeyboardInput(WORD vk, WORD scan, DWORD flags) {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.wScan = scan;
    input.ki.dwFlags = flags;
    return input;
}

/// The modifier keys, each with its two sides' bits, virtual keys and scan
/// codes, in the order they are put down: Shift, Control, Alt.
struct ModifierSides {
    unsigned leftBit, rightBit;
    WORD leftVk, rightVk;
    WORD scan;
};
constexpr ModifierSides kModifierSides[3] = {
    {kHeldLShift, kHeldRShift, VK_LSHIFT, VK_RSHIFT, 0x2A},
    {kHeldLControl, kHeldRControl, VK_LCONTROL, VK_RCONTROL, 0x1D},
    {kHeldLAlt, kHeldRAlt, VK_LMENU, VK_RMENU, 0x38},
};

/// One side of a modifier going down or up. The right Shift has a scan code
/// of its own; the right Control and Alt are the left ones' behind 0xE0.
INPUT ModifierInput(const ModifierSides& m, bool right, bool down) {
    WORD scan = m.scan;
    DWORD flags = down ? 0 : KEYEVENTF_KEYUP;
    if (right) {
        if (m.leftVk == VK_LSHIFT) {
            scan = 0x36;
        } else {
            flags |= KEYEVENTF_EXTENDEDKEY;
        }
    }
    return KeyboardInput(right ? m.rightVk : m.leftVk, scan, flags);
}

}  // namespace

int BuildCharKeyPress(const WCHAR* units, int unitCount, SHORT vkScan, WORD vkScanCode,
                      unsigned held, bool capsOn, bool isAlpha, INPUT out[32],
                      WORD* pressedVk) {
    int n = 0;
    *pressedVk = 0;
    if (unitCount < 1 || unitCount > 2) {
        return 0;
    }
    // A key on this layout types it when VkKeyScan found one that needs no
    // more than Shift, Control and Alt -- not the Hankaku or the layout's own
    // extra shift states, which nothing here can hold.
    const unsigned states = vkScan == -1 ? 0xFF : ((unsigned) vkScan >> 8) & 0xFF;
    const bool byKey = unitCount == 1 && vkScan != -1 && (states & ~7u) == 0
                    && (vkScan & 0xFF) != 0;
    bool need[3] = {false, false, false};
    if (byKey) {
        need[0] = (states & 1) != 0;
        need[1] = (states & 2) != 0;
        need[2] = (states & 4) != 0;
        // Caps Lock on, a letter's case comes from it with Shift turned around:
        // 'A' is the A key alone, 'a' is it with Shift.
        if (capsOn && isAlpha) {
            need[0] = !need[0];
        }
    } else {
        // Typed whole: Shift changes nothing about a unicode character, so it
        // stays as it is; Control or Alt under one would make it a shortcut.
        need[0] = (held & (kHeldLShift | kHeldRShift)) != 0;
    }

    bool lifted[3][2] = {};
    bool added[3] = {};
    // Every lift before every add, and the adds gone before the lifts come
    // back: Alt held while Shift goes down or up is Windows' Alt+Shift, which
    // switches the input language. Alt is lifted first, with the mask key
    // pressed while it is still held, so Windows does not open a menu for it.
    for (int i = 2; i >= 0; --i) {
        const ModifierSides& m = kModifierSides[i];
        const bool have = (held & (m.leftBit | m.rightBit)) != 0;
        if (!have || need[i]) { continue; }
        if (i == 2) {
            out[n++] = KeyboardInput(kVkMaskKey, 0, 0);
            out[n++] = KeyboardInput(kVkMaskKey, 0, KEYEVENTF_KEYUP);
        }
        for (int side = 0; side < 2; ++side) {
            if (held & (side ? m.rightBit : m.leftBit)) {
                out[n++] = ModifierInput(m, side == 1, false);
                lifted[i][side] = true;
            }
        }
    }
    for (int i = 0; i < 3; ++i) {
        const ModifierSides& m = kModifierSides[i];
        if (need[i] && (held & (m.leftBit | m.rightBit)) == 0) {
            out[n++] = ModifierInput(m, false, true);
            added[i] = true;
        }
    }

    if (byKey) {
        const WORD vk = (WORD) (vkScan & 0xFF);
        out[n++] = KeyboardInput(vk, vkScanCode, 0);
        *pressedVk = vk;
    } else {
        // Both halves of a pair in the one run, as BuildTextCharInput does.
        for (int i = 0; i < unitCount; ++i) {
            out[n++] = KeyboardInput(0, units[i], KEYEVENTF_UNICODE);
            out[n++] = KeyboardInput(0, units[i], KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }
    }

    // Everything back as the Mac has it: what was added goes first, then
    // what was lifted comes back, Alt last.
    for (int i = 2; i >= 0; --i) {
        if (added[i]) {
            out[n++] = ModifierInput(kModifierSides[i], false, false);
        }
    }
    bool altBack = false;
    for (int i = 0; i < 3; ++i) {
        for (int side = 0; side < 2; ++side) {
            if (lifted[i][side]) {
                out[n++] = ModifierInput(kModifierSides[i], side == 1, true);
                altBack = altBack || i == 2;
            }
        }
    }
    // Alt down again, and the Mac's ⌥ will come up next with nothing between:
    // a tap, to Windows, which opens the menu. The mask key is that something.
    if (altBack) {
        out[n++] = KeyboardInput(kVkMaskKey, 0, 0);
        out[n++] = KeyboardInput(kVkMaskKey, 0, KEYEVENTF_KEYUP);
    }
    return n;
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
