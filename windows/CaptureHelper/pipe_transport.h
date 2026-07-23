#pragma once

#include <Windows.h>
#include <NamedPipeapi.h>
#include <aclapi.h>
#include <d3d11.h>
#include <sddl.h>
#include <wrl/client.h>

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace SolStream::IPC {

// ── Constants ───────────────────────────────────────────────────────────────

constexpr std::size_t kMaxPayloadSize = 4096;
constexpr auto kDefaultTimeout = std::chrono::milliseconds(5000);

static constexpr std::wstring_view kPipeName = L"\\.\\pipe\\SolStream_CaptureHelper";

// ── Message protocol ────────────────────────────────────────────────────────

enum class MessageType : std::uint32_t {
    // CaptureHelper → Sunshine (0x01-0x0F)
    FrameReady        = 0x01,
    AdapterInfo       = 0x02,
    CaptureStopped    = 0x03,
    Heartbeat         = 0x04,
    SharedHandleInfo  = 0x05,  // Shared texture handle + slot index
    HandleAck         = 0x06,  // Confirmation handle received and opened
    StreamStarted     = 0x07,  // Capture session is running
    StreamStopped     = 0x08,  // Capture session stopped
    FrameSizeChanged  = 0x09,  // Window resize detected, new dimensions

    // Sunshine → CaptureHelper (0x81-0x8F)
    Quit              = 0x80,
    StartStream       = 0x81,
    StopStream        = 0x82,
    ResizeNotify      = 0x85,  // Encoder drained, ready for pool recreate
    SunshinePID       = 0x86,  // Sunshine's PID (for DuplicateHandle target)
};

#pragma pack(push, 1)
struct MessageHeader {
    std::uint32_t magic;
    MessageType   type;
    std::uint32_t payloadSize;  // 0 = no payload
    std::uint32_t sequence;
};
static_assert(sizeof(MessageHeader) == 16, "MessageHeader must be 16 bytes");
#pragma pack(pop)

constexpr std::uint32_t kMagic = 0x534F4C53;  // "SOLS"
constexpr std::size_t kMaxFrameSize = sizeof(MessageHeader) + kMaxPayloadSize;

// ── Exceptions ──────────────────────────────────────────────────────────────

class PipeException final : public std::runtime_error {
public:
    PipeException(std::string_view msg, DWORD errorCode);
    [[nodiscard]] DWORD ErrorCode() const noexcept { return m_errorCode; }
private:
    DWORD m_errorCode;
};

// ── RAII handle wrapper ─────────────────────────────────────────────────────

class WinHandle {
public:
    WinHandle() noexcept = default;
    explicit WinHandle(HANDLE h) noexcept : m_handle(h) {}
    ~WinHandle() noexcept { Close(); }

    WinHandle(const WinHandle&) = delete;
    WinHandle& operator=(const WinHandle&) = delete;
    WinHandle(WinHandle&& other) noexcept : m_handle(std::exchange(other.m_handle, nullptr)) {}
    WinHandle& operator=(WinHandle&& other) noexcept {
        if (this != &other) { Close(); m_handle = std::exchange(other.m_handle, nullptr); }
        return *this;
    }

    [[nodiscard]] HANDLE Get() const noexcept { return m_handle; }
    [[nodiscard]] bool IsValid() const noexcept { return m_handle != nullptr && m_handle != INVALID_HANDLE_VALUE; }
    void Close() noexcept { if (IsValid()) { CloseHandle(m_handle); } m_handle = nullptr; }

private:
    HANDLE m_handle{};
};

// ── Pipe base (common client/server logic) ──────────────────────────────────

class PipeBase {
public:
    using OnMessageFn = std::function<void(MessageType type,
                                            std::span<const std::byte> payload,
                                            std::uint32_t sequence)>;

    PipeBase() = default;
    virtual ~PipeBase() noexcept = default;

    PipeBase(const PipeBase&) = delete;
    PipeBase& operator=(const PipeBase&) = delete;
    PipeBase(PipeBase&&) = delete;
    PipeBase& operator=(PipeBase&&) = delete;

    [[nodiscard]] bool IsConnected() const noexcept { return m_connected.load(std::memory_order_acquire); }

    /// Send a message. Returns false on error (disconnect/pipe error).
    [[nodiscard]] bool Send(MessageType type, std::span<const std::byte> payload = {});

    /// Blocking read loop: reads messages from the pipe and dispatches to
    /// the callback. Returns when the peer disconnects, StopRequest() is set,
    /// or a fatal error occurs.
    void RunReadLoop();

    /// Signal the read loop to exit. Can be called from any thread.
    void RequestStop() noexcept { if (m_stopEvent.IsValid()) SetEvent(m_stopEvent.Get()); }

protected:
    WinHandle m_pipe;
    WinHandle m_stopEvent;  // auto-reset event, set by RequestStop()
    std::atomic<bool> m_connected{false};
    OnMessageFn m_onMessage;
    std::uint32_t m_sequence{};

    /// Create the stop event used to interrupt RunReadLoop.
    void CreateStopEvent();
};

// ── Pipe server ─────────────────────────────────────────────────────────────

class PipeServer : public PipeBase {
public:
    PipeServer() = default;

    /// Create the named pipe and begin waiting for a client connection.
    void Start(std::wstring_view pipeName = kPipeName, OnMessageFn onMessage = nullptr);

    /// Stop waiting for connection and close the pipe.
    void Stop() noexcept;
};

// ── Pipe client ─────────────────────────────────────────────────────────────

class PipeClient : public PipeBase {
public:
    PipeClient() = default;

    /// Connect to an existing server pipe.
    void Connect(std::wstring_view pipeName = kPipeName, OnMessageFn onMessage = nullptr,
                 std::chrono::milliseconds timeout = kDefaultTimeout);

    /// Disconnect from the server.
    void Disconnect() noexcept;
};

// ── Free functions ──────────────────────────────────────────────────────────

[[nodiscard]] std::vector<std::byte> BuildMessage(
    MessageType type, std::uint32_t sequence, std::span<const std::byte> payload);

// ── Shared handle transfer ───────────────────────────────────────────────────
//
// Shared-texture HANDLEs cannot be marshalled directly over a named pipe
// because handles are process-local. The workflow:
//   1. CaptureHelper calls ID3D11Device::GetSharedHandle() on a keyed-mutex
//      texture to get a process-local HANDLE.
//   2. CaptureHelper calls DuplicateHandle(GetCurrentProcess(), localHandle,
//      sunshineProcessHandle, &remoteHandle, 0, FALSE, DUPLICATE_SAME_ACCESS)
//      to create a handle valid in Sunshine's process context.
//   3. The remote-valid handle value is packed into SharedHandlePayload and
//      sent over the named pipe as a SharedHandleInfo message.
//   4. Sunshine receives the handle value and calls
//      ID3D11Device::OpenSharedResource(remoteHandle, ...) to obtain the
//      shared texture.
//
// The sunshine process handle is obtained when CaptureHelper receives a
// SunshinePID message from Sunshine during initial handshake.

#pragma pack(push, 1)
struct SharedHandlePayload {
    std::uint32_t slotIndex;         // Which ring slot this handle belongs to (0-2)
    std::uint64_t handleValue;       // Handle valid in Sunshine's process (from DuplicateHandle)
    std::int32_t  textureWidth;      // Current texture width in pixels
    std::int32_t  textureHeight;     // Current texture height in pixels
    std::uint32_t adapterLuidLow;    // DXGI adapter LUID low part (for verification)
    std::int32_t  adapterLuidHigh;   // DXGI adapter LUID high part
};
static_assert(sizeof(SharedHandlePayload) == 28,
    "SharedHandlePayload must be 28 bytes");
#pragma pack(pop)

/// Duplicate a shared-texture handle from the current process into the
/// target process identified by targetProcessHandle.
/// Returns the handle value valid in the target process, or nullptr on failure.
[[nodiscard]] HANDLE DuplicateHandleForProcess(
    HANDLE localHandle, HANDLE targetProcessHandle);

} // namespace SolStream::IPC
