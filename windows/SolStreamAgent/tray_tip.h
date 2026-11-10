// tray_tip.h -- what the notification-area icon's tooltip says.
//
// With the window hidden, which is how SolStream spends its day, the tooltip
// is the one thing that says how it is -- so it says the hard failures the
// window leads with, not "ready" over a PC no Mac can reach. Apart from
// host_window.cpp, which draws everything else, so it can be tested.

#pragma once

#include <string>

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
inline std::wstring TrayTip(const HostStatus& status, const std::wstring& update_version) {
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
        return L"SolStream — update " + update_version + L" available";
    }
    return L"SolStream — ready for your Mac";
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

}  // namespace solstream
