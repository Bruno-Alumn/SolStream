// What the host leaves behind when it crashes, and how it comes back.
//
// A crash used to leave nothing: the log stopped mid-session, Windows kept
// no report, the logon task said 0xC0000005, and the host stayed gone until
// the next logon -- a day and a half, the one time it was seen. Now it says
// where in its log, keeps a minidump beside it, and starts again.
#pragma once

namespace solstream {

/// From here on, a crash appends "[crash] …" to solstream.log, writes
/// crash.dmp beside it (stacks and thread state only, overwritten each time),
/// and -- when `restart` is set and the process had run for a minute, so a
/// crash at start cannot loop -- starts this program again with its own
/// command line and `--after-crash <pid>`. Everything the handler needs is
/// worked out here, ahead of time: a crashing process may have a broken heap.
void InstallCrashReport(bool restart);

/// For a copy started by InstallCrashReport: waits up to 15 s for the copy
/// that crashed to be gone, so its single-instance name is free.
void WaitForCrashedCopy(unsigned long pid);

}  // namespace solstream
