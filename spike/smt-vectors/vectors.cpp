// vectors.cpp — SMT/1's key schedule, computed on Windows, printed as hex.
//
// The other half of step 1. It must print byte-for-byte what vectors.swift
// prints, and the reason to write it before any socket exists is that the way
// this fails is silent: both ends derive different keys, every packet fails its
// authentication tag, and nothing anywhere says "the shared secret came back
// byte-reversed". It presents as a network fault and it is not one.
//
// THE TRAP THIS EXISTS TO CATCH. BCryptDeriveKey with BCRYPT_KDF_RAW_SECRET is
// documented to return the ECDH shared secret LITTLE-endian, while CryptoKit --
// and every specification -- means the x-coordinate big-endian. This program
// prints the raw output AND the reversal, so the answer is read off the screen
// rather than argued about.
//
// HKDF is built here from HMAC-SHA256 rather than from BCRYPT_HKDF_ALGORITHM.
// Not for portability: HKDF is six lines on top of HMAC, BCryptKeyDerivation
// needs a buffer-descriptor dance to say the same thing, and when two languages
// disagree it is far easier to bisect an extract and an expand you can see than
// one opaque call.
//
//   cmake -S spike/smt-vectors -B build/smt-vectors
//   cmake --build build/smt-vectors --config Release

#include <windows.h>
#include <bcrypt.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

#ifndef NT_SUCCESS
#define NT_SUCCESS(s) (((NTSTATUS)(s)) >= 0)
#endif

namespace {

using Bytes = std::vector<unsigned char>;

void Die(const char* what, NTSTATUS status) {
    std::printf("FAILED: %s (0x%08lX)\n", what, (unsigned long) status);
    std::exit(1);
}

Bytes FromHex(const std::string& hex) {
    Bytes out;
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back((unsigned char) std::stoul(hex.substr(i, 2), nullptr, 16));
    }
    return out;
}

std::string ToHex(const unsigned char* data, size_t n) {
    static const char* digits = "0123456789abcdef";
    std::string out;
    out.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) {
        out.push_back(digits[data[i] >> 4]);
        out.push_back(digits[data[i] & 0x0F]);
    }
    return out;
}
std::string ToHex(const Bytes& b) { return ToHex(b.data(), b.size()); }

Bytes Repeat(unsigned char byte, size_t n) { return Bytes(n, byte); }

void AppendBE(Bytes& out, unsigned long long value, int width) {
    for (int i = width - 1; i >= 0; --i) {
        out.push_back((unsigned char) ((value >> (8 * i)) & 0xFF));
    }
}

// ── Primitives ───────────────────────────────────────────────────────────────

Bytes Sha256(const Bytes& data) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    NTSTATUS s = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
    if (!NT_SUCCESS(s)) { Die("open sha256", s); }
    Bytes out(32);
    s = BCryptHash(alg, nullptr, 0, (PUCHAR) data.data(), (ULONG) data.size(),
                   out.data(), 32);
    if (!NT_SUCCESS(s)) { Die("sha256", s); }
    BCryptCloseAlgorithmProvider(alg, 0);
    return out;
}

Bytes HmacSha256(const Bytes& key, const Bytes& data) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    NTSTATUS s = BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr,
                                             BCRYPT_ALG_HANDLE_HMAC_FLAG);
    if (!NT_SUCCESS(s)) { Die("open hmac", s); }
    Bytes out(32);
    s = BCryptHash(alg, (PUCHAR) key.data(), (ULONG) key.size(),
                   (PUCHAR) data.data(), (ULONG) data.size(), out.data(), 32);
    if (!NT_SUCCESS(s)) { Die("hmac", s); }
    BCryptCloseAlgorithmProvider(alg, 0);
    return out;
}

/// RFC 5869. Extract is one HMAC; expand is the T(n) chain.
Bytes HkdfExtract(const Bytes& salt, const Bytes& ikm) {
    return HmacSha256(salt, ikm);
}

Bytes HkdfExpand(const Bytes& prk, const Bytes& info, size_t length) {
    Bytes out;
    Bytes previous;
    unsigned char counter = 1;
    while (out.size() < length) {
        Bytes input = previous;
        input.insert(input.end(), info.begin(), info.end());
        input.push_back(counter++);
        previous = HmacSha256(prk, input);
        out.insert(out.end(), previous.begin(), previous.end());
    }
    out.resize(length);
    return out;
}

// ── ECDH ─────────────────────────────────────────────────────────────────────
//
// The blob is a BCRYPT_ECCKEY_BLOB header followed by X, Y and (for a private
// key) d, each cbKey bytes and each BIG-endian -- which is what makes the
// little-endian RAW_SECRET output below so easy to miss. The two are not
// consistent with each other inside the same API.

BCRYPT_KEY_HANDLE ImportPrivate(BCRYPT_ALG_HANDLE alg, const Bytes& x,
                                const Bytes& y, const Bytes& d) {
    Bytes blob(sizeof(BCRYPT_ECCKEY_BLOB) + 96);
    auto* header = (BCRYPT_ECCKEY_BLOB*) blob.data();
    header->dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
    header->cbKey = 32;
    std::memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), x.data(), 32);
    std::memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB) + 32, y.data(), 32);
    std::memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB) + 64, d.data(), 32);

    BCRYPT_KEY_HANDLE key = nullptr;
    NTSTATUS s = BCryptImportKeyPair(alg, nullptr, BCRYPT_ECCPRIVATE_BLOB, &key,
                                     blob.data(), (ULONG) blob.size(), 0);
    if (!NT_SUCCESS(s)) { Die("import private", s); }
    return key;
}

BCRYPT_KEY_HANDLE ImportPublic(BCRYPT_ALG_HANDLE alg, const Bytes& x, const Bytes& y) {
    Bytes blob(sizeof(BCRYPT_ECCKEY_BLOB) + 64);
    auto* header = (BCRYPT_ECCKEY_BLOB*) blob.data();
    header->dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
    header->cbKey = 32;
    std::memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB), x.data(), 32);
    std::memcpy(blob.data() + sizeof(BCRYPT_ECCKEY_BLOB) + 32, y.data(), 32);

    BCRYPT_KEY_HANDLE key = nullptr;
    NTSTATUS s = BCryptImportKeyPair(alg, nullptr, BCRYPT_ECCPUBLIC_BLOB, &key,
                                     blob.data(), (ULONG) blob.size(), 0);
    if (!NT_SUCCESS(s)) { Die("import public", s); }
    return key;
}

/// The raw agreement, exactly as BCrypt hands it over. NOT reversed here: the
/// caller prints both so the endianness question is answered by reading, not by
/// trusting this comment.
Bytes RawSecret(BCRYPT_KEY_HANDLE mine, BCRYPT_KEY_HANDLE theirs) {
    BCRYPT_SECRET_HANDLE agreed = nullptr;
    NTSTATUS s = BCryptSecretAgreement(mine, theirs, &agreed, 0);
    if (!NT_SUCCESS(s)) { Die("secret agreement", s); }
    ULONG size = 0;
    s = BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET, nullptr, nullptr, 0, &size, 0);
    if (!NT_SUCCESS(s)) { Die("derive size", s); }
    Bytes out(size);
    s = BCryptDeriveKey(agreed, BCRYPT_KDF_RAW_SECRET, nullptr, out.data(), size,
                        &size, 0);
    if (!NT_SUCCESS(s)) { Die("derive", s); }
    BCryptDestroySecret(agreed);
    return out;
}

// ── AES-256-GCM ──────────────────────────────────────────────────────────────

void Seal(const Bytes& key, const Bytes& nonce, const Bytes& aad,
          const Bytes& plaintext, Bytes& ciphertext, Bytes& tag) {
    BCRYPT_ALG_HANDLE alg = nullptr;
    NTSTATUS s = BCryptOpenAlgorithmProvider(&alg, BCRYPT_AES_ALGORITHM, nullptr, 0);
    if (!NT_SUCCESS(s)) { Die("open aes", s); }
    s = BCryptSetProperty(alg, BCRYPT_CHAINING_MODE, (PUCHAR) BCRYPT_CHAIN_MODE_GCM,
                          sizeof(BCRYPT_CHAIN_MODE_GCM), 0);
    if (!NT_SUCCESS(s)) { Die("set gcm", s); }

    BCRYPT_KEY_HANDLE handle = nullptr;
    s = BCryptGenerateSymmetricKey(alg, &handle, nullptr, 0, (PUCHAR) key.data(),
                                   (ULONG) key.size(), 0);
    if (!NT_SUCCESS(s)) { Die("generate key", s); }

    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = (PUCHAR) nonce.data();
    info.cbNonce = (ULONG) nonce.size();
    info.pbAuthData = (PUCHAR) aad.data();
    info.cbAuthData = (ULONG) aad.size();
    tag.assign(16, 0);
    info.pbTag = tag.data();
    info.cbTag = 16;

    ciphertext.assign(plaintext.size(), 0);
    ULONG done = 0;
    s = BCryptEncrypt(handle, (PUCHAR) plaintext.data(), (ULONG) plaintext.size(),
                      &info, nullptr, 0, ciphertext.data(),
                      (ULONG) ciphertext.size(), &done, 0);
    if (!NT_SUCCESS(s)) { Die("encrypt", s); }
    BCryptDestroyKey(handle);
    BCryptCloseAlgorithmProvider(alg, 0);
}

}  // namespace

int main() {
    // ── The fixed vector, identical to vectors.swift ─────────────────────────
    //
    // The public points come from the vector rather than being computed here:
    // BCrypt cannot import a private key without them, and P-256 point
    // multiplication is not what this test is checking. What it is checking is
    // that two key schedules agree, and that starts at the shared secret.
    const Bytes clientD = Repeat(0x11, 32);
    const Bytes hostD = Repeat(0x22, 32);
    const std::string cpubHex =
        "040217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4ed"
        "194a7debcb97712d2dda3ca85aa8765a56f45fc758599652f2897c65306e5794";
    const std::string hpubHex =
        "04d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf3"
        "50185e895372df6221ea3a137557e473fddb6755f05bd507c3c533fce9c91285";
    const Bytes cnonce = Repeat(0xAA, 32);
    const Bytes hnonce = Repeat(0xBB, 32);
    const unsigned long long hcount = 42;
    const Bytes token = FromHex("00112233445566778899aabbccddeeff");

    const Bytes cpub = FromHex(cpubHex);
    const Bytes hpub = FromHex(hpubHex);
    if (cpub.size() != 65 || hpub.size() != 65 || cpub[0] != 0x04 || hpub[0] != 0x04) {
        std::printf("FAILED: the vector's public points are not 0x04||X||Y\n");
        return 1;
    }
    const Bytes cx(cpub.begin() + 1, cpub.begin() + 33);
    const Bytes cy(cpub.begin() + 33, cpub.end());
    const Bytes hx(hpub.begin() + 1, hpub.begin() + 33);
    const Bytes hy(hpub.begin() + 33, hpub.end());

    BCRYPT_ALG_HANDLE ecdh = nullptr;
    NTSTATUS s = BCryptOpenAlgorithmProvider(&ecdh, BCRYPT_ECDH_P256_ALGORITHM,
                                             nullptr, 0);
    if (!NT_SUCCESS(s)) { Die("open ecdh", s); }

    BCRYPT_KEY_HANDLE clientPriv = ImportPrivate(ecdh, cx, cy, clientD);
    BCRYPT_KEY_HANDLE hostPriv = ImportPrivate(ecdh, hx, hy, hostD);
    BCRYPT_KEY_HANDLE clientPub = ImportPublic(ecdh, cx, cy);
    BCRYPT_KEY_HANDLE hostPub = ImportPublic(ecdh, hx, hy);

    const Bytes rawFromClient = RawSecret(clientPriv, hostPub);
    const Bytes rawFromHost = RawSecret(hostPriv, clientPub);

    Bytes reversed(rawFromClient.rbegin(), rawFromClient.rend());

    std::printf("=== SMT/1 key schedule vector, computed by BCrypt ===\n");
    std::printf("raw secret AS RETURNED       %s\n", ToHex(rawFromClient).c_str());
    std::printf("raw secret REVERSED          %s\n", ToHex(reversed).c_str());
    std::printf("both directions agree        %s\n",
                rawFromClient == rawFromHost ? "yes" : "NO -- impossible, vector is wrong");

    // Whichever of the two above matches CryptoKit is Z. The Swift run printed
    // ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6, so this
    // program says which orientation produced it rather than assuming one.
    const std::string expectedZ =
        "ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6";
    Bytes Z;
    if (ToHex(rawFromClient) == expectedZ) {
        std::printf("ORIENTATION                  BCrypt returned BIG-endian already\n");
        Z = rawFromClient;
    } else if (ToHex(reversed) == expectedZ) {
        std::printf("ORIENTATION                  BCrypt returned LITTLE-endian; REVERSED\n");
        Z = reversed;
    } else {
        std::printf("ORIENTATION                  NEITHER matches CryptoKit -- stop here\n");
        return 1;
    }

    // ── Transcript, extract, expand ──────────────────────────────────────────
    Bytes transcript;
    const char* label = "SMT/1";
    transcript.insert(transcript.end(), label, label + 5);
    transcript.insert(transcript.end(), cpub.begin(), cpub.end());
    transcript.insert(transcript.end(), hpub.begin(), hpub.end());
    transcript.insert(transcript.end(), cnonce.begin(), cnonce.end());
    transcript.insert(transcript.end(), hnonce.begin(), hnonce.end());
    AppendBE(transcript, hcount, 8);
    const Bytes transcriptHash = Sha256(transcript);

    Bytes ikm = Z;
    ikm.insert(ikm.end(), token.begin(), token.end());
    const Bytes prk = HkdfExtract(transcriptHash, ikm);

    Bytes info;
    const char* keyLabel = "SMT/1 keys v1";
    info.insert(info.end(), keyLabel, keyLabel + 13);
    info.push_back(0);  // epoch high byte
    info.push_back(0);  // epoch low byte
    info.insert(info.end(), transcriptHash.begin(), transcriptHash.end());
    const Bytes okm = HkdfExpand(prk, info, 108);

    const Bytes kH2C(okm.begin(), okm.begin() + 32);
    const Bytes fH2C(okm.begin() + 64, okm.begin() + 70);
    const Bytes sid(okm.begin() + 76, okm.begin() + 80);

    // ── One sealed datagram ──────────────────────────────────────────────────
    const unsigned long long counter = 1;
    Bytes header;
    header.push_back((1 << 4) | 0);
    header.push_back(sid.back());
    AppendBE(header, counter, 6);

    Bytes nonce = fH2C;
    AppendBE(nonce, counter, 6);

    Bytes plaintext;
    plaintext.push_back(0x01);
    const char* ping = "SMT/1 ping";
    plaintext.insert(plaintext.end(), ping, ping + 10);

    Bytes ciphertext, tag;
    Seal(kH2C, nonce, header, plaintext, ciphertext, tag);

    std::printf("cpub            %s\n", ToHex(cpub).c_str());
    std::printf("hpub            %s\n", ToHex(hpub).c_str());
    std::printf("Z (ecdh x, BE)  %s\n", ToHex(Z).c_str());
    std::printf("transcriptHash  %s\n", ToHex(transcriptHash).c_str());
    std::printf("prk             %s\n", ToHex(prk).c_str());
    std::printf("okm[0..108]     %s\n", ToHex(okm).c_str());
    std::printf("  kH2C          %s\n", ToHex(kH2C).c_str());
    std::printf("  kC2H          %s\n", ToHex(Bytes(okm.begin() + 32, okm.begin() + 64)).c_str());
    std::printf("  fH2C          %s\n", ToHex(fH2C).c_str());
    std::printf("  fC2H          %s\n", ToHex(Bytes(okm.begin() + 70, okm.begin() + 76)).c_str());
    std::printf("  sid           %s\n", ToHex(sid).c_str());
    std::printf("  hostAuth      %s\n", ToHex(Bytes(okm.begin() + 80, okm.begin() + 92)).c_str());
    std::printf("  clientAuth    %s\n", ToHex(Bytes(okm.begin() + 92, okm.begin() + 104)).c_str());
    std::printf("header          %s\n", ToHex(header).c_str());
    std::printf("nonce           %s\n", ToHex(nonce).c_str());
    std::printf("plaintext       %s\n", ToHex(plaintext).c_str());
    std::printf("ciphertext      %s\n", ToHex(ciphertext).c_str());
    std::printf("tag             %s\n", ToHex(tag).c_str());

    Bytes datagram = header;
    datagram.insert(datagram.end(), ciphertext.begin(), ciphertext.end());
    datagram.insert(datagram.end(), tag.begin(), tag.end());
    std::printf("datagram        %s\n", ToHex(datagram).c_str());

    // Frozen. Both implementations agreed on every field on 2026-07-29, so from
    // here this is a regression test rather than an experiment: it exits
    // non-zero if either side ever drifts, which is the only way a change to the
    // key schedule can be noticed before it reaches a socket and turns into
    // "the network is broken".
    const std::string expectedDatagram =
        "106200000000000197a994e89c72a402aad58804a5822a0168d97fe393aefa275679b3";
    if (ToHex(datagram) != expectedDatagram) {
        std::printf("\nFAILED: the sealed datagram no longer matches the frozen "
                    "vector.\n  expected %s\n  got      %s\n",
                    expectedDatagram.c_str(), ToHex(datagram).c_str());
        return 1;
    }
    std::printf("\nPASS: matches the frozen cross-language vector.\n");
    return 0;
}
