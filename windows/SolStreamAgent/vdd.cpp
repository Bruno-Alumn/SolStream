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

std::wstring Upper(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(), ::towupper);
    return text;
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
        if (Upper(instance).rfind(L"ROOT\\DISPLAY", 0) != 0) {
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

bool HasVirtualDisplay() {
    for (const VirtualDisplay& display : FindVirtualDisplays()) {
        if (display.running) {
            return true;
        }
    }
    return false;
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
        error = "SolStream does not have a display driver bundled with it. "
                "Install the Virtual Display Driver, then start SolStream again.";
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
    execute.lpFile = L"pnputil.exe";
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
