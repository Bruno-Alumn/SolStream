// tray_tip.h -- what the notification-area icon's tooltip says.
//
// With the window hidden, which is how SolStream spends its day, the tooltip
// is the one thing that says how it is -- so it says the hard failures the
// window leads with, not "ready" over a PC no Mac can reach. Apart from
// host_window.cpp, which draws everything else, so it can be tested.

#pragma once

#include <string>
#include <vector>

#include "host_window.h"

namespace solstream {

/// The tooltip for `status`, with `update_version` the update on offer or
/// empty -- g_update_tip_version, read under g_mutex by the caller. Short: the
/// notification area cuts a tip at 127 characters.
///
/// The host lives in the tray, so an update an automatic check found is said
/// here as well -- quietly, where somebody pointing at the icon will see it,
/// rather than with a balloon. Not while streaming: then the stream is what the
/// icon is about, and Install has to wait for the Mac anyway. Nor over a hard
/// failure, which the window leads with too.
/// `update_ready`: the update is downloaded and checked, so Install goes
/// straight to the permission prompt -- "ready to install" rather than
/// "available", as the notification says it.
inline std::wstring TrayTip(const HostStatus& status, const std::wstring& update_version,
                            bool update_ready = false) {
    if (!status.agent_listening) {
        return L"SolStream — not reachable yet";
    }
    // The window's two hard failures, in its order: no address is SS-104,
    // a streaming host that did not start is the next.
    if (status.address.empty()) {
        return L"SolStream — not reachable: this PC has no network address";
    }
    if (!status.streaming_ready) {
        return L"SolStream — streaming didn't start";
    }
    if (status.connected_clients > 0) {
        return L"SolStream — streaming to your Mac";
    }
    if (!update_version.empty()) {
        return L"SolStream — update " + update_version
             + (update_ready ? L" ready to install" : L" available");
    }
    // As the window leads with it, after an update as there: "ready" over a
    // restart still owed read as nothing left to do.
    if (!status.virtual_display && status.driver_restart_pending) {
        return L"SolStream — restart this PC to finish the virtual display";
    }
    return L"SolStream — ready for your Mac";
}

/// The host window's title: the tooltip's words. The title is what Alt+Tab,
/// the taskbar's thumbnail and Narrator say of the window, and a plain
/// "SolStream" there said nothing of how it is.
inline std::wstring HostWindowTitle(const HostStatus& status, const std::wstring& update_version,
                                    bool update_ready = false) {
    return TrayTip(status, update_version, update_ready);
}

/// The title of the notification a scheduled check puts up. "Ready to
/// install" only once the installer is downloaded and checked; until then it
/// is "available", as the window's banner and the tooltip say it.
inline std::wstring UpdateNoticeTitle(const std::wstring& version, bool downloaded) {
    return L"SolStream " + version + (downloaded ? L" is ready to install" : L" is available");
}

/// The notification's text: what a click on it does, and the prompt it leads to.
inline std::wstring UpdateNoticeText(bool downloaded) {
    return downloaded
        ? L"It's downloaded and checked. Click here to install it \u2014 Windows will ask "
          L"for permission."
        : L"Click here to download and install it \u2014 Windows will ask for permission.";
}

/// The tray menu's items, by the command each sends back.
constexpr unsigned kTrayOpen = 1;
constexpr unsigned kTrayCopyToken = 2;
constexpr unsigned kTrayQuit = 3;
constexpr unsigned kTrayInstallUpdate = 4;
constexpr unsigned kTrayCheckUpdates = 5;
constexpr unsigned kTraySetUpDisplay = 6;
constexpr unsigned kTrayShowLog = 7;

/// What the tray menu is drawn from.
struct TrayMenuState {
    bool connected = false;     ///< a Mac is streaming: the token is hidden
    bool no_token = false;
    bool busy = false;          ///< a job, a check or an install under way
    bool job_running = false;
    bool streaming = false;
    std::wstring update_version;  ///< the update on offer, or empty
    bool offer_display = false;   ///< the virtual display's Set up applies here
};

/// One item, or a separator where `id` is 0.
struct TrayItem {
    unsigned id = 0;
    std::wstring caption;
    bool greyed = false;
};

/// The tray menu for `state`. Items are greyed rather than left out while
/// they can't be had, so the menu keeps its shape from one opening to the
/// next: Copy while the token is hidden or not there yet; the update ones
/// while something is under way, and Install while a Mac streams; Quit while
/// a job runs, when closing is refused. Show log is always there: it is what
/// to send along with a question, whatever is going on.
inline std::vector<TrayItem> TrayMenuItems(const TrayMenuState& state) {
    std::vector<TrayItem> items;
    items.push_back({kTrayOpen, L"Open SolStream", false});
    items.push_back({kTrayCopyToken, L"Copy pairing token", state.connected || state.no_token});
    items.push_back({});
    if (!state.update_version.empty()) {
        items.push_back({kTrayInstallUpdate, L"Install update " + state.update_version + L"\u2026",
                         state.busy || state.streaming});
    }
    items.push_back({kTrayCheckUpdates, L"Check for updates", state.busy});
    if (state.offer_display) {
        items.push_back({kTraySetUpDisplay, L"Set up virtual display\u2026", state.busy});
    }
    items.push_back({});
    items.push_back({kTrayShowLog, L"Show log", false});
    items.push_back({kTrayQuit, L"Quit SolStream", state.job_running});
    return items;
}

}  // namespace solstream
