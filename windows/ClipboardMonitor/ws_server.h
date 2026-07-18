#pragma once

/// @file ws_server.h
/// TLS TCP server on port 47991 for clipboard synchronization with the
/// macOS client. Uses Schannel (Windows built-in SSL) for TLS 1.3.
///
/// Thread safety: the server runs its own accept loop and spawns a
/// per-client read thread. Callbacks are invoked on the client thread.
/// The owning code must serialise access to shared clipboard state.

#include <Windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <schannel.h>
#include <security.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "clipboard_input_protocol.h"
#include "dedup.h"

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// ClipboardServer
// ══════════════════════════════════════════════════════════════════════════════
//
// Accepts clipboard connections from the macOS client.
// Uses a simple framed protocol over TLS 1.3:
//
//   [4 bytes: payload length (network order)]
//   [1 byte:  ClipboardFrameType]
//   [N bytes: payload]
//
class ClipboardServer {
public:
    using OnClipboardReceived = std::function<void(const ClipboardSnapshot&)>;

    ClipboardServer();
    ~ClipboardServer();

    ClipboardServer(const ClipboardServer&) = delete;
    ClipboardServer& operator=(const ClipboardServer&) = delete;

    /// Start the server. Creates the listening socket and accept thread.
    /// Returns false if socket creation or bind fails.
    bool Start(uint16_t port = kClipboardWSPort);

    /// Stop the server, close all connections, join thread.
    void Stop();

    /// Send a clipboard snapshot to all connected clients.
    /// The snapshot is serialised and sent as a ClipboardUpdate frame.
    void BroadcastClipboard(const ClipboardSnapshot& snapshot);

    /// Set the callback for received clipboard data (from macOS client).
    void SetReceiveCallback(OnClipboardReceived cb) { m_recvCb = std::move(cb); }

    /// Set the auth token. Connections must present this token to authenticate.
    void SetAuthToken(const std::string& token) { m_authToken = token; }

    /// Number of connected clients.
    [[nodiscard]] int ClientCount() const noexcept { return m_clientCount.load(std::memory_order_acquire); }

private:
    // Accept loop (runs on m_acceptThread).
    void AcceptLoop();

    // Client handler (runs on per-client thread).
    void ClientHandler(SOCKET clientSocket);

    // Remove a client socket from the active list.
    void RemoveClient(SOCKET sock);

    // TLS setup via Schannel on the listening socket.
    bool SetupServerTLS();

    // Send a framed message to a single client.
    bool SendFrame(SOCKET sock, ClipboardFrameType type,
                   const uint8_t* data, size_t len);

    // Receive a complete frame from a client.
    struct ReceivedFrame {
        ClipboardFrameType type;
        std::vector<uint8_t> payload;
    };
    [[nodiscard]] ReceivedFrame ReceiveFrame(SOCKET sock);

    // Serialize/deserialize clipboard snapshot to/from wire format.
    [[nodiscard]] std::vector<uint8_t> SerializeSnapshot(const ClipboardSnapshot& snap);
    [[nodiscard]] ClipboardSnapshot DeserializeSnapshot(const uint8_t* data, size_t len);

    // Validate auth token from an incoming connection.
    bool ValidateAuthToken(const std::vector<uint8_t>& tokenPayload);

    SOCKET m_listenSocket{INVALID_SOCKET};
    std::atomic<bool> m_running{false};
    std::thread m_acceptThread;

    // Active client sockets (mutex-protected).
    mutable std::mutex m_clientsMutex;
    std::vector<SOCKET> m_clientSockets;

    std::atomic<int> m_clientCount{0};
    std::string m_authToken;

    OnClipboardReceived m_recvCb;
    uint64_t m_nextOriginId{1};

    // TLS certificate context
    CredHandle m_schCred{};
    bool m_tlsInitialized{false};
};

} // namespace solstream::clipboard
