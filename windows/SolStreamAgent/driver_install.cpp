#include "driver_install.h"

#include <windows.h>
#include <setupapi.h>
#include <newdev.h>
#include <cfgmgr32.h>
// As vdd.cpp does, and for the same reason: mingw's import libraries do not
// carry the class GUIDs. Selectany, so the two definitions are one.
#define INITGUID
#include <initguid.h>
#include <devguid.h>
// The device property keys too, defined here for the same reason.
#include <devpkey.h>
#include <sddl.h>
#include <shlobj.h>
#include <bcrypt.h>

#include <vector>

#include "display_setup.h"
#include "updater.h"
#include "util.h"
#include "vdd.h"

namespace solstream {
namespace {

/// The driver-only zip of kDriverVersion, as GitHub serves it. The hash is the
/// one GitHub reports for the asset, checked against a download by hand when
/// it was pinned: four files, MttVDD.inf / .dll / .cat and vdd_settings.xml,
/// the catalog signed by SignPath Foundation. The "x86" in the name is the
/// project's, and it is the 64-bit (amd64) build. Built from kDriverVersion,
/// so the release fetched and the version the screens name cannot drift apart.
const std::string kPackageUrl =
    std::string("https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/")
    + kDriverVersion + "/VirtualDisplayDriver-x86.Driver.Only.zip";
constexpr char kPackageSha256[] =
    "e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a";
/// The zip is 132 KB. Anything near a megabyte is not it.
constexpr unsigned long long kPackageCap = 1024 * 1024;

/// What the INF declares, and so what the device has to be created as.
constexpr wchar_t kHardwareId[] = L"Root\\MttVDD";

/// Where SolStream remembers what it installed, so an uninstall takes back
/// that and no more.
constexpr wchar_t kStateKey[] = L"SOFTWARE\\SolStream";
/// Each recorded only when THIS install made it: the driver store package
/// (oemNN.inf), the device instance (ROOT\DISPLAY\000N), and the settings
/// folder. Something that was already there is somebody else's.
constexpr wchar_t kInfValue[] = L"DisplayDriverInf";
constexpr wchar_t kDeviceValue[] = L"DisplayDriverDevice";
constexpr wchar_t kSettingsValue[] = L"DisplayDriverSettingsFolder";
/// When the settings folder was already there, it is somebody else's, but the
/// settings file this install wrote into it is not, nor the copy
/// display_setup.cpp keeps of that file if this install is what made it.
constexpr wchar_t kSettingsFileValue[] = L"DisplayDriverSettingsFile";
constexpr wchar_t kSettingsBackupValue[] = L"DisplayDriverSettingsBackup";

/// Where the driver project says to get it by hand, said whenever SolStream
/// cannot do it itself -- so a retry that can only fail the same way is never
/// the whole answer.
const std::string kManualInstall =
    " You can install the Virtual Display Driver yourself from "
    "github.com/VirtualDrivers/Virtual-Display-Driver, then open SolStream again.";

/// A record from `root`\`key`: kStateKey in HKLM everywhere but the tests.
std::wstring ReadStateIn(HKEY root, const wchar_t* key, const wchar_t* name) {
    wchar_t value[MAX_PATH] = {0};
    DWORD size = sizeof(value);
    if (RegGetValueW(root, key, name, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, value,
                     &size)
        != ERROR_SUCCESS) {
        return {};
    }
    return value;
}

std::wstring ReadState(const wchar_t* name) {
    return ReadStateIn(HKEY_LOCAL_MACHINE, kStateKey, name);
}

void WriteState(const wchar_t* name, const std::wstring& value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, kStateKey, 0, nullptr, 0,
                        KEY_SET_VALUE | KEY_WOW64_64KEY, nullptr, &key, nullptr)
        != ERROR_SUCCESS) {
        return;
    }
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*) value.c_str(),
                   (DWORD) ((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
}

void DeleteStateIn(HKEY root, const wchar_t* key, const wchar_t* name) {
    HKEY opened = nullptr;
    if (RegOpenKeyExW(root, key, 0, KEY_SET_VALUE | KEY_WOW64_64KEY, &opened)
        == ERROR_SUCCESS) {
        RegDeleteValueW(opened, name);
        RegCloseKey(opened);
    }
}

void DeleteState(const wchar_t* name) {
    DeleteStateIn(HKEY_LOCAL_MACHINE, kStateKey, name);
}

/// A directory only SYSTEM and administrators can write to, for the download
/// and what comes out of it.
///
/// Not %TEMP%: the elevated half runs as the person who approved the prompt,
/// whose own unelevated programs can write there -- and could swap a file in
/// between the hash being checked and pnputil reading it. A fresh, randomly
/// named folder with nobody else on its access list has no such gap.
std::wstring PrivateDirectory(std::string& error) {
    wchar_t program_data[MAX_PATH] = {0};
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_COMMON_APPDATA, nullptr, SHGFP_TYPE_CURRENT,
                                program_data))) {
        error = "could not find ProgramData";
        return {};
    }
    const std::wstring base = program_data;

    unsigned char bytes[8] = {0};
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        error = "could not pick a private folder name";
        return {};
    }
    const std::wstring path = base + L"\\SolStream-display-driver-"
                            + ToWide(ToHex(bytes, sizeof(bytes)));

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)", SDDL_REVISION_1, &descriptor,
            nullptr)) {
        error = "could not describe a private folder";
        return {};
    }
    attributes.lpSecurityDescriptor = descriptor;
    // Fails if the name is already taken, rather than using a folder somebody
    // else made with their own access list.
    const BOOL made = CreateDirectoryW(path.c_str(), &attributes);
    LocalFree(descriptor);
    if (!made) {
        error = "could not make a private folder (error "
              + std::to_string(GetLastError()) + ")";
        return {};
    }
    return path;
}

bool WriteBytes(const std::wstring& path, const std::vector<char>& bytes) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    const BOOL ok = WriteFile(file, bytes.data(), (DWORD) bytes.size(), &written, nullptr);
    CloseHandle(file);
    return ok && written == bytes.size();
}

bool Exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

/// Delete a folder this file made, and everything in it. Only ever given the
/// private directory above, whose whole contents came from the zip.
void RemoveFolder(const std::wstring& path) {
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((path + L"\\*").c_str(), &found);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            const std::wstring name = found.cFileName;
            if (name == L"." || name == L"..") {
                continue;
            }
            const std::wstring child = path + L"\\" + name;
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                RemoveFolder(child);
            } else {
                SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child.c_str());
            }
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    RemoveDirectoryW(path.c_str());
}

/// Does this device's hardware ID list name the driver's?
bool HasDriverHardwareId(HDEVINFO set, SP_DEVINFO_DATA& device) {
    wchar_t ids[1024] = {0};
    if (!SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_HARDWAREID, nullptr,
                                           (PBYTE) ids, sizeof(ids) - 2 * sizeof(wchar_t),
                                           nullptr)) {
        return false;
    }
    const std::wstring wanted = FoldCase(kHardwareId);
    for (const wchar_t* id = ids; *id; id += wcslen(id) + 1) {
        if (FoldCase(id) == wanted) {
            return true;
        }
    }
    return false;
}

/// Every PRESENT display-class device with the driver's hardware ID: working,
/// disabled or failing. A non-present one is a leftover from a device that
/// was removed, which nothing can switch on again.
template <typename Visit>
void ForEachDriverDevice(Visit visit) {
    HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
                                        DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) {
        return;
    }
    SP_DEVINFO_DATA device{};
    device.cbSize = sizeof(device);
    for (DWORD index = 0; SetupDiEnumDeviceInfo(set, index, &device); ++index) {
        if (HasDriverHardwareId(set, device)) {
            visit(set, device);
        }
    }
    SetupDiDestroyDeviceInfoList(set);
}

/// Create the root-enumerated device the driver binds to.
///
/// This is the step pnputil does not do. `pnputil /add-driver /install` puts
/// the package in the driver store and installs it on matching devices -- and
/// a software device has no bus to announce it, so there are none. The same
/// sequence devcon's `install` uses: make a device node with the hardware ID,
/// register it, and let UpdateDriverForPlugAndPlayDevices bind the driver.
bool CreateDevice(SP_DEVINFO_DATA& created, HDEVINFO& set, std::wstring& instance,
                  std::string& error) {
    set = SetupDiCreateDeviceInfoList(&GUID_DEVCLASS_DISPLAY, nullptr);
    if (set == INVALID_HANDLE_VALUE) {
        error = "could not start a device list (error " + std::to_string(GetLastError()) + ")";
        return false;
    }
    created = SP_DEVINFO_DATA{};
    created.cbSize = sizeof(created);
    if (!SetupDiCreateDeviceInfoW(set, L"Display", &GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
                                  DICD_GENERATE_ID, &created)) {
        error = "could not create the display device (error "
              + std::to_string(GetLastError()) + ")";
        SetupDiDestroyDeviceInfoList(set);
        set = INVALID_HANDLE_VALUE;
        return false;
    }
    // A REG_MULTI_SZ: the ID, its terminator, and the list's.
    std::wstring ids = kHardwareId;
    ids.push_back(L'\0');
    ids.push_back(L'\0');
    if (!SetupDiSetDeviceRegistryPropertyW(set, &created, SPDRP_HARDWAREID,
                                           (const BYTE*) ids.data(),
                                           (DWORD) (ids.size() * sizeof(wchar_t)))
        || !SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, &created)) {
        error = "could not register the display device (error "
              + std::to_string(GetLastError()) + ")";
        SetupDiDestroyDeviceInfoList(set);
        set = INVALID_HANDLE_VALUE;
        return false;
    }
    // Which device this is, so an uninstall removes it and only it.
    wchar_t id[MAX_DEVICE_ID_LEN] = {0};
    if (SetupDiGetDeviceInstanceIdW(set, &created, id, MAX_DEVICE_ID_LEN, nullptr)) {
        instance = id;
    }
    return true;
}

/// What became of a recorded device that uninstall asked to remove.
enum class DeviceRemoval {
    Removed,     ///< it was there, and now it is not
    Gone,        ///< nothing has that instance ID any more
    NotDrivers,  ///< the ID names some other device now, which stays
    Failed,      ///< it is there and the driver's, and Windows would not remove it
};

/// Remove one device by its instance ID. Nothing else with the same hardware
/// ID is touched. `code` is Windows' reason when it fails.
DeviceRemoval RemoveDevice(const std::wstring& instance, DWORD& code) {
    code = 0;
    HDEVINFO set = SetupDiCreateDeviceInfoList(&GUID_DEVCLASS_DISPLAY, nullptr);
    if (set == INVALID_HANDLE_VALUE) {
        code = GetLastError();
        return DeviceRemoval::Failed;
    }
    SP_DEVINFO_DATA device{};
    device.cbSize = sizeof(device);
    DeviceRemoval outcome = DeviceRemoval::Removed;
    if (!SetupDiOpenDeviceInfoW(set, instance.c_str(), nullptr, 0, &device)) {
        code = GetLastError();
        // Only a definite "no such device" is gone. Anything else -- access
        // denied, say -- leaves the device's fate unknown, and so a failure.
        if (code == ERROR_NO_SUCH_DEVINST || code == ERROR_INVALID_DEVINST_NAME) {
            outcome = DeviceRemoval::Gone;
        } else if (code == ERROR_CLASS_MISMATCH) {
            outcome = DeviceRemoval::NotDrivers;
        } else {
            outcome = DeviceRemoval::Failed;
        }
    } else if (!HasDriverHardwareId(set, device)) {
        outcome = DeviceRemoval::NotDrivers;
    } else if (!SetupDiCallClassInstaller(DIF_REMOVE, set, &device)) {
        // Vetoed by something holding it, or refused.
        code = GetLastError();
        outcome = DeviceRemoval::Failed;
    }
    SetupDiDestroyDeviceInfoList(set);
    return outcome;
}

/// Only a name of the driver store's own form, oemNN.inf: what is passed here
/// came out of the registry, and must never name some other package's INF.
bool IsOemInfName(const std::wstring& name) {
    const std::wstring folded = FoldCase(name);
    return folded.rfind(L"oem", 0) == 0 && folded.size() > 7
        && folded.compare(folded.size() - 4, 4, L".inf") == 0
        && folded.find_first_of(L"\\/:") == std::wstring::npos;
}

/// The present devices of the driver's that Windows installed from this store
/// package, by instance ID.
std::vector<std::wstring> DevicesUsingPackage(const std::wstring& oem_name) {
    std::vector<std::wstring> found;
    const std::wstring wanted = FoldCase(oem_name);
    ForEachDriverDevice([&](HDEVINFO set, SP_DEVINFO_DATA& device) {
        DEVPROPTYPE type = 0;
        wchar_t inf[MAX_PATH] = {0};
        wchar_t id[MAX_DEVICE_ID_LEN] = {0};
        if (SetupDiGetDevicePropertyW(set, &device, &DEVPKEY_Device_DriverInfPath, &type,
                                      (PBYTE) inf, sizeof(inf) - sizeof(wchar_t), nullptr, 0)
            && type == DEVPROP_TYPE_STRING && FoldCase(inf) == wanted
            && SetupDiGetDeviceInstanceIdW(set, &device, id, MAX_DEVICE_ID_LEN, nullptr)) {
            found.push_back(id);
        }
    });
    return found;
}

/// The settings folder, made the way an elevated writer's folder at the root of C:
/// has to be: administrators and SYSTEM write, everybody else reads --
/// including LOCAL SERVICE, which the driver's user-mode host runs as.
/// Inheriting C:\'s own access list instead gives every signed-in user
/// Modify, and these files are written and deleted with administrator rights.
bool MakeSettingsFolder(const std::wstring& path) {
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFX;;;AU)(A;OICI;FRFX;;;LS)",
            SDDL_REVISION_1, &descriptor, nullptr)) {
        return false;
    }
    attributes.lpSecurityDescriptor = descriptor;
    const BOOL made = CreateDirectoryW(path.c_str(), &attributes);
    LocalFree(descriptor);
    return made != FALSE;
}

std::string InstallProblem(const char* what, DWORD code) {
    switch (code) {
        case ERROR_CANCELLED:
        case ERROR_AUTHENTICODE_TRUST_NOT_ESTABLISHED:
        case ERROR_AUTHENTICODE_PUBLISHER_NOT_TRUSTED:
            return "Windows asked whether to install the driver and the answer was no, so "
                   "nothing was installed.";
        case ERROR_INVALID_IMAGE_HASH:
        case (DWORD) TRUST_E_NOSIGNATURE:
            return "Windows would not accept the driver's signature, so nothing was "
                   "installed.";
        default:
            return std::string("Windows could not ") + what + " (error "
                 + std::to_string(code) + ").";
    }
}

}  // namespace

DriverState CurrentDriverState() {
    bool found = false;
    // A device Windows starts at the next restart is not off: it is an install
    // that is not finished yet. Called off, it was sent to Device Manager for
    // an Enable that isn't there.
    bool restart = false;
    for (const VirtualDisplay& display : FindVirtualDisplays()) {
        if (IsSolStreamDisplayDriver(display.friendly_name)) {
            if (display.running) {
                return DriverState::Ready;
            }
            found = true;
            restart = restart || display.restart_pending;
        }
    }
    ForEachDriverDevice([&found, &restart](HDEVINFO, SP_DEVINFO_DATA& device) {
        found = true;
        ULONG status = 0, problem = 0;
        if (CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == CR_SUCCESS
            && WaitsForRestart(status, problem)) {
            restart = true;
        }
    });
    if (!found) {
        return DriverState::Missing;
    }
    return restart ? DriverState::RestartPending : DriverState::Off;
}

bool HasSolStreamDriver() {
    return CurrentDriverState() == DriverState::Ready;
}

bool CanInstallDisplayDriver() {
    // The package is the amd64 build. On an ARM PC SolStream itself runs
    // under emulation, but a driver cannot, and the project's ARM64 build
    // needs test signing on current Windows -- not something to switch on
    // behind somebody's back.
    USHORT process_machine = 0, native_machine = 0;
    return !(IsWow64Process2(GetCurrentProcess(), &process_machine, &native_machine)
             && native_machine == IMAGE_FILE_MACHINE_ARM64);
}

std::string ManualInstallAdvice() {
    return kManualInstall.substr(1);
}

bool InstalledDriverHere() {
    return !ReadState(kInfValue).empty() || !ReadState(kDeviceValue).empty();
}

bool InstallDisplayDriver(const std::function<void(DriverStep)>& progress, HWND owner,
                          bool& already, bool& restart, std::string& note,
                          std::string& error) {
    restart = false;
    const DriverState state = CurrentDriverState();
    already = state == DriverState::Ready;
    // The settings file's backup, when this run wrote the file into a folder
    // that was already there and no backup of it was there yet.
    std::wstring new_backup;
    if (state == DriverState::Off) {
        // Somebody's own driver, switched off or failing. Theirs: installing
        // over it would bind a different version to their device, and an
        // uninstall would later take it. Saying where the switch is costs
        // them one click and takes nothing. Not "then choose Set up again":
        // once it is on there is a virtual display, and no Set up is offered.
        error = "This PC already has the Virtual Display Driver, but it's turned off or "
                "not working, so SolStream left it alone. Turn it on in Device Manager "
                "(Display adapters, Virtual Display Driver, Enable device) to stream to "
                "it.";
        return false;
    }
    if (state == DriverState::RestartPending) {
        // Installed already, by an earlier Set up or by hand, and Windows
        // starts it at the restart. Nothing here can hurry that, and the host
        // sets the display up when it starts after the restart.
        restart = true;
        note += "Windows hasn't finished installing the Virtual Display Driver yet. Restart "
                "this PC to finish setting up the virtual display.";
        return true;
    }
    if (state == DriverState::Missing) {
        if (!CanInstallDisplayDriver()) {
            error = "SolStream can't install the virtual display on an ARM PC." + kManualInstall;
            return false;
        }

        progress(DriverStep::Downloading);
        std::vector<char> package;
        std::string fetch_error;
        if (!update::FetchPinned(kPackageUrl, kPackageSha256, kPackageCap, package,
                                 fetch_error)) {
            // Network trouble or the release gone: either way a pointer to the
            // project itself, which is the way round both.
            error = "Couldn't download the virtual display driver: " + fetch_error + "."
                  + kManualInstall;
            return false;
        }

        std::string folder_error;
        const std::wstring work = PrivateDirectory(folder_error);
        if (work.empty()) {
            error = "Couldn't unpack the virtual display driver: " + folder_error + ".";
            return false;
        }
        struct Cleanup {
            std::wstring path;
            ~Cleanup() { RemoveFolder(path); }
        } cleanup{work};

        const std::wstring zip = work + L"\\driver.zip";
        if (!WriteBytes(zip, package)) {
            error = "Couldn't save the virtual display driver it downloaded.";
            return false;
        }
        // tar has been in System32 since Windows 10 1803 and reads zip. The
        // archive's hash was checked above, so what it unpacks is what was
        // reviewed; RunHidden runs System32's tar by full path.
        const DWORD unpacked =
            RunHidden(L"tar.exe -xf \"" + zip + L"\" -C \"" + work + L"\"", 60000);
        const std::wstring package_dir = work + L"\\VirtualDisplayDriver";
        const std::wstring inf = package_dir + L"\\MttVDD.inf";
        if (unpacked != 0 || !Exists(inf) || !Exists(package_dir + L"\\MttVDD.dll")
            || !Exists(package_dir + L"\\mttvdd.cat")) {
            error = "Couldn't unpack the virtual display driver (tar " + RunOutcome(unpacked)
                  + ").";
            return false;
        }

        // Everything this run makes, so a failure further down takes it back.
        // The settings file on its own as well as the folder: a folder that
        // was already there is somebody else's, but a file this run wrote into
        // it is not, and left behind it would be nobody's.
        bool made_folder = false;
        bool wrote_settings = false;
        std::wstring staged;
        bool staged_here = false;
        const std::wstring settings_folder = VddSettingsFolder();
        const std::wstring settings = settings_folder + L"\\vdd_settings.xml";
        auto undo = [&] {
            if (staged_here && IsOemInfName(staged)) {
                SetupUninstallOEMInfW(staged.c_str(), 0, nullptr);
            }
            if (made_folder) {
                RemoveDriverSettingsFolder(settings_folder);
            } else if (wrote_settings) {
                RemoveDriverSettingsFile(settings);
            }
        };

        // The driver reads its mode list from its settings folder when the
        // device starts, so the file is put there first. Somebody else's file
        // is kept: ConfigureVirtualDisplay below only adds to it. Never through
        // a junction or link: this runs elevated, and C:\ lets anybody make a
        // folder of that name first.
        if (IsReparsePoint(settings_folder) || IsReparsePoint(settings)) {
            note += "The display driver's settings folder is a link to somewhere else, so "
                    "SolStream did not write to it.\n";
        } else if (!Exists(settings)) {
            made_folder = !Exists(settings_folder) && MakeSettingsFolder(settings_folder);
            wrote_settings = CopyFileW((package_dir + L"\\vdd_settings.xml").c_str(),
                                       settings.c_str(), TRUE) != FALSE;
            if (!wrote_settings) {
                note += "Couldn't write the display driver's settings to "
                      + ToUtf8(settings_folder) + ", so it starts with its own sizes.\n";
            }
        }

        progress(DriverStep::Installing);
        // Into the driver store first, which is where Windows checks the
        // signature and -- for a publisher this PC has not trusted before --
        // asks the person whether to. NOOVERWRITE, so a package that is
        // already in the store answers ERROR_FILE_EXISTS rather than quietly
        // handing back its name: that one is somebody else's, and an uninstall
        // must never delete it.
        wchar_t oem_path[MAX_PATH] = {0};
        PWSTR oem_name = nullptr;
        if (SetupCopyOEMInfW(inf.c_str(), nullptr, SPOST_PATH, SP_COPY_NOOVERWRITE, oem_path,
                             MAX_PATH, nullptr, &oem_name)) {
            staged_here = true;
        } else if (GetLastError() != ERROR_FILE_EXISTS) {
            const DWORD code = GetLastError();
            undo();
            error = InstallProblem("add the driver", code);
            return false;
        }
        staged = oem_name ? oem_name : L"";
        // Past the one call that can ask. What follows -- making the device,
        // binding the driver, waiting for the display -- never does, and a
        // slow one must not send somebody looking for a prompt that isn't there.
        progress(DriverStep::Starting);

        // No device of the driver's is present (CurrentDriverState said so),
        // so this one is new and SolStream's.
        HDEVINFO created_set = INVALID_HANDLE_VALUE;
        SP_DEVINFO_DATA created{};
        std::wstring instance;
        if (!CreateDevice(created, created_set, instance, error)) {
            undo();
            return false;
        }
        // The owner is the window waiting on this, so whatever Windows asks
        // about the driver comes up over it rather than behind it.
        BOOL reboot = FALSE;
        if (!UpdateDriverForPlugAndPlayDevicesW(owner, kHardwareId, inf.c_str(), 0, &reboot)) {
            const DWORD code = GetLastError();
            // A device with no driver is a yellow triangle in Device Manager
            // and nothing else; take back the one this just made.
            SetupDiCallClassInstaller(DIF_REMOVE, created_set, &created);
            SetupDiDestroyDeviceInfoList(created_set);
            undo();
            error = InstallProblem("install the driver", code);
            return false;
        }
        SetupDiDestroyDeviceInfoList(created_set);
        if (!instance.empty()) {
            WriteState(kDeviceValue, instance);
        }
        if (staged_here && !staged.empty()) {
            WriteState(kInfValue, staged);
        }
        if (made_folder) {
            WriteState(kSettingsValue, settings_folder);
        } else if (wrote_settings) {
            WriteState(kSettingsFileValue, settings);
            // ConfigureVirtualDisplay keeps a copy of the file before it first
            // changes it. One made below is a copy of this run's file; one that
            // is already there came from something earlier, and stays.
            const std::wstring backup = settings + kVddSettingsBackupSuffix;
            if (!Exists(backup)) {
                new_backup = backup;
            }
        }
        note += "Installed the Virtual Display Driver " + std::string(kDriverVersion) + ".\n";
        if (reboot) {
            restart = true;
            note += "Windows wants a restart to finish installing it.\n";
        }

        // The device comes up a moment after the driver is bound.
        for (int attempt = 0; attempt < 20 && !HasVirtualDisplay(); ++attempt) {
            Sleep(500);
        }
    }

    progress(DriverStep::Configuring);
    std::string configured;
    std::string configure_error;
    const bool configured_ok = ConfigureVirtualDisplay(
        kDefaultCanvasWidth, kDefaultCanvasHeight, kDefaultScalePercent, configured,
        configure_error);
    if (!new_backup.empty() && Exists(new_backup)) {
        WriteState(kSettingsBackupValue, new_backup);
    }
    if (!configured_ok) {
        if (restart) {
            // Windows finishes the install at the restart, and until then the
            // device may not start at all, so there is no display yet to set
            // up. That is not a failure: the modes went into the settings file
            // just now, which needs no display, and the host does the rest
            // when it starts after the restart. Reported as one, the install was
            // called failed, and a Set up offered that would only find the
            // device not started and call it somebody's switched-off driver.
            note += configured;
            if (!configured.empty()) {
                note += "\n";
            }
            note += "SolStream finishes setting the virtual display up when it starts after "
                    "the restart.";
            return true;
        }
        error = configure_error;
        return false;
    }
    note += configured;
    return true;
}

void RemoveInstalledDriver(std::string& note) {
    std::wstring instance = ReadState(kDeviceValue);
    const std::wstring staged = ReadState(kInfValue);

    // A PC set up by an earlier build has the package recorded and not the
    // device: that build took every device of the driver's away instead. Its
    // device is the one Windows installed from that package -- when exactly
    // one is. With two or more, which is SolStream's would be a guess, so the
    // devices, the package they use, their settings and the record all stay.
    if (instance.empty() && IsOemInfName(staged)) {
        const std::vector<std::wstring> using_package = DevicesUsingPackage(staged);
        if (using_package.size() > 1) {
            note += std::to_string(using_package.size())
                  + " virtual displays use the driver package an earlier SolStream "
                    "installed (" + ToUtf8(staged) + "), and it didn't record which one "
                    "it added, so SolStream left them, the package and their settings as "
                    "they are.\n";
            return;
        }
        if (using_package.size() == 1) {
            instance = using_package.front();
        }
    }

    // The device first, and only the one SolStream created: a device of the
    // same driver somebody added themselves stays.
    if (!instance.empty()) {
        DWORD code = 0;
        switch (RemoveDevice(instance, code)) {
            case DeviceRemoval::Removed:
                note += "Removed the virtual display SolStream added.\n";
                break;
            case DeviceRemoval::Gone:
            case DeviceRemoval::NotDrivers:
                note += "The virtual display SolStream added was already gone.\n";
                break;
            case DeviceRemoval::Failed:
                // Still here, and still SolStream's. Its records stay, so a
                // later uninstall knows it; so do the package it runs on and
                // the settings it reads, which deleted from under it would
                // leave a device nothing claims, with its driver half gone.
                note += "Windows wouldn't remove the virtual display SolStream added (error "
                      + std::to_string(code) + "), so SolStream left it, its driver and its "
                        "settings in place, still recorded as SolStream's.\n";
                return;
        }
        DeleteState(kDeviceValue);
    }
    // Then the package, and only one this install put in the store. No force:
    // if some other device is using it, it stays.
    if (!staged.empty()) {
        if (IsOemInfName(staged) && SetupUninstallOEMInfW(staged.c_str(), 0, nullptr)) {
            note += "Removed the virtual display driver SolStream installed.\n";
        } else {
            note += "Windows kept the virtual display driver package (" + ToUtf8(staged)
                  + "), which something else may be using.\n";
        }
        DeleteState(kInfValue);
    }

    RemoveRecordedDriverSettings(HKEY_LOCAL_MACHINE, kStateKey, note);
}

void RemoveRecordedDriverSettings(HKEY root, const wchar_t* key, std::string& note) {
    // The settings folder only when SolStream made it, only what it holds of
    // the driver's and SolStream's, and never through a link. Its record goes
    // only with the folder: let go while the folder stays, nothing would say
    // again that the folder was SolStream's.
    const std::wstring folder = ReadStateIn(root, key, kSettingsValue);
    if (!folder.empty()) {
        if (RemoveDriverSettingsFolder(folder)) {
            DeleteStateIn(root, key, kSettingsValue);
        } else {
            note += "Left the display driver's settings folder, " + ToUtf8(folder)
                  + ", because it is a link or holds files SolStream didn't put there.\n";
        }
    }
    // The settings file written into somebody else's folder, and the copy of
    // it, on the same terms.
    for (const wchar_t* value : {kSettingsFileValue, kSettingsBackupValue}) {
        const std::wstring path = ReadStateIn(root, key, value);
        if (path.empty()) {
            continue;
        }
        if (RemoveDriverSettingsFile(path)) {
            DeleteStateIn(root, key, value);
        } else {
            note += "Left " + ToUtf8(path) + ": it is a link, isn't the display driver's "
                    "settings, or couldn't be deleted.\n";
        }
    }
}

bool RemoveDriverSettingsFolder(const std::wstring& folder) {
    if (!Exists(folder)) {
        return true;
    }
    if (IsReparsePoint(folder)) {
        return false;
    }
    // The backup is display_setup.cpp's copy of the file from before it first
    // changed it. In a folder SolStream made, that file was SolStream's too.
    const std::wstring settings = L"vdd_settings.xml";
    for (const std::wstring& file : {settings, settings + kVddSettingsBackupSuffix,
                                     std::wstring(L"option.txt"), std::wstring(L"adapter.txt")}) {
        const std::wstring path = folder + L"\\" + file;
        if (!IsReparsePoint(path)) {
            DeleteFileW(path.c_str());
        }
    }
    RemoveDirectoryW(folder.c_str());
    return !Exists(folder);
}

bool RemoveDriverSettingsFile(const std::wstring& path) {
    // Only the settings file or its backup, by name: the path came out of the
    // registry, as IsOemInfName's does, and must never name anything else.
    const size_t slash = path.find_last_of(L'\\');
    const std::wstring name = FoldCase(slash == std::wstring::npos ? path
                                                                    : path.substr(slash + 1));
    if (name != L"vdd_settings.xml"
        && name != L"vdd_settings.xml" + FoldCase(kVddSettingsBackupSuffix)) {
        return false;
    }
    if ((slash != std::wstring::npos && IsReparsePoint(path.substr(0, slash)))
        || IsReparsePoint(path)) {
        return false;
    }
    DeleteFileW(path.c_str());
    return !Exists(path);
}

}  // namespace solstream
