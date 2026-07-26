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

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <cstdlib>
#include <cwchar>
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

// ── Tiny request parsing ─────────────────────────────────────────────────────
//
// The command set is small and fixed, so a full JSON parser would be more
// surface area than the protocol itself. Extract by key instead.

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
    const size_t end = json.find('"', at + 1);
    if (end == std::string::npos) {
        return false;
    }
    out = json.substr(at + 1, end - at - 1);
    return true;
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

int wmain(int argc, wchar_t** argv) {
    unsigned short port = kDefaultPort;
    bool listen_all = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--port" && i + 1 < argc) {
            port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--listen-all") {
            listen_all = true;
        }
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
