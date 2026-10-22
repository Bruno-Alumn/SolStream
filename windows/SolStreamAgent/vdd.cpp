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

}  // namespace solstream
