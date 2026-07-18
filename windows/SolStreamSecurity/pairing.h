#pragma once

/// @file pairing.h
/// Secure pairing between macOS client and Sunshine server.
/// PIN exchange → cert fingerprint pinning → session token.
///
/// Thread safety: PairingManager is not thread-safe. All calls must be
/// serialised externally.

#include <Windows.h>
#include <bcrypt.h>
#include <array>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <unordered_map>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

namespace solstream::security {

// ── Constants ───────────────────────────────────────────────────────────────

constexpr uint32_t kSessionTokenBytes  = 64;
constexpr uint32_t kCertFingerprintBytes = 32;  // SHA-256
constexpr uint32_t kPinLength           = 4;
constexpr uint32_t kAESGCMKeySize       = 32;
constexpr uint32_t kAESGCMNonceSize     = 12;

// ── Types ───────────────────────────────────────────────────────────────────

using CertFingerprint = std::array<uint8_t, kCertFingerprintBytes>;
using SessionToken    = std::array<uint8_t, kSessionTokenBytes>;

/// Client registration (stored after successful pairing).
struct PairedClient {
    CertFingerprint fingerprint{};  ///< SHA-256 of client TLS cert
    SessionToken    token{};        ///< Current session token
    uint64_t        pairedAt{};     ///< Steady clock timestamp
    uint64_t        lastUsed{};     ///< Last activity timestamp
    bool            active{true};   ///< False after re-pair invalidates
};

// ══════════════════════════════════════════════════════════════════════════════
// PairingManager
// ══════════════════════════════════════════════════════════════════════════════
//
class PairingManager {
public:
    PairingManager();
    ~PairingManager();

    PairingManager(const PairingManager&) = delete;
    PairingManager& operator=(const PairingManager&) = delete;

    // ── PIN generation ───────────────────────────────────────────────────

    /// Generate a 4-digit PIN for the current pairing session.
    /// The PIN is valid for kPinTimeoutMs milliseconds.
    [[nodiscard]] std::string GeneratePIN();

    /// Get the current PIN (empty if none active).
    [[nodiscard]] std::string GetCurrentPIN() const;

    // ── Pairing ───────────────────────────────────────────────────────────

    /// Attempt to pair using the given PIN and client cert fingerprint.
    /// The PIN is compared against the current valid PIN.
    /// On success, generates a session token and stores the client.
    /// @return true if pairing succeeded.
    bool PairWithPIN(const std::string& pin,
                     const CertFingerprint& clientFingerprint);

    /// Check if a client cert fingerprint is already paired.
    [[nodiscard]] bool IsPaired(const CertFingerprint& fingerprint) const;

    /// Invalidate all sessions for a client (on re-pair).
    void InvalidateClient(const CertFingerprint& fingerprint);

    // ── Session tokens ───────────────────────────────────────────────────

    /// Issue a new session token for a paired client.
    [[nodiscard]] SessionToken IssueToken(
        const CertFingerprint& fingerprint);

    /// Validate a session token and return the client fingerprint.
    /// Returns nullopt if the token is invalid or expired.
    [[nodiscard]] std::optional<CertFingerprint> ValidateToken(
        const SessionToken& token) const;

    /// Invalidate all tokens (on server restart or security event).
    void InvalidateAllTokens();

    // ── Certificate storage ──────────────────────────────────────────────

    /// Save the server's own TLS cert fingerprint for display.
    void SetServerFingerprint(const CertFingerprint& fp);
    [[nodiscard]] CertFingerprint GetServerFingerprint() const;

    /// Persist paired clients to encrypted storage.
    bool SaveToStorage(const std::wstring& filePath) const;

    /// Load paired clients from storage.
    bool LoadFromStorage(const std::wstring& filePath);

private:
    // Current PIN
    std::string m_currentPIN;
    uint64_t m_pinGeneratedAt{};

    // PIN timeout (5 minutes)
    static constexpr uint64_t kPinTimeoutMs = 300'000;

    // Server's own cert fingerprint
    CertFingerprint m_serverFingerprint{};

    // Registered clients
    std::unordered_map<std::string, PairedClient> m_clients;  // key = hex fingerprint

    mutable std::mutex m_mutex;

    // Token-to-fingerprint reverse lookup
    mutable std::unordered_map<uint64_t, std::string> m_tokenLookup;

    /// Generate cryptographically random bytes.
    static std::vector<uint8_t> RandomBytes(size_t count);

    /// Compute SHA-256 hash.
    static CertFingerprint SHA256(std::span<const uint8_t> data);

    /// Fingerprint to hex string.
    static std::string FingerprintToHex(const CertFingerprint& fp);
    static CertFingerprint HexToFingerprint(const std::string& hex);

    /// Token to 64-bit key for reverse lookup.
    static uint64_t TokenKey(const SessionToken& token);
};

} // namespace solstream::security
