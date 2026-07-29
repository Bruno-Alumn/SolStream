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

#include <string>

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
bool ShowHostWindow(WindowMode mode = WindowMode::Host);

/// Replace what the window displays. Safe to call from any thread.
void UpdateHostStatus(const HostStatus& status);

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
