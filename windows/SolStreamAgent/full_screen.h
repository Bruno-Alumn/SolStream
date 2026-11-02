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

/// What the watcher knows about one streamed window's full screen.
struct FullScreenWatch {
    /// Gone full screen, as far as the Mac was told.
    bool on = false;
    /// Seen with a caption since it last went full screen. Only an app that had
    /// a caption can be said to have dropped it: one drawn without a caption
    /// -- Steam, a frameless Electron or Qt app, a borderless game -- covers
    /// its monitor whenever it maximises, or when the Mac's window is as big as
    /// the capture display, and none of that is going full screen. The price is
    /// an app that starts out full screen: it is not followed until it has
    /// once come out.
    bool armed = false;
    /// Until when the host leaves the window where the app put it, waiting for
    /// the Mac's window to go full screen and ask for a size; 0 when not
    /// waiting. Without it the watcher put the window straight back on its
    /// tile, a tick after it went full screen, for the second the Mac's
    /// animation takes -- and an app that leaves full screen when resized
    /// from outside left it there and then.
    ULONGLONG hold_until = 0;
};

/// What changed since the last look, with `watch` the state as of that look;
/// it is updated to the state now. `held` is the area the host holds the
/// window to: when that covers the monitor, the host put it there, at the
/// Mac's asking, and the application has not gone anywhere.
inline FullScreenChange NextFullScreen(FullScreenWatch& watch, LONG_PTR style,
                                       const RECT& window, const RECT& monitor,
                                       const RECT& held) {
    if (HasCaption(style)) {
        watch.armed = true;
        if (!watch.on) {
            return FullScreenChange::None;
        }
        watch.on = false;
        watch.hold_until = 0;
        return FullScreenChange::Left;
    }
    // Maximised is not full screen: the watcher un-maximises it.
    if (!watch.on && watch.armed && (style & WS_MAXIMIZE) == 0 && Covers(window, monitor)
        && !Covers(held, monitor)) {
        watch.on = true;
        watch.armed = false;
        return FullScreenChange::Entered;
    }
    return FullScreenChange::None;
}

/// Whether the watcher should leave the window alone for now; see hold_until.
inline bool WaitingForMac(const FullScreenWatch& watch, ULONGLONG now) {
    return watch.hold_until != 0 && now < watch.hold_until;
}

}  // namespace solstream
