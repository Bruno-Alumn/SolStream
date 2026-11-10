// banner_advice.h -- the place a banner's advice names, and the button that
// opens it.
//
// The window's banners told people to go to Device Manager, Windows Update or
// their network settings and left them to find the way; the button opens it.
// Apart from host_window.cpp, which draws the banner, so it can be tested.

#pragma once

#include <string>

#include "host_window.h"

namespace solstream {

enum class AdvicePlace { None, NetworkSettings, WindowsUpdate, DeviceManager };

/// Where the banner for `status` sends somebody, in the window's own order:
/// no address, then streaming that cannot start, then a virtual display
/// driver that is here and switched off or failing. A restart owed names no
/// place -- the restart is the thing to do -- nor does a driver SolStream can
/// set up itself, which has a button of its own.
inline AdvicePlace AdvicePlaceFor(const HostStatus& status) {
    if (status.address.empty()) {
        return AdvicePlace::NetworkSettings;
    }
    if (!status.streaming_ready) {
        return status.windows_too_old ? AdvicePlace::WindowsUpdate : AdvicePlace::None;
    }
    if (status.virtual_display || status.driver_restart_pending) {
        return AdvicePlace::None;
    }
    return status.driver_off || status.driver_failing ? AdvicePlace::DeviceManager
                                                      : AdvicePlace::None;
}

/// The button's caption.
inline const wchar_t* AdviceCaption(AdvicePlace place) {
    switch (place) {
        case AdvicePlace::NetworkSettings: return L"Network settings";
        case AdvicePlace::WindowsUpdate: return L"Windows Update";
        case AdvicePlace::DeviceManager: return L"Device Manager";
        case AdvicePlace::None: break;
    }
    return L"";
}

/// What the button hands the shell: a Settings page by its ms-settings: name,
/// or Device Manager's console.
inline const wchar_t* AdviceTarget(AdvicePlace place) {
    switch (place) {
        case AdvicePlace::NetworkSettings: return L"ms-settings:network-status";
        case AdvicePlace::WindowsUpdate: return L"ms-settings:windowsupdate";
        case AdvicePlace::DeviceManager: return L"devmgmt.msc";
        case AdvicePlace::None: break;
    }
    return L"";
}

}  // namespace solstream
