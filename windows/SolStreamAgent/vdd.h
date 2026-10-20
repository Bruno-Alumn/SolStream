// vdd.h — the virtual display SolStream streams, and noticing when it is missing.
//
// SolStream still depends on one, and the dependency is not incidental.
//
// The client crops a rectangle out of one captured display. On a real monitor
// that rectangle is a region of somebody's actual screen: anything dragged over
// it appears inside the streamed window, the window cannot be sized past the
// monitor's own resolution, and the mode cannot be changed to match the Mac
// without changing what the person at the desk is looking at. A virtual display
// has none of those problems — it can be resized to the Mac's exact pixel count
// so every crop is 1:1 rather than resampled, nothing is ever dragged onto it by
// accident, and it exists only while it is wanted.
//
// So a machine without one can stream, but not well, and the user should be told
// before they discover it as a bad picture rather than as a missing component.

#pragma once

#include <string>
#include <vector>

namespace solstream {

struct VirtualDisplay {
    std::wstring friendly_name;  ///< e.g. "Virtual Display Driver"
    std::wstring instance_id;    ///< e.g. ROOT\DISPLAY\0001
    bool running = false;        ///< Present *and* started.
};

/// Every indirect display driver this machine has.
///
/// Identified by being root-enumerated (`ROOT\DISPLAY\...`) rather than by name.
/// A driver on the PCI bus is a graphics card; one enumerated from the root is a
/// software device, which is what an indirect display driver is. Matching on
/// names instead would mean keeping a list of every VDD anyone ships, and being
/// wrong about the ones not on it.
std::vector<VirtualDisplay> FindVirtualDisplays();

/// Is there a usable virtual display?
bool HasVirtualDisplay();

/// Is this the driver SolStream sets up — the Virtual Display Driver, under any
/// of the names it has shipped as — rather than some other product's?
///
/// Root enumeration says "a virtual display", not "ours". Other software adds
/// its own (phone-as-monitor apps, remote-desktop tools), and one of those
/// enumerating first was enough to make SolStream patch, cycle and wait on a
/// device whose mode list it does not control, conclude the driver "offers no
/// size SolStream can stream", and fall back to the real monitor.
bool IsSolStreamDisplayDriver(const std::wstring& name);

/// The driver package SolStream would install, if it ships one.
///
/// Empty when nothing is bundled — in which case the honest thing to tell the
/// user is where to get one, not to pretend a button will fix it.
std::wstring BundledDriverPackage();

/// Install the bundled driver package.
///
/// Needs administrator rights, so this re-launches `pnputil` elevated and the
/// user sees the UAC prompt: a program that installs a kernel driver without the
/// user knowing is the wrong kind of convenient. Returns false if there is
/// nothing bundled or the user declined the prompt.
bool InstallBundledDriver(std::string& error);

}  // namespace solstream
