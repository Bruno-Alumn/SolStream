#include "display_setup.h"

#include "media/log.h"

#include <windows.h>
#include <aclapi.h>
#include <shlobj.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "display_demand.h"
#include "display_mode.h"
#include "util.h"
#include "vdd.h"

namespace solstream {
namespace {

// ── The device-info requests Windows does not declare ────────────────────────
//
// Written out flat, header inlined, rather than nesting the SDK's
// DISPLAYCONFIG_DEVICE_INFO_HEADER. Two of these requests — DPI scaling — are
// undocumented and have no SDK type at all, and the advanced-colour ones are
// missing from older SDKs and from some mingw headers, which matters because
// this program is cross-compiled from a Mac. One layout, spelled once, works on
// every toolchain.
//
// Sizes are load-bearing: every one of these calls fails with ERROR_GEN_FAILURE
// if `size` does not match what Windows expects for that type.

struct InfoHeader {
    int32_t type;
    uint32_t size;
    LUID adapter;
    uint32_t id;
};
static_assert(sizeof(InfoHeader) == 20, "the device-info header is 20 bytes");

struct SourceNameRequest {
    InfoHeader header;
    wchar_t gdi_name[32];
};

/// Scale values are indices relative to whatever Windows calls "recommended",
/// not percentages. The minimum absolute step is always 100%, which is what
/// makes recommended recoverable as -min.
struct DpiGetRequest {
    InfoHeader header;
    int32_t min_relative;
    int32_t current_relative;
    int32_t max_relative;
};

struct DpiSetRequest {
    InfoHeader header;
    int32_t relative;
};

struct AdvancedColorInfo {
    InfoHeader header;
    uint32_t flags;  ///< bit0 supported, bit1 enabled, bit2 wide colour enforced
    uint32_t colour_encoding;
    uint32_t bits_per_channel;
};

struct AdvancedColorState {
    InfoHeader header;
    uint32_t enable;  ///< bit0
};

constexpr int32_t kGetSourceName = 1;
constexpr int32_t kGetAdvancedColorInfo = 9;
constexpr int32_t kSetAdvancedColorState = 10;
constexpr int32_t kGetDpiScale = -3;
constexpr int32_t kSetDpiScale = -4;

/// Windows' fixed scaling steps. Not a range: DisplayConfigSetDeviceInfo takes
/// an index into this list, so a value not on it cannot be expressed.
constexpr int kScaleSteps[] = {100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500};

/// Every Retina Mac size we know about, in host pixels (points x 2). Seeding the
/// whole ladder up front is what keeps this out of the streaming path: a device
/// restart is needed to ADD a mode, never to switch between modes already in the
/// list. Pay it once here and any Mac that connects later is one
/// ChangeDisplaySettingsEx away.
///
/// All are within 4096 on both axes, which is NVENC's H.264 limit — a larger
/// canvas starts a session that never delivers a frame.
struct Mode { int width; int height; };
constexpr Mode kLadder[] = {
    {2560, 1440},  // 1280x720  @2x, and a 1440p panel at 100%
    {2560, 1600},  // 1280x800  @2x
    {2880, 1800},  // 1440x900  @2x — 13" Air default
    {2940, 1912},  // 1470x956  @2x — 14" MBP default
    {3024, 1964},  // 1512x982  @2x — 14" MBP native
    {3420, 2214},  // 1710x1107 @2x — 16" MBP default
    {3456, 2234},  // 1728x1117 @2x — 16" MBP native
    {3600, 2338},  // 1800x1169 @2x
    {3840, 2160},  // 4K panel at 100%
};

void Add(std::string& note, const std::string& line) {
    if (!note.empty()) {
        note += "\n";
    }
    note += line;
}

// ── The driver's settings file ───────────────────────────────────────────────

}  // namespace

std::wstring ReadRegString(HKEY root, const wchar_t* key, const wchar_t* name) {
    wchar_t value[MAX_PATH] = {0};
    DWORD size = sizeof(value);
    if (RegGetValueW(root, key, name, RRF_RT_REG_SZ | RRF_SUBKEY_WOW6464KEY, nullptr, value,
                     &size)
        != ERROR_SUCCESS) {
        return {};
    }
    return value;
}

std::wstring VddSettingsFolder() {
    const std::wstring configured = ReadRegString(
        HKEY_LOCAL_MACHINE, L"SOFTWARE\\MikeTheTech\\VirtualDisplayDriver", L"VDDPATH");
    if (!configured.empty()) {
        return configured;
    }
    // The literal the driver falls back to, not %SystemDrive%: MttVDD.dll
    // carries "C:\\VirtualDisplayDriver" as a string, and a folder anywhere
    // else is one it never reads.
    return L"C:\\VirtualDisplayDriver";
}

bool IsReparsePoint(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES
        && (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
}

namespace {

/// Whether `owner` is the account this process runs as: a folder the person
/// who is installing made themselves -- the driver unpacked by hand into
/// C:\\VirtualDisplayDriver -- is theirs to have written to. Another standard
/// user's is not.
bool OwnedByThisAccount(PSID owner) {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return false;
    }
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<unsigned char> buffer(size);
    bool same = false;
    if (size > 0 && GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
        same = EqualSid(owner, reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid) != FALSE;
    }
    CloseHandle(token);
    return same;
}

}  // namespace

bool IsUnsafeForElevatedWrite(const std::wstring& path) {
    HANDLE handle = CreateFileW(path.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                nullptr, OPEN_EXISTING,
                                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                                nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
        // Not there: it will be made by this process, and be its own.
        return GetLastError() != ERROR_FILE_NOT_FOUND && GetLastError() != ERROR_PATH_NOT_FOUND;
    }
    bool unsafe = true;
    BY_HANDLE_FILE_INFORMATION info{};
    PSID owner = nullptr;
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (GetFileInformationByHandle(handle, &info)
        && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0
        && GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, &owner,
                           nullptr, nullptr, nullptr, &descriptor) == ERROR_SUCCESS
        && owner) {
        unsafe = !IsWellKnownSid(owner, WinBuiltinAdministratorsSid)
              && !IsWellKnownSid(owner, WinLocalSystemSid)
              && !OwnedByThisAccount(owner);
    }
    if (descriptor) {
        LocalFree(descriptor);
    }
    CloseHandle(handle);
    return unsafe;
}

namespace {

/// Where MikeTheTech's driver keeps its mode list: its own folder first (see
/// VddSettingsFolder), then the places older builds used.
std::wstring FindVddSettings() {
    std::vector<std::wstring> candidates = {
        VddSettingsFolder() + L"\\vdd_settings.xml",
        L"C:\\IddSampleDriver\\vdd_settings.xml",
    };
    // From the shell, not the environment: an elevated process started from
    // a user's session takes their environment, which they can set.
    wchar_t root[MAX_PATH] = {0};
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_PROGRAM_FILES, nullptr, SHGFP_TYPE_CURRENT,
                                   root))) {
        candidates.push_back(std::wstring(root) + L"\\VirtualDisplayDriver\\vdd_settings.xml");
    }
    for (const std::wstring& path : candidates) {
        // Never one that is a link somewhere else, nor one a user made: this
        // file is rewritten with administrator rights, and C:\\ lets any user
        // make folders -- and swap one for a link after a check by path.
        if (GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES
            && !IsUnsafeForElevatedWrite(path)
            && !IsUnsafeForElevatedWrite(path.substr(0, path.find_last_of(L'\\')))) {
            return path;
        }
    }
    return {};
}

bool ReadFileText(const std::wstring& path, std::string& out) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    out.clear();
    char buffer[8192];
    DWORD read = 0;
    bool ok = true;
    for (;;) {
        // A read that fails partway is not the end of the file. Taken as one,
        // the half that was read would be patched and written back as all of it.
        if (!ReadFile(file, buffer, sizeof(buffer), &read, nullptr)) {
            ok = false;
            break;
        }
        if (read == 0) {
            break;
        }
        out.append(buffer, read);
    }
    CloseHandle(file);
    return ok;
}

/// Written beside it and moved over it, so a write that fails or a process
/// killed partway leaves the old file whole: an empty vdd_settings.xml is a
/// driver with no modes, which is no virtual display at all. The file beside it
/// is deleted first and then made new, never opened as it is -- elevated, this
/// must not write through a link somebody left at that name.
bool WriteFileText(const std::wstring& path, const std::string& text) {
    const std::wstring temporary = path + kVddSettingsWriteSuffix;
    if (!DeleteFileW(temporary.c_str()) && GetLastError() != ERROR_FILE_NOT_FOUND) {
        return false;
    }
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    const bool wrote = WriteFile(file, text.data(), (DWORD) text.size(), &written, nullptr)
                       && written == text.size() && FlushFileBuffers(file);
    CloseHandle(file);
    if (!wrote || !MoveFileExW(temporary.c_str(), path.c_str(),
                               MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}

/// Case-insensitive replace of `<tag>true</tag>` with false, tolerating the
/// whitespace the driver's own writer leaves in.
bool ClearBooleanTag(std::string& xml, const std::string& tag) {
    const std::string open = "<" + tag + ">";
    const std::string close = "</" + tag + ">";
    bool changed = false;
    size_t at = 0;
    while ((at = xml.find(open, at)) != std::string::npos) {
        const size_t value_start = at + open.size();
        const size_t value_end = xml.find(close, value_start);
        if (value_end == std::string::npos) {
            break;
        }
        std::string value = xml.substr(value_start, value_end - value_start);
        std::string trimmed;
        for (char c : value) {
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') {
                trimmed += (char) tolower((unsigned char) c);
            }
        }
        if (trimmed == "true") {
            xml.replace(value_start, value_end - value_start, "false");
            changed = true;
        }
        at = value_start;
    }
    return changed;
}

bool HasResolution(const std::string& xml, int width, int height) {
    // The driver writes one <resolution> per mode with the two numbers inside;
    // matching the pair textually is enough and needs no XML parser in a program
    // that has no other reason to carry one.
    const std::string w = "<width>" + std::to_string(width) + "</width>";
    size_t at = 0;
    while ((at = xml.find(w, at)) != std::string::npos) {
        const size_t next = xml.find("<resolution", at);
        const std::string window = xml.substr(at, (next == std::string::npos ? xml.size() : next) - at);
        if (window.find("<height>" + std::to_string(height) + "</height>")
            != std::string::npos) {
            return true;
        }
        at += w.size();
    }
    return false;
}

/// Patch the driver's settings: every ladder mode it does not already offer, and
/// HDR off. Returns true when the file changed, which is what decides whether
/// the device has to be cycled.
bool PatchVddSettings(const std::wstring& path, int width, int height,
                      std::string& note, std::string& error) {
    std::string xml;
    if (!ReadFileText(path, xml)) {
        error = "Could not read " + ToUtf8(path);
        return false;
    }
    const std::string original = xml;

    const bool hdr = ClearBooleanTag(xml, "HDRPlus");
    const bool ten_bit = ClearBooleanTag(xml, "SDR10bit");

    std::vector<Mode> wanted(std::begin(kLadder), std::end(kLadder));
    bool requested_on_ladder = false;
    for (const Mode& mode : wanted) {
        if (mode.width == width && mode.height == height) {
            requested_on_ladder = true;
        }
    }
    if (!requested_on_ladder && width > 0 && height > 0
        && width <= 4096 && height <= 4096) {
        wanted.push_back({width, height});
    }

    std::string block;
    int added = 0;
    for (const Mode& mode : wanted) {
        if (HasResolution(xml, mode.width, mode.height)) {
            continue;
        }
        // One refresh rate per added resolution, not the file's global list. The
        // driver replicates every <g_refresh_rate> across every resolution, so
        // the mode count is (resolutions x global rates) and a long ladder
        // against six global rates overflows the target-mode buffer. That
        // overflow is the nastiest failure here: the driver logs "Input buffer
        // is too small for target modes" and then reports success, so it
        // presents as a healthy device with no display at all.
        block += "        <resolution>\r\n            <width>"
               + std::to_string(mode.width) + "</width>\r\n            <height>"
               + std::to_string(mode.height)
               + "</height>\r\n            <refresh_rate>60</refresh_rate>\r\n        </resolution>\r\n";
        ++added;
    }
    if (added > 0) {
        const size_t close = xml.rfind("</resolutions>");
        if (close == std::string::npos) {
            error = "The driver's vdd_settings.xml has no <resolutions> block.";
            return false;
        }
        xml.insert(close, block + "    ");
    }

    if (xml == original) {
        Add(note, "The display driver already offers every mode SolStream uses.");
        return false;
    }

    // Keep the original, once. A driver that will not start after this is a
    // machine with no virtual display and no way back to the file that caused it.
    // A copy that failed is no copy: then the file stays as it is.
    if (!CopyFileW(path.c_str(), (path + kVddSettingsBackupSuffix).c_str(), TRUE)
        && GetLastError() != ERROR_FILE_EXISTS) {
        error = "Could not keep a copy of " + ToUtf8(path)
              + " before changing it, so it was left as it is. Setting up the "
                "display driver needs administrator rights.";
        return false;
    }
    if (!WriteFileText(path, xml)) {
        error = "Could not write " + ToUtf8(path)
              + ". Installing the display driver needs administrator rights.";
        return false;
    }
    if (added > 0) {
        Add(note, "Added " + std::to_string(added) + " display modes for the driver to offer.");
    }
    if (hdr || ten_bit) {
        Add(note, "Turned the driver's HDR off; SolStream streams SDR Rec.709.");
    }
    return true;
}

// ── Finding and driving the display ──────────────────────────────────────────

struct Adapter {
    std::wstring gdi_name;   ///< \\.\DISPLAY1
    bool attached = false;
    bool ours = false;       ///< IsSolStreamDisplayDriver
};

bool OffersMode(const std::wstring& gdi_name, int width, int height);

/// The virtual display's GDI adapter.
///
/// Root-enumerated, which is the same test vdd.cpp uses and the principled one:
/// a display adapter on a bus is a graphics card, one enumerated from the root
/// is a software device. The name check is the fallback for drivers whose
/// adapter reports a hardware id instead.
///
/// But "a virtual display" is not "SolStream's", and taking the first one found
/// picked a phone-as-monitor product's adapter on the dev box: no ladder mode,
/// so no virtual display at all. So every candidate is scored — our driver
/// first, then one already offering a size SolStream streams, then one already
/// attached — and the best wins.
bool FindVirtualAdapter(Adapter& out) {
    int best_score = -1;
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    for (DWORD n = 0; EnumDisplayDevicesW(nullptr, n, &device, 0); ++n) {
        const std::wstring id = FoldCase(device.DeviceID);
        const std::wstring name = device.DeviceString;
        const std::wstring folded_name = FoldCase(name);
        const bool root = id.rfind(L"root\\display", 0) == 0;
        const bool named = folded_name.find(L"virtual display") != std::wstring::npos
                        || folded_name.find(L"iddsample") != std::wstring::npos;
        if (root || named) {
            const bool attached =
                (device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
            bool streamable = false;
            for (const Mode& mode : kLadder) {
                if (OffersMode(device.DeviceName, mode.width, mode.height)) {
                    streamable = true;
                    break;
                }
            }
            const bool ours = IsSolStreamDisplayDriver(name);
            const int score = (ours ? 4 : 0) + (streamable ? 2 : 0) + (attached ? 1 : 0);
            if (score > best_score) {
                best_score = score;
                out.gdi_name = device.DeviceName;
                out.attached = attached;
                out.ours = ours;
            }
        }
        device = DISPLAY_DEVICEW{};
        device.cb = sizeof(device);
    }
    return best_score >= 0;
}

bool OffersMode(const std::wstring& gdi_name, int width, int height) {
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    for (DWORD i = 0; EnumDisplaySettingsW(gdi_name.c_str(), i, &mode); ++i) {
        if ((int) mode.dmPelsWidth == width && (int) mode.dmPelsHeight == height) {
            return true;
        }
        mode = DEVMODEW{};
        mode.dmSize = sizeof(mode);
    }
    return false;
}

/// The right edge of everything that is not this adapter, so the virtual display
/// is parked past it and never overlaps a real monitor's coordinates —
/// SolStream addresses windows in virtual-desktop space.
int RightOfEverythingElse(const std::wstring& skip) {
    int right = 0;
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    for (DWORD n = 0; EnumDisplayDevicesW(nullptr, n, &device, 0); ++n) {
        const std::wstring name = device.DeviceName;
        const bool attached =
            (device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
        if (attached && name != skip) {
            DEVMODEW mode{};
            mode.dmSize = sizeof(mode);
            if (EnumDisplaySettingsW(name.c_str(), ENUM_CURRENT_SETTINGS, &mode)) {
                const int edge = mode.dmPosition.x + (int) mode.dmPelsWidth;
                if (edge > right) {
                    right = edge;
                }
            }
        }
        device = DISPLAY_DEVICEW{};
        device.cb = sizeof(device);
    }
    return right;
}

/// Already attached at a size SolStream can stream? Then leave it alone.
///
/// Re-applying a mode costs a display reconfiguration -- every window on the
/// machine gets moved and every full-screen application blinks. Any size the
/// encoder takes counts, not only the ladder's: the Mac's `canvas` request
/// switches the display to the mode that best fits the Mac and persists it,
/// and that can be one of the driver's own modes. Comparing against the ladder
/// here put it back, only for the Mac to change it again on connecting.
bool AlreadyAttachedAtStreamableSize(const std::wstring& gdi_name) {
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    bool attached = false;
    for (DWORD n = 0; EnumDisplayDevicesW(nullptr, n, &device, 0); ++n) {
        if (gdi_name == device.DeviceName) {
            attached = (device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
            break;
        }
        device = DISPLAY_DEVICEW{};
        device.cb = sizeof(device);
    }
    if (!attached) {
        return false;
    }
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(gdi_name.c_str(), ENUM_CURRENT_SETTINGS, &mode)) {
        return false;
    }
    return KeepsAttachedSize(mode.dmPelsWidth, mode.dmPelsHeight);
}

/// The rate to attach at this size, by ChooseRefresh, or 0 when the display
/// offers none. The same choice the agent's `canvas` makes, so attaching and
/// resizing do not disagree about the rate.
DWORD RefreshAt(const std::wstring& gdi_name, int width, int height) {
    std::vector<unsigned> offered;
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    for (DWORD i = 0; EnumDisplaySettingsW(gdi_name.c_str(), i, &mode); ++i) {
        if ((int) mode.dmPelsWidth == width && (int) mode.dmPelsHeight == height
            && mode.dmBitsPerPel == 32) {
            offered.push_back(mode.dmDisplayFrequency);
        }
        mode = DEVMODEW{};
        mode.dmSize = sizeof(mode);
    }
    return ChooseRefresh(offered, kDisplayRefreshTarget);
}

bool AttachAt(const std::wstring& gdi_name, int width, int height, std::string& error) {
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    wcsncpy_s(mode.dmDeviceName, gdi_name.c_str(), _TRUNCATE);
    mode.dmPelsWidth = (DWORD) width;
    mode.dmPelsHeight = (DWORD) height;
    mode.dmBitsPerPel = 32;
    mode.dmPosition.x = RightOfEverythingElse(gdi_name);
    mode.dmPosition.y = 0;
    mode.dmFields = DM_POSITION | DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT;
    if (const DWORD hz = RefreshAt(gdi_name, width, height); hz != 0) {
        mode.dmDisplayFrequency = hz;
        mode.dmFields |= DM_DISPLAYFREQUENCY;
    }

    // Staged, then applied in one go. CDS_NORESET is 0x10000000 — 0x10000 is not
    // a valid flag and comes back DISP_CHANGE_BADFLAGS.
    LONG rc = ChangeDisplaySettingsExW(gdi_name.c_str(), &mode, nullptr,
                                       CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
    if (rc != DISP_CHANGE_SUCCESSFUL) {
        media::Log("[display] setting the size failed: %ld", rc);
        error = "The virtual display is installed, but Windows wouldn't set its size. "
                "Restarting this PC usually fixes it.";
        return false;
    }
    rc = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
    if (rc != DISP_CHANGE_SUCCESSFUL) {
        media::Log("[display] applying the settings failed: %ld", rc);
        error = "The virtual display is installed, but Windows wouldn't apply its "
                "settings. Restarting this PC usually fixes it.";
        return false;
    }
    return true;
}

// ── DisplayConfig ────────────────────────────────────────────────────────────

/// Every active path, so a display can be found by its GDI name and then
/// addressed as a source (DPI) or a target (HDR) — which are different halves of
/// the same path and the reason those two calls do not look alike.
bool QueryPaths(std::vector<DISPLAYCONFIG_PATH_INFO>& paths,
                std::vector<DISPLAYCONFIG_MODE_INFO>& modes) {
    UINT32 path_count = 0;
    UINT32 mode_count = 0;
    // The layout can change between asking for the sizes and reading the paths
    // -- most of all just after attaching a display -- and then the read
    // answers ERROR_INSUFFICIENT_BUFFER. Asking again is the documented answer;
    // giving up left HDR on, which is a black picture on the Mac.
    LONG result = ERROR_INSUFFICIENT_BUFFER;
    for (int attempt = 0; attempt < 3 && result == ERROR_INSUFFICIENT_BUFFER; ++attempt) {
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count)
            != ERROR_SUCCESS) {
            return false;
        }
        paths.assign(path_count, DISPLAYCONFIG_PATH_INFO{});
        modes.assign(mode_count, DISPLAYCONFIG_MODE_INFO{});
        result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(),
                                    &mode_count, modes.data(), nullptr);
    }
    if (result != ERROR_SUCCESS) {
        return false;
    }
    // QueryDisplayConfig writes back how many it actually filled, which can be
    // fewer than it asked for.
    paths.resize(path_count);
    modes.resize(mode_count);
    return true;
}

std::wstring SourceGdiName(const DISPLAYCONFIG_PATH_INFO& path) {
    SourceNameRequest request{};
    request.header.type = kGetSourceName;
    request.header.size = sizeof(request);
    request.header.adapter = path.sourceInfo.adapterId;
    request.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &request)
        != ERROR_SUCCESS) {
        return {};
    }
    return request.gdi_name;
}

bool FindPathFor(const std::wstring& gdi_name, DISPLAYCONFIG_PATH_INFO& out) {
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;
    if (!QueryPaths(paths, modes)) {
        return false;
    }
    for (const DISPLAYCONFIG_PATH_INFO& path : paths) {
        if (SourceGdiName(path) == gdi_name) {
            out = path;
            return true;
        }
    }
    return false;
}

/// The scaling a path's source is at, as a percentage, or 0 when it cannot be
/// read or is not one of Windows' steps.
int ScaleOf(const DISPLAYCONFIG_PATH_INFO& path) {
    DpiGetRequest get{};
    get.header.type = kGetDpiScale;
    get.header.size = sizeof(get);
    get.header.adapter = path.sourceInfo.adapterId;
    get.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &get)
        != ERROR_SUCCESS) {
        return 0;
    }
    const int index = -get.min_relative + get.current_relative;
    if (index < 0 || index >= (int) (sizeof(kScaleSteps) / sizeof(kScaleSteps[0]))) {
        return 0;
    }
    return kScaleSteps[index];
}

/// Where `percent` is in Windows' scaling steps, or -1 when it is not one.
int ScaleStep(int percent) {
    for (int i = 0; i < (int) (sizeof(kScaleSteps) / sizeof(kScaleSteps[0])); ++i) {
        if (kScaleSteps[i] == percent) {
            return i;
        }
    }
    return -1;
}

/// Whether Windows says no to `percent` on this path's display at its present
/// size. False when that cannot be read or `percent` is not a step: neither is
/// the size's fault, and attaching the display at another would not help.
bool ScaleOutOfReach(const DISPLAYCONFIG_PATH_INFO& path, int percent) {
    const int target = ScaleStep(percent);
    if (target < 0) {
        return false;
    }
    DpiGetRequest get{};
    get.header.type = kGetDpiScale;
    get.header.size = sizeof(get);
    get.header.adapter = path.sourceInfo.adapterId;
    get.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &get)
        != ERROR_SUCCESS) {
        return false;
    }
    return !ReachesScaleStep(target, get.min_relative, get.max_relative);
}

bool SetScale(const DISPLAYCONFIG_PATH_INFO& path, int percent, std::string& note) {
    const int target = ScaleStep(percent);
    if (target < 0) {
        Add(note, "Left the display's scaling alone: "
                  + std::to_string(percent) + "% is not one of Windows' steps.");
        return false;
    }

    DpiGetRequest get{};
    get.header.type = kGetDpiScale;
    get.header.size = sizeof(get);
    get.header.adapter = path.sourceInfo.adapterId;
    get.header.id = path.sourceInfo.id;
    if (DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &get)
        != ERROR_SUCCESS) {
        Add(note, "Could not read the display's scaling.");
        return false;
    }
    const int recommended = -get.min_relative;
    if (!ReachesScaleStep(target, get.min_relative, get.max_relative)) {
        Add(note, "This display cannot scale to " + std::to_string(percent) + "%.");
        return false;
    }
    // Already there, which is every Set up after the first. Setting it anyway
    // is a display reconfiguration: Windows re-lays out the desktop and every
    // window on it gets a WM_DPICHANGED, for a value that did not change.
    if (recommended + get.current_relative == target) {
        return true;
    }

    DpiSetRequest set{};
    set.header.type = kSetDpiScale;
    set.header.size = sizeof(set);
    set.header.adapter = path.sourceInfo.adapterId;
    set.header.id = path.sourceInfo.id;
    set.relative = target - recommended;
    if (DisplayConfigSetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &set)
        != ERROR_SUCCESS) {
        Add(note, "Could not set the display's scaling to "
                  + std::to_string(percent) + "%.");
        return false;
    }
    Add(note, "Set the display's scaling to " + std::to_string(percent)
              + "%, to match a Retina Mac.");
    return true;
}

/// Read the advanced-colour state of a path's TARGET. Advanced colour is a
/// target property, unlike DPI scaling which is a source one — getting that
/// wrong is a call that succeeds against the wrong half of the path and changes
/// nothing.
bool GetAdvancedColour(const DISPLAYCONFIG_PATH_INFO& path, AdvancedColorInfo& out) {
    out = AdvancedColorInfo{};
    out.header.type = kGetAdvancedColorInfo;
    out.header.size = sizeof(out);
    out.header.adapter = path.targetInfo.adapterId;
    out.header.id = path.targetInfo.id;
    return DisplayConfigGetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &out)
           == ERROR_SUCCESS;
}

/// Turn "Use HDR" off on a path's display, whose advanced-colour state `info`
/// says is on.
///
/// Needs no elevation, but does need the interactive session. This is the
/// setting that actually decides: clearing HDRPlus in the driver's own settings
/// file stops it ADVERTISING HDR, but Windows remembers the per-display toggle
/// and re-applies it, so the display keeps composing in PQ and only the bit
/// depth changes.
bool TurnHdrOff(const DISPLAYCONFIG_PATH_INFO& path, const AdvancedColorInfo& info,
                std::string& error) {
    if ((info.flags & 0x1) == 0) {
        // Cannot do HDR at all, so it is already off.
        return true;
    }
    AdvancedColorState state{};
    state.header.type = kSetAdvancedColorState;
    state.header.size = sizeof(state);
    state.header.adapter = path.targetInfo.adapterId;
    state.header.id = path.targetInfo.id;
    state.enable = 0u;
    if (DisplayConfigSetDeviceInfo((DISPLAYCONFIG_DEVICE_INFO_HEADER*) &state)
        != ERROR_SUCCESS) {
        error = "Could not change the display's HDR setting. Turn it off under "
                "Settings > System > Display > Use HDR.";
        return false;
    }
    return true;
}

/// How many ConfigureVirtualDisplay calls are running in this process.
std::atomic<int> g_configuring{0};

/// Where the size the virtual display had when it was last detached is kept,
/// for the next attach (ParseDisplaySize).
std::wstring RememberedSizePath() {
    return LocalDataPath(L"virtual-display-size.txt");
}

}  // namespace

std::wstring VirtualDisplayDevice() {
    Adapter adapter;
    return FindVirtualAdapter(adapter) && adapter.attached && adapter.ours
               ? adapter.gdi_name
               : std::wstring{};
}

bool ConfigureVirtualDisplay(int width, int height, int scale_percent,
                             std::string& note, std::string& error) {
    // Held for the whole of it, so the host does not detach the display it is
    // attaching and scaling; see ConfiguringVirtualDisplay.
    struct Configuring {
        Configuring() { g_configuring.fetch_add(1); }
        ~Configuring() { g_configuring.fetch_sub(1); }
    } configuring;
    if (width <= 0 || height <= 0 || width > 4096 || height > 4096) {
        error = "A streaming canvas has to be within 4096 pixels on both axes; "
                "larger starts a session that never delivers a frame.";
        return false;
    }

    // 1. Teach the driver the modes, and turn its HDR off.
    const std::wstring settings = FindVddSettings();
    bool cycle = false;
    if (settings.empty()) {
        Add(note, "Could not find the display driver's settings file, so its mode "
                  "list was left as it is.");
    } else {
        std::string patch_error;
        cycle = PatchVddSettings(settings, width, height, note, patch_error);
        // Not fatal. Run without administrator rights (--configure-display from
        // a plain prompt), writing under C:\ is refused and there is usually
        // nothing to write anyway, and everything below — attaching, scaling,
        // HDR — needs the session rather than the rights. Failing here would
        // throw away the part that works to report the part that was not
        // needed.
        if (!cycle && !patch_error.empty()) {
            Add(note, patch_error);
        }
    }

    // 2. The driver reads that file when the device starts, so a change needs a
    //    cycle. pnputil /restart-device has been in Windows since 10 2004 and
    //    needs nothing installed.
    if (cycle) {
        // Only the driver whose settings were just written. Restarting someone
        // else's virtual display blanks whatever they had on it, for nothing.
        // With none of ours here, nothing: the file belongs to a driver that is
        // not installed, and every display left is somebody else's.
        const auto displays = SolStreamDisplays(FindVirtualDisplays());
        // And checked. A restart that was refused — no administrator rights, or
        // pnputil answering 3010 because the device wants a reboot instead — left
        // the driver on its old mode list, and the only trace of it was the
        // fifteen-second wait below for modes that were never going to appear.
        bool restarted = false;
        for (const VirtualDisplay& display : displays) {
            const DWORD code = RunHidden(L"pnputil.exe /restart-device \""
                                         + display.instance_id + L"\"", 120000);
            if (code == 0) {
                restarted = true;
                continue;
            }
            Add(note, "Could not restart "
                      + ToUtf8(display.friendly_name.empty() ? display.instance_id
                                                             : display.friendly_name)
                      + " (pnputil " + RunOutcome(code) + "), so its new mode list "
                        "takes effect after restarting this PC.");
        }
        if (restarted) {
            Sleep(6000);
        } else {
            // Nothing reloaded its settings, so nothing new is coming: treat this
            // as the no-cycle case rather than wait for it.
            cycle = false;
        }
    }

    // 3. Find it, and wait for the mode to actually be offered. The device comes
    //    back before its mode list does.
    Adapter adapter;
    // The retry is only for the case where the device was just restarted. With
    // no cycle the answer is already known, and ten seconds of sleeping to
    // rediscover that would be ten seconds added to every Set up.
    const int tries = cycle ? 10 : 1;
    for (int attempt = 0; attempt < tries; ++attempt) {
        // Ours, not merely any: another product's display is listed straight
        // away while ours is still coming back from the restart.
        if (FindVirtualAdapter(adapter) && adapter.ours) {
            break;
        }
        // Only before another look: after the last one, waiting tells nothing.
        if (attempt + 1 < tries) {
            Sleep(1000);
        }
    }
    if (adapter.gdi_name.empty()) {
        error = "Windows hasn't started the virtual display yet. Restart this PC, then "
                "choose Set up in SolStream if it still streams your main display.";
        return false;
    }
    // Another product's virtual display -- Parsec's, Sunshine's, spacedesk's --
    // is that product's to size, scale and colour. Without our own driver this
    // used to resize it, set it to 200% and turn its HDR off at every logon.
    // VirtualDisplayDevice already refuses it for capture, so configuring it
    // bought nothing.
    if (!adapter.ours) {
        const auto displays = FindVirtualDisplays();
        const bool ours_installed = std::any_of(
            displays.begin(), displays.end(), [](const VirtualDisplay& display) {
                return IsSolStreamDisplayDriver(display.friendly_name);
            });
        error = ours_installed
            ? "SolStream's virtual display is installed but has not started, so "
              "another program's was left alone. Restart this PC and open "
              "SolStream again."
            : "SolStream's display driver is not installed, and the virtual "
              "display that is belongs to another program, so it was left "
              "alone. Choose Set up in SolStream to install SolStream's.";
        return false;
    }

    // Only wait if the device was just cycled — it comes back before its mode
    // list does. Without the cycle the answer is already final, and waiting
    // fifteen seconds for it would be fifteen seconds added to every Set up.
    bool offered = OffersMode(adapter.gdi_name, width, height);
    for (int attempt = 0; cycle && !offered && attempt < 15; ++attempt) {
        Sleep(1000);
        offered = OffersMode(adapter.gdi_name, width, height);
    }

    // Second best is a great deal better than nothing. A driver that was never
    // taught the ladder — because nobody has run this with administrator rights
    // yet — still offers its own modes, and streaming at the largest of those
    // is a picture rather than an error message.
    std::string fallback;
    if (!offered) {
        // Largest first: the ladder is written smallest to largest, and the
        // biggest canvas that fits is the one that resamples least on the Mac.
        for (int i = (int) (sizeof(kLadder) / sizeof(kLadder[0])) - 1; i >= 0; --i) {
            const Mode& mode = kLadder[i];
            if (mode.width > width || mode.height > height) {
                continue;
            }
            if (OffersMode(adapter.gdi_name, mode.width, mode.height)) {
                width = mode.width;
                height = mode.height;
                offered = true;
                fallback = "The display driver does not offer that size yet, so "
                          "SolStream used " + std::to_string(width) + "x"
                          + std::to_string(height)
                          + ". Set the display up with administrator rights to "
                            "add the rest.";
                break;
            }
        }
    }
    if (!offered) {
        error = "The display driver offers no size SolStream can stream. Restart "
                "this PC and open SolStream again.";
        return false;
    }

    // 4. Attach it.
    const auto attach = [&]() {
        if (!AttachAt(adapter.gdi_name, width, height, error)) {
            return false;
        }
        Sleep(2000);
        // Said only when it happened: with the display already at a size it
        // keeps, the size fallen back to was never put on it.
        if (!fallback.empty()) {
            Add(note, fallback);
        }
        Add(note, "Attached the virtual display at " + std::to_string(width) + "x"
                  + std::to_string(height) + ".");
        return true;
    };
    const bool kept = AlreadyAttachedAtStreamableSize(adapter.gdi_name);
    if (!kept && !attach()) {
        return false;
    }

    // 5. Scaling and HDR. Both are session-bound rather than privileged, and
    //    neither is worth failing the whole setup over: a display that is
    //    attached but scaled wrong still streams.
    DISPLAYCONFIG_PATH_INFO path{};
    if (!FindPathFor(adapter.gdi_name, path)) {
        Add(note, "Could not read the display's configuration, so its scaling and "
                  "HDR were left alone.");
        return true;
    }
    // A size kept in step 4 can be one Windows will not scale that far: the
    // driver's own stock mode, which Windows attaches a new display at, may be
    // 1080p, and Windows stops a display that size at about 175%. Nothing after
    // setup puts that right -- `canvas` changes the size and rate, never the
    // scaling -- so the Mac would get its canvas with tiny text. Attached at
    // the size asked for instead, once, and only when that is another size.
    if (kept && ScaleOutOfReach(path, scale_percent)) {
        DEVMODEW current{};
        current.dmSize = sizeof(current);
        const bool same_size =
            EnumDisplaySettingsW(adapter.gdi_name.c_str(), ENUM_CURRENT_SETTINGS, &current)
            && (int) current.dmPelsWidth == width && (int) current.dmPelsHeight == height;
        if (!same_size) {
            if (!attach() && !error.empty()) {
                // Still attached at the size it had, so still streams.
                Add(note, error);
                error.clear();
            }
            if (!FindPathFor(adapter.gdi_name, path)) {
                Add(note, "Could not read the display's configuration, so its scaling "
                          "and HDR were left alone.");
                return true;
            }
        }
    }
    SetScale(path, scale_percent, note);

    AdvancedColorInfo colour{};
    if (GetAdvancedColour(path, colour) && (colour.flags & 0x2) != 0) {
        std::string hdr_error;
        Add(note, TurnHdrOff(path, colour, hdr_error)
                      ? "Turned HDR off on the virtual display, so colours arrive "
                        "on your Mac the way Windows drew them."
                      : hdr_error);
    }
    return true;
}

int VirtualDisplayScale() {
    const std::wstring device = VirtualDisplayDevice();
    DISPLAYCONFIG_PATH_INFO path{};
    if (device.empty() || !FindPathFor(device, path)) {
        return 0;
    }
    return ScaleOf(path);
}

void CheckVirtualDisplay(std::string& note) {
    Adapter adapter;
    if (!FindVirtualAdapter(adapter) || !adapter.ours) {
        Add(note, "SolStream's virtual display is not running, so the main display is "
                  "captured.");
        return;
    }
    if (!adapter.attached) {
        // Left so. Attaching it here is a display reconfiguration at every
        // start of the host, and somebody may have turned it off in Windows'
        // display settings on purpose.
        Add(note, "The virtual display " + ToUtf8(adapter.gdi_name)
                  + " is not attached, so the main display is captured. Choose Set "
                    "up in SolStream's window or tray menu to attach it.");
        return;
    }
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    std::string line = "The virtual display " + ToUtf8(adapter.gdi_name) + " is attached";
    if (EnumDisplaySettingsW(adapter.gdi_name.c_str(), ENUM_CURRENT_SETTINGS, &mode)) {
        line += " at " + std::to_string(mode.dmPelsWidth) + "x"
              + std::to_string(mode.dmPelsHeight) + " @ "
              + std::to_string(mode.dmDisplayFrequency) + "Hz";
    }
    DISPLAYCONFIG_PATH_INFO path{};
    if (!FindPathFor(adapter.gdi_name, path)) {
        Add(note, line + "; its scaling and HDR could not be read.");
        return;
    }
    const int scale = ScaleOf(path);
    if (scale != 0) {
        line += ", " + std::to_string(scale) + "% scaling";
    }
    Add(note, line + ".");
    if (scale != 0 && scale != kDefaultScalePercent) {
        // Said, not changed: a scaling change re-lays out the whole desktop,
        // and Set up is where SolStream makes that kind of change.
        Add(note, "SolStream sets it up at " + std::to_string(kDefaultScalePercent)
                  + "% to match a Retina Mac; Set up in SolStream's window or tray "
                    "menu does that.");
    }

    // The one thing changed here. "Use HDR" is a per-display toggle any user
    // can set, it changes how the display composes and not its size or place,
    // and left on it is what made streamed content arrive as a black
    // rectangle inside correctly drawn window chrome.
    AdvancedColorInfo colour{};
    if (GetAdvancedColour(path, colour) && (colour.flags & 0x2) != 0) {
        std::string hdr_error;
        Add(note, TurnHdrOff(path, colour, hdr_error)
                      ? "Turned HDR off on the virtual display, so colours arrive "
                        "on your Mac the way Windows drew them."
                      : hdr_error);
    }
}

bool ConfiguringVirtualDisplay() {
    return g_configuring.load() > 0;
}

bool AttachVirtualDisplay(std::string& note, std::string& error) {
    Adapter adapter;
    if (!FindVirtualAdapter(adapter) || !adapter.ours) {
        error = "SolStream's virtual display is not running.";
        return false;
    }
    if (adapter.attached) {
        return true;
    }
    // The size it was detached at, which is the size the last Mac's `canvas`
    // chose: the same Mac asks for it again, and finds it already there. Then
    // the default canvas, then the largest ladder size it offers.
    int width = 0, height = 0;
    std::string text;
    unsigned w = 0, h = 0;
    if (ReadFileText(RememberedSizePath(), text) && ParseDisplaySize(text, w, h)
        && OffersMode(adapter.gdi_name, (int) w, (int) h)) {
        width = (int) w;
        height = (int) h;
    } else if (OffersMode(adapter.gdi_name, kDefaultCanvasWidth, kDefaultCanvasHeight)) {
        width = kDefaultCanvasWidth;
        height = kDefaultCanvasHeight;
    } else {
        for (int i = (int) (sizeof(kLadder) / sizeof(kLadder[0])) - 1; i >= 0; --i) {
            if (OffersMode(adapter.gdi_name, kLadder[i].width, kLadder[i].height)) {
                width = kLadder[i].width;
                height = kLadder[i].height;
                break;
            }
        }
    }
    if (width == 0) {
        error = "The display driver offers no size SolStream can stream.";
        return false;
    }
    if (!AttachAt(adapter.gdi_name, width, height, error)) {
        return false;
    }
    Add(note, "Attached the virtual display " + ToUtf8(adapter.gdi_name) + " at "
              + std::to_string(width) + "x" + std::to_string(height) + ".");
    return true;
}

bool DetachVirtualDisplay(std::string& note) {
    Adapter adapter;
    if (!FindVirtualAdapter(adapter) || !adapter.ours || !adapter.attached) {
        return false;
    }
    // Never the primary, and never the last display on the desktop: a PC with
    // no monitor of its own -- headless, or its monitor off at the wall -- has
    // only this one, and taking it away leaves Windows nothing to draw on.
    bool primary = false;
    int others = 0;
    DISPLAY_DEVICEW device{};
    device.cb = sizeof(device);
    for (DWORD n = 0; EnumDisplayDevicesW(nullptr, n, &device, 0); ++n) {
        if ((device.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0) {
            if (adapter.gdi_name == device.DeviceName) {
                primary = (device.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
            } else {
                ++others;
            }
        }
        device = DISPLAY_DEVICEW{};
        device.cb = sizeof(device);
    }
    if (primary || others == 0) {
        Add(note, "Left the virtual display " + ToUtf8(adapter.gdi_name) + " attached: it is "
                  + (primary ? "the main display." : "the only display."));
        return false;
    }

    DEVMODEW current{};
    current.dmSize = sizeof(current);
    if (EnumDisplaySettingsW(adapter.gdi_name.c_str(), ENUM_CURRENT_SETTINGS, &current)
        && KeepsAttachedSize(current.dmPelsWidth, current.dmPelsHeight)) {
        WriteFileText(RememberedSizePath(), std::to_string(current.dmPelsWidth) + "x"
                                                + std::to_string(current.dmPelsHeight) + "\n");
    }

    // No size and no place is Windows' "off the desktop". Into the registry,
    // as the attach is, so a host that crashes after this cannot have Windows
    // bring the display back at the next logon.
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    wcsncpy_s(mode.dmDeviceName, adapter.gdi_name.c_str(), _TRUNCATE);
    mode.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
    LONG rc = ChangeDisplaySettingsExW(adapter.gdi_name.c_str(), &mode, nullptr,
                                       CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
    if (rc != DISP_CHANGE_SUCCESSFUL) {
        Add(note, "Windows would not detach the virtual display " + ToUtf8(adapter.gdi_name)
                  + " (" + std::to_string(rc) + ").");
        return false;
    }
    rc = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
    if (rc != DISP_CHANGE_SUCCESSFUL) {
        Add(note, "Windows would not apply the detach of the virtual display "
                  + ToUtf8(adapter.gdi_name) + " (" + std::to_string(rc) + ").");
        return false;
    }
    Add(note, "Detached the virtual display " + ToUtf8(adapter.gdi_name) + ".");
    return true;
}

}  // namespace solstream
