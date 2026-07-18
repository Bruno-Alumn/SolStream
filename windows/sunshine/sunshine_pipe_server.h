#pragma once

/// @file sunshine_pipe_server.h
/// Named-pipe server running inside Sunshine's process that accepts
/// connections from CaptureHelper, receives shared-texture handles, and
/// forwards frame-ready notifications to the encoder pipeline.
///
/// Thread safety:
///   The pipe read-loop runs on its own thread. Frame-ready callbacks
///   are dispatched on that thread. Callbacks must be set before Start()
///   and must NOT be modified concurrently with execution — they are
///   protected by a mutex on set/get. The owning code must serialise
///   access to the EncoderInput instance; GetEncoderInput() exposes it
///   for setup (SetDevice) and drain operations. Start() and Stop()
///   are thread-safe and idempotent.
///
///   Destruction from inside a callback running on the pipe thread will
///   deadlock (join self). Do not let callback chains outlive the server.

#include <Windows.h>
#include <d3d11.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include "../CaptureHelper/pipe_transport.h"
#include "solstream_encoder_input.h"

namespace solstream {

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

/// How often to send a heartbeat query to CaptureHelper (milliseconds).
constexpr auto kHeartbeatInterval = std::chrono::milliseconds(5000);

/// How long to wait for CaptureHelper to connect before reporting failure.
constexpr auto kConnectTimeout = std::chrono::milliseconds(30000);

/// Maximum time without a Heartbeat or FrameReady before declaring
/// CaptureHelper as dead.
constexpr auto kWatchdogTimeout = std::chrono::milliseconds(15000);

/// Maximum number of consecutive reconnection attempts before giving up.
constexpr int kMaxReconnectAttempts = 10;

/// Delay between reconnection attempts (milliseconds).
constexpr auto kReconnectDelay = std::chrono::milliseconds(1000);

// ══════════════════════════════════════════════════════════════════════════════
// Stream state
// ══════════════════════════════════════════════════════════════════════════════

/// Connection state of the CaptureHelper pipe.
enum class PipeState : std::uint8_t {
    Disconnected,
    Connecting,
    Connected,
    Handshaking,   // Waiting for AdapterInfo after connection
    Streaming,     // Fully operational — capture running
    Reconnecting,  // Pipe disconnected, attempting reconnect
    Error,         // Fatal error — manual intervention needed
};

// ══════════════════════════════════════════════════════════════════════════════
// Callback types
// ══════════════════════════════════════════════════════════════════════════════

/// Called on the pipe thread when a FrameReady message arrives.
using FrameReadyCallback = std::function<void()>;

/// Called when the pipe connection state changes.
using PipeStateCallback = std::function<void(PipeState newState)>;

// ══════════════════════════════════════════════════════════════════════════════
// SunshinePipeServer
// ══════════════════════════════════════════════════════════════════════════════
//
// Manages the named-pipe connection to CaptureHelper and the associated
// EncoderInput that opens shared textures on Sunshine's D3D11 device.
//
// Lifecycle:
//   1. Construct with an existing EncoderInput reference.
//   2. (Optional) SetFrameReadyCallback() / SetStateCallback().
//   3. Start() creates the pipe thread, creates the named pipe, and waits
//      for CaptureHelper to connect.
//   4. On connection, sends SunshinePID, receives AdapterInfo + SharedHandleInfo.
//   5. On FrameReady, invokes the callback — encoder should call
//      EncoderInput::AcquireFrame() to retrieve the texture.
//   6. Stop() signals the pipe thread and joins it.
//
// Start()/Stop() are thread-safe and may be called multiple times.
// After Stop(), Start() can be called again to restart.
//
class SunshinePipeServer {
public:
    explicit SunshinePipeServer(EncoderInput& encoderInput);
    ~SunshinePipeServer();

    SunshinePipeServer(const SunshinePipeServer&) = delete;
    SunshinePipeServer& operator=(const SunshinePipeServer&) = delete;
    SunshinePipeServer(SunshinePipeServer&&) = delete;
    SunshinePipeServer& operator=(SunshinePipeServer&&) = delete;

    /// Start the pipe server thread. Creates the named pipe and begins
    /// accepting CaptureHelper connections.
    /// Returns false if already running. Throws if thread creation fails.
    /// Safe to call multiple times — subsequent calls return false.
    [[nodiscard]] bool Start();

    /// Stop the pipe server, disconnect, and join the pipe thread.
    /// Idempotent. Safe to call from any state (including never-started).
    void Stop() noexcept;

    /// Register a callback invoked when FrameReady is received.
    /// Must be called before Start() to avoid data races.
    void SetFrameReadyCallback(FrameReadyCallback cb);

    /// Register a callback invoked when pipe state changes.
    /// Must be called before Start().
    void SetStateCallback(PipeStateCallback cb);

    /// Current state.
    [[nodiscard]] PipeState GetState() const noexcept;

    /// EncoderInput reference for initial setup (SetDevice before Start,
    /// drain/handle clearance during Stop).
    [[nodiscard]] EncoderInput& GetEncoderInput() noexcept;

    /// Last-received texture dimensions. Valid after SharedHandleInfo
    /// messages have been received.
    [[nodiscard]] std::pair<UINT, UINT> GetTextureSize() const noexcept;

    /// Send a StartStream command to CaptureHelper via the pipe.
    [[nodiscard]] bool SendStreamStart(HWND targetHwnd);

    /// Send a StopStream command to CaptureHelper via the pipe.
    [[nodiscard]] bool SendStreamStop();

private:
    // Pipe message handler (runs on pipe thread)
    void OnPipeMessage(SolStream::IPC::MessageType type,
                       std::span<const std::byte> payload,
                       std::uint32_t sequence);

    // Send Sunshine's PID to CaptureHelper for DuplicateHandle.
    bool SendSunshinePID();

    // Handle an incoming SharedHandleInfo message.
    void HandleSharedHandleInfo(std::span<const std::byte> payload);

    // Handle incoming FrameSizeChanged message.
    void HandleFrameSizeChanged(std::span<const std::byte> payload);

    // Transition state atomically and invoke state callback.
    void SetState(PipeState newState) noexcept;

    // Pipe thread entry point.
    void Run();

    // ── Members ──────────────────────────────────────────────────────────

    EncoderInput& m_encoder;
    SolStream::IPC::PipeServer m_pipeServer;

    // Atomic state with release/acquire ordering for cross-thread visibility.
    std::atomic<PipeState> m_state{PipeState::Disconnected};
    std::atomic<bool> m_running{false};

    std::thread m_pipeThread;

    // Callbacks — protected by a mutex because they are set by the owner
    // thread and read by the pipe thread. Best practice: set before Start(),
    // and never modify during execution.
    mutable std::mutex m_cbMutex;
    FrameReadyCallback m_frameReadyCb;
    PipeStateCallback m_stateCb;

    // Cached texture size (mutex-protected, updated from pipe thread,
    // read from encoder thread).
    mutable std::mutex m_sizeMutex;
    UINT m_textureWidth{1920};
    UINT m_textureHeight{1080};
    bool m_sizeValid{false};
};

} // namespace solstream
