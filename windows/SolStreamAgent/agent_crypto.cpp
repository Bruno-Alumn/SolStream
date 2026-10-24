// agent_crypto.cpp — see agent_crypto.h.

#include "agent_crypto.h"

#include <algorithm>
#include <cstring>

#include "util.h"

namespace solstream {

bool ProofMatches(const std::string& token_hex, const std::string& challenge_hex,
                  const std::string& cnonce_hex, const std::string& proof_hex) {
    const std::vector<unsigned char> challenge = FromHex(challenge_hex);
    const std::vector<unsigned char> cnonce = FromHex(cnonce_hex);
    const std::vector<unsigned char> proof = FromHex(proof_hex);
    const std::vector<unsigned char> key = FromHex(token_hex);
    if (challenge.size() != 32 || cnonce.size() != 32 || proof.size() != 32
        || key.empty()) {
        return false;
    }
    static const char kLabel[] = "SolStream agent auth v2";
    std::vector<unsigned char> message(kLabel, kLabel + sizeof(kLabel) - 1);
    message.insert(message.end(), challenge.begin(), challenge.end());
    message.insert(message.end(), cnonce.begin(), cnonce.end());
    return ProofMatchesHmac(key, message, proof);
}

std::vector<unsigned char> Sha256(const std::vector<unsigned char>& data) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, 0))) {
        return {};
    }
    std::vector<unsigned char> out(32);
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, nullptr, 0, (PUCHAR) data.data(),
                                              (ULONG) data.size(), out.data(), 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok ? out : std::vector<unsigned char>{};
}

std::vector<unsigned char> HkdfExpand(const std::vector<unsigned char>& prk,
                                      const std::vector<unsigned char>& info,
                                      size_t length) {
    std::vector<unsigned char> out, previous;
    unsigned char counter = 1;
    while (out.size() < length) {
        std::vector<unsigned char> input = previous;
        input.insert(input.end(), info.begin(), info.end());
        input.push_back(counter++);
        previous = HmacSha256(prk, input);
        if (previous.empty()) {
            return {};
        }
        out.insert(out.end(), previous.begin(), previous.end());
    }
    out.resize(length);
    return out;
}

BCRYPT_KEY_HANDLE NewEcdhKeyPair(std::vector<unsigned char>& publicPoint) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDH_P256_ALGORITHM,
                                                    nullptr, 0))) {
        return nullptr;
    }
    BCRYPT_KEY_HANDLE key = nullptr;
    bool ok = BCRYPT_SUCCESS(BCryptGenerateKeyPair(algorithm, &key, 256, 0))
              && BCRYPT_SUCCESS(BCryptFinalizeKeyPair(key, 0));
    if (ok) {
        ULONG size = 0;
        ok = BCRYPT_SUCCESS(BCryptExportKey(key, nullptr, BCRYPT_ECCPUBLIC_BLOB, nullptr,
                                            0, &size, 0));
        std::vector<unsigned char> blob(size);
        ok = ok && BCRYPT_SUCCESS(BCryptExportKey(key, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                                  blob.data(), size, &size, 0));
        if (ok && size >= sizeof(BCRYPT_ECCKEY_BLOB) + 64) {
            publicPoint.assign(1, 0x04);
            publicPoint.insert(publicPoint.end(),
                               blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB),
                               blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB) + 64);
        } else {
            ok = false;
        }
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok && key) {
        BCryptDestroyKey(key);
        return nullptr;
    }
    return key;
}

std::vector<unsigned char> EcdhSecret(BCRYPT_KEY_HANDLE mine,
                                      const std::vector<unsigned char>& peerPoint) {
    if (peerPoint.size() != 65 || peerPoint[0] != 0x04) {
        return {};
    }
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDH_P256_ALGORITHM,
                                                    nullptr, 0))) {
        return {};
    }
    std::vector<unsigned char> blob(sizeof(BCRYPT_ECCKEY_BLOB) + 64);
    auto* header = (BCRYPT_ECCKEY_BLOB*) blob.data();
    header->dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
    header->cbKey = 32;
    memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), peerPoint.data() + 1, 64);

    BCRYPT_KEY_HANDLE peer = nullptr;
    std::vector<unsigned char> secret;
    if (BCRYPT_SUCCESS(BCryptImportKeyPair(algorithm, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                                           &peer, blob.data(), (ULONG) blob.size(), 0))) {
        BCRYPT_SECRET_HANDLE agreed = nullptr;
        if (BCRYPT_SUCCESS(BCryptSecretAgreement(mine, peer, &agreed, 0))) {
            ULONG size = 0;
            if (BCRYPT_SUCCESS(BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET, nullptr,
                                               nullptr, 0, &size, 0))) {
                secret.resize(size);
                if (!BCRYPT_SUCCESS(BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET,
                                                    nullptr, secret.data(), size,
                                                    &size, 0))) {
                    secret.clear();
                }
            }
            BCryptDestroySecret(agreed);
        }
        BCryptDestroyKey(peer);
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    std::reverse(secret.begin(), secret.end());   // <- the comment in the header
    return secret;
}

std::vector<unsigned char> DeriveMediaKeys(const std::vector<unsigned char>& cpub,
                                           const std::vector<unsigned char>& hpub,
                                           const std::vector<unsigned char>& cnonce,
                                           const std::vector<unsigned char>& hnonce,
                                           unsigned long long hcount,
                                           const std::vector<unsigned char>& secret,
                                           unsigned short epoch,
                                           const std::string& token_hex) {
    std::vector<unsigned char> transcript;
    static const char kLabel[] = "SMT/1";
    transcript.insert(transcript.end(), kLabel, kLabel + 5);
    transcript.insert(transcript.end(), cpub.begin(), cpub.end());
    transcript.insert(transcript.end(), hpub.begin(), hpub.end());
    transcript.insert(transcript.end(), cnonce.begin(), cnonce.end());
    transcript.insert(transcript.end(), hnonce.begin(), hnonce.end());
    for (int i = 7; i >= 0; --i) {
        transcript.push_back((unsigned char) ((hcount >> (8 * i)) & 0xFF));
    }
    const std::vector<unsigned char> hash = Sha256(transcript);

    // The token joins the INPUT KEY MATERIAL, not just the transcript: that is
    // what makes a token stolen later useless against a session already gone.
    std::vector<unsigned char> ikm = secret;
    const std::vector<unsigned char> tokenBytes = FromHex(token_hex);
    ikm.insert(ikm.end(), tokenBytes.begin(), tokenBytes.end());
    const std::vector<unsigned char> prk = HmacSha256(hash, ikm);

    std::vector<unsigned char> info;
    static const char kKeyLabel[] = "SMT/1 keys v1";
    info.insert(info.end(), kKeyLabel, kKeyLabel + 13);
    info.push_back((unsigned char) (epoch >> 8));
    info.push_back((unsigned char) (epoch & 0xFF));
    info.insert(info.end(), hash.begin(), hash.end());
    return HkdfExpand(prk, info, 108);
}

}  // namespace solstream
