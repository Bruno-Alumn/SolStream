// host_window.h — the one thing the user opens on the Windows PC.
//
// Everything this program does was previously reachable only from a command
// line: print the token, check which display is
// virtual, find out why a Mac cannot connect. That is a reasonable interface for
// the person who wrote it and no interface at all for anybody else.
//
// The window answers the four questions somebody actually has, in the order they
// have them: is this PC ready, what do I type on the Mac, is the display driver
// there, and — when a Mac is asking to pair — what is the code.

#pragma once

#include <functional>
#include <string>

namespace solstream::update {
struct CheckResult;
}  // namespace solstream::update

namespace solstream {

/// What the window shows. Filled in by the agent and read by the UI thread.
struct HostStatus {
    std::wstring computer_name;
    std::wstring address;          ///< Where the Mac should look, or empty.
    std::wstring pairing_token;
    bool agent_listening = false;
    bool streaming_ready = false;
    bool virtual_display = false;
    std::wstring streaming_detail;
    std::wstring display_detail;
    int connected_clients = 0;
    /// The Virtual Display Driver is here but switched off or failing: the
    /// user's own, which the window points at rather than offering to install.
    bool driver_off = false;
    /// This PC's Tailscale address, or empty when it is not on Tailscale.
    std::wstring tailscale_address;
};

/// Which face the window shows.
///
/// One window class, three faces, rather than a separate installer executable.
/// Setup is not a different program — it is the same program before it has been
/// put anywhere — and a second binary would be a second place for the theme, the
/// DPI handling and the wording to drift out of step. It is also the design's
/// own arrangement: first run is a state of this window, with a checklist.
enum class WindowMode {
    Host,       ///< Installed and running: status, token, pairing.
    Setup,      ///< Not installed yet: what it will do, and an Install button.
    Uninstall,  ///< Reached from Add/Remove Programs.
};

/// Create and show the window. Returns false if the window could not be made,
/// in which case the caller should carry on headless rather than exit — the
/// agent is useful without a UI, and a machine with no window station (a service
/// in session 0) is exactly where that happens.
/// `start_hidden`: the host goes straight to the notification area with no
/// window, which is how it starts at logon. Ignored for setup and uninstall.
bool ShowHostWindow(WindowMode mode = WindowMode::Host, bool start_hidden = false);

/// Replace what the window displays. Safe to call from any thread.
void UpdateHostStatus(const HostStatus& status);

/// What an update check found, for the window to announce: a banner and a tray
/// item when there is an update, and -- only when somebody asked, through
/// "Check for updates" -- the answer either way. Never a balloon, and never the
/// foreground: an automatic check is something the window mentions, not
/// something that interrupts. Safe to call from any thread.
void UpdateCheckFinished(const update::CheckResult& result, bool asked);

/// What became of the update an earlier copy started installing: `installed`
/// when this copy is `version`, otherwise it did not finish. Said in the
/// window's notice. Call before ShowHostWindow, on the thread that will run it.
void SayInstallOutcome(bool installed, const std::string& version);

/// What to run once the window's "Set up" has installed a virtual display into
/// this running host: choosing it as the display to capture. Called on a
/// worker thread. Set before ShowHostWindow.
void SetDisplayReadyHandler(std::function<void()> handler);

/// Pump the window's messages until it is closed. Returns the exit code.
int RunHostWindowLoop();

/// True once the user has closed the window.
bool HostWindowClosed();

/// Bring an already-running SolStream's window forward, if there is one.
///
/// Returns false when nothing is running, which is the caller's cue to be that
/// something. The shortcuts point at the executable with no arguments, so
/// without this a second press would start a second agent to fight the first
/// for the port — and the window the user was asking to see would never appear.
bool FocusExistingHostWindow();

}  // namespace solstream
