// mouse_fence.h — keeping the PC's own mouse off the capture display.
//
// The virtual display SolStream streams from is a monitor nobody can see,
// parked to the right of the real ones. To Windows it is desktop like any
// other, so the mouse on the desk slides onto it past the right edge of the
// last real screen -- and with a stream open, what is there is the streamed
// window. Someone playing a game on the PC moved their mouse off the game's
// edge, clicked, and the streamed browser took the keyboard from the game:
// measured on the dev PC, the log trading the keyboard between them for half
// an hour while nobody touched the Mac.
//
// So while a window is streamed, a low-level mouse hook in the host watches
// input that did NOT come from SendInput -- the hand on the PC's own mouse --
// and puts the pointer back on the real screen whenever it lands on the
// capture display, as if that edge were a wall. Movements are let through
// first and corrected after, so a game reading raw input still sees every
// one; a click or a turn of the wheel made while the pointer is on the
// capture display is held back, and sent again once the pointer is back,
// where it goes to what is there instead of to the streamed window. What the
// Mac sends is injected, and never touched.
//
// The decisions are here, apart from the hook, so they can be tested.

#pragma once

#include <windows.h>

namespace solstream {

/// Whether `point` is on the fenced-off display. An empty fence holds nothing.
inline bool InFence(const RECT& fence, POINT point) {
    return fence.right > fence.left && fence.bottom > fence.top
        && point.x >= fence.left && point.x < fence.right
        && point.y >= fence.top && point.y < fence.bottom;
}

/// The point of `area` nearest `point`: where the pointer stops against the
/// wall. `area` empty leaves the point as it is.
inline POINT ClampInto(const RECT& area, POINT point) {
    if (area.right <= area.left || area.bottom <= area.top) {
        return point;
    }
    POINT out = point;
    if (out.x < area.left) {
        out.x = area.left;
    } else if (out.x >= area.right) {
        out.x = area.right - 1;
    }
    if (out.y < area.top) {
        out.y = area.top;
    } else if (out.y >= area.bottom) {
        out.y = area.bottom - 1;
    }
    return out;
}

/// What the hook does with one event.
struct FenceAction {
    bool swallow = false;  ///< hold it back; it is sent again after the clamp
    bool clamp = false;    ///< put the pointer back on the real screen
};

/// `injected`: LLMHF_INJECTED -- the Mac's input, or any other program's.
/// `message`: the hook's wParam. `inside`: the event's point is on the fence.
inline FenceAction DecideFence(bool injected, UINT message, bool inside) {
    FenceAction action;
    if (injected || !inside) {
        return action;
    }
    action.clamp = true;
    // A movement goes through: a game turning its camera reads it as raw
    // input, and swallowing it would stop the turn at the edge.
    action.swallow = message != WM_MOUSEMOVE;
    return action;
}

/// The SendInput flags that send `message` again, with what goes in
/// mouseData; 0 for a message that is not a button or the wheel.
inline DWORD ResendFlags(UINT message, DWORD hook_mouse_data, DWORD& mouse_data) {
    mouse_data = 0;
    switch (message) {
    case WM_LBUTTONDOWN: return MOUSEEVENTF_LEFTDOWN;
    case WM_LBUTTONUP: return MOUSEEVENTF_LEFTUP;
    case WM_RBUTTONDOWN: return MOUSEEVENTF_RIGHTDOWN;
    case WM_RBUTTONUP: return MOUSEEVENTF_RIGHTUP;
    case WM_MBUTTONDOWN: return MOUSEEVENTF_MIDDLEDOWN;
    case WM_MBUTTONUP: return MOUSEEVENTF_MIDDLEUP;
    // Which X button, and how far the wheel turned, are the high word of the
    // hook's mouseData and the whole of SendInput's.
    case WM_XBUTTONDOWN:
        mouse_data = HIWORD(hook_mouse_data);
        return MOUSEEVENTF_XDOWN;
    case WM_XBUTTONUP:
        mouse_data = HIWORD(hook_mouse_data);
        return MOUSEEVENTF_XUP;
    case WM_MOUSEWHEEL:
        mouse_data = static_cast<DWORD>(static_cast<LONG>(static_cast<SHORT>(HIWORD(hook_mouse_data))));
        return MOUSEEVENTF_WHEEL;
    case WM_MOUSEHWHEEL:
        mouse_data = static_cast<DWORD>(static_cast<LONG>(static_cast<SHORT>(HIWORD(hook_mouse_data))));
        return MOUSEEVENTF_HWHEEL;
    default:
        return 0;
    }
}

}  // namespace solstream
