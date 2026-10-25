#include "input.h"
#include "keys.h"
#include "smt.h"

#include <dwmapi.h>

#include <algorithm>
#include <optional>

namespace solstream::media {
namespace {

static_assert(kInputButton == 3 && kInputKey == 6 && kInputKeyScan == 8,
              "HoldTarget in keys.cpp names the kinds by number");

int16_t ReadBE16s(const unsigned char* p) {
    return (int16_t) (uint16_t) smt::ReadBE(p, 2);
}

/// Whether this PC's Caps Lock is on, as the window taking the keys sees it,
/// or nothing when that cannot be asked.
///
/// GetKeyState answers for the calling thread's input queue, and this thread
/// takes no keyboard input of its own, so alone it answers with whatever its
/// queue last heard. Joined to the foreground window's queue for the one call,
/// it answers for the keyboard the keys are going to -- the same
/// AttachThreadInput ForceForeground uses, and let go of at once.
///
/// When it cannot be joined -- no foreground window, one that is not
/// answering, or one that refuses this agent, as an elevated window or the
/// secure desktop does -- there is no answer. This thread's own used to stand
/// in, and Caps Lock was pressed on a reading that could be any age: a game
/// on a loading screen, not reading its input, had its Caps Lock flipped by
/// the first key of every second.
std::optional<bool> CapsLockIsOn() {
    // Asked here first, for the queue: the call gives this thread the one
    // AttachThreadInput needs it to have.
    const bool own = (GetKeyState(VK_CAPITAL) & 1) != 0;
    const HWND foreground = GetForegroundWindow();
    if (!foreground || IsHungAppWindow(foreground)) {
        return std::nullopt;
    }
    const DWORD self = GetCurrentThreadId();
    const DWORD holder = GetWindowThreadProcessId(foreground, nullptr);
    if (!holder) {
        return std::nullopt;
    }
    if (holder == self) {
        return own;
    }
    if (!AttachThreadInput(self, holder, TRUE)) {
        return std::nullopt;
    }
    const bool on = (GetKeyState(VK_CAPITAL) & 1) != 0;
    AttachThreadInput(self, holder, FALSE);
    return on;
}

/// Which keys need the extended flag or SendInput sends the numeric-keypad twin.
bool IsExtended(unsigned short vk) {
    switch (vk) {
        case VK_RCONTROL: case VK_RMENU: case VK_INSERT: case VK_DELETE:
        case VK_HOME: case VK_END: case VK_PRIOR: case VK_NEXT:
        case VK_LEFT: case VK_RIGHT: case VK_UP: case VK_DOWN:
        case VK_NUMLOCK: case VK_DIVIDE: case VK_SNAPSHOT:
            return true;
        default:
            return false;
    }
}

/// A virtual key going down or up, with the scan code and the extended flag
/// Windows expects alongside it.
INPUT VirtualKeyInput(WORD vk, bool down) {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vk;
    input.ki.wScan = (WORD) MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    input.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP)
                     | (IsExtended(vk) ? KEYEVENTF_EXTENDEDKEY : 0);
    return input;
}

}  // namespace

void InputInjector::SetTarget(const InputTarget& target) {
    std::lock_guard<std::mutex> guard(targetLock_);
    target_ = target;
}

bool InputInjector::ScreenPoint(uint16_t nx, uint16_t ny, LONG* x, LONG* y) const {
    // A copy, taken and released before anything below calls into Windows.
    // Retarget writes the target from the agent's command thread while this runs
    // on the receive thread, and DwmGetWindowAttribute on a window whose process
    // is not answering can take a long time -- so holding the lock across it
    // would stall the retarget that is trying to point somewhere else.
    InputTarget target;
    {
        std::lock_guard<std::mutex> guard(targetLock_);
        target = target_;
    }
    RECT area{};
    if (target.window && IsWindow(target.window)) {
        // The DWM frame bounds, not GetWindowRect. GetWindowRect includes the
        // invisible resize border Windows 10 and 11 put around a window, so
        // every coordinate derived from it is a few pixels off in both axes --
        // which reads as a calibration bug rather than as the wrong rectangle.
        if (FAILED(DwmGetWindowAttribute(target.window, DWMWA_EXTENDED_FRAME_BOUNDS,
                                         &area, sizeof(area)))) {
            if (!GetWindowRect(target.window, &area)) {
                return false;
            }
        }
    } else if (target.monitor) {
        MONITORINFO info{};
        info.cbSize = sizeof(info);
        if (!GetMonitorInfoW(target.monitor, &info)) {
            return false;
        }
        area = info.rcMonitor;
    } else {
        return false;
    }
    const LONG width = area.right - area.left;
    const LONG height = area.bottom - area.top;
    if (width <= 0 || height <= 0) {
        return false;
    }
    *x = area.left + (LONG) ((int64_t) nx * width / 65535);
    *y = area.top + (LONG) ((int64_t) ny * height / 65535);
    return true;
}

bool InputInjector::ApplyOne(unsigned char kind, const unsigned char* body,
                             size_t length) {
    INPUT input{};
    switch (kind) {
        case kInputMouseAbs: {
            if (length < 4) { return false; }
            LONG x = 0, y = 0;
            if (!ScreenPoint((uint16_t) smt::ReadBE(body, 2),
                             (uint16_t) smt::ReadBE(body + 2, 2), &x, &y)) {
                return false;
            }
            // SendInput's absolute coordinates are normalised over the VIRTUAL
            // desktop, not the primary monitor, and the denominator is one less
            // than the extent. Both are easy to get subtly wrong in a way that
            // only shows on a multi-monitor host.
            const LONG left = GetSystemMetrics(SM_XVIRTUALSCREEN);
            const LONG top = GetSystemMetrics(SM_YVIRTUALSCREEN);
            const LONG width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            const LONG height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            if (width <= 1 || height <= 1) { return false; }
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
                             | MOUSEEVENTF_VIRTUALDESK;
            input.mi.dx = (LONG) ((int64_t) (x - left) * 65535 / (width - 1));
            input.mi.dy = (LONG) ((int64_t) (y - top) * 65535 / (height - 1));
            break;
        }
        case kInputMouseRel: {
            if (length < 4) { return false; }
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = MOUSEEVENTF_MOVE;
            input.mi.dx = ReadBE16s(body);
            input.mi.dy = ReadBE16s(body + 2);
            break;
        }
        case kInputButton: {
            if (length < 2) { return false; }
            const unsigned char button = body[0];
            const bool down = body[1] != 0;
            input.type = INPUT_MOUSE;
            switch (button) {
                case 1: input.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
                case 2: input.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
                case 3: input.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
                case 4:
                case 5:
                    input.mi.dwFlags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP;
                    input.mi.mouseData = button == 4 ? XBUTTON1 : XBUTTON2;
                    break;
                default: return false;
            }
            if (button >= 1 && button <= 5) {
                if (down) {
                    buttonsDown_ |= (unsigned char) (1u << (button - 1));
                    // A click has to reach the window that is being streamed,
                    // and keyboard input goes to whatever has the foreground on
                    // the HOST -- which may be something the user walked away
                    // from. Raising it on a press is the least surprising place
                    // to do it.
                    //
                    // Through a copy, as everywhere else the target is read: the
                    // command thread can be retargeting this session while the
                    // receive thread is in here.
                    HWND raise = nullptr;
                    {
                        std::lock_guard<std::mutex> guard(targetLock_);
                        raise = target_.window;
                    }
                    if (raise && IsWindow(raise) && GetForegroundWindow() != raise) {
                        SetForegroundWindow(raise);
                    }
                } else {
                    buttonsDown_ &= (unsigned char) ~(1u << (button - 1));
                }
            }
            break;
        }
        case kInputScrollV:
        case kInputScrollH: {
            if (length < 2) { return false; }
            input.type = INPUT_MOUSE;
            input.mi.dwFlags = kind == kInputScrollV ? MOUSEEVENTF_WHEEL
                                                     : MOUSEEVENTF_HWHEEL;
            input.mi.mouseData = (DWORD) (int32_t) ReadBE16s(body);
            break;
        }
        case kInputKey: {
            if (length < 3) { return false; }
            const WORD vk = (WORD) smt::ReadBE(body, 2);
            const bool down = body[2] != 0;
            input = VirtualKeyInput(vk, down);
            TrackKey(vk, down);
            break;
        }
        case kInputKeyScan: {
            if (length < 3) { return false; }
            const uint16_t code = (uint16_t) smt::ReadBE(body, 2);
            const bool down = body[2] != 0;
            // Before the key, so that the letter it types already has the
            // Mac's case. On a press only: a release types nothing.
            if (down && length >= 4) {
                MatchCapsLock((body[3] & kModifierCapsLock) != 0);
            }
            // Caps Lock's own event has done all it came to do above.
            if (code == kScanCapsLock) { return true; }
            if (!BuildScanKeyInput(code, down, &input)) { return false; }
            TrackKey(kHeldByScan | code, down);
            break;
        }
        case kInputText: {
            // UTF-16 code units, a character at a time as unicode keystrokes:
            // both halves of an emoji in the one SendInput. See keys.h.
            bool typed = true;
            size_t at = 0;
            while (at < length) {
                INPUT keys[4];
                int count = 0;
                const size_t used = BuildTextCharInput(body, length, at, keys, &count);
                if (used == 0) { break; }
                at += used;
                if (count > 0 && SendInput((UINT) count, keys, sizeof(INPUT)) != (UINT) count) {
                    typed = false;
                }
            }
            return typed;
        }
        default:
            return false;
    }
    return SendInput(1, &input, sizeof(INPUT)) == 1;
}

uint32_t InputInjector::Apply(const unsigned char* plaintext, size_t length) {
    if (length < 4 || plaintext[0] != 0x30) {
        return acked_.load();
    }
    // Each event needs at least a 4-byte sequence, kind, and body-length byte,
    // so the count cannot honestly exceed this; ignore an implausible one.
    const int count =
        std::min<int>(plaintext[1], static_cast<int>((length - 4) / 6));
    size_t at = 4;
    for (int i = 0; i < count && at + 6 <= length; ++i) {
        const uint32_t seq = (uint32_t) smt::ReadBE(plaintext + at, 4);
        const unsigned char kind = plaintext[at + 4];
        const size_t bodyLen = plaintext[at + 5];
        const unsigned char* body = plaintext + at + 6;
        at += 6 + bodyLen;
        if (at > length) {
            break;
        }

        // Deduplicate. The client repeats deliberately -- a lost key-up is a key
        // that stays down -- so a repeat is the normal case and must be cheap
        // and silent, not a warning.
        //
        // The window is only ASKED here. It used to be written here as well,
        // before the event had been applied, so an event with a body too short
        // for its kind, or one whose SendInput was rejected, was recorded as
        // seen and then acknowledged like any other. The Mac deletes an
        // acknowledged event: it keeps a tail of 32 and stops repeating 300 ms
        // after the last new event, so the event was gone from both machines and
        // a key-up lost that way left the key down with nothing to release it.
        // Recording now happens below, after ApplyOne has had its attempt.
        if (seen_.SeenOrTooOld(seq)) {
            duplicates_.fetch_add(1);
            continue;
        }

        // RECORDED WHETHER OR NOT IT APPLIED. A failure used to be left out of
        // the window so the next copy could try again -- but the failures that
        // happen are not the kind a retry fixes. A malformed body is malformed
        // in every copy, and a SendInput refused because an elevated window
        // has focus is refused for as long as it has. Meanwhile an unrecorded
        // sequence is a hole the contiguous acknowledgement can never step
        // over, so one bad event froze the ack for the rest of the session and
        // every later event was repeated until the Mac's 300 ms give-up, for
        // ever. The retry it bought was at most those same 300 ms. Counted, so
        // the stats line says when input is being dropped on the floor.
        //
        // An event overtaken by a newer one for the same key or button is
        // recorded too, and counted with the duplicates: see keys.h.
        if (!HoldEventIsNewest(holdOrder_, HoldTarget(kind, body, bodyLen), seq)) {
            duplicates_.fetch_add(1);
        } else if (ApplyOne(kind, body, bodyLen)) {
            applied_.fetch_add(1);
        } else {
            failed_.fetch_add(1);
        }

        seen_.Record(seq);
    }

    // The acknowledgement is the highest CONTIGUOUS sequence: the client stops
    // repeating an event only when the host says it has everything up to it,
    // and a gap has to hold that line or the missing event is never repeated.
    //
    // Counted UP FROM WHAT WAS LAST ACKNOWLEDGED, which starts at zero, rather
    // than down from the highest sequence seen. Counting down made the top of
    // the window into evidence about everything beneath it, and there is none:
    // a session whose first datagram to survive the network carried seq 3
    // answered "I have everything up to 1" about an event that had never reached
    // this machine, and the Mac then deleted it. Counting up can only ever step
    // over a sequence this injector has applied itself, so every number it
    // reports is one it has actually earned -- and the same rule holds the line
    // when a long blackout slides the window past a gap: `behind` runs off the
    // end of the window, the ack stops there and stays there.
    //
    // A stuck acknowledgement costs repetition, which is cheap -- the client
    // resends its eight newest events every 10 ms, with the releases it still
    // owes for up to five seconds, and every one of them is still applied here
    // exactly once. A wrong one costs an event that both ends have
    // forgotten and neither applied, which for a key-up means a key held down
    // until the session ends.
    //
    // Not wrap-aware, nor needs to be: see `seen_` in input.h.
    uint32_t acked = acked_.load();
    while (seen_.started && acked < seen_.highest) {
        const uint64_t behind = seen_.highest - (acked + 1);
        if (behind >= 1024) { break; }
        if (!((seen_.bits[behind / 64] >> (behind % 64)) & 1)) { break; }
        ++acked;
    }
    acked_.store(acked);
    return acked;
}

void InputInjector::Reset() {
    seen_ = {};
    acked_.store(0);
    applied_.store(0);
    duplicates_.store(0);
    failed_.store(0);
    holdOrder_ = HoldOrder{};
    // Asked afresh each session: the PC's Caps Lock may have been changed at
    // the PC since the last one.
    capsLock_ = CapsLockBelief{};
}

void InputInjector::MatchCapsLock(bool wanted) {
    const uint64_t now = GetTickCount64();
    if (!CapsLockPressNeeded(capsLock_, CapsLockIsOn, wanted, now)) {
        return;
    }
    INPUT toggle[2];
    BuildCapsLockToggle(toggle);
    // Believed only once Windows has taken both halves. Refused -- an
    // elevated window has the foreground -- the next key asks again.
    if (SendInput(2, toggle, sizeof(INPUT)) == 2) {
        CapsLockNoted(capsLock_, wanted, now);
    }
}

void InputInjector::TrackKey(uint32_t key, bool down) {
    if (down) {
        if (keysDownCount_ < 256) {
            bool already = false;
            for (int i = 0; i < keysDownCount_; ++i) {
                if (keysDown_[i] == key) { already = true; break; }
            }
            if (!already) { keysDown_[keysDownCount_++] = key; }
        }
    } else {
        for (int i = 0; i < keysDownCount_; ++i) {
            if (keysDown_[i] == key) {
                keysDown_[i] = keysDown_[--keysDownCount_];
                break;
            }
        }
    }
}

void InputInjector::ReleaseAll() {
    for (int i = 0; i < keysDownCount_; ++i) {
        INPUT up{};
        if (keysDown_[i] & kHeldByScan) {
            // Released the way it was pressed: by scan code, or by whatever
            // BuildScanKeyInput chose for it.
            if (!BuildScanKeyInput((uint16_t) (keysDown_[i] & 0xFFFF), false, &up)) {
                continue;
            }
        } else {
            up = VirtualKeyInput((WORD) keysDown_[i], false);
        }
        SendInput(1, &up, sizeof(INPUT));
    }
    keysDownCount_ = 0;

    static const DWORD ups[5] = {MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEUP,
                                 MOUSEEVENTF_RIGHTUP, MOUSEEVENTF_XUP,
                                 MOUSEEVENTF_XUP};
    for (int i = 0; i < 5; ++i) {
        if (buttonsDown_ & (1u << i)) {
            INPUT up{};
            up.type = INPUT_MOUSE;
            up.mi.dwFlags = ups[i];
            if (i >= 3) { up.mi.mouseData = i == 3 ? XBUTTON1 : XBUTTON2; }
            SendInput(1, &up, sizeof(INPUT));
        }
    }
    buttonsDown_ = 0;
}

}  // namespace solstream::media
