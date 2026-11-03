// What the host leaves behind when it crashes, and how it comes back.
//
// A crash used to leave nothing: the log stopped mid-session, Windows kept
// no report, the logon task said 0xC0000005, and the host stayed gone until
// the next logon -- a day and a half, the one time it was seen. Now it says
// where in its log, keeps a minidump beside it, and starts again.
#pragma once

namespace solstream {

/// From here on, a crash appends "[crash] …" to solstream.log; when
/// `restart` is set and the process had run for a minute -- so a crash at
/// start cannot loop -- and has not already come back five times, it starts
/// this program again with its own command line and `--after-crash <pid>`;
/// then it writes crash.dmp beside the log (stacks and thread state only,
/// overwritten each time) and ends the process. Covers faults the system
/// raises and an uncaught C++ exception, and std::terminate, a pure virtual
/// call and an invalid parameter to the C runtime; not a fail-fast (/GS,
/// heap corruption), which ends the process without running any of this.
/// Everything the handler needs is worked out here, ahead of time: a crashing
/// process may have a broken heap.
void InstallCrashReport(bool restart);

/// From here on a crash is reported but not restarted: the host is on its
/// way out by request -- Quit, an installer, Windows ending the session --
/// and coming back in the tray would undo that.
void DisableCrashRestart();

/// For a copy started by InstallCrashReport: waits up to 15 s for the copy
/// that crashed to be gone, so its single-instance name is free.
void WaitForCrashedCopy(unsigned long pid);

}  // namespace solstream
