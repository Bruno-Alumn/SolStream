// SolStream Agent — the Windows half of single-application streaming.
//
// It does one job: make a chosen application's window sit at a known,
// non-overlapping rectangle on a chosen display, and tell the Mac where it is.
// The Mac then crops that rectangle out of the single Sunshine stream and
// presents it as a native window.
//
// Deliberately plain Win32 — SetWindowPos, EnumWindows, GetMonitorInfo, a
// socket. No D3D, no WinRT, no COM lifetimes, no shared handles. That is the
// only kind of Windows code that can be written correctly without a debugger,
// which matters because this is developed on a Mac and cross-compiled.
//
// Build (macOS cross):  ./build-cross.sh
// Build (Windows):      cmake --build . --target SolStreamAgent

// windows.h defines min/max as macros, which turns any std::max( into std::(
// and produces a baffling "illegal token on right side of ::" from MSVC.
// mingw-w64 does not define them, so this only shows up in the MSVC build.
// Target Windows 10 1703+, where SetProcessDpiAwarenessContext and the
// PER_MONITOR_AWARE_V2 context are declared. The MSVC SDK guards them behind
// this; mingw-w64 declares them unconditionally.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif

#define NOMINMAX
// Keeps windows.h from dragging in the original winsock.h, which would clash
// with winsock2.h below.
#define WIN32_LEAN_AND_MEAN

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <wincrypt.h>
#include <winhttp.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <cstdlib>
#include <cwchar>
#include <cwctype>
#include <set>
#include <string>
#include <vector>

namespace {

constexpr unsigned short kDefaultPort = 47997;

// Anyone who can reach this socket can enumerate every window title and move or
// focus any window on the machine. There is no authentication, so by default it
// is bound to loopback only and reached through an SSH tunnel. --listen-all is
// opt-in and prints a warning.
constexpr const char* kLoopback = "127.0.0.1";
constexpr int kProtocolVersion = 1;

/// Sunshine's web UI / config API port. It is the stream port plus one, so a host
/// that moved Sunshine off its default needs --sunshine-port to match.
unsigned short g_sunshine_web_port = 47990;

// ── Logging ──────────────────────────────────────────────────────────────────

void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(args);
}

// ── Text ─────────────────────────────────────────────────────────────────────

std::string ToUtf8(const std::wstring& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return {};
    }
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                        out.data(), needed, nullptr, nullptr);
    return out;
}

std::wstring ToWide(const std::string& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0);
    if (needed <= 0) {
        return {};
    }
    std::wstring out(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(), out.data(), needed);
    return out;
}

/// Escape a string for embedding in JSON. Window titles are arbitrary user
/// text — quotes and backslashes in them would otherwise corrupt the stream.
std::string JsonEscape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 8);
    for (const unsigned char ch : text) {
        switch (ch) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (ch < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
                    out += buffer;
                } else {
                    out += static_cast<char>(ch);
                }
        }
    }
    return out;
}

// ── Displays ─────────────────────────────────────────────────────────────────

struct Display {
    std::string device_name;  // matches Sunshine's output_name / DXGI DeviceName
    std::string adapter;      // e.g. "NVIDIA GeForce RTX 4070 SUPER", "Virtual Display Driver"
    RECT bounds{};
    bool primary = false;
};

/// The GDI adapter driving a display.
///
/// The Mac uses this to tell a virtual display from a physical one. Parking the
/// streamed application on a display of its own is what stops anything the user
/// has open on the real monitor from ever landing inside the crop.
std::string AdapterDescription(const wchar_t* device_name) {
    for (DWORD i = 0;; ++i) {
        DISPLAY_DEVICEW adapter{};
        adapter.cb = sizeof(adapter);
        if (!EnumDisplayDevicesW(nullptr, i, &adapter, 0)) {
            return {};
        }
        if (wcscmp(adapter.DeviceName, device_name) == 0) {
            return ToUtf8(adapter.DeviceString);
        }
    }
}

BOOL CALLBACK MonitorProc(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
    auto* displays = reinterpret_cast<std::vector<Display>*>(param);

    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) {
        return TRUE;
    }

    Display display;
    display.device_name = ToUtf8(info.szDevice);
    display.adapter = AdapterDescription(info.szDevice);
    display.bounds = info.rcMonitor;
    display.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
    displays->push_back(std::move(display));
    return TRUE;
}

std::vector<Display> EnumerateDisplays() {
    std::vector<Display> displays;
    EnumDisplayMonitors(nullptr, nullptr, MonitorProc, reinterpret_cast<LPARAM>(&displays));
    return displays;
}

/// Point a display at the mode that best fits a requested canvas.
///
/// The Mac asks the host to render at the Mac's own resolution: a bigger canvas
/// spends encoder time and bitrate on pixels nobody sees, and a smaller one gets
/// upscaled and looks soft.
///
/// This only ever SWITCHES between modes the driver already offers, which is
/// immediate. Adding a mode to a virtual display is the expensive operation — it
/// needs a device restart — so the modes are seeded once at setup instead.
/// Picks the smallest mode that still covers the request, so the Mac's window is
/// never upscaled, and falls back to the largest available if nothing covers it.
bool SetDisplayMode(const std::wstring& device, int want_w, int want_h,
                    int& out_w, int& out_h) {
    DEVMODEW best{};
    DEVMODEW largest{};
    bool have_best = false;
    bool have_largest = false;

    for (DWORD i = 0;; ++i) {
        DEVMODEW mode{};
        mode.dmSize = sizeof(mode);
        if (!EnumDisplaySettingsW(device.c_str(), i, &mode)) {
            break;
        }
        if (mode.dmBitsPerPel != 32) {
            continue;
        }
        const long long area = (long long) mode.dmPelsWidth * mode.dmPelsHeight;
        if (!have_largest || area > (long long) largest.dmPelsWidth * largest.dmPelsHeight) {
            largest = mode;
            have_largest = true;
        }
        if ((int) mode.dmPelsWidth < want_w || (int) mode.dmPelsHeight < want_h) {
            continue;
        }
        if (!have_best || area < (long long) best.dmPelsWidth * best.dmPelsHeight) {
            best = mode;
            have_best = true;
        }
    }
    if (!have_best) {
        if (!have_largest) {
            return false;
        }
        best = largest;
    }

    DEVMODEW current{};
    current.dmSize = sizeof(current);
    if (EnumDisplaySettingsW(device.c_str(), ENUM_CURRENT_SETTINGS, &current)
        && current.dmPelsWidth == best.dmPelsWidth
        && current.dmPelsHeight == best.dmPelsHeight) {
        out_w = (int) current.dmPelsWidth;
        out_h = (int) current.dmPelsHeight;
        return true;  // already there; do not make the screen flash for nothing
    }

    best.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;
    const LONG rc = ChangeDisplaySettingsExW(device.c_str(), &best, nullptr,
                                             CDS_UPDATEREGISTRY, nullptr);
    if (rc != DISP_CHANGE_SUCCESSFUL) {
        Log("[agent] mode change to %ux%u failed: %ld",
            best.dmPelsWidth, best.dmPelsHeight, rc);
        return false;
    }
    out_w = (int) best.dmPelsWidth;
    out_h = (int) best.dmPelsHeight;
    Log("[agent] display mode -> %dx%d", out_w, out_h);
    return true;
}

// ── Windows ──────────────────────────────────────────────────────────────────

struct WindowInfo {
    HWND handle = nullptr;
    std::string title;
    std::string class_name;
    DWORD pid = 0;
    RECT frame{};   // the visible frame, excluding invisible resize borders
    RECT client{};  // client area in screen coordinates
    /// Something is drawn over this window's client area.
    ///
    /// This matters because the Mac crops a RECTANGLE out of the captured
    /// display: the crop has no idea where window borders are, so anything
    /// covering the tile is streamed as though it were part of the app.
    bool occluded = false;
    std::string occluded_by;
    /// Pixels of non-client caption above the client area.
    ///
    /// The Mac crops the CLIENT area, so a standard caption is already outside
    /// the crop and its minimise/maximise/close buttons never reach the stream.
    /// A window that draws its own caption inside the client area (Explorer,
    /// Chrome, Discord) reports 0 here — and for those the buttons share a strip
    /// with tabs and the address bar, so cropping them off would take real UI
    /// with them.
    int caption_inset = 0;
};

/// Could this window actually draw over what is beneath it?
///
/// WS_EX_TRANSPARENT marks a click-through overlay, and a layered window with
/// zero alpha draws nothing. Both sit above ordinary windows without hiding
/// anything, so treating them as occluders would report a permanent false
/// positive on any machine with a game overlay installed.
bool CanPaintOver(HWND window) {
    const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);

    // Click-through overlay.
    if (style & WS_EX_TRANSPARENT) {
        return false;
    }

    if (style & WS_EX_LAYERED) {
        BYTE alpha = 255;
        DWORD flags = 0;
        COLORREF key = 0;
        if (GetLayeredWindowAttributes(window, &key, &alpha, &flags)) {
            if ((flags & LWA_ALPHA) && alpha < 16) {
                return false;
            }
        } else {
            // The call only succeeds for windows that used
            // SetLayeredWindowAttributes. A failure means per-pixel alpha via
            // UpdateLayeredWindow, which is how game and chat overlays are
            // built — screen-sized, and almost entirely transparent. Treating
            // those as occluders reports a permanent false positive.
            return false;
        }
    }

    // A window that never takes focus and hides from the task bar is
    // decoration, not something a user would say is "covering" their app.
    if ((style & WS_EX_NOACTIVATE) && (style & WS_EX_TOOLWINDOW)) {
        return false;
    }
    return true;
}

bool Intersects(const RECT& a, const RECT& b) {
    return a.left < b.right && b.left < a.right &&
           a.top < b.bottom && b.top < a.bottom;
}

/// Windows 10+ window rectangles include an invisible resize border, so
/// GetWindowRect overstates the visible bounds by several pixels on each side.
/// DWM knows the truth; fall back only if it refuses.
RECT VisibleFrame(HWND window) {
    RECT frame{};
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS,
                                        &frame, sizeof(frame)))) {
        return frame;
    }
    GetWindowRect(window, &frame);
    return frame;
}

/// Client area, in screen coordinates.
RECT ClientAreaInScreen(HWND window) {
    RECT client{};
    GetClientRect(window, &client);
    POINT topLeft{client.left, client.top};
    POINT bottomRight{client.right, client.bottom};
    ClientToScreen(window, &topLeft);
    ClientToScreen(window, &bottomRight);
    return RECT{topLeft.x, topLeft.y, bottomRight.x, bottomRight.y};
}

/// Is this a window a user would think of as an application window?
bool IsUserWindow(HWND window) {
    if (!IsWindowVisible(window) || IsIconic(window)) {
        return false;
    }
    if (GetWindow(window, GW_OWNER) != nullptr) {
        return false;  // tool palettes, dialogs owned by another window
    }

    const LONG_PTR style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    if (style & WS_EX_TOOLWINDOW) {
        return false;
    }

    // UWP keeps invisible "ghost" windows around that pass every check above;
    // DWM marks them cloaked. Without this the window list is full of junk.
    int cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))
        && cloaked != 0) {
        return false;
    }

    if (GetWindowTextLengthW(window) == 0) {
        return false;
    }

    const RECT frame = VisibleFrame(window);
    return (frame.right - frame.left) > 0 && (frame.bottom - frame.top) > 0;
}

/// Accumulates the enumeration, plus every visible window above the current
/// one, so occlusion can be decided in a single top-to-bottom pass.
struct EnumState {
    std::vector<WindowInfo> windows;
    std::vector<std::pair<RECT, std::string>> above;
};

BOOL CALLBACK WindowProc(HWND window, LPARAM param) {
    auto* state = reinterpret_cast<EnumState*>(param);

    // Anything visible can occlude, including the tool windows and owned
    // dialogs that IsUserWindow filters out of the reported list — but only if
    // it actually paints. Screen-wide click-through overlays (the NVIDIA
    // GeForce overlay is the usual one) sit above everything and would
    // otherwise report constant false occlusion.
    const bool visible = IsWindowVisible(window) && !IsIconic(window) && CanPaintOver(window);
    int cloaked = 0;
    if (visible
        && !(SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))
             && cloaked != 0)) {
        const RECT frame = VisibleFrame(window);
        if ((frame.right - frame.left) > 0 && (frame.bottom - frame.top) > 0) {
            wchar_t occluder_title[128] = {};
            GetWindowTextW(window, occluder_title, 128);
            state->above.emplace_back(frame, ToUtf8(occluder_title));
        }
    }

    if (!IsUserWindow(window)) {
        return TRUE;
    }
    auto* windows = &state->windows;

    WindowInfo info;
    info.handle = window;
    info.frame = VisibleFrame(window);
    info.client = ClientAreaInScreen(window);
    info.caption_inset = (int) std::max(0L, info.client.top - info.frame.top);
    GetWindowThreadProcessId(window, &info.pid);

    std::wstring title(static_cast<size_t>(GetWindowTextLengthW(window)) + 1, L'\0');
    const int copied = GetWindowTextW(window, title.data(), (int) title.size());
    title.resize(static_cast<size_t>(std::max(copied, 0)));
    info.title = ToUtf8(title);

    wchar_t class_name[256] = {};
    GetClassNameW(window, class_name, 256);
    info.class_name = ToUtf8(class_name);

    // Everything already in `above` was enumerated earlier, i.e. is higher in
    // the Z-order. The last entry is this window itself. Report whichever
    // covers the most of the tile — the first one found is not necessarily the
    // one a user would blame.
    long long worst = 0;
    for (size_t i = 0; i + 1 < state->above.size(); ++i) {
        const RECT& other = state->above[i].first;
        if (!Intersects(other, info.client)) {
            continue;
        }
        const long long overlap =
            (long long) (std::min(other.right, info.client.right) - std::max(other.left, info.client.left)) *
            (long long) (std::min(other.bottom, info.client.bottom) - std::max(other.top, info.client.top));
        if (overlap > worst) {
            worst = overlap;
            info.occluded = true;
            info.occluded_by = state->above[i].second;
        }
    }

    windows->push_back(std::move(info));
    return TRUE;
}

std::vector<WindowInfo> EnumerateWindows() {
    EnumState state;
    EnumWindows(WindowProc, reinterpret_cast<LPARAM>(&state));
    return std::move(state.windows);
}

HWND WindowFromId(uint64_t id) {
    auto handle = reinterpret_cast<HWND>(static_cast<uintptr_t>(id));
    return IsWindow(handle) ? handle : nullptr;
}

uint64_t IdFromWindow(HWND window) {
    return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(window));
}

// ── Launchable applications ──────────────────────────────────────────────────

struct AppEntry {
    std::string name;
    std::wstring path;  // the .lnk itself; ShellExecute resolves it
};

/// Walk a Start Menu tree collecting shortcuts.
///
/// The shortcuts are launched as-is rather than resolved to their targets: that
/// keeps the arguments, working directory and "run as" flags the installer chose,
/// and avoids needing COM for IShellLink.
void ScanShortcuts(const std::wstring& dir, std::vector<AppEntry>& out, int depth) {
    if (depth > 4) {
        return;
    }
    WIN32_FIND_DATAW found{};
    HANDLE handle = FindFirstFileW((dir + L"\\*").c_str(), &found);
    if (handle == INVALID_HANDLE_VALUE) {
        return;
    }
    do {
        const std::wstring name = found.cFileName;
        if (name == L"." || name == L"..") {
            continue;
        }
        const std::wstring full = dir + L"\\" + name;
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            ScanShortcuts(full, out, depth + 1);
            continue;
        }
        if (name.size() <= 4 || _wcsicmp(name.c_str() + name.size() - 4, L".lnk") != 0) {
            continue;
        }
        const std::wstring stem = name.substr(0, name.size() - 4);
        std::wstring lowered = stem;
        std::transform(lowered.begin(), lowered.end(), lowered.begin(), ::towlower);
        // Nobody wants to stream an uninstaller, and clicking one by accident
        // from a list of application names would be genuinely bad.
        if (lowered.find(L"uninstall") != std::wstring::npos) {
            continue;
        }
        out.push_back(AppEntry{ToUtf8(stem), full});
    } while (FindNextFileW(handle, &found));
    FindClose(handle);
}

std::vector<AppEntry> EnumerateApps() {
    std::vector<AppEntry> apps;
    wchar_t buffer[MAX_PATH] = {};
    const wchar_t* roots[] = {L"ProgramData", L"APPDATA"};
    for (const wchar_t* root : roots) {
        if (GetEnvironmentVariableW(root, buffer, MAX_PATH)) {
            ScanShortcuts(std::wstring(buffer) + L"\\Microsoft\\Windows\\Start Menu\\Programs",
                          apps, 0);
        }
    }
    std::sort(apps.begin(), apps.end(), [](const AppEntry& a, const AppEntry& b) {
        return _stricmp(a.name.c_str(), b.name.c_str()) < 0;
    });
    // The per-user and all-users trees overlap heavily.
    apps.erase(std::unique(apps.begin(), apps.end(), [](const AppEntry& a, const AppEntry& b) {
        return _stricmp(a.name.c_str(), b.name.c_str()) == 0;
    }), apps.end());
    return apps;
}

/// Start an application and return the window it opens.
///
/// Matching on the launched process id alone is not enough: plenty of shortcuts
/// run a stub that spawns the real process, so the window that appears belongs to
/// a different pid. So take a snapshot first and watch for a window that was not
/// there before, preferring a pid match while there is still time to wait for one.
uint64_t LaunchAndWaitForWindow(const std::wstring& path, DWORD timeout_ms) {
    std::set<HWND> before;
    for (const WindowInfo& window : EnumerateWindows()) {
        before.insert(window.handle);
    }
    const HWND foreground_before = GetForegroundWindow();

    SHELLEXECUTEINFOW request{};
    request.cbSize = sizeof(request);
    request.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    request.lpVerb = L"open";
    request.lpFile = path.c_str();
    request.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&request)) {
        Log("[agent] ShellExecuteEx failed: %lu", GetLastError());
        return 0;
    }
    DWORD launched_pid = 0;
    if (request.hProcess) {
        launched_pid = GetProcessId(request.hProcess);
        CloseHandle(request.hProcess);
    }

    const ULONGLONG start = GetTickCount64();
    const ULONGLONG deadline = start + timeout_ms;
    HWND fallback = nullptr;
    ULONGLONG fallback_seen = 0;
    while (GetTickCount64() < deadline) {
        Sleep(250);
        for (const WindowInfo& window : EnumerateWindows()) {
            if (before.count(window.handle)) {
                continue;
            }
            if (launched_pid && window.pid == launched_pid) {
                return IdFromWindow(window.handle);
            }
            if (!fallback) {
                fallback = window.handle;
                fallback_seen = GetTickCount64();
            }
        }
        // Give the exact match a moment to show up, then take what we have
        // rather than sitting out the whole timeout for a stub launcher.
        if (fallback && GetTickCount64() - fallback_seen > 3000) {
            return IdFromWindow(fallback);
        }

        // No new window may be the correct outcome rather than a failure: an
        // application that is already running usually reuses its window —
        // Explorer opens a tab in the existing one, and single-instance
        // applications just raise theirs. Starting an application does always
        // bring its window forward, so a foreground window that changed is very
        // probably the one the user asked for. Waited on for a few seconds so a
        // genuinely new window still wins if one is on its way.
        if (!fallback && GetTickCount64() - start > 4000) {
            const HWND foreground = GetForegroundWindow();
            if (foreground && foreground != foreground_before && IsUserWindow(foreground)) {
                Log("[agent] no new window; taking the newly focused one instead");
                return IdFromWindow(foreground);
            }
        }
    }
    return fallback ? IdFromWindow(fallback) : 0;
}

// ── Sunshine pairing ─────────────────────────────────────────────────────────
//
// Sunshine pairs by showing a PIN on the client and having a human type it into
// Sunshine's web UI on the host. For a non-technical user that means a browser, a
// self-signed-certificate warning, creating web UI credentials, and finding the
// PIN page — which is where most people give up.
//
// The agent already runs on the host, so it can do that step itself: the Mac
// sends the PIN it is displaying and the agent POSTs it to Sunshine's own local
// API. Reading confighttp.cpp, /api/pin needs HTTP Basic auth, and its CSRF check
// is skipped outright for requests carrying neither Origin nor Referer — those
// cannot be browser-initiated, so a non-browser client needs no token.
//
// Sunshine stores only a salted hash of its web UI password, so the plaintext
// cannot be recovered from disk. It is supplied once via
// --set-sunshine-credentials and kept encrypted with DPAPI, which ties it to this
// Windows user account: another account on the same machine cannot read it.

std::wstring CredentialPath(bool create_directory) {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    if (create_directory) {
        CreateDirectoryW(dir.c_str(), nullptr);
    }
    return dir + L"\\sunshine.cred";
}

bool StoreSunshineCredentials(const std::string& user, const std::string& password) {
    const std::wstring path = CredentialPath(true);
    if (path.empty()) {
        return false;
    }
    std::string plain = user;
    plain.push_back('\n');
    plain += password;

    DATA_BLOB in{static_cast<DWORD>(plain.size()), reinterpret_cast<BYTE*>(plain.data())};
    DATA_BLOB out{};
    if (!CryptProtectData(&in, L"SolStream Sunshine credentials", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        Log("[agent] CryptProtectData failed: %lu", GetLastError());
        return false;
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    bool ok = false;
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        ok = WriteFile(file, out.pbData, out.cbData, &written, nullptr) && written == out.cbData;
        CloseHandle(file);
    }
    SecureZeroMemory(plain.data(), plain.size());
    LocalFree(out.pbData);
    return ok;
}

bool LoadSunshineCredentials(std::string& user, std::string& password) {
    const std::wstring path = CredentialPath(false);
    if (path.empty()) {
        return false;
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    LARGE_INTEGER size{};
    std::vector<BYTE> encrypted;
    if (GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart < (1 << 20)) {
        encrypted.resize(static_cast<size_t>(size.QuadPart));
        DWORD read = 0;
        if (!ReadFile(file, encrypted.data(), (DWORD) encrypted.size(), &read, nullptr)
            || read != encrypted.size()) {
            encrypted.clear();
        }
    }
    CloseHandle(file);
    if (encrypted.empty()) {
        return false;
    }

    DATA_BLOB in{static_cast<DWORD>(encrypted.size()), encrypted.data()};
    DATA_BLOB out{};
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        Log("[agent] CryptUnprotectData failed: %lu", GetLastError());
        return false;
    }
    const std::string plain(reinterpret_cast<char*>(out.pbData), out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);

    const size_t split = plain.find('\n');
    if (split == std::string::npos) {
        return false;
    }
    user = plain.substr(0, split);
    password = plain.substr(split + 1);
    return !user.empty() && !password.empty();
}

std::string Base64(const std::string& raw) {
    DWORD needed = 0;
    if (!CryptBinaryToStringA(reinterpret_cast<const BYTE*>(raw.data()), (DWORD) raw.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &needed)) {
        return {};
    }
    std::string out(needed, '\0');
    if (!CryptBinaryToStringA(reinterpret_cast<const BYTE*>(raw.data()), (DWORD) raw.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &needed)) {
        return {};
    }
    out.resize(strlen(out.c_str()));
    return out;
}

struct HttpResult {
    bool sent = false;
    DWORD status = 0;
    std::string body;
    std::string error;
};

/// POST to Sunshine's config API on loopback.
HttpResult PostToSunshine(const wchar_t* path, const std::string& body,
                          const std::string& user, const std::string& password,
                          INTERNET_PORT port) {
    HttpResult result;
    HINTERNET session = WinHttpOpen(L"SolStreamAgent/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        result.error = "WinHttpOpen failed";
        return result;
    }
    HINTERNET connection = WinHttpConnect(session, L"127.0.0.1", port, 0);
    HINTERNET request = connection
        ? WinHttpOpenRequest(connection, L"POST", path, nullptr, WINHTTP_NO_REFERER,
                             WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE)
        : nullptr;
    if (!request) {
        result.error = "could not open a request to Sunshine";
        if (connection) WinHttpCloseHandle(connection);
        WinHttpCloseHandle(session);
        return result;
    }

    // Sunshine's web UI serves a self-signed certificate. Validation is waived
    // only because this connection never leaves the loopback interface.
    DWORD security = SECURITY_FLAG_IGNORE_UNKNOWN_CA | SECURITY_FLAG_IGNORE_CERT_CN_INVALID
                   | SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
    WinHttpSetOption(request, WINHTTP_OPTION_SECURITY_FLAGS, &security, sizeof(security));

    // No Origin and no Referer, deliberately: that is what lets Sunshine skip its
    // CSRF check for a non-browser client.
    const std::string headers = "Content-Type: application/json\r\nAuthorization: Basic "
                                + Base64(user + ":" + password) + "\r\n";
    const std::wstring wide_headers = ToWide(headers);
    WinHttpAddRequestHeaders(request, wide_headers.c_str(), (DWORD) -1L,
                             WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);

    if (WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           const_cast<char*>(body.data()), (DWORD) body.size(),
                           (DWORD) body.size(), 0)
        && WinHttpReceiveResponse(request, nullptr)) {
        result.sent = true;
        DWORD status = 0;
        DWORD length = sizeof(status);
        WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                            WINHTTP_HEADER_NAME_BY_INDEX, &status, &length, WINHTTP_NO_HEADER_INDEX);
        result.status = status;
        for (;;) {
            DWORD available = 0;
            if (!WinHttpQueryDataAvailable(request, &available) || available == 0) {
                break;
            }
            std::string chunk(available, '\0');
            DWORD read = 0;
            if (!WinHttpReadData(request, chunk.data(), available, &read) || read == 0) {
                break;
            }
            chunk.resize(read);
            result.body += chunk;
            if (result.body.size() > 64 * 1024) {
                break;
            }
        }
    } else {
        result.error = "Sunshine did not answer on 127.0.0.1:" + std::to_string(port)
                     + " (error " + std::to_string(GetLastError()) + ")";
    }

    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connection);
    WinHttpCloseHandle(session);
    return result;
}

/// Hand a client's pairing PIN to Sunshine, so nobody has to open its web UI.
std::string PairJson(const std::string& pin, const std::string& name, INTERNET_PORT port) {
    std::string user, password;
    if (!LoadSunshineCredentials(user, password)) {
        return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"no-credentials\","
               "\"message\":\"No Sunshine credentials stored. Run "
               "SolStreamAgent.exe --set-sunshine-credentials on the host once.\"}";
    }
    const std::string body = "{\"pin\":\"" + JsonEscape(pin) + "\",\"name\":\""
                           + JsonEscape(name) + "\"}";
    const HttpResult reply = PostToSunshine(L"/api/pin", body, user, password, port);
    SecureZeroMemory(password.data(), password.size());

    if (!reply.sent) {
        return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"unreachable\",\"message\":\""
               + JsonEscape(reply.error) + "\"}";
    }
    if (reply.status == 401) {
        return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"bad-credentials\","
               "\"message\":\"Sunshine rejected the stored credentials.\"}";
    }
    // nvhttp::pin returns false when no client is actually waiting to pair, which
    // still comes back as HTTP 200 — so the body decides, not the status.
    const bool ok = reply.status == 200 && reply.body.find("\"status\":true") != std::string::npos;
    Log("[agent] pair pin -> HTTP %lu %s", reply.status, ok ? "accepted" : "rejected");
    if (ok) {
        return "{\"type\":\"paired\",\"ok\":true}";
    }
    return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"refused\",\"message\":\""
           + JsonEscape(reply.body.substr(0, 200)) + "\"}";
}

// ── Placement ────────────────────────────────────────────────────────────────

/// Place a window so its CLIENT AREA lands exactly on the requested rectangle.
///
/// The caller cares about the client area, because that is what gets cropped
/// out of the stream — but SetWindowPos positions the whole window including
/// its frame. So measure the current difference between the two and offset by
/// it. Measuring beats computing from AdjustWindowRect, which does not know
/// about DPI scaling, custom frames, or DWM's invisible borders.
bool PlaceClientArea(HWND window, int x, int y, int width, int height) {
    if (IsIconic(window)) {
        ShowWindow(window, SW_RESTORE);
    }

    const RECT frame_before = VisibleFrame(window);
    const RECT client_before = ClientAreaInScreen(window);

    const int border_left = client_before.left - frame_before.left;
    const int border_top = client_before.top - frame_before.top;
    const int border_width = (frame_before.right - frame_before.left)
                           - (client_before.right - client_before.left);
    const int border_height = (frame_before.bottom - frame_before.top)
                            - (client_before.bottom - client_before.top);

    // GetWindowRect (what SetWindowPos speaks) may differ from the visible
    // frame by the invisible resize border; carry that across too.
    RECT window_rect{};
    GetWindowRect(window, &window_rect);
    const int shadow_left = frame_before.left - window_rect.left;
    const int shadow_top = frame_before.top - window_rect.top;
    const int shadow_width = (window_rect.right - window_rect.left)
                           - (frame_before.right - frame_before.left);
    const int shadow_height = (window_rect.bottom - window_rect.top)
                            - (frame_before.bottom - frame_before.top);

    const int target_x = x - border_left - shadow_left;
    const int target_y = y - border_top - shadow_top;
    const int target_w = width + border_width + shadow_width;
    const int target_h = height + border_height + shadow_height;

    return SetWindowPos(window, nullptr, target_x, target_y, target_w, target_h,
                        SWP_NOZORDER | SWP_NOACTIVATE) != FALSE;
}

// ── JSON output ──────────────────────────────────────────────────────────────

std::string DisplaysJson(const std::vector<Display>& displays) {
    std::string out = "{\"type\":\"displays\",\"displays\":[";
    for (size_t i = 0; i < displays.size(); ++i) {
        const Display& display = displays[i];
        char buffer[1024];
        std::snprintf(buffer, sizeof(buffer),
                      "%s{\"name\":\"%s\",\"adapter\":\"%s\",\"x\":%ld,\"y\":%ld,"
                      "\"w\":%ld,\"h\":%ld,\"primary\":%s}",
                      i ? "," : "",
                      JsonEscape(display.device_name).c_str(),
                      JsonEscape(display.adapter).c_str(),
                      display.bounds.left, display.bounds.top,
                      display.bounds.right - display.bounds.left,
                      display.bounds.bottom - display.bounds.top,
                      display.primary ? "true" : "false");
        out += buffer;
    }
    out += "]}";
    return out;
}

std::string WindowsJson(const std::vector<WindowInfo>& windows) {
    std::string out = "{\"type\":\"windows\",\"windows\":[";
    for (size_t i = 0; i < windows.size(); ++i) {
        const WindowInfo& window = windows[i];
        std::string entry = i ? "," : "";
        entry += "{\"id\":";
        entry += std::to_string(static_cast<uint64_t>(reinterpret_cast<uintptr_t>(window.handle)));
        entry += ",\"pid\":" + std::to_string(window.pid);
        entry += ",\"title\":\"" + JsonEscape(window.title) + "\"";
        entry += ",\"class\":\"" + JsonEscape(window.class_name) + "\"";
        entry += ",\"x\":" + std::to_string(window.client.left);
        entry += ",\"y\":" + std::to_string(window.client.top);
        entry += ",\"w\":" + std::to_string(window.client.right - window.client.left);
        entry += ",\"h\":" + std::to_string(window.client.bottom - window.client.top);
        entry += ",\"exStyle\":" + std::to_string(
            (unsigned long) GetWindowLongPtrW(window.handle, GWL_EXSTYLE));
        entry += ",\"captionInset\":" + std::to_string(window.caption_inset);
        entry += ",\"occluded\":" + std::string(window.occluded ? "true" : "false");
        if (window.occluded) {
            entry += ",\"occludedBy\":\"" + JsonEscape(window.occluded_by) + "\"";
        }
        entry += "}";
        out += entry;
    }
    out += "]}";
    return out;
}

std::string AppsJson(const std::vector<AppEntry>& apps) {
    std::string out = "{\"type\":\"apps\",\"apps\":[";
    for (size_t i = 0; i < apps.size(); ++i) {
        out += i ? "," : "";
        out += "{\"name\":\"" + JsonEscape(apps[i].name) + "\"";
        out += ",\"path\":\"" + JsonEscape(ToUtf8(apps[i].path)) + "\"}";
    }
    out += "]}";
    return out;
}

/// One window's live state, for the Mac to poll.
///
/// `alive` is the whole point: a window whose caption buttons reach the stream
/// can be closed from inside it, and the Mac has to notice and tear the session
/// down. It is deliberately based on the handle still existing rather than on
/// the window being enumerable — minimising an application must not look like
/// quitting it.
std::string WindowStatusJson(uint64_t id) {
    HWND handle = WindowFromId(id);
    if (!handle) {
        return "{\"type\":\"window\",\"id\":" + std::to_string(id) + ",\"alive\":false}";
    }
    const RECT client = ClientAreaInScreen(handle);
    const RECT frame = VisibleFrame(handle);
    std::string out = "{\"type\":\"window\",\"id\":" + std::to_string(id);
    out += ",\"alive\":true";
    out += ",\"minimized\":" + std::string(IsIconic(handle) ? "true" : "false");
    out += ",\"x\":" + std::to_string(client.left);
    out += ",\"y\":" + std::to_string(client.top);
    out += ",\"w\":" + std::to_string(client.right - client.left);
    out += ",\"h\":" + std::to_string(client.bottom - client.top);
    out += ",\"captionInset\":" + std::to_string((int) std::max(0L, client.top - frame.top));
    out += "}";
    return out;
}

// ── Tiny request parsing ─────────────────────────────────────────────────────
//
// The command set is small and fixed, so a full JSON parser would be more
// surface area than the protocol itself. Extract by key instead.

/// Extract a JSON string value, honouring escapes.
///
/// The escape handling is not decoration. Every string the Mac sends us is full
/// of backslashes — Windows device names like \\.\DISPLAY7 and shortcut paths
/// like C:\Users\... — and JSON doubles every one of them on the wire. Taking the
/// raw substring gives back the doubled form, and it also stops at the first
/// quote, so any window title containing one truncates.
///
/// Path arguments survived that for a while because Windows collapses duplicate
/// separators, so C:\\Users\\x opens the same file as C:\Users\x. Device names do
/// not: they are matched literally, and \\\\.\\DISPLAY7 resolves to nothing at
/// all.
bool FieldString(const std::string& json, const char* key, std::string& out) {
    const std::string needle = std::string("\"") + key + "\"";
    size_t at = json.find(needle);
    if (at == std::string::npos) {
        return false;
    }
    at = json.find(':', at + needle.size());
    if (at == std::string::npos) {
        return false;
    }
    at = json.find('"', at);
    if (at == std::string::npos) {
        return false;
    }

    std::string value;
    for (size_t i = at + 1; i < json.size(); ++i) {
        const char c = json[i];
        if (c == '"') {
            out = std::move(value);
            return true;
        }
        if (c != '\\') {
            value.push_back(c);
            continue;
        }
        if (++i >= json.size()) {
            return false;
        }
        switch (json[i]) {
            case '"':  value.push_back('"');  break;
            case '\\': value.push_back('\\'); break;
            case '/':  value.push_back('/');  break;
            case 'b':  value.push_back('\b'); break;
            case 'f':  value.push_back('\f'); break;
            case 'n':  value.push_back('\n'); break;
            case 'r':  value.push_back('\r'); break;
            case 't':  value.push_back('\t'); break;
            case 'u': {
                if (i + 4 >= json.size()) {
                    return false;
                }
                unsigned code = 0;
                for (int k = 1; k <= 4; ++k) {
                    const char digit = json[i + k];
                    code <<= 4;
                    if (digit >= '0' && digit <= '9') {
                        code |= static_cast<unsigned>(digit - '0');
                    } else if (digit >= 'a' && digit <= 'f') {
                        code |= static_cast<unsigned>(digit - 'a' + 10);
                    } else if (digit >= 'A' && digit <= 'F') {
                        code |= static_cast<unsigned>(digit - 'A' + 10);
                    } else {
                        return false;
                    }
                }
                i += 4;
                // UTF-8, without reassembling surrogate pairs: nothing we parse
                // carries characters outside the basic multilingual plane.
                if (code < 0x80) {
                    value.push_back(static_cast<char>(code));
                } else if (code < 0x800) {
                    value.push_back(static_cast<char>(0xC0 | (code >> 6)));
                    value.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                } else {
                    value.push_back(static_cast<char>(0xE0 | (code >> 12)));
                    value.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                    value.push_back(static_cast<char>(0x80 | (code & 0x3F)));
                }
                break;
            }
            default:
                return false;
        }
    }
    return false;
}

bool FieldNumber(const std::string& json, const char* key, long long& out) {
    const std::string needle = std::string("\"") + key + "\"";
    size_t at = json.find(needle);
    if (at == std::string::npos) {
        return false;
    }
    at = json.find(':', at + needle.size());
    if (at == std::string::npos) {
        return false;
    }
    ++at;
    while (at < json.size() && (json[at] == ' ' || json[at] == '\t')) {
        ++at;
    }
    size_t end = at;
    if (end < json.size() && (json[end] == '-' || json[end] == '+')) {
        ++end;
    }
    while (end < json.size() && json[end] >= '0' && json[end] <= '9') {
        ++end;
    }
    if (end == at) {
        return false;
    }
    // std::stoll throws on a sign with no digits and on values that do not fit,
    // and an uncaught exception here would terminate the agent on one malformed
    // line. strtoll reports both cases through errno instead.
    const std::string digits = json.substr(at, end - at);
    errno = 0;
    char* stop = nullptr;
    const long long value = std::strtoll(digits.c_str(), &stop, 10);
    if (errno == ERANGE || stop == digits.c_str()) {
        return false;
    }
    out = value;
    return true;
}

std::string HandleCommand(const std::string& line) {
    std::string command;
    if (!FieldString(line, "cmd", command)) {
        return "{\"type\":\"error\",\"message\":\"missing cmd\"}";
    }

    if (command == "displays") {
        return DisplaysJson(EnumerateDisplays());
    }

    if (command == "windows") {
        return WindowsJson(EnumerateWindows());
    }

    if (command == "apps") {
        return AppsJson(EnumerateApps());
    }

    if (command == "canvas") {
        std::string device;
        long long want_w = 0, want_h = 0;
        if (!FieldString(line, "display", device)
            || !FieldNumber(line, "w", want_w) || !FieldNumber(line, "h", want_h)) {
            return "{\"type\":\"error\",\"message\":\"canvas needs display,w,h\"}";
        }
        if (want_w < 640 || want_h < 480 || want_w > 8192 || want_h > 8192) {
            return "{\"type\":\"error\",\"message\":\"canvas size out of range\"}";
        }
        int got_w = 0, got_h = 0;
        if (!SetDisplayMode(ToWide(device), (int) want_w, (int) want_h, got_w, got_h)) {
            return "{\"type\":\"canvas\",\"ok\":false,\"message\":\"could not set a display mode\"}";
        }
        char buffer[192];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"canvas\",\"ok\":true,\"w\":%d,\"h\":%d}", got_w, got_h);
        return buffer;
    }

    if (command == "pair") {
        std::string pin;
        if (!FieldString(line, "pin", pin)) {
            return "{\"type\":\"error\",\"message\":\"pair needs pin\"}";
        }
        std::string name;
        FieldString(line, "name", name);
        if (name.empty()) {
            name = "SolStream client";
        }
        return PairJson(pin, name, g_sunshine_web_port);
    }

    if (command == "window") {
        long long id = 0;
        if (!FieldNumber(line, "id", id)) {
            return "{\"type\":\"error\",\"message\":\"window needs id\"}";
        }
        return WindowStatusJson(static_cast<uint64_t>(id));
    }

    if (command == "launch") {
        std::string path;
        if (!FieldString(line, "path", path)) {
            return "{\"type\":\"error\",\"message\":\"launch needs path\"}";
        }
        long long timeout = 20000;
        FieldNumber(line, "timeoutMs", timeout);
        timeout = std::min<long long>(std::max<long long>(timeout, 1000), 60000);
        // This blocks until the application shows a window. The agent serves one
        // client at a time, so nothing else is waiting on it, and the alternative
        // — returning immediately and making the Mac poll for an unidentified
        // new window — just moves the same matching problem across the wire.
        const uint64_t id = LaunchAndWaitForWindow(ToWide(path), (DWORD) timeout);
        if (id == 0) {
            return "{\"type\":\"error\",\"message\":\"launched, but no window appeared\"}";
        }
        Log("[agent] launched %s -> window %llu", path.c_str(), (unsigned long long) id);
        return WindowStatusJson(id);
    }

    if (command == "place") {
        long long id = 0, x = 0, y = 0, w = 0, h = 0;
        if (!FieldNumber(line, "id", id) || !FieldNumber(line, "x", x) ||
            !FieldNumber(line, "y", y) || !FieldNumber(line, "w", w) ||
            !FieldNumber(line, "h", h)) {
            return "{\"type\":\"error\",\"message\":\"place needs id,x,y,w,h\"}";
        }
        HWND window = WindowFromId(static_cast<uint64_t>(id));
        if (!window) {
            return "{\"type\":\"error\",\"message\":\"no such window\"}";
        }
        const bool ok = PlaceClientArea(window, (int) x, (int) y, (int) w, (int) h);
        const RECT client = ClientAreaInScreen(window);
        char buffer[256];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"placed\",\"ok\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld}",
                      ok ? "true" : "false",
                      client.left, client.top,
                      client.right - client.left, client.bottom - client.top);
        return buffer;
    }

    if (command == "topmost") {
        long long id = 0, on = 1;
        if (!FieldNumber(line, "id", id)) {
            return "{\"type\":\"error\",\"message\":\"topmost needs id\"}";
        }
        FieldNumber(line, "on", on);
        HWND window = WindowFromId(static_cast<uint64_t>(id));
        if (!window) {
            return "{\"type\":\"error\",\"message\":\"no such window\"}";
        }
        // Pinning a managed window above ordinary ones stops other apps
        // covering the tile. Safe for our own tiles because they never
        // overlap each other.
        const BOOL ok = SetWindowPos(window, on ? HWND_TOPMOST : HWND_NOTOPMOST,
                                     0, 0, 0, 0,
                                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        char buffer[96];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"topmost\",\"ok\":%s,\"on\":%s}",
                      ok ? "true" : "false", on ? "true" : "false");
        return buffer;
    }

    if (command == "focus") {
        long long id = 0;
        if (!FieldNumber(line, "id", id)) {
            return "{\"type\":\"error\",\"message\":\"focus needs id\"}";
        }
        HWND window = WindowFromId(static_cast<uint64_t>(id));
        if (!window) {
            return "{\"type\":\"error\",\"message\":\"no such window\"}";
        }

        // SetForegroundWindow alone is unreliable: Windows refuses foreground
        // changes requested by a process that does not own the foreground, so
        // it silently fails whenever a modal dialog or another app holds it.
        // Raising in the Z-order is not subject to that restriction and is what
        // actually matters for capture, so do that first and unconditionally.
        if (IsIconic(window)) {
            ShowWindow(window, SW_RESTORE);
        }
        SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        BringWindowToTop(window);
        const BOOL foreground = SetForegroundWindow(window);

        char buffer[128];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"focused\",\"ok\":true,\"foreground\":%s}",
                      foreground ? "true" : "false");
        return buffer;
    }

    return "{\"type\":\"error\",\"message\":\"unknown cmd\"}";
}

// ── Server ───────────────────────────────────────────────────────────────────

bool SendLine(SOCKET client, const std::string& text) {
    std::string payload = text;
    payload += '\n';
    size_t sent = 0;
    while (sent < payload.size()) {
        const int n = send(client, payload.data() + sent, (int) (payload.size() - sent), 0);
        if (n <= 0) {
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    return true;
}

void ServeClient(SOCKET client) {
    // Without a receive timeout a peer that vanishes without a FIN (sleep, VPN
    // drop, cable pull) leaves this blocked in recv forever, and because the
    // accept loop is single-client the agent never serves anyone again.
    DWORD timeout_ms = 30000;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char*) &timeout_ms, sizeof(timeout_ms));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, (const char*) &timeout_ms, sizeof(timeout_ms));
    BOOL keepalive = TRUE;
    setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, (const char*) &keepalive, sizeof(keepalive));

    // Greet with the protocol version and the display list, so the Mac can pick
    // its capture display without a round trip.
    char hostname[256] = {};
    DWORD hostname_size = sizeof(hostname);
    GetComputerNameA(hostname, &hostname_size);

    std::string hello = "{\"type\":\"hello\",\"version\":";
    hello += std::to_string(kProtocolVersion);
    hello += ",\"host\":\"" + JsonEscape(hostname) + "\"}";
    if (!SendLine(client, hello) || !SendLine(client, DisplaysJson(EnumerateDisplays()))) {
        return;
    }

    std::string buffer;
    char chunk[4096];
    for (;;) {
        const int n = recv(client, chunk, sizeof(chunk), 0);
        if (n == SOCKET_ERROR && WSAGetLastError() == WSAETIMEDOUT) {
            Log("[agent] client idle for 30s, dropping");
            return;
        }
        if (n <= 0) {
            return;
        }
        buffer.append(chunk, static_cast<size_t>(n));

        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            std::string line = buffer.substr(0, newline);
            buffer.erase(0, newline + 1);
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            if (line.empty()) {
                continue;
            }
            if (!SendLine(client, HandleCommand(line))) {
                return;
            }
        }

        // A client that never sends a newline must not grow this unbounded.
        if (buffer.size() > 64 * 1024) {
            Log("[agent] oversized request, dropping client");
            return;
        }
    }
}

}  // namespace

/// Read one line from stdin without echoing it, for the password prompt.
std::string ReadLineHidden() {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0;
    const bool console = GetConsoleMode(input, &mode) != 0;
    if (console) {
        SetConsoleMode(input, mode & ~static_cast<DWORD>(ENABLE_ECHO_INPUT));
    }
    std::string line;
    int ch = 0;
    while ((ch = std::fgetc(stdin)) != EOF && ch != '\n') {
        if (ch != '\r') {
            line.push_back(static_cast<char>(ch));
        }
    }
    if (console) {
        SetConsoleMode(input, mode);
        std::fputs("\n", stdout);
    }
    return line;
}

/// One-time setup: remember Sunshine's web UI credentials so the agent can pair
/// clients on the user's behalf.
///
/// Prompted rather than taken as an argument, because a password on a command line
/// is visible to every process on the machine through the process list.
int SetSunshineCredentials() {
    std::fputs("Sunshine web UI username: ", stdout);
    std::fflush(stdout);
    std::string user;
    int ch = 0;
    while ((ch = std::fgetc(stdin)) != EOF && ch != '\n') {
        if (ch != '\r') {
            user.push_back(static_cast<char>(ch));
        }
    }
    std::fputs("Sunshine web UI password: ", stdout);
    std::fflush(stdout);
    const std::string password = ReadLineHidden();

    if (user.empty() || password.empty()) {
        std::fputs("Nothing stored: both a username and a password are required.\n", stderr);
        return 1;
    }
    if (!StoreSunshineCredentials(user, password)) {
        std::fputs("Could not store the credentials.\n", stderr);
        return 1;
    }

    // Prove they work now rather than failing later, mid-pairing. An empty PIN is
    // rejected by Sunshine, but only after it has checked the credentials — so a
    // 401 distinguishes bad credentials from a bad PIN.
    const HttpResult reply = PostToSunshine(L"/api/pin", "{\"pin\":\"\",\"name\":\"SolStream\"}",
                                            user, password, g_sunshine_web_port);
    if (!reply.sent) {
        std::fprintf(stdout, "Stored, but Sunshine could not be reached: %s\n", reply.error.c_str());
        return 0;
    }
    if (reply.status == 401) {
        std::fputs("Stored, but Sunshine REJECTED them. Re-run with the right ones.\n", stderr);
        return 1;
    }
    std::fputs("Stored and accepted by Sunshine. Pairing will no longer need the web UI.\n", stdout);
    return 0;
}

int wmain(int argc, wchar_t** argv) {
    unsigned short port = kDefaultPort;
    bool listen_all = false;
    bool set_credentials = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--port" && i + 1 < argc) {
            port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--sunshine-port" && i + 1 < argc) {
            g_sunshine_web_port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--listen-all") {
            listen_all = true;
        } else if (arg == L"--set-sunshine-credentials") {
            set_credentials = true;
        }
    }

    if (set_credentials) {
        return SetSunshineCredentials();
    }

    // Without this every coordinate we read or write is silently rescaled by
    // Windows' DPI virtualisation, and windows land in the wrong place on any
    // display that is not at 100%.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        Log("[agent] WSAStartup failed");
        return 1;
    }

    SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listener == INVALID_SOCKET) {
        Log("[agent] socket() failed: %d", WSAGetLastError());
        return 1;
    }

    BOOL reuse = TRUE;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, (const char*) &reuse, sizeof(reuse));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (listen_all) {
        address.sin_addr.s_addr = INADDR_ANY;
        Log("[agent] WARNING: listening on ALL interfaces. This socket is");
        Log("[agent] WARNING: unauthenticated and can move any window on this");
        Log("[agent] WARNING: machine. Prefer the default loopback bind.");
    } else {
        inet_pton(AF_INET, kLoopback, &address.sin_addr);
    }

    if (bind(listener, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        Log("[agent] bind(%u) failed: %d", port, WSAGetLastError());
        return 1;
    }
    if (listen(listener, 1) == SOCKET_ERROR) {
        Log("[agent] listen failed: %d", WSAGetLastError());
        return 1;
    }

    Log("[agent] SolStream agent v%d listening on %s:%u",
        kProtocolVersion, listen_all ? "0.0.0.0" : kLoopback, port);
    for (const Display& display : EnumerateDisplays()) {
        Log("[agent]   display %s %ldx%ld at (%ld,%ld)%s",
            display.device_name.c_str(),
            display.bounds.right - display.bounds.left,
            display.bounds.bottom - display.bounds.top,
            display.bounds.left, display.bounds.top,
            display.primary ? " [primary]" : "");
    }

    for (;;) {
        SOCKET client = accept(listener, nullptr, nullptr);
        if (client == INVALID_SOCKET) {
            Log("[agent] accept failed: %d", WSAGetLastError());
            continue;
        }
        Log("[agent] client connected");
        ServeClient(client);
        closesocket(client);
        Log("[agent] client disconnected");
    }
}
