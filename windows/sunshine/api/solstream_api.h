#pragma once

/// @file solstream_api.h
/// SolStream HTTP API route handlers for Sunshine's web server.
///
/// Routes:
///   GET  /api/solstream/apps        → list capturable windows
///   POST /api/solstream/stream/start → start streaming a window
///   POST /api/solstream/stream/stop  → stop the active stream
///   GET  /api/solstream/status       → stream health state
///
/// These are designed to be integrated into Sunshine's existing HTTP
/// routing system (Simple-Web-Server / boost beast).
///
/// Thread safety: these handlers run on Sunshine's HTTP thread pool.
/// They access the SunshinePipeServer via a shared pointer.

#include <Windows.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

#include "../sunshine_pipe_server.h"

namespace solstream {

// ══════════════════════════════════════════════════════════════════════════════
// Types
// ══════════════════════════════════════════════════════════════════════════════

/// A capturable application window.
struct AppInfo {
    std::wstring name;     ///< Window title (UTF-16)
    HWND         hwnd{};   ///< Window handle
    DWORD        pid{};    ///< Owning process ID
    std::wstring processName; ///< Process executable name
    bool         isMinimized{false};
};

/// SolStream state for status endpoint.
struct StreamStatus {
    bool     captureActive{false};
    bool     pipeConnected{false};
    uint64_t framesCaptured{};
    uint64_t framesEncoded{};
    int      textureWidth{1920};
    int      textureHeight{1920};
    std::string stateText{"idle"};
};

// ══════════════════════════════════════════════════════════════════════════════
// API handler
// ══════════════════════════════════════════════════════════════════════════════
//
// Wraps the pipe server reference and provides HTTP-friendly methods.
// Designed to be a singleton or injected into Sunshine's route map.

class SolStreamAPI {
public:
    explicit SolStreamAPI(SunshinePipeServer& pipeServer)
        : m_pipeServer(pipeServer) {}

    SolStreamAPI(const SolStreamAPI&) = delete;
    SolStreamAPI& operator=(const SolStreamAPI&) = delete;

    /// Enumerate all capturable windows.
    /// Returns JSON array: [{"name":"...","hwnd":1234,"pid":5678,"processName":"...","isMinimized":false}]
    [[nodiscard]] std::string HandleApps();

    /// Start streaming the window matching the given HWND.
    /// Accepts JSON: {"hwnd": 1234}
    /// Returns JSON: {"status":"ok","message":"..."}
    [[nodiscard]] std::string HandleStreamStart(const std::string_view jsonBody);

    /// Stop the current stream.
    [[nodiscard]] std::string HandleStreamStop();

    /// Return current stream health.
    [[nodiscard]] std::string HandleStatus();

private:
    SunshinePipeServer& m_pipeServer;

    // Internal helpers
    [[nodiscard]] std::vector<AppInfo> EnumerateWindows();

    // HWND tracking (JSON response helper)
    [[nodiscard]] static std::string EscapeJson(const std::wstring& ws);
    [[nodiscard]] static std::string EscapeJson(const std::string& s);
};

} // namespace solstream
