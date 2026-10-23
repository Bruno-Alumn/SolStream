#include "smt.h"

#include <mutex>

namespace solstream::smt {
namespace {

BCRYPT_ALG_HANDLE g_provider = nullptr;
std::once_flag g_provider_once;

}  // namespace

BCRYPT_ALG_HANDLE GcmProvider() {
    std::call_once(g_provider_once, [] {
        BCRYPT_ALG_HANDLE handle = nullptr;
        if (!NT_SUCCESS(BCryptOpenAlgorithmProvider(&handle, BCRYPT_AES_ALGORITHM,
                                                    nullptr, 0))) {
            return;
        }
        if (!NT_SUCCESS(BCryptSetProperty(handle, BCRYPT_CHAINING_MODE,
                                          (PUCHAR) BCRYPT_CHAIN_MODE_GCM,
                                          sizeof(BCRYPT_CHAIN_MODE_GCM), 0))) {
            BCryptCloseAlgorithmProvider(handle, 0);
            return;
        }
        g_provider = handle;
    });
    return g_provider;
}

BCRYPT_KEY_HANDLE MakeKey(const unsigned char* key32) {
    BCRYPT_ALG_HANDLE provider = GcmProvider();
    if (!provider) { return nullptr; }
    BCRYPT_KEY_HANDLE key = nullptr;
    if (!NT_SUCCESS(BCryptGenerateSymmetricKey(provider, &key, nullptr, 0,
                                               (PUCHAR) key32, 32, 0))) {
        return nullptr;
    }
    return key;
}

size_t Seal(Direction& direction, unsigned char sessTag, const unsigned char* plaintext,
            size_t plaintextLen, unsigned char* datagram, size_t datagramCapacity) {
    if (!direction.key || datagramCapacity < plaintextLen + kOverhead) {
        return 0;
    }
    const uint64_t counter = direction.counter++;

    datagram[0] = (1 << 4) | 0;   // version 1, epoch 0
    datagram[1] = sessTag;
    PutBE(datagram + 2, counter, 6);

    unsigned char nonce[12];
    std::memcpy(nonce, direction.fixed, 6);
    std::memcpy(nonce + 6, datagram + 2, 6);

    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = nonce;
    info.cbNonce = 12;
    info.pbAuthData = datagram;
    info.cbAuthData = kHeaderBytes;
    info.pbTag = datagram + kHeaderBytes + plaintextLen;
    info.cbTag = kTagBytes;

    // Straight from the caller's plaintext into the datagram, rather than
    // copied in first and encrypted in place.
    ULONG done = 0;
    if (!NT_SUCCESS(BCryptEncrypt(direction.key, (PUCHAR) plaintext,
                                  (ULONG) plaintextLen, &info, nullptr, 0,
                                  datagram + kHeaderBytes, (ULONG) plaintextLen,
                                  &done, 0))) {
        return 0;
    }
    return kHeaderBytes + plaintextLen + kTagBytes;
}

bool Open(Direction& direction, ReplayWindow& window, unsigned char* datagram,
          size_t length, unsigned char** plaintext, size_t* plaintextLen,
          uint64_t* counterOut) {
    if (!direction.key || length < (size_t) kOverhead) {
        return false;
    }
    if ((datagram[0] >> 4) != 1) {
        return false;
    }
    const uint64_t counter = ReadBE(datagram + 2, 6);
    if (window.SeenOrTooOld(counter)) {
        return false;
    }

    unsigned char nonce[12];
    std::memcpy(nonce, direction.fixed, 6);
    std::memcpy(nonce + 6, datagram + 2, 6);

    const size_t bodyLen = length - kOverhead;

    BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO info;
    BCRYPT_INIT_AUTH_MODE_INFO(info);
    info.pbNonce = nonce;
    info.cbNonce = 12;
    info.pbAuthData = datagram;
    info.cbAuthData = kHeaderBytes;
    info.pbTag = datagram + kHeaderBytes + bodyLen;
    info.cbTag = kTagBytes;

    ULONG done = 0;
    if (!NT_SUCCESS(BCryptDecrypt(direction.key, datagram + kHeaderBytes,
                                  (ULONG) bodyLen, &info, nullptr, 0,
                                  datagram + kHeaderBytes, (ULONG) bodyLen,
                                  &done, 0))) {
        return false;
    }
    window.Record(counter);
    *plaintext = datagram + kHeaderBytes;
    *plaintextLen = bodyLen;
    if (counterOut) { *counterOut = counter; }
    return true;
}

}  // namespace solstream::smt
