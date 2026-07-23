#pragma once

/// @file udp_input.h
/// UDP socket on port 47990 receiving encrypted input packets from the
/// macOS client. Performs AES-GCM decryption, replay-window validation,
/// and forwards decrypted InputPackets to InputInjector via named pipe.
///
/// Thread safety: the UDP receive loop runs on its own thread. The
/// forwarding callback is invoked on that thread.

#include <Windows.h>
#include <bcrypt.h>
#include <winsock2.h>

#include <atomic>
#include <array>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace solstream::clipboard {

#include "clipboard_input_protocol.h"

// ══════════════════════════════════════════════════════════════════════════════
// ReplayWindow
// ══════════════════════════════════════════════════════════════════════════════
//
// Sliding-window replay protection for UDP sequence numbers.
// Tracks the last kReplayWindowSize sequence numbers and rejects
// duplicates or out-of-window packets.
//
class ReplayWindow {
public:
    ReplayWindow();

    /// Check and record a sequence number.
    /// Returns true if the sequence is new and within the window.
    [[nodiscard]] bool CheckAndRecord(uint64_t sequence);

    /// Reset the window (on session change).
    void Reset();

private:
    uint64_t m_lastSequence{};
    uint64_t m_bitmap{};  ///< Bits 0..63 correspond to seq (last-n) .. last
};

// ══════════════════════════════════════════════════════════════════════════════
// InputReceiver
// ══════════════════════════════════════════════════════════════════════════════
//
// Receives UDP packets, decrypts with AES-GCM, validates with replay
// window, and forwards to InputInjector.
//
class InputReceiver {
public:
    using OnInputPacket = std::function<void(const InputPacket&)>;

    InputReceiver();
    ~InputReceiver();

    InputReceiver(const InputReceiver&) = delete;
    InputReceiver& operator=(const InputReceiver&) = delete;

    /// Start the UDP receiver on port kInputUDPPort.
    /// Returns false if socket creation fails.
    bool Start(uint16_t port = kInputUDPPort);

    /// Stop the receiver and join the thread.
    void Stop();

    /// Set the callback for decrypted input packets.
    void SetPacketCallback(OnInputPacket cb) { m_packetCb = std::move(cb); }

    /// Set the AES-256 key for decryption (32 bytes).
    void SetDecryptionKey(const uint8_t* key, size_t len);

private:
    // Receive loop (runs on m_recvThread).
    void RecvLoop();

    // Decrypt and validate a received UDP packet.
    // Returns true if the packet is authentic and forwarded.
    bool ProcessPacket(const uint8_t* data, size_t len);

    // Forward decrypted InputPacket to the callback.
    void ForwardPacket(const InputPacket& packet, uint64_t sequence);

    SOCKET m_sock{INVALID_SOCKET};
    std::atomic<bool> m_running{false};
    std::thread m_recvThread;

    // AES-GCM key (32 bytes)
    std::array<uint8_t, kAESGCMKeySize> m_key{};
    bool m_keySet{false};

    // Cached BCrypt handles (initialized once, reused per packet)
    BCRYPT_ALG_HANDLE m_hAlgo{nullptr};
    BCRYPT_KEY_HANDLE m_hKey{nullptr};

    // Replay protection
    ReplayWindow m_replayWindow;
    std::mutex m_replayMutex;

    OnInputPacket m_packetCb;
};

} // namespace solstream::clipboard
