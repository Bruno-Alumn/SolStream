#include "channel.h"

#include <bcrypt.h>

#include <cstring>

namespace solstream::media {
namespace {

std::vector<unsigned char> FromHex(const std::string& hex) {
    std::vector<unsigned char> out;
    out.reserve(hex.size() / 2);
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') { return c - '0'; }
        if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
        if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
        return -1;
    };
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        const int high = nibble(hex[i]);
        const int low = nibble(hex[i + 1]);
        if (high < 0 || low < 0) { return {}; }
        out.push_back((unsigned char) ((high << 4) | low));
    }
    return out;
}

bool Sha256(const unsigned char* data, size_t length, unsigned char out[32]) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) {
        return false;
    }
    BCRYPT_HASH_HANDLE hash = nullptr;
    bool ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) == 0;
    if (ok) { ok = BCryptHashData(hash, (PUCHAR) data, (ULONG) length, 0) == 0; }
    if (ok) { ok = BCryptFinishHash(hash, out, 32, 0) == 0; }
    if (hash) { BCryptDestroyHash(hash); }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

bool HmacSha256(const unsigned char* key, size_t keyLength, const unsigned char* data,
                size_t dataLength, unsigned char out[32]) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    BCRYPT_ALG_HANDLE_HMAC_FLAG) != 0) {
        return false;
    }
    BCRYPT_HASH_HANDLE hash = nullptr;
    bool ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, (PUCHAR) key,
                               (ULONG) keyLength, 0) == 0;
    if (ok) { ok = BCryptHashData(hash, (PUCHAR) data, (ULONG) dataLength, 0) == 0; }
    if (ok) { ok = BCryptFinishHash(hash, out, 32, 0) == 0; }
    if (hash) { BCryptDestroyHash(hash); }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

/// HKDF-Expand, RFC 5869. Written out rather than reached for because BCrypt's
/// own KDF wants a key handle and this needs raw bytes.
std::vector<unsigned char> HkdfExpand(const unsigned char prk[32],
                                      const std::string& info, size_t length) {
    std::vector<unsigned char> out;
    unsigned char previous[32];
    size_t previousLength = 0;
    unsigned char counter = 1;
    while (out.size() < length) {
        std::vector<unsigned char> block;
        block.insert(block.end(), previous, previous + previousLength);
        block.insert(block.end(), info.begin(), info.end());
        block.push_back(counter);
        unsigned char digest[32];
        if (!HmacSha256(prk, 32, block.data(), block.size(), digest)) {
            return {};
        }
        std::memcpy(previous, digest, 32);
        previousLength = 32;
        out.insert(out.end(), digest, digest + 32);
        ++counter;
    }
    out.resize(length);
    return out;
}

}  // namespace

void Channel::Reset() {
    if (toClient.key) { BCryptDestroyKey(toClient.key); toClient.key = nullptr; }
    if (fromClient.key) { BCryptDestroyKey(fromClient.key); fromClient.key = nullptr; }
    toClient.counter = 0;
    fromClient.counter = 0;
    encrypted = false;
    sessTag = 0;
}

bool DeriveChannelKeys(Channel& channel, const std::string& token,
                       const std::string& challenge, const std::string& cnonce) {
    const std::vector<unsigned char> tokenBytes = FromHex(token);
    if (tokenBytes.empty() || challenge.empty() || cnonce.empty()) {
        return false;
    }

    // The salt binds the keys to THIS connection. Both values are fresh per
    // connection -- the challenge is invented by the host and the nonce by the
    // client -- so neither end can force a key it has seen before.
    std::string transcript = "SolStream channel v1";
    transcript += challenge;
    transcript += cnonce;
    unsigned char salt[32];
    if (!Sha256((const unsigned char*) transcript.data(), transcript.size(), salt)) {
        return false;
    }
    unsigned char prk[32];
    if (!HmacSha256(salt, 32, tokenBytes.data(), tokenBytes.size(), prk)) {
        return false;
    }
    const std::vector<unsigned char> okm =
        HkdfExpand(prk, "SolStream channel keys v1", 76);
    if (okm.size() != 76) {
        return false;
    }

    channel.Reset();
    channel.toClient.key = smt::MakeKey(okm.data());
    channel.fromClient.key = smt::MakeKey(okm.data() + 32);
    std::memcpy(channel.toClient.fixed, okm.data() + 64, 6);
    std::memcpy(channel.fromClient.fixed, okm.data() + 70, 6);
    channel.sessTag = okm[75];
    if (!channel.toClient.key || !channel.fromClient.key) {
        channel.Reset();
        return false;
    }
    return true;
}

bool SealMessage(Channel& channel, const std::string& message,
                 std::vector<unsigned char>& record) {
    if (!channel.toClient.key || message.size() > kMaxChannelMessage) {
        return false;
    }
    const size_t sealedLength = message.size() + smt::kOverhead;
    record.resize(4 + sealedLength);
    for (int i = 0; i < 4; ++i) {
        record[i] = (unsigned char) ((sealedLength >> (8 * (3 - i))) & 0xFF);
    }
    const size_t written = smt::Seal(channel.toClient, channel.sessTag,
                                     (const unsigned char*) message.data(),
                                     message.size(), record.data() + 4, sealedLength);
    if (written != sealedLength) {
        return false;
    }
    return true;
}

bool OpenMessage(Channel& channel, std::string& buffer, std::string& message,
                 bool& fatal) {
    fatal = false;
    if (buffer.size() < 4) {
        return false;
    }
    size_t sealedLength = 0;
    for (int i = 0; i < 4; ++i) {
        sealedLength = (sealedLength << 8) | (size_t) (unsigned char) buffer[i];
    }
    if (sealedLength < (size_t) smt::kOverhead
        || sealedLength > kMaxChannelMessage + smt::kOverhead) {
        // A length this side never writes. The stream is not a stream this
        // build understands, and skipping it would only desynchronise further.
        fatal = true;
        return false;
    }
    if (buffer.size() < 4 + sealedLength) {
        return false;
    }

    std::vector<unsigned char> record(buffer.begin() + 4,
                                      buffer.begin() + 4 + sealedLength);
    unsigned char* plaintext = nullptr;
    size_t plaintextLength = 0;
    uint64_t counter = 0;
    // TCP delivers in order and exactly once, so the counter must be the next
    // one. A replay window would be answering a question the transport below has
    // already answered; a mismatch here is tampering, not reordering.
    smt::ReplayWindow window;
    if (!smt::Open(channel.fromClient, window, record.data(), record.size(),
                   &plaintext, &plaintextLength, &counter)
        || counter != channel.fromClient.counter) {
        fatal = true;
        return false;
    }
    ++channel.fromClient.counter;
    message.assign((const char*) plaintext, plaintextLength);
    buffer.erase(0, 4 + sealedLength);
    return true;
}

}  // namespace solstream::media
