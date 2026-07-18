#include "solstream_api.h"

#include <psapi.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdlib>
#include <cstring>
#include <format>
#include <ranges>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

#include "../CaptureHelper/pipe_transport.h"

namespace solstream {

// ══════════════════════════════════════════════════════════════════════════════
// JSON escaping helpers
// ══════════════════════════════════════════════════════════════════════════════

std::string SolStreamAPI::EscapeJson(const std::wstring& ws) {
    // Convert UTF-16 → UTF-8, then escape.
    int len = WideCharToMultiByte(CP_UTF8, 0,
                                  ws.data(), static_cast<int>(ws.size()),
                                  nullptr, 0, nullptr, nullptr);
    if (len <= 0) return "\"\"";
    std::string utf8(static_cast<std::size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0,
                        ws.data(), static_cast<int>(ws.size()),
                        utf8.data(), len, nullptr, nullptr);
    return EscapeJson(utf8);
}

std::string SolStreamAPI::EscapeJson(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 2);
    out += '"';
    for (char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n";  break;
        case '\r': out += "\\r";  break;
        case '\t': out += "\\t";  break;
        default:
            if (static_cast<unsigned char>(c) < 0x20) {
                out += std::format("\\u{:04x}", static_cast<unsigned char>(c));
            } else {
                out += c;
            }
            break;
        }
    }
    out += '"';
    return out;
}

// ══════════════════════════════════════════════════════════════════════════════
// Window enumeration
// ══════════════════════════════════════════════════════════════════════════════

namespace {

/// Callback context for EnumWindows.
struct EnumContext {
    std::vector<AppInfo>& apps;
    DWORD currentSessionId{};
};

/// Determine the executable name for a PID.
static std::wstring GetProcessName(DWORD pid) {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!hProcess)
        return L"";
    std::array<wchar_t, MAX_PATH> buf{};
    DWORD bufSize = static_cast<DWORD>(buf.size());
    QueryFullProcessImageNameW(hProcess, 0, buf.data(), &bufSize);
    CloseHandle(hProcess);

    // Extract just the executable name (last component).
    std::wstring path(buf.data(), bufSize);
    auto pos = path.find_last_of(L'\\');
    return (pos != std::wstring::npos) ? path.substr(pos + 1) : path;
}

static BOOL CALLBACK EnumWindowsProc(HWND hwnd, LPARAM lParam) {
    auto& ctx = *reinterpret_cast<EnumContext*>(lParam);

    // Skip windows that are not visible or have no title.
    if (!IsWindowVisible(hwnd))
        return TRUE;
    if (!IsWindow(hwnd))
        return TRUE;

    // Check that this window belongs to the current session.
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == 0)
        return TRUE;

    // Skip windows without owner and with empty titles (system windows).
    std::array<wchar_t, 256> titleBuf{};
    int titleLen = GetWindowTextW(hwnd, titleBuf.data(),
                                  static_cast<int>(titleBuf.size()));
    if (titleLen <= 0)
        return TRUE;

    AppInfo info;
    info.name.assign(titleBuf.data(), static_cast<std::size_t>(titleLen));
    info.hwnd = hwnd;
    info.pid = pid;
    info.processName = GetProcessName(pid);
    info.isMinimized = IsIconic(hwnd) != FALSE;

    ctx.apps.push_back(std::move(info));
    return TRUE;
}

} // anonymous namespace

std::vector<AppInfo> SolStreamAPI::EnumerateWindows() {
    std::vector<AppInfo> apps;
    EnumContext ctx{apps};
    EnumWindows(EnumWindowsProc, reinterpret_cast<LPARAM>(&ctx));

    // Sort alphabetically by window title for stable ordering.
    std::ranges::sort(apps, [](const AppInfo& a, const AppInfo& b) {
        return _wcsicmp(a.name.c_str(), b.name.c_str()) < 0;
    });

    return apps;
}

// ══════════════════════════════════════════════════════════════════════════════
// Route handlers
// ══════════════════════════════════════════════════════════════════════════════

std::string SolStreamAPI::HandleApps() {
    auto apps = EnumerateWindows();

    std::string json;
    json += "{\"apps\":[";

    bool first = true;
    for (const auto& app : apps) {
        if (!first) json += ',';
        first = false;

        json += std::format(
            "{{\"name\":{},\"hwnd\":{},\"pid\":{},\"processName\":{},\"isMinimized\":{}}}",
            EscapeJson(app.name),
            reinterpret_cast<std::uintptr_t>(app.hwnd),
            app.pid,
            EscapeJson(app.processName),
            app.isMinimized ? "true" : "false");
    }

    json += "]}";
    return json;
}

std::string SolStreamAPI::HandleStreamStart(const std::string_view jsonBody) {
    // Parse JSON body to extract HWND.
    // Simple parser: find "hwnd":<number> or "hwnd": <number>.
    HWND targetHwnd = nullptr;

    auto hwndPos = jsonBody.find("hwnd");
    if (hwndPos != std::string_view::npos) {
        auto colonPos = jsonBody.find(':', hwndPos);
        if (colonPos != std::string_view::npos) {
            // Skip whitespace and optional quotes.
            auto start = colonPos + 1;
            while (start < jsonBody.size() &&
                   (jsonBody[start] == ' ' || jsonBody[start] == '"'))
                ++start;

            // Parse the number.
            auto end = start;
            while (end < jsonBody.size() && jsonBody[end] >= '0' && jsonBody[end] <= '9')
                ++end;

            if (end > start) {
                std::uintptr_t hwndValue = 0;
                std::from_chars(jsonBody.data() + start,
                                jsonBody.data() + end, hwndValue);
                targetHwnd = reinterpret_cast<HWND>(hwndValue);
            }
        }
    }

    if (!targetHwnd || !IsWindow(targetHwnd)) {
        return R"({"status":"error","message":"Invalid or missing HWND"})";
    }

    // Send StartStream via the pipe server.
    bool sent = m_pipeServer.SendStreamStart(targetHwnd);
    if (!sent) {
        return R"({"status":"error","message":"Pipe not connected or send failed"})";
    }

    return std::format(
        R"({{"status":"ok","message":"Stream start requested","hwnd":{}}})",
        reinterpret_cast<std::uintptr_t>(targetHwnd));
}

std::string SolStreamAPI::HandleStreamStop() {
    bool sent = m_pipeServer.SendStreamStop();
    if (!sent) {
        return R"({"status":"error","message":"Pipe not connected or send failed"})";
    }
    return R"({"status":"ok","message":"Stream stop requested"})";
}

std::string SolStreamAPI::HandleStatus() {
    auto state = m_pipeServer.GetState();

    std::string stateStr;
    switch (state) {
    case PipeState::Disconnected: stateStr = "disconnected"; break;
    case PipeState::Connecting:   stateStr = "connecting";   break;
    case PipeState::Connected:    stateStr = "connected";    break;
    case PipeState::Handshaking:  stateStr = "handshaking";  break;
    case PipeState::Streaming:    stateStr = "streaming";    break;
    case PipeState::Reconnecting: stateStr = "reconnecting"; break;
    case PipeState::Error:        stateStr = "error";        break;
    default:                      stateStr = "unknown";      break;
    }

    auto [w, h] = m_pipeServer.GetTextureSize();

    return std::format(
        R"({{"status":"{}","state":"{}","textureWidth":{},"textureHeight":{}}})",
        state == PipeState::Streaming ? "active" : "inactive",
        stateStr, w, h);
}

} // namespace solstream
