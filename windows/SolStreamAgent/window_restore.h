// window_restore.h — giving a streamed window back exactly as it was found.
//
// A streamed window spends its session on the capture display, which runs at
// 200%, and goes back at the end to a monitor that usually runs at something
// else. This is the part of putting it back that needs no window, so it can
// be tested.
//
// SetWindowPlacement moves a window across monitors, and a window that is
// per-monitor DPI aware -- File Explorer, anything modern -- answers the
// WM_DPICHANGED that move sends by scaling ITSELF by the ratio of the two
// scalings, after it has already been given the size it was asked for. Measured
// on a 125% monitor: put back at 1406x792, it settled at 879x495, every time,
// and the Mac opened the next session at the smaller size and shrank it again
// at the end. Asked a second time, the window is already on that monitor, no
// DPI change follows, and it keeps the size it is given.

#pragma once

#include <windows.h>

#include <functional>

namespace solstream {

/// How many times one restore will ask. The first carries the window across
/// monitors and may be rescaled after it; the second lands on the same monitor
/// and is kept; the third is for an application that lays itself out again a
/// beat late. Past that the window is holding a size of its own.
constexpr int kRestorePlacementAttempts = 3;

/// How far a window's restored rectangle is from the one it was asked for, as
/// one number.
long long PlacementDistance(const RECT& wanted, const RECT& got);

/// Apply `saved` through `set`, read it back through `get`, and apply it again
/// while the window has landed somewhere else and is getting closer. Returns
/// the number of times `set` was called, 0 when the first one failed;
/// `matched` says whether the window ended where it was asked to be.
int RestorePlacement(const WINDOWPLACEMENT& saved,
                     const std::function<bool(const WINDOWPLACEMENT&)>& set,
                     const std::function<bool(WINDOWPLACEMENT&)>& get,
                     bool* matched = nullptr);

}  // namespace solstream
