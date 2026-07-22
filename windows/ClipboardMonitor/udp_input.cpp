#include "udp_input.h"

#include <bcrypt.h>
#include <cstring>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "ws2_32.lib")

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// ReplayWindow
// ══════════════════════════════════════════════════════════════════════════════

ReplayWindow::ReplayWindow() = default;

bool ReplayWindow::CheckAndRecord(uint64_t sequence) {
    if (sequence == 0)
        return false;

    if (sequence > m_lastSequence) {
        uint64_t diff = sequence - m_lastSequence;

        if (diff >= kReplayWindowSize) {
            // Sequence advanced beyond window — reset bitmap.
            m_bitmap = 0;
        } else {
            // Shift bitmap left by diff positions to make room for new sequence.
            // Bitmap bit 0 = m_lastSequence, bit N = m_lastSequence - N
            // When advancing by diff, shift left by diff to expire old entries.
            m_bitmap <<= diff;
        }

        // Set the bit for the new sequence (position 0 after shift).
        m_bitmap |= 1;

        m_lastSequence = sequence;
        return true;
    }

    // Sequence <= last: check if it's in the window.
    uint64_t diff = m_lastSequence - sequence;
    if (diff >= kReplayWindowSize)
        return false;  // Too old

    // Check if this bit is already set (replay).
    uint64_t bit = 1ULL << diff;
    if (m_bitmap & bit)
        return false;  // Replay

    // Record it.
    m_bitmap |= bit;
    return true;
}

void ReplayWindow::Reset() {
    m_lastSequence = 0;
    m_bitmap = 0;
}

// ══════════════════════════════════════════════════════════════════════════════
// InputReceiver
// ══════════════════════════════════════════════════════════════════════════════

InputReceiver::InputReceiver() = default;
InputReceiver::~InputReceiver() { Stop(); }

bool InputReceiver::Start(uint16_t port) {
    if (m_running.exchange(true, std::memory_order_acq_rel))
        return false;

    WSADATA wsaData{};
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0)
        return false;

    // Create UDP socket.
    m_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (m_sock == INVALID_SOCKET) {
        WSACleanup();
        return false;
    }

    // Allow address reuse.
    int reuse = 1;
    setsockopt(m_sock, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    // Bind to port 47990 (localhost only — dev mode).
    sockaddr_in addr{};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_LOOPBACK;  // Dev only
    addr.sin_port        = htons(port);

    if (bind(m_sock, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        closesocket(m_sock);
        WSACleanup();
        return false;
    }

    // Set receive timeout (100ms for responsive shutdown).
    DWORD timeout = 100;
    setsockopt(m_sock, SOL_SOCKET, SO_RCVTIMEO,
               reinterpret_cast<const char*>(&timeout), sizeof(timeout));

    // Start receive thread.
    try {
        m_recvThread = std::thread([this] { RecvLoop(); });
    } catch (...) {
        closesocket(m_sock);
        WSACleanup();
        m_running.store(false, std::memory_order_release);
        return false;
    }

    return true;
}

void InputReceiver::Stop() {
    m_running.store(false, std::memory_order_release);
    if (m_sock != INVALID_SOCKET) {
        closesocket(m_sock);
        m_sock = INVALID_SOCKET;
    }
    if (m_recvThread.joinable())
        m_recvThread.join();
    WSACleanup();
    m_packetCb = nullptr;
}

void InputReceiver::SetDecryptionKey(const uint8_t* key, size_t len) {
    if (len > m_key.size())
        len = m_key.size();
    std::memcpy(m_key.data(), key, len);
    m_keySet = true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Receive loop
// ══════════════════════════════════════════════════════════════════════════════

void InputReceiver::RecvLoop() {
    std::vector<uint8_t> buf(65535);

    while (m_running.load(std::memory_order_acquire)) {
        sockaddr_in sender{};
        int senderLen = sizeof(sender);

        int n = recvfrom(m_sock, reinterpret_cast<char*>(buf.data()),
                         static_cast<int>(buf.size()), 0,
                         reinterpret_cast<sockaddr*>(&sender), &senderLen);

        if (n <= 0) {
            if (WSAGetLastError() == WSAETIMEDOUT)
                continue;  // Timeout — check m_running
            break;
        }

        ProcessPacket(buf.data(), static_cast<size_t>(n));
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Packet processing
// ══════════════════════════════════════════════════════════════════════════════
//
// UDP packet wire format:
//   [12 bytes: nonce]
//   [N  bytes: AES-GCM ciphertext]
//   [16 bytes: authentication tag]
//
// Plaintext (after decryption):
//   [8  bytes: 64-bit sequence number]
//   [12 bytes: InputPacket]
//

bool InputReceiver::ProcessPacket(const uint8_t* data, size_t len) {
    if (!m_keySet || len < kAESGCMNonceSize + kAESGCMTagSize + 1)
        return false;

    // Minimum: nonce(12) + seq(8) + InputPacket(12) + tag(16) = 48
    if (len < kAESGCMNonceSize + 20 + kAESGCMTagSize)
        return false;

    const uint8_t* nonce     = data;
    const uint8_t* ciphertext = data + kAESGCMNonceSize;
    size_t ciphertextLen     = len - kAESGCMNonceSize - kAESGCMTagSize;
    const uint8_t* tag        = data + len - kAESGCMTagSize;

    // Decrypt using BCrypt (AES-GCM).
    // Note: For production use, the algorithm provider and key should be cached
    // and only regenerated when the session key changes, not per-packet.
    BCRYPT_ALG_HANDLE hAlgo = nullptr;
    BCryptOpenAlgorithmProvider(&hAlgo, BCRYPT_AES_ALGORITHM,
                                nullptr, 0);
    if (!hAlgo)
        return false;

    BCryptSetProperty(hAlgo, BCRYPT_CHAINING_MODE,
                      (PBYTE)BCRYPT_CHAIN_MODE_GCM,
                      sizeof(BCRYPT_CHAIN_MODE_GCM), 0);

    // Derive session key from shared key + nonce.
    BCRYPT_KEY_HANDLE hKey = nullptr;
    BCryptGenerateSymmetricKey(hAlgo, &hKey, nullptr, 0,
                                m_key.data(),
                                static_cast<ULONG>(m_key.size()), 0);

    if (!hKey) {
        BCryptCloseAlgorithmProvider(hAlgo, 0);
        return false;
    }

    // Prepare GCM authentication info.
    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO authInfo;
    BCRYPT_INIT_AUTH_MODE_INFO(authInfo);
    authInfo.pbNonce     = const_cast<PUCHAR>(nonce);
    authInfo.cbNonce     = kAESGCMNonceSize;
    authInfo.pbTag       = const_cast<PUCHAR>(tag);
    authInfo.cbTag       = kAESGCMTagSize;
    authInfo.pbAuthData  = nullptr;
    authInfo.cbAuthData  = 0;

    // Decrypt in place.
    std::vector<uint8_t> plaintext(ciphertextLen);
    ULONG plaintextLen = 0;

    NTSTATUS status = BCryptDecrypt(
        hKey,
        const_cast<PUCHAR>(ciphertext),
        static_cast<ULONG>(ciphertextLen),
        &authInfo,
        nullptr, 0,
        plaintext.data(),
        static_cast<ULONG>(plaintext.size()),
        &plaintextLen,
        0);

    BCryptDestroyKey(hKey);
    BCryptCloseAlgorithmProvider(hAlgo, 0);

    if (status != 0)
        return false;  // Authentication failure

    plaintext.resize(plaintextLen);

    // Parse sequence number and InputPacket.
    if (plaintext.size() < 8 + sizeof(InputPacket))
        return false;

    uint64_t sequence = 0;
    std::memcpy(&sequence, plaintext.data(), 8);

    // Replay window check.
    {
        std::lock_guard lk(m_replayMutex);
        if (!m_replayWindow.CheckAndRecord(sequence))
            return false;  // Replay or too old
    }

    InputPacket packet{};
    std::memcpy(&packet, plaintext.data() + 8, sizeof(packet));

    // Validate InputPacket before forwarding
    if (static_cast<uint8_t>(packet.type) == 0xFF) {
        return false;  // Invalid MessageType 0xFF
    }

    ForwardPacket(packet, sequence);
    return true;
}

void InputReceiver::ForwardPacket(const InputPacket& packet, uint64_t sequence) {
    if (m_packetCb)
        m_packetCb(packet);
}

} // namespace solstream::clipboard
