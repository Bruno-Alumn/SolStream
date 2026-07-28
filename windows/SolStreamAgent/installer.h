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
// is the only arrangement where the two cannot drift apart. What ships is that
// binary named SolStreamSetup.exe; run from anywhere other than the install
// directory it shows the setup screen, and what it copies into Program Files is
// itself, named SolStream.exe.

#pragma once

#include <string>

namespace solstream {

/// The version reported to Add/Remove Programs. One place, so the number in the
/// control panel cannot disagree with the number in the window.
constexpr wchar_t kVersion[] = L"1.0.0";

/// What the user ticked on the setup screen.
///
/// All three default to on, because all three are what somebody installing a
/// program expects to get and every one of them is trivially reversible. The
/// setup screen still shows them, because a program that puts things on your
/// desktop without saying so is a program you resent.
struct InstallOptions {
    bool desktop_shortcut = true;
    bool start_menu_shortcut = true;
    bool start_at_logon = true;
};

/// Encode/decode options as command-line switches, because the install runs in a
/// second, elevated process and this is how the choice gets there.
std::wstring OptionArguments(const InstallOptions& options);
InstallOptions OptionsFromArguments(int argc, wchar_t** argv);

/// Is this process running with an administrator token?
bool IsElevated();

/// Re-launch this executable elevated, passing `arguments`, and wait for it.
///
/// Deliberately visible: the UAC prompt is the moment the user agrees to a
/// program writing to Program Files, creating firewall rules and registering a
/// logon task. Suppressing it would mean doing all of that behind their back.
bool RelaunchElevated(const std::wstring& arguments, std::string& error);

/// Copy this program into Program Files, open the ports it needs, register it to
/// start at logon and make the shortcuts asked for. Returns false and fills
/// `error` with something a person can act on.
bool InstallSelf(const InstallOptions& options, std::string& error);

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

/// Copy this executable to a temporary directory and run *that* with the same
/// arguments, then return true so the caller can exit.
///
/// A program cannot delete the directory it is running from, so uninstalling
/// from Program Files leaves SolStream.exe behind and reports failure — which is
/// exactly what Add/Remove Programs would invoke. Stepping outside first is the
/// standard answer and the only one that works.
bool RelaunchFromTemp(const std::wstring& arguments, std::string& error);

/// Where the install writes what it did. The one file to ask for when an install
/// fails on a machine nobody was watching.
std::wstring InstallLogPath();

/// The elevated install runs in a second process, so its failure has to travel
/// back somehow. It writes the reason here and the setup screen reads it, rather
/// than showing the user an exit code.
void WriteInstallResult(bool ok, const std::string& error);
bool ReadInstallResult(std::string& error);

}  // namespace solstream
