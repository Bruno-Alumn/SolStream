// display_demand.h — the virtual display on the desktop only while a Mac is
// connected.
//
// Attached for good, the virtual display is a monitor nobody can see that
// Windows treats like any other: windows open on it, the mouse wanders onto
// it, a game asks how many monitors there are and counts it, and Sunshine or
// a screenshot tool lists it. Apollo's SudoVDA and Parsec's VDD add theirs
// when a client connects and take it away when it goes. The MTT driver
// SolStream uses has no such watchdog, so the host does it: it attaches the
// display when a Mac proves the token, before the display list the Mac picks
// its capture display from, and detaches it once nothing has used it for
// kDetachAfterIdleMs.
//
// Idle, not "the last Mac left": the slot is freed before the streamed
// windows are given back, so a Mac reconnecting or taking its session over
// can be in before the last one is done, and a detach timed from the leaving
// would land under it. The watcher looks instead, and only detaches a display
// that has sat unused for the whole delay -- which covers a host that starts
// with it attached, after a crash, too, without flapping against the Mac
// reconnecting to it.
//
// Never under a full-screen game: attaching or detaching is a reconfiguration
// of the whole desktop, and a game in exclusive full screen loses its mode,
// or minimises, over it. The detach waits; the attach is skipped, and that
// session streams the real monitor, as a PC without the display does.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#include <string>

#include "display_mode.h"

namespace solstream {

/// How long the virtual display stays attached with nothing using it. Longer
/// than the Mac's reconnect backoff (2 s) and a takeover's wait for the
/// session it ended, so a Mac coming straight back finds it still there, and
/// longer than the rescue of stranded windows takes, so whatever the restore
/// left on it is carried to a monitor before the display goes.
constexpr unsigned long long kDetachAfterIdleMs = 10000;

/// What the watcher knows about the virtual display going unused.
struct DisplayIdle {
    /// When it was first seen attached with nothing using it; 0 when it is in
    /// use or not attached.
    unsigned long long since = 0;
    /// Whether a detach has been put off for a full-screen game, and said so.
    bool deferred = false;
    /// Whether the last detach did not happen -- it is the primary display or
    /// the only one, or Windows said no. Not tried again until the display has
    /// been in use or off the desktop, or it is tried, and said, every few
    /// seconds for as long as the host runs.
    bool refused = false;
};

enum class DisplayStep {
    Wait,    ///< nothing to do now
    Detach,  ///< detach it now
    Defer,   ///< due, but a full-screen game is in front: say so, and wait
};

/// What to do about the virtual display at `now`, with `idle` as of the last
/// look, updated to now. `attached` is whether SolStream's is on the desktop;
/// `in_use` whether a Mac holds the slot, windows are still being given back,
/// or setup is working on it; `game` whether a full-screen game is in front.
/// Defer is said once per wait, and Wait after it until the game has gone.
inline DisplayStep NextDisplayStep(DisplayIdle& idle, unsigned long long now, bool attached,
                                   bool in_use, bool game,
                                   unsigned long long after_ms = kDetachAfterIdleMs) {
    if (!attached || in_use) {
        idle = DisplayIdle{};
        return DisplayStep::Wait;
    }
    if (idle.refused) {
        return DisplayStep::Wait;
    }
    if (idle.since == 0) {
        // 0 is "not idle", so a clock that reads 0 starts at 1.
        idle.since = now == 0 ? 1 : now;
        return DisplayStep::Wait;
    }
    if (now - idle.since < after_ms) {
        return DisplayStep::Wait;
    }
    if (game) {
        if (idle.deferred) {
            return DisplayStep::Wait;
        }
        idle.deferred = true;
        return DisplayStep::Defer;
    }
    idle = DisplayIdle{};
    return DisplayStep::Detach;
}

/// After a Detach that did not happen; see DisplayIdle::refused.
inline void NoteDetachRefused(DisplayIdle& idle) {
    idle = DisplayIdle{};
    idle.refused = true;
}

/// SHQueryUserNotificationState's answers that mean something is full screen:
/// QUNS_BUSY (a full-screen application, or presentation settings),
/// QUNS_RUNNING_D3D_FULL_SCREEN and QUNS_PRESENTATION_MODE. Plain numbers, so
/// the test program needs no shell header.
inline bool NotificationStateIsFullScreen(int state) {
    return state == 2 || state == 3 || state == 4;
}

/// Whether a full-screen game is in front on the PC, so the display layout
/// must not change under it. `state` is SHQueryUserNotificationState's answer;
/// `fills_monitor` whether the foreground window has no caption and covers
/// its monitor; `on_virtual` whether that monitor is SolStream's own virtual
/// display -- where a streamed window held to the Mac's full screen looks
/// exactly like that, and is no game on the PC.
inline bool FullScreenInFront(int state, bool fills_monitor, bool on_virtual) {
    if (on_virtual) {
        return false;
    }
    return fills_monitor || NotificationStateIsFullScreen(state);
}

/// The size the virtual display was at when it was last detached, as the host
/// writes it down ("3024x1964"), so the next attach puts it back at the size
/// the Mac's `canvas` chose rather than at one the Mac then changes. False for
/// anything else, or a size the encoder would not take.
inline bool ParseDisplaySize(const std::string& text, unsigned& width, unsigned& height) {
    unsigned long long w = 0, h = 0;
    size_t i = 0;
    const auto digits = [&text, &i](unsigned long long& out) {
        const size_t start = i;
        while (i < text.size() && text[i] >= '0' && text[i] <= '9' && i - start < 6) {
            out = out * 10 + (unsigned) (text[i] - '0');
            ++i;
        }
        return i > start;
    };
    if (!digits(w) || i >= text.size() || text[i] != 'x') {
        return false;
    }
    ++i;
    if (!digits(h)) {
        return false;
    }
    while (i < text.size() && (text[i] == '\r' || text[i] == '\n')) {
        ++i;
    }
    if (i != text.size() || !KeepsAttachedSize((unsigned) w, (unsigned) h)) {
        return false;
    }
    width = (unsigned) w;
    height = (unsigned) h;
    return true;
}

}  // namespace solstream
