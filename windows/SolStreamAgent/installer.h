// installer.h — SolStream installs itself.
//
// There used to be a PowerShell script for this, which meant the answer to "how
// do I install this" was "open PowerShell, mind the execution policy, and pass
// the right -Package path". For an application whose whole premise is that the
// user never has to think about any of it, that was the wrong first impression —
// and a script is also the one artefact that cannot be signed the way an
// executable can.
//
// So the executable does it. There is no separate installer to build, ship or
// keep in step: the same binary that streams is the binary that installs, which
// is the only arrangement where the two cannot drift apart.

#pragma once

#include <string>

namespace solstream {

/// Is this process running with an administrator token?
bool IsElevated();

/// Re-launch this executable elevated, passing `arguments`, and wait for it.
///
/// Deliberately visible: the UAC prompt is the moment the user agrees to a
/// program writing to Program Files, creating firewall rules and registering a
/// logon task. Suppressing it would mean doing all of that behind their back.
bool RelaunchElevated(const std::wstring& arguments, std::string& error);

/// Copy this program and everything beside it into Program Files, open the
/// ports it needs, and register it to start at logon. Returns false and fills
/// `error` with something a person can act on.
bool InstallSelf(std::string& error);

/// Undo InstallSelf. Settings in %LOCALAPPDATA%\SolStream are deliberately kept:
/// they hold the pairing token and the generated Sunshine credentials, and
/// making every Mac pair again after a reinstall is a worse default than leaving
/// a few kilobytes behind.
bool UninstallSelf(std::string& error);

/// Where an install lives.
std::wstring InstallDirectory();

/// True when this executable is already running from the install directory,
/// which is what tells the running program it does not need to offer setup.
bool RunningInstalled();

}  // namespace solstream
