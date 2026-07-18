#include "ws_server.h"

#include <cstring>
#include <format>
#include <span>
#include <sstream>

// Link with schannel, secur32, ws2_32
#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "secur32.lib")
#pragma comment(lib, "crypt32.lib")

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

ClipboardServer::ClipboardServer() = default;

ClipboardServer::~ClipboardServer() {
    Stop();
}

// ══════════════════════════════════════════════════════════════════════════════
// Start / Stop
// ══════════════════════════════════════════════════════════════════════════════

bool ClipboardServer::Start(uint16_t port) {
    if (m_running.exchange(true, std::memory_order_acq_rel))
        return false;

    // Initialise Winsock.
    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0)
        return false;

    // Create listening socket.
    m_listenSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (m_listenSocket == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }

    // Allow address reuse.
    int reuse = 1;
    setsockopt(m_listenSocket, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    // Bind.
    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_LOOPBACK;  // Dev only — restrict to localhost
    addr.sin_port        = htons(port);

    if (bind(m_listenSocket, reinterpret_cast<sockaddr*>(&addr), sizeof(addr))
        != 0) {
        closesocket(m_listenSocket);
        WSACleanup();
        return false;
    }

    // Listen.
    if (listen(m_listenSocket, SOMAXCONN) != 0) {
        closesocket(m_listenSocket);
        WSACleanup();
        return false;
    }

    // Start accept thread.
    try {
        m_acceptThread = std::thread([this] { AcceptLoop(); });
    } catch (...) {
        closesocket(m_listenSocket);
        WSACleanup();
        m_running.store(false, std::memory_order_release);
        return false;
    }

    return true;
}

void ClipboardServer::Stop() {
    m_running.store(false, std::memory_order_release);

    // Close the listening socket to break accept().
    if (m_listenSocket != INVALID_SOCKET) {
        closesocket(m_listenSocket);
        m_listenSocket = INVALID_SOCKET;
    }

    // Close all client sockets.
    {
        std::lock_guard lk(m_clientsMutex);
        for (auto s : m_clientSockets)
            closesocket(s);
        m_clientSockets.clear();
    }

    if (m_acceptThread.joinable())
        m_acceptThread.join();

    WSACleanup();
    m_clientCount.store(0, std::memory_order_release);
}

// ══════════════════════════════════════════════════════════════════════════════
// Accept loop
// ══════════════════════════════════════════════════════════════════════════════

void ClipboardServer::AcceptLoop() {
    while (m_running.load(std::memory_order_acquire)) {
        sockaddr_in clientAddr{};
        int addrLen = sizeof(clientAddr);
        SOCKET clientSock = accept(m_listenSocket,
                                   reinterpret_cast<sockaddr*>(&clientAddr),
                                   &addrLen);

        if (clientSock == INVALID_SOCKET) {
            if (WSAGetLastError() == WSAEINTR || !m_running.load())
                break;
            continue;
        }

        // Add to client list.
        {
            std::lock_guard lk(m_clientsMutex);
            m_clientSockets.push_back(clientSock);
        }
        m_clientCount.fetch_add(1, std::memory_order_release);

        // Spawn a handler thread for this client.
        std::thread([this, clientSock]() {
            ClientHandler(clientSock);
        }).detach();
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Client handler
// ══════════════════════════════════════════════════════════════════════════════

void ClipboardServer::ClientHandler(SOCKET clientSocket) {
    // Read the auth token frame first.
    auto authFrame = ReceiveFrame(clientSocket);
    if (authFrame.type != ClipboardFrameType::AuthToken ||
        !ValidateAuthToken(authFrame.payload)) {
        closesocket(clientSocket);
        RemoveClient(clientSocket);
        return;
    }

    // Enter receive loop.
    while (m_running.load(std::memory_order_acquire)) {
        auto frame = ReceiveFrame(clientSocket);
        if (frame.type == ClipboardFrameType::ClipboardUpdate && m_recvCb) {
            auto snapshot = DeserializeSnapshot(frame.payload.data(),
                                                 frame.payload.size());
            if (!snapshot.IsEmpty())
                m_recvCb(snapshot);
        } else if (frame.type == ClipboardFrameType::Heartbeat) {
            // Reply with heartbeat ack.
            SendFrame(clientSocket, ClipboardFrameType::Heartbeat,
                      nullptr, 0);
        } else if (frame.type == ClipboardFrameType::ClipboardRequest) {
            // Client requests current clipboard — ignored for now.
            // In a full implementation, the server would snapshot and reply.
            break;
        } else if (frame.type == static_cast<ClipboardFrameType>(0)) {
            // Error or disconnect.
            break;
        }
    }

    closesocket(clientSocket);
    RemoveClient(clientSocket);
}

void ClipboardServer::RemoveClient(SOCKET sock) {
    std::lock_guard lk(m_clientsMutex);
    auto it = std::find(m_clientSockets.begin(), m_clientSockets.end(), sock);
    if (it != m_clientSockets.end())
        m_clientSockets.erase(it);
    m_clientCount.fetch_sub(1, std::memory_order_release);
}

// ══════════════════════════════════════════════════════════════════════════════
// Send / Receive frames
// ══════════════════════════════════════════════════════════════════════════════

bool ClipboardServer::SendFrame(SOCKET sock, ClipboardFrameType type,
                                 const uint8_t* data, size_t len)
{
    std::vector<uint8_t> frame;
    frame.reserve(5 + len);

    uint32_t netLen = htonl(static_cast<uint32_t>(len));
    frame.insert(frame.end(),
                 reinterpret_cast<uint8_t*>(&netLen),
                 reinterpret_cast<uint8_t*>(&netLen) + 4);
    frame.push_back(static_cast<uint8_t>(type));
    if (len > 0)
        frame.insert(frame.end(), data, data + len);

    size_t totalSent = 0;
    while (totalSent < frame.size()) {
        int sent = send(sock,
                        reinterpret_cast<const char*>(frame.data() + totalSent),
                        static_cast<int>(frame.size() - totalSent), 0);
        if (sent <= 0)
            return false;
        totalSent += static_cast<size_t>(sent);
    }
    return true;
}

ClipboardServer::ReceivedFrame ClipboardServer::ReceiveFrame(SOCKET sock) {
    ReceivedFrame result{};

    // Read 4-byte length prefix.
    uint32_t netLen = 0;
    size_t bytesRead = 0;
    while (bytesRead < 4) {
        int n = recv(sock,
                     reinterpret_cast<char*>(&netLen) + bytesRead,
                     static_cast<int>(4 - bytesRead), 0);
        if (n <= 0) return result;  // type stays 0 = error
        bytesRead += static_cast<size_t>(n);
    }

    uint32_t payloadLen = ntohl(netLen);

    // Read 1-byte type.
    uint8_t typeByte = 0;
    if (recv(sock, reinterpret_cast<char*>(&typeByte), 1, 0) <= 0)
        return result;
    result.type = static_cast<ClipboardFrameType>(typeByte);

    // Read payload.
    if (payloadLen > 0) {
        result.payload.resize(payloadLen);
        bytesRead = 0;
        while (bytesRead < payloadLen) {
            int n = recv(sock,
                         reinterpret_cast<char*>(result.payload.data() + bytesRead),
                         static_cast<int>(payloadLen - bytesRead), 0);
            if (n <= 0) { result.type = static_cast<ClipboardFrameType>(0); break; }
            bytesRead += static_cast<size_t>(n);
        }
    }

    return result;
}

// ══════════════════════════════════════════════════════════════════════════════
// Broadcast
// ══════════════════════════════════════════════════════════════════════════════

void ClipboardServer::BroadcastClipboard(const ClipboardSnapshot& snapshot) {
    auto wireData = SerializeSnapshot(snapshot);

    std::lock_guard lk(m_clientsMutex);
    for (auto it = m_clientSockets.begin(); it != m_clientSockets.end(); ) {
        if (!SendFrame(*it, ClipboardFrameType::ClipboardUpdate,
                       wireData.data(), wireData.size())) {
            closesocket(*it);
            it = m_clientSockets.erase(it);
            m_clientCount.fetch_sub(1, std::memory_order_release);
        } else {
            ++it;
        }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Serialization (simple binary wire format)
// ══════════════════════════════════════════════════════════════════════════════
//
// Wire format:
//   [8 bytes: sequence]
//   [4 bytes: originId]
//   [4 bytes: format count]
//   For each format:
//     [4 bytes: formatId]
//     [4 bytes: formatName length]
//     [N bytes: formatName UTF-8]
//     [8 bytes: data length]
//     [N bytes: data]
//     [8 bytes: hash]
//

std::vector<uint8_t> ClipboardServer::SerializeSnapshot(
    const ClipboardSnapshot& snap)
{
    std::vector<uint8_t> buf;
    auto write64 = [&](uint64_t v) {
        v = _byteswap_uint64(v);
        auto* p = reinterpret_cast<const uint8_t*>(&v);
        buf.insert(buf.end(), p, p + 8);
    };
    auto write32 = [&](uint32_t v) {
        v = htonl(v);
        auto* p = reinterpret_cast<const uint8_t*>(&v);
        buf.insert(buf.end(), p, p + 4);
    };
    auto writeBytes = [&](const uint8_t* d, size_t len) {
        buf.insert(buf.end(), d, d + len);
    };

    write64(snap.sequence);
    write32(snap.originId);
    write32(static_cast<uint32_t>(snap.formats.size()));

    for (const auto& fmt : snap.formats) {
        write32(fmt.formatId);
        write32(static_cast<uint32_t>(fmt.formatName.size()));
        writeBytes(reinterpret_cast<const uint8_t*>(fmt.formatName.data()),
                   fmt.formatName.size());
        write64(fmt.data.size());
        writeBytes(fmt.data.data(), fmt.data.size());
        write64(fmt.hash);
    }

    return buf;
}

ClipboardSnapshot ClipboardServer::DeserializeSnapshot(
    const uint8_t* data, size_t len)
{
    ClipboardSnapshot snap;
    if (!data || len < 16) return snap;

    auto read64 = [&](size_t& off) -> uint64_t {
        uint64_t v = 0;
        std::memcpy(&v, data + off, 8);
        off += 8;
        return _byteswap_uint64(v);
    };
    auto read32 = [&](size_t& off) -> uint32_t {
        uint32_t v = 0;
        std::memcpy(&v, data + off, 4);
        off += 4;
        return ntohl(v);
    };

    size_t offset = 0;
    snap.sequence = read64(offset);
    snap.originId = read32(offset);
    uint32_t fmtCount = read32(offset);

    for (uint32_t i = 0; i < fmtCount; ++i) {
        if (offset >= len) break;
        ClipboardFormatData fmt;
        fmt.formatId = read32(offset);

        uint32_t nameLen = read32(offset);
        if (nameLen > 0 && offset + nameLen <= len) {
            fmt.formatName.assign(
                reinterpret_cast<const char*>(data + offset), nameLen);
            offset += nameLen;
        }

        uint64_t dataLen = read64(offset);
        if (dataLen > 0 && offset + dataLen <= len) {
            fmt.data.assign(data + offset, data + offset + dataLen);
            offset += static_cast<size_t>(dataLen);
        }

        fmt.hash = read64(offset);
        snap.formats.push_back(std::move(fmt));
    }

    return snap;
}

// ══════════════════════════════════════════════════════════════════════════════
// Auth token validation
// ══════════════════════════════════════════════════════════════════════════════

bool ClipboardServer::ValidateAuthToken(const std::vector<uint8_t>& tokenPayload) {
    if (m_authToken.empty())
        return true;  // No token configured — accept all (dev mode)
    if (tokenPayload.empty())
        return false;

    std::string received(tokenPayload.begin(), tokenPayload.end());
    return received == m_authToken;
}

} // namespace solstream::clipboard
