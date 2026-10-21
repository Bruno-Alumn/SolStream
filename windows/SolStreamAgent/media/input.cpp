#include "input.h"
#include "smt.h"

#include <dwmapi.h>

#include <cstring>

namespace solstream::media {
namespace {

uint32_t ReadBE32(const unsigned char* p) {
    return ((uint32_t) p[0] << 24) | ((uint32_t) p[1] << 16)
         | ((uint32_t) p[2] << 8) | (uint32_t) p[3];
}

uint16_t ReadBE16(const unsigned char* p) {
    return (uint16_t) (((uint16_t) p[0] << 8) | (uint16_t) p[1]);
}

int16_t ReadBE16s(const unsigned char* p) {
    return (int16_t) ReadBE16(p);
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
            if (!ScreenPoint(ReadBE16(body), ReadBE16(body + 2), &x, &y)) {
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
            const unsigned short vk = ReadBE16(body);
            const bool down = body[2] != 0;
            input.type = INPUT_KEYBOARD;
            input.ki.wVk = vk;
            input.ki.wScan = (WORD) MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
            input.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP)
                             | (IsExtended(vk) ? KEYEVENTF_EXTENDEDKEY : 0);
            if (down) {
                if (keysDownCount_ < 256) {
                    bool already = false;
                    for (int i = 0; i < keysDownCount_; ++i) {
                        if (keysDown_[i] == vk) { already = true; break; }
                    }
                    if (!already) { keysDown_[keysDownCount_++] = vk; }
                }
            } else {
                for (int i = 0; i < keysDownCount_; ++i) {
                    if (keysDown_[i] == vk) {
                        keysDown_[i] = keysDown_[--keysDownCount_];
                        break;
                    }
                }
            }
            break;
        }
        case kInputText: {
            // UTF-16 code units, sent one at a time as a unicode keystroke.
            for (size_t i = 0; i + 1 < length; i += 2) {
                INPUT unit{};
                unit.type = INPUT_KEYBOARD;
                unit.ki.wScan = ReadBE16(body + i);
                unit.ki.dwFlags = KEYEVENTF_UNICODE;
                SendInput(1, &unit, sizeof(INPUT));
                unit.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
                SendInput(1, &unit, sizeof(INPUT));
            }
            return true;
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
    const int count = plaintext[1];
    size_t at = 4;
    for (int i = 0; i < count && at + 6 <= length; ++i) {
        const uint32_t seq = ReadBE32(plaintext + at);
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
        if (started_ && seq <= highest_) {
            const uint32_t behind = highest_ - seq;
            if (behind >= 1024 || ((seen_[behind / 64] >> (behind % 64)) & 1)) {
                duplicates_.fetch_add(1);
                continue;
            }
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
        if (ApplyOne(kind, body, bodyLen)) {
            applied_.fetch_add(1);
        } else {
            failed_.fetch_add(1);
        }

        if (!started_) {
            started_ = true;
            highest_ = seq;
            std::memset(seen_, 0, sizeof(seen_));
            seen_[0] = 1;
        } else if (seq > highest_) {
            smt::SlideWindow(seen_, seq - highest_);
            highest_ = seq;
            seen_[0] |= 1;
        } else {
            const uint32_t behind = highest_ - seq;
            seen_[behind / 64] |= 1ull << (behind % 64);
        }
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
    // resends at most eight events every 10 ms, and every one of them is still
    // applied here exactly once. A wrong one costs an event that both ends have
    // forgotten and neither applied, which for a key-up means a key held down
    // until the session ends.
    uint32_t acked = acked_.load();
    while (started_ && acked < highest_) {
        const uint32_t behind = highest_ - (acked + 1);
        if (behind >= 1024) { break; }
        if (!((seen_[behind / 64] >> (behind % 64)) & 1)) { break; }
        ++acked;
    }
    acked_.store(acked);
    return acked;
}

void InputInjector::Reset() {
    started_ = false;
    highest_ = 0;
    acked_.store(0);
    applied_.store(0);
    duplicates_.store(0);
    failed_.store(0);
    std::memset(seen_, 0, sizeof(seen_));
}

void InputInjector::ReleaseAll() {
    for (int i = 0; i < keysDownCount_; ++i) {
        INPUT up{};
        up.type = INPUT_KEYBOARD;
        up.ki.wVk = keysDown_[i];
        up.ki.wScan = (WORD) MapVirtualKeyW(keysDown_[i], MAPVK_VK_TO_VSC);
        up.ki.dwFlags = KEYEVENTF_KEYUP
                      | (IsExtended(keysDown_[i]) ? KEYEVENTF_EXTENDEDKEY : 0);
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
