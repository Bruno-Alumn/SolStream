#include "pipe_transport.h"

#include <array>
#include <cstring>
#include <format>
#include <string>

namespace SolStream::IPC {

// ══════════════════════════════════════════════════════════════════════════════
// PipeException
// ══════════════════════════════════════════════════════════════════════════════

PipeException::PipeException(std::string_view msg, DWORD errorCode)
    : std::runtime_error(
          std::format("{} [error={}]", msg, errorCode)),
      m_errorCode(errorCode) {}

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

namespace {

std::wstring ToNullTerminated(std::wstring_view sv) {
    return std::wstring(sv);
}

constexpr DWORD kPipeOpenMode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
constexpr DWORD kPipeMode = PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT;
constexpr DWORD kPipeMaxInstances = 1;
constexpr DWORD kPipeBufferSize = 4096;

// Overlapped RAII helper for ConnectNamedPipe cancellation.
struct OverlappedHolder {
    OVERLAPPED ov{};
    WinHandle event;
    HANDLE pipeHandle{};

    OverlappedHolder(HANDLE pipe) : pipeHandle(pipe) {
        event = WinHandle(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        ov.hEvent = event.Get();
    }

    bool IsValid() const { return event.IsValid(); }

    // Wait until completed or stopEvent is signaled.
    DWORD Wait(HANDLE stopEvent) {
        HANDLE handles[2] = {ov.hEvent, stopEvent};
        return WaitForMultipleObjects(2, handles, FALSE, INFINITE);
    }

    // Get overlapped result.
    bool GetResult(DWORD& transferred) {
        return GetOverlappedResult(pipeHandle, &ov, &transferred, FALSE) != FALSE;
    }
};

} // anonymous namespace

// ══════════════════════════════════════════════════════════════════════════════
// PipeBase
// ══════════════════════════════════════════════════════════════════════════════

void PipeBase::CreateStopEvent() {
    WinHandle ev(CreateEventW(nullptr, TRUE, FALSE, nullptr));
    if (!ev.IsValid())
        throw PipeException("CreateStopEvent failed.", GetLastError());
    m_stopEvent = std::move(ev);
}

bool PipeBase::Send(MessageType type, std::span<const std::byte> payload) {
    if (!m_pipe.IsValid() || !m_connected.load(std::memory_order_acquire))
        return false;
    if (payload.size() > kMaxPayloadSize)
        return false;

    auto buf = BuildMessage(type, ++m_sequence, payload);

    DWORD written = 0;
    return WriteFile(m_pipe.Get(), buf.data(), static_cast<DWORD>(buf.size()),
                     &written, nullptr) != FALSE &&
           written == buf.size();
}

void PipeBase::RunReadLoop() {
    if (!m_pipe.IsValid())
        return;

    while (m_connected.load(std::memory_order_acquire)) {
        std::array<std::byte, kMaxFrameSize> buf{};

        DWORD bytesRead = 0;
        BOOL ok = ReadFile(m_pipe.Get(), buf.data(),
                           static_cast<DWORD>(buf.size()),
                           &bytesRead, nullptr);

        if (ok) {
            // Complete message received.
            if (bytesRead < sizeof(MessageHeader))
                continue;

            MessageHeader hdr{};
            std::memcpy(&hdr, buf.data(), sizeof(hdr));

            if (hdr.magic != kMagic)
                continue;
            if (hdr.payloadSize > kMaxPayloadSize)
                continue;
            // Validate declared payload matches actual bytes after header.
            if (hdr.payloadSize != bytesRead - sizeof(MessageHeader))
                continue;

            auto payload = std::span<const std::byte>(
                buf.data() + sizeof(MessageHeader),
                hdr.payloadSize);

            if (m_onMessage)
                m_onMessage(hdr.type, payload, hdr.sequence);

        } else {
            DWORD err = GetLastError();
            if (err == ERROR_BROKEN_PIPE ||
                err == ERROR_PIPE_NOT_CONNECTED ||
                err == ERROR_NO_DATA) {
                // Peer disconnected.
                break;
            }
            if (err == ERROR_MORE_DATA) {
                // Message larger than our buffer — drain and disconnect.
                std::array<std::byte, 4096> drainBuf;
                while (ReadFile(m_pipe.Get(), drainBuf.data(),
                                static_cast<DWORD>(drainBuf.size()),
                                &bytesRead, nullptr) == FALSE &&
                       GetLastError() == ERROR_MORE_DATA) {}
                break;
            }
            // Other error — exit loop.
            break;
        }
    }

    m_connected.store(false, std::memory_order_release);
}

// ══════════════════════════════════════════════════════════════════════════════
// PipeServer
// ══════════════════════════════════════════════════════════════════════════════

void PipeServer::Start(std::wstring_view pipeName, OnMessageFn onMessage) {
    if (m_pipe.IsValid())
        throw PipeException("PipeServer already started.", ERROR_ALREADY_EXISTS);

    m_onMessage = std::move(onMessage);
    CreateStopEvent();

    auto name = ToNullTerminated(pipeName);

    WinHandle pipe(CreateNamedPipeW(
        name.c_str(), kPipeOpenMode, kPipeMode,
        kPipeMaxInstances, kPipeBufferSize, kPipeBufferSize,
        0, nullptr));

    if (!pipe.IsValid())
        throw PipeException("CreateNamedPipeW failed.", GetLastError());

    // Wait for a client connection (overlapped so stop event works).
    OverlappedHolder ov(pipe.Get());
    if (!ov.IsValid())
        throw PipeException("CreateEventW failed.", GetLastError());

    BOOL connected = ConnectNamedPipe(pipe.Get(), &ov.ov);
    DWORD err = connected ? ERROR_SUCCESS : GetLastError();

    if (err == ERROR_IO_PENDING) {
        DWORD waitResult = ov.Wait(m_stopEvent.Get());
        if (waitResult == WAIT_OBJECT_0 + 1) {
            // Stop requested during accept.
            CancelIoEx(pipe.Get(), &ov.ov);
            // Wait for cancellation to complete.
            DWORD unused = 0;
            ov.GetResult(unused);
            return;
        }
        if (waitResult != WAIT_OBJECT_0)
            throw PipeException("WaitForMultipleObjects failed.", GetLastError());
        // Confirm connection succeeded.
        DWORD unused = 0;
        if (!ov.GetResult(unused))
            throw PipeException("ConnectNamedPipe failed.", GetLastError());
    } else if (err == ERROR_PIPE_CONNECTED) {
        // Client already connected.
    } else {
        throw PipeException("ConnectNamedPipe failed.", err);
    }

    m_pipe = std::move(pipe);
    m_sequence = 0;
    m_connected.store(true, std::memory_order_release);
}

void PipeServer::Stop() noexcept {
    m_connected.store(false, std::memory_order_release);
    RequestStop();
    if (m_pipe.IsValid()) {
        DisconnectNamedPipe(m_pipe.Get());
        m_pipe.Close();
    }
    m_stopEvent.Close();
    m_onMessage = nullptr;
}

// ══════════════════════════════════════════════════════════════════════════════
// PipeClient
// ══════════════════════════════════════════════════════════════════════════════

void PipeClient::Connect(std::wstring_view pipeName, OnMessageFn onMessage,
                          std::chrono::milliseconds timeout) {
    if (m_pipe.IsValid())
        throw PipeException("PipeClient already connected.", ERROR_ALREADY_EXISTS);

    m_onMessage = std::move(onMessage);
    CreateStopEvent();

    auto name = ToNullTerminated(pipeName);

    // Retry loop for transient server availability.
    auto deadline = std::chrono::steady_clock::now() + timeout;
    WinHandle pipe;
    DWORD lastError = ERROR_FILE_NOT_FOUND;

    while (std::chrono::steady_clock::now() < deadline) {
        pipe = WinHandle(CreateFileW(
            name.c_str(),
            GENERIC_READ | GENERIC_WRITE,
            0, nullptr, OPEN_EXISTING,
            0, nullptr));

        if (pipe.IsValid())
            break;

        lastError = GetLastError();
        if (lastError != ERROR_PIPE_BUSY && lastError != ERROR_FILE_NOT_FOUND)
            throw PipeException("CreateFileW failed.", lastError);

        // Wait briefly before retry.
        if (!WaitNamedPipeW(name.c_str(), 200))
            continue;
    }

    if (!pipe.IsValid())
        throw PipeException("PipeClient could not connect within timeout.", lastError);

    // Set message read mode.
    DWORD mode = PIPE_READMODE_MESSAGE;
    if (!SetNamedPipeHandleState(pipe.Get(), &mode, nullptr, nullptr)) {
        DWORD err = GetLastError();
        pipe.Close();
        throw PipeException("SetNamedPipeHandleState failed.", err);
    }

    m_pipe = std::move(pipe);
    m_sequence = 0;
    m_connected.store(true, std::memory_order_release);
}

void PipeClient::Disconnect() noexcept {
    m_connected.store(false, std::memory_order_release);
    RequestStop();
    m_pipe.Close();
    m_stopEvent.Close();
    m_onMessage = nullptr;
}

// ══════════════════════════════════════════════════════════════════════════════
// Free functions
// ══════════════════════════════════════════════════════════════════════════════

std::vector<std::byte> BuildMessage(
    MessageType type, std::uint32_t sequence, std::span<const std::byte> payload)
{
    if (payload.size() > kMaxPayloadSize)
        throw PipeException("BuildMessage: payload too large.", ERROR_INVALID_PARAMETER);

    MessageHeader hdr{};
    hdr.magic       = kMagic;
    hdr.type        = type;
    hdr.payloadSize = static_cast<std::uint32_t>(payload.size());
    hdr.sequence    = sequence;

    std::vector<std::byte> buf(sizeof(hdr) + payload.size());
    std::memcpy(buf.data(), &hdr, sizeof(hdr));
    if (!payload.empty())
        std::memcpy(buf.data() + sizeof(hdr), payload.data(), payload.size());

    return buf;
}

MessageHeader ParseHeader(std::span<const std::byte> buffer) {
    if (buffer.size() < sizeof(MessageHeader))
        throw PipeException("ParseHeader: buffer too small.", ERROR_INVALID_PARAMETER);

    MessageHeader hdr{};
    std::memcpy(&hdr, buffer.data(), sizeof(hdr));

    if (hdr.magic != kMagic)
        throw PipeException("ParseHeader: invalid magic.", ERROR_INVALID_DATA);

    return hdr;
}

// ══════════════════════════════════════════════════════════════════════════════
// Shared handle transfer helpers
// ══════════════════════════════════════════════════════════════════════════════

HANDLE DuplicateHandleForProcess(HANDLE localHandle, HANDLE targetProcessHandle) {
    if (!localHandle || localHandle == INVALID_HANDLE_VALUE)
        return nullptr;
    if (!targetProcessHandle || targetProcessHandle == INVALID_HANDLE_VALUE)
        return nullptr;

    HANDLE remoteHandle = nullptr;
    BOOL ok = DuplicateHandle(
        GetCurrentProcess(),
        localHandle,
        targetProcessHandle,
        &remoteHandle,
        0,           // dwDesiredAccess (ignored with DUPLICATE_SAME_ACCESS)
        FALSE,       // bInheritHandle
        DUPLICATE_SAME_ACCESS);

    if (!ok)
        return nullptr;

    return remoteHandle;
}

HANDLE DuplicateHandleForPID(HANDLE localHandle, DWORD targetPID) {
    if (!localHandle || localHandle == INVALID_HANDLE_VALUE)
        return nullptr;

    HANDLE targetProcess = OpenProcess(PROCESS_DUP_HANDLE, FALSE, targetPID);
    if (!targetProcess)
        return nullptr;

    HANDLE remoteHandle = DuplicateHandleForProcess(localHandle, targetProcess);
    CloseHandle(targetProcess);
    return remoteHandle;
}

Microsoft::WRL::ComPtr<ID3D11Texture2D> OpenSharedHandle(
    ID3D11Device* device, HANDLE sharedHandle)
{
    if (!device || !sharedHandle || sharedHandle == INVALID_HANDLE_VALUE)
        return nullptr;

    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    HRESULT hr = device->OpenSharedResource(sharedHandle, IID_PPV_ARGS(&texture));
    if (FAILED(hr))
        return nullptr;

    return texture;
}

} // namespace SolStream::IPC
