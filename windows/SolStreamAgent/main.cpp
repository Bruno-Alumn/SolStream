// SolStream Agent — the Windows half of single-application streaming.
//
// This file is the control side: the authenticated agent channel, window and
// application enumeration, placement and locking, discovery and startup. It
// makes a chosen application's window sit at a known, non-overlapping
// rectangle on the capture display and tells the Mac where it is; the Mac crops
// that rectangle out of the single SMT/1 stream and presents it as a native
// window. Capture, encode and transport are in media/, the window in
// host_window.cpp.
//
// The code here is plain Win32 on purpose -- SetWindowPos, EnumWindows,
// GetMonitorInfo, a socket -- because it is developed on a Mac and
// cross-compiled, and that is the kind of Windows code that can be checked
// without a debugger.
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
#include <objbase.h>
#include <wincrypt.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <shellscalingapi.h>

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
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "agent_crypto.h"
#include "capture_display.h"
#include "clipboard.h"
#include "display_setup.h"
#include "driver_install.h"
#include "foreground.h"
#include "tailscale.h"
#include "host_window.h"
#include "installer.h"
#include "ports.h"
#include "session_takeover.h"
#include "stranded.h"
#include "window_restore.h"
#include "updater.h"
#include "util.h"

// The media path is MSVC-only: Windows.Graphics.Capture and Media Foundation
// both arrive through C++/WinRT and the Windows SDK, neither of which mingw
// has. The cross-compiled build is a development convenience; what ships is
// built on Windows.
#include "media/log.h"
#ifdef SOLSTREAM_MEDIA
#include "media/audio.h"
#include "media/audio_source.h"
#include "media/capture.h"
#include "media/channel.h"
#include "media/session.h"
#endif
#include "vdd.h"

// Defined with ChooseCaptureDisplay; the watcher calls it.
void RechooseCaptureDisplayIfStale();

namespace {

using solstream::DeriveMediaKeys;
using solstream::EcdhSecret;
using solstream::FoldCase;
using solstream::FromHex;
using solstream::JsonEscape;
using solstream::LocalDataPath;
using solstream::NewEcdhKeyPair;
using solstream::RandomHex;
using solstream::ToHex;
using solstream::ToUtf8;
using solstream::ToWide;

constexpr unsigned short kDefaultPort = solstream::kDefaultPort;

// By default this socket is bound to loopback only and reached through an SSH
// tunnel; anywhere else a token is required. --listen-all is opt-in and warns.
constexpr const char* kLoopback = "127.0.0.1";
// 2 since auth v2: the token is proved rather than sent. A v1 host and a v2
// Mac cannot interoperate, and deliberately so -- see the client's refusal.
constexpr int kProtocolVersion = 2;

/// The display SolStream captures. Chosen at startup to the virtual one when
/// there is one, because a crop taken from a real monitor is a crop out of
/// somebody's actual screen -- and chosen again when the window's "Set up"
/// installs one or the displays change, which is why it is behind a lock: the
/// status, watcher and command threads all read it, and it can now change
/// under them.
std::mutex g_capture_mutex;
std::wstring g_capture_display;

std::wstring CaptureDisplay() {
    std::lock_guard<std::mutex> lock(g_capture_mutex);
    return g_capture_display;
}
/// How many Macs are connected right now, for the window.
std::atomic<int> g_clients_connected{0};
/// How many of those have presented the token, which is a different number and
/// the one the window actually wants.
///
/// A Mac that has connected but not authenticated is a Mac SITTING ON THE TOKEN
/// PROMPT — and the window used to treat it as a live session: it said
/// "Streaming to your Mac", and it hid the pairing token, on the grounds that a
/// visible token beside a live session is an invitation. Both are right about a
/// real session and exactly backwards here. The one thing the user needs at that
/// moment is the token, and connecting is what made it disappear.
std::atomic<int> g_clients_authenticated{0};

// ── Logging ──────────────────────────────────────────────────────────────────

void Log(const char* fmt, ...) {
    char line[2048];
    va_list args;
    va_start(args, fmt);
    const int written = std::vsnprintf(line, sizeof(line), fmt, args);
    va_end(args);
    if (written < 0) {
        return;
    }

    std::fprintf(stderr, "%s\n", line);
    std::fflush(stderr);

    // Opened per line rather than held: this runs for days, and a handle held
    // open for days is a log nobody can delete and a last line nobody can read
    // until the process exits.
    // Beside the token. Log() used to write only to stderr, and an installed
    // agent has no console, so a failure on any machine but a development box
    // said nothing at all.
    static const std::wstring path = LocalDataPath(L"solstream.log");
    if (path.empty()) {
        return;
    }
    // Serialised, and opened shared with other writers including DELETE: several
    // threads log through here, a narrower share mode silently lost the second
    // of two simultaneous lines, and rotation could not rename a file another
    // handle had open. The mutex makes check-size-then-rotate atomic.
    static std::mutex writing;
    std::lock_guard<std::mutex> held(writing);
    constexpr DWORD kShare = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, kShare,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    // Rolled at a megabyte, from the top. A log that grows without bound on a
    // machine nobody looks at is a disk that fills up eventually.
    LARGE_INTEGER size{};
    if (GetFileSizeEx(file, &size) && size.QuadPart > 1024 * 1024) {
        CloseHandle(file);
        DeleteFileW((path + L".1").c_str());
        MoveFileW(path.c_str(), (path + L".1").c_str());
        file = CreateFileW(path.c_str(), FILE_APPEND_DATA, kShare, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) {
            return;
        }
    }
    SYSTEMTIME now{};
    GetLocalTime(&now);
    // The process id, because one file can have two writers: the installed
    // agent and a development copy both started at logon once, and their lines
    // interleaved into what read as a single agent that bound its port, failed
    // to bind it, and carried on regardless.
    char stamped[2200];
    const int total = std::snprintf(stamped, sizeof(stamped),
                                    "%04d-%02d-%02d %02d:%02d:%02d  [%lu] %s\r\n",
                                    now.wYear, now.wMonth, now.wDay, now.wHour,
                                    now.wMinute, now.wSecond,
                                    (unsigned long) GetCurrentProcessId(), line);
    if (total > 0) {
        DWORD put = 0;
        WriteFile(file, stamped, (DWORD) total, &put, nullptr);
    }
    CloseHandle(file);
}

// ── Text ─────────────────────────────────────────────────────────────────────

/// An address somebody could actually type on their Mac.
///
/// The window used to show the BIND address, which for an installed host is
/// "0.0.0.0" — true, and useless: it is the answer to "which interfaces am I
/// listening on", printed under a label that asks "where should my Mac look".
///
/// Answered by asking the routing table, not by ranking a list of addresses.
///
/// A Windows PC has more addresses than it has networks. Hyper-V, WSL and
/// Docker each add a virtual switch with its own private range, and on this
/// project's own test machine the highest-ranked address by any sensible
/// heuristic was a 172.x.x.x address on a Hyper-V switch that no Mac
/// anywhere can reach, printed under "Address" as though it were the answer.
///
/// Connecting a UDP socket sends nothing; it only makes Windows choose the
/// interface it would use to reach the outside world, which is the interface a
/// Mac on the same network is on. Then ask the socket which address that was.
std::string RoutedLocalAddress() {
    SOCKET probe = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (probe == INVALID_SOCKET) {
        return {};
    }
    // A public address that is never contacted. 192.0.2.1 is TEST-NET-1,
    // reserved by RFC 5737 for exactly this kind of use, so it cannot collide
    // with anything real even if something did try to send.
    sockaddr_in target{};
    target.sin_family = AF_INET;
    target.sin_port = htons(53);
    inet_pton(AF_INET, "192.0.2.1", &target.sin_addr);

    std::string address;
    if (connect(probe, (sockaddr*) &target, sizeof(target)) == 0) {
        sockaddr_in local{};
        int size = sizeof(local);
        char text[INET_ADDRSTRLEN] = {0};
        if (getsockname(probe, (sockaddr*) &local, &size) == 0
            && inet_ntop(AF_INET, &local.sin_addr, text, sizeof(text)) != nullptr) {
            address = text;
        }
    }
    closesocket(probe);
    return address == "0.0.0.0" ? std::string() : address;
}

/// The fallback, for a machine with no route off itself at all. Ranked, and
/// 172.16/12 is ranked BELOW the VPN range rather than with the other private
/// blocks: in practice a 172.x address on Windows is a virtual switch far more
/// often than it is somebody's home network.
std::string BestLocalAddress() {
    if (const std::string routed = RoutedLocalAddress(); !routed.empty()) {
        return routed;
    }
    char host[256] = {0};
    if (gethostname(host, sizeof(host)) != 0) {
        return {};
    }
    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* found = nullptr;
    if (getaddrinfo(host, nullptr, &hints, &found) != 0) {
        return {};
    }

    std::string best;
    int best_rank = 0;
    for (addrinfo* at = found; at != nullptr; at = at->ai_next) {
        const auto* in = reinterpret_cast<const sockaddr_in*>(at->ai_addr);
        const unsigned long bits = ntohl(in->sin_addr.s_addr);
        const unsigned a = (bits >> 24) & 0xFF;
        const unsigned b = (bits >> 16) & 0xFF;

        int rank = 1;
        if (a == 127) {
            continue;  // loopback is never the answer to "where should my Mac look"
        } else if (a == 169 && b == 254) {
            continue;  // link-local means DHCP did not answer
        } else if (a == 192 && b == 168) {
            rank = 5;
        } else if (a == 10) {
            rank = 4;
        } else if (a == 100 && b >= 64 && b <= 127) {
            rank = 3;  // CGNAT, which in practice means Tailscale
        } else if (a == 172 && b >= 16 && b <= 31) {
            rank = 2;  // usually a Hyper-V, WSL or Docker switch
        }
        if (rank > best_rank) {
            char text[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &in->sin_addr, text, sizeof(text)) != nullptr) {
                best = text;
                best_rank = rank;
            }
        }
    }
    freeaddrinfo(found);
    return best;
}

/// This PC's name in UTF-8, as the greeting, the busy refusal and the discovery
/// answer all give it. Asked of the wide API: the ANSI one answers in the PC's
/// code page, so a PC called JÜRGEN-PC greeted the Mac with a byte its parser
/// would not take, and every connection to it ended on the first line.
std::string ComputerName() {
    wchar_t name[256] = {};
    DWORD size = 256;
    if (!GetComputerNameW(name, &size)) {
        return {};
    }
    return ToUtf8(std::wstring(name, size));
}

/// One log line per sentence. Several of the setup steps report a paragraph of
/// what they did, and a log line with newlines inside it is a log line nothing
/// downstream can count.
std::vector<std::string> SplitLines(const std::string& text) {
    std::vector<std::string> lines;
    size_t start = 0;
    while (start <= text.size()) {
        const size_t end = text.find('\n', start);
        const std::string line = text.substr(start, end == std::string::npos
                                                        ? std::string::npos
                                                        : end - start);
        if (!line.empty()) {
            lines.push_back(line);
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return lines;
}

// ── Displays ─────────────────────────────────────────────────────────────────

struct Display {
    std::string device_name;  // matches the DXGI DeviceName
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
        // Smallest area that still covers the request — and, among equals, the
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
            // built -- screen-sized, and almost entirely transparent. Treating
            // those as occluders reports a permanent false positive.
            //
            // It is also how a modern Windows dialog draws its shadow, so this
            // misses a real one: a Windows Security prompt about SolStream sat
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

    // Never our own host window. It is visible, titled, unowned and not a tool
    // window, so it passes every test below and a client could ask for its
    // handle, `place` it onto the captured display and `focus` it -- which would
    // put the pairing token, and anything else this program shows a human at the
    // PC, inside the video feed of the client doing the asking, with the clicks
    // to match.
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == GetCurrentProcessId()) {
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
    // Whether THIS window ended up in `above`, which the occlusion pass below
    // needs to know and cannot assume — see the note there.
    bool self_in_above = false;
    int cloaked = 0;
    if (visible
        && !(SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))
             && cloaked != 0)) {
        const RECT frame = VisibleFrame(window);
        if ((frame.right - frame.left) > 0 && (frame.bottom - frame.top) > 0) {
            wchar_t occluder_title[128] = {};
            GetWindowTextW(window, occluder_title, 128);
            state->above.emplace_back(frame, ToUtf8(occluder_title));
            self_in_above = true;
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
    // the Z-order. Report whichever covers the most of the tile — the first one
    // found is not necessarily the one a user would blame.
    //
    // The last entry is this window itself ONLY when the block at the top of
    // this function appended it, and that block has a test the reported list
    // does not: CanPaintOver. A window that fails it — any window built on
    // UpdateLayeredWindow, which is a great many of them — is still a user
    // window and still gets here, with nothing of its own in `above`. Skipping
    // the last entry unconditionally therefore skipped a real occluder, and it
    // skipped the nearest one, which is the one most likely to be over the tile.
    const size_t occluders =
        self_in_above ? state->above.size() - 1 : state->above.size();
    long long worst = 0;
    for (size_t i = 0; i < occluders; ++i) {
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

/// Resolve a window id from the wire, refusing our own windows.
///
/// Keeping the host window out of `windows` hides the handle but does not
/// protect it: every id here arrives from the client, and a handle that is
/// merely unlisted can still be guessed -- they are small, dense integers. This
/// is the one place `focus`, `place`, `topmost` and `lock` all pass through, so
/// it is the place the rule belongs.
HWND WindowFromId(uint64_t id) {
    auto handle = reinterpret_cast<HWND>(static_cast<uintptr_t>(id));
    if (!IsWindow(handle)) {
        return nullptr;
    }
    DWORD pid = 0;
    GetWindowThreadProcessId(handle, &pid);
    if (pid == GetCurrentProcessId()) {
        Log("[agent] refused a command aimed at SolStream's own window");
        return nullptr;
    }
    return handle;
}

uint64_t IdFromWindow(HWND window) {
    return static_cast<uint64_t>(reinterpret_cast<uintptr_t>(window));
}

/// The HMONITOR behind a `\\.\DISPLAYn` name.
///
/// The `displays` command names a display the way DXGI and the display settings
/// do, and the capture path wants a monitor handle. A device restart renumbers
/// these, which is a known trap on this machine -- so the lookup is done every
/// time rather than cached.
/// `maybe_unused`: both callers are inside SOLSTREAM_MEDIA, so a build without
/// it warns about a function that is not dead, merely not needed there.
[[maybe_unused]] HMONITOR MonitorFromDeviceName(const std::string& device_name) {
    struct Search {
        std::wstring wanted;
        HMONITOR found = nullptr;
    } search;
    search.wanted = ToWide(device_name);
    EnumDisplayMonitors(nullptr, nullptr,
        [](HMONITOR monitor, HDC, LPRECT, LPARAM param) -> BOOL {
            auto* state = reinterpret_cast<Search*>(param);
            MONITORINFOEXW info{};
            info.cbSize = sizeof(info);
            if (GetMonitorInfoW(monitor, &info)
                && state->wanted == info.szDevice) {
                state->found = monitor;
                return FALSE;
            }
            return TRUE;
        },
        reinterpret_cast<LPARAM>(&search));
    return search.found;
}

/// ForceForeground's requests, so that the threads it leaves behind when an
/// app hangs neither pile up nor put an old window in front; see foreground.h.
solstream::ForegroundTurns g_foreground_turns;

/// Actually give a window the keyboard focus, and say whether it worked.
///
/// SetForegroundWindow on its own is not enough. Windows refuses a foreground
/// change requested by a process that does not already own the foreground, and
/// the refusal is silent — the call returns FALSE and nothing happens. The
/// agent is a background process, so it is refused by default.
///
/// That matters far more than it sounds. The host injects keystrokes with
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
    // A hung application cannot take the foreground anyway, and every call
    // below would wait on its message loop -- and AttachThreadInput would tie
    // this thread's input to a queue nobody is reading.
    if (IsHungAppWindow(window)) {
        return false;
    }

    // All of it on a thread of its own, with a bound. The restore and the raise
    // wait on the window's app, which IsHungAppWindow calls hung only after
    // some seconds, and joined to the holder's queue the foreground calls wait
    // on the holder; either one hung would hold this thread and every command
    // behind it. See foreground.h.
    const solstream::ForegroundTurns::Turn turn = g_foreground_turns.Begin(window);
    const bool answered = solstream::RunWithin(solstream::kForegroundWaitMs, [window, turn] {
        if (IsIconic(window)) {
            ShowWindow(window, SW_RESTORE);
        }
        // Z-order first, and unconditionally: raising is not subject to the
        // foreground restriction, and it is what capture needs even in the
        // case where focus cannot be won. Synchronous: the foreground attempts
        // below depend on the window already being on top, and an asynchronous
        // raise lost the first of them in a live session -- "could not take
        // the foreground" until a later attempt landed.
        SetWindowPos(window, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        BringWindowToTop(window);

        // Overtaken while stuck in the raise: the newer request's window goes
        // in front, not this one.
        const HWND wanted = g_foreground_turns.Wanted(turn, window);
        if (wanted && wanted != window && !IsHungAppWindow(wanted)) {
            SetWindowPos(wanted, HWND_TOP, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
        }
        if (wanted && GetForegroundWindow() != wanted && !IsHungAppWindow(wanted)) {
            // A message queue of its own, which AttachThreadInput needs.
            MSG msg;
            PeekMessageW(&msg, nullptr, 0, 0, PM_NOREMOVE);
            const DWORD self_thread = GetCurrentThreadId();
            const HWND holder = GetForegroundWindow();
            const DWORD holder_thread =
                holder ? GetWindowThreadProcessId(holder, nullptr) : 0;
            // Not while an earlier request is still joined to a queue: a hang
            // would otherwise gather a stuck thread for every click.
            const bool attached =
                turn.mayJoin
                && solstream::JoinsHolderQueue(holder_thread, self_thread,
                                               holder && IsHungAppWindow(holder))
                && AttachThreadInput(self_thread, holder_thread, TRUE);

            SetForegroundWindow(wanted);
            // Both, because they answer different questions: which top-level
            // window is active, and which control inside it takes the keys.
            SetActiveWindow(wanted);
            SetFocus(wanted);

            // Overtaken while asking: put the newest request's window back in
            // front, which this thread may still do while it is joined.
            const HWND newest = g_foreground_turns.Wanted(turn, window);
            if (newest && newest != wanted && !IsHungAppWindow(newest)) {
                SetForegroundWindow(newest);
            }

            if (attached) {
                AttachThreadInput(self_thread, holder_thread, FALSE);
            }
        }
        g_foreground_turns.Finish(turn);
    });
    if (!answered) {
        Log("[focus] the window in front on the PC did not answer within %lu ms; "
            "not waiting for it", static_cast<unsigned long>(solstream::kForegroundWaitMs));
    }
    return GetForegroundWindow() == window;
}

// ── Launchable applications ──────────────────────────────────────────────────

struct AppEntry {
    std::string name;
    std::wstring path;  // the .lnk itself; ShellExecute resolves it
};

/// Walk a Start Menu tree collecting shortcuts.
///
/// The shortcuts are launched as-is rather than resolved to their targets: that
/// keeps the arguments, working directory and "run as" flags the installer chose.
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
        const std::wstring lowered = FoldCase(stem);
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
/// directory walk and removes the primitive rather than narrowing it — there is
/// no path a client can name that the user could not have clicked in their own
/// Start Menu.
///
/// Deliberately an exact match against paths this process constructed, not a
/// prefix or extension test. There is no traversal to reason about, no
/// canonicalisation to get subtly wrong, and no argument about what `..` means
/// halfway through a UNC path.
///
/// Cached, because membership is asked once per icon, and the list itself is
/// asked for every time the Mac redraws its picker -- which a window opening or
/// closing anywhere on the PC makes it do. Each walk of two Start Menu trees to
/// depth 4 is disk I/O on the agent's single command thread, with every other
/// command queued behind it. Ten seconds stale is fresh enough for "what is
/// installed".
///
/// No lock: commands are served one at a time, on one thread.
std::vector<AppEntry> g_advertised_apps;
std::set<std::wstring> g_advertised_paths;
ULONGLONG g_advertised_at = 0;
constexpr ULONGLONG kAdvertisedTtlMs = 10000;

/// The application list, walked again only when the cached one is stale.
const std::vector<AppEntry>& AdvertisedApps() {
    const ULONGLONG now = GetTickCount64();
    if (g_advertised_at == 0 || now - g_advertised_at > kAdvertisedTtlMs) {
        g_advertised_apps = EnumerateApps();
        g_advertised_paths.clear();
        for (const AppEntry& app : g_advertised_apps) {
            g_advertised_paths.insert(FoldCase(app.path));
        }
        g_advertised_at = now;
    }
    return g_advertised_apps;
}

bool IsAdvertisedApp(const std::wstring& path) {
    AdvertisedApps();
    return g_advertised_paths.count(FoldCase(path)) != 0;
}

/// Start an application and return the window it opens.
///
/// Matching on the launched process id alone is not enough: plenty of shortcuts
/// run a stub that spawns the real process, so the window that appears belongs to
/// a different pid. So take a snapshot first and watch for a window that was not
/// there before, preferring a pid match while there is still time to wait for one.
/// The user windows open right now, with their owning process: what the launch
/// wait compares against, without the titles, classes and occlusion pass that
/// EnumerateWindows computes for the picker.
struct OpenWindow {
    HWND handle;
    DWORD pid;
};

std::vector<OpenWindow> OpenUserWindows() {
    std::vector<OpenWindow> found;
    EnumWindows([](HWND window, LPARAM param) -> BOOL {
        if (IsUserWindow(window)) {
            DWORD pid = 0;
            GetWindowThreadProcessId(window, &pid);
            reinterpret_cast<std::vector<OpenWindow>*>(param)->push_back({window, pid});
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&found));
    return found;
}

uint64_t LaunchAndWaitForWindow(const std::wstring& path, DWORD timeout_ms) {
    std::set<HWND> before;
    for (const OpenWindow& window : OpenUserWindows()) {
        before.insert(window.handle);
    }
    const HWND foreground_before = GetForegroundWindow();

    SHELLEXECUTEINFOW request{};
    request.cbSize = sizeof(request);
    request.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI;
    request.lpVerb = L"open";
    request.lpFile = path.c_str();
    request.nShow = SW_SHOWNORMAL;
    // ShellExecuteEx may hand a shortcut to a shell extension, which is COM, and
    // Windows documents it as needing COM initialised on the calling thread.
    // Scoped to this call rather than the whole client thread, whose apartment
    // the media path's WinRT calls would otherwise inherit.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED
                                                | COINIT_DISABLE_OLE1DDE);
    const BOOL executed = ShellExecuteExW(&request);
    const DWORD execute_error = GetLastError();
    if (SUCCEEDED(com)) {
        CoUninitialize();
    }
    if (!executed) {
        Log("[agent] ShellExecuteEx failed: %lu", execute_error);
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
        for (const OpenWindow& window : OpenUserWindows()) {
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

// ── Clipboard ────────────────────────────────────────────────────────────────
//
// Text only, and deliberately so. Images and files raise questions this does not
// need to answer yet — how large is too large, what happens to a 2 GB file
// dropped on a link — whereas text is what people actually copy between a Mac and
// a remote application all day.
//
// Carried on the agent channel because it is the one authenticated, encrypted
// channel to this machine; a second port for it would be a second thing to
// secure.

// The transfer and its replies are in clipboard.cpp.

// ── Icons ────────────────────────────────────────────────────────────────────
//
// Sent as raw BGRA plus dimensions rather than PNG. Neither side then needs an
// image codec: the agent stays plain Win32 with no GDI+ lifetime to get wrong,
// and the Mac builds an NSImage straight from the bytes. An icon is a few KB, so
// the size difference does not matter over a LAN.

/// Render an HICON into a straight-alpha BGRA buffer.
///
/// Icons come back from Windows as two bitmaps — colour and mask — and the colour
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

// ── Authentication ───────────────────────────────────────────────────────────
//
// This socket can enumerate and move every window on the machine and launch
// arbitrary applications. Binding a single trusted address limits who can reach
// it, which is worth doing, but reachability is not authentication: anything else
// on that network still gets in. So a client must present a shared token before
// any command is accepted.
//
// The token is generated on first run and kept in the user's own profile. It is
// not encrypted, deliberately — the point is for the person at the machine to be
// able to read it and give it to their Mac.
//
// The token itself never crosses the wire: the client proves it holds it with
// an HMAC over a per-connection challenge, and the same exchange agrees the
// forward-secret keys the channel is encrypted with from then on. The
// cryptography is in agent_crypto.cpp; docs/architecture.md has the whole
// handshake.

std::string g_token;
bool g_require_auth = true;
/// Bumped and persisted on every media session. It is in the key-schedule
/// transcript so that two sessions cannot derive the same keys even on a machine
/// whose RNG is repeating itself after an image restore -- the one failure that
/// would otherwise be silent and total. Persisted beside the token, because an
/// image restore restarts the process too: a counter kept only in memory would
/// start from zero again, with the same RNG stream, and repeat the keys.
unsigned long long g_media_count = 0;

std::string LoadOrCreateToken() {
    const std::wstring path = LocalDataPath(L"agent.token");
    if (path.empty()) {
        return {};
    }
    std::string existing;
    if (solstream::ReadSmallFile(path, 127, existing) && !existing.empty()) {
        while (!existing.empty()
               && (existing.back() == '\n' || existing.back() == '\r' || existing.back() == ' ')) {
            existing.pop_back();
        }
        if (existing.size() >= 16) {
            return existing;
        }
    }

    const std::string fresh = RandomHex(16);
    if (fresh.empty()) {
        return {};
    }
    solstream::WriteWholeFile(path, fresh);
    return fresh;
}

/// The counter as it stood when this machine last opened a media session.
///
/// A missing or unreadable file reads as zero, which is where an agent that has
/// never streamed starts anyway. That is the honest answer rather than a safe
/// one -- if the file cannot be read the counter repeats, exactly as it did
/// before this existed -- but it is not a reason to refuse to stream.
unsigned long long LoadMediaCount() {
    const std::wstring path = LocalDataPath(L"media.count");
    if (path.empty()) {
        return 0;
    }
    std::string text;
    if (!solstream::ReadSmallFile(path, 31, text) || text.empty()) {
        return 0;
    }
    return std::strtoull(text.c_str(), nullptr, 10);
}

/// Written before the keys derived from it are used, not after: a crash between
/// deriving and writing must leave the counter ahead of what was used, never
/// behind it. Ahead costs a skipped number; behind hands the next session the
/// same transcript.
void SaveMediaCount(unsigned long long count) {
    const std::wstring path = LocalDataPath(L"media.count");
    if (path.empty()) {
        return;
    }
    solstream::WriteWholeFile(path, std::to_string(count));
}

// ── Geometry lock ────────────────────────────────────────────────────────────
//
// The Mac crops a FIXED rectangle out of the shared canvas, so a window resized
// on the host stops lining up with it and the stream shows desktop where the
// application used to be. Size has to be driven from the macOS window — the thing
// the user is actually looking at — and only from there.
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

#ifdef SOLSTREAM_MEDIA
/// The agent channel's own encryption, keyed by what auth v2 already agreed.
/// Guarded by g_send_cs on the way out; the receive side is single-threaded.
solstream::media::Channel g_channel;
/// Derived while answering the auth request, promoted once that answer -- the
/// last message that crosses in the clear -- has actually gone out.
solstream::media::Channel g_pending_channel;
/// WHICH SOCKET THOSE KEYS BELONG TO. The channel is a global and the sockets
/// are not, and that difference cost a paired Mac its session: a SECOND Mac
/// knocking while one was connected was refused with a `busy` line, and
/// SendLine sealed that line with the FIRST Mac's keys before writing it down
/// the second Mac's socket. The record the first Mac was owed never arrived,
/// its counter was one behind from then on, and the next real message failed
/// its tag -- so an unrelated third party could end a working session just by
/// connecting. The second Mac could not read the refusal either, since it was
/// encrypted to keys it had never seen. Binding the keys to their socket makes
/// both impossible: anything addressed elsewhere goes out in the clear, which
/// is what a client that has negotiated nothing is expecting to read.
SOCKET g_channel_socket = INVALID_SOCKET;
#endif

/// Which cursor watcher is the current one.
///
/// A shared stop flag was not enough, and is gone. StopCursorWatcher waits two
/// seconds for the thread to leave, and the thread can be inside SendLine for
/// far longer than that -- SO_SNDTIMEO on this socket is thirty seconds, so a client whose
/// receive window has filled up holds it there. When the wait timed out the
/// handle was closed and the thread abandoned, and the NEXT client's
/// StartCursorWatcher then cleared the stop flag out from under it: the
/// abandoned thread carried on for ever, pushing cursor shapes down the new
/// client's socket beside the new watcher's own. Each thread now keeps the
/// generation it was started with and exits when it is no longer the current
/// one, which no later Start can undo.
volatile LONG g_cursor_generation = 0;

/// Send one line to the authenticated client, if there is one, and say
/// whether a send failed -- which means the client has gone; the serving
/// thread notices that on its own recv.
///
/// Silent until that client has proved who it is. The socket is read and
/// written to under the send lock, which the client's departure also takes
/// before clearing it: released between the two, the socket could be closed
/// and its value reissued to the next connection, and the line would land
/// there. A CRITICAL_SECTION is recursive, so SendLine taking it again is fine.
///
/// `generation` is the cursor watcher's own, or 0 for any other push. Checked
/// inside the lock as well: a watcher that waited there past
/// StopCursorWatcher's timeout belongs to nobody.
bool PushLine(const std::string& line, LONG generation = 0) {
    if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
        return true;
    }
    bool sent = true;
    EnterCriticalSection(&g_send_cs);
    const SOCKET client = g_push_client;
    if (client != INVALID_SOCKET
        && (generation == 0
            || InterlockedCompareExchange(&g_cursor_generation, 0, 0) == generation)) {
        sent = SendLine(client, line);
    }
    LeaveCriticalSection(&g_send_cs);
    return sent;
}

/// The frame bits a geometry lock takes away, and the only style bits the agent
/// ever writes. Everything else in the style word belongs to the application --
/// WS_MAXIMIZE, WS_DISABLED while it shows a modal dialog, WS_CAPTION when it
/// goes full screen -- and changes under us during a session, so a lock and its
/// release toggle these two against the style as it is NOW. Writing back a
/// whole word saved earlier put a stale WS_MAXIMIZE on a window that had just
/// been restored, and a stale WS_DISABLED on one whose dialog had since closed.
constexpr LONG_PTR kLockedStyleBits = WS_THICKFRAME | WS_MAXIMIZEBOX;

struct WindowLock {
    HWND window = nullptr;
    RECT desired{};           // client area, in virtual-desktop coordinates
    /// Which of kLockedStyleBits the lock removed, and so owes back.
    LONG_PTR removed_style = 0;
    /// Who owned this window when the agent first touched it.
    ///
    /// Windows recycles window handles, so `IsWindow` on a handle whose window
    /// has been destroyed can come back true — pointing at something else
    /// entirely. Without this the watcher would go on enforcing a geometry,
    /// a topmost band and a stripped frame on an unrelated application, and the
    /// Mac would go on showing whatever now occupies those pixels rather than
    /// noticing that the thing it was streaming is gone.
    DWORD pid = 0;
    /// When that process started, so a record of this slot written to disk
    /// names it and no later process given the same pid. 0 when unknown.
    uint64_t process_created = 0;
    // How the window looked before the agent touched it. Everything the agent
    // changes has to be recorded, because the client that changed it may never
    // come back to change it again: a Mac that loses its network leaves the
    // window exactly as it was mid-session.
    WINDOWPLACEMENT saved_placement{};
    bool saved_topmost = false;
    bool geometry_locked = false;  // the watcher holds this one in place
    bool active = false;           // the agent owes this window a restore
    /// Bumped on every claim, so the watcher can tell that the slot it read a
    /// moment ago is still the same tenancy.
    ///
    /// The watcher copies `window` and `desired` under the lock and then lets it
    /// go before doing the slow part -- ShowWindow and SetWindowPos wait on
    /// another process's message pump. A release landing in that gap would
    /// leave it holding coordinates on the capture display for a window that
    /// has just been put back on a real monitor, and it would drag it straight
    /// back to a display nobody can see.
    uint64_t generation = 0;
};

CRITICAL_SECTION g_lock_cs;
WindowLock g_locks[kMaxLocks];
/// Serialises writing down what is owed; see RecordOwedWindows.
CRITICAL_SECTION g_owed_cs;
/// Windows owed a restore outside the active slots: left by a stopped host or
/// a failed cleanup, or still being restored. Written down with the slots so a
/// skipped or failed restore does not lose the debt. Guarded by g_lock_cs.
std::vector<solstream::OwedWindow> g_left_behind;
/// Windows an older cleanup is still touching. Claims wait until that cleanup
/// finishes, so it cannot move a window belonging to a new session. Same lock.
std::vector<uint64_t> g_restoring_windows;
constexpr int kClaimRestoreInProgress = -2;
uint64_t g_lock_generation = 0;   // guarded by g_lock_cs

/// Is this window's thread too busy to answer messages?
///
/// SetWindowPos, ShowWindow, SetWindowLongPtr and SetWindowPlacement on a window
/// belonging to another thread wait for that thread to process the request,
/// with no timeout. An application hung inside its message loop therefore hung
/// whichever agent thread touched it: the watcher, the command thread, or the
/// disconnect cleanup -- and a cleanup stuck there never released the client
/// slot, so every later Mac was turned away until the host was restarted. So
/// every cross-process window write below asks first, and the ones whose result
/// nothing measures afterwards are made asynchronous as well.
bool Unresponsive(HWND window) {
    return IsHungAppWindow(window) != FALSE;
}

/// When a process started (GetProcessTimes, in 100 ns units), or 0 when it
/// cannot be opened -- it has gone, or it is protected.
uint64_t ProcessCreationTime(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        return 0;
    }
    FILETIME created{}, exited{}, kernel{}, user{};
    const bool ok = GetProcessTimes(process, &created, &exited, &kernel, &user) != FALSE;
    CloseHandle(process);
    return ok ? (static_cast<uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime
              : 0;
}

bool PlaceClientArea(HWND window, int x, int y, int width, int height,
                     RECT* out_client = nullptr, long long* out_error = nullptr);
void RecordOwedWindows();

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

/// The client-area sizes this window accepts, in pixels, and whether it can be
/// resized at all.
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
struct ClientLimits {
    POINT minimum{1, 1};
    /// Zero on an axis the application does not limit.
    POINT maximum{0, 0};
    /// Whether the user could resize it before SolStream touched it.
    bool resizable = true;
};

ClientLimits ClientSizeLimits(HWND window) {
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
    //
    // AT THE WINDOW'S OWN DPI. AdjustWindowRectEx reads metrics for the calling
    // thread's DPI context and knows nothing about which display the window is
    // on, so on a host whose primary runs at 100% and whose capture display runs
    // at 200% it measured the frame at the wrong scale. On this project's own dev
    // box the two agree -- the virtual display IS primary -- so it changes
    // nothing there, which is exactly why it was worth changing: the wrong answer
    // was invisible on the one machine it gets tested on.
    //
    // Note what this does NOT explain. Character Map reports a client-area
    // minimum HEIGHT of 1 px here, and that is the honest answer rather than a
    // miscalculation: it declares no minimum of its own, so the prefill stands at
    // SM_CYMINTRACK, which is caption-plus-border and almost exactly the furniture
    // being subtracted. A window whose only constraint is "at least as tall as my
    // own title bar" genuinely has no client-area floor. Do not "fix" that by
    // inventing one -- an earlier attempt at this substituted a floor derived from
    // the same two metrics, which is the same number by a longer route.
    const UINT dpi = GetDpiForWindow(window);
    const DWORD style = (DWORD) GetWindowLongPtrW(window, GWL_STYLE);
    const DWORD exStyle = (DWORD) GetWindowLongPtrW(window, GWL_EXSTYLE);
    RECT furniture{0, 0, 0, 0};
    if (dpi == 0 || !AdjustWindowRectExForDpi(&furniture, style, FALSE, exStyle, dpi)) {
        furniture = RECT{0, 0, 0, 0};
        AdjustWindowRectEx(&furniture, style, FALSE, exStyle);
    }
    ClientLimits limits;
    const LONG furnitureW = furniture.right - furniture.left;
    const LONG furnitureH = furniture.bottom - furniture.top;
    limits.minimum.x = std::max<LONG>(1, info.ptMinTrackSize.x - furnitureW);
    limits.minimum.y = std::max<LONG>(1, info.ptMinTrackSize.y - furnitureH);
    // A maximum only when the application set one: the prefill is the size of
    // the whole virtual desktop plus borders, which is "no limit", and saying
    // so as a number would cap the Mac window at an arbitrary size.
    if (info.ptMaxTrackSize.x < GetSystemMetrics(SM_CXMAXTRACK)) {
        limits.maximum.x = std::max<LONG>(limits.minimum.x, info.ptMaxTrackSize.x - furnitureW);
    }
    if (info.ptMaxTrackSize.y < GetSystemMetrics(SM_CYMAXTRACK)) {
        limits.maximum.y = std::max<LONG>(limits.minimum.y, info.ptMaxTrackSize.y - furnitureH);
    }

    // Resizable means a sizing border -- as the window had it before the lock
    // took it away. A dialog like Character Map has none: Windows lets
    // SetWindowPos make it any size, so it reports no meaningful minimum, but
    // its controls are laid out once for one size and a smaller window simply
    // cuts them off. The Mac has to hold such a window at the size it is.
    limits.resizable = (style & WS_THICKFRAME) != 0;
    if (!limits.resizable) {
        EnterCriticalSection(&g_lock_cs);
        for (int i = 0; i < kMaxLocks; ++i) {
            if (g_locks[i].active && g_locks[i].window == window) {
                limits.resizable = (g_locks[i].removed_style & WS_THICKFRAME) != 0;
                break;
            }
        }
        LeaveCriticalSection(&g_lock_cs);
    }
    return limits;
}

/// How tall the title bar an application draws inside its own client area is,
/// in pixels; 0 when it draws none, or when that cannot be told.
///
/// A standard title bar sits above the client area, outside the Mac's crop
/// already. Chrome, Discord, Explorer and the like draw theirs inside it, so
/// their minimise, maximise and close reach the stream, and the Mac can leave
/// the strip out of the picture when the person asks it to.
///
/// Asked of the application rather than assumed: WM_NCHITTEST down a few
/// columns from the top of the client area, the way Windows itself finds out
/// where a click would drag the window or press a caption button. The strip is
/// the rows where any column answers as caption or as one of its buttons -- a
/// tab under one column, the empty strip or a button under another -- and it
/// ends at the first row where none does. A row is answered by whichever
/// column the application says is caption, so Discord's (drag in the middle,
/// its own buttons at the right, which are client) and Chrome's (tabs in the
/// middle, Windows-style buttons at the right) both measure.
///
/// Zero rather than a guess when the answer would be wrong to act on: a window
/// that is DPI-virtualised (the point would be scaled before it reached the
/// application), one that answers caption all the way down (a splash, or a
/// window draggable anywhere), one that is hung, and a strip thinner than a
/// border.
int TitleStripHeight(HWND window) {
    const RECT frame = VisibleFrame(window);
    const RECT client = ClientAreaInScreen(window);
    if (client.top - frame.top > 4) {
        return 0;
    }
    if (GetAwarenessFromDpiAwarenessContext(GetWindowDpiAwarenessContext(window))
            != DPI_AWARENESS_PER_MONITOR_AWARE || Unresponsive(window)) {
        return 0;
    }
    const UINT window_dpi = GetDpiForWindow(window);
    const int dpi = window_dpi ? (int) window_dpi : 96;
    const LONG width = client.right - client.left;
    const LONG height = client.bottom - client.top;
    if (width < MulDiv(160, dpi, 96) || height < MulDiv(80, dpi, 96)) {
        return 0;
    }
    // Under the close button, under maximise, and two across the middle.
    const LONG columns[] = {
        client.right - MulDiv(23, dpi, 96), client.right - MulDiv(69, dpi, 96),
        client.left + width / 2, client.left + width / 4,
    };
    const ULONGLONG started = GetTickCount64();
    bool gave_up = false;
    // What the application says a point is. Explorer and Windows Terminal put
    // a child window over their title strip that answers for it, while the
    // window itself says client there, so the child under the point is asked
    // as well; a child that is see-through for hit-testing defers to its parent.
    auto ask = [&](HWND target, LONG x, LONG y, LRESULT& hit) {
        DWORD_PTR answer = HTNOWHERE;
        if (!SendMessageTimeoutW(target, WM_NCHITTEST, 0, MAKELPARAM((short) x, (short) y),
                                 SMTO_ABORTIFHUNG | SMTO_BLOCK, 100, &answer)) {
            gave_up = true;
            return false;
        }
        hit = (LRESULT) answer;
        return true;
    };
    auto child_under = [&](LONG x, LONG y) {
        HWND deepest = window;
        for (int depth = 0; depth < 8; ++depth) {
            POINT point{x, y};
            ScreenToClient(deepest, &point);
            HWND next = ChildWindowFromPointEx(deepest, point,
                CWP_SKIPINVISIBLE | CWP_SKIPDISABLED | CWP_SKIPTRANSPARENT);
            if (!next || next == deepest) {
                break;
            }
            deepest = next;
        }
        return deepest;
    };
    auto row = [&](LONG y, bool& caption) {
        caption = false;
        bool title = false;
        for (const LONG x : columns) {
            if (GetTickCount64() - started > 300) {
                gave_up = true;
                return false;
            }
            LRESULT hit = HTNOWHERE;
            if (!ask(window, x, y, hit)) {
                return false;
            }
            if (hit == HTCLIENT) {
                const HWND child = child_under(x, y);
                LRESULT child_hit = HTNOWHERE;
                if (child != window && !ask(child, x, y, child_hit)) {
                    return false;
                }
                if (child != window && child_hit != HTTRANSPARENT && child_hit != HTNOWHERE) {
                    hit = child_hit;
                }
            }
            switch (hit) {
            case HTCAPTION: case HTSYSMENU: case HTMINBUTTON: case HTMAXBUTTON:
            case HTCLOSE: case HTHELP:
                caption = true;
                title = true;
                break;
            // The resize edge along the top belongs to the strip, but alone it
            // is not one.
            case HTTOP: case HTTOPLEFT: case HTTOPRIGHT:
                title = true;
                break;
            default:
                break;
            }
        }
        return title;
    };

    const int most = std::min<int>(MulDiv(96, dpi, 96), (int) height / 3);
    const int step = std::max(1, MulDiv(2, dpi, 96));
    bool saw_caption = false;
    int last_title = -1;
    int first_plain = -1;
    for (int y = 0; y < most; y += step) {
        bool caption = false;
        if (!row(client.top + y, caption)) {
            first_plain = y;
            break;
        }
        saw_caption = saw_caption || caption;
        last_title = y;
    }
    if (gave_up || !saw_caption || first_plain < 0) {
        return 0;
    }
    // Sampled every `step`; the edge is somewhere after the last title row.
    int strip = first_plain;
    for (int y = last_title + 1; y < first_plain; ++y) {
        bool caption = false;
        if (!row(client.top + y, caption)) {
            strip = y;
            break;
        }
    }
    return (gave_up || strip < MulDiv(8, dpi, 96)) ? 0 : strip;
}

/// TitleStripHeight for the window being placed, measured at most once a
/// second. A drag on the Mac places the window at the round trip's rate, and
/// the strip does not change with the width; a second is soon enough for an
/// application that lays itself out again after moving onto the capture
/// display. Only the command thread places windows.
int CachedTitleStripHeight(HWND window) {
    static HWND measured = nullptr;
    static UINT measured_dpi = 0;
    static ULONGLONG measured_at = 0;
    static int height = 0;
    const UINT dpi = GetDpiForWindow(window);
    const ULONGLONG now = GetTickCount64();
    if (window != measured || dpi != measured_dpi || now - measured_at > 1000) {
        height = TitleStripHeight(window);
        measured = window;
        measured_dpi = dpi;
        measured_at = now;
    }
    return height;
}

/// The file name of the program that owns this window, "Discord.exe", for the
/// Mac to remember per-application choices by; empty when Windows will not say.
std::string ProgramName(HWND window) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    HANDLE process = pid ? OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) : nullptr;
    if (!process) {
        return {};
    }
    wchar_t path[MAX_PATH] = {0};
    DWORD length = MAX_PATH;
    const BOOL ok = QueryFullProcessImageNameW(process, 0, path, &length);
    CloseHandle(process);
    if (!ok) {
        return {};
    }
    const wchar_t* name = std::wcsrchr(path, L'\\');
    return ToUtf8(name ? name + 1 : path);
}

/// A window's title for the log, read wide and converted like the one the
/// occlusion push sends the Mac. The ANSI call answers in the PC's code page,
/// and a log holding both encodings garbles one or the other in whatever it is
/// opened with -- while its focus, pointer and occlusion lines are read side by
/// side to explain one fault.
std::string WindowTitleForLog(HWND window) {
    wchar_t title[128] = {};
    GetWindowTextW(window, title, 128);
    return ToUtf8(title);
}

/// A window's class name for the log, read the same way for the same reason.
std::string WindowClassForLog(HWND window) {
    wchar_t cls[96] = {};
    GetClassNameW(window, cls, 96);
    return ToUtf8(cls);
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

#ifdef SOLSTREAM_MEDIA
/// The process whose sound belongs to a window.
///
/// Its owner, almost always. A Store app's window is a frame drawn by
/// ApplicationFrameHost, and the app itself -- the process that plays its
/// sound -- owns a child window inside that frame, so that child's owner is
/// the one wanted. Only for that frame: plenty of programs host another
/// process's window inside their own, and the host is the one being streamed.
DWORD SoundOwner(HWND window) {
    DWORD owner = 0;
    GetWindowThreadProcessId(window, &owner);
    wchar_t className[64] = {0};
    GetClassNameW(window, className, 63);
    if (wcscmp(className, L"ApplicationFrameWindow") != 0) {
        return owner;
    }
    struct Search {
        DWORD frame;
        DWORD app;
    } search{owner, 0};
    EnumChildWindows(window, [](HWND child, LPARAM param) -> BOOL {
        auto* found = reinterpret_cast<Search*>(param);
        DWORD pid = 0;
        GetWindowThreadProcessId(child, &pid);
        if (pid != 0 && pid != found->frame) {
            found->app = pid;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&search));
    return search.app ? search.app : owner;
}

/// The processes of every window the Mac is managing: whose sound is the
/// stream's, when it asked for the streamed apps' alone. Read on the audio
/// thread; the windows are copied out under the lock and asked about outside it.
std::vector<unsigned long> StreamedProcesses() {
    HWND windows[kMaxLocks] = {};
    int count = 0;
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active && g_locks[i].window) {
            windows[count++] = g_locks[i].window;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    std::vector<unsigned long> pids;
    for (int i = 0; i < count; ++i) {
        if (IsWindow(windows[i])) {
            pids.push_back(SoundOwner(windows[i]));
        }
    }
    return pids;
}
#endif

/// Tell the Mac a window it was streaming has been closed.
///
/// Pushed the moment the watcher notices, rather than left for the Mac's
/// once-a-second poll to discover. The poll is still there as a backstop, but a
/// window whose application has quit goes on showing the last frame it ever
/// sent until something says otherwise, and up to a second of a dead
/// application's corpse is a second too many.
void NotifyWindowClosed(uint64_t id) {
    // Unlike the cursor thread, this watcher is never joined before the socket
    // closes, which is why PushLine reads it under the send lock.
    PushLine("{\"type\":\"closed\",\"id\":" + std::to_string(id) + "}");
}

/// Set when a window somewhere on this PC has come, gone or been renamed, with
/// the tick it last happened on. Written by the event hook on the message-loop
/// thread and read by the watcher, hence atomics rather than the lock.
std::atomic<bool> g_window_set_dirty{false};
std::atomic<ULONGLONG> g_window_set_touched{0};
/// Set when a window the picker lists has only been renamed.
///
/// Kept apart from the set changing because titles tick: a browser playing
/// media, a terminal running a build, a clock in a caption. Every rename used to
/// be a `windowsChanged`, and every one of those has the Mac fetch the window
/// list AND the application list -- a full enumeration and a Start Menu walk
/// two and a half times a second, for as long as some title kept moving.
std::atomic<bool> g_window_titles_dirty{false};
/// When a rename last went out. Watcher thread only.
ULONGLONG g_titles_pushed_at = 0;
constexpr ULONGLONG kTitlePushIntervalMs = 5000;
/// Wakes the watcher early, so a change waits on the debounce rather than on
/// the idle cadence.
HANDLE g_watcher_wake = nullptr;
/// The windows the picker lists, as far as the hook has seen. Hook thread only:
/// out-of-context hooks are delivered on the thread that set them.
std::set<HWND> g_listed_windows;

/// Fill g_listed_windows with what is open now, so the first event for a window
/// that was already listed is not mistaken for it arriving.
void SeedListedWindows() {
    EnumWindows([](HWND window, LPARAM) -> BOOL {
        if (IsUserWindow(window)) {
            g_listed_windows.insert(window);
        }
        return TRUE;
    }, 0);
}

/// The picker's list is not a photograph: an application quit on the PC must
/// stop being offerable, and one started there must become pickable, without
/// reconnecting.
///
/// The hook fires for every object on the desktop, so it is filtered to
/// top-level windows and then to MEMBERSHIP of the listed set -- a window
/// becoming or ceasing to be one the picker shows. Hidden helper windows,
/// tooltips and anything invisible change nothing the Mac draws, and used to
/// trigger a refresh all the same. The push itself is debounced on the watcher
/// thread, because opening one application emits a burst of these.
void CALLBACK WindowSetChanged(HWINEVENTHOOK, DWORD event, HWND window,
                               LONG object, LONG child, DWORD, DWORD) {
    if (object != OBJID_WINDOW || child != CHILDID_SELF || !window) {
        return;
    }
    const bool was = g_listed_windows.count(window) != 0;
    // Asked before the top-level test: a destroyed window has no ancestor left.
    const bool is = event != EVENT_OBJECT_DESTROY
                 && GetAncestor(window, GA_ROOT) == window && IsUserWindow(window);
    if (was == is) {
        if (is && event == EVENT_OBJECT_NAMECHANGE) {
            g_window_titles_dirty.store(true);
        }
        return;
    }
    if (is) {
        g_listed_windows.insert(window);
    } else {
        g_listed_windows.erase(window);
    }
    g_window_set_touched.store(GetTickCount64());
    g_window_set_dirty.store(true);
    if (g_watcher_wake) {
        SetEvent(g_watcher_wake);
    }
}

/// Tell the Mac the window set moved, once the burst has settled -- or that a
/// listed window was renamed, at most every kTitlePushIntervalMs.
void NotifyWindowsChangedIfSettled() {
    const ULONGLONG now = GetTickCount64();
    bool push = false;
    // Long enough to swallow an application's startup burst, short enough that
    // it still feels immediate to someone watching the picker.
    if (g_window_set_dirty.load() && now - g_window_set_touched.load() >= 400) {
        g_window_set_dirty.store(false);
        push = true;
    }
    if (!push && g_window_titles_dirty.load()
        && now - g_titles_pushed_at >= kTitlePushIntervalMs) {
        push = true;
    }
    if (!push) {
        return;
    }
    // One list fetch answers both, so a rename pending alongside goes with it.
    g_window_titles_dirty.store(false);
    g_titles_pushed_at = now;

    // Deliberately just a nudge, with no list attached. The Mac asks for
    // `windows` when it wants them, and it needs `apps` in the same breath to
    // redraw the picker anyway — so sending a list here would either be half
    // the answer or a second copy of one it is about to fetch.
    PushLine("{\"type\":\"windowsChanged\"}");
}

/// Windows already carried back to a real monitor. Kept so that someone who
/// deliberately drags one onto the capture display is not fought over it.
/// Watcher thread only.
std::vector<HWND> g_rescued;

/// Where a stranded window should go, if the capture display is one nobody can
/// see. False when SolStream is capturing a real monitor: what is on that is
/// visible to the person sitting at the PC, and rearranging their windows
/// because a dialog opened would be interference, not help.
bool WorkOutCaptureDisplayIsInvisible(RECT& capture, RECT& rescue_to) {
    const std::wstring capture_display = CaptureDisplay();
    if (capture_display.empty()) {
        return false;
    }
    const std::vector<Display> displays = EnumerateDisplays();
    const Display* captured = nullptr;
    const Display* primary = nullptr;
    for (const Display& display : displays) {
        if (ToWide(display.device_name) == capture_display) {
            captured = &display;
        }
        if (display.primary) {
            primary = &display;
        }
    }
    if (!captured || !primary || captured == primary) {
        return false;
    }
    if (captured->adapter.find("Virtual Display") == std::string::npos) {
        return false;
    }
    capture = captured->bounds;
    rescue_to = primary->bounds;
    return true;
}

/// The same answer, cached for a few seconds. It moves only when the display
/// layout does, and working it out enumerates every monitor and asks the
/// display stack for each one's adapter -- which, asked on every watcher tick,
/// was most of what an idle host spent its time on. Watcher thread only.
bool CaptureDisplayIsInvisible(RECT& capture, RECT& rescue_to) {
    static bool known = false;
    static bool invisible = false;
    static RECT cached_capture{};
    static RECT cached_rescue_to{};
    static ULONGLONG checked_at = 0;
    const ULONGLONG now = GetTickCount64();
    if (!known || now - checked_at >= 3000) {
        known = true;
        checked_at = now;
        invisible = WorkOutCaptureDisplayIsInvisible(cached_capture, cached_rescue_to);
    }
    capture = cached_capture;
    rescue_to = cached_rescue_to;
    return invisible;
}

struct StrandedSearch {
    std::vector<HWND> found;
    RECT capture{};
    /// The streamed windows, copied out of their slots once per search rather
    /// than with the lock taken for every window on the desktop.
    std::vector<solstream::StreamedWindow> streamed;
};

BOOL CALLBACK StrandedProc(HWND window, LPARAM param) {
    auto* search = reinterpret_cast<StrandedSearch*>(param);
    // Before anything is skipped: EnumWindows goes from the top of the
    // z-order down, and what comes after a streamed window is behind it.
    solstream::NoteMet(window, search->streamed);

    if (!IsWindowVisible(window) || IsIconic(window)) {
        return TRUE;
    }
    // Titled only. A person can act on a window they can name, and this is the
    // line that separates the Windows Security dialog — which they need — from
    // the shell's untitled modal dimmer behind it, which is a full-screen sheet
    // there is no point carrying anywhere.
    if (GetWindowTextLengthW(window) == 0) {
        return TRUE;
    }
    const LONG_PTR ex_style = GetWindowLongPtrW(window, GWL_EXSTYLE);
    if (ex_style & WS_EX_TRANSPARENT) {
        return TRUE;  // click-through overlay; moving it would break it
    }
    int cloaked = 0;
    if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked, sizeof(cloaked)))
        && cloaked != 0) {
        return TRUE;
    }
    // The shell's own furniture exists on every display and belongs to none.
    char cls[64] = {0};
    GetClassNameA(window, cls, sizeof(cls) - 1);
    for (const char* shell : {"Progman", "WorkerW", "Shell_TrayWnd",
                              "Shell_SecondaryTrayWnd", "SHELLDLL_DefView"}) {
        if (std::strcmp(cls, shell) == 0) {
            return TRUE;
        }
    }

    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid == GetCurrentProcessId()) {
        return TRUE;
    }
    RECT rect{};
    if (!GetWindowRect(window, &rect) || rect.right <= rect.left || rect.bottom <= rect.top) {
        return TRUE;
    }
    // The streamed windows live on this display on purpose, and so do their own
    // menus and dialogs — those reach the user through the video, as part of the
    // application they are looking at. Including the ones another process puts
    // up for it, which say so by their owner; see stranded.h.
    std::vector<solstream::OwnerLink> owners;
    for (HWND owner = GetWindow(window, GW_OWNER); owner && owners.size() < 8;
         owner = GetWindow(owner, GW_OWNER)) {
        solstream::OwnerLink link;
        link.window = owner;
        GetWindowThreadProcessId(owner, &link.pid);
        owners.push_back(link);
    }
    if (solstream::PartOfTheStream(window, pid, owners, rect, (ex_style & WS_EX_TOPMOST) != 0,
                                   search->streamed)) {
        return TRUE;
    }
    // By its middle, so a dialog straddling the edge of two displays is judged
    // by where it mostly is rather than by one stray corner.
    const POINT middle{(rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2};
    if (!PtInRect(&search->capture, middle)) {
        return TRUE;
    }

    if (std::find(g_rescued.begin(), g_rescued.end(), window) != g_rescued.end()) {
        return TRUE;
    }
    search->found.push_back(window);
    return TRUE;
}

/// Carry anything that is not ours off the capture display and onto a monitor.
///
/// The capture display has no panel. SolStream created it so that a streamed
/// application could sit somewhere nothing else would ever cover it — and the
/// consequence nobody planned for is that anything Windows puts there is
/// invisible to the person at the PC. A Windows Firewall prompt landed on it and
/// stayed unanswered for days: absent from every monitor, and present in the
/// video only when it happened to overlap the crop. Its system-modal dimmer took
/// every click meanwhile, so the streamed application looked perfectly healthy
/// and completely dead.
///
/// Moving it is not answering it. Whatever the dialog asks stays the user's
/// decision — this only puts the question somewhere they can read it.
void RescueStrandedWindows() {
    StrandedSearch search;
    RECT rescue_to{};
    if (!CaptureDisplayIsInvisible(search.capture, rescue_to)) {
        return;
    }
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active) {
            solstream::StreamedWindow slot;
            slot.window = g_locks[i].window;
            slot.pid = g_locks[i].pid;
            slot.desired = g_locks[i].desired;
            slot.held = g_locks[i].geometry_locked;
            search.streamed.push_back(slot);
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    EnumWindows(StrandedProc, reinterpret_cast<LPARAM>(&search));

    for (HWND window : search.found) {
        RECT rect{};
        if (!GetWindowRect(window, &rect)) {
            continue;
        }
        const LONG width = rect.right - rect.left;
        const LONG height = rect.bottom - rect.top;
        LONG x = rescue_to.left + ((rescue_to.right - rescue_to.left) - width) / 2;
        LONG y = rescue_to.top + ((rescue_to.bottom - rescue_to.top) - height) / 2;
        if (x < rescue_to.left) { x = rescue_to.left; }
        if (y < rescue_to.top) { y = rescue_to.top; }

        // No activation. A modal dialog already holds the input queue, and
        // taking the foreground out from under whatever the user is typing into
        // would be its own bug.
        // Asynchronous: the dialog belongs to another process, nothing below
        // measures where it went, and a hung one must not hang the watcher.
        if (Unresponsive(window)
            || !SetWindowPos(window, nullptr, x, y, 0, 0,
                             SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
                             | SWP_ASYNCWINDOWPOS)) {
            continue;
        }
        if (g_rescued.size() < 64) {
            g_rescued.push_back(window);
        }
        const std::string title = WindowTitleForLog(window);
        Log("[rescue] \"%s\" opened on the capture display, where no monitor shows "
            "it; moved it to the main display", title.empty() ? "(untitled)" : title.c_str());
    }
}

/// What the agent last told the Mac was covering each streamed window, and how
/// long the current answer has held. Watcher thread only.
struct OcclusionState {
    HWND reported = nullptr;   // what the Mac has been told about
    HWND candidate = nullptr;  // what the last sample saw
    int stable_ticks = 0;
};
OcclusionState g_occlusion[kMaxLocks];

/// Say when a window belonging to something else is sitting on top of the one
/// being streamed.
///
/// The user can see it — it is inside the captured rectangle, so it arrives in
/// the video — but seeing it explains nothing. A Windows Security prompt landing
/// on the streamed window is system-modal: it takes every click aimed anywhere
/// near it, and the application behind carries on looking perfectly normal and
/// completely dead. That failure cost days here, on this machine, before anyone
/// worked out what it was.
///
/// Hit-testing, not enumeration. Two earlier attempts went through the visible
/// window list and both failed: a heuristic about layered windows that take
/// focus misfired on an ordinary application, and a check for the system dimmer
/// by class name never fired at all, because the enumeration does not see the
/// window `WindowFromPoint` returns. So ask the question Windows itself answers
/// when it routes a click, at points inside the streamed window.
///
/// It also gets the hard case right for free: `WindowFromPoint` skips windows
/// that are disabled or `WS_EX_TRANSPARENT`, which is exactly the screen-wide
/// click-through overlay that made the heuristic version unusable.
///
/// Windows of the streamed application itself are not occluders. Its menus, its
/// combo drop-downs, its tooltips and its own dialogs are all separate top-level
/// windows, and every one of them would otherwise be reported as something
/// covering the application — which, to the person who just opened the menu, it
/// plainly is not.
void ReportOcclusion() {
    for (int i = 0; i < kMaxLocks; ++i) {
        HWND window = nullptr;
        RECT rect{};
        DWORD owner = 0;
        EnterCriticalSection(&g_lock_cs);
        if (g_locks[i].active) {
            window = g_locks[i].window;
            rect = g_locks[i].desired;
            owner = g_locks[i].pid;
        }
        LeaveCriticalSection(&g_lock_cs);
        if (!window) {
            g_occlusion[i] = OcclusionState{};
            continue;
        }

        const LONG width = rect.right - rect.left;
        const LONG height = rect.bottom - rect.top;
        if (width <= 0 || height <= 0) {
            continue;
        }
        // Five points rather than one: a dialog centred on the window covers the
        // middle, and one docked to a corner covers no sample taken only there.
        const POINT samples[5] = {
            {rect.left + width / 2, rect.top + height / 2},
            {rect.left + width / 4, rect.top + height / 4},
            {rect.left + width * 3 / 4, rect.top + height / 4},
            {rect.left + width / 4, rect.top + height * 3 / 4},
            {rect.left + width * 3 / 4, rect.top + height * 3 / 4},
        };

        HWND found = nullptr;
        for (const POINT& point : samples) {
            HWND hit = WindowFromPoint(point);
            if (!hit) {
                continue;
            }
            HWND root = GetAncestor(hit, GA_ROOT);
            if (root == window) {
                continue;
            }
            DWORD hit_pid = 0;
            GetWindowThreadProcessId(root, &hit_pid);
            if (hit_pid == owner || hit_pid == GetCurrentProcessId()) {
                continue;
            }
            found = root;
            break;
        }

        // Hold an answer for a few ticks before believing it. The watcher runs
        // every 120ms and a window being dragged across the screen is not worth
        // a message in each direction.
        if (found == g_occlusion[i].candidate) {
            if (g_occlusion[i].stable_ticks < 100) {
                ++g_occlusion[i].stable_ticks;
            }
        } else {
            g_occlusion[i].candidate = found;
            g_occlusion[i].stable_ticks = 0;
        }
        if (g_occlusion[i].stable_ticks < 4 || found == g_occlusion[i].reported) {
            continue;
        }
        g_occlusion[i].reported = found;

        // Read wide and converted, because the title goes to the Mac: the ANSI
        // calls answer in the PC's code page, and a French "Sécurité Windows"
        // or an em dash in a browser tab became a byte the Mac would not parse,
        // which cost the whole session at the very moment this push exists to
        // explain.
        std::string title;
        std::string cls;
        if (found) {
            wchar_t wide_title[128] = {};
            wchar_t wide_class[64] = {};
            GetWindowTextW(found, wide_title, 128);
            GetClassNameW(found, wide_class, 64);
            title = ToUtf8(wide_title);
            cls = ToUtf8(wide_class);
            Log("[occlusion] [%s] \"%s\" is on top of the streamed window",
                cls.empty() ? "?" : cls.c_str(), title.empty() ? "(untitled)" : title.c_str());
        } else {
            Log("[occlusion] the streamed window is clear again");
        }

        // Empty means "nothing is on top any more", and it has to stay empty
        // when there is no window: naming the absence would leave the Mac
        // showing a warning that never goes away.
        //
        // Otherwise the important case is an untitled one — the shell's modal
        // dimmer has no title at all — so it needs a name, and its class is
        // not it. "Shell_SystemDim is in front" tells a person nothing; "a
        // Windows dialog is in front" tells them why their clicks are going
        // nowhere, which is the whole reason for saying anything.
        std::string by;
        if (found) {
            by = title;
            if (by.empty()) {
                by = (cls.rfind("Shell_System", 0) == 0 || cls == "#32770")
                     ? "a Windows dialog"
                     : "another window";
            }
        }
        PushLine("{\"type\":\"occluded\",\"id\":" + std::to_string(IdFromWindow(window))
                 + ",\"by\":\"" + JsonEscape(by) + "\"}");
    }
}

/// Say so when something on this PC takes the keyboard away from the window
/// being streamed.
///
/// The host injects keystrokes into whatever holds the foreground *here*, not
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

    std::string cls;
    std::string title;
    if (foreground) {
        cls = WindowClassForLog(foreground);
        title = WindowTitleForLog(foreground);
    }
    Log("[focus] \"%s\" [%s] took the keyboard from the streamed window;"
        " typing at the Mac is going there instead",
        title.empty() ? "(untitled)" : title.c_str(), cls.empty() ? "?" : cls.c_str());
}

/// Say which window would receive a click at the pointer.
///
/// Diagnostic. Keystrokes go to whatever holds the FOCUS, but clicks go to
/// whatever is under the POINTER, so an invisible window over the tile breaks
/// the mouse while leaving the keyboard working perfectly. Reported only while
/// something is being streamed, and only when the TOP-LEVEL window under the
/// pointer changes: comparing the control under it logged a line for every
/// button and field the pointer crossed, each one a file open and close, and
/// rotated everything else out of the log within a session.
void ReportPointerTarget() {
    POINT cursor{};
    if (!GetCursorPos(&cursor)) {
        return;
    }
    HWND under = WindowFromPoint(cursor);
    HWND root = under ? GetAncestor(under, GA_ROOT) : nullptr;
    static HWND reported = nullptr;
    if (root == reported) {
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
        if (g_locks[i].window == root) {
            ours = true;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    if (!streaming) {
        return;
    }

    reported = root;
    std::string cls;
    std::string title;
    if (root) {
        cls = WindowClassForLog(root);
        title = WindowTitleForLog(root);
    }
    Log("[pointer] at %ld,%ld a click would go to [%s] \"%s\"%s",
        cursor.x, cursor.y, cls.empty() ? "?" : cls.c_str(),
        title.empty() ? "(untitled)" : title.c_str(),
        ours ? "" : "  <-- NOT the streamed window");
}

/// The watcher's two speeds. Fast while a window is held, because that is when
/// a window moving off its tile is a broken picture; slow otherwise, because
/// then its only jobs are carrying stranded dialogs off the capture display and
/// the picker's change notice, and neither is worth waking the CPU eight times a
/// second on an idle PC. A window-set change wakes it early (g_watcher_wake).
constexpr DWORD kWatchActiveMs = 120;
constexpr DWORD kWatchIdleMs = 1000;
/// Stranded-window rescue walks every window on the desktop, so it runs at the
/// idle rate even while the fast loop is running. A little under the idle
/// interval, so tick jitter cannot make it skip every other idle wake.
constexpr ULONGLONG kRescueIntervalMs = 900;

/// Put a locked window back if anything moved or resized it, and everything
/// else that has to notice the desktop changing. Runs for the life of the host.
DWORD WINAPI WatcherProc(LPVOID) {
    DWORD interval = kWatchIdleMs;
    ULONGLONG rescued_at = 0;
    for (;;) {
        if (g_watcher_wake) {
            WaitForSingleObject(g_watcher_wake, interval);
        } else {
            Sleep(interval);
        }
        bool holding = false;
        for (int i = 0; i < kMaxLocks; ++i) {
            HWND window = nullptr;
            RECT desired{};
            uint64_t closed = 0;
            uint64_t generation = 0;
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
                generation = g_locks[i].generation;
            }
            holding = holding || g_locks[i].active;
            LeaveCriticalSection(&g_lock_cs);
            if (closed != 0) {
                RecordOwedWindows();
                Log("[agent] tracked window %llu was closed", (unsigned long long) closed);
                NotifyWindowClosed(closed);
                continue;
            }
            if (!window) {
                continue;
            }
            // A minimised window is the user's business; leave it alone and let it
            // settle back when they restore it.
            if (IsIconic(window) || Unresponsive(window)) {
                continue;
            }
            // Un-maximised asynchronously, and placed on a later tick once the
            // restore has landed: measuring straight after an asynchronous
            // restore would measure the maximised window.
            if (IsZoomed(window)) {
                ShowWindowAsync(window, SW_RESTORE);
                continue;
            }
            const RECT now = ClientAreaInScreen(window);
            if (now.left == desired.left && now.top == desired.top
                && now.right == desired.right && now.bottom == desired.bottom) {
                continue;
            }
            // Last look before moving anything. Everything above this line took
            // long enough for a `lock off` to have arrived, restored the window
            // and freed the slot -- and placing it now would undo that restore,
            // dragging a window the user has just got back onto a display that
            // is about to stop existing. Re-checking is cheap; holding the lock
            // across the calls above is not, because they block on another
            // process's message pump.
            //
            // The rectangle is re-read here as well as the tenancy, and for the
            // same reason. A `place` arriving in that gap calls SetLockedGeometry
            // -- it does not touch `generation`, because the tenancy has not
            // changed -- so the copy taken at the top of the loop is now the OLD
            // position, and placing it would drag the window straight back off
            // the tile the Mac has just moved it to. The Mac would then re-issue
            // the same `place`, and the two would fight at 120ms.
            bool still_ours = false;
            EnterCriticalSection(&g_lock_cs);
            still_ours = g_locks[i].active && g_locks[i].geometry_locked
                      && g_locks[i].window == window
                      && g_locks[i].generation == generation;
            if (still_ours) {
                desired = g_locks[i].desired;
            }
            LeaveCriticalSection(&g_lock_cs);
            if (!still_ours) {
                continue;
            }
            PlaceClientArea(window, desired.left, desired.top,
                            desired.right - desired.left, desired.bottom - desired.top);
        }
        // Each of these returns at once when nothing is held.
        ReportForegroundThief();
        ReportPointerTarget();
        ReportOcclusion();
        const ULONGLONG now = GetTickCount64();
        if (now - rescued_at >= kRescueIntervalMs) {
            rescued_at = now;
            RechooseCaptureDisplayIfStale();
            RescueStrandedWindows();
        }
        NotifyWindowsChangedIfSettled();
        interval = holding || g_window_set_dirty.load() ? kWatchActiveMs : kWatchIdleMs;
    }
}

/// Started once, at startup, and never stopped: binding the agent's socket is
/// what makes Windows ask whether it may accept connections, and that prompt
/// lands on the capture display long before any Mac connects.
void StartWatcher() {
    g_watcher_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HANDLE thread = CreateThread(nullptr, 0, WatcherProc, nullptr, 0, nullptr);
    if (thread) {
        CloseHandle(thread);
    }
}

/// Find this window's slot, claiming a free one and recording how the window
/// looked first. Call with `g_lock_cs` held.
///
/// Recording happens here, once, rather than in each caller: `lock` and
/// `topmost` both change a window and both owe it a restore, and a window that
/// was only ever made topmost still has to come back down.
int ClaimSlot(HWND window) {
    if (solstream::RestoreInProgress(g_restoring_windows, IdFromWindow(window))) {
        return kClaimRestoreInProgress;
    }
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
        g_locks[i].generation = ++g_lock_generation;
        GetWindowThreadProcessId(window, &g_locks[i].pid);
        g_locks[i].process_created = ProcessCreationTime(g_locks[i].pid);
        g_locks[i].saved_topmost =
            (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
        // WINDOWPLACEMENT rather than GetWindowRect: it carries the restored
        // size *and* whether the window was maximised, so a window that was
        // full screen before the session goes back to full screen after it.
        g_locks[i].saved_placement.length = sizeof(WINDOWPLACEMENT);
        GetWindowPlacement(window, &g_locks[i].saved_placement);
        // Still owed from a host stopped by force: it is on the capture display
        // and stripped of its frame bits now, so how it looks is not how it
        // was. What that host wrote down is, and this slot owes it instead.
        solstream::OwedWindow owed;
        if (solstream::TakeOwed(g_left_behind, IdFromWindow(window), g_locks[i].pid,
                                g_locks[i].process_created, &owed)) {
            g_locks[i].saved_placement = owed.placement;
            g_locks[i].saved_topmost = owed.topmost;
            g_locks[i].removed_style = (LONG_PTR) owed.removed_style & kLockedStyleBits;
        }
        return i;
    }
    return -1;
}

/// When this PC last started, in seconds of the system clock; see BootSecond.
uint64_t ThisBootSecond() {
    FILETIME now{};
    GetSystemTimeAsFileTime(&now);
    return solstream::BootSecond(
        (static_cast<uint64_t>(now.dwHighDateTime) << 32) | now.dwLowDateTime,
        GetTickCount64());
}

/// Where a host writes down the windows it owes a restore.
std::wstring OwedWindowsPath() {
    static const std::wstring path = LocalDataPath(L"owed-windows.txt");
    return path;
}

/// Write down every window this host owes a restore, as the slots say now.
///
/// For the next host, should this one be killed before it can give them back
/// itself: see window_restore.h. Called after every claim and release, and
/// before the change the claim is for -- a resize border taken away before it
/// is written down is one a kill at that moment loses for good. The snapshot is
/// taken inside the same lock as the write, so two threads writing at once can
/// only ever leave the later state on disk.
void RecordOwedWindows() {
    EnterCriticalSection(&g_owed_cs);
    solstream::OwedRecord owed;
    owed.boot = ThisBootSecond();
    owed.written = GetTickCount64();
    std::vector<solstream::OwedWindow> held;
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        // A window whose process could not be identified is not written down:
        // the next host could not tell it from another one with its handle.
        if (!g_locks[i].active || g_locks[i].process_created == 0) {
            continue;
        }
        solstream::OwedWindow entry;
        entry.window = IdFromWindow(g_locks[i].window);
        entry.pid = g_locks[i].pid;
        entry.process_created = g_locks[i].process_created;
        entry.removed_style = (uint64_t) g_locks[i].removed_style;
        entry.topmost = g_locks[i].saved_topmost;
        entry.placement = g_locks[i].saved_placement;
        held.push_back(entry);
    }
    // A closed window is owed nothing. One whose process cannot be identified
    // stays owed in this host's memory, but is not safe to persist for another.
    g_left_behind.erase(
        std::remove_if(g_left_behind.begin(), g_left_behind.end(),
                       [](const solstream::OwedWindow& entry) {
                           return !IsWindow(reinterpret_cast<HWND>(
                               static_cast<uintptr_t>(entry.window)));
                       }),
        g_left_behind.end());
    std::vector<solstream::OwedWindow> persistent;
    for (const solstream::OwedWindow& entry : g_left_behind) {
        if (entry.process_created != 0) {
            persistent.push_back(entry);
        }
    }
    owed.windows = solstream::OwedToWrite(held, persistent);
    LeaveCriticalSection(&g_lock_cs);
    static bool complained = false;
    if (!solstream::SaveOwedWindows(OwedWindowsPath(), owed) && !complained) {
        complained = true;
        Log("[restore] could not write down the windows owed a restore; a host "
            "stopped by force would leave them where they are");
    }
    LeaveCriticalSection(&g_owed_cs);
}

/// Wait, briefly, for an older session's restore of this window to finish; see
/// kRestoreWaitMs. On the command thread, and holding no lock while it sleeps,
/// so the restore it waits for can finish. True when no restore holds it now.
bool WaitForRestoreToFinish(HWND window) {
    const uint64_t id = IdFromWindow(window);
    auto restoring = [id] {
        EnterCriticalSection(&g_lock_cs);
        const bool busy = solstream::RestoreInProgress(g_restoring_windows, id);
        LeaveCriticalSection(&g_lock_cs);
        return busy;
    };
    if (!restoring()) {
        return true;
    }
    const ULONGLONG start = GetTickCount64();
    const bool finished = solstream::WaitWhileBusy(
        restoring, [] { return (uint64_t) GetTickCount64(); },
        [](uint32_t ms) { Sleep(ms); },
        solstream::kRestoreWaitMs, solstream::kRestoreWaitStepMs);
    Log("[restore] window %llu was still being given back; %s after %llu ms",
        (unsigned long long) id, finished ? "done" : "gave up waiting",
        (unsigned long long) (GetTickCount64() - start));
    return finished;
}

/// Take away a window's ability to be resized from the host side.
bool LockWindow(HWND window) {
    if (Unresponsive(window)) {
        return false;
    }
    EnterCriticalSection(&g_lock_cs);
    const int slot = ClaimSlot(window);
    LeaveCriticalSection(&g_lock_cs);
    if (slot < 0) {
        return false;
    }
    RecordOwedWindows();

    // Un-maximise only now that the placement is recorded, or the restore would
    // believe the window had always been this size. Synchronous, because the
    // client area is measured next.
    if (IsZoomed(window)) {
        ShowWindow(window, SW_RESTORE);
    }

    // Against the style as it is now -- after the restore above -- and only the
    // two frame bits. See kLockedStyleBits.
    const LONG_PTR current = GetWindowLongPtrW(window, GWL_STYLE);
    const LONG_PTR removing = current & kLockedStyleBits;

    EnterCriticalSection(&g_lock_cs);
    // The lock was released across the un-maximise above, so re-establish that
    // this slot is still this window's.
    if (!g_locks[slot].active || g_locks[slot].window != window) {
        LeaveCriticalSection(&g_lock_cs);
        return false;
    }
    g_locks[slot].geometry_locked = true;
    g_locks[slot].desired = ClientAreaInScreen(window);
    g_locks[slot].removed_style |= removing;
    LeaveCriticalSection(&g_lock_cs);
    RecordOwedWindows();

    if (removing != 0) {
        SetWindowLongPtrW(window, GWL_STYLE, current & ~kLockedStyleBits);
        // SWP_FRAMECHANGED makes the window recompute its non-client area;
        // without it the border is gone in style only and still drag-resizes.
        SetWindowPos(window, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
                     | SWP_FRAMECHANGED);
    }
    return true;
}

/// Give one window back what the agent took. The outcome says whether its
/// recovery record can be forgotten or needs another attempt later.
solstream::RestoreOutcome RestoreWindow(const WindowLock& saved) {
    HWND window = saved.window;
    if (!window || !IsWindow(window)) {
        return solstream::RestoreOutcome::Gone;
    }
    // IsWindow can come back true for a recycled handle. The pid and process
    // start keep a dead application's state off an unrelated window.
    if (saved.pid != 0) {
        DWORD owner = 0;
        GetWindowThreadProcessId(window, &owner);
        if (owner != saved.pid) {
            return solstream::RestoreOutcome::Gone;
        }
    }
    if (saved.process_created != 0) {
        const uint64_t created = ProcessCreationTime(saved.pid);
        if (created == 0) {
            return solstream::RestoreOutcome::Retry;
        }
        if (created != saved.process_created) {
            return solstream::RestoreOutcome::Gone;
        }
    }
    // A hung application would hang this thread -- which on disconnect is the
    // cleanup that frees the client slot. Leaving its frame and placement as
    // they are is the lesser harm, and said.
    if (Unresponsive(window)) {
        Log("[agent] window %llu is not responding; left as it is rather than "
            "restored", (unsigned long long) IdFromWindow(window));
        return solstream::RestoreOutcome::Retry;
    }

    if (saved.removed_style != 0) {
        const LONG_PTR current = GetWindowLongPtrW(window, GWL_STYLE);
        SetWindowLongPtrW(window, GWL_STYLE, current | saved.removed_style);
    }
    // Drop back out of the always-on-top band unless the window was already in
    // it: left set, the window floats above everything the user does next with
    // no visible cause. Asynchronous, because nothing measures it.
    //
    // A refusal is said, but does not make the restore owed again: the frame
    // and place below are given back regardless, and a restore tried again
    // later would put the window back where it was before the session, over
    // wherever the user has moved it since.
    const bool z_order_failed =
        SetWindowPos(window, saved.saved_topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                     0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED
                     | SWP_ASYNCWINDOWPOS) == FALSE;
    const DWORD z_order_error = z_order_failed ? GetLastError() : 0;
    // And put it back where it was. Managed windows are parked on the virtual
    // display, whose origin sits off the side of the real desktop, so a window
    // left at those coordinates is not merely misplaced -- it is invisible, on
    // a monitor that stops existing when the session ends.
    //
    // Asked again when it does not land there: see window_restore.h. The move
    // off the 200% capture display makes a DPI-aware window rescale itself by
    // the ratio of the two scalings AFTER taking the size it is given, so one
    // SetWindowPlacement put File Explorer back at 0.625 of its size on a 125%
    // monitor -- and the next session opened at that size, and shrank it again.
    //
    // And never shown by it: a window its application hid while it was ours --
    // closed to the tray -- is given its place back hidden. See
    // PlacementForRestore.
    if (saved.saved_placement.length == sizeof(WINDOWPLACEMENT)) {
        const bool visible = IsWindowVisible(window) != FALSE;
        const WINDOWPLACEMENT placement =
            solstream::PlacementForRestore(saved.saved_placement, visible);
        bool matched = false;
        const int tries = solstream::RestorePlacement(
            placement,
            [window](const WINDOWPLACEMENT& placement) {
                return SetWindowPlacement(window, &placement) != FALSE;
            },
            [window](WINDOWPLACEMENT& placement) {
                return GetWindowPlacement(window, &placement) != FALSE;
            },
            &matched);
        if (tries == solstream::kRestorePlacementFailed) {
            Log("[restore] window %llu could not be put back; still owed its place",
                (unsigned long long) IdFromWindow(window));
            return solstream::RestoreOutcome::Retry;
        }
        const RECT& wanted = saved.saved_placement.rcNormalPosition;
        WINDOWPLACEMENT now{};
        now.length = sizeof(now);
        const bool read_back = GetWindowPlacement(window, &now) != FALSE;
        const RECT& got = now.rcNormalPosition;
        const std::string title = WindowTitleForLog(window);
        if (!read_back) {
            Log("[restore] \"%s\" asked back to %ldx%ld at %ld,%ld; where it settled "
                "could not be read (%d %s)",
                title.empty() ? "(untitled)" : title.c_str(),
                wanted.right - wanted.left, wanted.bottom - wanted.top,
                wanted.left, wanted.top, tries, tries == 1 ? "try" : "tries");
        } else if (matched) {
            Log("[restore] \"%s\" back at %ldx%ld at %ld,%ld (%d %s)%s",
                title.empty() ? "(untitled)" : title.c_str(),
                wanted.right - wanted.left, wanted.bottom - wanted.top,
                wanted.left, wanted.top, tries, tries == 1 ? "try" : "tries",
                visible ? "" : ", left hidden");
        } else {
            Log("[restore] \"%s\" asked back to %ldx%ld at %ld,%ld and settled at "
                "%ldx%ld at %ld,%ld after %d %s%s",
                title.empty() ? "(untitled)" : title.c_str(),
                wanted.right - wanted.left, wanted.bottom - wanted.top,
                wanted.left, wanted.top,
                got.right - got.left, got.bottom - got.top, got.left, got.top,
                tries, tries == 1 ? "try" : "tries", visible ? "" : ", left hidden");
        }
    }
    if (z_order_failed) {
        Log("[restore] window %llu could not be put back in its place in the "
            "window order (%lu); its frame and place are back",
            (unsigned long long) IdFromWindow(window), z_order_error);
    }
    return solstream::RestoreOutcome::Restored;
}

/// The slot's tenancy also versions its recovery debt, so stale startup work
/// cannot delete a newer session's entry for the same handle.
solstream::OwedWindow OwedForRestore(const WindowLock& saved) {
    solstream::OwedWindow entry;
    entry.window = IdFromWindow(saved.window);
    entry.pid = saved.pid;
    entry.process_created = saved.process_created;
    entry.removed_style = (uint64_t) saved.removed_style;
    entry.topmost = saved.saved_topmost;
    entry.placement = saved.saved_placement;
    entry.revision = saved.generation;
    return entry;
}

/// Finish a restore marked by BeginRestore. The queue and its in-progress mark
/// change under the same lock that ClaimSlot uses.
void RestoreMarkedWindow(const WindowLock& saved) {
    const uint64_t id = IdFromWindow(saved.window);
    const solstream::RestoreOutcome outcome = RestoreWindow(saved);
    EnterCriticalSection(&g_lock_cs);
    solstream::FinishRestore(g_left_behind, g_restoring_windows, id,
                             saved.generation, outcome);
    LeaveCriticalSection(&g_lock_cs);
    RecordOwedWindows();
}

/// Whether a window's thread answers a message within half a second.
///
/// IsHungAppWindow only says so after five seconds of silence, so a window
/// that has just stopped answering passes it -- and the calls that follow
/// would wait on it without limit. This asks, and gives up.
bool AnswersPromptly(HWND window) {
    DWORD_PTR result = 0;
    return SendMessageTimeoutW(window, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 500, &result) != 0;
}

/// Release one window's slot, or every slot for a null window. Removing the slot
/// and adding its recovery entry are one critical section: a claim or a
/// persistence snapshot can never see the handoff half done.
///
/// Not marked as being restored here: RestoreReleasedSlots marks each window
/// only as it gets to it. Marked all at once, a window queued behind one whose
/// app has hung stayed marked for as long as that app took to answer, and every
/// session that asked for it meanwhile was told it was still being restored.
/// Unmarked, a session that streams it again takes what it is owed instead.
std::vector<WindowLock> TakeSlotsForRestore(HWND window = nullptr) {
    std::vector<WindowLock> released;
    EnterCriticalSection(&g_lock_cs);
    for (int i = 0; i < kMaxLocks; ++i) {
        if (!g_locks[i].active || (window && g_locks[i].window != window)) {
            continue;
        }
        const uint64_t id = IdFromWindow(g_locks[i].window);
        if (solstream::RestoreInProgress(g_restoring_windows, id)) {
            continue;
        }
        solstream::RememberOwed(g_left_behind, OwedForRestore(g_locks[i]));
        released.push_back(g_locks[i]);
        g_locks[i] = WindowLock{};
    }
    LeaveCriticalSection(&g_lock_cs);
    return released;
}

/// Persist the handoff before touching a window. A crash or failed call then
/// leaves its debt in the recovery queue instead of dropping it with the slot.
///
/// One window at a time, each marked just before it is touched. A window that
/// does not answer within half a second is passed over and stays owed: the
/// calls that restore it wait on its app without limit, and IsHungAppWindow
/// takes five seconds to call it hung.
void RestoreReleasedSlots(const std::vector<WindowLock>& released) {
    if (released.empty()) {
        return;
    }
    RecordOwedWindows();
    for (const WindowLock& saved : released) {
        const uint64_t id = IdFromWindow(saved.window);
        // A window that has gone is still worth the call: RestoreWindow finds
        // it gone, and the debt is dropped.
        if (IsWindow(saved.window) && !AnswersPromptly(saved.window)) {
            Log("[restore] window %llu is not answering; left where it is, and still "
                "owed its place", (unsigned long long) id);
            continue;
        }
        // A session may have taken the debt back meanwhile; then it is that
        // session's to give back.
        EnterCriticalSection(&g_lock_cs);
        const bool marked = solstream::BeginRestore(g_left_behind, g_restoring_windows,
                                                    id, saved.generation);
        LeaveCriticalSection(&g_lock_cs);
        if (!marked) {
            continue;
        }
        RestoreMarkedWindow(saved);
    }
}

void UnlockWindow(HWND window) {
    RestoreReleasedSlots(TakeSlotsForRestore(window));
}

/// Give every locked window its resize border back, so a Mac that goes away
/// does not leave applications permanently unresizable.
void UnlockAll() {
    RestoreReleasedSlots(TakeSlotsForRestore());
}

/// Give back what a host killed mid-session owed, one window at a time.
///
/// Its windows are still where it left them: on the capture display, which no
/// monitor shows, without the resize border and maximise box the session took.
/// Left to the next session, the window is claimed as it is -- so the Mac is
/// told it cannot be resized, and the end of that session "restores" it to the
/// capture display.
///
/// A window that is not answering is skipped and stays in g_left_behind, so it
/// is still written down, and a session that streams it again takes what it is
/// owed from there (ClaimSlot). Each window leaves the list only once it has
/// been given back, or is found to be gone or someone else's.
DWORD WINAPI RestoreLeftBehindProc(LPVOID) {
    EnterCriticalSection(&g_lock_cs);
    const std::vector<solstream::OwedWindow> owed = g_left_behind;
    LeaveCriticalSection(&g_lock_cs);
    auto forget = [](const solstream::OwedWindow& expected) {
        EnterCriticalSection(&g_lock_cs);
        solstream::ForgetOwedRevision(g_left_behind, expected.window, expected.revision);
        LeaveCriticalSection(&g_lock_cs);
    };
    for (const solstream::OwedWindow& entry : owed) {
        WindowLock saved;
        saved.window = reinterpret_cast<HWND>(static_cast<uintptr_t>(entry.window));
        saved.pid = entry.pid;
        saved.process_created = entry.process_created;
        saved.generation = entry.revision;
        // Only ever the two bits a lock takes, whatever the file says.
        saved.removed_style = (LONG_PTR) entry.removed_style & kLockedStyleBits;
        saved.saved_topmost = entry.topmost;
        saved.saved_placement = entry.placement;
        // The same window of the same process, and not this one's own window,
        // which a handle reused since could be.
        DWORD owner = 0;
        if (!IsWindow(saved.window)
            || (GetWindowThreadProcessId(saved.window, &owner), owner == GetCurrentProcessId())
            || owner != entry.pid) {
            forget(entry);
            continue;
        }
        const uint64_t created = ProcessCreationTime(owner);
        if (created != 0 && created != entry.process_created) {
            forget(entry);
            continue;
        }
        if (created == 0) {
            Log("[restore] window %llu's process cannot be identified; still owed "
                "its place", (unsigned long long) entry.window);
            continue;
        }
        if (!AnswersPromptly(saved.window)) {
            Log("[restore] window %llu is not answering; left where it is, and still "
                "owed its place", (unsigned long long) entry.window);
            continue;
        }
        // A session may have taken the debt while Windows answered our checks.
        // If not, mark the restore before releasing the lock; ClaimSlot refuses
        // this window until RestoreMarkedWindow clears that mark.
        EnterCriticalSection(&g_lock_cs);
        const bool marked =
            solstream::BeginRestore(g_left_behind, g_restoring_windows,
                                    entry.window, entry.revision);
        LeaveCriticalSection(&g_lock_cs);
        if (!marked) {
            continue;
        }
        RestoreMarkedWindow(saved);
    }
    RecordOwedWindows();
    return 0;
}

/// Read what a host stopped by force owed, and give it back before serving.
///
/// Only a record from this run of Windows, and only for the process that
/// owned each window then: handles and pids both start again with Windows, and
/// either can be given to something else since.
///
/// The giving back crosses into other processes, so it runs on a thread of its
/// own and is waited for only so long. A window that hangs part-way through
/// must not keep the host from coming up while it holds the single-instance
/// name -- that would leave the PC with no host at all, and every later start
/// turned away as a second copy.
void RestoreWindowsLeftBehind() {
    const solstream::OwedRecord record = solstream::LoadOwedWindows(OwedWindowsPath());
    if (record.windows.empty()) {
        return;
    }
    if (!solstream::RecordIsFromThisBoot(record, ThisBootSecond(), GetTickCount64())) {
        Log("[restore] the windows a host owed were written down before this PC "
            "last started; none of them is still there to give back");
        solstream::SaveOwedWindows(OwedWindowsPath(), solstream::OwedRecord{});
        return;
    }
    Log("[restore] the last host stopped owing %zu window%s a restore; giving "
        "%s back now", record.windows.size(), record.windows.size() == 1 ? "" : "s",
        record.windows.size() == 1 ? "it" : "them");
    EnterCriticalSection(&g_lock_cs);
    g_left_behind = record.windows;
    LeaveCriticalSection(&g_lock_cs);
    HANDLE thread = CreateThread(nullptr, 0, RestoreLeftBehindProc, nullptr, 0, nullptr);
    if (!thread) {
        return;   // still written down, and taken by a session that streams it
    }
    if (WaitForSingleObject(thread, 5000) == WAIT_TIMEOUT) {
        Log("[restore] giving the windows back is taking more than 5 s; starting "
            "anyway, and it carries on meanwhile");
    }
    CloseHandle(thread);
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

// ── Placement ────────────────────────────────────────────────────────────────

/// Place a window so its CLIENT AREA lands exactly on the requested rectangle.
///
/// The caller cares about the client area, because that is what gets cropped
/// out of the stream — but SetWindowPos positions the whole window including
/// its frame. So measure the current difference between the two and offset by
/// it. Measuring beats computing from AdjustWindowRect, which does not know
/// about DPI scaling, custom frames, or DWM's invisible borders.
/// How many times one placement will correct itself before settling for what it
/// got. Two is enough for the DPI case -- the second attempt measures the frame
/// the window actually ended up with -- and the third is for a window whose own
/// WM_WINDOWPOSCHANGING adjusts what it is given. Past that, whatever is left is
/// the application enforcing something, and asking again just costs another
/// cross-process round trip on the agent's only command thread.
constexpr int kPlaceAttempts = 3;

/// The distance between where the client area landed and where it was asked to
/// be, as one number, so successive attempts can be compared for progress.
long long PlacementError(const RECT& got, int x, int y, int width, int height) {
    return llabs((long long) got.left - x)
         + llabs((long long) got.top - y)
         + llabs((long long) (got.right - got.left) - width)
         + llabs((long long) (got.bottom - got.top) - height);
}

bool PlaceClientArea(HWND window, int x, int y, int width, int height,
                     RECT* out_client, long long* out_error) {   // NOLINT: see declaration
    // Synchronous below, because each attempt measures where the last one
    // landed -- so a hung window is not attempted at all. Reported as a miss of
    // whatever distance it is from the request.
    if (Unresponsive(window)) {
        const RECT client = ClientAreaInScreen(window);
        if (out_client) { *out_client = client; }
        if (out_error) { *out_error = PlacementError(client, x, y, width, height); }
        return false;
    }
    if (IsIconic(window)) {
        ShowWindow(window, SW_RESTORE);
    }

    // ACTIVELY CORRECTED, rather than computed once and hoped for.
    //
    // The arithmetic below measures the gap between the visible frame and the
    // client area BEFORE the move, and applies it to a target the window will
    // occupy AFTER it. Those are the same number only while nothing about the
    // frame changes -- and the move that matters most here changes it: carrying a
    // window from a real monitor at 100% onto the virtual display at 200% doubles
    // every piece of non-client furniture as a consequence of the move itself. So
    // the first attempt lands out by the difference, which on a 200% display is
    // tens of pixels, and NOTHING used to correct it: the reply carried the
    // missed rectangle, the Mac resized its own window to match it, and
    // SetLockedGeometry told the watcher to hold the miss in place for the rest
    // of the session. Both ends agreed, and both were wrong.
    //
    // A second attempt measures the frame the window now really has, so it
    // converges. The loop stops the moment it is exact, and stops early when an
    // attempt makes no progress -- a window enforcing a minimum or a size grid is
    // as close as it is going to get, and hammering it would only be slow.
    bool moved = false;
    RECT client = ClientAreaInScreen(window);
    long long best = PlacementError(client, x, y, width, height);
    for (int attempt = 0; attempt < kPlaceAttempts; ++attempt) {
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

        if (!SetWindowPos(window, nullptr, target_x, target_y, target_w, target_h,
                          SWP_NOZORDER | SWP_NOACTIVATE)) {
            break;
        }
        moved = true;
        client = ClientAreaInScreen(window);
        const long long error = PlacementError(client, x, y, width, height);
        if (error == 0) {
            best = 0;
            break;
        }
        // No better than the attempt before it: the window is holding a size of
        // its own, and another go would land in the same place.
        if (attempt > 0 && error >= best) {
            break;
        }
        best = error;
    }
    if (out_client) { *out_client = client; }
    if (out_error) { *out_error = best; }
    return moved;
}

/// Put a window's client area at x,y and leave its size to the application.
///
/// For a window that cannot be resized -- a dialog like Character Map. Its
/// controls are laid out for the size it chooses, and moving it onto the 200%
/// capture display makes it choose again (WM_DPICHANGED). Forcing the size the
/// Mac computed from the old display clipped its right-hand buttons. So it is
/// only moved, by the distance its client origin is from where it should be,
/// and whatever size it settles at is the answer. Twice, because the move that
/// changes its DPI also changes its frame, and with it where the client area
/// sits inside the frame.
bool MoveClientArea(HWND window, int x, int y, RECT* out_client) {
    if (Unresponsive(window)) {
        if (out_client) { *out_client = ClientAreaInScreen(window); }
        return false;
    }
    if (IsIconic(window)) {
        ShowWindow(window, SW_RESTORE);
    }
    bool moved = false;
    for (int attempt = 0; attempt < 2; ++attempt) {
        const RECT client = ClientAreaInScreen(window);
        const int dx = x - client.left;
        const int dy = y - client.top;
        if (dx == 0 && dy == 0) {
            break;
        }
        RECT frame{};
        GetWindowRect(window, &frame);
        if (!SetWindowPos(window, nullptr, frame.left + dx, frame.top + dy, 0, 0,
                          SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
            break;
        }
        moved = true;
    }
    const RECT client = ClientAreaInScreen(window);
    if (out_client) { *out_client = client; }
    // Already where it was asked to be is success too: the Mac's settling pass
    // asks again for the place the window is already in, and a "not ok" for
    // that was dropped on the floor along with the size it carried.
    return moved || (client.left == x && client.top == y);
}

// ── JSON output ──────────────────────────────────────────────────────────────

std::string DisplaysJson(const std::vector<Display>& displays) {
    std::string out = "{\"type\":\"displays\",\"displays\":[";
    for (size_t i = 0; i < displays.size(); ++i) {
        const Display& display = displays[i];
        char buffer[1024];
        // Which display is actually being encoded, said here rather than only
        // in `status`. The Mac crops a rectangle out of whatever arrives, so if
        // it places windows on a different display every crop is taken from the
        // wrong pixels — and the result is not an error, it is a picture. Seen
        // for real: a window titled "Character Map", frames arriving, nothing
        // dropped, and a black strip beside an olive rectangle on screen.
        // Sending it with the list means the client has it at the moment it
        // chooses, with no second round trip to race.
        const bool captured = ToWide(display.device_name) == CaptureDisplay();
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

/// The effective DPI of a monitor, or 0 when Windows will not say.
UINT MonitorDpi(HMONITOR monitor) {
    UINT x = 0, y = 0;
    return monitor && SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y)) ? x : 0;
}

/// The effective DPI of the capture display, or 0 when there is none.
UINT CaptureDisplayDpi() {
    const std::wstring capture_display = CaptureDisplay();
    struct Search { const std::wstring* name; HMONITOR found; } search{&capture_display, nullptr};
    EnumDisplayMonitors(nullptr, nullptr,
        [](HMONITOR monitor, HDC, LPRECT, LPARAM param) -> BOOL {
            auto* search = reinterpret_cast<Search*>(param);
            MONITORINFOEXW info{};
            info.cbSize = sizeof(info);
            if (GetMonitorInfoW(monitor, &info) && *search->name == info.szDevice) {
                search->found = monitor;
                return FALSE;
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&search));
    return MonitorDpi(search.found);
}

std::string WindowsJson(const std::vector<WindowInfo>& windows) {
    std::string out = "{\"type\":\"windows\",\"windows\":[";
    // Every window grows or shrinks by the ratio of the two scalings when it is
    // moved onto the capture display — DPI-aware ones by WM_DPICHANGED, the
    // rest by DWM's bitmap stretch — so the size the Mac should open at is that
    // ratio times the size it is now. Asked of the MONITOR, not the window: an
    // unaware window answers 96 wherever it is.
    const UINT capture_dpi = CaptureDisplayDpi();
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
        const UINT window_dpi =
            MonitorDpi(MonitorFromWindow(window.handle, MONITOR_DEFAULTTONEAREST));
        if (capture_dpi > 0 && window_dpi > 0) {
            entry += ",\"naturalW\":" + std::to_string(MulDiv(
                window.client.right - window.client.left, (int) capture_dpi, (int) window_dpi));
            entry += ",\"naturalH\":" + std::to_string(MulDiv(
                window.client.bottom - window.client.top, (int) capture_dpi, (int) window_dpi));
        }
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

    // No occlusion here. This poll used to re-run the whole window enumeration
    // once a second per streamed window to answer it with the rectangle
    // heuristic -- the one ReportOcclusion's hit-test replaced for being wrong
    // about layered dialogs and overlays. The watcher pushes `occluded` when the
    // answer changes, and that is the Mac's source.
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
                unsigned code = 0;
                if (!solstream::ParseHex4(json, i + 1, code)) {
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
                        && solstream::ParseHex4(json, i + 3, low)
                        && low >= 0xDC00 && low <= 0xDFFF) {
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        i += 6;
                    } else {
                        code = 0xFFFD;  // unpaired high surrogate
                    }
                } else if (code >= 0xDC00 && code <= 0xDFFF) {
                    code = 0xFFFD;      // stray low surrogate
                }
                solstream::AppendUtf8(value, code);
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

/// - Parameter channel_cnonce: set to the client's nonce when a v2 auth agreed
///   channel keys, which tells the caller to switch framing once its reply has
///   gone out. `maybe_unused` because the only thing that writes it is compiled
///   out without SOLSTREAM_MEDIA, and a warning there is noise rather than news.
/// - Parameter auth_failures: counts refused proofs on this connection, so the
///   caller can stop serving one that is only ever going to guess.
std::string HandleCommand(const std::string& line, bool& authenticated,
                          const std::string& challenge,
                          [[maybe_unused]] std::string& channel_cnonce,
                          int& auth_failures) {
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

    // What the host application is doing with itself: its capture display and
    // its media port. Answered before authentication because it
    // says nothing a port scan could not already establish, and because it is
    // what the Mac shows when it cannot get any further.
    if (command == "status") {
        std::string out = "{\"type\":\"status\",\"ok\":true";
        out += ",\"agent\":\"listening\"";
        out += ",\"clients\":" + std::to_string(g_clients_authenticated.load());
#ifdef SOLSTREAM_MEDIA
        out += ",\"streaming\":"
             + std::string(solstream::media::MediaSession::Instance().Running()
                           ? "true" : "false");
        out += ",\"mediaPort\":" + std::to_string(solstream::kDefaultMediaPort);
#else
        out += ",\"streaming\":false";
#endif
        out += ",\"captureDisplay\":\"" + JsonEscape(ToUtf8(CaptureDisplay())) + "\"";
        out += ",\"virtualDisplay\":"
             + std::string(solstream::HasVirtualDisplayCached() ? "true" : "false");
        out += "}";
        return out;
    }

    if (command == "auth") {
        // v2 first. The token itself never crosses the wire: the client proves
        // it holds one against a challenge this connection just invented.
        std::string proof, cnonce;
        if (FieldString(line, "proof", proof) && FieldString(line, "cnonce", cnonce)) {
            if (solstream::ProofMatches(g_token, challenge, cnonce, proof)) {
                if (!authenticated) {
                    g_clients_authenticated.fetch_add(1);
                }
                authenticated = true;
                // The channel's own keys, agreed in the same message that
                // proved the token so it costs no extra round trip.
                //
                // Version 2 exactly, not "2 or more" and not "anything
                // non-zero": a client that speaks a version this host does not
                // must stay in the clear rather than have both ends read each
                // other's bytes as the wrong thing.
#ifdef SOLSTREAM_MEDIA
                // Guarded: DeriveChannelKeys and g_pending_channel exist only with
                // SOLSTREAM_MEDIA, and the mingw cross-build compiles without it.
                long long wants = 0;
                std::string cpubHex;
                if (FieldNumber(line, "channelCrypto", wants) && wants == 2
                    && FieldString(line, "cpub", cpubHex)) {
                    const std::vector<unsigned char> cpub = FromHex(cpubHex);
                    std::vector<unsigned char> hpub;
                    BCRYPT_KEY_HANDLE pair = nullptr;
                    if (cpub.size() == 65 && cpub[0] == 0x04) {
                        pair = NewEcdhKeyPair(hpub);
                    }
                    if (pair) {
                        const std::vector<unsigned char> secret = EcdhSecret(pair, cpub);
                        // Destroyed here, before the reply is even built. The
                        // private half existing no longer than it must is the
                        // whole of what forward secrecy is.
                        BCryptDestroyKey(pair);
                        std::string hostAuth;
                        if (secret.size() == 32
                            && solstream::media::DeriveChannelKeys(
                                   g_pending_channel, g_token, challenge, cnonce,
                                   cpub, hpub, secret, hostAuth)) {
                            channel_cnonce = cnonce;
                            const std::string hpubHex = ToHex(hpub);
                            return "{\"type\":\"auth\",\"ok\":true"
                                   ",\"channelCrypto\":2"
                                   ",\"hpub\":\"" + hpubHex + "\""
                                   ",\"hauth\":\"" + hostAuth + "\"}";
                        }
                    }
                    Log("[agent] could not agree channel keys; staying in the clear");
                }
#endif  // SOLSTREAM_MEDIA
                // Logged because which auth path a client took is the first question
                // when one misbehaves.
                Log("[agent] client authenticated with a v2 proof");
                return "{\"type\":\"auth\",\"ok\":true}";
            }
            ++auth_failures;
            Log("[agent] rejected a bad auth proof (%d on this connection)",
                auth_failures);
            return "{\"type\":\"auth\",\"ok\":false,\"message\":\"bad token\"}";
        }

        // No v1 fallback. Accepting a cleartext `token` would be a downgrade to
        // an authorised session with no channel keys -- window titles, the
        // application list and the clipboard all in the clear -- since
        // `channelCrypto` is only negotiated in the v2 branch above.
        if (std::string ignored; FieldString(line, "token", ignored)) {
            ++auth_failures;
            Log("[agent] refused a cleartext token: this host authenticates with a "
                "v2 proof only (%d refusal%s on this connection)",
                auth_failures, auth_failures == 1 ? "" : "s");
            return "{\"type\":\"auth\",\"ok\":false,\"message\":\"this host needs a "
                   "v2 proof, not a token. Update SolStream on the Mac.\"}";
        }
        // Counted, not slept off: a delay here would hold the one client slot
        // shut against the paired Mac, which is the attacker's goal rather than
        // his cost. See kMaxAuthFailures.
        ++auth_failures;
        Log("[agent] rejected a bad token (%d refusal%s on this connection)",
            auth_failures, auth_failures == 1 ? "" : "s");
        return "{\"type\":\"auth\",\"ok\":false,\"message\":\"bad token\"}";
    }

    if (g_require_auth && !authenticated) {
        return "{\"type\":\"error\",\"message\":\"unauthenticated\",\"needsAuth\":true}";
    }

    // ── Media session ────────────────────────────────────────────────────────
    //
    // What replaces GameStream's setup entirely: no HTTP pairing, no HTTPS
    // /launch, no seven RTSP round trips. Two programs that have already
    // authenticated each other agree an ephemeral key and start sending.
    if (command == "media") {
        std::string op;
        FieldString(line, "op", op);
#ifdef SOLSTREAM_MEDIA
        if (op == "stop") {
            solstream::media::MediaSession::Instance().Stop();
            Log("[media] session stopped on request");
            return "{\"type\":\"media\",\"ok\":true,\"op\":\"stop\"}";
        }
        if (op == "stats") {
            return "{\"type\":\"media\",\"ok\":true,\"op\":\"stats\",\"stats\":"
                   + solstream::media::MediaSession::Instance().StatsJson() + "}";
        }
        if (op == "retarget") {
            long long id = 0;
            std::string displayName;
            FieldNumber(line, "window", id);
            FieldString(line, "display", displayName);
            HWND window = id ? WindowFromId(static_cast<uint64_t>(id)) : nullptr;
            HMONITOR monitor = displayName.empty() ? nullptr
                                                   : MonitorFromDeviceName(displayName);
            if (!window && !monitor) {
                return "{\"type\":\"media\",\"ok\":false,\"message\":\"no such target\"}";
            }
            const bool ok =
                solstream::media::MediaSession::Instance().Retarget(window, monitor);
            return std::string("{\"type\":\"media\",\"ok\":")
                 + (ok ? "true" : "false") + ",\"op\":\"retarget\"}";
        }
#endif
        if (op != "open") {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"unknown op\"}";
        }
        std::string cpubHex, cnonceHex;
        FieldString(line, "cpub", cpubHex);
        FieldString(line, "cnonce", cnonceHex);
        const std::vector<unsigned char> cpub = FromHex(cpubHex);
        const std::vector<unsigned char> cnonce = FromHex(cnonceHex);
        if (cpub.size() != 65 || cpub[0] != 0x04 || cnonce.size() != 32) {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"bad key material\"}";
        }

        std::vector<unsigned char> hpub;
        BCRYPT_KEY_HANDLE keyPair = NewEcdhKeyPair(hpub);
        if (!keyPair) {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"no key pair\"}";
        }
        const std::vector<unsigned char> secret = EcdhSecret(keyPair, cpub);
        BCryptDestroyKey(keyPair);
        if (secret.size() != 32) {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"agreement failed\"}";
        }

        const std::string hnonceHex = RandomHex(32);
        const std::vector<unsigned char> hnonce = FromHex(hnonceHex);
        const unsigned long long hcount = ++g_media_count;
        SaveMediaCount(hcount);
        const std::vector<unsigned char> okm =
            DeriveMediaKeys(cpub, hpub, cnonce, hnonce, hcount, secret, 0, g_token);
        if (okm.size() != 108) {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"derivation failed\"}";
        }

        // hostAuth, bytes 80..92. The Mac derives the same 108 bytes and checks
        // this: if it matches, both ends hold the same keys, and that is worth
        // knowing HERE rather than discovering it as every packet failing its
        // tag with nothing to say why.
        const std::string hauth = ToHex(okm.data() + 80, 12);
        const std::string hpubHex = ToHex(hpub);
        // Keys agreed. Now start the media path itself, if the client named
        // something to capture. A client that only wants the keys -- the
        // handshake test does -- gets them and nothing starts, which is what
        // made step 4 measurable before step 6 existed.
        std::string started = "false";
        std::string startError;
        // What the sound will be sent as, said in the reply so the Mac knows
        // without waiting for a packet. Empty -- and so not said -- without sound.
        std::string audioCodecReply, audioSourceReply;
        // What this host's input takes beyond what every host does. A Mac
        // sends keys by position only when this says "scancodes", and by
        // virtual key otherwise -- which every host, this one included, still
        // takes -- so either end can be the older one.
        std::string inputReply;
#ifdef SOLSTREAM_MEDIA
        inputReply = ",\"scancodes\":1";
        long long targetId = 0, fps = 60, bitrate = 20000000, audio = 1;
        // Zero means "host decides", which is what an absent field leaves behind.
        long long width = 0, height = 0;
        std::string displayName;
        FieldNumber(line, "window", targetId);
        FieldString(line, "display", displayName);
        FieldNumber(line, "fps", fps);
        FieldNumber(line, "bitrate", bitrate);
        FieldNumber(line, "audio", audio);
        FieldNumber(line, "width", width);
        FieldNumber(line, "height", height);
        // Sound quality and source. Absent from every Mac that predates them,
        // which therefore gets the whole PC's sound as PCM, as it always has.
        std::string audioCodec, audioSource;
        FieldString(line, "audioSource", audioSource);
        long long audioBitrate = 0, audioFrameMs = 0;
        FieldString(line, "audioCodec", audioCodec);
        FieldNumber(line, "audioBitrate", audioBitrate);
        FieldNumber(line, "audioFrameMs", audioFrameMs);
        HWND targetWindow =
            targetId ? WindowFromId(static_cast<uint64_t>(targetId)) : nullptr;
        HMONITOR targetMonitor =
            displayName.empty() ? nullptr : MonitorFromDeviceName(displayName);
        if (targetWindow || targetMonitor) {
            solstream::media::MediaConfig config;
            config.window = targetWindow;
            config.monitor = targetMonitor;
            config.fps = (UINT) (fps > 0 && fps <= 240 ? fps : 60);
            // An upper bound as well as a lower one. This arrives as a long long
            // and was only ever checked for being too small, so a client asking
            // for five billion bit/s had it wrapped into a UINT -- 705 Mbit/s,
            // a number nobody chose -- and the sender then paced at twice that,
            // which is line rate on any link this runs over. Out of range falls
            // back to the default rather than clamping, because a bitrate that
            // far out is a client bug, not a preference worth honouring.
            config.bitrate =
                (UINT) (bitrate > 1000000 && bitrate <= 500000000 ? bitrate : 20000000);
            // The Mac asks for a canvas so that its crops are pixel-exact
            // against the capture display; when it asks for nothing, the first
            // captured frame decides, exactly as before. Clamped here as well as
            // on the Mac because a number off the wire is a number off the wire:
            // above 4096 the H.264 encoders this runs on open and then never
            // produce a frame, which looks from the Mac like a session that
            // agreed to stream and went silent.
            config.width = (UINT) (width > 0 ? (width > 4096 ? 4096 : width) : 0);
            config.height = (UINT) (height > 0 ? (height > 4096 ? 4096 : height) : 0);
            config.audio = audio != 0;
            // Opus only when named. A bitrate outside what libopus does well with
            // stereo falls back to Standard's, and a packet length other than the
            // three the Mac offers to 10 ms, rather than either being clamped: as
            // with the video's, a number that far out is a client bug.
            if (audioCodec == "opus") {
                config.audioEncoding.codec = solstream::media::AudioEncoding::Codec::Opus;
                config.audioEncoding.bitrate =
                    (unsigned) (audioBitrate >= 24000 && audioBitrate <= 510000
                                    ? audioBitrate : 128000);
                config.audioEncoding.frameMs =
                    (unsigned) (audioFrameMs == 5 || audioFrameMs == 10 || audioFrameMs == 20
                                    ? audioFrameMs : 10);
            }
            if (config.audio) {
                audioCodecReply = audioCodec == "opus" ? "opus" : "pcm";
            }
            // The streamed apps' sound only: the processes of every window the
            // Mac is managing, read afresh by the audio thread as they change.
            // Said only when this Windows can do it, so that the Mac hears
            // when it gets the whole PC's sound instead; see audio_source.h.
            if (config.audio) {
                audioSourceReply = solstream::media::AudioSourceReply(
                    audioSource == "apps", solstream::media::AppSoundSupported());
                if (audioSourceReply == "apps") {
                    config.audioProcesses = [] { return StreamedProcesses(); };
                } else if (audioSource == "apps") {
                    Log("[media] only the streamed apps' sound needs Windows build 20348 "
                        "or later; sending the whole PC's");
                }
            }
            config.port = solstream::kDefaultMediaPort;
            // Start does not return until the capture and the encoder have both
            // opened or one of them has failed, so `streaming` below is what
            // happened rather than what was intended. It used to be the latter:
            // capture and encode are set up on the capture thread, this returned
            // as soon as that thread existed, and a WGC or encoder failure
            // arrived seconds later in the host's log only -- the Mac had
            // already closed its picker and sat on "Waiting for video" for ever.
            started = solstream::media::MediaSession::Instance().Start(
                          okm.data(), config, &startError)
                          ? "true" : "false";
        } else {
            startError = "no window or display named";
        }
#else
        startError = "this build has no media path";
#endif
        Log("[media] session %llu opened; keys derived; streaming %s%s%s; sound %s%s%s",
            hcount, started.c_str(), startError.empty() ? "" : " -- ",
            startError.c_str(), audioCodecReply.empty() ? "off" : audioCodecReply.c_str(),
            audioSourceReply.empty() ? "" : " from ", audioSourceReply.c_str());
        return "{\"type\":\"media\",\"ok\":true,\"ver\":1"
               ",\"hpub\":\"" + hpubHex + "\""
               ",\"hnonce\":\"" + hnonceHex + "\""
               ",\"hcount\":\"" + std::to_string(hcount) + "\""
               ",\"hauth\":\"" + hauth + "\""
               ",\"streaming\":" + started
               + (startError.empty() ? std::string()
                                     : ",\"message\":\"" + JsonEscape(startError) + "\"")
               + (audioCodecReply.empty() ? std::string()
                                          : ",\"audioCodec\":\"" + audioCodecReply + "\"")
               + (audioSourceReply.empty() ? std::string()
                                           : ",\"audioSource\":\"" + audioSourceReply + "\"")
               + inputReply
               + ",\"hport\":" + std::to_string(solstream::kDefaultMediaPort) + "}";
    }

    if (command == "displays") {
        return DisplaysJson(EnumerateDisplays());
    }

    if (command == "windows") {
        return WindowsJson(EnumerateWindows());
    }

    if (command == "apps") {
        // The same cached list `launch` and `icon` check membership against, so
        // the client can only ever name a path it was given.
        return AppsJson(AdvertisedApps());
    }

    if (command == "clipboard") {
        std::string text;
        if (FieldString(line, "text", text)) {
            return solstream::ClipboardSetJson(text);
        }
        // No text field means "what have you got"; a seq that matches what the
        // Mac already has means it need not ask for the contents.
        long long since = -1;
        if (FieldNumber(line, "seq", since) && since >= 0
            && static_cast<DWORD>(since) == solstream::ClipboardSequence()) {
            return solstream::ClipboardUnchangedJson();
        }
        return solstream::ClipboardGetJson();
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
        // Only the virtual display this host is capturing. SetDisplayMode writes
        // with CDS_UPDATEREGISTRY, so a name the Mac got wrong — or a host with
        // no virtual display, capturing the primary — would permanently change
        // the resolution of somebody's real monitor. The Mac already only asks
        // for a display it believes is virtual; this is the host not taking its
        // word for it. `ok:false` is what the Mac reads as "the host kept its
        // size", and it carries on at that size.
        const std::wstring wanted = ToWide(device);
        const std::wstring virtual_device = solstream::VirtualDisplayDevice();
        const std::wstring capture_display = CaptureDisplay();
        const bool is_capture = !capture_display.empty()
            && _wcsicmp(wanted.c_str(), capture_display.c_str()) == 0;
        const bool is_virtual =
            (!virtual_device.empty()
             && _wcsicmp(wanted.c_str(), virtual_device.c_str()) == 0)
            || solstream::IsSolStreamDisplayDriver(
                   ToWide(AdapterDescription(wanted.c_str())));
        if (!is_capture || !is_virtual) {
            Log("[agent] canvas refused for %s: not the virtual display being "
                "captured", device.c_str());
            return "{\"type\":\"canvas\",\"ok\":false,\"message\":\"only the "
                   "virtual display being captured can be resized\"}";
        }
        int got_w = 0, got_h = 0;
        int got_hz = 0;
        if (!SetDisplayMode(wanted, (int) want_w, (int) want_h,
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
        RECT client{};
        long long missed = 0;
        // A window that cannot be resized is moved and keeps its own size; see
        // MoveClientArea. Not a miss: the size it reports is the size it is.
        const bool fixed_size = !ClientSizeLimits(window).resizable;
        const bool ok = fixed_size
            ? MoveClientArea(window, (int) x, (int) y, &client)
            : PlaceClientArea(window, (int) x, (int) y, (int) w, (int) h, &client, &missed);
        // A miss that survived every correction is the application refusing the
        // size, and it is worth a line: it is the difference between "SolStream
        // sized this wrongly" and "this window will not be that shape", and until
        // now nothing anywhere recorded which of the two had happened. Only when
        // it is large enough to see -- an off-by-one on a rounded axis is not news.
        if (missed > 2) {
            const std::string title = WindowTitleForLog(window);
            Log("[place] \"%s\" asked for %lldx%lld at %lld,%lld and settled at "
                "%ldx%ld at %ld,%ld (%lld px out)",
                title.empty() ? "(untitled)" : title.c_str(), w, h, x, y,
                client.right - client.left, client.bottom - client.top,
                client.left, client.top, missed);
        }
        // The Mac asked for this, so it is the new truth — otherwise the watcher
        // would immediately drag the window back to the previous size.
        SetLockedGeometry(window, client);
        char buffer[384];
        const ClientLimits limits = ClientSizeLimits(window);
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"placed\",\"ok\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld"
                      ",\"minW\":%ld,\"minH\":%ld,\"maxW\":%ld,\"maxH\":%ld"
                      ",\"resizable\":%s,\"border\":%d,\"missed\":%lld}",
                      ok ? "true" : "false",
                      client.left, client.top,
                      client.right - client.left, client.bottom - client.top,
                      limits.minimum.x, limits.minimum.y,
                      limits.maximum.x, limits.maximum.y,
                      limits.resizable ? "true" : "false",
                      ResizeBorderThickness(window), missed);
        // The title strip the application draws, for the Mac to leave out of
        // the picture when asked, and the program, to remember that by.
        std::string reply(buffer);
        reply.pop_back();
        reply += ",\"titleBar\":" + std::to_string(CachedTitleStripHeight(window));
        reply += ",\"program\":\"" + JsonEscape(ProgramName(window)) + "\"}";
        return reply;
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
            // A reconnecting Mac asks at once, while its last session's
            // cleanup may still be giving this window back.
            WaitForRestoreToFinish(window);
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
        // Pinning claims a slot even when the window is not geometry-locked, so
        // that whatever happens to the session — a clean disconnect or a Mac
        // that simply vanishes — the window is known to be owed a trip back
        // down; and it is refused when no slot is free, because a window pinned
        // with nothing recording it stays above everything until its
        // application restarts. The slot is also what makes the watcher report
        // the window closing.
        if (on) {
            WaitForRestoreToFinish(window);
            EnterCriticalSection(&g_lock_cs);
            const int slot = ClaimSlot(window);
            LeaveCriticalSection(&g_lock_cs);
            if (slot == kClaimRestoreInProgress) {
                return "{\"type\":\"error\",\"message\":\"this window is still being "
                       "restored; try again shortly\"}";
            }
            if (slot < 0) {
                Log("[agent] refused topmost: all %d window slots are taken", kMaxLocks);
                return "{\"type\":\"error\",\"message\":\"too many windows are being "
                       "managed; close one on the Mac first\"}";
            }
            RecordOwedWindows();
        }
        // Asynchronous, and refused for a hung window, so an application stuck
        // in its message loop cannot stall the command thread.
        const BOOL ok = !Unresponsive(window)
            && SetWindowPos(window, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
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
            const std::string title = WindowTitleForLog(window);
            Log("[focus] could not take the foreground for \"%s\";"
                " keystrokes will go to whatever holds it", title.c_str());
        }

        char buffer[128];
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"focused\",\"ok\":%s,\"foreground\":%s}",
                      foreground ? "true" : "false", foreground ? "true" : "false");
        return buffer;
    }

    return "{\"type\":\"error\",\"message\":\"unknown cmd\"}";
}

// ── Server ───────────────────────────────────────────────────────────────────

// A line torn in half by another thread's send() is a protocol desync the Mac
// cannot recover from -- it has no request ids to resynchronise against, so it
// drops the connection. `g_send_cs` is declared with the push channel, above.
bool SendLine(SOCKET client, const std::string& text) {
    EnterCriticalSection(&g_send_cs);
    struct Unlock {
        ~Unlock() { LeaveCriticalSection(&g_send_cs); }
    } unlock;

    std::string payload;
#ifdef SOLSTREAM_MEDIA
    if (g_channel.encrypted && client == g_channel_socket) {
        // Sealed and length-prefixed. The newline framing below is not merely
        // unnecessary here, it is unusable: ciphertext contains 0x0A as often
        // as any other byte.
        std::vector<unsigned char> record;
        if (!solstream::media::SealMessage(g_channel, text, record)) {
            Log("[agent] could not seal a %zu-byte message; dropping the client",
                text.size());
            return false;
        }
        payload.assign((const char*) record.data(), record.size());
    } else {
        payload = text;
        payload += '\n';
    }
#else
    payload = text;
    payload += '\n';
#endif

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
//
// Whether there is a cursor at all is pushed the same way, as the shape
// "hidden". A game reading raw motion hides it -- GLFW games such as Minecraft
// set a null cursor over their window, others call ShowCursor(FALSE) -- and
// shows one again for a menu. The Mac's gaming mode follows that: the mouse is
// taken while it is hidden and given back the moment a shape returns. A Mac
// that predates "hidden" draws its arrow for a name it does not know, which is
// what it drew for a hidden cursor before.
//
// Every push also carries "reportsHidden":1. A shape alone cannot say whether
// the agent behind it would ever send "hidden" -- one that predates it never
// does -- and without that the Mac has to watch a game hide its cursor AND show
// it again before it dares follow, which is a whole round of menus with no
// pointer. Macs that read only "shape" are unaffected by the extra key.

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
const char* CursorName(HCURSOR cursor) {
    // Before the table, so a system cursor that failed to load (a null handle)
    // cannot match a cursor that could not be read.
    if (cursor == nullptr) {
        return "arrow";
    }
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

/// Whether an application has taken the cursor off the screen -- a game reading
/// the mouse itself -- rather than Windows simply not drawing one.
///
/// GLFW and SDL hide it with SetCursor(NULL), which leaves no handle; others
/// call ShowCursor(FALSE), which clears CURSOR_SHOWING. But Windows clears that
/// flag on its own as well: for pen and touch input, which it marks
/// CURSOR_SUPPRESSED, and on a PC with no mouse, whose display count starts
/// below zero and stays there whatever SendInput does. Neither is a game asking
/// for the mouse. Reported as hidden, they would put "hidden" in place of every
/// shape for as long as they last -- no I-beam over a text field even in
/// desktop mode -- and have gaming mode take the mouse over a menu.
bool HiddenByApplication(const CURSORINFO& info) {
    if (info.hCursor == nullptr) {
        return true;
    }
    if ((info.flags & CURSOR_SHOWING) != 0 || (info.flags & CURSOR_SUPPRESSED) != 0) {
        return false;
    }
    return GetSystemMetrics(SM_MOUSEPRESENT) != 0;
}

DWORD WINAPI CursorWatcherProc(LPVOID parameter) {
    const LONG mine = (LONG) (LONG_PTR) parameter;
    HCURSOR last = nullptr;
    bool last_hidden = false;
    bool logged_once = false;
    while (InterlockedCompareExchange(&g_cursor_generation, 0, 0) == mine) {
        if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
            // Not authenticated yet. Forget the last state too, so the first
            // push after authentication carries the current one rather than
            // being skipped as unchanged.
            last = nullptr;
            last_hidden = false;
            Sleep(40);
            continue;
        }
        CURSORINFO info{};
        info.cbSize = sizeof(info);
        if (!GetCursorInfo(&info)) {
            // A failed read -- the secure desktop holding the input during a
            // UAC prompt, say -- says nothing about the application, so the
            // last state stands and nothing is sent. Either answer could be
            // wrong: "hidden" has the Mac take the mouse for a game that never
            // asked, and a shape gives it back from one that still wants it.
            Sleep(40);
            continue;
        }
        const bool hidden = HiddenByApplication(info);
        // No handle while hidden: a game swapping cursors it never shows is no
        // change worth a line.
        HCURSOR current = hidden ? nullptr : info.hCursor;
        if (!logged_once) {
            logged_once = true;
            Log("[cursor] reporting shape changes (currently %s)",
                hidden ? "hidden" : CursorName(current));
        }
        if (current != last || hidden != last_hidden) {
            if (hidden != last_hidden) {
                // One line per hide and show: when the Mac holds on to the
                // mouse in a menu, this says whether the PC ever said so.
                Log("[cursor] %s", hidden ? "hidden" : "shown again");
            }
            last = current;
            last_hidden = hidden;
            std::string line = "{\"type\":\"cursor\",\"shape\":\"";
            line += hidden ? "hidden" : CursorName(current);
            line += "\",\"reportsHidden\":1}";
            // Only while this watcher is still the current one; see PushLine.
            const bool sent = PushLine(line, mine);
            if (!sent) {
                break;
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
    // Under the lock the window watcher and the cursor watcher both read it
    // under. Only the clearing in StopCursorWatcher used to be, and a SOCKET is
    // not written atomically -- so the two threads that read this while it was
    // being assigned could see neither the old value nor the new one.
    EnterCriticalSection(&g_send_cs);
    g_push_client = client;
    LeaveCriticalSection(&g_send_cs);
    InterlockedExchange(&g_push_authorised, authorised ? 1 : 0);
    const LONG generation = InterlockedIncrement(&g_cursor_generation);
    g_cursor_thread = CreateThread(nullptr, 0, CursorWatcherProc,
                                   (LPVOID) (LONG_PTR) generation, 0, nullptr);
}

void StopCursorWatcher() {
    // Retire this generation: the thread leaves at its next look, and one that
    // outlives the wait below can never be the current one again.
    InterlockedIncrement(&g_cursor_generation);
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

/// A session that has proved the token may go this long without saying anything.
///
/// Without a receive timeout at all, a peer that vanishes without a FIN (sleep,
/// VPN drop, cable pull) leaves this blocked in recv forever, and because the
/// accept loop is single-client the agent never serves anyone again.
constexpr DWORD kIdleTimeoutMs = 30000;

/// And this long before it has proved anything.
///
/// A socket that has authenticated nothing is not owed a session's patience: it
/// is holding the one slot, and for as long as it does the paired Mac is turned
/// away. Thirty seconds of that, on repeat, is a denial of service that costs
/// the attacker one connect() and nothing else.
///
/// Not "a few seconds", though, because the legitimate pre-auth state is a
/// person reading the pairing token off the Windows screen and typing it into a
/// sheet on the Mac -- the connection stays open across all of it. What keeps
/// that socket alive is the Mac's ten-second heartbeat, so anything at or below
/// ten seconds here would drop somebody in the middle of typing.
constexpr DWORD kPreAuthTimeoutMs = 15000;

/// And this long in total, however busy it is.
///
/// The timeout above bounds nothing on its own, which is the trap this closes.
/// SO_RCVTIMEO is applied per recv() call, so every byte that arrives starts
/// those fifteen seconds again: anyone who can open this port can hold the
/// agent's only client slot for as long as they like by writing one byte every
/// fourteen seconds, and never authenticating. While they hold it the accept
/// loop closes the paired Mac on arrival without a word, so the symptom is a
/// Mac that reconnects, is dropped, backs off and reconnects, for ever.
///
/// This clock starts when the socket is accepted and nothing resets it.
///
/// Two minutes rather than the fifteen seconds above, because the one thing
/// that legitimately keeps a connection here unproved is a person reading a
/// 32-character pairing token off the PC's screen and typing it into a sheet on
/// the Mac. There is no clipboard between the two machines until they are
/// paired, so that is half a minute of careful typing for most people, and the
/// Mac cannot hold its place across a drop: it re-asks from scratch, on a second
/// sheet over the first, with whatever was typed into the first one buried under
/// it. A budget short enough to inconvenience a squatter is therefore short
/// enough to make pairing impossible, and a squatter who is disconnected simply
/// reconnects — what this is worth is that the hold is now finite and logged,
/// not that it is prevented.
constexpr ULONGLONG kPreAuthDeadlineMs = 120000;

/// How many rejected proofs one connection may make before it is dropped.
///
/// Guessing 16 random bytes is not a real attack; what needs bounding is one
/// socket guessing for ever while it holds the only client slot.
///
/// Three, not one, because a person who mistypes a token should be told so and
/// allowed another go on the same connection, and the Mac re-asks in place when
/// a proof comes back refused.
constexpr int kMaxAuthFailures = 3;

// ── The session's holder ─────────────────────────────────────────────────────
//
// Which Mac holds the one session, so that the same Mac coming back from a
// network change can take it over rather than be told it is busy with itself
// (session_takeover.h).
//
// All four fields are guarded by g_holder_mutex. The socket is cleared under
// it BEFORE the serving thread closes the socket, so a takeover that shuts the
// holder down can never reach a handle Winsock has since given to somebody
// else -- it reuses SOCKET values freely.
std::mutex g_holder_mutex;
SOCKET g_holder_socket = INVALID_SOCKET;
/// The id that Mac sent with its auth proof; empty for one that sent none.
std::string g_holder_id;
/// Set by a takeover, read by the serving thread on its next wakeup.
bool g_holder_retiring = false;
/// When the holder was last heard from: by the serving thread's reads, and by
/// knocks that find more waiting unread than before (session_takeover.h).
solstream::HolderHearing g_holder_hearing;

/// Record `client` as the session's holder, the moment it is authenticated.
void BecomeHolder(SOCKET client, const std::string& id) {
    std::lock_guard<std::mutex> lock(g_holder_mutex);
    g_holder_socket = client;
    g_holder_id = id;
    g_holder_retiring = false;
    g_holder_hearing = solstream::HeardFresh(GetTickCount64());
}

/// Bytes waiting unread on `socket`, or nothing known.
bool UnreadBytes(SOCKET socket, unsigned long long& unread) {
    u_long waiting = 0;
    if (ioctlsocket(socket, FIONREAD, &waiting) != 0) {
        return false;
    }
    unread = waiting;
    return true;
}

/// The serving thread has read from `client`: see solstream::HearingRead.
void HeardFromHolder(SOCKET client, unsigned long long sent_by) {
    unsigned long long left = 0;
    const bool known = UnreadBytes(client, left);
    std::lock_guard<std::mutex> lock(g_holder_mutex);
    if (g_holder_socket != client) {
        return;
    }
    solstream::HearingRead(g_holder_hearing, sent_by, known ? left : g_holder_hearing.unread);
}

/// Whether a takeover has asked `client`'s session to end.
bool SessionRetired(SOCKET client) {
    std::lock_guard<std::mutex> lock(g_holder_mutex);
    return g_holder_socket == client && g_holder_retiring;
}

enum class ClientWait { Readable, Idle, Retired, Failed };

/// Wait for `client` to send something, for at most `idle_ms` of silence.
///
/// A select() on a short tick rather than one recv() blocking for the whole of
/// the idle timeout, because a session that the same Mac has taken over has to
/// END: its recv() would otherwise sit there for thirty seconds holding the
/// slot the Mac is waiting for. shutdown() from another thread is not promised
/// to wake a blocked recv() on Windows, and closesocket() from another thread
/// would free a handle this thread is still using. Polling a flag is neither.
ClientWait AwaitClient(SOCKET client, DWORD idle_ms) {
    const ULONGLONG since = GetTickCount64();
    for (;;) {
        if (SessionRetired(client)) {
            return ClientWait::Retired;
        }
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(client, &readable);
        timeval tick{0, 250 * 1000};
        const int ready = select(0, &readable, nullptr, nullptr, &tick);
        if (ready == SOCKET_ERROR) {
            return ClientWait::Failed;
        }
        if (ready > 0) {
            return ClientWait::Readable;
        }
        if (GetTickCount64() - since >= idle_ms) {
            return ClientWait::Idle;
        }
    }
}

void ServeClient(SOCKET client) {
    // Raised to kIdleTimeoutMs the moment the client authenticates, below.
    DWORD timeout_ms = g_require_auth ? kPreAuthTimeoutMs : kIdleTimeoutMs;
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, (const char*) &timeout_ms, sizeof(timeout_ms));
    // Before the greeting, so nothing this connection does can shorten what it
    // is measured against.
    const ULONGLONG accepted_at = GetTickCount64();
    const DWORD send_timeout_ms = kIdleTimeoutMs;
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, (const char*) &send_timeout_ms,
               sizeof(send_timeout_ms));
    BOOL keepalive = TRUE;
    setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, (const char*) &keepalive, sizeof(keepalive));

#ifdef SOLSTREAM_MEDIA
    // BEFORE the greeting, not after it. Every connection starts in the clear
    // and negotiates again, and a channel left encrypted by the last client
    // would seal THIS client's plaintext hello with keys it has never heard of
    // -- binary where it is reading newline-JSON, on the very first line. This
    // reset used to sit below the send, where it could not prevent that. Winsock
    // also reuses SOCKET values freely, so clearing the binding here is what
    // stops a recycled handle from inheriting the last connection's keys.
    EnterCriticalSection(&g_send_cs);
    g_channel.Reset();
    g_pending_channel.Reset();
    g_channel_socket = INVALID_SOCKET;
    LeaveCriticalSection(&g_send_cs);
#endif

    // Greet with the protocol version and the display list, so the Mac can pick
    // its capture display without a round trip.
    const std::string hostname = ComputerName();

    // The greeting says whether a token is needed, so the Mac can ask for one up
    // front rather than discovering it by having a command refused.
    // Fresh per connection, so a proof recorded off the wire is worth nothing on
    // the next one. Generated even when no auth is required, because the same
    // value seeds the media key schedule later and the handshake should not have
    // two shapes.
    const std::string challenge = RandomHex(32);

    std::string hello = "{\"type\":\"hello\",\"version\":";
    hello += std::to_string(kProtocolVersion);
    hello += ",\"host\":\"" + JsonEscape(hostname) + "\"";
    hello += ",\"needsAuth\":" + std::string(g_require_auth ? "true" : "false");
    hello += ",\"challenge\":\"" + challenge + "\"";
#ifdef SOLSTREAM_MEDIA
    // Advertised rather than assumed. A client that does not understand it goes
    // on speaking newline-JSON, and a host that does not offer it never has a
    // client try: a mismatch here is not a degraded channel, it is a socket
    // where each end is reading the other's bytes as the wrong thing entirely.
    hello += ",\"channelCrypto\":2";
#endif
    hello += "}";
    if (!SendLine(client, hello)) {
        return;
    }
    // The display list is only volunteered to a client that has no authenticating
    // to do; otherwise it would leak the machine's monitor layout to anyone who
    // can open a socket.
    bool authenticated = !g_require_auth;
    // Whatever this function returns through, the count comes back down with
    // it: there are several early returns below and one of them forgotten would
    // leave the window claiming a Mac that had gone.
    struct AuthCount {
        const bool& live;
        ~AuthCount() {
            if (live) {
                g_clients_authenticated.fetch_sub(1);
            }
        }
    } counted{authenticated};
    // And the holder's record goes with it, under its lock and before the
    // caller closes this socket -- see g_holder_mutex.
    struct Holding {
        SOCKET socket;
        ~Holding() {
            std::lock_guard<std::mutex> lock(g_holder_mutex);
            if (g_holder_socket == socket) {
                g_holder_socket = INVALID_SOCKET;
                g_holder_id.clear();
                g_holder_retiring = false;
            }
        }
    } holding{client};
    if (authenticated) {
        // Loopback, which needs no token and is therefore already a session.
        // It names nobody, so nothing can take it over.
        g_clients_authenticated.fetch_add(1);
        BecomeHolder(client, std::string());
        if (!SendLine(client, DisplaysJson(EnumerateDisplays()))) {
            return;
        }
    }

    std::string buffer;
    char chunk[4096];
    // Per connection, deliberately: a fresh socket is a fresh three guesses, and
    // the point is not to make guessing hard — the token is 16 random bytes —
    // but to stop one socket guessing for ever while holding the slot.
    int auth_failures = 0;
    // Set once a line has outgrown the cap, and cleared at the newline that ends
    // it. The rest of an oversized line has not arrived yet — it comes in later
    // recv() chunks — so this cannot be a one-off scan of what is in hand.
    bool discarding = false;
    // When this thread last stopped waiting and went to handle what arrived.
    ULONGLONG busy_since = GetTickCount64();
    for (;;) {
        // Anything already waiting came while the last command ran, which can
        // be a minute for a launch. Said to have been sent no later than that
        // command started, so a Mac whose network went in the middle of it is
        // not counted as heard from the moment the command returns.
        unsigned long long waiting = 0;
        const bool came_while_busy = UnreadBytes(client, waiting) && waiting > 0;
        const ClientWait waited = AwaitClient(client, timeout_ms);
        if (waited == ClientWait::Retired) {
            Log("[agent] ending this session: the Mac that held it has taken it over");
            return;
        }
        if (waited == ClientWait::Failed) {
            return;
        }
        bool idle = waited == ClientWait::Idle;
        int n = SOCKET_ERROR;
        if (!idle) {
            // The receive timeout set above still stands behind this, for a
            // recv() that blocks although select() said there was something.
            n = recv(client, chunk, sizeof(chunk), 0);
            idle = n == SOCKET_ERROR && WSAGetLastError() == WSAETIMEDOUT;
        }
        if (idle) {
            Log("[agent] client idle for %lus%s, dropping",
                (unsigned long) (timeout_ms / 1000),
                authenticated ? "" : " without authenticating");
            return;
        }
        if (n <= 0) {
            return;
        }
        const ULONGLONG received_at = GetTickCount64();
        HeardFromHolder(client, came_while_busy ? busy_since : received_at);
        busy_since = received_at;
        // Here, on every wakeup, and before a single byte of what arrived is
        // looked at. Anywhere further down and some framing state ducks it: the
        // oversized-line discard below leaves the loop early, so a client that
        // sends an endless line and no newline would never reach a check placed
        // after it -- which is exactly the shape of the traffic this bounds.
        if (!authenticated && GetTickCount64() - accepted_at >= kPreAuthDeadlineMs) {
            Log("[agent] client held the socket for %llus without authenticating, "
                "dropping", (unsigned long long) (kPreAuthDeadlineMs / 1000));
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

        // Two framings, and which one is in force changes exactly once per
        // connection: newline-delimited until the auth reply has gone out,
        // length-prefixed records after it. Reading one as the other produces
        // garbage rather than an error, which is why the switch happens on the
        // send side first and is never negotiated twice.
        for (;;) {
            std::string line;
#ifdef SOLSTREAM_MEDIA
            if (g_channel.encrypted) {
                bool fatal = false;
                if (!solstream::media::OpenMessage(g_channel, buffer, line, fatal)) {
                    if (fatal) {
                        Log("[agent] a record on the encrypted channel did not "
                            "authenticate; dropping the client");
                        return;
                    }
                    break;   // more bytes needed
                }
            } else
#endif
            {
                const size_t newline = buffer.find('\n');
                if (newline == std::string::npos) {
                    break;
                }
                line = buffer.substr(0, newline);
                buffer.erase(0, newline + 1);
            }
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            if (line.empty()) {
                continue;
            }
            const bool was_authenticated = authenticated;
            std::string channel_cnonce;
            if (!SendLine(client, HandleCommand(line, authenticated, challenge,
                                                channel_cnonce, auth_failures))) {
                return;
            }
#ifdef SOLSTREAM_MEDIA
            // AFTER the reply, never before: the client is still reading lines
            // until it has read the one that says the proof was accepted.
            if (!channel_cnonce.empty() && !g_channel.encrypted) {
                EnterCriticalSection(&g_send_cs);
                g_channel.Adopt(g_pending_channel);
                g_channel.encrypted = true;
                g_channel_socket = client;
                LeaveCriticalSection(&g_send_cs);
                Log("[agent] the channel is encrypted from here, "
                    "with an ephemeral key");
            }
#endif
            // Authenticating completes the greeting: the display list is part of
            // the hello sequence, withheld until now, and the Mac waits for it
            // before doing anything else.
            if (!was_authenticated && authenticated) {
                // A session may now be quiet for as long as a session may: the
                // Mac polls nothing while it sits in the application picker,
                // and the short pre-auth budget above exists to bound a socket
                // that has proved nothing, not to hurry one that has.
                timeout_ms = kIdleTimeoutMs;
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO,
                           (const char*) &timeout_ms, sizeof(timeout_ms));
                // Who this is, from the line that proved it. A Mac that
                // predates the field sends none, and its session is then one
                // nobody can take over.
                std::string id;
                if (!FieldString(line, "client", id) || !solstream::IsClientId(id)) {
                    id.clear();
                }
                BecomeHolder(client, id);
                InterlockedExchange(&g_push_authorised, 1);
                if (!SendLine(client, DisplaysJson(EnumerateDisplays()))) {
                    return;
                }
            }
            // After the reply, never before it: a client whose last guess was
            // wrong has to be told so, or the Mac shows a token sheet that never
            // says the token was refused and the person retypes the same thing.
            if (!authenticated && auth_failures >= kMaxAuthFailures) {
                Log("[agent] dropping a client after %d refused proofs", auth_failures);
                return;
            }
        }

        // A client that never sends a newline must not grow this unbounded —
        // but refuse the line, not the client. Dropping the connection is far
        // more destructive than it sounds: closing the socket runs UnlockAll(),
        // which pulls every streamed window off the virtual display and back
        // onto the real desktop, in the middle of a session the user is still
        // watching. The Mac does reconnect and re-assert every window now, but
        // the media session does not come back with it -- so what this costs is
        // still a live picture of a window that has been moved out from under it.
        if (buffer.size() > solstream::kMaxLineBytes) {
#ifdef SOLSTREAM_MEDIA
            // Newline framing only. Everything above -- clearing the buffer,
            // then resynchronising on the next '\n' -- describes a line, and on
            // the encrypted channel there are no lines: there is a length
            // prefix and a sealed record, and 0x0A occurs in ciphertext as
            // often as any other byte. Run here it threw away half of a record,
            // then treated an arbitrary byte inside the next one as a frame
            // boundary, after which every record failed its tag for a reason
            // nothing could report. A record that cannot be framed cannot be
            // recovered from, so drop the connection instead.
            if (g_channel.encrypted) {
                Log("[agent] a record on the encrypted channel passed %zu bytes "
                    "without framing; dropping the client", solstream::kMaxLineBytes);
                return;
            }
#endif
            Log("[agent] request over %zu bytes, skipping it", solstream::kMaxLineBytes);
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

/// Take the one client slot for a connection, if it is free.
///
/// A compare-and-swap rather than a check and an increment, because two
/// threads now admit clients: the accept loop, and a takeover waiting for the
/// session it ended to let go. Whichever gets there first has the slot.
bool ClaimClientSlot() {
    int expected = 0;
    return g_clients_connected.compare_exchange_strong(expected, 1);
}

/// Sessions whose windows are still being put back where they were, after the
/// slot was freed. See ServeAndRetire.
std::atomic<int> g_windows_restoring{0};

/// Serve a client that holds the slot, then put everything back. Runs on a
/// thread of its own; the slot must already have been claimed for it.
void ServeAndRetire(SOCKET client) {
    // Loopback needs no token, so it is authorised from the start.
    StartCursorWatcher(client, !g_require_auth);
    ServeClient(client);
#ifdef SOLSTREAM_MEDIA
    // Destroy the session keys with the session. The point of the
    // ephemeral half is that it stops existing when the connection
    // does; holding the derived keys until the NEXT client happens
    // to connect keeps a recorded session decryptable for exactly
    // as long as nobody reconnects.
    EnterCriticalSection(&g_send_cs);
    g_channel.Reset();
    g_pending_channel.Reset();
    g_channel_socket = INVALID_SOCKET;
    LeaveCriticalSection(&g_send_cs);
#endif
    // Stopped before the socket closes: the watcher writes to it.
    StopCursorWatcher();
    closesocket(client);
#ifdef SOLSTREAM_MEDIA
    // And stop streaming to a Mac that has gone, rather than leave
    // capture, encode and send running -- and whatever key or button
    // it was holding still down on the host -- until the media
    // path's own silence timeout notices.
    solstream::media::MediaSession::Instance().Stop();
#endif
    // Every managed window is owed its frame, z-order and placement
    // back. The slots are released first and the client slot freed
    // before the windows are touched: restoring crosses into other
    // processes, and if one of those is hung, a cleanup stuck there
    // must not keep every later Mac turned away.
    const std::vector<WindowLock> released = TakeSlotsForRestore();
    // Counted before the slot is freed, so nobody who claims the slot and
    // then reads this count can find it zero while the windows are being
    // moved. That holds only for a reader that claims first: see
    // ListenForTakeover.
    g_windows_restoring.fetch_add(1);
    g_clients_connected.fetch_sub(1);
    RestoreReleasedSlots(released);
    g_windows_restoring.fetch_sub(1);
    Log("[agent] client disconnected");
}

// ── Taking over a session ────────────────────────────────────────────────────

/// Knocks being given the chance to take over, at most this many at once. Each
/// holds a thread for a few seconds at most, and a Mac that cannot take over
/// closes straight away; the cap is for anything that connects and then sits.
constexpr int kMaxTakeoverListeners = 4;
std::atomic<int> g_takeover_listeners{0};
/// How long a knock has to ask, once it has been offered.
constexpr DWORD kTakeoverListenMs = 5000;
/// How long a takeover waits for the session it ended to let go of the slot.
/// The teardown joins the cursor watcher (up to two seconds) and stops the
/// media session; a session stuck in a command takes as long as the command.
/// The Mac waits twelve seconds for an answer, so this has to be well inside.
constexpr DWORD kTakeoverWaitMs = 8000;

/// The refusal a Mac gets while somebody holds the session. `extra` is more
/// fields, each with its leading comma.
std::string BusyLine(const std::string& message, const std::string& extra) {
    std::string busy = "{\"type\":\"busy\",\"message\":\"" + JsonEscape(message) + "\"";
    busy += ",\"virtualDisplay\":"
         + std::string(solstream::HasVirtualDisplayCached() ? "true" : "false");
    busy += extra;
    busy += "}";
    return busy;
}

std::string AnotherMacMessage() {
    return ComputerName() + " is already streaming to another Mac. Disconnect there first.";
}

std::string SameMacMessage() {
    return ComputerName() + " is still letting go of this Mac's last connection.";
}

/// One line from a socket nobody else is reading: within `budget_ms` in all,
/// at most `max_bytes`, and nothing after it. False if the peer closed, went
/// quiet, or sent more -- this side is about to hand the socket to
/// ServeClient, which starts with an empty buffer, so a byte read past the
/// line here would be a byte lost.
///
/// Each wait is for what is left of the budget, not the whole of it again. A
/// receive timeout is per recv(), so a peer that sent one byte just inside
/// the budget used to be given a second budget to send the next, and held a
/// listener for twice as long as it was meant to.
bool ReadOnlyLine(SOCKET socket, DWORD budget_ms, size_t max_bytes, std::string& line) {
    const ULONGLONG started = GetTickCount64();
    std::string buffer;
    char chunk[512];
    for (;;) {
        const ULONGLONG elapsed = GetTickCount64() - started;
        if (elapsed >= budget_ms) {
            return false;
        }
        const ULONGLONG left_ms = budget_ms - elapsed;
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socket, &readable);
        timeval left{static_cast<long>(left_ms / 1000), static_cast<long>((left_ms % 1000) * 1000)};
        if (select(0, &readable, nullptr, nullptr, &left) <= 0) {
            return false;
        }
        const int n = recv(socket, chunk, sizeof(chunk), 0);
        if (n <= 0) {
            return false;
        }
        buffer.append(chunk, static_cast<size_t>(n));
        const size_t newline = buffer.find('\n');
        if (newline != std::string::npos) {
            if (newline + 1 != buffer.size()) {
                return false;
            }
            line = buffer.substr(0, newline);
            if (!line.empty() && line.back() == '\r') {
                line.pop_back();
            }
            return true;
        }
        if (buffer.size() > max_bytes) {
            return false;
        }
    }
}

/// Offer a knock the chance to show it is the Mac whose session this is, and
/// let it in if so. True when it has been given the slot.
///
/// The offer rides on the same `busy` line every Mac has always been sent,
/// as two fields a Mac that predates them ignores: it reports the refusal and
/// closes, exactly as before. A Mac that understands them answers with a
/// takeover proof over a fresh challenge and the id it gave in its own auth.
bool ListenForTakeover(SOCKET client) {
    const std::string challenge = RandomHex(32);
    if (challenge.empty()) {
        SendLine(client, BusyLine(AnotherMacMessage(), std::string()));
        return false;
    }
    if (!SendLine(client, BusyLine(AnotherMacMessage(),
                                   ",\"takeover\":1,\"challenge\":\"" + challenge + "\""))) {
        return false;
    }
    std::string line;
    if (!ReadOnlyLine(client, kTakeoverListenMs, 4096, line)) {
        return false;
    }
    std::string command, proof, cnonce, id;
    if (!FieldString(line, "cmd", command) || command != "takeover") {
        return false;
    }
    FieldString(line, "proof", proof);
    FieldString(line, "cnonce", cnonce);
    FieldString(line, "client", id);
    const bool proof_ok = solstream::TakeoverProofMatches(g_token, challenge, cnonce, id, proof);

    solstream::TakeoverVerdict verdict;
    unsigned long long silent_ms = 0;
    {
        std::lock_guard<std::mutex> lock(g_holder_mutex);
        const bool present = g_holder_socket != INVALID_SOCKET;
        // A serving thread inside a long command -- a launch waits up to a
        // minute for its window -- reads nothing until it returns, while a live
        // Mac's pings pile up unread behind it. More waiting than at the last
        // look is that Mac heard from; the same amount is not, so a Mac whose
        // network went in the middle of the command is taken over 15 seconds
        // after the first knock that finds its last bytes waiting, launch or
        // no launch.
        if (present) {
            unsigned long long unread = 0;
            if (!UnreadBytes(g_holder_socket, unread)) {
                unread = g_holder_hearing.unread;
            }
            silent_ms = solstream::HearingSilentMs(g_holder_hearing, unread, GetTickCount64());
        }
        verdict = solstream::DecideTakeover(proof_ok, id, present, g_holder_id, silent_ms);
        if (verdict == solstream::TakeoverVerdict::Take && present) {
            // Under the lock, so this is still the holder's socket and not a
            // handle reissued since. The flag is what ends its wait for the
            // next request; the shutdown is what fails a command or a push
            // in the middle of writing to a Mac that is not there.
            g_holder_retiring = true;
            shutdown(g_holder_socket, SD_BOTH);
        }
    }
    switch (verdict) {
        case solstream::TakeoverVerdict::Refused:
            Log("[agent] refused a takeover that did not prove the token");
            SendLine(client, BusyLine(AnotherMacMessage(), std::string()));
            return false;
        case solstream::TakeoverVerdict::Another:
            Log("[agent] refused a takeover: the session belongs to another Mac");
            SendLine(client, BusyLine(AnotherMacMessage(), ",\"holder\":\"other\""));
            return false;
        case solstream::TakeoverVerdict::NotYet:
            Log("[agent] the Mac that holds the session reconnected while it was still "
                "live (heard %llus ago); asking it to try again",
                silent_ms / 1000);
            SendLine(client, BusyLine(SameMacMessage(), ",\"holder\":\"self\""));
            return false;
        case solstream::TakeoverVerdict::Take:
            break;
    }
    Log("[agent] the Mac that held the session is taking it over (silent for %llus)",
        silent_ms / 1000);

    const ULONGLONG deadline = GetTickCount64() + kTakeoverWaitMs;
    for (;;) {
        // An update about to stop this host lets nobody in, as on arrival.
        if (solstream::update::InstallStarting()) {
            return false;
        }
        // And not while the ended session is still putting its windows back.
        // This Mac re-places the same windows the moment it is in, a round
        // trip from now, and a restore landing after that would carry a window
        // off the capture display under a stream that looks perfectly healthy.
        // A Mac arriving the ordinary way comes seconds later and never meets
        // this; one let in here would meet it every time.
        //
        // The slot is claimed first and the count read after, never the other
        // way round. The ended session raises the count before it frees the
        // slot, so a claim that succeeds has already seen it raised. Read
        // first, the count can be zero a moment before that session raises it
        // and frees the slot, and the claim that follows then succeeds in the
        // middle of the restore.
        if (ClaimClientSlot()) {
            if (g_windows_restoring.load() == 0) {
                return true;
            }
            g_clients_connected.fetch_sub(1);
        }
        if (GetTickCount64() >= deadline) {
            break;
        }
        Sleep(25);
    }
    // Still held: by the old session, stuck in a command that has not returned,
    // or by somebody who got into the slot first. Say which as best this side
    // knows; the Mac tries again either way, and is told then.
    bool another = false;
    {
        std::lock_guard<std::mutex> lock(g_holder_mutex);
        another = g_holder_socket != INVALID_SOCKET && g_holder_id != id;
    }
    Log("[agent] the session did not let go within %lus", (unsigned long) (kTakeoverWaitMs / 1000));
    SendLine(client, another ? BusyLine(AnotherMacMessage(), ",\"holder\":\"other\"")
                             : BusyLine(SameMacMessage(), ",\"holder\":\"self\""));
    return false;
}

/// ListenForTakeover on a thread of its own, then serve or close.
void OfferTakeover(SOCKET client) {
    const bool admitted = ListenForTakeover(client);
    g_takeover_listeners.fetch_sub(1);
    if (admitted) {
        ServeAndRetire(client);
    } else {
        closesocket(client);
    }
}

}  // namespace

/// Answer "is anybody there" on the local network.
///
/// One datagram in, one datagram out. It replaces an mDNS record that Sunshine
/// used to advertise on this machine's behalf, which is not something that can
/// be inherited: SolStream would have had to run a responder, and Windows has
/// no in-box way to advertise an arbitrary service.
///
/// What it discloses is the computer's name and the fact that SolStream is
/// installed, to anybody already on the same network segment. A port scan
/// establishes both. It grants nothing: every command still requires the token.
///
/// The reply is barely larger than the question, so this is not usable as a
/// reflection amplifier -- but it only ever answers the exact question string,
/// which keeps it from answering anything else at all.
void StartDiscoveryResponder() {
    std::thread([] {
        SOCKET listener = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (listener == INVALID_SOCKET) {
            return;
        }
        BOOL reuse = TRUE;
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, (const char*) &reuse, sizeof(reuse));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = INADDR_ANY;
        address.sin_port = htons(solstream::kDiscoveryPort);
        if (bind(listener, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
            Log("[discover] UDP %u is taken; this PC will not answer discovery",
                solstream::kDiscoveryPort);
            closesocket(listener);
            return;
        }

        const std::string name = ComputerName();
        const std::string reply = "SOLSTREAM-HOST/1 " + name;
        Log("[discover] answering on UDP %u as %s", solstream::kDiscoveryPort,
            name.c_str());

        char buffer[256];
        bool complained = false;
        for (;;) {
            sockaddr_in from{};
            int fromLen = sizeof(from);
            const int n = recvfrom(listener, buffer, sizeof(buffer) - 1, 0,
                                   (sockaddr*) &from, &fromLen);
            if (n <= 0) {
                // This socket has no receive timeout, so recvfrom blocks and a
                // return here is an error rather than an idle moment. Windows
                // reports an ICMP port-unreachable from an earlier reply as
                // WSAECONNRESET on the next call, which returns instantly -- and
                // a bare `continue` then spins this thread at the speed of the
                // system call, for ever, on a discovery responder nobody is
                // watching. Paced, and said once.
                const int error = n < 0 ? WSAGetLastError() : 0;
                if (error != 0) {
                    if (!complained) {
                        complained = true;
                        Log("[discover] recvfrom failed with %d; pacing the loop",
                            error);
                    }
                    Sleep(50);
                }
                continue;
            }
            complained = false;
            buffer[n] = 0;
            if (std::string(buffer, (size_t) n) != "SOLSTREAM-DISCOVER/1") {
                continue;
            }
            sendto(listener, reply.c_str(), (int) reply.size(), 0,
                   (sockaddr*) &from, fromLen);
        }
    }).detach();
}

/// Give back a console nobody asked for.
///
/// The agent starts from a logon task and from a desktop shortcut, and being a
/// console subsystem program it got a console window each time: a black
/// rectangle sitting on the desktop for as long as SolStream ran, which the
/// picker then offered to the user's Mac as a window it could stream.
///
/// The obvious fix — building as a GUI subsystem program — is wrong, and
/// measurably so: a shell does not wait for a GUI program, so `SolStream.exe
/// --print-token` returns to the prompt before it has printed anything and every
/// script built on it silently reads nothing. That is a worse bug than a stray
/// window, and it is invisible until something depends on it.
///
/// So: keep the console subsystem, and hand the console back only when this
/// process is the only thing attached to it. One attached process means it was
/// created for us and no shell is reading it, so nothing is lost by closing it;
/// two or more means somebody ran this from a prompt and is waiting for output.
void ReleaseUnwantedConsole() {
    DWORD pids[4] = {0};
    if (GetConsoleProcessList(pids, 4) != 1) {
        return;
    }
    // Hidden first: FreeConsole tears the window down, but not before it has
    // been painted at least once.
    if (HWND console = GetConsoleWindow()) {
        ShowWindow(console, SW_HIDE);
    }
    FreeConsole();
    // The standard streams now point at handles that no longer exist. Writing
    // to those is harmless but pointless; NUL makes every later fprintf a
    // no-op instead of an error nobody checks.
#ifdef _MSC_VER
    FILE* stream = nullptr;
    freopen_s(&stream, "NUL", "w", stdout);
    freopen_s(&stream, "NUL", "w", stderr);
#else
    freopen("NUL", "w", stdout);
    freopen("NUL", "w", stderr);
#endif
}

/// The licences of the third-party code inside this executable, which
/// resources.rc embeds. libopus's is the only one. Its BSD licence asks for the
/// notice to go wherever a binary does, and for a program that ships as one
/// file, that means inside it. Nothing to print means a build without the media
/// path, which has no libopus in it either.
int PrintLicenses() {
    HRSRC found = FindResourceW(nullptr, L"OPUS_COPYING", RT_RCDATA);
    HGLOBAL loaded = found ? LoadResource(nullptr, found) : nullptr;
    const void* text = loaded ? LockResource(loaded) : nullptr;
    if (!text) {
        std::fputs("This build of SolStream contains no third-party code.\n", stdout);
        return 0;
    }
    std::fputs("SolStream compresses the PC's sound with libopus (https://opus-codec.org),\n"
               "which is distributed under this licence:\n\n", stdout);
    std::fwrite(text, 1, SizeofResource(nullptr, found), stdout);
    return 0;
}

/// Pick what is captured: the virtual display when there is one, so a crop
/// can never be a crop out of somebody's real screen. At startup, again once
/// the window has installed one, and again whenever the displays change under
/// the choice (RechooseCaptureDisplayIfStale). A session already streaming
/// keeps the display it opened on; the next one uses this.
void ChooseCaptureDisplay() {
    std::wstring chosen;
    const std::string configured = ToUtf8(solstream::VirtualDisplayDevice());
    for (const Display& display : EnumerateDisplays()) {
        if (!configured.empty() && display.device_name == configured) {
            chosen = ToWide(display.device_name);
            Log("[agent] capturing %s [%s]", display.device_name.c_str(),
                display.adapter.c_str());
            break;
        }
    }
    for (const Display& display : EnumerateDisplays()) {
        if (!chosen.empty()) {
            break;
        }
        // Ours only. This used to match "virtual" or "idd" anywhere in the
        // adapter name, which is every phone-as-monitor and remote-desktop
        // product's display too — and capturing one of those streams a screen
        // SolStream did not size, from a display it does not control. Better
        // the primary below, which at least says plainly what it is.
        const std::string& adapter = display.adapter;
        if (solstream::IsSolStreamDisplayDriver(ToWide(adapter))) {
            chosen = ToWide(display.device_name);
            Log("[agent] capturing %s [%s]", display.device_name.c_str(), adapter.c_str());
            break;
        }
    }
    if (chosen.empty()) {
        for (const Display& display : EnumerateDisplays()) {
            if (display.primary) {
                chosen = ToWide(display.device_name);
                Log("[agent] no virtual display; falling back to %s",
                    display.device_name.c_str());
                break;
            }
        }
    }

    std::lock_guard<std::mutex> lock(g_capture_mutex);
    g_capture_display = chosen;
}

/// Choose again when the displays have changed under the choice; see
/// capture_display.h. Every few seconds at most: it asks for every display.
/// Watcher thread only, which runs in every host, headless and session 0
/// included.
void RechooseCaptureDisplayIfStale() {
    static ULONGLONG checked_at = 0;
    const ULONGLONG now = GetTickCount64();
    if (checked_at != 0 && now - checked_at < 3000) {
        return;
    }
    checked_at = now;
    std::vector<solstream::PresentDisplay> present;
    for (const Display& display : EnumerateDisplays()) {
        solstream::PresentDisplay entry;
        entry.name = ToWide(display.device_name);
        entry.ours = solstream::IsSolStreamDisplayDriver(ToWide(display.adapter));
        present.push_back(entry);
    }
    const std::wstring current = CaptureDisplay();
    if (solstream::CaptureDisplayIsStale(current, present, solstream::VirtualDisplayDevice())) {
        Log("[agent] the displays changed under %s; choosing what to capture again",
            current.empty() ? "no capture display" : ToUtf8(current).c_str());
        ChooseCaptureDisplay();
    }
}

/// The setup or host window waiting on this elevated process, to be told how
/// the virtual display is getting on. Null when nobody is waiting.
HWND g_progress_window = nullptr;

void ReportDriverStep(solstream::DriverStep step) {
    if (!g_progress_window) {
        return;
    }
    static const UINT message = RegisterWindowMessageW(solstream::kSetupProgressMessage);
    // Downwards across integrity levels, which UIPI allows: this process is
    // elevated and the window is not.
    PostMessageW(g_progress_window, message, (WPARAM) step, 0);
}

/// The virtual display's line in the result the waiting window reads; see
/// WriteInstallResult. "ready-restart" when Windows said the install needs a
/// restart: carried as its own word, not guessed from what the notes say.
std::string DisplayResult(bool ok, bool already, bool restart, const std::string& note,
                          const std::string& error) {
    if (!ok) {
        return "failed " + error;
    }
    return std::string(restart ? "ready-restart " : "ready ")
         + (already ? "This PC already had the Virtual Display Driver, so SolStream set "
                      "it up for streaming.\n"
                    : "")
         + note;
}

/// Normal priority, however this copy was started: for the CPU, for the disk
/// and for memory.
///
/// A logon task registered before it said <Priority> runs its program at Task
/// Scheduler's default of 7, and that is three settings, not one: the below
/// normal priority class, low I/O priority and low memory priority. The class
/// decides who gets the CPU when a game on the PC wants it too, and every
/// application the Mac opens from here inherits it. The other two are what
/// SetPriorityClass leaves alone outside background mode, and they matter in
/// the same contention: the disk serves this process after everybody else,
/// and under a game's memory pressure the pages of capture, the encoder and
/// the audio are the first Windows takes away.
///
/// Each one only ever raised to normal: a host somebody started high on
/// purpose keeps what they gave it. Best effort throughout, and the log says
/// what was found and what became of it.
void RaiseToNormalPriority() {
    HANDLE self = GetCurrentProcess();

    const DWORD priority = GetPriorityClass(self);
    if (priority == BELOW_NORMAL_PRIORITY_CLASS || priority == IDLE_PRIORITY_CLASS) {
        if (SetPriorityClass(self, NORMAL_PRIORITY_CLASS)) {
            Log("[agent] started below normal CPU priority; raised to normal");
        } else {
            Log("[agent] started below normal CPU priority and could not raise it: %lu",
                (unsigned long) GetLastError());
        }
    }

    // The process's, which every thread started from here on takes, and this
    // thread's own, which it took from the process before this ran.
    MEMORY_PRIORITY_INFORMATION memory{};
    if (GetProcessInformation(self, ProcessMemoryPriority, &memory, sizeof(memory))
        && memory.MemoryPriority < MEMORY_PRIORITY_NORMAL) {
        const unsigned long found = memory.MemoryPriority;
        memory.MemoryPriority = MEMORY_PRIORITY_NORMAL;
        if (SetProcessInformation(self, ProcessMemoryPriority, &memory, sizeof(memory))) {
            SetThreadInformation(GetCurrentThread(), ThreadMemoryPriority, &memory,
                                 sizeof(memory));
            Log("[agent] started at memory priority %lu; raised to normal (%d)", found,
                MEMORY_PRIORITY_NORMAL);
        } else {
            Log("[agent] started at memory priority %lu and could not raise it: %lu",
                found, (unsigned long) GetLastError());
        }
    }

    // No Win32 call sets I/O priority outside background mode, so this is
    // ntdll's, asked for by name as audio.cpp asks for RtlGetVersion. Normal
    // and below need no privilege; only High would. The numbers are ntdll's
    // own: ProcessIoPriority, ThreadIoPriority, and IoPriorityNormal.
    using QueryProcessFn = LONG(NTAPI*)(HANDLE, ULONG, PVOID, ULONG, PULONG);
    using SetInformationFn = LONG(NTAPI*)(HANDLE, ULONG, PVOID, ULONG);
    constexpr ULONG kProcessIoPriority = 33;
    constexpr ULONG kThreadIoPriority = 22;
    constexpr ULONG kIoPriorityNormal = 2;
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    auto query = ntdll ? reinterpret_cast<QueryProcessFn>(reinterpret_cast<void*>(
                             GetProcAddress(ntdll, "NtQueryInformationProcess")))
                       : nullptr;
    auto set_process = ntdll ? reinterpret_cast<SetInformationFn>(reinterpret_cast<void*>(
                                   GetProcAddress(ntdll, "NtSetInformationProcess")))
                             : nullptr;
    auto set_thread = ntdll ? reinterpret_cast<SetInformationFn>(reinterpret_cast<void*>(
                                  GetProcAddress(ntdll, "NtSetInformationThread")))
                            : nullptr;
    ULONG io = kIoPriorityNormal;
    if (query && set_process && query(self, kProcessIoPriority, &io, sizeof(io), nullptr) >= 0
        && io < kIoPriorityNormal) {
        const unsigned long found = io;
        io = kIoPriorityNormal;
        const LONG status = set_process(self, kProcessIoPriority, &io, sizeof(io));
        if (status >= 0) {
            if (set_thread) {
                set_thread(GetCurrentThread(), kThreadIoPriority, &io, sizeof(io));
            }
            Log("[agent] started at I/O priority %lu; raised to normal (%lu)", found,
                (unsigned long) kIoPriorityNormal);
        } else {
            Log("[agent] started at I/O priority %lu and could not raise it: 0x%08lX", found,
                (unsigned long) status);
        }
    }
}

int wmain(int argc, wchar_t** argv) {
    ReleaseUnwantedConsole();
    // Everything outside main.cpp logs through the agent's file rather than
    // through a second one, and learns where that is here rather than by
    // declaring a function it has no way to reach.
    solstream::media::SetLogger([](const char* line) { Log("%s", line); });
    unsigned short port = kDefaultPort;
    // Loopback by default, where no token is asked for (see g_require_auth);
    // an installed host switches to every interface below, with the token
    // required.
    std::string bind_address = kLoopback;
    bool print_token = false;
    bool print_licenses = false;
    bool no_auth = false;
    bool install = false;
    bool uninstall = false;
    bool uninstall_now = false;
    bool configure_display = false;
    // --headless keeps the original behaviour: no window, log to stderr. Every
    // verification in this project is done over SSH, where there is no desktop
    // to put a window on.
    bool headless = false;
    bool start_hidden = false;
    bool install_driver = false;
    bool check_updates = false;
    bool download_update = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--verify-update-signature") {
            // Everything after it is its own: two paths and perhaps a key.
            // Answered here, before any of the machine is touched -- CI runs it
            // on a build that is not installed, where carrying on would open the
            // setup window and wait for somebody to close it.
            return solstream::update::VerifySignatureCommand(argc - i - 1, argv + i + 1);
        }
        if (arg == L"--check-updates") {
            check_updates = true;
            // Only as its modifier: on its own the word means nothing here.
            if (i + 1 < argc && std::wstring(argv[i + 1]) == L"--download") {
                download_update = true;
                ++i;
            }
        } else if (arg == L"--port" && i + 1 < argc) {
            port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--headless") {
            headless = true;
        } else if (arg == L"--install-display-driver") {
            install_driver = true;
        } else if (arg == L"--bind" && i + 1 < argc) {
            // Prefer a single address — a VPN interface such as Tailscale, whose
            // peers are already device-authenticated — over every interface.
            bind_address = ToUtf8(argv[i + 1]);
        } else if (arg == L"--listen-all") {
            bind_address = "0.0.0.0";
        } else if (arg == L"--background") {
            // Straight to the notification area, no window: how the logon
            // task starts it.
            start_hidden = true;
        } else if (arg == L"--print-token") {
            print_token = true;
        } else if (arg == L"--licenses") {
            print_licenses = true;
        } else if (arg == L"--no-auth") {
            no_auth = true;
        } else if (arg == L"--install") {
            install = true;
        } else if (arg == L"--uninstall") {
            uninstall = true;
        } else if (arg == L"--now" || arg == L"--quiet") {
            // Do it rather than ask about it. What Add/Remove Programs invokes
            // as its QuietUninstallString, and what the confirmation window
            // passes to the elevated half of itself.
            uninstall_now = true;
        } else if (arg == L"--configure-display") {
            configure_display = true;
        } else if (arg == L"--progress-window" && i + 1 < argc) {
            // Only a live window in this session: anything else on the switch is
            // ignored, and the worst a wrong one could do is receive a number.
            const HWND window = (HWND) (uintptr_t) std::wcstoull(argv[++i], nullptr, 10);
            DWORD session = 0, own = 0;
            DWORD pid = 0;
            if (window && IsWindow(window) && GetWindowThreadProcessId(window, &pid)
                && ProcessIdToSessionId(pid, &session)
                && ProcessIdToSessionId(GetCurrentProcessId(), &own) && session == own) {
                g_progress_window = window;
            }
        }
    }

    // Every DLL from System32 and nowhere else, for the elevated roles that run
    // from a folder this user's own programs can write to: the install the
    // updater starts from %LOCALAPPDATA%\SolStream\Updates and the one setup
    // starts from Downloads, and the uninstall that steps out to %TEMP%. Windows looks beside the executable first, so a DLL planted there
    // would run inside the elevated process the moment the prompt was approved.
    // CMakeLists.txt's /DEPENDENTLOADFLAG covers the imports resolved before
    // wmain; this covers everything loaded after it, including what system DLLs
    // load by bare name.
    //
    // Not for the host. The installed one runs from Program Files, which only an
    // administrator can write to, and its media path loads hardware encoders
    // whose own dependencies this has never been tried against. Nor, yet, for
    // the unelevated setup window: a DLL planted beside it runs as the user who
    // planted it, which gains nothing, and its Direct2D, DirectWrite, comctl32
    // and driver-install paths have not been tried under this restriction.
    if (install || uninstall || install_driver) {
        SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_SYSTEM32);
    }

    // Asks nothing of the machine, so it answers before anything is set up.
    if (print_licenses) {
        return PrintLicenses();
    }
    // One update check, said on the console: how the updater is tested by hand.
    // Honours SOLSTREAM_PRETEND_VERSION and SOLSTREAM_GITHUB_TOKEN; --download
    // also fetches and verifies the installer, and never runs it.
    if (check_updates) {
        return solstream::update::CheckCommand(download_update);
    }

    // Without this every coordinate we read or write is silently rescaled by
    // Windows' DPI virtualisation, and windows land in the wrong place on any
    // display that is not at 100%.
    //
    // Before any branch below, because setting process DPI awareness only
    // works before the first window exists -- and the setup and uninstall
    // windows are created on those branches.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    // Installing is the executable's own job. It used to be a PowerShell script,
    // which made the answer to "how do I install this" involve an execution
    // policy and a -Package path — for a program whose whole premise is that
    // none of this should be the user's problem.
    //
    // --install always DOES the install; it is what the setup window's elevated
    // half runs, and it never shows a window of its own. --uninstall ASKS first,
    // in a window, because it is what Add/Remove Programs invokes; --uninstall
    // --now does it.
    if (uninstall) {
        // Nothing can delete the directory it is running from, so step outside
        // before anything else happens. Both halves below then run from the
        // copy, and Program Files can go. Without this the uninstall leaves
        // SolStream.exe behind and reports failure — from the one entry point
        // every user would actually use.
        if (solstream::RunningInstalled()) {
            std::string error;
            const std::wstring pass = uninstall_now ? L"--uninstall --now"
                                                    : L"--uninstall";
            if (!solstream::RelaunchFromTemp(pass, error)) {
                // stderr is /dev/null in the case this matters -- an uninstall
                // started from Add/Remove Programs has no console at all -- so
                // the reason has to go where somebody can find it.
                solstream::WriteInstallResult(false, error);
                std::fprintf(stderr, "%s\n", error.c_str());
                return 1;
            }
            return 0;
        }
        if (!uninstall_now) {
            if (solstream::ShowHostWindow(solstream::WindowMode::Uninstall)) {
                return solstream::RunHostWindowLoop();
            }
            // No desktop to ask on — over SSH, or in session 0. Carry on and
            // remove it, which is what somebody typing this there meant.
        }
        if (!solstream::IsElevated()) {
            std::string error;
            if (!solstream::RelaunchElevated(L"--uninstall --now", error)) {
                std::fprintf(stderr, "%s\n", error.c_str());
                return 1;
            }
            return 0;
        }
        std::string error;
        std::string left;
        const bool ok = solstream::UninstallSelf(error, left);
        // What of the virtual display stayed goes back as the warning on an
        // uninstall that otherwise went through, for the window to say.
        solstream::WriteInstallResult(ok, ok ? left : error);
        if (!ok) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        if (!left.empty()) {
            std::fprintf(stdout, "%s\n", left.c_str());
        }
        std::fputs("SolStream has been removed. Your pairing token and "
                   "settings are kept in %LOCALAPPDATA%\\SolStream.\n", stdout);
        return 0;
    }

    if (install) {
        const solstream::InstallOptions options =
            solstream::OptionsFromArguments(argc, argv);
        if (!solstream::IsElevated()) {
            // Ask once, visibly. This is the moment the user agrees to a program
            // writing to Program Files, opening ports and registering a logon
            // task; doing it behind an invisible prompt would be doing it behind
            // their back.
            std::string error;
            if (!solstream::RelaunchElevated(
                    L"--install" + solstream::OptionArguments(options), error,
                    options.display_driver)) {
                std::fprintf(stderr, "%s\n", error.c_str());
                return 1;
            }
            return 0;
        }
        // Hold this very file, sharing read access only, until it has been
        // copied: InstallSelf copies it into Program Files by path. Started by
        // the updater, this is the other half of its hold -- the updater keeps
        // the download open across this process starting, and this keeps it
        // open from here to the copy, so nothing can rename it and put other
        // bytes at that path in between. From the setup window it costs nothing.
        HANDLE self = INVALID_HANDLE_VALUE;
        DWORD hold_error = ERROR_FILENAME_EXCED_RANGE;
        {
            wchar_t path[MAX_PATH] = {0};
            const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
            if (length > 0 && length < MAX_PATH) {
                self = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                                   OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
                hold_error = GetLastError();
            }
        }
        // Without the hold, the copy below would be by a path nothing protects
        // once InstallSelf has stopped the old host (and with it the updater's
        // hold). So no hold, no install -- before anything has been changed.
        if (self == INVALID_HANDLE_VALUE) {
            const std::string error = "SolStream couldn't hold its own installer file "
                                      "(error " + std::to_string(hold_error)
                                    + "), so nothing was changed.";
            solstream::WriteInstallResult(false, error);
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        // The virtual display before SolStream itself: InstallSelf ends by
        // starting the host, and the host chooses what to capture as it
        // starts. Done the other way round, it would pick the main display and
        // keep it until the next logon. A display that cannot be set up is not
        // a failed install -- SolStream streams the main display meanwhile --
        // so it is reported beside the install's answer, not instead of it.
        std::string display;
        if (options.display_driver) {
            bool already = false, restart = false;
            std::string note, driver_error;
            const bool ready = solstream::InstallDisplayDriver(
                ReportDriverStep, g_progress_window, already, restart, note, driver_error);
            ReportDriverStep(solstream::DriverStep::Done);
            display = DisplayResult(ready, already, restart, note, driver_error);
            for (const std::string& line : SplitLines(ready ? note : driver_error)) {
                Log("[display] %s", line.c_str());
            }
        }
        std::string error;
        const bool ok = solstream::InstallSelf(options, error);
        CloseHandle(self);
        // The window that asked for this is in another process and cannot see a
        // return code, so the reason goes in a file it knows to read.
        solstream::WriteInstallResult(ok, error, display);
        if (!ok) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        // On a true return `error` is the install's warning: it stands, but it
        // may not be running, or may not start at logon, and this sentence
        // must not say otherwise.
        if (!error.empty()) {
            std::fprintf(stdout, "%s\n", error.c_str());
            return 0;
        }
        std::fputs(options.start_at_logon
                       ? "SolStream is installed and running. It will start again "
                         "when you log in.\n"
                       : "SolStream is installed and running.\n",
                   stdout);
        return 0;
    }

    if (install_driver) {
        // What the host window's "Set up" runs, elevated: the same steps as
        // setup's tick box, for a PC that was installed without them.
        if (!solstream::IsElevated()) {
            std::string error;
            if (!solstream::RelaunchElevated(L"--install-display-driver", error, true)) {
                std::fprintf(stderr, "%s\n", error.c_str());
                return 1;
            }
            std::string display;
            solstream::ReadInstallResult(error, &display);
            std::fprintf(stdout, "%s\n", display.c_str());
            return display.rfind("ready", 0) == 0 ? 0 : 1;
        }
        bool already = false, restart = false;
        std::string note, error;
        const bool ready = solstream::InstallDisplayDriver(ReportDriverStep, g_progress_window,
                                                           already, restart, note, error);
        solstream::WriteInstallResult(ready, ready ? std::string() : error,
                                      DisplayResult(ready, already, restart, note, error));
        std::fprintf(ready ? stdout : stderr, "%s\n", (ready ? note : error).c_str());
        return ready ? 0 : 1;
    }

    if (configure_display) {
        std::string error;
        // A driver already here, set up for streaming: out of the box it offers
        // a mode list that matches no Mac, scales wrong, and advertises HDR —
        // which is what made streamed content arrive as a black rectangle with
        // its chrome drawn correctly around it.
        std::string note;
        if (!solstream::ConfigureVirtualDisplay(solstream::kDefaultCanvasWidth,
                                                solstream::kDefaultCanvasHeight,
                                                solstream::kDefaultScalePercent,
                                                note, error)) {
            std::fprintf(stderr, "%s\n%s\n", note.c_str(), error.c_str());
            return 1;
        }
        std::fprintf(stdout, "%s\n", note.c_str());
        return 0;
    }

    // Nothing was asked for, and this copy is not the installed one: somebody
    // has just downloaded the file and run it. That used to start the agent in
    // place and report an error as the entire first impression, with the actual
    // install reachable only by knowing to type --install at a command line.
    if (argc == 1 && !solstream::RunningInstalled()) {
        if (solstream::ShowHostWindow(solstream::WindowMode::Setup)) {
            return solstream::RunHostWindowLoop();
        }
        std::fputs("SolStream is not installed. Run it on the desktop to set it "
                   "up, or pass --install here.\n", stderr);
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

    // Below here this process intends to BE the agent, and everything that only
    // wanted to ask it something has already answered and gone. Putting the
    // one-instance check any earlier makes `SolStream.exe --print-token` on an
    // installed machine raise the window and exit 0 having printed nothing,
    // which is the kind of regression a script discovers and a person does not.
    //
    // One window, one agent: the shortcuts point at this executable with no
    // arguments, and a second copy would fight the first for the port and lose,
    // so a shortcut press on a machine already running SolStream means "show me
    // the window", which is what every program with a shortcut does.
    //
    // A named mutex, for every copy, rather than looking for a window and only
    // from the installed one. Two hosts once started together at logon — the
    // installed task with --listen-all and a development copy with --bind — and
    // the window check could not have caught that: neither had a window yet.
    // Both went on to configure the virtual display, cycling it under each
    // other, and the loser then died on bind with 10013 and said nothing anyone
    // read. Taken here, before any of that, so the second copy costs nothing.
    // Local\ is this logon session, which is also the scope of the window and
    // the desktop being streamed; another user's session is its own host. The
    // handle is never closed: holding it is the point, and the process exiting
    // is what lets go of it.
    {
        constexpr wchar_t kInstanceName[] = L"Local\\SolStreamAgentHost";
        HANDLE instance = CreateMutexW(nullptr, FALSE, kInstanceName);
        const DWORD created = GetLastError();
        // Access denied is also "somebody has it": an elevated copy's mutex
        // carries a DACL an unelevated one cannot open.
        if ((instance && created == ERROR_ALREADY_EXISTS)
            || (!instance && created == ERROR_ACCESS_DENIED)) {
            // Let go first: holding the name while this copy waits below would
            // make a third launch believe in a host that had already gone, and
            // would keep this one from ever seeing the name come free.
            if (instance) {
                CloseHandle(instance);
                instance = nullptr;
            }
            bool focused = solstream::FocusExistingHostWindow();
            // The other copy may still be starting. It takes this mutex before
            // anything else and makes its window only once it is listening and
            // the virtual display is set up, which takes seconds -- more when
            // the display has to be cycled. "Open SolStream" at the end of setup
            // lands in exactly that gap, as can a shortcut pressed just after
            // logon: there was no window to bring forward, this copy left, and
            // the first one went on to start in the tray, so the press did
            // nothing anybody could see. So wait for the window, unless this
            // copy was itself started for the tray and has nothing to show.
            //
            // Or it may be on its way out. Quit in the tray destroys the window
            // at once but lets go of this name only when the process ends,
            // after the stream has stopped and the windows it held have been
            // given back. A press in that gap waited the whole time for a
            // window that was never coming and then left as well, and nothing
            // was running. So each pass also asks for the name again: free
            // means the other copy has gone, and this one is the host now.
            if (!focused && !start_hidden) {
                for (int waited = 0; waited < 20000 && !instance; waited += 250) {
                    Sleep(250);
                    focused = solstream::FocusExistingHostWindow();
                    if (focused) {
                        break;
                    }
                    HANDLE retry = CreateMutexW(nullptr, FALSE, kInstanceName);
                    const DWORD retried = GetLastError();
                    if (retry && retried != ERROR_ALREADY_EXISTS) {
                        instance = retry;
                    } else if (retry) {
                        CloseHandle(retry);
                    }
                }
            }
            if (!instance) {
                Log("[agent] another SolStream host is already running in this "
                    "session%s; this copy is exiting",
                    focused ? " (its window was brought forward)" : "");
                return 0;
            }
            Log("[agent] the SolStream host that was running here has exited; "
                "this copy is starting in its place");
        }
        if (!instance) {
            // Not worth refusing to start over. The port is still exclusive, so
            // the worst case is the old one: a second copy that fails to bind.
            Log("[agent] could not create the single-instance mutex: %lu",
                (unsigned long) created);
        }
    }

    // Normal priority, however this copy was started, and before anything that
    // captures, encodes or starts an application: see RaiseToNormalPriority.
    RaiseToNormalPriority();

    // An installed SolStream exists to serve a Mac, so it listens like one
    // unless told otherwise. Off loopback the token is still required; the
    // window shows it. That is the lock, not the address.
    if (solstream::RunningInstalled() && bind_address == kLoopback) {
        bind_address = "0.0.0.0";
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

    // Where the media key schedule's replay counter left off last time this
    // machine ran. Read once here rather than per session; the write happens at
    // each bump, in the media handshake.
    g_media_count = LoadMediaCount();

    InitializeCriticalSection(&g_lock_cs);
    InitializeCriticalSection(&g_owed_cs);
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
    // bind a port that is already bound — it does not merely permit reusing a
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
    // the interface is seconds away from existing — so the agent would exit and
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
            // 10013 is what SO_EXCLUSIVEADDRUSE answers when the port is taken,
            // not a permissions problem, and a bare number sent the last person
            // to see it looking at the firewall.
            if (error == WSAEADDRINUSE || error == WSAEACCES) {
                Log("[agent] another program holds port %u -- probably another "
                    "SolStream, perhaps in another user's session. Stop it and "
                    "start this one again.", port);
            }
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
    // Checked before the media path starts, because it decides what is captured.
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
            Log("[agent] the window's Set up button installs one, as does");
            Log("[agent] SolStream.exe --install-display-driver.");
        } else {
            for (const auto& display : virtual_displays) {
                Log("[agent] virtual display: %s (%s)",
                    ToUtf8(display.friendly_name).c_str(),
                    display.running           ? "running"
                    : display.restart_pending ? "starts when this PC restarts"
                                              : "present but not started");
            }
        }
    }

    // Make the virtual display fit to stream, before deciding what to capture —
    // this is what attaches it, so doing it afterwards would pick from a list it
    // was not on yet.
    //
    // The privileged half of this (teaching the driver its mode list) needs
    // rights the agent does not have and will simply be noted as undone; the
    // half that matters most does not. Turning "Use HDR" off is a per-display
    // toggle any user can set, and leaving it on is what made streamed content
    // arrive as a black rectangle inside correctly drawn window chrome — worst
    // in terminals and browsers, invisible in anything pure black-on-white.
    if (solstream::HasVirtualDisplay()) {
        std::string note;
        std::string display_error;
        const bool ready = solstream::ConfigureVirtualDisplay(
            solstream::kDefaultCanvasWidth, solstream::kDefaultCanvasHeight,
            solstream::kDefaultScalePercent, note, display_error);
        for (const std::string& line : SplitLines(note)) {
            Log("[display] %s", line.c_str());
        }
        if (!ready) {
            Log("[display] %s", display_error.c_str());
        }
    }

    ChooseCaptureDisplay();
    // The window's "Set up" installs a virtual display into a host that is
    // already running, which then has to start capturing it.
    solstream::SetDisplayReadyHandler(ChooseCaptureDisplay);

    for (const Display& display : EnumerateDisplays()) {
        Log("[agent]   display %s %ldx%ld at (%ld,%ld)%s",
            display.device_name.c_str(),
            display.bounds.right - display.bounds.left,
            display.bounds.bottom - display.bounds.top,
            display.bounds.left, display.bounds.top,
            display.primary ? " [primary]" : "");
    }

    // From here, not from the first client. Binding the agent's socket is
    // itself what makes Windows ask whether it may accept connections, and that
    // prompt arrives long before any Mac has connected — onto the capture
    // display, which no monitor shows. A watcher that only runs while someone
    // is streaming would never see the one dialog most worth carrying back.
    // Before the watcher, whose rescue would otherwise carry these windows off
    // the capture display at whatever size the move gave them, and before any
    // Mac can connect and claim them as they are.
    RestoreWindowsLeftBehind();
    StartWatcher();
    StartDiscoveryResponder();

    // The accept loop moves off the main thread so the window can own it.
    //
    // A Win32 message loop has to run on the thread that created the window, and
    // this loop blocks in accept() indefinitely — so one of the two has to be
    // somewhere else, and it is easier to reason about a server thread than
    // about a UI that only pumps between connections.
    std::thread server([listener]() {
        // Consecutive failures, and when one was last written down. An accept
        // that fails does so immediately, and the errors that persist —
        // WSAENOBUFS, WSAEMFILE when the process is out of handles — failed
        // again on the very next call, so a bare `continue` spun this thread at
        // the speed of the system call and wrote a log line per lap until the
        // megabyte cap rotated away everything worth reading.
        unsigned failures = 0;
        unsigned long long last_complaint = 0;
        unsigned suppressed = 0;
        for (;;) {
            SOCKET client = accept(listener, nullptr, nullptr);
            if (client == INVALID_SOCKET) {
                const int error = WSAGetLastError();
                ++failures;
                const unsigned long long now = GetTickCount64();
                if (last_complaint == 0 || now - last_complaint >= 10000) {
                    Log("[agent] accept failed: %d (%u more since the last report)",
                        error, suppressed);
                    last_complaint = now;
                    suppressed = 0;
                } else {
                    ++suppressed;
                }
                // A one-off (a client that reset before it was accepted) costs
                // ten milliseconds; a persistent one settles at a second a lap.
                Sleep(failures >= 7 ? 1000 : 10u << (failures - 1));
                continue;
            }
            failures = 0;

            // One Mac at a time, said out loud rather than by hanging.
            //
            // There is one capture, one encoder and one media socket, so two
            // Macs streaming from one PC is not something this can support
            // however the socket is written. What it CAN do is say so.
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
            //
            // Keyed on clients that have PROVED the token, not on open sockets: a
            // Mac connecting afresh treats `busy` as final, so counting any
            // accepted socket let a port scanner or a single stray connect()
            // lock the paired Mac out.
            // An update waiting on its permission prompt, or already running:
            // the installer is about to stop this host, so a Mac let in now
            // would have its stream cut. Closed without a word, like the
            // unauthenticated case below, so the Mac's reconnect backoff brings
            // it back -- to the new host, once it is up. Not an auth refusal:
            // the Mac forgets its token on one of those.
            if (solstream::update::InstallStarting()) {
                Log("[agent] turned a client away: an update is being installed");
                closesocket(client);
                continue;
            }
            if (g_clients_authenticated.load() > 0) {
                // The session may be this very Mac's, left behind by a network
                // change that no FIN ever reported (session_takeover.h). Such
                // a Mac is offered the chance to say so, on a thread of its
                // own: the answer takes a round trip, and this loop must go on
                // accepting meanwhile.
                if (g_require_auth && !g_token.empty()
                    && g_takeover_listeners.load() < kMaxTakeoverListeners) {
                    g_takeover_listeners.fetch_add(1);
                    Log("[agent] a client knocked while one is connected; offering a takeover");
                    std::thread([client]() { OfferTakeover(client); }).detach();
                    continue;
                }
                Log("[agent] refused a second client: one is already connected");
                SendLine(client, BusyLine(AnotherMacMessage(), std::string()));
                closesocket(client);
                continue;
            }

            // Somebody holds the socket but has proved nothing: a Mac waiting on
            // the token prompt, or a stranger sitting on the port. There is
            // still exactly one of everything below this line — one push
            // channel, one cursor watcher, one encrypted channel — so this
            // connection cannot be served beside that one either.
            //
            // Closed without a word rather than refused with `busy`, and the
            // difference is the whole point: an unexplained close is what the
            // Mac's reconnect backoff is for, so it comes back in a couple of
            // seconds and goes on coming back. What it comes back to is a slot
            // the pre-auth timeout in ServeClient frees when the holder falls
            // quiet, and kPreAuthDeadlineMs frees even when the holder does not
            // — before that deadline existed, a holder that kept talking without
            // ever authenticating kept this client out indefinitely. Saying
            // `busy` here would be saying something untrue —
            // nobody is streaming — to a client that would believe it for good.
            //
            // Claimed rather than checked: a takeover admits clients too, from
            // its own thread, and the two must not both get the slot.
            if (!ClaimClientSlot()) {
                Log("[agent] closed a client on arrival: the socket is held by "
                    "one that has not authenticated yet");
                closesocket(client);
                continue;
            }

            Log("[agent] client connected");
            std::thread([client]() { ServeAndRetire(client); }).detach();
        }
    });
    server.detach();

    if (headless) {
        Log("[agent] headless: no window, Ctrl+C to stop");
        for (;;) {
            Sleep(60000);
        }
    }

    // What became of an update this PC started. When this copy is the version
    // it was installing, somebody pressed Install a moment ago, watched that
    // window close, and is waiting for SolStream to come back -- so the window
    // opens to say it has, though the logon task asked for the tray. Read only
    // by the installed copy, the only one an install replaces, and after the
    // single-instance check, so a second copy that exits cannot use it up.
    if (solstream::RunningInstalled()) {
        const solstream::update::InstallNote note = solstream::update::TakeInstallNote();
        if (note.kind != solstream::update::InstallNote::Kind::None) {
            solstream::SayInstallOutcome(
                note.kind == solstream::update::InstallNote::Kind::Installed, note.version);
            if (note.recent) {
                start_hidden = false;
            }
        }
    }

    if (!solstream::ShowHostWindow(solstream::WindowMode::Host, start_hidden)) {
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
            // Listening on everything means the bind address says nothing about
            // where to look, so find an address that does. Re-read every tick
            // rather than cached: a laptop that joins a network, or a VPN that
            // comes up, changes the answer while this window is open.
            status.address = bind_address == "0.0.0.0"
                                 ? ToWide(BestLocalAddress())
                                 : ToWide(bind_address);
            status.pairing_token = ToWide(g_token);
            status.tailscale_address = solstream::TailscaleAddress();
            status.agent_listening = true;
            status.connected_clients = g_clients_authenticated.load();

            // Ready to stream, not currently streaming. The two used to be one
            // fact because a Sunshine that was not running was the only way
            // this could fail; now the media path only exists while a Mac is
            // connected, and a host with nobody connected is fine.
#ifdef SOLSTREAM_MEDIA
            status.streaming_ready = solstream::media::Capture::Supported();
            status.streaming_detail =
                solstream::media::MediaSession::Instance().Running()
                    ? L"streaming" : L"ready";
            if (!status.streaming_ready) {
                status.streaming_detail =
                    L"This PC's Windows is too old for the capture SolStream uses.";
                // The version that added capturing one window or one display
                // by its handle, which is how media/capture.cpp starts every
                // capture. The calls that came later are tried and survived.
                status.streaming_why =
                    L"SolStream streams with Windows' own window capture, which "
                    L"needs Windows 10 version 1903 or later.";
            }
#else
            status.streaming_ready = false;
            status.streaming_detail = L"This build has no media path.";
            status.streaming_why =
                L"It was built without the capture and encoding SolStream streams with.";
#endif

            status.virtual_display = solstream::HasVirtualDisplayCached();
            // Asked only when there is no display, and at most every ten
            // seconds: a device scan once a second would cost more than the
            // answer is worth.
            static ULONGLONG off_checked = 0;
            static bool off = false;
            static bool failing = false;
            static bool restart_pending = false;
            if (status.virtual_display) {
                off = false;
                failing = false;
                restart_pending = false;
            } else if (off_checked == 0 || GetTickCount64() - off_checked > 10000) {
                const solstream::DriverState state = solstream::CurrentDriverState();
                off = state == solstream::DriverState::Off;
                failing = state == solstream::DriverState::Failing;
                restart_pending = state == solstream::DriverState::RestartPending;
                off_checked = GetTickCount64();
            }
            status.driver_off = off;
            status.driver_failing = failing;
            status.driver_restart_pending = restart_pending;
            status.display_detail = status.virtual_display
                ? (CaptureDisplay().empty() ? L"ready" : CaptureDisplay())
                : L"not installed";

            solstream::UpdateHostStatus(status);
            Sleep(1000);
        }
    });
    status.detach();

    // Updates: a minute after start, then daily, on their own thread. Only
    // here, with a window -- an update is installed when somebody says so, and
    // headless or in session 0 there is nobody to say it and nowhere to ask.
    // "Streaming" is a Mac that has proved the token, the same count the window
    // shows; a scheduled check waits for it to go.
    //
    // And only for the installed copy. The installer replaces Program Files and
    // stops what runs from there; offered to a copy started from anywhere else
    // -- a development build with --bind -- it would install the update, leave
    // this copy running, and the new host would exit on this one's mutex.
    if (solstream::RunningInstalled()) {
        solstream::update::SchedulerHooks hooks;
        hooks.streaming_clients = [] { return g_clients_authenticated.load(); };
        hooks.finished = [](const solstream::update::CheckResult& result, bool asked) {
            solstream::UpdateCheckFinished(result, asked);
        };
        solstream::update::StartScheduler(hooks);
    }

    // Installed here because an out-of-context hook delivers its callbacks on
    // the thread that set it, through that thread's message loop — and this is
    // the thread with one. Set from the watcher instead, the callbacks would
    // have nowhere to arrive and the picker would go on showing a stale list.
    SeedListedWindows();
    HWINEVENTHOOK window_set_hook = SetWinEventHook(
        EVENT_OBJECT_CREATE, EVENT_OBJECT_HIDE, nullptr, WindowSetChanged, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    HWINEVENTHOOK name_hook = SetWinEventHook(
        EVENT_OBJECT_NAMECHANGE, EVENT_OBJECT_NAMECHANGE, nullptr, WindowSetChanged, 0, 0,
        WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    if (!window_set_hook) {
        Log("[agent] could not watch for window changes; the Mac's list will "
            "only refresh when it reconnects");
    }

    const int code = solstream::RunHostWindowLoop();
    if (name_hook) { UnhookWinEvent(name_hook); }
    if (window_set_hook) { UnhookWinEvent(window_set_hook); }
    // Closing the window takes the host down with it. A capture still holding
    // the display after SolStream is gone is one
    // nobody can see to stop.
    //
    // Stopped HERE, once, and then out through ExitProcess rather than a return.
    // Returning from wmain runs static destructors while the detached server
    // and client threads are still alive, and one of those is
    // MediaSession::~MediaSession calling Stop() — which could land while a
    // client thread, seeing its socket go, was inside Stop() too. Two threads
    // joining the same std::thread is std::terminate, which is a crash dialog
    // on the way out of a program the user had just closed. Stop is serialised
    // inside MediaSession as well; ExitProcess means the destructor never gets
    // the chance to be the second caller at all.
#ifdef SOLSTREAM_MEDIA
    solstream::media::MediaSession::Instance().Stop();
#endif
    // And give back every resize border the session took. A client thread
    // does this when its Mac goes away, but ExitProcess ends that thread
    // wherever it is, and a window left unresizable outlives the host.
    UnlockAll();
    ExitProcess((UINT) code);
}
