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

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <dwmapi.h>
#include <shellscalingapi.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace {

constexpr unsigned short kDefaultPort = 47997;
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
    RECT bounds{};
    bool primary = false;
};

BOOL CALLBACK MonitorProc(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
    auto* displays = reinterpret_cast<std::vector<Display>*>(param);

    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(monitor, &info)) {
        return TRUE;
    }

    Display display;
    display.device_name = ToUtf8(info.szDevice);
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
};

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

BOOL CALLBACK WindowProc(HWND window, LPARAM param) {
    if (!IsUserWindow(window)) {
        return TRUE;
    }
    auto* windows = reinterpret_cast<std::vector<WindowInfo>*>(param);

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

    windows->push_back(std::move(info));
    return TRUE;
}

std::vector<WindowInfo> EnumerateWindows() {
    std::vector<WindowInfo> windows;
    EnumWindows(WindowProc, reinterpret_cast<LPARAM>(&windows));
    return windows;
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
        char buffer[512];
        std::snprintf(buffer, sizeof(buffer),
                      "%s{\"name\":\"%s\",\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld,\"primary\":%s}",
                      i ? "," : "",
                      JsonEscape(display.device_name).c_str(),
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
    out = std::stoll(json.substr(at, end - at));
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

    if (command == "focus") {
        long long id = 0;
        if (!FieldNumber(line, "id", id)) {
            return "{\"type\":\"error\",\"message\":\"focus needs id\"}";
        }
        HWND window = WindowFromId(static_cast<uint64_t>(id));
        if (!window) {
            return "{\"type\":\"error\",\"message\":\"no such window\"}";
        }
        SetForegroundWindow(window);
        return "{\"type\":\"focused\",\"ok\":true}";
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
    for (int i = 1; i + 1 < argc; ++i) {
        if (std::wstring(argv[i]) == L"--port") {
            port = static_cast<unsigned short>(_wtoi(argv[i + 1]));
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
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    if (bind(listener, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        Log("[agent] bind(%u) failed: %d", port, WSAGetLastError());
        return 1;
    }
    if (listen(listener, 1) == SOCKET_ERROR) {
        Log("[agent] listen failed: %d", WSAGetLastError());
        return 1;
    }

    Log("[agent] SolStream agent v%d listening on port %u", kProtocolVersion, port);
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
