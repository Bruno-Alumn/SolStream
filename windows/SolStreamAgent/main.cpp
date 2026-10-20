// SolStream Agent ΓÇö the Windows half of single-application streaming.
//
// It does one job: make a chosen application's window sit at a known,
// non-overlapping rectangle on a chosen display, and tell the Mac where it is.
// The Mac then crops that rectangle out of the single SMT/1 stream and
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

#include "display_setup.h"
#include "host_window.h"
#include "installer.h"
#include "ports.h"

// The media path is MSVC-only: Windows.Graphics.Capture and Media Foundation
// both arrive through C++/WinRT and the Windows SDK, neither of which mingw
// has. The cross-compiled build is a development convenience; what ships is
// built on Windows.
#include "media/log.h"
#ifdef SOLSTREAM_MEDIA
#include "media/capture.h"
#include "media/channel.h"
#include "media/session.h"
#endif
#include "vdd.h"

namespace {

constexpr unsigned short kDefaultPort = solstream::kDefaultPort;

// By default this socket is bound to loopback only and reached through an SSH
// tunnel; anywhere else a token is required. --listen-all is opt-in and warns.
constexpr const char* kLoopback = "127.0.0.1";
// 2 since auth v2: the token is proved rather than sent. A v1 host and a v2
// Mac cannot interoperate, and deliberately so -- see the client's refusal.
constexpr int kProtocolVersion = 2;

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

/// The display SolStream captures. Resolved at startup to the virtual one when
/// there is one, because a crop taken from a real monitor is a crop out of
/// somebody's actual screen.
std::wstring g_capture_display;
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

// ΓöÇΓöÇ Logging ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

/// Where the running agent leaves a record of itself.
///
/// It did not used to leave one. Log() wrote to stderr, and an installed agent
/// starts from a scheduled task with no console attached to write it to — so on
/// every machine that was not a development box, the program that had just
/// failed to stream had said exactly nothing about why. Beside the token, which
/// is where this program's other state already lives.
std::wstring AgentLogPath() {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\solstream.log";
}

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
    static const std::wstring path = AgentLogPath();
    if (path.empty()) {
        return;
    }
    // SERIALISED, AND SHARED WITH OTHER WRITERS. Nine threads log through here --
    // the watcher, the cursor watcher, the client thread, the capture, the
    // sender, the receive loop, the audio thread, the discovery responder and
    // the status thread -- and the share mode was FILE_SHARE_READ, which forbids
    // a second writer. So whenever two of them logged at once the second
    // CreateFileW failed with a sharing violation and its line went nowhere:
    // silently, with no error checked, on the one diagnostic this program has on
    // a machine with no console. The rotation was worse -- MoveFileW cannot
    // rename a file another handle has open without FILE_SHARE_DELETE, so a busy
    // log simply grew past its cap for ever. The mutex is what makes the
    // size-check-then-rotate sequence atomic; the wider share mode is what stops
    // an external tail(1) or the other log file from breaking either.
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

// ΓöÇΓöÇ Text ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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
/// heuristic was 172.x.x.x — a Hyper-V switch that no Mac anywhere can
/// reach, printed under "Address" as though it were the answer.
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
    // put the pairing PIN, and anything else this program asks a human at the PC
    // to confirm, inside the video feed of the client doing the asking, with the
    // clicks to match. The confirmation is only worth anything if it happens
    // somewhere the remote side cannot reach.
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
    // dialogs that IsUserWindow filters out of the reported list ΓÇö but only if
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
    // the Z-order. Report whichever covers the most of the tile ΓÇö the first one
    // found is not necessarily the one a user would blame.
    //
    // The last entry is this window itself ONLY when the block at the top of
    // this function appended it, and that block has a test the reported list
    // does not: CanPaintOver. A window that fails it ΓÇö any window built on
    // UpdateLayeredWindow, which is a great many of them ΓÇö is still a user
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
/// Bumped and persisted on every media session. It is in the key-schedule
/// transcript so that two sessions cannot derive the same keys even on a machine
/// whose RNG is repeating itself after an image restore -- the one failure that
/// would otherwise be silent and total.
///
/// "Persisted" was the load-bearing half of that sentence and nothing did it:
/// the counter lived only in this variable, so it restarted at zero with the
/// process. An image restore takes the agent down with it, which is precisely
/// the case the counter exists for -- restore the same image twice, get the same
/// RNG stream, and the first media session of each run derived identical keys.
/// It is now read at startup and written on every bump, beside the token.
unsigned long long g_media_count = 0;

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

/// Where the media session counter lives. Beside the token, because it is the
/// same kind of thing: state this machine must remember across restarts for the
/// key schedule to mean anything.
std::wstring MediaCountPath() {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\media.count";
}

/// The counter as it stood when this machine last opened a media session.
///
/// A missing or unreadable file reads as zero, which is where an agent that has
/// never streamed starts anyway. That is the honest answer rather than a safe
/// one -- if the file cannot be read the counter repeats, exactly as it did
/// before this existed -- but it is not a reason to refuse to stream.
unsigned long long LoadMediaCount() {
    const std::wstring path = MediaCountPath();
    if (path.empty()) {
        return 0;
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return 0;
    }
    char buffer[32] = {};
    DWORD read = 0;
    const bool ok = ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr) && read > 0;
    CloseHandle(file);
    if (!ok) {
        return 0;
    }
    return std::strtoull(buffer, nullptr, 10);
}

/// Written before the keys derived from it are used, not after: a crash between
/// deriving and writing must leave the counter ahead of what was used, never
/// behind it. Ahead costs a skipped number; behind hands the next session the
/// same transcript.
void SaveMediaCount(unsigned long long count) {
    const std::wstring path = MediaCountPath();
    if (path.empty()) {
        return;
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    char text[32] = {};
    const int written = std::snprintf(text, sizeof(text), "%llu", count);
    if (written > 0) {
        DWORD put = 0;
        WriteFile(file, text, (DWORD) written, &put, nullptr);
    }
    CloseHandle(file);
}

/// Constant-time compare, so a wrong token cannot be found a character at a time
/// by timing the reply.
/// `count` random bytes as lowercase hex.
std::string RandomHex(size_t count) {
    std::vector<unsigned char> bytes(count);
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes.data(), (ULONG) count,
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        return {};
    }
    static const char* hex = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);
    for (unsigned char byte : bytes) {
        out.push_back(hex[byte >> 4]);
        out.push_back(hex[byte & 0x0F]);
    }
    return out;
}

std::vector<unsigned char> FromHex(const std::string& hex) {
    std::vector<unsigned char> out;
    if (hex.size() % 2 != 0) {
        return out;
    }
    for (size_t i = 0; i < hex.size(); i += 2) {
        int high = -1, low = -1;
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') { return c - '0'; }
            if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
            if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
            return -1;
        };
        high = nibble(hex[i]);
        low = nibble(hex[i + 1]);
        if (high < 0 || low < 0) {
            return {};
        }
        out.push_back((unsigned char) ((high << 4) | low));
    }
    return out;
}

std::vector<unsigned char> HmacSha256(const std::vector<unsigned char>& key,
                                      const std::vector<unsigned char>& data) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG))) {
        return {};
    }
    std::vector<unsigned char> out(32);
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, (PUCHAR) key.data(),
                                              (ULONG) key.size(), (PUCHAR) data.data(),
                                              (ULONG) data.size(), out.data(), 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok ? out : std::vector<unsigned char>{};
}

/// Auth v2: the Mac proves it holds the token instead of sending it.
///
/// proof = HMAC-SHA256(tokenBytes, "SolStream agent auth v2" || challenge || cnonce)
///
/// The challenge is fresh per connection, so a recorded proof is worth nothing
/// on the next one; the client's own nonce is in there because the same values
/// seed the media key schedule later and neither side should be able to fix all
/// of that input by itself.
bool ProofMatches(const std::string& challengeHex, const std::string& cnonceHex,
                  const std::string& proofHex) {
    const std::vector<unsigned char> challenge = FromHex(challengeHex);
    const std::vector<unsigned char> cnonce = FromHex(cnonceHex);
    const std::vector<unsigned char> proof = FromHex(proofHex);
    const std::vector<unsigned char> key = FromHex(g_token);
    if (challenge.size() != 32 || cnonce.size() != 32 || proof.size() != 32
        || key.empty()) {
        return false;
    }
    static const char kLabel[] = "SolStream agent auth v2";
    std::vector<unsigned char> message(kLabel, kLabel + sizeof(kLabel) - 1);
    message.insert(message.end(), challenge.begin(), challenge.end());
    message.insert(message.end(), cnonce.begin(), cnonce.end());

    const std::vector<unsigned char> expected = HmacSha256(key, message);
    if (expected.size() != 32) {
        return false;
    }
    unsigned char difference = 0;
    for (size_t i = 0; i < 32; ++i) {
        difference |= (unsigned char) (expected[i] ^ proof[i]);
    }
    return difference == 0;
}

// ── SMT/1 key schedule ───────────────────────────────────────────────────────
//
// Pinned by the frozen cross-language vector in spike/smt-vectors: if any of
// this drifts, that vector stops matching and says so before a socket is
// involved. See docs/transport-smt1.md for why each input is there.

std::vector<unsigned char> Sha256(const std::vector<unsigned char>& data) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, 0))) {
        return {};
    }
    std::vector<unsigned char> out(32);
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, nullptr, 0, (PUCHAR) data.data(),
                                              (ULONG) data.size(), out.data(), 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok ? out : std::vector<unsigned char>{};
}

/// RFC 5869. Extract is one HMAC; expand is the T(n) chain. Written out rather
/// than using BCRYPT_HKDF_ALGORITHM because when two languages disagree, an
/// extract and an expand you can read are far easier to bisect than one opaque
/// call -- and they did have to be bisected once already.
std::vector<unsigned char> HkdfExpand(const std::vector<unsigned char>& prk,
                                      const std::vector<unsigned char>& info,
                                      size_t length) {
    std::vector<unsigned char> out, previous;
    unsigned char counter = 1;
    while (out.size() < length) {
        std::vector<unsigned char> input = previous;
        input.insert(input.end(), info.begin(), info.end());
        input.push_back(counter++);
        previous = HmacSha256(prk, input);
        if (previous.empty()) {
            return {};
        }
        out.insert(out.end(), previous.begin(), previous.end());
    }
    out.resize(length);
    return out;
}

/// A fresh P-256 key pair. `publicPoint` comes back as 0x04||X||Y, 65 bytes --
/// the uncompressed form the wire carries, which is BCrypt's blob with its
/// 8-byte header swapped for the 0x04 tag.
BCRYPT_KEY_HANDLE NewEcdhKeyPair(std::vector<unsigned char>& publicPoint) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDH_P256_ALGORITHM,
                                                    nullptr, 0))) {
        return nullptr;
    }
    BCRYPT_KEY_HANDLE key = nullptr;
    bool ok = BCRYPT_SUCCESS(BCryptGenerateKeyPair(algorithm, &key, 256, 0))
              && BCRYPT_SUCCESS(BCryptFinalizeKeyPair(key, 0));
    if (ok) {
        ULONG size = 0;
        ok = BCRYPT_SUCCESS(BCryptExportKey(key, nullptr, BCRYPT_ECCPUBLIC_BLOB, nullptr,
                                            0, &size, 0));
        std::vector<unsigned char> blob(size);
        ok = ok && BCRYPT_SUCCESS(BCryptExportKey(key, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                                  blob.data(), size, &size, 0));
        if (ok && size >= sizeof(BCRYPT_ECCKEY_BLOB) + 64) {
            publicPoint.assign(1, 0x04);
            publicPoint.insert(publicPoint.end(),
                               blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB),
                               blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB) + 64);
        } else {
            ok = false;
        }
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok && key) {
        BCryptDestroyKey(key);
        return nullptr;
    }
    return key;
}

/// The ECDH shared secret as the x-coordinate, BIG-endian.
///
/// *** BCRYPT_KDF_RAW_SECRET RETURNS IT LITTLE-ENDIAN. *** CryptoKit, and every
/// specification, means big-endian, and the same BCrypt API is inconsistent with
/// itself -- BCRYPT_ECCKEY_BLOB's X, Y and d are all big-endian. Without this
/// reverse the two ends derive different keys, every packet fails its tag, and
/// nothing says why. Measured, not assumed: spike/smt-vectors prints both.
std::vector<unsigned char> EcdhSecret(BCRYPT_KEY_HANDLE mine,
                                      const std::vector<unsigned char>& peerPoint) {
    if (peerPoint.size() != 65 || peerPoint[0] != 0x04) {
        return {};
    }
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDH_P256_ALGORITHM,
                                                    nullptr, 0))) {
        return {};
    }
    std::vector<unsigned char> blob(sizeof(BCRYPT_ECCKEY_BLOB) + 64);
    auto* header = (BCRYPT_ECCKEY_BLOB*) blob.data();
    header->dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
    header->cbKey = 32;
    memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), peerPoint.data() + 1, 64);

    BCRYPT_KEY_HANDLE peer = nullptr;
    std::vector<unsigned char> secret;
    if (BCRYPT_SUCCESS(BCryptImportKeyPair(algorithm, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                           &peer, blob.data(), (ULONG) blob.size(), 0))) {
        BCRYPT_SECRET_HANDLE agreed = nullptr;
        if (BCRYPT_SUCCESS(BCryptSecretAgreement(mine, peer, &agreed, 0))) {
            ULONG size = 0;
            if (BCRYPT_SUCCESS(BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET, nullptr,
                                               nullptr, 0, &size, 0))) {
                secret.resize(size);
                if (!BCRYPT_SUCCESS(BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET,
                                                    nullptr, secret.data(), size,
                                                    &size, 0))) {
                    secret.clear();
                }
            }
            BCryptDestroySecret(agreed);
        }
        BCryptDestroyKey(peer);
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    std::reverse(secret.begin(), secret.end());   // <- the whole comment above
    return secret;
}

/// 108 bytes: two directional keys, two nonce fixed fields, a session id and the
/// two authentication tags each side uses to prove it derived the same thing.
std::vector<unsigned char> DeriveMediaKeys(const std::vector<unsigned char>& cpub,
                                           const std::vector<unsigned char>& hpub,
                                           const std::vector<unsigned char>& cnonce,
                                           const std::vector<unsigned char>& hnonce,
                                           unsigned long long hcount,
                                           const std::vector<unsigned char>& secret,
                                           unsigned short epoch) {
    std::vector<unsigned char> transcript;
    static const char kLabel[] = "SMT/1";
    transcript.insert(transcript.end(), kLabel, kLabel + 5);
    transcript.insert(transcript.end(), cpub.begin(), cpub.end());
    transcript.insert(transcript.end(), hpub.begin(), hpub.end());
    transcript.insert(transcript.end(), cnonce.begin(), cnonce.end());
    transcript.insert(transcript.end(), hnonce.begin(), hnonce.end());
    for (int i = 7; i >= 0; --i) {
        transcript.push_back((unsigned char) ((hcount >> (8 * i)) & 0xFF));
    }
    const std::vector<unsigned char> hash = Sha256(transcript);

    // The token joins the INPUT KEY MATERIAL, not just the transcript: that is
    // what makes a token stolen later useless against a session already gone.
    std::vector<unsigned char> ikm = secret;
    const std::vector<unsigned char> tokenBytes = FromHex(g_token);
    ikm.insert(ikm.end(), tokenBytes.begin(), tokenBytes.end());
    const std::vector<unsigned char> prk = HmacSha256(hash, ikm);

    std::vector<unsigned char> info;
    static const char kKeyLabel[] = "SMT/1 keys v1";
    info.insert(info.end(), kKeyLabel, kKeyLabel + 13);
    info.push_back((unsigned char) (epoch >> 8));
    info.push_back((unsigned char) (epoch & 0xFF));
    info.insert(info.end(), hash.begin(), hash.end());
    return HkdfExpand(prk, info, 108);
}

// There was a `TokenMatches` here, the constant-time compare the legacy auth
// path used. Its one caller has gone -- see the refusal in the `auth` handler --
// and the only comparison against the token now is `ProofMatches`, which
// compares HMAC tags rather than the token itself.

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
    /// Bumped on every claim, so the watcher can tell that the slot it read a
    /// moment ago is still the same tenancy.
    ///
    /// The watcher copies `window` and `desired` under the lock and then lets it
    /// go before doing the slow part -- DwmGetWindowAttribute, ShowWindow,
    /// SetWindowPos, all of which block on another process's message pump. A
    /// release landing in that gap leaves it holding coordinates on the virtual
    /// capture display for a window that has just been put back on a real
    /// monitor, and it drags it straight back to a display nobody can see. That
    /// used to be covered by UnlockAll replaying the restore when the socket
    /// dropped; nothing drops the socket on a window close any more.
    uint64_t generation = 0;
};

CRITICAL_SECTION g_lock_cs;
WindowLock g_locks[kMaxLocks];
uint64_t g_lock_generation = 0;   // guarded by g_lock_cs
HANDLE g_watcher = nullptr;
volatile LONG g_watcher_stop = 0;

bool PlaceClientArea(HWND window, int x, int y, int width, int height,
                     RECT* out_client = nullptr, long long* out_error = nullptr);

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

/// Set when a window somewhere on this PC has come, gone or been renamed, with
/// the tick it last happened on. Written by the event hook on the message-loop
/// thread and read by the watcher, hence atomics rather than the lock.
std::atomic<bool> g_window_set_dirty{false};
std::atomic<ULONGLONG> g_window_set_touched{0};

/// The picker's list is not a photograph.
///
/// Nothing told the Mac that the set of open windows had changed, so the list it
/// drew on connecting was the list it kept: quit an application and its window
/// stayed offerable, start one and it could not be picked without reconnecting.
///
/// The hook fires for every object on the desktop, including menu items and
/// individual controls, so it is filtered hard to real top-level windows and
/// then only sets a flag. The push itself is debounced on the watcher thread —
/// opening one application emits a burst of these, and a message per event
/// would have the Mac rebuild its list a dozen times for one visible change.
void CALLBACK WindowSetChanged(HWINEVENTHOOK, DWORD, HWND window,
                               LONG object, LONG child, DWORD, DWORD) {
    if (object != OBJID_WINDOW || child != CHILDID_SELF || !window) {
        return;
    }
    // Top-level only. A control being created inside a window that is already
    // open changes nothing the picker shows.
    if (GetAncestor(window, GA_ROOT) != window) {
        return;
    }
    g_window_set_touched.store(GetTickCount64());
    g_window_set_dirty.store(true);
}

/// Tell the Mac the window set moved, once the burst has settled.
void NotifyWindowsChangedIfSettled() {
    if (!g_window_set_dirty.load()) {
        return;
    }
    // Long enough to swallow an application's startup burst, short enough that
    // it still feels immediate to someone watching the picker.
    if (GetTickCount64() - g_window_set_touched.load() < 400) {
        return;
    }
    g_window_set_dirty.store(false);

    if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
        return;
    }
    EnterCriticalSection(&g_send_cs);
    struct Unlock {
        ~Unlock() { LeaveCriticalSection(&g_send_cs); }
    } unlock;
    const SOCKET client = g_push_client;
    if (client == INVALID_SOCKET) {
        return;
    }
    // Deliberately just a nudge, with no list attached. The Mac asks for
    // `windows` when it wants them, and it needs `apps` in the same breath to
    // redraw the picker anyway — so sending a list here would either be half
    // the answer or a second copy of one it is about to fetch.
    SendLine(client, "{\"type\":\"windowsChanged\"}");
}

/// Windows already carried back to a real monitor. Kept so that someone who
/// deliberately drags one onto the capture display is not fought over it.
/// Watcher thread only.
std::vector<HWND> g_rescued;

/// Where a stranded window should go, if the capture display is one nobody can
/// see. False when SolStream is capturing a real monitor: what is on that is
/// visible to the person sitting at the PC, and rearranging their windows
/// because a dialog opened would be interference, not help.
bool CaptureDisplayIsInvisible(RECT& capture, RECT& rescue_to) {
    if (g_capture_display.empty()) {
        return false;
    }
    const std::vector<Display> displays = EnumerateDisplays();
    const Display* captured = nullptr;
    const Display* primary = nullptr;
    for (const Display& display : displays) {
        if (ToWide(display.device_name) == g_capture_display) {
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

struct StrandedSearch {
    std::vector<HWND> found;
    RECT capture{};
};

BOOL CALLBACK StrandedProc(HWND window, LPARAM param) {
    auto* search = reinterpret_cast<StrandedSearch*>(param);

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
    // The streamed windows live on this display on purpose, and so do their own
    // menus and dialogs — those reach the user through the video, as part of the
    // application they are looking at.
    EnterCriticalSection(&g_lock_cs);
    bool ours = false;
    for (int i = 0; i < kMaxLocks; ++i) {
        if (g_locks[i].active && (g_locks[i].window == window || g_locks[i].pid == pid)) {
            ours = true;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    if (ours) {
        return TRUE;
    }

    RECT rect{};
    if (!GetWindowRect(window, &rect) || rect.right <= rect.left || rect.bottom <= rect.top) {
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
        if (!SetWindowPos(window, nullptr, x, y, 0, 0,
                          SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
            continue;
        }
        if (g_rescued.size() < 64) {
            g_rescued.push_back(window);
        }
        char title[128] = {0};
        GetWindowTextA(window, title, sizeof(title) - 1);
        Log("[rescue] \"%s\" opened on the capture display, where no monitor shows "
            "it; moved it to the main display", title[0] ? title : "(untitled)");
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

        char title[128] = {0};
        char cls[64] = {0};
        if (found) {
            GetWindowTextA(found, title, sizeof(title) - 1);
            GetClassNameA(found, cls, sizeof(cls) - 1);
            Log("[occlusion] [%s] \"%s\" is on top of the streamed window",
                cls[0] ? cls : "?", title[0] ? title : "(untitled)");
        } else {
            Log("[occlusion] the streamed window is clear again");
        }

        if (InterlockedCompareExchange(&g_push_authorised, 0, 0) == 0) {
            continue;
        }
        EnterCriticalSection(&g_send_cs);
        const SOCKET client = g_push_client;
        if (client != INVALID_SOCKET) {
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
                    const std::string klass = cls;
                    by = (klass.rfind("Shell_System", 0) == 0 || klass == "#32770")
                         ? "a Windows dialog"
                         : "another window";
                }
            }
            SendLine(client,
                     "{\"type\":\"occluded\",\"id\":" + std::to_string(IdFromWindow(window))
                     + ",\"by\":\"" + JsonEscape(by) + "\"}");
        }
        LeaveCriticalSection(&g_send_cs);
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

/// Say which window would receive a click at the pointer.
///
/// Diagnostic, and deliberately measured from here: the agent creates no window
/// of its own, so unlike a probe launched as a scheduled task it cannot be the
/// thing it is looking for. That mattered — a `WindowFromPoint` taken inside
/// such a probe reported a system dim window over the stream that a second run
/// could not find, and the probe's own console was a plausible cause of it.
///
/// It answers a question the streamed window cannot: keystrokes go to whatever
/// holds the FOCUS, but clicks go to whatever is under the POINTER, so an
/// invisible window over the tile breaks the mouse while leaving the keyboard
/// working perfectly. Reported only on change, and only while something is
/// being streamed.
void ReportPointerTarget() {
    POINT cursor{};
    if (!GetCursorPos(&cursor)) {
        return;
    }
    HWND under = WindowFromPoint(cursor);
    static HWND reported = nullptr;
    if (under == reported) {
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
        // A control inside the streamed window is still the streamed window.
        if (g_locks[i].window == under
            || g_locks[i].window == GetAncestor(under, GA_ROOT)) {
            ours = true;
        }
    }
    LeaveCriticalSection(&g_lock_cs);
    if (!streaming) {
        return;
    }

    reported = under;
    char cls[96] = {0};
    char title[128] = {0};
    if (under) {
        GetClassNameA(under, cls, sizeof(cls) - 1);
        GetWindowTextA(GetAncestor(under, GA_ROOT), title, sizeof(title) - 1);
    }
    Log("[pointer] at %ld,%ld a click would go to [%s] \"%s\"%s",
        cursor.x, cursor.y, cls[0] ? cls : "?", title[0] ? title : "(untitled)",
        ours ? "" : "  <-- NOT the streamed window");
}

/// Put a locked window back if anything moved or resized it.
DWORD WINAPI WatcherProc(LPVOID) {
    while (InterlockedCompareExchange(&g_watcher_stop, 0, 0) == 0) {
        Sleep(120);
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
        ReportForegroundThief();
        ReportPointerTarget();
        ReportOcclusion();
        RescueStrandedWindows();
        NotifyWindowsChangedIfSettled();
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
        g_locks[i].generation = ++g_lock_generation;
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
    // The same guard SlotWindowGone applies, and for the same reason: WindowLock
    // carries a pid precisely because IsWindow can come back true for a handle
    // Windows has since recycled onto somebody else's window. This path did not
    // apply it, so a window that quit and had its handle reused got a dead
    // application's saved style, topmost bit and WINDOWPLACEMENT written over
    // it -- an unrelated program losing its resize border and jumping to the
    // last tile of a session it was never part of. Doing nothing is the right
    // answer: the window this slot described no longer exists to restore.
    if (saved.pid != 0) {
        DWORD owner = 0;
        GetWindowThreadProcessId(window, &owner);
        if (owner != saved.pid) {
            return;
        }
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

// -- Pairing, which no longer exists --------------------------------------
//
// Sunshine paired by showing a PIN on the client and having a human type it into
// a web UI on the host, behind a self-signed certificate warning and a set of
// credentials the user had to create first. Most of the code that used to be
// here existed to spare them that: DPAPI-encrypted web credentials, an HTTP POST
// to a local config API, and a careful note about exactly which CSRF check it
// was allowed to skip.
//
// SolStream pairs by the user typing a token once, and the agent proves it with
// an HMAC challenge. There is nothing left here.

// ΓöÇΓöÇ Placement ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

/// Place a window so its CLIENT AREA lands exactly on the requested rectangle.
///
/// The caller cares about the client area, because that is what gets cropped
/// out of the stream ΓÇö but SetWindowPos positions the whole window including
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

// ΓöÇΓöÇ JSON output ΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇΓöÇ

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

/// The effective DPI of a monitor, or 0 when Windows will not say.
UINT MonitorDpi(HMONITOR monitor) {
    UINT x = 0, y = 0;
    return monitor && SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &x, &y)) ? x : 0;
}

/// The effective DPI of the capture display, or 0 when there is none.
UINT CaptureDisplayDpi() {
    struct Search { const std::wstring* name; HMONITOR found; } search{&g_capture_display, nullptr};
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
    // about SolStream appeared on the virtual display mid-test and sat over half
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
        out += ",\"captureDisplay\":\"" + JsonEscape(ToUtf8(g_capture_display)) + "\"";
        out += ",\"virtualDisplay\":"
             + std::string(solstream::HasVirtualDisplay() ? "true" : "false");
        out += "}";
        return out;
    }

    if (command == "auth") {
        // v2 first. The token itself never crosses the wire: the client proves
        // it holds one against a challenge this connection just invented.
        std::string proof, cnonce;
        if (FieldString(line, "proof", proof) && FieldString(line, "cnonce", cnonce)) {
            if (ProofMatches(challenge, cnonce, proof)) {
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
                // Guarded, because everything it reaches for is: both
                // `DeriveChannelKeys` and `g_pending_channel` are declared
                // inside SOLSTREAM_MEDIA, and this block was written without a
                // guard of its own. That made the no-media configuration stop
                // compiling -- and with it the mingw cross-build, which is the
                // only way to compile-check this file without the Windows
                // machine. It failed with "'DeriveChannelKeys' is not a member
                // of 'solstream::media'", which reads like a missing include
                // rather than a missing guard.
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
                            static const char* hex = "0123456789abcdef";
                            std::string hpubHex;
                            for (unsigned char byte : hpub) {
                                hpubHex.push_back(hex[byte >> 4]);
                                hpubHex.push_back(hex[byte & 0x0F]);
                            }
                            return "{\"type\":\"auth\",\"ok\":true"
                                   ",\"channelCrypto\":2"
                                   ",\"hpub\":\"" + hpubHex + "\""
                                   ",\"hauth\":\"" + hostAuth + "\"}";
                        }
                    }
                    Log("[agent] could not agree channel keys; staying in the clear");
                }
#endif  // SOLSTREAM_MEDIA
                // Said out loud. Which of the two auth paths a client took is
                // the first question when one of them misbehaves, and until now
                // a successful authentication left no trace at all -- only a
                // failed one did.
                Log("[agent] client authenticated with a v2 proof");
                return "{\"type\":\"auth\",\"ok\":true}";
            }
            ++auth_failures;
            Log("[agent] rejected a bad auth proof (%d on this connection)",
                auth_failures);
            return "{\"type\":\"auth\",\"ok\":false,\"message\":\"bad token\"}";
        }

        // NO v1 FALLBACK, and now on this side too.
        //
        // The host used to accept `{"cmd":"auth","token":"..."}` on the grounds
        // that taking a token somebody already holds discloses nothing, while
        // sending one does -- which is why the Mac's half was deleted. Both
        // halves of that were true and it still had to go, for a reason the
        // asymmetry hid: a client that authenticated this way agreed no channel
        // keys, because `channelCrypto` is negotiated inside the v2 branch above.
        // So it was a downgrade route that ended in a working, fully authorised
        // session with the window titles, the application list and every
        // clipboard transfer crossing in the clear. Nothing has ever used it --
        // the Mac refuses to carry on unencrypted, and no spike or probe sends a
        // token -- and docs/architecture.md has claimed for its whole life that
        // authentication here is v2 only. It is now.
        if (std::string ignored; FieldString(line, "token", ignored)) {
            ++auth_failures;
            Log("[agent] refused a cleartext token: this host authenticates with a "
                "v2 proof only (%d refusal%s on this connection)",
                auth_failures, auth_failures == 1 ? "" : "s");
            return "{\"type\":\"auth\",\"ok\":false,\"message\":\"this host needs a "
                   "v2 proof, not a token. Update SolStream on the Mac.\"}";
        }
        // Counted rather than slept off. This is the only guess-and-check
        // surface here, and it used to answer a wrong token a second late on the
        // grounds that the delay cost an attacker everything and a legitimate
        // client nothing. Both were false: the agent serves one client at a
        // time, so the second was a second in which the paired Mac could not be
        // served, which is the attacker's goal and not his cost. See
        // kMaxAuthFailures.
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
            DeriveMediaKeys(cpub, hpub, cnonce, hnonce, hcount, secret, 0);
        if (okm.size() != 108) {
            return "{\"type\":\"media\",\"ok\":false,\"message\":\"derivation failed\"}";
        }

        // hostAuth, bytes 80..92. The Mac derives the same 108 bytes and checks
        // this: if it matches, both ends hold the same keys, and that is worth
        // knowing HERE rather than discovering it as every packet failing its
        // tag with nothing to say why.
        static const char* hex = "0123456789abcdef";
        std::string hauth;
        for (size_t i = 80; i < 92; ++i) {
            hauth.push_back(hex[okm[i] >> 4]);
            hauth.push_back(hex[okm[i] & 0x0F]);
        }
        std::string hpubHex;
        for (unsigned char byte : hpub) {
            hpubHex.push_back(hex[byte >> 4]);
            hpubHex.push_back(hex[byte & 0x0F]);
        }
        // Keys agreed. Now start the media path itself, if the client named
        // something to capture. A client that only wants the keys -- the
        // handshake test does -- gets them and nothing starts, which is what
        // made step 4 measurable before step 6 existed.
        std::string started = "false";
        std::string startError;
#ifdef SOLSTREAM_MEDIA
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
        Log("[media] session %llu opened; keys derived; streaming %s%s%s",
            hcount, started.c_str(), startError.empty() ? "" : " -- ",
            startError.c_str());
        return "{\"type\":\"media\",\"ok\":true,\"ver\":1"
               ",\"hpub\":\"" + hpubHex + "\""
               ",\"hnonce\":\"" + hnonceHex + "\""
               ",\"hcount\":\"" + std::to_string(hcount) + "\""
               ",\"hauth\":\"" + hauth + "\""
               ",\"streaming\":" + started
               + (startError.empty() ? std::string()
                                     : ",\"message\":\"" + JsonEscape(startError) + "\"")
               + ",\"hport\":" + std::to_string(solstream::kDefaultMediaPort) + "}";
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
        // Only the virtual display this host is capturing. SetDisplayMode writes
        // with CDS_UPDATEREGISTRY, so a name the Mac got wrong — or a host with
        // no virtual display, capturing the primary — would permanently change
        // the resolution of somebody's real monitor. The Mac already only asks
        // for a display it believes is virtual; this is the host not taking its
        // word for it. `ok:false` is what the Mac reads as "the host kept its
        // size", and it carries on at that size.
        const std::wstring wanted = ToWide(device);
        const std::wstring virtual_device = solstream::VirtualDisplayDevice();
        const bool is_capture = !g_capture_display.empty()
            && _wcsicmp(wanted.c_str(), g_capture_display.c_str()) == 0;
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

    // `pair` is gone with GameStream. A Mac that still sends it is running an
    // older build, and telling it so beats a silent failure.
    if (command == "pair") {
        return "{\"type\":\"paired\",\"ok\":false,\"reason\":\"gone\""
               ",\"message\":\"SolStream pairs with a token, not a PIN. "
               "Update the Mac application.\"}";
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
        RECT client{};
        long long missed = 0;
        const bool ok = PlaceClientArea(window, (int) x, (int) y, (int) w, (int) h,
                                        &client, &missed);
        // A miss that survived every correction is the application refusing the
        // size, and it is worth a line: it is the difference between "SolStream
        // sized this wrongly" and "this window will not be that shape", and until
        // now nothing anywhere recorded which of the two had happened. Only when
        // it is large enough to see -- an off-by-one on a rounded axis is not news.
        if (missed > 2) {
            char title[96] = {0};
            GetWindowTextA(window, title, sizeof(title) - 1);
            Log("[place] \"%s\" asked for %lldx%lld at %lld,%lld and settled at "
                "%ldx%ld at %ld,%ld (%lld px out)",
                title[0] ? title : "(untitled)", w, h, x, y,
                client.right - client.left, client.bottom - client.top,
                client.left, client.top, missed);
        }
        // The Mac asked for this, so it is the new truth ΓÇö otherwise the watcher
        // would immediately drag the window back to the previous size.
        SetLockedGeometry(window, client);
        char buffer[320];
        const POINT minimum = MinimumClientSize(window);
        std::snprintf(buffer, sizeof(buffer),
                      "{\"type\":\"placed\",\"ok\":%s,\"x\":%ld,\"y\":%ld,\"w\":%ld,\"h\":%ld"
                      ",\"minW\":%ld,\"minH\":%ld,\"border\":%d,\"missed\":%lld}",
                      ok ? "true" : "false",
                      client.left, client.top,
                      client.right - client.left, client.bottom - client.top,
                      minimum.x, minimum.y, ResizeBorderThickness(window), missed);
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
        //
        // And refuse the command when there is no slot to be had. ClaimSlot
        // returns -1 once all kMaxLocks are taken, and that return used to be
        // dropped on the floor: the ninth window was pinned into the always-on-
        // top band with nothing recording that it had been, so neither
        // UnlockAll on disconnect nor `topmost off` could put it back. The
        // window stayed above everything the user did next, with no visible
        // cause, until the application was restarted. Better to do nothing and
        // say so.
        EnterCriticalSection(&g_lock_cs);
        const int slot = ClaimSlot(window);
        LeaveCriticalSection(&g_lock_cs);
        if (slot < 0) {
            Log("[agent] refused topmost: all %d window slots are taken", kMaxLocks);
            return "{\"type\":\"error\",\"message\":\"too many windows are being "
                   "managed; close one on the Mac first\"}";
        }
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
            // Through Log, not printf. An installed host has had its stdout
            // reopened on NUL by ReleaseUnwantedConsole, so this line -- the
            // only trace of a session where the picture is right and the typing
            // goes somewhere else -- was written to nowhere on every machine
            // that was not a development box.
            Log("[focus] could not take the foreground for \"%s\";"
                " keystrokes will go to whatever holds it", title);
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
/// Which cursor watcher is the current one.
///
/// A shared stop flag was not enough. StopCursorWatcher waits two seconds for
/// the thread to leave, and the thread can be inside SendLine for far longer
/// than that -- SO_SNDTIMEO on this socket is thirty seconds, so a client whose
/// receive window has filled up holds it there. When the wait timed out the
/// handle was closed and the thread abandoned, and the NEXT client's
/// StartCursorWatcher then cleared the stop flag out from under it: the
/// abandoned thread carried on for ever, pushing cursor shapes down the new
/// client's socket beside the new watcher's own. Each thread now keeps the
/// generation it was started with and exits when it is no longer the current
/// one, which no later Start can undo.
volatile LONG g_cursor_generation = 0;

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

DWORD WINAPI CursorWatcherProc(LPVOID parameter) {
    const LONG mine = (LONG) (LONG_PTR) parameter;
    HCURSOR last = nullptr;
    bool logged_once = false;
    while (InterlockedCompareExchange(&g_cursor_stop, 0, 0) == 0
           && InterlockedCompareExchange(&g_cursor_generation, 0, 0) == mine) {
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
            // Under the send lock, like every other reader of it: the client
            // thread retires this socket under the same lock, so reading it
            // outside was a torn read away from writing to a handle that had
            // been closed and reissued to the next connection.
            EnterCriticalSection(&g_send_cs);
            const SOCKET client = g_push_client;
            LeaveCriticalSection(&g_send_cs);
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
    // Under the lock the window watcher and the cursor watcher both read it
    // under. Only the clearing in StopCursorWatcher used to be, and a SOCKET is
    // not written atomically -- so the two threads that read this while it was
    // being assigned could see neither the old value nor the new one.
    EnterCriticalSection(&g_send_cs);
    g_push_client = client;
    LeaveCriticalSection(&g_send_cs);
    InterlockedExchange(&g_cursor_stop, 0);
    InterlockedExchange(&g_push_authorised, authorised ? 1 : 0);
    const LONG generation = InterlockedIncrement(&g_cursor_generation);
    g_cursor_thread = CreateThread(nullptr, 0, CursorWatcherProc,
                                   (LPVOID) (LONG_PTR) generation, 0, nullptr);
}

void StopCursorWatcher() {
    InterlockedExchange(&g_cursor_stop, 1);
    // And retire this generation, so a thread that outlives the wait below
    // cannot be revived by the next Start clearing the stop flag.
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
/// A wrong token used to cost the guesser a one-second Sleep and nothing else,
/// and the comment beside it said that cost the attacker everything and a
/// legitimate client nothing. Both halves were wrong once the connection itself
/// became the prize: that Sleep runs on the serving thread, which is the only
/// thread there is, so it kept the slot shut for a second per guess and the
/// legitimate client — locked out for the duration — was the one paying. The
/// limit replaces it. Guessing 16 random bytes is not a real attack in any case;
/// what needed bounding was the guessing being free to go on for ever on one
/// socket.
///
/// Three, not one, because a person who mistypes a token should be told so and
/// allowed another go on the same connection, and the Mac re-asks in place when
/// a proof comes back refused.
constexpr int kMaxAuthFailures = 3;

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
    char hostname[256] = {};
    DWORD hostname_size = sizeof(hostname);
    GetComputerNameA(hostname, &hostname_size);

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
    if (authenticated) {
        // Loopback, which needs no token and is therefore already a session.
        g_clients_authenticated.fetch_add(1);
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
    // it. The rest of an oversized line has not arrived yet ΓÇö it comes in later
    // recv() chunks ΓÇö so this cannot be a one-off scan of what is in hand.
    bool discarding = false;
    for (;;) {
        const int n = recv(client, chunk, sizeof(chunk), 0);
        if (n == SOCKET_ERROR && WSAGetLastError() == WSAETIMEDOUT) {
            Log("[agent] client idle for %lus%s, dropping",
                (unsigned long) (timeout_ms / 1000),
                authenticated ? "" : " without authenticating");
            return;
        }
        if (n <= 0) {
            return;
        }
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

        // A client that never sends a newline must not grow this unbounded ΓÇö
        // but refuse the line, not the client. Dropping the connection is far
        // more destructive than it sounds: closing the socket runs UnlockAll(),
        // which pulls every streamed window off the virtual display and back
        // onto the real desktop, in the middle of a session the user is still
        // watching. The Mac does reconnect and re-assert every window now, but
        // the media session does not come back with it -- so what this costs is
        // still a live picture of a window that has been moved out from under it.
        if (buffer.size() > kMaxLineBytes) {
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
                    "without framing; dropping the client", kMaxLineBytes);
                return;
            }
#endif
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

        wchar_t name[256] = {};
        DWORD size = 256;
        GetComputerNameW(name, &size);
        const std::string reply = "SOLSTREAM-HOST/1 " + ToUtf8(name);
        Log("[discover] answering on UDP %u as %s", solstream::kDiscoveryPort,
            ToUtf8(name).c_str());

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

int wmain(int argc, wchar_t** argv) {
    ReleaseUnwantedConsole();
    // Everything outside main.cpp logs through the agent's file rather than
    // through a second one, and learns where that is here rather than by
    // declaring a function it has no way to reach.
    solstream::media::SetLogger([](const char* line) { Log("%s", line); });
    unsigned short port = kDefaultPort;
    // Loopback by default. This socket has no authentication yet, so the address
    // it binds is the only thing limiting who can drive it.
    std::string bind_address = kLoopback;
    bool print_token = false;
    bool no_auth = false;
    bool install = false;
    bool uninstall = false;
    bool uninstall_now = false;
    bool configure_display = false;
    // --headless keeps the original behaviour: no window, log to stderr. Every
    // verification in this project is done over SSH, where there is no desktop
    // to put a window on.
    bool headless = false;
    bool install_driver = false;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--port" && i + 1 < argc) {
            port = static_cast<unsigned short>(std::wcstol(argv[i + 1], nullptr, 10));
        } else if (arg == L"--headless") {
            headless = true;
        } else if (arg == L"--install-display-driver") {
            install_driver = true;
        } else if (arg == L"--bind" && i + 1 < argc) {
            // Prefer a single address ΓÇö a VPN interface such as Tailscale, whose
            // peers are already device-authenticated ΓÇö over every interface.
            bind_address = ToUtf8(argv[i + 1]);
        } else if (arg == L"--listen-all") {
            bind_address = "0.0.0.0";
        } else if (arg == L"--print-token") {
            print_token = true;
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
        }
    }

    // Without this every coordinate we read or write is silently rescaled by
    // Windows' DPI virtualisation, and windows land in the wrong place on any
    // display that is not at 100%.
    //
    // Here, before any of the branches below, rather than down on the agent
    // path where it used to sit. The setup window and the uninstall
    // confirmation are created and returned from above that line, so both of
    // them ran DPI-unaware — which made the whole per-monitor path in
    // host_window.cpp dead code for the two windows a new user sees first, and
    // left them bitmap-stretched and blurry on exactly the high-DPI laptop
    // panels where it matters. Setting process DPI awareness has to happen
    // before the first window exists; it cannot be corrected afterwards.
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
        const bool ok = solstream::UninstallSelf(error);
        solstream::WriteInstallResult(ok, error);
        if (!ok) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
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
                    L"--install" + solstream::OptionArguments(options), error)) {
                std::fprintf(stderr, "%s\n", error.c_str());
                return 1;
            }
            return 0;
        }
        std::string error;
        const bool ok = solstream::InstallSelf(options, error);
        // The window that asked for this is in another process and cannot see a
        // return code, so the reason goes in a file it knows to read.
        solstream::WriteInstallResult(ok, error);
        if (!ok) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        std::fputs("SolStream is installed and running. It will start again "
                   "when you log in.\n", stdout);
        return 0;
    }

    if (install_driver || configure_display) {
        std::string error;
        if (install_driver && !solstream::InstallBundledDriver(error)) {
            std::fprintf(stderr, "%s\n", error.c_str());
            return 1;
        }
        // Installing the driver is not the same as having a display worth
        // capturing: out of the box it offers a mode list that matches no Mac,
        // scales wrong, and advertises HDR — which is what made streamed content
        // arrive as a black rectangle with its chrome drawn correctly around it.
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
        HANDLE instance = CreateMutexW(nullptr, FALSE, L"Local\\SolStreamAgentHost");
        const DWORD created = GetLastError();
        // Access denied is also "somebody has it": an elevated copy's mutex
        // carries a DACL an unelevated one cannot open.
        if ((instance && created == ERROR_ALREADY_EXISTS)
            || (!instance && created == ERROR_ACCESS_DENIED)) {
            const bool focused = solstream::FocusExistingHostWindow();
            Log("[agent] another SolStream host is already running in this "
                "session%s; this copy is exiting",
                focused ? " (its window was brought forward)" : "");
            return 0;
        }
        if (!instance) {
            // Not worth refusing to start over. The port is still exclusive, so
            // the worst case is the old one: a second copy that fails to bind.
            Log("[agent] could not create the single-instance mutex: %lu",
                (unsigned long) created);
        }
    }

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

    // Pick what is captured: the virtual display when there is one, so a
    // crop can never be a crop out of somebody's real screen. The one that was
    // just set up first — matching "virtual" alone also matches other products'
    // virtual displays, which are not sized for the Mac.
    const std::string configured = ToUtf8(solstream::VirtualDisplayDevice());
    for (const Display& display : EnumerateDisplays()) {
        if (!configured.empty() && display.device_name == configured) {
            g_capture_display = ToWide(display.device_name);
            Log("[agent] capturing %s [%s]", display.device_name.c_str(),
                display.adapter.c_str());
            break;
        }
    }
    for (const Display& display : EnumerateDisplays()) {
        if (!g_capture_display.empty()) {
            break;
        }
        // Ours only. This used to match "virtual" or "idd" anywhere in the
        // adapter name, which is every phone-as-monitor and remote-desktop
        // product's display too — and capturing one of those streams a screen
        // SolStream did not size, from a display it does not control. Better
        // the primary below, which at least says plainly what it is.
        const std::string& adapter = display.adapter;
        if (solstream::IsSolStreamDisplayDriver(ToWide(adapter))) {
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
            // Keyed on clients that have PROVED the token, not on open sockets.
            // g_clients_connected counts an accepted socket from the moment it
            // is accepted and nothing frees it early, so anything that opened
            // this port and then said nothing — a port scanner, a monitoring
            // probe, anyone at all — was enough to have the paired Mac told that
            // this PC was "already streaming to another Mac". The Mac treats
            // `busy` as final and does not come back, so one connect() locked
            // the pairing out for the whole idle timeout, and a repeated one
            // locked it out indefinitely. A genuine second Mac has proved the
            // token; that is what this now asks.
            if (g_clients_authenticated.load() > 0) {
                char name[256] = {};
                DWORD name_size = sizeof(name);
                GetComputerNameA(name, &name_size);
                std::string busy = "{\"type\":\"busy\",\"message\":\"";
                busy += JsonEscape(std::string(name) + " is already streaming to "
                                   "another Mac. Disconnect there first.");
                busy += "\"";
                busy += ",\"virtualDisplay\":"
                     + std::string(solstream::HasVirtualDisplay() ? "true" : "false");
                busy += "}";
                Log("[agent] refused a second client: one is already connected");
                SendLine(client, busy);
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
            if (g_clients_connected.load() > 0) {
                Log("[agent] closed a client on arrival: the socket is held by "
                    "one that has not authenticated yet");
                closesocket(client);
                continue;
            }

            Log("[agent] client connected");
            g_clients_connected.fetch_add(1);
            // From here, not from `lock`. The watcher is what carries the
            // debounced "the window set moved" push, and a Mac sitting in the
            // application picker has locked nothing at all — which is precisely
            // when a list that never refreshes is the thing being looked at.
            // Idempotent, and its body does nothing while no window is held.
            StartWatcher();
            std::thread([client]() {
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
                // And stop streaming to a Mac that has gone. Nothing here did
                // that: the only thing that ended a session was the client's own
                // UDP BYE, which sets a flag, and a fifteen-second silence
                // timeout for when the BYE is lost -- so a Mac that vanished
                // left the capture, the encoder, the sender and the receive
                // threads running, its socket and keys held, and whatever key or
                // mouse button it was holding still down on the host. This is
                // the backstop the close path used to get for free by dropping
                // the socket, and it is what makes losing a client the same as
                // ending a session cleanly.
                solstream::media::MediaSession::Instance().Stop();
#endif
                // Give every managed window its resize border back. A Mac that
                // goes away must not leave applications permanently unresizable.
                UnlockAll();
                // A PIN nobody is waiting on any more is worse than no PIN: it
                // is a code on screen that does nothing, for a Mac that has gone.
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
            // Listening on everything means the bind address says nothing about
            // where to look, so find an address that does. Re-read every tick
            // rather than cached: a laptop that joins a network, or a VPN that
            // comes up, changes the answer while this window is open.
            status.address = bind_address == "0.0.0.0"
                                 ? ToWide(BestLocalAddress())
                                 : ToWide(bind_address);
            status.pairing_token = ToWide(g_token);
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
            }
#else
            status.streaming_ready = false;
            status.streaming_detail = L"This build has no media path.";
#endif

            status.virtual_display = solstream::HasVirtualDisplay();
            status.display_detail = status.virtual_display
                ? (g_capture_display.empty() ? L"ready" : g_capture_display)
                : L"not installed";

            solstream::UpdateHostStatus(status);
            Sleep(1000);
        }
    });
    status.detach();

    // Installed here because an out-of-context hook delivers its callbacks on
    // the thread that set it, through that thread's message loop — and this is
    // the thread with one. Set from the watcher instead, the callbacks would
    // have nowhere to arrive and the picker would go on showing a stale list.
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
