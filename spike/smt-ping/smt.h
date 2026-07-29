// smt.h — SMT/1's packet layer on Windows: seal, open, and the replay window.
//
// Header-only and self-contained so the ping responder beside it needs nothing
// built. When this graduates into the agent it becomes a .cpp; until then it is
// deliberately easy to compile in isolation, because the whole point of this
// step is to measure the transport with nothing else in the frame.
//
// KEYS ARE PRE-SHARED HERE. Step 3 measures the wire, not the handshake, so it
// uses the key from the frozen cross-language vector (spike/smt-vectors) rather
// than doing ECDH. That is the same reason step 5 will feed the packetizer from
// a file rather than a live encoder: one new variable at a time, or a number
// means nothing.

#pragma once

// Anything including this alongside sockets must include winsock2.h first; this
// only keeps windows.h from dragging in the rest of the world unasked.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <bcrypt.h>

#include <cstdint>
#include <cstring>
#include <vector>

#pragma comment(lib, "bcrypt.lib")

#ifndef NT_SUCCESS
#define NT_SUCCESS(s) (((NTSTATUS)(s)) >= 0)
#endif

namespace smt {

using Bytes = std::vector<unsigned char>;

constexpr int kHeaderBytes = 8;
constexpr int kTagBytes = 16;
constexpr int kOverhead = kHeaderBytes + kTagBytes;

enum : unsigned char {
    kTypePing = 0x01,
    kTypePong = 0x02,
};

/// One direction's sealing state: a key, a nonce fixed field, and the counter
/// that must never repeat under them.
struct Direction {
    Bytes key;      ///< 32 bytes, AES-256
    Bytes fixed;    ///< 6 bytes, the nonce's fixed field -- never transmitted
    uint64_t counter = 0;
};

inline void AppendBE(Bytes& out, uint64_t value, int width) {
    for (int i = width - 1; i >= 0; --i) {
        out.push_back((unsigned char) ((value >> (8 * i)) & 0xFF));
    }
}

inline uint64_t ReadBE(const unsigned char* p, int width) {
    uint64_t value = 0;
    for (int i = 0; i < width; ++i) {
        value = (value << 8) | p[i];
    }
    return value;
}

/// AES-256-GCM in place. One algorithm handle per call is wasteful and will be
/// hoisted when this graduates; at ping rates it is invisible, and a spike that
/// caches handles is a spike hiding a lifetime bug.
inline bool Gcm(const Bytes& key, const unsigned char* nonce, const unsigned char* aad,
                ULONG aadLen, unsigned char* data, ULONG dataLen, unsigned char* tag,
                bool encrypt) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_AES_ALGORITHM,
                                                nullptr, 0))) {
        return false;
    }
    bool ok = NT_SUCCESS(BCryptSetProperty(algorithm, BCRYPT_CHAINING_MODE,
                                           (PUCHAR) BCRYPT_CHAIN_MODE_GCM,
                                           sizeof(BCRYPT_CHAIN_MODE_GCM), 0));
    BCRYPT_KEY_HANDLE handle = nullptr;
    if (ok) {
        ok = NT_SUCCESS(BCryptGenerateSymmetricKey(algorithm, &handle, nullptr, 0,
                                                   (PUCHAR) key.data(),
                                                   (ULONG) key.size(), 0));
    }
    if (ok) {
        BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
        BCRYPT_INIT_AUTH_MODE_INFO(info);
        info.pbNonce = (PUCHAR) nonce;
        info.cbNonce = 12;
        info.pbAuthData = (PUCHAR) aad;
        info.cbAuthData = aadLen;
        info.pbTag = tag;
        info.cbTag = kTagBytes;
        ULONG done = 0;
        ok = NT_SUCCESS(encrypt
            ? BCryptEncrypt(handle, data, dataLen, &info, nullptr, 0, data, dataLen,
                            &done, 0)
            : BCryptDecrypt(handle, data, dataLen, &info, nullptr, 0, data, dataLen,
                            &done, 0));
    }
    if (handle) { BCryptDestroyKey(handle); }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

/// Build one datagram. The header is the AAD verbatim, so a forged epoch,
/// session tag or counter fails the tag rather than being quietly accepted.
inline Bytes Seal(Direction& direction, unsigned char sessTag, const Bytes& plaintext) {
    const uint64_t counter = direction.counter++;

    Bytes datagram;
    datagram.reserve(kOverhead + plaintext.size());
    datagram.push_back((1 << 4) | 0);   // version 1, epoch 0
    datagram.push_back(sessTag);
    AppendBE(datagram, counter, 6);

    const size_t bodyAt = datagram.size();
    datagram.insert(datagram.end(), plaintext.begin(), plaintext.end());
    datagram.resize(datagram.size() + kTagBytes);

    unsigned char nonce[12];
    std::memcpy(nonce, direction.fixed.data(), 6);
    for (int i = 0; i < 6; ++i) {
        nonce[6 + i] = (unsigned char) ((counter >> (40 - 8 * i)) & 0xFF);
    }

    if (!Gcm(direction.key, nonce, datagram.data(), kHeaderBytes,
             datagram.data() + bodyAt, (ULONG) plaintext.size(),
             datagram.data() + bodyAt + plaintext.size(), true)) {
        return {};
    }
    return datagram;
}

/// A 1024-packet sliding replay window. A datagram whose counter is older than
/// the window, or one already seen, is dropped BEFORE its tag is verified only
/// in the "already seen" case -- an old counter still has to fail authentication
/// to prove it is not simply reordered, which is why the window is updated after
/// the open succeeds and never before.
struct ReplayWindow {
    uint64_t highest = 0;
    uint64_t bits[16] = {};   // 1024 slots
    bool started = false;

    bool SeenOrTooOld(uint64_t counter) const {
        if (!started) { return false; }
        if (counter > highest) { return false; }
        const uint64_t behind = highest - counter;
        if (behind >= 1024) { return true; }
        return (bits[behind / 64] >> (behind % 64)) & 1;
    }

    void Record(uint64_t counter) {
        if (!started) {
            started = true;
            highest = counter;
            bits[0] = 1;
            return;
        }
        if (counter > highest) {
            // Slide the window forward. Bit n means "we have seen highest - n",
            // so advancing by `shift` moves every recorded slot `shift` further
            // back, and anything pushed past 1024 falls out of memory.
            const uint64_t shift = counter - highest;
            uint64_t slid[16] = {};
            if (shift < 1024) {
                for (int slot = 0; slot < 1024; ++slot) {
                    if ((bits[slot / 64] >> (slot % 64)) & 1) {
                        const uint64_t moved = (uint64_t) slot + shift;
                        if (moved < 1024) {
                            slid[moved / 64] |= 1ull << (moved % 64);
                        }
                    }
                }
            }
            std::memcpy(bits, slid, sizeof(bits));
            highest = counter;
            bits[0] |= 1;   // and this one, at offset zero
            return;
        }
        const uint64_t behind = highest - counter;
        if (behind < 1024) {
            bits[behind / 64] |= 1ull << (behind % 64);
        }
    }
};

/// Verify and decrypt in place. Returns false on anything that does not
/// authenticate, which includes a forged header, since the header is the AAD.
inline bool Open(Direction& direction, ReplayWindow& window, unsigned char* datagram,
                 size_t length, Bytes& plaintext, uint64_t& counterOut) {
    if (length < (size_t) kOverhead) {
        return false;
    }
    if ((datagram[0] >> 4) != 1) {
        return false;   // a version this build does not speak
    }
    const uint64_t counter = ReadBE(datagram + 2, 6);
    if (window.SeenOrTooOld(counter)) {
        return false;
    }

    unsigned char nonce[12];
    std::memcpy(nonce, direction.fixed.data(), 6);
    std::memcpy(nonce + 6, datagram + 2, 6);

    const size_t bodyLen = length - kOverhead;
    if (!Gcm(direction.key, nonce, datagram, kHeaderBytes, datagram + kHeaderBytes,
             (ULONG) bodyLen, datagram + kHeaderBytes + bodyLen, false)) {
        return false;
    }
    window.Record(counter);
    plaintext.assign(datagram + kHeaderBytes, datagram + kHeaderBytes + bodyLen);
    counterOut = counter;
    return true;
}

}  // namespace smt
