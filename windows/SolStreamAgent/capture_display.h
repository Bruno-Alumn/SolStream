// capture_display.h — when the display SolStream captures has to be chosen
// again.
//
// The host picks it as it starts, and again when its own Set up installs the
// virtual display. Displays change at other times too: a driver update or
// Display settings restarts the virtual display, which Windows may then
// number differently, or the virtual display attaches only after a host that
// started without it settled for the primary. The choice went on naming a
// display that was gone, or the real monitor, until the host restarted --
// and with it the canvas sizing and the carrying of stranded dialogs back to
// a monitor quietly stopped working.
//
// Header-only, so the test program can check it.

#pragma once

#include <algorithm>
#include <string>
#include <vector>

namespace solstream {

/// Whether `current`, the display chosen for capture, should be chosen again,
/// given the displays `present` now and the virtual display's device name
/// (empty when it is not attached). Only when choosing again would change it,
/// so that asking every few seconds does not choose, and log, every time.
inline bool CaptureDisplayIsStale(const std::wstring& current,
                                  const std::vector<std::wstring>& present,
                                  const std::wstring& virtual_device) {
    const auto there = [&present](const std::wstring& name) {
        return std::find(present.begin(), present.end(), name) != present.end();
    };
    if (!virtual_device.empty() && virtual_device != current && there(virtual_device)) {
        return true;  // the virtual display is back, or has a new name
    }
    if (current.empty()) {
        return !present.empty();
    }
    return !there(current);
}

}  // namespace solstream
