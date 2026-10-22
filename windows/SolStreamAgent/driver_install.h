// driver_install.h — putting the virtual display on a PC that has none.
//
// SolStream streams a virtual display (vdd.h says why it still depends on
// one), and until this file the only way to get one was to find the Virtual
// Display Driver's GitHub page, pick the right zip, unpack it, run its own
// installer and then come back. The "Install driver" button looked for a
// package nothing ever shipped, and pnputil on its own stages a driver
// without ever creating the device it drives.
//
// So SolStream fetches the driver itself, one fixed release whose SHA-256 is
// compiled in below, and does what pnputil leaves out. Nothing about it is
// hidden: the setup screen asks first, Windows' administrator prompt and its
// own "install this device software?" prompt both appear, and uninstalling
// SolStream takes back exactly what this put here and nothing it found.

#pragma once

#include <functional>
#include <string>

namespace solstream {

/// The Virtual Display Driver release SolStream installs. MIT licensed, signed
/// by SignPath Foundation, and user-mode (UMDF): it cannot bugcheck a PC.
/// Changing it means checking the new zip's contents and hash by hand.
constexpr char kDriverVersion[] = "25.7.23";
constexpr wchar_t kDriverProject[] = L"github.com/VirtualDrivers/Virtual-Display-Driver";

/// Registered window message the elevated half posts to the window waiting on
/// it (`--progress-window`), with a DriverStep in wParam.
constexpr wchar_t kSetupProgressMessage[] = L"SolStream.SetupProgress";

/// Where an install has got to, for the window that is waiting on it.
enum class DriverStep {
    Downloading = 1,
    Installing,   ///< Windows may ask whether to trust the publisher now
    Configuring,  ///< the screen may blink
    Done,         ///< the display's part is over; SolStream's own install follows
};

/// Is the Virtual Display Driver -- SolStream's, not another product's virtual
/// display -- on this PC and running? A device left behind with no working
/// driver does not count: that is a PC setup should still offer to fix.
bool HasSolStreamDriver();

/// Fetch, check and install the driver, create its device, and set the display
/// up for streaming. Needs administrator rights and the interactive session.
///
/// True when a virtual display is ready at the end, including when the driver
/// was already here (`already` is then true and nothing was downloaded).
/// `note` collects what was done and anything worth knowing; `error` says why
/// not, in words a person can act on.
bool InstallDisplayDriver(const std::function<void(DriverStep)>& progress,
                          bool& already, std::string& note, std::string& error);

/// Whether InstallDisplayDriver installed the driver on this PC, and so whether
/// uninstalling SolStream should take it away again. A driver somebody
/// installed for themselves is theirs, and is left alone.
bool InstalledDriverHere();

/// Undo InstallDisplayDriver: remove the device, the driver package, and the
/// settings folder if SolStream created it. Needs administrator rights.
/// Best effort; what could not be done goes to `note`.
void RemoveInstalledDriver(std::string& note);

}  // namespace solstream
