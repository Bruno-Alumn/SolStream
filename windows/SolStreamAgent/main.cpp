// SolStream Agent ΓÇö the Windows half of single-application streaming.
//
// It does one job: make a chosen application's window sit at a known,
// non-overlapping rectangle on a chosen display, and tell the Mac where it is.
// The Mac then crops that rectangle out of the single Sunshine stream and
// presents it as a native window.
//
// Deliberately plain Win32 ΓÇö SetWindowPos, EnumWindows, GetMonitorInfo, a
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
#include <tlhelp32.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <wincrypt.h>
#include <winhttp.h>
#include <bcrypt.h>

#include <algorithm>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cerrno>
#include <cstdlib>
#include <cwchar>
#include <cstring>
#include <cwctype>
#include <atomic>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "host_window.h"
#include "ports.h"
#include "sunshine_host.h"
#include "vdd.h"

namespace {

constexpr unsigned short kDefaultPort = solstream::kDefaultAgentPort;

// By default this socket is bound to loopback only and reached through an SSH
// tunnel; anywhere else a token is required. --listen-all is opt-in and warns.
constexpr const char* kLoopback = "127.0.0.1";
constexpr int kProtocolVersion = 1;

// Transport and payload budgets. These have to be picked together, and together
// with the matching pair in AgentConnection.swift, because the clipboard is the
// one command whose payload is sized by the user rather than by the protocol.
//
// JSON escaping can expand text sixfold ΓÇö a control byte becomes \u00xx ΓÇö so the
// line limit must clear six times the payload cap at both ends. Getting this
// wrong is not a truncated clipboard: whichever side hits its line cap first
// tears down the control channel mid-session.
constexpr size_t kMaxClipboardBytes = 256 * 1024;
constexpr size_t kMaxLineBytes = 4 * 1024 * 1024;

/// The base port SolStream's own Sunshine runs on. Everything Sunshine listens
/// on is this plus a fixed offset -- see ports.h, which the Mac mirrors.
unsigned short g_sunshine_base =
    solstream::kDefaultSunshineBase;
/// Sunshine's web UI / config API port, derived from the base.
unsigned short g_sunshine_web_port =
    solstream::MapPort(solstream::kDefaultSunshineBase, solstream::SunshinePort::kWebUi);
/// The display SolStream captures. Resolved at startup to the virtual one when
/// there is one, because a crop taken from a real monitor is a crop out of
/// somebody's actual screen.
std::wstring g_capture_display;
/// How many Macs are connected right now, for the window.
std::atomic<int> g_clients_connected{0};

// ΓöÇΓöÇ Logging ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(args);
}

// ΓöÇΓöÇ Text ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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
/// text ΓÇö quotes and backslashes in them would otherwise corrupt the stream.
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

// ΓöÇΓöÇ Displays ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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
/// immediate. Adding a mode to a virtual display is the expensive operation ΓÇö it
/// needs a device restart ΓÇö so the modes are seeded once at setup instead.
/// Picks the smallest mode that still covers the request, so the Mac's window is
/// never upscaled, and falls back to the largest available if nothing covers it.
bool SetDisplayMode(const std::wstring& device, int want_w, int want_h,
                    int& out_w, int& out_h, int& out_hz) {
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
        const long long largest_area =
            (long long) largest.dmPelsWidth * largest.dmPelsHeight;
        if (!have_largest || area > largest_area
            || (area == largest_area
                && mode.dmDisplayFrequency > largest.dmDisplayFrequency)) {
            largest = mode;
            have_largest = true;
        }
        if ((int) mode.dmPelsWidth < want_w || (int) mode.dmPelsHeight < want_h) {
            continue;
        }
        // Smallest area that still covers the request ΓÇö and, among equals, the
        // highest refresh rate. Ranking on area alone left the winner as
        // whichever mode the driver happened to enumerate first, and the virtual
        // display offers every resolution at every rate, so that was a coin toss
        // between 30 Hz and 120 Hz. The choice is then written with
        // CDS_UPDATEREGISTRY, so a bad flip persists; and since the early-out
        // below used to compare only width and height, nothing ever corrected
        // it. A display pinned at 30 Hz is indistinguishable, from the Mac, from
        // a network problem.
        const long long best_area = (long long) best.dmPelsWidth * best.dmPelsHeight;
        if (!have_best || area < best_area
            || (area == best_area && mode.dmDisplayFrequency > best.dmDisplayFrequency)) {
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
        && current.dmPelsHeight == best.dmPelsHeight
        // Refresh rate counts as "already there" too, or a display left pinned
        // at the wrong rate by an earlier run would never be corrected: the
        // resolution matches, so nothing would ever be applied again.
        && current.dmDisplayFrequency >= best.dmDisplayFrequency) {
        out_w = (int) current.dmPelsWidth;
        out_h = (int) current.dmPelsHeight;
        out_hz = (int) current.dmDisplayFrequency;
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
    out_hz = (int) best.dmDisplayFrequency;
    Log("[agent] display mode -> %dx%d @ %dHz", out_w, out_h, out_hz);
    return true;
}

// ΓöÇΓöÇ Windows ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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
    /// Chrome, Discord) reports 0 here ΓÇö and for those the buttons share a strip
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
            // built -- screen-sized, and almost entirely transparent. Treating
            // those as occluders reports a permanent false positive.
            //
            // It is also how a modern Windows dialog draws its shadow, so this
            // misses a real one: a Windows Security prompt about Sunshine sat
            // in the middle of a streamed window and nothing reported it.
            //
            // Tried and reverted: counting a layered window as an occluder when
            // it takes focus and does not span the screen. That is true of a
            // dialog, and also true of a background window this machine happens
            // to run called "AwsBuddyWindow" -- after which EVERY window on the
            // host reported as occluded, permanently. A warning pinned over
            // every stream forever is worse than missing an occasional dialog,
            // and the comment above had already learned this once.
            //
            // A correct test needs to know whether the pixels are actually
            // opaque, which neither the window styles nor the layered-window
            // attributes answer.
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
    // dialogs that IsUserWindow filters out of the reported list ΓÇö but only if
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
    // covers the most of the tile ΓÇö the first one found is not necessarily the
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

/// Actually give a window the keyboard focus, and say whether it worked.
///
/// SetForegroundWindow on its own is not enough. Windows refuses a foreground
/// change requested by a process that does not already own the foreground, and
/// the refusal is silent — the call returns FALSE and nothing happens. The
/// agent is a background process, so it is refused by default.
///
/// That matters far more than it sounds. Sunshine injects keystrokes with
/// SendInput, which delivers them to whatever window has the foreground on this
/// PC — not to the window we happen to be streaming. So a failed focus does not
/// mean "the window looks inactive": it means every key the user types goes
/// into a DIFFERENT application, invisibly, while the streamed one sits on
/// screen doing nothing. Measured: streaming an already-open terminal and then
/// switching to Character Map left the terminal foreground, and everything
/// typed at Character Map was fed to the terminal's command prompt instead.
///
/// The way out is AttachThreadInput. A thread sharing the foreground window's
/// input queue counts as owning the foreground, so the call is permitted; we
/// attach, ask, and detach again. Deliberately NOT used: the documented
/// alternative is to turn the foreground lock off system-wide with
/// SPI_SETFOREGROUNDLOCKTIMEOUT, which is the user's setting to make, not ours.
///
/// Returns what GetForegroundWindow actually says afterwards, never the result
/// of the request — the whole problem here is a call that claims nothing and
/// fails anyway.
bool ForceForeground(HWND window) {
    if (IsIconic(window)) {
        ShowWindow(window, SW_RESTORE);
    }
    // Z-order first, and unconditionally: raising is not subject to the
    // foreground restriction, and it is what capture needs even in the case
    // where focus cannot be won.
    SetWindowPos(window, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    BringWindowToTop(window);

    if (GetForegroundWindow() == window) {
        return true;
    }

    const DWORD self_thread = GetCurrentThreadId();
    const HWND holder = GetForegroundWindow();
    const DWORD holder_thread = holder ? GetWindowThreadProcessId(holder, nullptr) : 0;
    const bool attached = holder_thread && holder_thread != self_thread &&
                          AttachThreadInput(self_thread, holder_thread, TRUE);

    SetForegroundWindow(window);
    // Both, because they answer different questions: which top-level window is
    // active, and which control inside it takes the keys.
    SetActiveWindow(window);
    SetFocus(window);

    if (attached) {
        AttachThreadInput(self_thread, holder_thread, FALSE);
    }
    return GetForegroundWindow() == window;
}

// ΓöÇΓöÇ Launchable applications ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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

/// Is this one of the applications the agent itself advertised?
///
/// `launch` used to run whatever path arrived on the wire, which made the agent
/// socket a remote code execution primitive: one line of JSON naming
/// `\\attacker\share\payload.exe` ran it as the logged-in user, and `icon` would
/// happily reach the same UNC path and hand over a set of NTLM credentials on
/// the way. Checking against the list the agent just produced costs one
/// directory walk and removes the primitive rather than narrowing it ΓÇö there is
/// no path a client can name that the user could not have clicked in their own
/// Start Menu.
///
/// Deliberately an exact match against paths this process constructed, not a
/// prefix or extension test. There is no traversal to reason about, no
/// canonicalisation to get subtly wrong, and no argument about what `..` means
/// halfway through a UNC path.
///
/// Cached, because membership is asked once per icon and the picker asks for one
/// icon per row as rows scroll into view. Re-walking two Start Menu trees to
/// depth 4 for each of those put real disk I/O on the agent's single command
/// thread, and every other command queues behind it.
///
/// No lock: commands are served one at a time, on one thread.
std::set<std::wstring> g_advertised_paths;
DWORD g_advertised_at = 0;
constexpr DWORD kAdvertisedTtlMs = 5000;

std::wstring FoldCase(const std::wstring& text) {
    std::wstring lowered = text;
    std::transform(lowered.begin(), lowered.end(), lowered.begin(), ::towlower);
    return lowered;
}

void RememberAdvertised(const std::vector<AppEntry>& apps) {
    g_advertised_paths.clear();
    for (const AppEntry& app : apps) {
        g_advertised_paths.insert(FoldCase(app.path));
    }
    // Zero means "never populated", so nudge past it on the once-in-49-days
    // tick where GetTickCount returns 0.
    g_advertised_at = GetTickCount() | 1;
}

bool IsAdvertisedApp(const std::wstring& path) {
    const DWORD now = GetTickCount();
    if (g_advertised_at == 0 || now - g_advertised_at > kAdvertisedTtlMs) {
        RememberAdvertised(EnumerateApps());
    }
    return g_advertised_paths.count(FoldCase(path)) != 0;
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
        // application that is already running usually reuses its window ΓÇö
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

// ΓöÇΓöÇ Clipboard ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// Text only, and deliberately so. Images and files raise questions this does not
// need to answer yet ΓÇö how large is too large, what happens to a 2 GB file
// dropped on a link ΓÇö whereas text is what people actually copy between a Mac and
// a remote application all day.
//
// Implemented here rather than in the separate ClipboardMonitor daemon: that one
// stands up its own WebSocket server with no authentication, and the agent is
// already the one authenticated channel to this machine. A second open port for
// this would be a second thing to secure.

/// The clipboard is a shared, contended resource: another process can hold it
/// open, and OpenClipboard fails rather than waiting.
class ClipboardLock {
public:
    ClipboardLock() {
        for (int attempt = 0; attempt < 10 && !held_; ++attempt) {
            held_ = OpenClipboard(nullptr) != FALSE;
            if (!held_) {
                Sleep(20);
            }
        }
    }
    ~ClipboardLock() {
        if (held_) {
            CloseClipboard();
        }
    }
    bool held() const { return held_; }

    ClipboardLock(const ClipboardLock&) = delete;
    ClipboardLock& operator=(const ClipboardLock&) = delete;

private:
    bool held_ = false;
};

/// Bumped by Windows whenever anything changes the clipboard, so the Mac can poll
/// for "has it changed" without transferring the contents every time.
DWORD ClipboardSequence() {
    return GetClipboardSequenceNumber();
}

std::string ClipboardGetJson() {
    ClipboardLock lock;
    if (!lock.held()) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard busy\"}";
    }
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    if (!handle) {
        // Not an error: the clipboard may hold an image, or nothing.
        return "{\"type\":\"clipboard\",\"ok\":true,\"text\":\"\",\"seq\":"
             + std::to_string(ClipboardSequence()) + "}";
    }
    auto* wide = static_cast<const wchar_t*>(GlobalLock(handle));
    if (!wide) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"could not lock\"}";
    }
    std::string text = ToUtf8(wide);
    GlobalUnlock(handle);

    // A clipboard can hold a whole document; this channel is for text people
    // copy, not for bulk transfer.
    bool truncated = false;
    if (text.size() > kMaxClipboardBytes) {
        // Cut between codepoints, not at a byte offset. resize() alone can slice
        // a multi-byte character in half, and the Mac rejects the whole line as
        // malformed JSON ΓÇö losing the reply, not just the tail of the text.
        size_t cut = kMaxClipboardBytes;
        while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80) {
            --cut;
        }
        text.resize(cut);
        truncated = true;
    }
    return "{\"type\":\"clipboard\",\"ok\":true,\"seq\":" + std::to_string(ClipboardSequence())
         + ",\"truncated\":" + (truncated ? "true" : "false")
         + ",\"text\":\"" + JsonEscape(text) + "\"}";
}

std::string ClipboardSetJson(const std::string& text) {
    const std::wstring wide = ToWide(text);
    const size_t bytes = (wide.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"out of memory\"}";
    }
    if (void* target = GlobalLock(memory)) {
        std::memcpy(target, wide.c_str(), bytes);
        GlobalUnlock(memory);
    } else {
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"could not lock\"}";
    }

    ClipboardLock lock;
    if (!lock.held()) {
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard busy\"}";
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        // Ownership only transfers on success; on failure it is still ours.
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard rejected it\"}";
    }
    return "{\"type\":\"clipboard\",\"ok\":true,\"seq\":"
         + std::to_string(ClipboardSequence()) + "}";
}

// ΓöÇΓöÇ Icons ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// Sent as raw BGRA plus dimensions rather than PNG. Neither side then needs an
// image codec: the agent stays plain Win32 with no GDI+ lifetime to get wrong,
// and the Mac builds an NSImage straight from the bytes. An icon is a few KB, so
// the size difference does not matter over a LAN.

/// Render an HICON into a straight-alpha BGRA buffer.
///
/// Icons come back from Windows as two bitmaps ΓÇö colour and mask ΓÇö and the colour
/// one is only sometimes 32-bit with real alpha. Drawing onto a black DIB and
/// taking the mask into account handles both cases, which matters because the
/// 16-colour icons some old executables still carry would otherwise come out as
/// solid rectangles.
bool IconToBgra(HICON icon, int size, std::vector<unsigned char>& out) {
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = size;
    info.bmiHeader.biHeight = -size;  // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;

    HDC screen = GetDC(nullptr);
    if (!screen) {
        return false;
    }
    void* bits = nullptr;
    HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
    HDC memory = CreateCompatibleDC(screen);
    ReleaseDC(nullptr, screen);
    if (!bitmap || !memory || !bits) {
        if (bitmap) DeleteObject(bitmap);
        if (memory) DeleteDC(memory);
        return false;
    }
    HGDIOBJ previous = SelectObject(memory, bitmap);
    std::memset(bits, 0, static_cast<size_t>(size) * size * 4);
    const BOOL drawn = DrawIconEx(memory, 0, 0, icon, size, size, 0, nullptr, DI_NORMAL);
    SelectObject(memory, previous);

    if (drawn) {
        out.assign(static_cast<unsigned char*>(bits),
                   static_cast<unsigned char*>(bits) + static_cast<size_t>(size) * size * 4);
        // DrawIconEx leaves alpha at zero for icons without an alpha channel, which
        // would make them invisible. If nothing is opaque, treat any coloured pixel
        // as solid.
        bool anyAlpha = false;
        for (size_t i = 3; i < out.size(); i += 4) {
            if (out[i] != 0) { anyAlpha = true; break; }
        }
        if (!anyAlpha) {
            for (size_t i = 0; i < out.size(); i += 4) {
                const bool coloured = out[i] || out[i + 1] || out[i + 2];
                out[i + 3] = coloured ? 0xFF : 0x00;
            }
        }
    }
    DeleteObject(bitmap);
    DeleteDC(memory);
    return drawn != FALSE;
}

std::string Base64Encode(const std::vector<unsigned char>& bytes) {
    if (bytes.empty()) {
        return {};
    }
    DWORD needed = 0;
    if (!CryptBinaryToStringA(bytes.data(), (DWORD) bytes.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &needed)) {
        return {};
    }
    std::string out(needed, '\0');
    if (!CryptBinaryToStringA(bytes.data(), (DWORD) bytes.size(),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &needed)) {
        return {};
    }
    out.resize(strlen(out.c_str()));
    return out;
}

/// A window's own icon, asked for politely then taken from the class.
HICON WindowIcon(HWND window) {
    // WM_GETICON with a timeout: a hung application must not hang the agent.
    DWORD_PTR result = 0;
    for (WPARAM which : {static_cast<WPARAM>(ICON_BIG), static_cast<WPARAM>(ICON_SMALL2),
                         static_cast<WPARAM>(ICON_SMALL)}) {
        if (SendMessageTimeoutW(window, WM_GETICON, which, 0,
                                SMTO_ABORTIFHUNG | SMTO_BLOCK, 200, &result)
            && result) {
            return reinterpret_cast<HICON>(result);
        }
    }
    if (HICON fromClass = reinterpret_cast<HICON>(GetClassLongPtrW(window, GCLP_HICON))) {
        return fromClass;
    }
    return reinterpret_cast<HICON>(GetClassLongPtrW(window, GCLP_HICONSM));
}

constexpr int kIconSize = 64;

std::string IconJson(const std::string& id, HICON icon, bool destroy) {
    std::vector<unsigned char> bgra;
    const bool ok = icon && IconToBgra(icon, kIconSize, bgra);
    if (destroy && icon) {
        DestroyIcon(icon);
    }
    if (!ok) {
        return "{\"type\":\"icon\",\"ok\":false,\"id\":\"" + JsonEscape(id) + "\"}";
    }
    return "{\"type\":\"icon\",\"ok\":true,\"id\":\"" + JsonEscape(id) + "\",\"w\":"
         + std::to_string(kIconSize) + ",\"h\":" + std::to_string(kIconSize)
         + ",\"bgra\":\"" + Base64Encode(bgra) + "\"}";
}

// ΓöÇΓöÇ Authentication ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// This socket can enumerate and move every window on the machine and launch
// arbitrary applications. Binding a single trusted address limits who can reach
// it, which is worth doing, but reachability is not authentication: anything else
// on that network still gets in. So a client must present a shared token before
// any command is accepted.
//
// The token is generated on first run and kept in the user's own profile. It is
// not encrypted, deliberately ΓÇö the point is for the person at the machine to be
// able to read it and give it to their Mac.
//
// Plaintext over TCP means this authenticates the client to the host and nothing
// more: it does not encrypt the session or protect against someone who can read
// the traffic. On a home LAN or a VPN that is the right amount of security for
// what it guards. Do not mistake it for more than that.

std::string g_token;
bool g_require_auth = true;

std::wstring TokenPath() {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\agent.token";
}

std::string RandomToken() {
    unsigned char bytes[16] = {};
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        return {};
    }
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(sizeof(bytes) * 2);
    for (unsigned char byte : bytes) {
        out.push_back(hex[byte >> 4]);
        out.push_back(hex[byte & 0x0F]);
    }
    return out;
}

std::string LoadOrCreateToken() {
    const std::wstring path = TokenPath();
    if (path.empty()) {
        return {};
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        char buffer[128] = {};
        DWORD read = 0;
        const bool ok = ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr) && read > 0;
        CloseHandle(file);
        if (ok) {
            std::string existing(buffer, read);
            while (!existing.empty()
                   && (existing.back() == '\n' || existing.back() == '\r' || existing.back() == ' ')) {
                existing.pop_back();
            }
            if (existing.size() >= 16) {
                return existing;
            }
        }
    }

    const std::string fresh = RandomToken();
    if (fresh.empty()) {
        return {};
    }
    file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(file, fresh.data(), (DWORD) fresh.size(), &written, nullptr);
        CloseHandle(file);
    }
    return fresh;
}

/// Constant-time compare, so a wrong token cannot be found a character at a time
/// by timing the reply.
bool TokenMatches(const std::string& supplied) {
    if (supplied.size() != g_token.size() || g_token.empty()) {
        return false;
    }
    unsigned char difference = 0;
    for (size_t i = 0; i < g_token.size(); ++i) {
        difference |= static_cast<unsigned char>(supplied[i] ^ g_token[i]);
    }
    return difference == 0;
}

// ΓöÇΓöÇ Geometry lock ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// The Mac crops a FIXED rectangle out of the shared canvas, so a window resized
// on the host stops lining up with it and the stream shows desktop where the
// application used to be. Size has to be driven from the macOS window ΓÇö the thing
// the user is actually looking at ΓÇö and only from there.
//
// Two layers, because one is not enough. Removing WS_THICKFRAME and
// WS_MAXIMIZEBOX takes away the resize border and the maximise affordance, which
// closes the ordinary routes. That alone does not hold: an application drawing its
// own caption can still ask to be maximised, plenty do their own WM_NCHITTEST, and
// some resize themselves when their content changes. So a watcher also puts the
// window back whenever it moves or resizes anyway.

constexpr int kMaxLocks = 8;

// ── The push channel ─────────────────────────────────────────────────────────
//
// Two things the host has to volunteer rather than wait to be asked about: the
// cursor changing shape, and a streamed window being closed. Both go to the one
// authenticated client on the same socket the commands arrive on, and both must
// stay silent until that client has proved who it is — the display list is
// withheld for the same reason, and a notice that leaked the host's UI state to
// anyone who can open a socket would quietly undo it.

SOCKET g_push_client = INVALID_SOCKET;
volatile LONG g_push_authorised = 0;
/// Serialises writes to the client socket. Three threads send on it — the one
/// serving commands, the cursor watcher and the window watcher — and a line
/// interleaved with another is a line neither end can parse.
CRITICAL_SECTION g_send_cs;
bool SendLine(SOCKET client, const std::string& text);

struct WindowLock {
    HWND window = nullptr;
    RECT desired{};           // client area, in virtual-desktop coordinates
    LONG_PTR saved_style = 0;
    /// Who owned this window when the agent first touched it.
    ///
    /// Windows recycles window handles, so `IsWindow` on a handle whose window
    /// has been destroyed can come back true — pointing at something else
    /// entirely. Without this the watcher would go on enforcing a geometry,
    /// a topmost band and a stripped frame on an unrelated application, and the
    /// Mac would go on showing whatever now occupies those pixels rather than
    /// noticing that the thing it was streaming is gone.
    DWORD pid = 0;
    // How the window looked before the agent touched it. Everything the agent
    // changes has to be recorded, because the client that changed it may never
    // come back to change it again: a Mac that loses its network leaves the
    // window exactly as it was mid-session.
    WINDOWPLACEMENT saved_placement{};
    bool saved_topmost = false;
    bool geometry_locked = false;  // the watcher holds this one in place
    bool active = false;           // the agent owes this window a restore
};

CRITICAL_SECTION g_lock_cs;
WindowLock g_locks[kMaxLocks];
HANDLE g_watcher = nullptr;
volatile LONG g_watcher_stop = 0;

bool PlaceClientArea(HWND window, int x, int y, int width, int height);

/// How wide the window's resize grab area is, in pixels, at its own DPI.
///
/// The Mac keeps the pointer this far inside the crop so a drag can never start
/// a resize on the host. Read per-window rather than assumed: the streamed
/// display runs at a different scaling from the primary one, and the grab area
/// is in physical pixels, so a constant would be right on one monitor and wrong
/// on the other.
int ResizeBorderThickness(HWND window) {
    const UINT dpi = GetDpiForWindow(window);
    if (dpi == 0) {
        return GetSystemMetrics(SM_CXSIZEFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER);
    }
    return GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi)
         + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

/// The smallest client area this window will accept, in pixels.
///
/// Asked of the window rather than inferred from what it does. Watching for "we
/// asked for less and got more" sounds equivalent and is not: that is also what
/// every failed placement looks like, and mistaking one for a minimum latches a
/// floor the size of the whole display, which the Mac window then cannot be
/// dragged below.
///
/// WM_GETMINMAXINFO is prefilled the way Windows prefills it, so an application
/// that ignores the message still yields the system defaults rather than zeroes.
/// Sent with a timeout because it crosses into another process, and a hung
/// application must not take the agent with it.
POINT MinimumClientSize(HWND window) {
    MINMAXINFO info{};
    info.ptMinTrackSize.x = GetSystemMetrics(SM_CXMINTRACK);
    info.ptMinTrackSize.y = GetSystemMetrics(SM_CYMINTRACK);
    info.ptMaxTrackSize.x = GetSystemMetrics(SM_CXMAXTRACK);
    info.ptMaxTrackSize.y = GetSystemMetrics(SM_CYMAXTRACK);
    DWORD_PTR unused = 0;
    SendMessageTimeoutW(window, WM_GETMINMAXINFO, 0, (LPARAM) &info,
                        SMTO_ABORTIFHUNG | SMTO_BLOCK, 250, &unused);

    // ptMinTrackSize is a whole-window minimum; the crop is the client area, so
    // take the non-client furniture back off.
    RECT furniture{0, 0, 0, 0};
    AdjustWindowRectEx(&furniture,
                       (DWORD) GetWindowLongPtrW(window, GWL_STYLE), FALSE,
                       (DWORD) GetWindowLongPtrW(window, GWL_EXSTYLE));
    POINT minimum{};
    minimum.x = info.ptMinTrackSize.x - (furniture.right - furniture.left);
    minimum.y = info.ptMinTrackSize.y - (furniture.bottom - furniture.top);
    if (minimum.x < 1) { minimum.x = 1; }
    if (minimum.y < 1) { minimum.y = 1; }
    return minimum;
}

/// Has this slot's window gone?
///
/// A destroyed handle can be handed back out to a new window, so the process
/// that owns it has to agree as well. Call with `g_lock_cs` held.
bool SlotWindowGone(const WindowLock& lock) {
    if (!IsWindow(lock.window)) {
        return true;
    }
    if (lock.pid == 0) {
        return false;
    }
    DWORD owner = 0;
    GetWindowThreadProcessId(lock.window, &owner);
    return owner != lock.pid;
}

/// Tell the Mac a window it was streaming has been closed.
///
/// Pushed the moment the watcher notices, rather than left for the Mac's
/// once-a-second poll to discover. The poll is still there as a backstop, but a
/// window whose application has quit goes on showing the last frame it ever
/// sent until something says otherwise, and up to a second of a dead
/// application's corpse is a second too many.
void NotifyWindowClosed(uint64_t id) {
    if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
        return;
    }
    // Read the socket and write to it under the send lock, which the client's
    // departure also takes before clearing it. Unlike the cursor thread, this
    // watcher is never joined before the socket closes ΓÇö so without this the
    // handle could be closed and reissued to the *next* client between the read
    // and the send, and this line would land on somebody else's connection.
    // A CRITICAL_SECTION is recursive, so SendLine taking it again is fine.
    EnterCriticalSection(&g_send_cs);
    struct Unlock {
        ~Unlock() { LeaveCriticalSection(&g_send_cs); }
    } unlock;
    const SOCKET client = g_push_client;
    if (client == INVALID_SOCKET) {
        return;
    }
    // A failure means the client has gone, which the serving thread finds out
    // on its own recv. Nothing to do about it here.
    SendLine(client, "{\"type\":\"closed\",\"id\":" + std::to_string(id) + "}");
}

/// Say so when something on this PC takes the keyboard away from the window
/// being streamed.
///
/// Sunshine injects keystrokes into whatever holds the foreground *here*, not
/// into the window the Mac is showing. So a window that quietly takes the
/// foreground does not merely look wrong — it silently receives everything the
/// user types at their Mac, while the stream carries on looking perfect and
/// completely unresponsive. Nothing in the video says why.
///
/// Only reports changes: the foreground is sampled every watcher tick, and a
/// line per tick would bury the log.
void ReportForegroundThief() {
    HWND foreground = GetForegroundWindow();
    static HWND reported = nullptr;
    if (foreground == reported) {
        return;
    }

    bool streaming = false;
    bool ours = false;
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (!g_locks[i].active) {
            continue;
        }
        streaming = true;
        if (g_locks[i].window == foreground) {
            ours = true;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    if (!streaming) {
        return;
    }

    reported = foreground;
    if (ours) {
        Log("[focus] the streamed window has the keyboard");
        return;
    }

    char cls[96] = {0};
    char title[128] = {0};
    if (foreground) {
        GetClassNameA(foreground, cls, sizeof(cls) - 1);
        GetWindowTextA(foreground, title, sizeof(title) - 1);
    }
    Log("[focus] \"%s\" [%s] took the keyboard from the streamed window;"
        " typing at the Mac is going there instead",
        title[0] ? title : "(untitled)", cls[0] ? cls : "?");
}

/// Put a locked window back if anything moved or resized it.
DWORD WINAPI WatcherProc(LPVOID) {
    while (InterlockedCompareExchange(&g_watcher_stop, 0, 0) == 0) {
        Sleep(120);
        for (int i = 0; i < kMaxLocks; ++i) {
            HWND window = nullptr;
            RECT desired{};
            uint64_t closed = 0;
            EnterCriticalSection(&g_lock_cs);
            if (g_locks[i].active && SlotWindowGone(g_locks[i])) {
                // Release the slot here rather than through UnlockWindow: there
                // is no window left to give a frame, a placement or a z-order
                // back to, and holding the slot would keep this dead handle in
                // the way of the next application to be streamed.
                closed = IdFromWindow(g_locks[i].window);
                g_locks[i] = WindowLock{};
            } else if (g_locks[i].geometry_locked) {
                window = g_locks[i].window;
                desired = g_locks[i].desired;
            }
            LeaveCriticalSection(&g_lock_cs);
            if (closed != 0) {
                Log("[agent] tracked window %llu was closed", (unsigned long long) closed);
                NotifyWindowClosed(closed);
                continue;
            }
            if (!window) {
                continue;
            }
            // A minimised window is the user's business; leave it alone and let it
            // settle back when they restore it.
            if (IsIconic(window)) {
                continue;
            }
            if (IsZoomed(window)) {
                ShowWindow(window, SW_RESTORE);
            }
            const RECT now = ClientAreaInScreen(window);
            if (now.left == desired.left && now.top == desired.top
                && now.right == desired.right && now.bottom == desired.bottom) {
                continue;
            }
            PlaceClientArea(window, desired.left, desired.top,
                            desired.right - desired.left, desired.bottom - desired.top);
        }
        ReportForegroundThief();
    }
    return 0;
}

void StartWatcher() {
    if (g_watcher) {
        return;
    }
    InterlockedExchange(&g_watcher_stop, 0);
    g_watcher = CreateThread(nullptr, 0, WatcherProc, nullptr, 0, nullptr);
}

/// Find this window's slot, claiming a free one and recording how the window
/// looked first. Call with `g_lock_cs` held.
///
/// Recording happens here, once, rather than in each caller: `lock` and
/// `topmost` both change a window and both owe it a restore, and a window that
/// was only ever made topmost still has to come back down.
int ClaimSlot(HWND window) {
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active && g_locks[i].window == window) {
            return i;
        }
    }
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active) {
            continue;
        }
        g_locks[i] = WindowLock{};
        g_locks[i].window = window;
        g_locks[i].active = true;
        g_locks[i].saved_style = GetWindowLongPtrW(window, GWL_STYLE);
        GetWindowThreadProcessId(window, &g_locks[i].pid);
        g_locks[i].saved_topmost =
            (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
        // WINDOWPLACEMENT rather than GetWindowRect: it carries the restored
        // size *and* whether the window was maximised, so a window that was
        // full screen before the session goes back to full screen after it.
        g_locks[i].saved_placement.length = sizeof(WINDOWPLACEMENT);
        GetWindowPlacement(window, &g_locks[i].saved_placement);
        return i;
    }
    return -1;
}

/// Take away a window's ability to be resized from the host side.
bool LockWindow(HWND window) {
    EnterCriticalSection(&g_lock_cs);
    const int slot = ClaimSlot(window);
    LeaveCriticalSection(&g_lock_cs);
    if (slot < 0) {
        return false;
    }

    // Un-maximise only now that the placement is recorded, or the restore would
    // believe the window had always been this size.
    if (IsZoomed(window)) {
        ShowWindow(window, SW_RESTORE);
    }

    EnterCriticalSection(&g_lock_cs);
    // The lock was released across the un-maximise above, so re-establish that
    // this slot is still this window's. Nothing reclaims slots concurrently
    // today ΓÇö commands and the disconnect cleanup all run on the client thread ΓÇö
    // but reviving a slot that had been cleared would restore a zeroed style
    // onto a real window, and that is not a failure worth finding later.
    if (!g_locks[slot].active || g_locks[slot].window != window) {
        LeaveCriticalSection(&g_lock_cs);
        return false;
    }
    g_locks[slot].geometry_locked = true;
    g_locks[slot].desired = ClientAreaInScreen(window);
    const LONG_PTR stripped =
        g_locks[slot].saved_style & ~static_cast<LONG_PTR>(WS_THICKFRAME | WS_MAXIMIZEBOX);
    LeaveCriticalSection(&g_lock_cs);

    SetWindowLongPtrW(window, GWL_STYLE, stripped);
    // SWP_FRAMECHANGED makes the window recompute its non-client area; without it
    // the border is gone in style only and still drag-resizes.
    SetWindowPos(window, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    StartWatcher();
    return true;
}

void UnlockWindow(HWND window) {
    WindowLock saved{};
    bool found = false;
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active && g_locks[i].window == window) {
            saved = g_locks[i];
            g_locks[i] = WindowLock{};
            found = true;
            break;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    if (!found || !IsWindow(window)) {
        return;
    }

    SetWindowLongPtrW(window, GWL_STYLE, saved.saved_style);
    // Drop back out of the always-on-top band unless the window was already in
    // it. Leaving it set is the worst of the three things left behind here: the
    // window floats above everything the user does next, with no visible cause
    // and no way to fix it short of restarting the application.
    SetWindowPos(window, saved.saved_topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    // And put it back where it was. Managed windows are parked on the virtual
    // display, whose origin sits off the side of the real desktop, so a window
    // left at those coordinates is not merely misplaced ΓÇö it is invisible, on a
    // monitor that stops existing when the session ends.
    if (saved.saved_placement.length == sizeof(WINDOWPLACEMENT)) {
        SetWindowPlacement(window, &saved.saved_placement);
    }
}

/// Give every locked window its resize border back.
///
/// Called when a client disconnects, so a Mac that goes away does not leave
/// applications permanently unresizable on someone's desktop.
void UnlockAll() {
    for (int i = 0; i < kMaxLocks; ++i) {
        EnterCriticalSection(&g_lock_cs);
        HWND window = g_locks[i].active ? g_locks[i].window : nullptr;
        LeaveCriticalSection(&g_lock_cs);
        if (window) {
            UnlockWindow(window);
        }
    }
}

/// Tell the watcher a new size is legitimate, because the Mac asked for it.
void SetLockedGeometry(HWND window, const RECT& client) {
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active && g_locks[i].window == window) {
            g_locks[i].desired = client;
            break;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
}

// ΓöÇΓöÇ Sunshine pairing ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// Sunshine pairs by showing a PIN on the client and having a human type it into
// Sunshine's web UI on the host. For a non-technical user that means a browser, a
// self-signed-certificate warning, creating web UI credentials, and finding the
// PIN page ΓÇö which is where most people give up.
//
// The agent already runs on the host, so it can do that step itself: the Mac
// sends the PIN it is displaying and the agent POSTs it to Sunshine's own local
// API. Reading confighttp.cpp, /api/pin needs HTTP Basic auth, and its CSRF check
// is skipped outright for requests carrying neither Origin nor Referer ΓÇö those
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
    // The supervised Sunshine first: SolStream generated its web credentials
    // itself, so approving a PIN needs nothing from the user at all. Falling
    // back to stored credentials covers the other case -- a Sunshine somebody
    // installed and configured before SolStream existed.
    std::string user, password;
    if (!solstream::SupervisedCredentials(user, password)
        && !LoadSunshineCredentials(user, password)) {
        return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"no-credentials\","
               "\"message\":\"SolStream is not running its own Sunshine, and no "
               "credentials are stored for the one that is.\"}";
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
    // still comes back as HTTP 200 ΓÇö so the body decides, not the status.
    const bool ok = reply.status == 200 && reply.body.find("\"status\":true") != std::string::npos;
    Log("[agent] pair pin -> HTTP %lu %s", reply.status, ok ? "accepted" : "rejected");
    if (ok) {
        return "{\"type\":\"paired\",\"ok\":true}";
    }
    return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"refused\",\"message\":\""
           + JsonEscape(reply.body.substr(0, 200)) + "\"}";
}

// ΓöÇΓöÇ Placement ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

/// Place a window so its CLIENT AREA lands exactly on the requested rectangle.
///
/// The caller cares about the client area, because that is what gets cropped
/// out of the stream ΓÇö but SetWindowPos positions the whole window including
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

// ΓöÇΓöÇ JSON output ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

std::string DisplaysJson(const std::vector<Display>& displays) {
    std::string out = "{\"type\":\"displays\",\"displays\":[";
    for (size_t i = 0; i < displays.size(); ++i) {
        const Display& display = displays[i];
        char buffer[1024];
        // Which display Sunshine is actually encoding, said here rather than only
        // in `status`. The Mac crops a rectangle out of whatever arrives, so if
        // it places windows on a different display every crop is taken from the
        // wrong pixels — and the result is not an error, it is a picture. Seen
        // for real: a window titled "Character Map", frames arriving, nothing
        // dropped, and a black strip beside an olive rectangle on screen.
        // Sending it with the list means the client has it at the moment it
        // chooses, with no second round trip to race.
        const bool captured = ToWide(display.device_name) == g_capture_display;
        std::snprintf(buffer, sizeof(buffer),
                      "%s{\"name\":\"%s\",\"adapter\":\"%s\",\"x\":%ld,\"y\":%ld,"
                      "\"w\":%ld,\"h\":%ld,\"primary\":%s,\"captured\":%s}",
                      i ? "," : "",
                      JsonEscape(display.device_name).c_str(),
                      JsonEscape(display.adapter).c_str(),
                      display.bounds.left, display.bounds.top,
                      display.bounds.right - display.bounds.left,
                      display.bounds.bottom - display.bounds.top,
                      display.primary ? "true" : "false",
                      captured ? "true" : "false");
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
/// the window being enumerable ΓÇö minimising an application must not look like
/// quitting it.
std::string WindowStatusJson(uint64_t id) {
    HWND handle = WindowFromId(id);
    // A tracked window is checked against the process that owned it, so a
    // recycled handle reads as what it is — the original window is gone. Without
    // this the poll and the watcher could disagree: the watcher would report the
    // window closed and drop it, and the next poll would say it was alive again.
    if (handle) {
        EnterCriticalSection(&g_lock_cs);
        for (int i = 0; i < kMaxLocks; ++i) {
            if (g_locks[i].active && g_locks[i].window == handle
                && SlotWindowGone(g_locks[i])) {
                handle = nullptr;
                break;
            }
        }
        LeaveCriticalSection(&g_lock_cs);
    }
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

    // Whether anything is drawn over it, and by what.
    //
    // The crop is a rectangle on a shared display: anything covering the tile is
    // streamed as though it were part of the application, with nothing on the
    // Mac to say otherwise. It is not hypothetical — a Windows Firewall prompt
    // about Sunshine appeared on the virtual display mid-test and sat over half
    // the streamed window, looking for all the world like part of it.
    //
    // Computed from the same top-to-bottom enumeration the window list uses,
    // which already works this out; asked once a second per window, which is
    // the same rate the liveness poll runs at anyway.
    for (const WindowInfo& info : EnumerateWindows()) {
        if (info.handle != handle) {
            continue;
        }
        out += ",\"occluded\":" + std::string(info.occluded ? "true" : "false");
        if (info.occluded) {
            out += ",\"occludedBy\":\"" + JsonEscape(info.occluded_by) + "\"";
        }
        break;
    }
    out += "}";
    return out;
}

// ΓöÇΓöÇ Tiny request parsing ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ
//
// The command set is small and fixed, so a full JSON parser would be more
// surface area than the protocol itself. Extract by key instead.

/// Extract a JSON string value, honouring escapes.
///
/// The escape handling is not decoration. Every string the Mac sends us is full
/// of backslashes ΓÇö Windows device names like \\.\DISPLAY7 and shortcut paths
/// like C:\Users\... ΓÇö and JSON doubles every one of them on the wire. Taking the
/// raw substring gives back the doubled form, and it also stops at the first
/// quote, so any window title containing one truncates.
///
/// Path arguments survived that for a while because Windows collapses duplicate
/// separators, so C:\\Users\\x opens the same file as C:\Users\x. Device names do
/// not: they are matched literally, and \\\\.\\DISPLAY7 resolves to nothing at
/// all.
/// Parse exactly four hex digits at `at`.
bool ParseHex4(const std::string& json, size_t at, unsigned& out) {
    if (at + 3 >= json.size()) {
        return false;
    }
    unsigned code = 0;
    for (int k = 0; k < 4; ++k) {
        const char digit = json[at + k];
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
    out = code;
    return true;
}

void AppendUtf8(std::string& out, unsigned code) {
    if (code < 0x80) {
        out.push_back(static_cast<char>(code));
    } else if (code < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (code >> 6)));
        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else if (code < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (code >> 12)));
        out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (code >> 18)));
        out.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    }
}

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
                unsigned code = 0;
                if (!ParseHex4(json, i + 1, code)) {
                    return false;
                }
                i += 4;
                // Reassemble surrogate pairs. This used to say that nothing we
                // parse carries characters outside the basic multilingual
                // plane, which stopped being true once the clipboard began
                // carrying whatever the user had copied: an emoji arrives as
                // two \u escapes, and encoding each half separately produces
                // two invalid sequences instead of one character.
                if (code >= 0xD800 && code <= 0xDBFF) {
                    unsigned low = 0;
                    if (i + 6 < json.size() && json[i + 1] == '\\' && json[i + 2] == 'u'
                        && ParseHex4(json, i + 3, low)
                        && low >= 0xDC00 && low <= 0xDFFF) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        i += 6;
                    } else {
                        code = 0xFFFD;  // unpaired high surrogate
                    }
                } else if (code >= 0xDC00 && code <= 0xDFFF) {
                    code = 0xFFFD;      // stray low surrogate
                }
                AppendUtf8(value, code);
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

std::string HandleCommand(const std::string& line, bool& authenticated) {
    std::string command;
    if (!FieldString(line, "cmd", command)) {
        return "{\"type\":\"error\",\"message\":\"missing cmd\"}";
    }

    // Answered before the authentication check, and doing nothing: it exists so
    // a client that is simply idle — sitting in the application picker with no
    // window open — does not look like a client that has vanished. The recv
    // timeout below cannot tell those apart, and dropping the wrong one leaves
    // the Mac holding a socket that is gone, on which every later command fails
    // silently.
    if (command == "ping") {
        return "{\"type\":\"pong\"}";
    }

    // What the host application is doing with itself: its Sunshine, its capture
    // display, and the ports both. Answered before authentication because it
    // says nothing a port scan could not already establish, and because it is
    // what the Mac shows when it cannot get any further.
    if (command == "status") {
        const solstream::SunshineState state = solstream::GetSunshineState();
        std::string out = "{\"type\":\"status\"";
        out += ",\"sunshine\":\"";
        switch (state) {
            case solstream::SunshineState::kRunning: out += "running"; break;
            case solstream::SunshineState::kStarting: out += "starting"; break;
            case solstream::SunshineState::kFailed: out += "failed"; break;
            case solstream::SunshineState::kNotBundled: out += "missing"; break;
            default: out += "stopped"; break;
        }
        out += "\",\"sunshineDetail\":\"" + JsonEscape(solstream::SunshineStatusText()) + "\"";
        out += ",\"basePort\":" + std::to_string(g_sunshine_base);
        out += ",\"captureDisplay\":\"" + JsonEscape(ToUtf8(g_capture_display)) + "\"";
        out += ",\"virtualDisplay\":"
             + std::string(solstream::HasVirtualDisplay() ? "true" : "false");
        out += "}";
        return out;
    }

    if (command == "auth") {
        std::string supplied;
        FieldString(line, "token", supplied);
        if (TokenMatches(supplied)) {
            authenticated = true;
            return "{\"type\":\"auth\",\"ok\":true}";
        }
        // Deliberately slow: this is the only guess-and-check surface here, and
        // the agent serves one client at a time, so a delay costs a legitimate
        // client nothing and costs an attacker everything.
        Sleep(1000);
        Log("[agent] rejected a bad token");
        return "{\"type\":\"auth\",\"ok\":false,\"message\":\"bad token\"}";
    }

    if (g_require_auth && !authenticated) {
        return "{\"type\":\"error\",\"message\":\"unauthenticated\",\"needsAuth\":true}";
    }

    if (command == "displays") {
        return DisplaysJson(EnumerateDisplays());
    }

    if (command == "windows") {
        return WindowsJson(EnumerateWindows());
    }

    if (command == "apps") {
        const std::vector<AppEntry> apps = EnumerateApps();
        // The client launches and fetches icons from exactly this list, so seed
        // the membership cache with it rather than walking the tree again.
        RememberAdvertised(apps);
        return AppsJson(apps);
    }

    if (command == "clipboard") {
        std::string text;
        if (FieldString(line, "text", text)) {
            return ClipboardSetJson(text);
        }
        // No text field means "what have you got"; a seq that matches what the
        // Mac already has means it need not ask for the contents.
        long long since = -1;
        if (FieldNumber(line, "seq", since) && since >= 0
            && static_cast<DWORD>(since) == ClipboardSequence()) {
            return "{\"type\":\"clipboard\",\"ok\":true,\"unchanged\":true,\"seq\":"
                 + std::to_string(ClipboardSequence()) + "}";
        }
        return ClipboardGetJson();
    }

    if (command == "icon") {
        // Either a window (by id) or a shortcut (by path). Fetched one at a time
        // and on demand, so a picker showing 245 applications does not extract
        // 245 icons before it can draw anything.
        long long id = 0;
        if (FieldNumber(line, "id", id)) {
            HWND window = WindowFromId(static_cast<uint64_t>(id));
            if (!window) {
                return "{\"type\":\"icon\",\"ok\":false,\"id\":\"" + std::to_string(id) + "\"}";
            }
            return IconJson(std::to_string(id), WindowIcon(window), false);
        }
        std::string path;
        if (!FieldString(line, "path", path)) {
            return "{\"type\":\"error\",\"message\":\"icon needs id or path\"}";
        }
        const std::wstring wide = ToWide(path);
        if (!IsAdvertisedApp(wide)) {
            return "{\"type\":\"icon\",\"ok\":false,\"id\":\"" + JsonEscape(path) + "\"}";
        }
        HICON large = nullptr;
        // ExtractIconEx resolves a .lnk to its target on its own.
        if (ExtractIconExW(wide.c_str(), 0, &large, nullptr, 1) == 0 || !large) {
            return "{\"type\":\"icon\",\"ok\":false,\"id\":\"" + JsonEscape(path) + "\"}";
        }
        return IconJson(path, large, true);
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
        int got_hz = 0;
        if (!SetDisplayMode(ToWide(device), (int) want_w, (int) want_h,
                            got_w, got_h, got_hz)) {
            return "{\"type\":\"canvas\",\"ok\":false,\"message\":\"could not set a display mode\"}";
        }
        char buffer[192];
        // The rate goes back so the Mac can log it. A capture display stuck at
        // 30 Hz otherwise looks exactly like a slow network.
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"canvas\",\"ok\":true,\"w\":%d,\"h\":%d,\"hz\":%d}",
                      got_w, got_h, got_hz);
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
        const std::string reply = PairJson(pin, name, g_sunshine_web_port);

        // Put the code on screen here when it could not be approved for the
        // user. The window has always been able to draw this card; nothing
        // ever asked it to, so the one moment the host application exists for
        // -- a Mac waiting on a code -- was the one moment it said nothing.
        //
        // The Mac shows the PIN too, but only the person at this PC can act on
        // it, and they may not be the person holding the Mac.
        if (reply.find("\"ok\":true") == std::string::npos) {
            solstream::ShowPairingPin(ToWide(pin), ToWide(name));
        } else {
            solstream::ShowPairingPin(L"", L"");
        }
        return reply;
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
        const std::wstring wide = ToWide(path);
        if (!IsAdvertisedApp(wide)) {
            Log("[agent] refused to launch %s: not an advertised application", path.c_str());
            return "{\"type\":\"error\",\"message\":\"not an installed application\"}";
        }
        long long timeout = 20000;
        FieldNumber(line, "timeoutMs", timeout);
        timeout = std::min<long long>(std::max<long long>(timeout, 1000), 60000);
        // This blocks until the application shows a window. The agent serves one
        // client at a time, so nothing else is waiting on it, and the alternative
        // ΓÇö returning immediately and making the Mac poll for an unidentified
        // new window ΓÇö just moves the same matching problem across the wire.
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
        // The Mac asked for this, so it is the new truth ΓÇö otherwise the watcher
        // would immediately drag the window back to the previous size.
        SetLockedGeometry(window, client);
        char buffer[256];
        const POINT minimum = MinimumClientSize(window);
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"placed\",\"ok\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld"
                      ",\"minW\":%ld,\"minH\":%ld,\"border\":%d}",
                      ok ? "true" : "false",
                      client.left, client.top,
                      client.right - client.left, client.bottom - client.top,
                      minimum.x, minimum.y, ResizeBorderThickness(window));
        return buffer;
    }

    if (command == "lock") {
        long long id = 0, on = 1;
        if (!FieldNumber(line, "id", id)) {
            return "{\"type\":\"error\",\"message\":\"lock needs id\"}";
        }
        FieldNumber(line, "on", on);
        HWND window = WindowFromId(static_cast<uint64_t>(id));
        if (!window) {
            return "{\"type\":\"error\",\"message\":\"no such window\"}";
        }
        bool ok = true;
        if (on) {
            ok = LockWindow(window);
        } else {
            UnlockWindow(window);
        }
        char buffer[96];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"locked\",\"ok\":%s,\"on\":%s}",
                      ok ? "true" : "false", on ? "true" : "false");
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
        //
        // Claim a slot even when this window is not geometry-locked, so that
        // whatever happens to the session ΓÇö a clean disconnect or a Mac that
        // simply vanishes ΓÇö the window is known to be owed a trip back down.
        EnterCriticalSection(&g_lock_cs);
        ClaimSlot(window);
        LeaveCriticalSection(&g_lock_cs);
        // And start watching from here rather than from `lock`. This is the
        // first thing the Mac says about a window it intends to stream, and the
        // watcher is what notices the window being closed ΓÇö an application that
        // exits between being pinned and being locked would otherwise go
        // unreported until the Mac next polled.
        if (on) {
            StartWatcher();
        }
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

        const bool foreground = ForceForeground(window);
        if (!foreground) {
            // Worth a log line of its own: the window still streams, so nothing
            // looks wrong, but the user's keystrokes are going somewhere else.
            char title[128] = {0};
            GetWindowTextA(window, title, sizeof(title) - 1);
            std::printf("[focus] could not take the foreground for \"%s\";"
                        " keystrokes will go to whatever holds it\n", title);
            std::fflush(stdout);
        }

        char buffer[128];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"focused\",\"ok\":%s,\"foreground\":%s}",
                      foreground ? "true" : "false", foreground ? "true" : "false");
        return buffer;
    }

    return "{\"type\":\"error\",\"message\":\"unknown cmd\"}";
}

// ΓöÇΓöÇ Server ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

// A line torn in half by another thread's send() is a protocol desync the Mac
// cannot recover from -- it has no request ids to resynchronise against, so it
// drops the connection. `g_send_cs` is declared with the push channel, above.
bool SendLine(SOCKET client, const std::string& text) {
    std::string payload = text;
    payload += '\n';
    EnterCriticalSection(&g_send_cs);
    struct Unlock {
        ~Unlock() { LeaveCriticalSection(&g_send_cs); }
    } unlock;
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

/// When the running Sunshine process started, as a 64-bit tick count, or 0 if it
/// is not running.
///
/// The Mac needs this to track whether the host is drawing its cursor.
/// Sunshine's `display_cursor` is a process-global that starts true and can only
/// be *flipped*, never read, so a client that remembers "I hid it" has no way to
/// notice that Sunshine restarted and put it back. Keyed against this, a restart
/// is a new instance and the belief resets by itself.
unsigned long long SunshineInstanceId() {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) {
        return 0;
    }
    unsigned long long instance = 0;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (_wcsicmp(entry.szExeFile, L"sunshine.exe") != 0) {
                continue;
            }
            // The process id on its own already changes when Sunshine restarts,
            // which is the whole question being asked. The creation time is
            // added when it can be read, but Sunshine normally runs as a service
            // under SYSTEM and this agent does not run elevated, so OpenProcess
            // is usually denied — hence a pid-only answer has to be good enough
            // rather than a failure.
            instance = entry.th32ProcessID;
            HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                         entry.th32ProcessID);
            if (process) {
                FILETIME created{}, exited{}, kernel{}, user{};
                if (GetProcessTimes(process, &created, &exited, &kernel, &user)) {
                    ULARGE_INTEGER value{};
                    value.LowPart = created.dwLowDateTime;
                    value.HighPart = created.dwHighDateTime;
                    // Mixed in rather than replacing the pid, so the answer is
                    // still unique if the times are unavailable for one process
                    // and not another.
                    instance ^= value.QuadPart;
                }
                CloseHandle(process);
            }
            break;
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return instance;
}

// ── Cursor shape ─────────────────────────────────────────────────────────────
//
// The Mac draws its own pointer over the video, so it has to know what the
// Windows cursor currently *is* — an I-beam over a text field, a resize arrow
// over a split, and so on — or the pointer stays an arrow while it hovers
// things that are plainly not arrows.
//
// Pushed rather than polled. The Mac already polls this socket for window
// status, and the agent serves one command at a time on one thread, so a poll
// fast enough to feel immediate would sit in front of every `place` sent during
// a live resize. This costs one line per actual change instead.

struct NamedCursor {
    const wchar_t* id;
    const char* name;
    HCURSOR handle;
};

/// The standard cursors, resolved once. A custom cursor belonging to some
/// application matches none of them and is reported as "arrow", which is the
/// honest answer: its bitmap means nothing to macOS.
NamedCursor g_cursors[] = {
    {IDC_ARROW, "arrow", nullptr},
    {IDC_IBEAM, "ibeam", nullptr},
    {IDC_WAIT, "wait", nullptr},
    {IDC_CROSS, "crosshair", nullptr},
    {IDC_UPARROW, "uparrow", nullptr},
    {IDC_SIZENWSE, "resizeNWSE", nullptr},
    {IDC_SIZENESW, "resizeNESW", nullptr},
    {IDC_SIZEWE, "resizeWE", nullptr},
    {IDC_SIZENS, "resizeNS", nullptr},
    {IDC_SIZEALL, "move", nullptr},
    {IDC_NO, "no", nullptr},
    {IDC_HAND, "hand", nullptr},
    {IDC_APPSTARTING, "appstarting", nullptr},
    {IDC_HELP, "help", nullptr},
};

HANDLE g_cursor_thread = nullptr;
volatile LONG g_cursor_stop = 0;

const char* CursorName(HCURSOR cursor) {
    for (NamedCursor& known : g_cursors) {
        if (known.handle == nullptr) {
            known.handle = LoadCursorW(nullptr, known.id);
        }
        if (known.handle == cursor) {
            return known.name;
        }
    }
    return "arrow";
}

DWORD WINAPI CursorWatcherProc(LPVOID) {
    HCURSOR last = nullptr;
    bool logged_once = false;
    while (InterlockedCompareExchange(&g_cursor_stop, 0, 0) == 0) {
        CURSORINFO info{};
        info.cbSize = sizeof(info);
        const BOOL got = GetCursorInfo(&info);
        HCURSOR current = got ? info.hCursor : nullptr;
        if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
            // Not authenticated yet. Forget the last shape too, so the first
            // push after authentication carries the current one rather than
            // being skipped as unchanged.
            last = nullptr;
            Sleep(40);
            continue;
        }
        if (!logged_once) {
            logged_once = true;
            Log("[cursor] reporting shape changes (currently %s)", CursorName(current));
        }
        if (current != last) {
            last = current;
            const SOCKET client = g_push_client;
            if (client != INVALID_SOCKET) {
                std::string line = "{\"type\":\"cursor\",\"shape\":\"";
                line += CursorName(current);
                line += "\"}";
                // A failure here means the client has gone; the serving thread
                // notices that on its own recv, so there is nothing to do but
                // stop bothering it.
                if (!SendLine(client, line)) {
                    break;
                }
            }
        }
        Sleep(40);
    }
    return 0;
}

/// Open the push channel for this client and start watching the cursor.
///
/// The socket registered here is the one the window watcher reports closures on
/// too, so this has to run for every client, not only the ones interested in the
/// cursor.
void StartCursorWatcher(SOCKET client, bool authorised) {
    g_push_client = client;
    InterlockedExchange(&g_cursor_stop, 0);
    InterlockedExchange(&g_push_authorised, authorised ? 1 : 0);
    g_cursor_thread = CreateThread(nullptr, 0, CursorWatcherProc, nullptr, 0, nullptr);
}

void StopCursorWatcher() {
    InterlockedExchange(&g_cursor_stop, 1);
    if (g_cursor_thread) {
        // Bounded by the 40ms poll, so this is a short wait, and it has to
        // happen before the socket closes underneath the thread.
        WaitForSingleObject(g_cursor_thread, 2000);
        CloseHandle(g_cursor_thread);
        g_cursor_thread = nullptr;
    }
    // Under the send lock, so the window watcher — which is not joined here —
    // cannot be holding this socket while it is retired.
    EnterCriticalSection(&g_send_cs);
    g_push_client = INVALID_SOCKET;
    LeaveCriticalSection(&g_send_cs);
    InterlockedExchange(&g_push_authorised, 0);
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

    // The greeting says whether a token is needed, so the Mac can ask for one up
    // front rather than discovering it by having a command refused.
    std::string hello = "{\"type\":\"hello\",\"version\":";
    hello += std::to_string(kProtocolVersion);
    hello += ",\"host\":\"" + JsonEscape(hostname) + "\"";
    hello += ",\"needsAuth\":" + std::string(g_require_auth ? "true" : "false");
    hello += ",\"sunshineInstance\":\"" + std::to_string(SunshineInstanceId()) + "\"";
    hello += "}";
    if (!SendLine(client, hello)) {
        return;
    }
    // The display list is only volunteered to a client that has no authenticating
    // to do; otherwise it would leak the machine's monitor layout to anyone who
    // can open a socket.
    bool authenticated = !g_require_auth;
    if (authenticated && !SendLine(client, DisplaysJson(EnumerateDisplays()))) {
        return;
    }

    std::string buffer;
    char chunk[4096];
    // Set once a line has outgrown the cap, and cleared at the newline that ends
    // it. The rest of an oversized line has not arrived yet ΓÇö it comes in later
    // recv() chunks ΓÇö so this cannot be a one-off scan of what is in hand.
    bool discarding = false;
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

        if (discarding) {
            const size_t end = buffer.find('\n');
            if (end == std::string::npos) {
                buffer.clear();
                continue;
            }
            buffer.erase(0, end + 1);
            discarding = false;
        }

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
            const bool was_authenticated = authenticated;
            if (!SendLine(client, HandleCommand(line, authenticated))) {
                return;
            }
            // Authenticating completes the greeting: the display list is part of
            // the hello sequence, withheld until now, and the Mac waits for it
            // before doing anything else.
            if (!was_authenticated && authenticated) {
                InterlockedExchange(&g_push_authorised, 1);
                if (!SendLine(client, DisplaysJson(EnumerateDisplays()))) {
                    return;
                }
            }
        }

        // A client that never sends a newline must not grow this unbounded ΓÇö
        // but refuse the line, not the client. Dropping the connection is far
        // more destructive than it sounds: closing the socket runs UnlockAll(),
        // which pulls every streamed window off the virtual display and back
        // onto the real desktop, in the middle of a session the user is still
        // watching. The Mac has no reconnect, so the picture stays live while
        // every window command silently stops working.
        if (buffer.size() > kMaxLineBytes) {
            Log("[agent] request over %zu bytes, skipping it", kMaxLineBytes);
            buffer.clear();
            discarding = true;
            // Exactly one line, because the Mac pops one waiting completion per
            // reply. Zero or two desynchronises every later reply on this
            // connection.
            if (!SendLine(client, "{\"type\":\"error\",\"message\":\"request too large\"}")) {
                return;
            }
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
    // rejected by Sunshine, but only after it has checked the credentials ΓÇö so a
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
    // Loopback by default. This socket has no authentication yet, so the address
    // it binds is the only thing limiting who can drive it.
    std::string bind_address = kLoopback;
    bool set_credentials = false;
    bool print_token = false;
    bool no_auth = false;
    // --headless keeps the original behaviour: no window, log to stderr. Every
    // verification in this project is done over SSH, where there is no desktop
    // to put a window on.
    bool headless = false;
    // --no-sunshine leaves an existing Sunshine alone, for a host that was set
    // up before SolStream and wants to keep the one it has.
    bool no_sunshine = false;
    bool install_driver = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--port" && i + 1 < argc) {
            port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--sunshine-port" && i + 1 < argc) {
            // The BASE port, not the web one -- everything else is derived from
            // it, on both sides of the connection.
            g_sunshine_base = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
            g_sunshine_web_port =
                solstream::MapPort(g_sunshine_base, solstream::SunshinePort::kWebUi);
        } else if (arg == L"--headless") {
            headless = true;
        } else if (arg == L"--no-sunshine") {
            no_sunshine = true;
        } else if (arg == L"--install-display-driver") {
            install_driver = true;
        } else if (arg == L"--bind" && i + 1 < argc) {
            // Prefer a single address ΓÇö a VPN interface such as Tailscale, whose
            // peers are already device-authenticated ΓÇö over every interface.
            bind_address = ToUtf8(argv[i + 1]);
        } else if (arg == L"--listen-all") {
            bind_address = "0.0.0.0";
        } else if (arg == L"--set-sunshine-credentials") {
            set_credentials = true;
        } else if (arg == L"--print-token") {
            print_token = true;
        } else if (arg == L"--no-auth") {
            no_auth = true;
        }
    }

    if (set_credentials) {
        return SetSunshineCredentials();
    }

    if (install_driver) {
        std::string error;
        if (solstream::InstallBundledDriver(error)) {
            std::fputs("Display driver installed.\n", stdout);
            return 0;
        }
        std::fprintf(stderr, "%s\n", error.c_str());
        return 1;
    }

    g_token = LoadOrCreateToken();
    if (print_token) {
        if (g_token.empty()) {
            std::fputs("Could not read or create the agent token.\n", stderr);
            return 1;
        }
        std::fprintf(stdout, "%s\n", g_token.c_str());
        return 0;
    }

    // Loopback needs no token: reaching it already means running as a user on
    // this machine, which is strictly more access than the agent grants. Keeping
    // that exemption is what lets an SSH port forward work without one.
    // --no-auth used to be honoured anywhere, with a warning. A warning is the
    // wrong instrument: the agent starts from a scheduled task at logon, so the
    // log line lands in a file nobody is reading, on a machine whose owner
    // believes their VPN is the boundary. Refuse instead.
    if (no_auth && bind_address != kLoopback) {
        Log("[agent] --no-auth is only allowed on %s, not on %s.",
            kLoopback, bind_address.c_str());
        Log("[agent] Anything that could open that socket would be able to launch");
        Log("[agent] applications as this user without presenting anything.");
        return 1;
    }

    // Loopback needs no token: reaching it already means running as a user on
    // this machine, which is strictly more access than the agent grants. Keeping
    // that exemption is what lets an SSH port forward work without one.
    g_require_auth = !no_auth && bind_address != kLoopback;
    if (g_require_auth && g_token.empty()) {
        Log("[agent] refusing to listen on %s without a token", bind_address.c_str());
        return 1;
    }

    // Without this every coordinate we read or write is silently rescaled by
    // Windows' DPI virtualisation, and windows land in the wrong place on any
    // display that is not at 100%.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    InitializeCriticalSection(&g_lock_cs);
    InitializeCriticalSection(&g_send_cs);

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

    // EXCLUSIVE, not REUSEADDR. On Windows SO_REUSEADDR lets a second process
    // bind a port that is already bound ΓÇö it does not merely permit reusing a
    // port in TIME_WAIT as it does on unix. A second agent, in another user's
    // session, would therefore start successfully, and which of the two a given
    // connection reached would be indeterminate: the Mac could silently end up
    // driving somebody else's desktop.
    BOOL exclusive = TRUE;
    setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
               (const char*) &exclusive, sizeof(exclusive));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, bind_address.c_str(), &address.sin_addr) != 1) {
        Log("[agent] --bind %s is not a valid IPv4 address", bind_address.c_str());
        return 1;
    }
    if (bind_address == "0.0.0.0") {
        Log("[agent] WARNING: listening on ALL interfaces. The token is the only");
        Log("[agent] WARNING: thing between an attacker and launching applications");
        Log("[agent] WARNING: as this user. Prefer --bind with the one address of a");
        Log("[agent] WARNING: trusted network, so the token is a second lock and");
        Log("[agent] WARNING: not the only one.");
    } else if (bind_address != kLoopback) {
        Log("[agent] reachable on %s only, and a token is required",
            bind_address.c_str());
    }

    // Wait for the address to exist rather than giving up on it.
    //
    // The agent starts at logon, and a VPN interface does not. Binding a Tailscale
    // address the moment the desktop appears fails with WSAEADDRNOTAVAIL, because
    // the interface is seconds away from existing ΓÇö so the agent would exit and
    // the Mac would find nothing there until somebody started it by hand. The same
    // applies to DHCP on a slow network.
    bool bound = false;
    for (int attempt = 0; attempt < 150 && !bound; ++attempt) {
        if (bind(listener, (sockaddr*) &address, sizeof(address)) != SOCKET_ERROR) {
            bound = true;
            break;
        }
        const int error = WSAGetLastError();
        if (error != WSAEADDRNOTAVAIL) {
            Log("[agent] bind(%u) failed: %d", port, error);
            return 1;
        }
        if (attempt == 0) {
            // ASCII only in log output: the console reads these bytes in the
            // active code page, so anything above 7-bit comes out as mojibake.
            Log("[agent] %s does not exist yet, waiting for the interface",
                bind_address.c_str());
        }
        Sleep(2000);
    }
    if (!bound) {
        Log("[agent] gave up waiting for %s to exist", bind_address.c_str());
        return 1;
    }
    if (listen(listener, 1) == SOCKET_ERROR) {
        Log("[agent] listen failed: %d", WSAGetLastError());
        return 1;
    }

    Log("[agent] SolStream agent v%d listening on %s:%u",
        kProtocolVersion, bind_address.c_str(), port);

    // ── The virtual display ──────────────────────────────────────────────────
    //
    // Checked before Sunshine starts, because it decides what Sunshine captures.
    // A machine without one can still stream — the real monitor is captured
    // instead — but the window cannot be sized past that monitor's resolution,
    // the crop shows anything dragged over it, and the mode cannot be matched to
    // the Mac. So this is reported plainly rather than left for the user to
    // discover as a bad picture.
    {
        const auto virtual_displays = solstream::FindVirtualDisplays();
        if (virtual_displays.empty()) {
            Log("[agent] no virtual display driver is installed.");
            Log("[agent] SolStream will capture a real monitor, which means the");
            Log("[agent] streamed window cannot be larger than it and anything");
            Log("[agent] dragged over the window appears inside the stream.");
            if (solstream::BundledDriverPackage().empty()) {
                Log("[agent] no driver is bundled with this build; install the");
                Log("[agent] Virtual Display Driver and restart SolStream.");
            } else {
                Log("[agent] a driver is bundled: use the window's Install button,");
                Log("[agent] or run with --install-display-driver.");
            }
        } else {
            for (const auto& display : virtual_displays) {
                Log("[agent] virtual display: %s (%s)",
                    ToUtf8(display.friendly_name).c_str(),
                    display.running ? "running" : "present but not started");
            }
        }
    }

    // Pick what Sunshine captures: the virtual display when there is one, so a
    // crop can never be a crop out of somebody's real screen.
    for (const Display& display : EnumerateDisplays()) {
        const std::string& adapter = display.adapter;
        std::string lowered = adapter;
        for (char& c : lowered) { c = (char) tolower((unsigned char) c); }
        if (lowered.find("virtual") != std::string::npos
            || lowered.find("idd") != std::string::npos) {
            g_capture_display = ToWide(display.device_name);
            Log("[agent] capturing %s [%s]", display.device_name.c_str(), adapter.c_str());
            break;
        }
    }
    if (g_capture_display.empty()) {
        for (const Display& display : EnumerateDisplays()) {
            if (display.primary) {
                g_capture_display = ToWide(display.device_name);
                Log("[agent] no virtual display; falling back to %s",
                    display.device_name.c_str());
                break;
            }
        }
    }

    // ── Sunshine ─────────────────────────────────────────────────────────────
    //
    // Started by us, configured by us, on our own ports. A Sunshine the user
    // installed themselves keeps its own configuration and its own ports and is
    // never touched.
    if (!no_sunshine) {
        bool started = solstream::StartSunshine(g_sunshine_base, g_capture_display);
        if (!started && solstream::RestartedForDisplay()) {
            // The first start was only to read Sunshine's own display table.
            // Now it knows which display it means, so say it properly.
            Log("[agent] learned the capture display's id; restarting Sunshine");
            started = solstream::StartSunshine(g_sunshine_base, g_capture_display);
        }
        if (started) {
            Log("[agent] %s", solstream::SunshineStatusText().c_str());
            Log("[agent] Sunshine ports: https %u, http %u, web %u, rtsp %u",
                solstream::MapPort(g_sunshine_base, solstream::SunshinePort::kHttps),
                solstream::MapPort(g_sunshine_base, solstream::SunshinePort::kHttp),
                g_sunshine_web_port,
                solstream::MapPort(g_sunshine_base, solstream::SunshinePort::kRtsp));
        } else {
            Log("[agent] %s", solstream::SunshineStatusText().c_str());
        }
    }

    for (const Display& display : EnumerateDisplays()) {
        Log("[agent]   display %s %ldx%ld at (%ld,%ld)%s",
            display.device_name.c_str(),
            display.bounds.right - display.bounds.left,
            display.bounds.bottom - display.bounds.top,
            display.bounds.left, display.bounds.top,
            display.primary ? " [primary]" : "");
    }

    // The accept loop moves off the main thread so the window can own it.
    //
    // A Win32 message loop has to run on the thread that created the window, and
    // this loop blocks in accept() indefinitely — so one of the two has to be
    // somewhere else, and it is easier to reason about a server thread than
    // about a UI that only pumps between connections.
    std::thread server([listener]() {
        for (;;) {
            SOCKET client = accept(listener, nullptr, nullptr);
            if (client == INVALID_SOCKET) {
                Log("[agent] accept failed: %d", WSAGetLastError());
                continue;
            }

            // One Mac at a time, said out loud rather than by hanging.
            //
            // Sunshine serves one session — it refuses a second /launch
            // outright — so two Macs streaming from one PC is not something
            // this can support however the socket is written. What it CAN do is
            // say so.
            //
            // Saying so requires accept() to keep running, which is why serving
            // moved onto its own thread. The first attempt at this put the
            // check here and left ServeClient inline, which changed nothing:
            // the loop was blocked inside ServeClient for the whole session, so
            // the second connection never reached the check at all — it sat in
            // the kernel's accept backlog exactly as before, with no error and
            // no timeout. The refusal only works if something is still
            // listening to refuse with.
            //
            // The refusal carries the same fields as `status`, so a second Mac
            // can still tell whether the host is healthy — and so can anyone
            // diagnosing it, which is how this was noticed at all.
            if (g_clients_connected.load() > 0) {
                char name[256] = {};
                DWORD name_size = sizeof(name);
                GetComputerNameA(name, &name_size);
                std::string busy = "{\"type\":\"busy\",\"message\":\"";
                busy += JsonEscape(std::string(name) + " is already streaming to "
                                   "another Mac. Disconnect there first.");
                busy += "\",\"sunshine\":\"";
                busy += solstream::GetSunshineState() == solstream::SunshineState::kRunning
                            ? "running" : "not running";
                busy += "\",\"basePort\":" + std::to_string(g_sunshine_base);
                busy += ",\"virtualDisplay\":"
                     + std::string(solstream::HasVirtualDisplay() ? "true" : "false");
                busy += "}";
                Log("[agent] refused a second client: one is already connected");
                SendLine(client, busy);
                closesocket(client);
                continue;
            }

            Log("[agent] client connected");
            g_clients_connected.fetch_add(1);
            std::thread([client]() {
                // Loopback needs no token, so it is authorised from the start.
                StartCursorWatcher(client, !g_require_auth);
                ServeClient(client);
                // Stopped before the socket closes: the watcher writes to it.
                StopCursorWatcher();
                closesocket(client);
                // Give every managed window its resize border back. A Mac that
                // goes away must not leave applications permanently unresizable.
                UnlockAll();
                // A PIN nobody is waiting on any more is worse than no PIN: it
                // is a code on screen that does nothing, for a Mac that has gone.
                solstream::ShowPairingPin(L"", L"");
                g_clients_connected.fetch_sub(1);
                Log("[agent] client disconnected");
            }).detach();
        }
    });
    server.detach();

    if (headless) {
        Log("[agent] headless: no window, Ctrl+C to stop");
        for (;;) {
            Sleep(60000);
        }
    }

    if (!solstream::ShowHostWindow()) {
        // No window station — a scheduled task in session 0, typically. The
        // agent is still useful there, so carry on rather than exiting: the
        // alternative is a host that silently refuses to start for a reason
        // nobody can see.
        Log("[agent] could not create a window; continuing without one");
        for (;;) {
            Sleep(60000);
        }
    }

    // Keep the window's numbers current while it is up.
    std::thread status([bind_address]() {
        while (!solstream::HostWindowClosed()) {
            solstream::HostStatus status;
            wchar_t name[256] = {};
            DWORD size = 256;
            GetComputerNameW(name, &size);
            status.computer_name = name;
            status.address = ToWide(bind_address);
            status.pairing_token = ToWide(g_token);
            status.agent_listening = true;
            status.connected_clients = g_clients_connected.load();

            const solstream::SunshineState state = solstream::GetSunshineState();
            status.sunshine_running = state == solstream::SunshineState::kRunning
                                   || state == solstream::SunshineState::kStarting;
            const std::string detail = solstream::SunshineStatusText();
            status.sunshine_detail = ToWide(detail);

            // Log every change, so a Sunshine that died and was brought back
            // leaves a trail. The window shows the current state, but the
            // question afterwards is always "did it restart, and when" — and
            // the answer was nowhere before this.
            static std::string last_detail;
            if (detail != last_detail) {
                last_detail = detail;
                Log("[agent] sunshine: %s", detail.c_str());
            }

            status.web_ui_port = g_sunshine_web_port;
            status.virtual_display = solstream::HasVirtualDisplay();
            status.display_detail = status.virtual_display
                ? (g_capture_display.empty() ? L"ready" : g_capture_display)
                : L"not installed";

            solstream::UpdateHostStatus(status);
            Sleep(1000);
        }
    });
    status.detach();

    const int code = solstream::RunHostWindowLoop();
    // Closing the window takes the host down with it, Sunshine included. A
    // Sunshine still holding the capture display after SolStream is gone is one
    // nobody can see to stop.
    solstream::StopSunshine();
    return code;
}
