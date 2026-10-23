// smt.h — SMT/1's packet layer, promoted out of spike/smt-ping into the agent.
//
// Two changes from the spike, both because this one runs at 2500 packets a
// second instead of one:
//
//   * the BCrypt key handle is created ONCE per direction and kept. The spike
//     opened an algorithm provider and generated a symmetric key inside every
//     Seal, which at ping rates is invisible and at video rates is most of the
//     CPU the transport uses.
//   * Seal writes into a caller-owned buffer rather than returning a vector, so
//     a frame's worth of fragments costs no allocation at all.
//
// The wire format is unchanged and is still the one frozen by
// spike/smt-vectors: eight cleartext bytes, AES-256-GCM, the tag last, the
// header as the AAD verbatim.
//
//   off  w  field
//    0   1  verEpoch   high nibble = version (1); low nibble = key epoch mod 16
//    1   1  sessTag    low byte of the derived 32-bit session id
//    2   6  counter    48-bit big-endian, per-direction AEAD invocation number
//    8   N  ciphertext
//  8+N  16  tag

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <bcrypt.h>

#include <cstdint>
#include <cstring>

#ifndef NT_SUCCESS
#define NT_SUCCESS(s) (((NTSTATUS)(s)) >= 0)
#endif

namespace solstream::smt {

constexpr int kHeaderBytes = 8;
constexpr int kTagBytes = 16;
constexpr int kOverhead = kHeaderBytes + kTagBytes;

/// 1500 MTU less IPv4+UDP (28) less the SMT overhead (24). Everything inside is
/// the inner header plus payload.
constexpr int kMaxPlaintext = 1448;

// ── Inner packet types ───────────────────────────────────────────────────────
//
// The type is the first plaintext byte, so it is INSIDE the AEAD: an observer
// cannot tell video from input from a keepalive, and a forger cannot change one
// into another. That is the reason it is not in the cleartext header where it
// would be more convenient.
enum : unsigned char {
    kTypePing = 0x01,        ///< client -> host, also the address probe
    kTypePong = 0x02,        ///< host -> client
    kTypeVideo = 0x10,       ///< host -> client
    kTypeAudio = 0x20,       ///< host -> client
    kTypeInput = 0x30,       ///< client -> host
    kTypeFeedback = 0x40,    ///< client -> host: what arrived, what is missing
    kTypeHostStat = 0x41,    ///< host -> client: input ack, host clock
    kTypeBye = 0x50,         ///< either way
};

// Video header flags.
enum : unsigned char {
    kFlagFrameStart = 0x01,
    kFlagFrameEnd = 0x04,
    kFlagIdr = 0x08,
};

/// One direction's sealing state.
///
/// `counter` is never reset, including across a rekey: the loss detector, the
/// feedback space and every ring above index on it, and 2^48 invocations at
/// 2500 packets a second is 3,570 years.
struct Direction {
    BCRYPT_KEY_HANDLE key = nullptr;
    unsigned char fixed[6] = {};   ///< the nonce's fixed field, never transmitted
    uint64_t counter = 0;
};

inline void PutBE(unsigned char* out, uint64_t value, int width) {
    for (int i = 0; i < width; ++i) {
        out[i] = (unsigned char) ((value >> (8 * (width - 1 - i))) & 0xFF);
    }
}

inline uint64_t ReadBE(const unsigned char* p, int width) {
    uint64_t value = 0;
    for (int i = 0; i < width; ++i) {
        value = (value << 8) | p[i];
    }
    return value;
}

/// The one algorithm provider the whole process shares. Opening one per packet
/// was measurable; opening one per session is not, and this has no lifetime to
/// get wrong.
BCRYPT_ALG_HANDLE GcmProvider();

/// Import a 32-byte AES key, once. Returns nullptr on failure.
BCRYPT_KEY_HANDLE MakeKey(const unsigned char* key32);

/// Seal `plaintext` into `datagram`, which must have room for
/// `plaintextLen + kOverhead`. Returns the datagram length, or 0.
size_t Seal(Direction& direction, unsigned char sessTag, const unsigned char* plaintext,
            size_t plaintextLen, unsigned char* datagram, size_t datagramCapacity);

/// Advance a 1024-slot window, where slot n means "highest minus n", by
/// `shift`: a 1024-bit left shift, a word at a time with the carry between
/// words. Runs for nearly every packet, so it does not walk the bits. The
/// replay window here and the input dedupe in input.cpp both use it, and the
/// Mac's SMTReplayWindow does the same.
inline void SlideWindow(uint64_t (&bits)[16], uint64_t shift) {
    if (shift >= 1024) {
        for (uint64_t& word : bits) { word = 0; }
        return;
    }
    const int words = (int) (shift / 64);
    const unsigned carry = (unsigned) (shift % 64);
    for (int word = 15; word >= 0; --word) {
        const int from = word - words;
        uint64_t value = 0;
        if (from >= 0) {
            value = bits[from] << carry;
            if (carry > 0 && from > 0) { value |= bits[from - 1] >> (64 - carry); }
        }
        bits[word] = value;
    }
}

/// A 1024-packet sliding replay window.
///
/// Updated only AFTER the AEAD open succeeds. A counter that is merely old still
/// has to fail authentication to prove it is a replay rather than a reordering,
/// and recording it before the tag is checked would let anyone puncture the
/// window with garbage.
struct ReplayWindow {
    uint64_t highest = 0;
    uint64_t bits[16] = {};
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
            const uint64_t shift = counter - highest;
            SlideWindow(bits, shift);
            highest = counter;
            bits[0] |= 1;
            return;
        }
        const uint64_t behind = highest - counter;
        if (behind < 1024) {
            bits[behind / 64] |= 1ull << (behind % 64);
        }
    }
};

/// Verify and decrypt in place. `plaintext` points into `datagram` on success.
bool Open(Direction& direction, ReplayWindow& window, unsigned char* datagram,
          size_t length, unsigned char** plaintext, size_t* plaintextLen,
          uint64_t* counterOut);

}  // namespace solstream::smt
