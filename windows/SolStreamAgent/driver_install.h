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

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

namespace solstream {

/// The Virtual Display Driver release SolStream installs. MIT licensed, signed
/// by SignPath Foundation, and user-mode (UMDF): it cannot bugcheck a PC.
/// Changing it means checking the new zip's contents and hash by hand, and
/// putting that hash in kPackageSha256 (driver_install.cpp); the download's
/// URL is built from this.
constexpr char kDriverVersion[] = "25.7.23";
constexpr wchar_t kDriverProject[] = L"github.com/VirtualDrivers/Virtual-Display-Driver";

/// Registered window message the elevated half posts to the window waiting on
/// it (`--progress-window`), with a DriverStep in wParam.
constexpr wchar_t kSetupProgressMessage[] = L"SolStream.SetupProgress";

/// Where an install has got to, for the window that is waiting on it.
enum class DriverStep {
    Downloading = 1,
    Installing,   ///< Windows may ask whether to trust the publisher now
    Starting,     ///< past that question: the device is made and its driver bound
    Configuring,  ///< the screen may blink
    Done,         ///< the display's part is over; SolStream's own install follows
};

/// `count` random bytes as lowercase hex, or empty if the RNG refuses. Here
/// rather than in util.h only because installer.cpp needs it too.
std::string RandomHex(size_t count);

/// Where SolStream's driver stands on this PC.
enum class DriverState {
    Missing,         ///< no device of it at all: setup may install one
    Ready,           ///< present and running
    RestartPending,  ///< installed, and Windows starts it once the PC restarts
    Off,             ///< present and switched off in Device Manager -- left alone
    Failing,         ///< present and switched on, and it didn't start -- left alone
};
DriverState CurrentDriverState();

/// False on an ARM PC: the driver SolStream fetches is the amd64 build.
bool CanInstallDisplayDriver();

/// Where to get the driver by hand, as one sentence, for whenever SolStream
/// can't install it itself.
std::string ManualInstallAdvice();

/// Fetch, check and install the driver, create its device, and set the display
/// up for streaming. Needs administrator rights and the interactive session.
///
/// Only on a PC with no device of the driver's at all: a device that is there
/// but switched off is somebody's own, and this says so rather than install
/// over it. One that waits for a restart is installed already, and this says
/// to restart (`restart`) and changes nothing. What it does install it records
/// -- the store package only if this call added it, the device it created, the
/// settings folder if it made it, or else the settings file if it wrote one
/// into a folder that was already there -- and on failure it takes those back.
///
/// `owner` is the window waiting on this, for Windows' own prompts to come up
/// over. True when a virtual display is ready at the end, including when one
/// already was (`already`), and when Windows wants a restart to finish
/// (`restart`): the display may not start until then, and SolStream sets it up
/// when it starts after the restart. `note` collects what was done; `error`
/// says why not, in words a person can act on.
bool InstallDisplayDriver(const std::function<void(DriverStep)>& progress, HWND owner,
                          bool& already, bool& restart, std::string& note,
                          std::string& error);

/// Whether InstallDisplayDriver installed anything on this PC, and so whether
/// uninstalling SolStream has anything of the driver's to take away.
bool InstalledDriverHere();

/// Undo InstallDisplayDriver: the device it created, the package it added and
/// the settings folder it made or the settings file it wrote -- each only if
/// recorded, and nothing else with the same driver. The device only while it
/// is the one SolStream made, by the mark it gave it, not just by its
/// instance ID, which Windows hands to the next device once this one is gone.
/// A device Windows won't remove stays recorded, and its package and settings
/// stay with it; so do those of one Windows removes only when the PC restarts,
/// which uses them until then. A settings record is let go only once what it
/// names is gone. Needs administrator rights. What was done goes to `note`, a
/// line each. True when nothing it installed is left, or it installed nothing;
/// false when something stays on the PC, which `note` then says.
bool RemoveInstalledDriver(std::string& note);

/// What became of a recorded device that uninstall asked to remove.
enum class DeviceRemoval {
    Removed,           ///< it was there, and now it is not
    RemovedAtRestart,  ///< Windows removes it when the PC restarts, and until then it is there
    Gone,              ///< nothing has that instance ID any more
    NotDrivers,        ///< the ID names some other device now, which stays
    Failed,            ///< it is there and the driver's, and Windows would not remove it
};

/// What Windows answered, step by step, about a recorded device and when
/// asked to remove it: did SetupDiOpenDeviceInfoW find its instance ID
/// (`opened`), and if not, why not (`open_error`); is what it found the
/// driver's (`drivers`); the mark recorded beside the ID (`recorded_mark`,
/// empty in a record from before marks) and the one the device carries
/// (`device_mark`, empty when it has none), or whether Windows wouldn't say
/// (`device_mark_unknown`); did DIF_REMOVE go through (`removed`); and the
/// device's install flags after it (`install_flags`), which say when the
/// removal waits for a restart.
struct RemovalAnswers {
    bool opened = false;
    DWORD open_error = 0;
    bool drivers = false;
    std::wstring recorded_mark = {};
    std::wstring device_mark = {};
    bool device_mark_unknown = false;
    bool removed = false;
    DWORD install_flags = 0;
};

/// Whose the device at a recorded instance ID is now.
enum class RecordedDevice {
    Ours,       ///< the driver's, with the mark SolStream recorded (or a record from before marks)
    Gone,       ///< nothing has that instance ID any more
    Somebodys,  ///< another device has the ID now: not the driver's, or not marked as recorded
    Unknown,    ///< Windows wouldn't say, so it may still be SolStream's
};

/// What the first answers -- before any removal -- say of the recorded
/// device. Only one that is Ours is ever removed. Exposed for its tests.
RecordedDevice JudgeRecordedDevice(const RemovalAnswers& answers);

/// What all the answers come to. Exposed for its tests.
DeviceRemoval ClassifyRemoval(const RemovalAnswers& answers);

/// The steps RemoveRecordedDriver asks of Windows, as parameters so the tests
/// can stand in for them.
struct DriverRemovalSteps {
    /// Remove the device at this instance ID if it carries this mark (or the
    /// record has none), as RemoveDevice does. `code` is Windows' reason when
    /// it would not.
    std::function<DeviceRemoval(const std::wstring& device, const std::wstring& mark,
                                DWORD& code)>
        remove;
    /// Take this oemNN.inf out of the driver store, unless a device uses it.
    std::function<bool(const std::wstring& package)> uninstall;
    /// The present devices Windows installed from this package, by instance ID.
    std::function<std::vector<std::wstring>(const std::wstring& package)> devices_using;
    /// Whether a device of the driver's other than this instance ID (none when
    /// empty) is present: one that reads the settings folder too.
    std::function<bool(const std::wstring& except)> other_device_present;
};

/// RemoveInstalledDriver on the records in `root`\`key`, with `steps`
/// standing in for Windows. What became of the device decides the rest: one
/// that is still there -- refused, or removed only at the restart -- keeps
/// its package, its settings, and their records, and its own record too. One
/// removed at the restart frees its instance ID for the next device, so an
/// unmarked record of it keeps only that there was one; a marked one keeps the
/// ID, since the next device there has no mark. The settings go only
/// when no other device of the driver's is there to read them. True when
/// nothing recorded is left. Exposed for its tests.
bool RemoveRecordedDriver(HKEY root, const wchar_t* key, const DriverRemovalSteps& steps,
                          std::string& note);

/// The settings part of that: the folder SolStream made, or the settings file
/// it wrote into somebody else's and its backup, each record let go only once
/// what it names is gone, and true when every one was. The records are read
/// from and let go in `root`\`key`: HKLM\SOFTWARE\SolStream for
/// RemoveInstalledDriver, and a key of their own for the tests, which are why
/// it is exposed.
bool RemoveRecordedDriverSettings(HKEY root, const wchar_t* key, std::string& note);

/// The settings folder's part of that, for a folder SolStream made: the files
/// the driver and SolStream keep in it, then the folder itself -- never
/// through a link. True when the folder is gone, false when it is a link or
/// holds something else. Exposed for its tests.
bool RemoveDriverSettingsFolder(const std::wstring& folder);

/// One file SolStream wrote into a settings folder that is not its own, never
/// through a link. True when the file is gone. Exposed for its tests.
bool RemoveDriverSettingsFile(const std::wstring& path);

}  // namespace solstream
