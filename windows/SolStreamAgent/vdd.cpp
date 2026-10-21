#include "vdd.h"

#include <windows.h>
#include <setupapi.h>
// INITGUID before devguid.h defines the class GUIDs in this object file rather
// than referencing them from a library. mingw's import libraries do not carry
// them, so without this the link fails on GUID_DEVCLASS_DISPLAY — and the agent
// is cross-compiled from a Mac, so "works with MSVC" is not enough.
#define INITGUID
#include <initguid.h>
#include <devguid.h>
#include <cfgmgr32.h>
#include <shellapi.h>

#include <algorithm>
#include <cstdio>
#include <cwctype>
#include <mutex>

#include "util.h"

namespace solstream {
namespace {

std::wstring ExecutableDir() {
    wchar_t path[MAX_PATH] = {};
    if (!GetModuleFileNameW(nullptr, path, MAX_PATH)) {
        return {};
    }
    std::wstring full(path);
    const size_t slash = full.find_last_of(L'\\');
    return slash == std::wstring::npos ? std::wstring{} : full.substr(0, slash);
}

}  // namespace

std::vector<VirtualDisplay> FindVirtualDisplays() {
    std::vector<VirtualDisplay> found;

    HDEVINFO set = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, nullptr, nullptr,
                                        DIGCF_PRESENT);
    if (set == INVALID_HANDLE_VALUE) {
        return found;
    }

    SP_DEVINFO_DATA device{};
    device.cbSize = sizeof(device);
    for (DWORD index = 0; SetupDiEnumDeviceInfo(set, index, &device); ++index) {
        wchar_t instance[MAX_DEVICE_ID_LEN] = {};
        if (!SetupDiGetDeviceInstanceIdW(set, &device, instance,
                                         MAX_DEVICE_ID_LEN, nullptr)) {
            continue;
        }
        // Root-enumerated means a software device rather than a card on a bus,
        // which is exactly what an indirect display driver is.
        if (FoldCase(instance).rfind(L"root\\display", 0) != 0) {
            continue;
        }

        VirtualDisplay display;
        display.instance_id = instance;

        wchar_t name[512] = {};
        if (SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_FRIENDLYNAME, nullptr,
                                              (PBYTE) name, sizeof(name), nullptr)
            || SetupDiGetDeviceRegistryPropertyW(set, &device, SPDRP_DEVICEDESC, nullptr,
                                                 (PBYTE) name, sizeof(name), nullptr)) {
            display.friendly_name = name;
        }

        // Present is not the same as working: a driver that failed to start, or
        // one the user disabled, still enumerates. Reporting it as available
        // would send the client to a display that never produces a frame.
        ULONG status = 0, problem = 0;
        if (CM_Get_DevNode_Status(&status, &problem, device.DevInst, 0) == CR_SUCCESS) {
            display.running = (status & DN_STARTED) != 0 && problem == 0;
        }
        found.push_back(display);
    }
    SetupDiDestroyDeviceInfoList(set);
    return found;
}

bool IsSolStreamDisplayDriver(const std::wstring& name) {
    const std::wstring folded = FoldCase(name);
    if (folded.find(L"virtual display driver") != std::wstring::npos
        || folded.find(L"iddsample") != std::wstring::npos
        || folded.find(L"solstream") != std::wstring::npos) {
        return true;
    }
    // MikeTheTech's vendor token -- "VDD by MTT", "MttVDD" -- as a word of its
    // own, never three letters inside some other product's name.
    size_t start = 0;
    while (start < folded.size()) {
        while (start < folded.size() && !std::iswalnum(folded[start])) {
            ++start;
        }
        size_t end = start;
        while (end < folded.size() && std::iswalnum(folded[end])) {
            ++end;
        }
        const std::wstring word = folded.substr(start, end - start);
        if (word == L"mtt" || word.rfind(L"mttvdd", 0) == 0) {
            return true;
        }
        start = end;
    }
    return false;
}

bool HasVirtualDisplay() {
    // When SolStream's own driver is installed, only it counts. Another
    // product's display running beside a stopped one of ours is not a display
    // SolStream will capture, and answering yes for it told the window and the
    // Mac that a virtual display was ready when it was not. Without ours, any
    // running one still counts, as it always did.
    const auto displays = FindVirtualDisplays();
    const bool ours_present = std::any_of(
        displays.begin(), displays.end(), [](const VirtualDisplay& display) {
            return IsSolStreamDisplayDriver(display.friendly_name);
        });
    for (const VirtualDisplay& display : displays) {
        if (ours_present && !IsSolStreamDisplayDriver(display.friendly_name)) {
            continue;
        }
        if (display.running) {
            return true;
        }
    }
    return false;
}

bool HasVirtualDisplayCached() {
    // A SetupDi scan takes the PnP lock and costs milliseconds, and the window,
    // the `status` command and the busy refusal all ask -- the first of them
    // once a second, forever, and the second before anybody has authenticated.
    // Display drivers come and go on the scale of minutes, so ten seconds stale
    // is fresh enough for every one of them.
    static std::mutex guard;
    static bool known = false;
    static bool answer = false;
    static ULONGLONG checked_at = 0;
    std::lock_guard<std::mutex> held(guard);
    const ULONGLONG now = GetTickCount64();
    if (!known || now - checked_at >= 10000) {
        answer = HasVirtualDisplay();
        checked_at = now;
        known = true;
    }
    return answer;
}

std::wstring BundledDriverPackage() {
    const std::wstring here = ExecutableDir();
    if (here.empty()) {
        return {};
    }
    const std::wstring inf = here + L"\\driver\\SolStreamDisplay.inf";
    const DWORD attributes = GetFileAttributesW(inf.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        return {};
    }
    return inf;
}

bool InstallBundledDriver(std::string& error) {
    const std::wstring inf = BundledDriverPackage();
    if (inf.empty()) {
        // Say what is missing, where it goes, and what happens without it.
        // "No driver bundled" on its own tells the user nothing they can act
        // on, and this is the one message they will see at exactly the moment
        // they cannot stream properly.
        error = "This build of SolStream has no display driver bundled with it.\r\n\r\n"
                "SolStream streams a virtual display so the window can be any size, "
                "can be matched to your Mac's resolution exactly, and can never show "
                "what is on your real monitor. Without one it captures a real screen "
                "instead, and all three of those stop being true.\r\n\r\n"
                "Install any indirect display driver - the Virtual Display Driver "
                "from github.com/itsmikethetech/Virtual-Display-Driver is the one "
                "SolStream is tested against - then start SolStream again.\r\n\r\n"
                "To have SolStream install it for you, put the driver package in a "
                "'driver' folder beside SolStream.exe, named SolStreamDisplay.inf.";
        return false;
    }

    // Elevated, and visibly so. pnputil installs a kernel-mode driver package;
    // doing that behind a UAC prompt the user never sees is not something this
    // program should be able to do.
    std::wstring arguments = L"/add-driver \"" + inf + L"\" /install";
    SHELLEXECUTEINFOW execute{};
    execute.cbSize = sizeof(execute);
    execute.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute.lpVerb = L"runas";
    // System32, not a bare name. ShellExecuteEx searches the same way
    // CreateProcess does, starting with the directory this process was started
    // from -- and this call is the one that asks for administrator rights and
    // then installs a kernel-mode driver package. A `pnputil.exe` dropped
    // beside the setup program would be run instead, elevated, at the prompt
    // the user has just approved.
    wchar_t system_dir[MAX_PATH] = {0};
    std::wstring pnputil = L"pnputil.exe";
    if (GetSystemDirectoryW(system_dir, MAX_PATH) != 0) {
        pnputil = std::wstring(system_dir) + L"\\pnputil.exe";
    }
    execute.lpFile = pnputil.c_str();
    execute.lpParameters = arguments.c_str();
    execute.nShow = SW_HIDE;
    if (!ShellExecuteExW(&execute)) {
        const DWORD code = GetLastError();
        error = code == ERROR_CANCELLED
            ? "Installing the display driver needs administrator approval."
            : "Could not start the driver installer.";
        return false;
    }

    DWORD exit_code = 1;
    if (execute.hProcess) {
        WaitForSingleObject(execute.hProcess, 120000);
        GetExitCodeProcess(execute.hProcess, &exit_code);
        CloseHandle(execute.hProcess);
    }
    if (exit_code != 0) {
        char buffer[128];
        std::snprintf(buffer, sizeof(buffer),
                      "The display driver installer failed (code %lu).", exit_code);
        error = buffer;
        return false;
    }
    return true;
}

}  // namespace solstream
