// full_screen.h — telling when a streamed application goes full screen.
//
// A video player, a browser showing a video, or a game going full screen on the
// PC does it the same way: it takes its caption away and stretches itself over
// the whole of its monitor. Its Mac window should follow, into full screen and
// back out. The host only reports the change; the Mac decides what to do, and
// sizes the PC window to its own full-screen window as it would after any
// other resize.
//
// Leaving is told by the caption coming back, not by the window no longer
// covering its monitor: once the Mac's window is full screen the host holds the
// PC window to that size, which is seldom the capture display's, and that is
// not the application leaving full screen.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

namespace solstream {

/// Whether a window carries a whole caption: a title bar, not just a border.
inline bool HasCaption(LONG_PTR style) {
    return (style & WS_CAPTION) == WS_CAPTION;
}

/// Whether `rect` covers every pixel of a (non-empty) `monitor`.
inline bool Covers(const RECT& rect, const RECT& monitor) {
    return monitor.right > monitor.left && monitor.bottom > monitor.top
        && rect.left <= monitor.left && rect.top <= monitor.top
        && rect.right >= monitor.right && rect.bottom >= monitor.bottom;
}

/// Whether a window is laid out as an application in full screen: no caption,
/// and covering every pixel of its monitor.
inline bool LooksFullScreen(LONG_PTR style, const RECT& window, const RECT& monitor) {
    return !HasCaption(style) && Covers(window, monitor);
}

enum class FullScreenChange { None, Entered, Left };

/// What changed since the last look, with `full_screen` the state as of that
/// look; it is updated to the state now. `held` is the area the host holds the
/// window to: when that covers the monitor, the host put it there, at the
/// Mac's asking -- a captionless app in a Mac window as big as the capture
/// display -- and the application has not gone anywhere.
inline FullScreenChange NextFullScreen(bool& full_screen, LONG_PTR style, const RECT& window,
                                       const RECT& monitor, const RECT& held) {
    if (!full_screen && LooksFullScreen(style, window, monitor) && !Covers(held, monitor)) {
        full_screen = true;
        return FullScreenChange::Entered;
    }
    if (full_screen && HasCaption(style)) {
        full_screen = false;
        return FullScreenChange::Left;
    }
    return FullScreenChange::None;
}

}  // namespace solstream
