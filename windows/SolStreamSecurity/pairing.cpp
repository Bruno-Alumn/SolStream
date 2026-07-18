#include "pairing.h"

#include <algorithm>
#include <charconv>
#include <cstring>
#include <format>
#include <fstream>
#include <span>
#include <sstream>

namespace solstream::security {

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

std::vector<uint8_t> PairingManager::RandomBytes(size_t count) {
    std::vector<uint8_t> buf(count);
    BCRYPT_ALG_HANDLE hAlgo{};
    if (BCryptOpenAlgorithmProvider(&hAlgo, BCRYPT_RNG_ALGORITHM,
                                     nullptr, 0) != 0)
        return {};
    BCryptGenRandom(hAlgo, buf.data(), (ULONG)buf.size(), 0);
    BCryptCloseAlgorithmProvider(hAlgo, 0);
    return buf;
}

CertFingerprint PairingManager::SHA256(std::span<const uint8_t> data) {
    CertFingerprint result{};
    BCRYPT_ALG_HANDLE hAlgo{};
    if (BCryptOpenAlgorithmProvider(&hAlgo, BCRYPT_SHA256_ALGORITHM,
                                     nullptr, 0) != 0)
        return result;

    BCryptHash(hAlgo, nullptr, 0,
               const_cast<PUCHAR>(data.data()), (ULONG)data.size(),
               result.data(), (ULONG)result.size());
    BCryptCloseAlgorithmProvider(hAlgo, 0);
    return result;
}

std::string PairingManager::FingerprintToHex(const CertFingerprint& fp) {
    std::string hex;
    hex.reserve(fp.size() * 2);
    for (auto b : fp)
        hex += std::format("{:02x}", b);
    return hex;
}

CertFingerprint PairingManager::HexToFingerprint(const std::string& hex) {
    CertFingerprint fp{};
    if (hex.size() != fp.size() * 2)
        return fp;
    for (size_t i = 0; i < fp.size(); ++i) {
        unsigned int val = 0;
        std::from_chars(hex.data() + i * 2, hex.data() + i * 2 + 2, val, 16);
        fp[i] = static_cast<uint8_t>(val);
    }
    return fp;
}

uint64_t PairingManager::TokenKey(const SessionToken& token) {
    uint64_t key = 0;
    std::memcpy(&key, token.data(), sizeof(key));
    return key;
}

// ══════════════════════════════════════════════════════════════════════════════
// Construction
// ══════════════════════════════════════════════════════════════════════════════

PairingManager::PairingManager() = default;
PairingManager::~PairingManager() = default;

// ══════════════════════════════════════════════════════════════════════════════
// PIN management
// ══════════════════════════════════════════════════════════════════════════════

std::string PairingManager::GeneratePIN() {
    std::lock_guard lk(m_mutex);

    // Generate 4 random decimal digits.
    auto bytes = RandomBytes(2);
    if (bytes.size() < 2) {
        m_currentPIN = "0000";
    } else {
        uint16_t val = (static_cast<uint16_t>(bytes[0]) << 8) | bytes[1];
        val %= 10000;
        m_currentPIN = std::format("{:04d}", val);
    }

    m_pinGeneratedAt = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    return m_currentPIN;
}

std::string PairingManager::GetCurrentPIN() const {
    std::lock_guard lk(m_mutex);

    // Check timeut.
    auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now - m_pinGeneratedAt > kPinTimeoutMs)
        return {};

    return m_currentPIN;
}

// ══════════════════════════════════════════════════════════════════════════════
// Pairing
// ══════════════════════════════════════════════════════════════════════════════

bool PairingManager::PairWithPIN(const std::string& pin,
                                  const CertFingerprint& clientFingerprint)
{
    std::lock_guard lk(m_mutex);

    // Verify PIN.
    if (pin.empty() || m_currentPIN.empty() || pin != m_currentPIN)
        return false;

    // Check PIN timeout.
    auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now - m_pinGeneratedAt > kPinTimeoutMs)
        return false;

    // Invalidate any existing session for this client.
    std::string key = FingerprintToHex(clientFingerprint);
    auto it = m_clients.find(key);
    if (it != m_clients.end()) {
        // Remove old token lookup.
        m_tokenLookup.erase(TokenKey(it->second.token));
        it->second.active = false;
    }

    // Create new paired client.
    PairedClient client;
    client.fingerprint = clientFingerprint;
    client.pairedAt = now;
    client.lastUsed = now;
    client.active = true;

    // Generate initial session token.
    auto tokenBytes = RandomBytes(kSessionTokenBytes);
    if (tokenBytes.size() >= kSessionTokenBytes) {
        std::memcpy(client.token.data(), tokenBytes.data(), kSessionTokenBytes);
    }

    m_clients[key] = std::move(client);
    m_tokenLookup[TokenKey(m_clients[key].token)] = key;

    // Clear PIN (one-time use).
    m_currentPIN.clear();

    return true;
}

bool PairingManager::IsPaired(const CertFingerprint& fingerprint) const {
    std::lock_guard lk(m_mutex);
    std::string key = FingerprintToHex(fingerprint);
    auto it = m_clients.find(key);
    return it != m_clients.end() && it->second.active;
}

void PairingManager::InvalidateClient(const CertFingerprint& fingerprint) {
    std::lock_guard lk(m_mutex);
    std::string key = FingerprintToHex(fingerprint);
    auto it = m_clients.find(key);
    if (it != m_clients.end()) {
        m_tokenLookup.erase(TokenKey(it->second.token));
        m_clients.erase(it);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Session tokens
// ══════════════════════════════════════════════════════════════════════════════

SessionToken PairingManager::IssueToken(const CertFingerprint& fingerprint) {
    std::lock_guard lk(m_mutex);
    std::string key = FingerprintToHex(fingerprint);
    auto it = m_clients.find(key);
    if (it == m_clients.end() || !it->second.active)
        return SessionToken{};

    // Generate new token.
    auto tokenBytes = RandomBytes(kSessionTokenBytes);
    SessionToken newToken{};
    if (tokenBytes.size() >= kSessionTokenBytes)
        std::memcpy(newToken.data(), tokenBytes.data(), kSessionTokenBytes);

    // Remove old lookup, add new.
    m_tokenLookup.erase(TokenKey(it->second.token));
    it->second.token = newToken;
    m_tokenLookup[TokenKey(newToken)] = key;

    return newToken;
}

std::optional<CertFingerprint>
PairingManager::ValidateToken(const SessionToken& token) const {
    std::lock_guard lk(m_mutex);
    uint64_t key = TokenKey(token);
    auto it = m_tokenLookup.find(key);
    if (it == m_tokenLookup.end())
        return std::nullopt;

    auto clientIt = m_clients.find(it->second);
    if (clientIt == m_clients.end() || !clientIt->second.active)
        return std::nullopt;

    // Constant-time token comparison to prevent timing attacks.
    auto& storedToken = clientIt->second.token;
    volatile uint8_t diff = 0;
    for (size_t i = 0; i < kSessionTokenBytes; ++i)
        diff |= storedToken[i] ^ token[i];
    if (diff != 0)
        return std::nullopt;

    return clientIt->second.fingerprint;
}

void PairingManager::InvalidateAllTokens() {
    std::lock_guard lk(m_mutex);
    m_tokenLookup.clear();
    for (auto& [_, client] : m_clients)
        client.active = false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Certificate fingerprint storage
// ══════════════════════════════════════════════════════════════════════════════

void PairingManager::SetServerFingerprint(const CertFingerprint& fp) {
    m_serverFingerprint = fp;
}

CertFingerprint PairingManager::GetServerFingerprint() const {
    return m_serverFingerprint;
}

// ══════════════════════════════════════════════════════════════════════════════
// Persistence
// ══════════════════════════════════════════════════════════════════════════════

bool PairingManager::SaveToStorage(const std::wstring& filePath) const {
    std::lock_guard lk(m_mutex);

    // Simple JSON-like persistence.
    std::ofstream out(filePath, std::ios::binary);
    if (!out)
        return false;

    for (const auto& [hex, client] : m_clients) {
        if (!client.active) continue;
        out << hex << "|"
            << client.pairedAt << "|"
            << client.lastUsed << "|";
        // Write fingerprint bytes.
        out.write(reinterpret_cast<const char*>(client.fingerprint.data()),
                  client.fingerprint.size());
        out << "|";
        // Write token bytes.
        out.write(reinterpret_cast<const char*>(client.token.data()),
                  client.token.size());
        out << "\n";
    }
    return true;
}

bool PairingManager::LoadFromStorage(const std::wstring& filePath) {
    std::lock_guard lk(m_mutex);

    std::ifstream in(filePath, std::ios::binary);
    if (!in)
        return false;

    m_clients.clear();
    m_tokenLookup.clear();

    std::string line;
    while (std::getline(in, line)) {
        // Parse: hex|pairedAt|lastUsed|32fpbytes|64tokenbytes
        size_t pos1 = line.find('|');
        if (pos1 == std::string::npos) continue;
        size_t pos2 = line.find('|', pos1 + 1);
        if (pos2 == std::string::npos) continue;
        size_t pos3 = line.find('|', pos2 + 1);
        if (pos3 == std::string::npos) continue;

        PairedClient client;
        std::string hex = line.substr(0, pos1);
        client.pairedAt = std::stoull(line.substr(pos1 + 1, pos2 - pos1 - 1));
        client.lastUsed = std::stoull(line.substr(pos2 + 1, pos3 - pos2 - 1));

        // Read fixed-size fields after the last '|'.
        size_t dataOffset = pos3 + 1;
        if (dataOffset + kCertFingerprintBytes + kSessionTokenBytes > line.size())
            continue;

        std::memcpy(client.fingerprint.data(),
                    line.data() + dataOffset, kCertFingerprintBytes);
        std::memcpy(client.token.data(),
                    line.data() + dataOffset + kCertFingerprintBytes,
                    kSessionTokenBytes);
        client.active = true;

        m_clients[hex] = std::move(client);
        auto& stored = m_clients[hex];
        m_tokenLookup[TokenKey(stored.token)] = hex;
    }

    return true;
}

} // namespace solstream::security
