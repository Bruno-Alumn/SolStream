// window_restore.h — giving a streamed window back exactly as it was found.
//
// A streamed window spends its session on the capture display, which runs at
// 200%, and goes back at the end to a monitor that usually runs at something
// else. Two things went wrong with that, and these are the parts of the cure
// that need no window, so they can be tested.
//
// The size. SetWindowPlacement moves a window across monitors, and a window
// that is per-monitor DPI aware -- File Explorer, anything modern -- answers
// the WM_DPICHANGED that move sends by scaling ITSELF by the ratio of the two
// scalings, after it has already been given the size it was asked for. Measured
// on a 125% monitor: put back at 1406x792, it settled at 879x495, every time,
// and the Mac opened the next session at the smaller size and shrank it again
// at the end. Asked a second time, the window is already on that monitor, no
// DPI change follows, and it keeps the size it is given.
//
// The record. What a window is owed lives in the host's memory, so a host that
// is killed mid-session -- ended from Task Scheduler, upgraded by force,
// crashed -- left the window on a display nobody can see and without the
// resize border and maximise box the session had taken. The next host found a
// window that could not be resized and believed it. So it is written down as
// well, and the next host gives it back before it serves anyone.

#pragma once

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

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

/// The placement to give back: `saved`, except that a window hidden now stays
/// hidden.
///
/// An application that hides to the notification area -- Discord, Steam,
/// Teams -- keeps its window, its handle and its process when the user closes
/// it, and only stops showing it. The placement saved before the session says
/// "shown", so putting it back as saved would bring back a window the user had
/// just put away. Hidden, it still gets its place and size back, for whenever
/// the application shows it again.
WINDOWPLACEMENT PlacementForRestore(const WINDOWPLACEMENT& saved, bool visible);

/// One window a host owes a restore to, as it is written down.
struct OwedWindow {
    uint64_t window = 0;      // the HWND, as the Mac also knows it
    uint32_t pid = 0;         // who owned it, against handle reuse
    uint64_t removed_style = 0;
    bool topmost = false;     // whether it was always-on-top before
    WINDOWPLACEMENT placement{};
};

/// The record as text: a header line, then one line of numbers per window.
std::string FormatOwedWindows(const std::vector<OwedWindow>& windows);

/// The record read back. Lines that are not whole are skipped, as is a record
/// without the header; an empty list is the answer to anything unreadable.
std::vector<OwedWindow> ParseOwedWindows(const std::string& text);

/// Write the record to `path`, replacing it whole, or remove it when there is
/// nothing owed. False when the file could not be written.
bool SaveOwedWindows(const std::wstring& path, const std::vector<OwedWindow>& windows);

/// Read the record at `path`; empty when there is none.
std::vector<OwedWindow> LoadOwedWindows(const std::wstring& path);

}  // namespace solstream
