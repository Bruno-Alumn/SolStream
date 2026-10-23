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
/// and is kept; the third is for a window whose second answer moved it again.
/// Past that the window is holding a size of its own.
///
/// No pause between them. The rescaling was measured happening inside the
/// SetWindowPlacement call itself -- read back at once and again 500 ms later,
/// File Explorer was at the same rescaled size both times, and at the exact
/// one after the second call -- so a wait would find nothing new, and it would
/// be paid on every window at every disconnect.
constexpr int kRestorePlacementAttempts = 3;

/// How far a window's restored rectangle is from the one it was asked for, as
/// one number.
long long PlacementDistance(const RECT& wanted, const RECT& got);

constexpr int kRestorePlacementFailed = -1;

/// Apply `saved` through `set`, read it back through `get`, and apply it again
/// while the window has landed somewhere else and is getting closer. Returns
/// the number of times `set` was called, or kRestorePlacementFailed when either
/// Windows call failed. `matched` says whether it ended where it was asked to be.
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
    /// When that process started (GetProcessTimes, 100 ns units). A pid is
    /// reused as readily as a handle, so the pair alone could name an
    /// unrelated window; with the start time it names one process only.
    uint64_t process_created = 0;
    uint64_t removed_style = 0;
    bool topmost = false;     // whether it was always-on-top before
    WINDOWPLACEMENT placement{};
    /// Memory only, never written: distinguishes a newer debt from a stale
    /// startup snapshot naming the same handle. Loaded records start at zero.
    uint64_t revision = 0;
};

/// The whole record: the windows, and which run of Windows wrote it.
struct OwedRecord {
    /// When this PC last started, in whole seconds of the system clock
    /// (BootSecond), as the writer worked it out.
    uint64_t boot = 0;
    /// The writer's GetTickCount64 at the time.
    uint64_t written = 0;
    std::vector<OwedWindow> windows;
};

/// When the PC started, in seconds of the system clock: the time now less how
/// long it has been running. `filetime_now` is GetSystemTimeAsFileTime as one
/// number, `tick_ms` GetTickCount64.
uint64_t BootSecond(uint64_t filetime_now, uint64_t tick_ms);

/// How far two workings-out of the same start may differ: rounding, and the
/// clock being set while the PC runs.
constexpr uint64_t kBootSlackSeconds = 60;

/// Whether `record` was written since this PC last started. Window handles and
/// pids start again with Windows, so a record from before a restart names
/// windows that are not the ones it means, however well they match. A start
/// further from this one than the slack is another; and a record written later
/// into its run than this run has lasted cannot be from this one either.
bool RecordIsFromThisBoot(const OwedRecord& record, uint64_t boot_second, uint64_t tick_ms);

/// What to write down: every window a slot holds, then each one a stopped host
/// left behind that no slot has taken since.
std::vector<OwedWindow> OwedToWrite(const std::vector<OwedWindow>& held,
                                    const std::vector<OwedWindow>& left_behind);

/// Take this window's entry out of `owed`. True, with it in `taken`, when the
/// entry is for this same process; an entry for the handle under another
/// process is out of date, and is dropped without being taken. Zero start times
/// are safe here because they exist only in memory, never in a loaded record.
bool TakeOwed(std::vector<OwedWindow>& owed, uint64_t window, uint32_t pid,
              uint64_t process_created, OwedWindow* taken);

/// Forget a rejected startup entry only if a newer handoff has not replaced it.
bool ForgetOwedRevision(std::vector<OwedWindow>& owed, uint64_t window, uint64_t revision);

enum class RestoreOutcome { Restored, Gone, Retry };

/// Add or replace a window's debt without duplicating its handle.
void RememberOwed(std::vector<OwedWindow>& owed, const OwedWindow& entry);

/// Whether an older restore still owns this window. A new session must not
/// claim it until FinishRestore clears that ownership.
bool RestoreInProgress(const std::vector<uint64_t>& restoring, uint64_t window);

/// Mark a still-owed snapshot as being restored. False when it was replaced,
/// is already being restored, or has a zero handle.
bool BeginRestore(const std::vector<OwedWindow>& owed,
                  std::vector<uint64_t>& restoring, uint64_t window, uint64_t revision);

/// Clear the in-progress mark. Only a completed restore or a window known to be
/// gone loses its debt; a failed or hung restore stays owed for another try.
/// A newer revision of the same handle is never erased by an older completion.
void FinishRestore(std::vector<OwedWindow>& owed, std::vector<uint64_t>& restoring,
                   uint64_t window, uint64_t revision, RestoreOutcome outcome);

/// The record as text: a header line, the line saying when it was written, then
/// one line of numbers per window.
std::string FormatOwedWindows(const OwedRecord& record);

/// The record read back. Window lines that are not whole are skipped; a record
/// without the header or the time it was written reads as empty.
OwedRecord ParseOwedWindows(const std::string& text);

/// Write the record to `path`, replacing it whole, or remove it when no window
/// is owed. False when the file could not be written.
bool SaveOwedWindows(const std::wstring& path, const OwedRecord& record);

/// Read the record at `path`; empty when there is none.
OwedRecord LoadOwedWindows(const std::wstring& path);

}  // namespace solstream
