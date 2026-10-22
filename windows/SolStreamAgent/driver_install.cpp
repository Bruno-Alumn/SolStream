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
/// project's, and it is the 64-bit (amd64) build.
constexpr char kPackageUrl[] =
    "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/"
    "25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip";
constexpr char kPackageSha256[] =
    "e24210692b442b39af763536330ce78b423f19342b7a7792c26de3944e418b3a";
/// The zip is 132 KB. Anything near a megabyte is not it.
constexpr unsigned long long kPackageCap = 1024 * 1024;

/// What the INF declares, and so what the device has to be created as.
constexpr wchar_t kHardwareId[] = L"Root\\MttVDD";

/// Where SolStream remembers what it installed, so an uninstall takes back
/// that and no more.
constexpr wchar_t kStateKey[] = L"SOFTWARE\\SolStream";
constexpr wchar_t kInfValue[] = L"DisplayDriverInf";
constexpr wchar_t kSettingsValue[] = L"DisplayDriverSettingsFolder";

/// The driver's own settings location: VDDPATH under this key when somebody
/// has set one, otherwise C:\VirtualDisplayDriver -- both read out of
/// MttVDD.dll itself, not out of its documentation.
constexpr wchar_t kDriverKey[] = L"SOFTWARE\\MikeTheTech\\VirtualDisplayDriver";

std::wstring ReadState(const wchar_t* name) {
    wchar_t value[MAX_PATH] = {0};
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, kStateKey, name,
                     RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, value, &size)
        != ERROR_SUCCESS) {
        return {};
    }
    return value;
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

void DeleteState(const wchar_t* name) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kStateKey, 0, KEY_SET_VALUE | KEY_WOW64_64KEY,
                      &key) == ERROR_SUCCESS) {
        RegDeleteValueW(key, name);
        RegCloseKey(key);
    }
}

std::wstring DriverSettingsFolder() {
    wchar_t value[MAX_PATH] = {0};
    DWORD size = sizeof(value);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, kDriverKey, L"VDDPATH",
                     RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, value, &size)
            == ERROR_SUCCESS
        && value[0] != L'\0') {
        return value;
    }
    wchar_t drive[8] = L"C:";
    GetEnvironmentVariableW(L"SystemDrive", drive, 8);
    return std::wstring(drive) + L"\\VirtualDisplayDriver";
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

/// Every display-class device with the driver's hardware ID -- present or
/// not, since a device left behind by an earlier install still counts.
template <typename Visit>
void ForEachDriverDevice(Visit visit) {
    HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, nullptr, nullptr, 0);
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
bool CreateDevice(SP_DEVINFO_DATA& created, HDEVINFO& set, std::string& error) {
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
    return true;
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

bool HasSolStreamDriver() {
    for (const VirtualDisplay& display : FindVirtualDisplays()) {
        if (display.running && IsSolStreamDisplayDriver(display.friendly_name)) {
            return true;
        }
    }
    return false;
}

bool InstalledDriverHere() {
    return !ReadState(kInfValue).empty();
}

bool InstallDisplayDriver(const std::function<void(DriverStep)>& progress,
                          bool& already, std::string& note, std::string& error) {
    already = HasSolStreamDriver();
    if (!already) {
        // The package is the amd64 build. On an ARM PC SolStream itself runs
        // under emulation, but a driver cannot, and the project's ARM64 build
        // needs test signing on current Windows -- not something to switch on
        // behind somebody's back.
        USHORT process_machine = 0, native_machine = 0;
        if (IsWow64Process2(GetCurrentProcess(), &process_machine, &native_machine)
            && native_machine == IMAGE_FILE_MACHINE_ARM64) {
            error = "SolStream can't install the virtual display on an ARM PC. Install "
                    "the Virtual Display Driver from "
                  + ToUtf8(kDriverProject) + " instead, then open SolStream again.";
            return false;
        }

        progress(DriverStep::Downloading);
        std::vector<char> package;
        std::string fetch_error;
        if (!update::FetchPinned(kPackageUrl, kPackageSha256, kPackageCap, package,
                                 fetch_error)) {
            error = "Couldn't download the virtual display driver: " + fetch_error + ".";
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
        // reviewed.
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

        // The driver reads its mode list from its settings folder when the
        // device starts, so the file is put there first. Somebody else's file
        // is kept: ConfigureVirtualDisplay below only adds to it.
        const std::wstring settings_folder = DriverSettingsFolder();
        const std::wstring settings = settings_folder + L"\\vdd_settings.xml";
        if (!Exists(settings)) {
            const bool made = CreateDirectoryW(settings_folder.c_str(), nullptr) != FALSE;
            if (CopyFileW((package_dir + L"\\vdd_settings.xml").c_str(), settings.c_str(),
                          TRUE)) {
                if (made) {
                    WriteState(kSettingsValue, settings_folder);
                }
            } else {
                note += "Couldn't write the display driver's settings to "
                      + ToUtf8(settings_folder) + ", so it starts with its own sizes.\n";
            }
        }

        progress(DriverStep::Installing);
        // Into the driver store first, which is where Windows checks the
        // signature and -- for a publisher this PC has not trusted before --
        // asks the person whether to. SetupCopyOEMInf also says what the store
        // named the package, which is what an uninstall needs to remove it.
        wchar_t oem_path[MAX_PATH] = {0};
        PWSTR oem_name = nullptr;
        if (!SetupCopyOEMInfW(inf.c_str(), nullptr, SPOST_PATH, 0, oem_path, MAX_PATH,
                              nullptr, &oem_name)) {
            error = InstallProblem("add the driver", GetLastError());
            return false;
        }
        const std::wstring staged = oem_name ? oem_name : L"";

        HDEVINFO created_set = INVALID_HANDLE_VALUE;
        SP_DEVINFO_DATA created{};
        bool device_exists = false;
        ForEachDriverDevice([&device_exists](HDEVINFO, SP_DEVINFO_DATA&) {
            device_exists = true;
        });
        if (!device_exists && !CreateDevice(created, created_set, error)) {
            return false;
        }
        BOOL reboot = FALSE;
        if (!UpdateDriverForPlugAndPlayDevicesW(nullptr, kHardwareId, inf.c_str(),
                                                INSTALLFLAG_FORCE, &reboot)) {
            const DWORD code = GetLastError();
            // A device with no driver is a yellow triangle in Device Manager
            // and nothing else; take back the one this just made.
            if (created_set != INVALID_HANDLE_VALUE) {
                SetupDiCallClassInstaller(DIF_REMOVE, created_set, &created);
                SetupDiDestroyDeviceInfoList(created_set);
            }
            error = InstallProblem("install the driver", code);
            return false;
        }
        if (created_set != INVALID_HANDLE_VALUE) {
            SetupDiDestroyDeviceInfoList(created_set);
        }
        if (!staged.empty()) {
            WriteState(kInfValue, staged);
        }
        note += "Installed the Virtual Display Driver " + std::string(kDriverVersion) + ".\n";
        if (reboot) {
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
    if (!ConfigureVirtualDisplay(kDefaultCanvasWidth, kDefaultCanvasHeight,
                                 kDefaultScalePercent, configured, configure_error)) {
        error = configure_error;
        return false;
    }
    note += configured;
    return true;
}

void RemoveInstalledDriver(std::string& note) {
    const std::wstring staged = ReadState(kInfValue);
    if (staged.empty()) {
        return;
    }
    int removed = 0;
    ForEachDriverDevice([&removed](HDEVINFO set, SP_DEVINFO_DATA& device) {
        if (SetupDiCallClassInstaller(DIF_REMOVE, set, &device)) {
            ++removed;
        }
    });
    // Only a name of the store's own form: this value came out of the registry,
    // and SetupUninstallOEMInf must never be handed some other package's INF.
    const std::wstring folded = FoldCase(staged);
    const bool oem_form = folded.rfind(L"oem", 0) == 0 && folded.size() > 7
                       && folded.compare(folded.size() - 4, 4, L".inf") == 0
                       && folded.find_first_of(L"\\/:") == std::wstring::npos;
    if (oem_form && SetupUninstallOEMInfW(staged.c_str(), SUOI_FORCEDELETE, nullptr)) {
        note += "Removed the virtual display driver SolStream installed.\n";
    } else {
        note += "Removed " + std::to_string(removed) + " virtual display device(s), but "
                "Windows kept the driver package (" + ToUtf8(staged) + ").\n";
    }
    DeleteState(kInfValue);

    // The settings folder only when SolStream made it, and only what it holds
    // of the driver's -- never a folder somebody had before.
    const std::wstring folder = ReadState(kSettingsValue);
    if (!folder.empty()) {
        for (const wchar_t* file : {L"vdd_settings.xml", L"option.txt", L"adapter.txt"}) {
            DeleteFileW((folder + L"\\" + file).c_str());
        }
        RemoveDirectoryW(folder.c_str());
        DeleteState(kSettingsValue);
    }
}

}  // namespace solstream
