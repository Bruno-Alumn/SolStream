// stranded.h — which windows on the capture display belong to the stream.
//
// The capture display has no panel, so a window that lands on it and is not
// being streamed is invisible to everyone: the host carries those back to a
// monitor (RescueStrandedWindows in main.cpp). What it must NOT carry off is
// what the streamed application asked for, because the user answers that
// through the video. Matching by process alone missed the dialogs Windows
// raises for an application from a process of its own: the Windows Security
// credential and passkey prompts (CredentialUIBroker.exe), the work-account
// sign-in of Office, Teams and OneDrive (Microsoft.AAD.BrokerPlugin.exe), and
// "How do you want to open this file?" (OpenWith.exe). Each one opened over the
// streamed window, was moved to a monitor the Mac cannot see within a second,
// and left the application waiting on a question nobody could answer.
//
// Two things now keep a window where it is, either being enough. Its owner
// chain reaches a streamed window, or a window of a streamed process: that is
// how Windows itself says a dialog belongs to an application. Or it is in the
// picture the Mac is showing: its middle inside the part of the display a
// streamed window is held to, and IN FRONT of that window -- always on top, or
// met before it going down the z-order. The Mac pins every streamed window on
// top, so a window that is merely under one is hidden from everybody, and that
// one is still carried off.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <vector>

namespace solstream {

/// One streamed window, copied out of its lock slot.
struct StreamedWindow {
    HWND window = nullptr;
    DWORD pid = 0;
    /// The client area it is held to, in virtual-desktop coordinates.
    RECT desired{};
    /// Whether `desired` is in force. A slot that is not held has no area.
    bool held = false;
    /// Whether the search, going from the top of the z-order down, has met
    /// this window yet. Every window met after it is behind it.
    bool met = false;
};

/// One window in a candidate's owner chain, nearest owner first.
struct OwnerLink {
    HWND window = nullptr;
    DWORD pid = 0;
};

/// Whether the middle of `rect` lies inside `area`.
inline bool MiddleInside(const RECT& rect, const RECT& area) {
    const LONG x = rect.left + (rect.right - rect.left) / 2;
    const LONG y = rect.top + (rect.bottom - rect.top) / 2;
    return x >= area.left && x < area.right && y >= area.top && y < area.bottom;
}

/// Note that the search going down the z-order has reached `window`.
inline void NoteMet(HWND window, std::vector<StreamedWindow>& streamed) {
    for (StreamedWindow& slot : streamed) {
        if (slot.window == window) {
            slot.met = true;
        }
    }
}

/// Whether the window `window`, of process `pid`, with these owners and this
/// rectangle, is part of what is being streamed and so stays put. `topmost`
/// is whether it is always on top.
inline bool PartOfTheStream(HWND window, DWORD pid, const std::vector<OwnerLink>& owners,
                            const RECT& rect, bool topmost,
                            const std::vector<StreamedWindow>& streamed) {
    for (const StreamedWindow& slot : streamed) {
        if (slot.window == window || (slot.pid != 0 && slot.pid == pid)) {
            return true;
        }
        for (const OwnerLink& owner : owners) {
            if ((owner.window && owner.window == slot.window)
                || (slot.pid != 0 && owner.pid == slot.pid)) {
                return true;
            }
        }
        if (slot.held && (topmost || !slot.met) && MiddleInside(rect, slot.desired)) {
            return true;
        }
    }
    return false;
}

}  // namespace solstream
