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
/// empty. Short: the notification area cuts a tip at 127 characters.
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

}  // namespace solstream
