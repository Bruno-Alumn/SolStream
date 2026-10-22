// session_takeover.cpp — see session_takeover.h.

#include "session_takeover.h"

#include <windows.h>
#include <bcrypt.h>

#include "util.h"

namespace solstream {

bool IsClientId(const std::string& id) {
    if (id.size() != 32) {
        return false;
    }
    for (const char c : id) {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return false;
        }
    }
    return true;
}

std::vector<unsigned char> TakeoverProofMessage(const std::vector<unsigned char>& challenge,
                                                const std::vector<unsigned char>& cnonce,
                                                const std::string& client_id) {
    static const char kLabel[] = "SolStream agent takeover v1";
    std::vector<unsigned char> message(kLabel, kLabel + sizeof(kLabel) - 1);
    message.insert(message.end(), challenge.begin(), challenge.end());
    message.insert(message.end(), cnonce.begin(), cnonce.end());
    message.insert(message.end(), client_id.begin(), client_id.end());
    return message;
}

std::vector<unsigned char> TakeoverHmac(const std::vector<unsigned char>& key,
                                        const std::vector<unsigned char>& data) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG))) {
        return {};
    }
    std::vector<unsigned char> out(32);
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, (PUCHAR) key.data(),
                                              (ULONG) key.size(), (PUCHAR) data.data(),
                                              (ULONG) data.size(), out.data(), 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok ? out : std::vector<unsigned char>{};
}

bool TakeoverProofMatches(const std::string& token_hex, const std::string& challenge_hex,
                          const std::string& cnonce_hex, const std::string& client_id,
                          const std::string& proof_hex) {
    const std::vector<unsigned char> key = FromHex(token_hex);
    const std::vector<unsigned char> challenge = FromHex(challenge_hex);
    const std::vector<unsigned char> cnonce = FromHex(cnonce_hex);
    const std::vector<unsigned char> proof = FromHex(proof_hex);
    if (key.empty() || challenge.size() != 32 || cnonce.size() != 32 || proof.size() != 32
        || !IsClientId(client_id)) {
        return false;
    }
    const std::vector<unsigned char> expected =
        TakeoverHmac(key, TakeoverProofMessage(challenge, cnonce, client_id));
    if (expected.size() != 32) {
        return false;
    }
    unsigned char difference = 0;
    for (size_t i = 0; i < 32; ++i) {
        difference |= (unsigned char) (expected[i] ^ proof[i]);
    }
    return difference == 0;
}

TakeoverVerdict DecideTakeover(bool proof_ok, const std::string& client_id,
                               bool holder_present, const std::string& holder_id,
                               unsigned long long holder_silent_ms) {
    // Before anything about the holder is consulted: a knock that cannot prove
    // the token learns nothing from the answer, not even whose session it is.
    if (!proof_ok) {
        return TakeoverVerdict::Refused;
    }
    if (!IsClientId(client_id)) {
        return TakeoverVerdict::Another;
    }
    // The session ended while the request was on its way. The slot is free, or
    // about to be, and a Mac that has proved the token may have it -- which is
    // what it would have been told had it knocked a moment later.
    if (!holder_present) {
        return TakeoverVerdict::Take;
    }
    // A Mac that gave no id is never somebody else's to end: every Mac built
    // before this one is such a Mac, and its session must stay as safe as it
    // always was.
    if (holder_id.empty() || holder_id != client_id) {
        return TakeoverVerdict::Another;
    }
    if (holder_silent_ms < kTakeoverSilenceMs) {
        return TakeoverVerdict::NotYet;
    }
    return TakeoverVerdict::Take;
}

}  // namespace solstream
