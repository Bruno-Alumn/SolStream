// channel.h — encrypting the agent channel with what auth v2 already agreed.
//
// TCP 47630 carries window titles, application names, the display layout, the
// cursor shape and the ENTIRE CLIPBOARD, and until now it carried all of it in
// the clear. The media path beside it has been AES-256-GCM since it existed,
// which made the plaintext channel the most valuable thing on the wire.
//
// No new handshake. Auth v2 already has both ends holding the token, a
// host-chosen challenge and a client-chosen nonce, and already proves possession
// without transmitting the token. The same three values key the channel through
// a different label, so this costs no extra round trip:
//
//   PRK = HKDF-Extract(salt = SHA256("SolStream channel v1" || challenge || cnonce),
//                      ikm  = tokenBytes)
//   okm = HKDF-Expand(PRK, "SolStream channel keys v1", 76)
//         0..32  host -> client key      64..70  host -> client nonce fixed field
//        32..64  client -> host key      70..76  client -> host nonce fixed field
//
// This is NOT forward secret. An attacker who later learns the token can decrypt
// a recorded session, because there is no ephemeral key here -- unlike the media
// path, which mixes in an ECDH secret that is discarded when the session ends.
// Fixing that means a Diffie-Hellman on the channel before it is encrypted, and
// it is worth doing; what is here removes passive disclosure to anyone on the
// path, which is the part that was true of every session simultaneously.
//
// Framing, once encryption is on:
//
//   4 bytes  big-endian length of the sealed record that follows
//   N bytes  the record: an 8-byte SMT/1 header, ciphertext, and a 16-byte tag
//
// FOUR bytes, not two. Two would cap a record at 65,535 bytes, and the clipboard
// alone is allowed 256 KB -- so a large paste would have failed to seal and
// dropped the connection, in the encrypted path only. The cap here matches
// kMaxLineBytes in main.cpp deliberately: the encrypted channel must carry
// exactly what the plaintext one carried, or a message size becomes a way to
// tell the two apart.
//
// One JSON message per record. The newline framing that came before it is not
// merely unnecessary, it is unusable: ciphertext contains 0x0A as often as any
// other byte.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <string>
#include <vector>

#include "smt.h"

namespace solstream::media {

/// The largest JSON message the channel will carry. The same 4 MB as
/// kMaxLineBytes, so encryption changes nothing about what fits.
constexpr size_t kMaxChannelMessage = 4 * 1024 * 1024;

/// One connection's channel keys. There is one client at a time, so there is one
/// of these.
struct Channel {
    bool encrypted = false;
    smt::Direction toClient, fromClient;
    unsigned char sessTag = 0;

    void Reset();
};

/// Derive both directions from the auth-v2 material. `token` is the 32 hex
/// characters; `challenge` and `cnonce` are hex as they went over the wire.
bool DeriveChannelKeys(Channel& channel, const std::string& token,
                       const std::string& challenge, const std::string& cnonce);

/// Seal one message into a length-prefixed record. Returns false if the message
/// is too large or the channel has no keys.
bool SealMessage(Channel& channel, const std::string& message,
                 std::vector<unsigned char>& record);

/// Take one message out of `buffer` if a whole record is present, removing it.
/// Returns false when more bytes are needed; `fatal` distinguishes that from a
/// record that failed to authenticate, which must end the connection rather than
/// be skipped -- a channel that quietly drops what it cannot open is a channel an
/// attacker can silence one message at a time.
bool OpenMessage(Channel& channel, std::string& buffer, std::string& message,
                 bool& fatal);

}  // namespace solstream::media
