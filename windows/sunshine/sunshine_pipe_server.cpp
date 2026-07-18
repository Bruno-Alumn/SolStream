#include "sunshine_pipe_server.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <mutex>
#include <thread>
#include <utility>

// Namespace alias at file scope (NOT inside a function).
namespace ipc = SolStream::IPC;

namespace solstream {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

SunshinePipeServer::SunshinePipeServer(EncoderInput& encoderInput)
    : m_encoder(encoderInput)
{
}

SunshinePipeServer::~SunshinePipeServer() {
    Stop();
}

// ══════════════════════════════════════════════════════════════════════════════
// Start / Stop
// ══════════════════════════════════════════════════════════════════════════════
//
// NOTE on thread safety:
//   Start/Stop must NOT be called concurrently. The header claims thread
//   safety for single-threaded callers (guarded by m_running atomic), but
//   concurrent Start+Start or Start+Stop races on m_pipeThread assignment.
//   In practice, the owning Sunshine thread calls Start once at init and
//   Stop once at shutdown — no concurrent access.

bool SunshinePipeServer::Start() {
    bool expected = false;
    if (!m_running.compare_exchange_strong(expected, true,
                                           std::memory_order_acq_rel,
                                           std::memory_order_relaxed))
        return false;

    // If a previous thread still exists (shouldn't happen after Stop()),
    // ensure it's fully joined before creating a new one.
    if (m_pipeThread.joinable())
        m_pipeThread.join();

    try {
        m_pipeThread = std::thread([this] { Run(); });
    } catch (...) {
        m_running.store(false, std::memory_order_release);
        throw;
    }
    return true;
}

void SunshinePipeServer::Stop() noexcept {
    m_running.store(false, std::memory_order_release);
    m_pipeServer.RequestStop();
    m_pipeServer.Stop();

    if (m_pipeThread.joinable())
        m_pipeThread.join();

    SetState(PipeState::Disconnected);

    // Clear callbacks under the mutex.
    {
        std::lock_guard lk(m_cbMutex);
        m_frameReadyCb = nullptr;
        m_stateCb = nullptr;
    }

    // Reset EncoderInput so a new connection starts clean.
    m_encoder.Reset();
}

// ══════════════════════════════════════════════════════════════════════════════
// Callbacks
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::SetFrameReadyCallback(FrameReadyCallback cb) {
    std::lock_guard lk(m_cbMutex);
    m_frameReadyCb = std::move(cb);
}

void SunshinePipeServer::SetStateCallback(PipeStateCallback cb) {
    std::lock_guard lk(m_cbMutex);
    m_stateCb = std::move(cb);
}

// ══════════════════════════════════════════════════════════════════════════════
// Accessors
// ══════════════════════════════════════════════════════════════════════════════

PipeState SunshinePipeServer::GetState() const noexcept {
    return m_state.load(std::memory_order_acquire);
}

EncoderInput& SunshinePipeServer::GetEncoderInput() noexcept {
    return m_encoder;
}

std::pair<UINT, UINT> SunshinePipeServer::GetTextureSize() const noexcept {
    std::lock_guard lk(m_sizeMutex);
    return {m_textureWidth, m_textureHeight};
}

// ══════════════════════════════════════════════════════════════════════════════
// State management
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::SetState(PipeState newState) noexcept {
    m_state.store(newState, std::memory_order_release);

    // Copy the callback under the lock, invoke outside it.
    PipeStateCallback cb;
    {
        std::lock_guard lk(m_cbMutex);
        cb = m_stateCb;
    }
    if (cb) {
        try {
            cb(newState);
        } catch (...) {
            // Swallow callback exceptions — pipe thread must survive.
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Pipe thread
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::Run() {
    int reconnectAttempts = 0;

    while (m_running.load(std::memory_order_acquire)) {
        SetState(PipeState::Connecting);

        auto onMsg = [this](ipc::MessageType type,
                            std::span<const std::byte> payload,
                            std::uint32_t sequence) {
            try {
                OnPipeMessage(type, payload, sequence);
            } catch (...) {
                // Swallow — pipe thread must survive.
            }
        };

        try {
            m_pipeServer.Start(ipc::kPipeName, std::move(onMsg));
        } catch (ipc::PipeException const&) {
            if (!m_running.load(std::memory_order_acquire))
                return;
            ++reconnectAttempts;
            if (reconnectAttempts >= kMaxReconnectAttempts) {
                SetState(PipeState::Error);
                return;
            }
            std::this_thread::sleep_for(kReconnectDelay);
            continue;
        }

        if (!m_running.load(std::memory_order_acquire)) {
            m_pipeServer.Stop();
            return;
        }

        // Reset reconnect counter on connection.
        reconnectAttempts = 0;

        // Send our PID.
        if (!SendSunshinePID()) {
            m_pipeServer.Stop();
            SetState(PipeState::Error);
            return;
        }

        SetState(PipeState::Handshaking);

        // Run the read loop (blocks until disconnect or stop).
        m_pipeServer.RunReadLoop();

        // Disconnected.
        SetState(PipeState::Disconnected);
        m_pipeServer.Stop();

        if (!m_running.load(std::memory_order_acquire))
            return;

        ++reconnectAttempts;
        if (reconnectAttempts >= kMaxReconnectAttempts) {
            SetState(PipeState::Error);
            return;
        }
        std::this_thread::sleep_for(kReconnectDelay);
    }
}

bool SunshinePipeServer::SendSunshinePID() {
    DWORD pid = GetCurrentProcessId();
    std::array<std::byte, sizeof(pid)> payload{};
    std::memcpy(payload.data(), &pid, sizeof(pid));
    return m_pipeServer.Send(ipc::MessageType::SunshinePID, payload);
}

// ══════════════════════════════════════════════════════════════════════════════
// Message handler (runs on pipe thread)
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::OnPipeMessage(
    ipc::MessageType type,
    std::span<const std::byte> payload,
    std::uint32_t /*sequence*/)
{
    switch (type) {
    case ipc::MessageType::AdapterInfo:
        SetState(PipeState::Connected);
        break;

    case ipc::MessageType::SharedHandleInfo:
        HandleSharedHandleInfo(payload);
        break;

    case ipc::MessageType::FrameReady:
        // Copy callback under lock, invoke outside.
        {
            FrameReadyCallback cb;
            {
                std::lock_guard lk(m_cbMutex);
                cb = m_frameReadyCb;
            }
            if (cb) {
                try {
                    cb();
                } catch (...) {
                    // Swallow.
                }
            }
        }
        break;

    case ipc::MessageType::StreamStarted:
        SetState(PipeState::Streaming);
        break;

    case ipc::MessageType::StreamStopped:
        SetState(PipeState::Connected);
        break;

    case ipc::MessageType::CaptureStopped:
        SetState(PipeState::Connected);
        break;

    case ipc::MessageType::FrameSizeChanged:
        HandleFrameSizeChanged(payload);
        break;

    case ipc::MessageType::Heartbeat:
        break;

    default:
        break;
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Handle transfer
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::HandleSharedHandleInfo(std::span<const std::byte> payload) {
    if (payload.size() != sizeof(ipc::SharedHandlePayload))
        return;

    ipc::SharedHandlePayload shp{};
    std::memcpy(&shp, payload.data(), sizeof(shp));

    // Validate dimensions.
    if (shp.textureWidth <= 0 || shp.textureHeight <= 0 ||
        shp.textureWidth > 16384 || shp.textureHeight > 16384)
        return;

    // Validate handle value.
    HANDLE remoteHandle = reinterpret_cast<HANDLE>(
        static_cast<std::uintptr_t>(shp.handleValue));
    if (!remoteHandle || remoteHandle == INVALID_HANDLE_VALUE)
        return;

    // Import into the encoder input.
    int slotIndex = m_encoder.ImportHandle(remoteHandle);
    if (slotIndex < 0) {
        // All slots full — log and close.
        CloseHandle(remoteHandle);
        return;
    }

    // Cache texture size.
    {
        std::lock_guard lk(m_sizeMutex);
        m_textureWidth  = static_cast<UINT>(shp.textureWidth);
        m_textureHeight = static_cast<UINT>(shp.textureHeight);
        m_sizeValid = true;
    }

    // Send acknowledgement with the local slot index.
    std::array<std::byte, sizeof(int)> ack{};
    std::memcpy(ack.data(), &slotIndex, sizeof(slotIndex));
    m_pipeServer.Send(ipc::MessageType::HandleAck, ack);
}

// ══════════════════════════════════════════════════════════════════════════════
// Resize handling
// ══════════════════════════════════════════════════════════════════════════════

void SunshinePipeServer::HandleFrameSizeChanged(std::span<const std::byte> payload) {
    if (payload.size() < sizeof(int32_t) * 2)
        return;

    int32_t newWidth  = 0;
    int32_t newHeight = 0;
    std::memcpy(&newWidth,  payload.data(),                     sizeof(newWidth));
    std::memcpy(&newHeight, payload.data() + sizeof(newWidth),  sizeof(newHeight));

    if (newWidth <= 0 || newHeight <= 0 || newWidth > 16384 || newHeight > 16384)
        return;

    {
        std::lock_guard lk(m_sizeMutex);
        m_textureWidth  = static_cast<UINT>(newWidth);
        m_textureHeight = static_cast<UINT>(newHeight);
    }

    // Notify CaptureHelper that encoder is ready for pool recreate.
    m_pipeServer.Send(ipc::MessageType::ResizeNotify);
}

// ══════════════════════════════════════════════════════════════════════════════
// Public command methods (called from API handler threads)
// ══════════════════════════════════════════════════════════════════════════════

bool SunshinePipeServer::SendStreamStart(HWND targetHwnd) {
    if (!m_pipeServer.IsConnected())
        return false;

    std::array<std::byte, sizeof(HWND)> payload{};
    std::memcpy(payload.data(), &targetHwnd, sizeof(targetHwnd));
    return m_pipeServer.Send(ipc::MessageType::StartStream, payload);
}

bool SunshinePipeServer::SendStreamStop() {
    if (!m_pipeServer.IsConnected())
        return false;
    return m_pipeServer.Send(ipc::MessageType::StopStream);
}

} // namespace solstream
