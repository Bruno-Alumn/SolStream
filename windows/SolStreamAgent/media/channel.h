// channel.h — encrypting the agent channel with what auth v2 already agreed.
//
// TCP 47630 carries window titles, application names, the display layout, the
// cursor shape and the ENTIRE CLIPBOARD, and until now it carried all of it in
// the clear. The media path beside it has been AES-256-GCM since it existed,
// which made the plaintext channel the most valuable thing on the wire.
//
// Still no extra round trip. Auth v2 already has both ends holding the token, a
// host-chosen challenge and a client-chosen nonce; the client's proof message
// now also carries an ephemeral P-256 public point, and the reply carries the
// host's. Both are in the clear, which is exactly what they are for.
//
//   Z   = ECDH(ephemeral)                              -- discarded immediately
//   PRK = HKDF-Extract(salt = SHA256("SolStream channel v2" || challenge
//                                    || cnonce || cpub || hpub),
//                      ikm  = Z || tokenBytes)
//   okm = HKDF-Expand(PRK, "SolStream channel keys v2", 100)
//         0..32  host -> client key      64..70  host -> client nonce fixed field
//        32..64  client -> host key      70..76  client -> host nonce fixed field
//        76..88  hostAuth                88..100 clientAuth
//
// THE EPHEMERAL SECRET IS WHAT MAKES THIS FORWARD SECRET, and mixing the token
// into the same input key material is what keeps it authenticated. The first
// version of this file derived from the token alone and said plainly that it was
// not forward secret: anyone who later learned the token could decrypt a session
// they had recorded. Now they cannot, because the other half of the key material
// was thrown away when the connection closed.
//
// The token also defeats the obvious attack on an unauthenticated Diffie-Hellman.
// Someone in the middle can substitute their own public point, but without the
// token they cannot derive the keys either end will use -- so both ends derive
// different ones, every record fails its tag, and the connection drops. That is
// a detected failure rather than a silent compromise.
//
// `hostAuth` is what lets the CLIENT authenticate the HOST, which nothing did
// before: the challenge-response proves the client to the host and not the other
// way round. The host returns its twelve bytes in the auth reply and the client
// refuses to switch if they disagree.
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

    /// Take another channel's keys, leaving it empty.
    ///
    /// The derivation happens while the auth reply is being built and the switch
    /// happens after it has gone out, so the keys have to survive between the
    /// two without a second copy of the BCrypt handles to destroy.
    void Adopt(Channel& other);
};

/// Derive both directions.
///
/// `secret` is the raw ECDH shared secret, x-coordinate big-endian — the caller
/// does the agreement, because the ECDH helpers live beside the media
/// handshake's and there is no reason for two copies of them. `hostAuth` comes
/// back as 24 hex characters for the reply.
bool DeriveChannelKeys(Channel& channel, const std::string& token,
                       const std::string& challenge, const std::string& cnonce,
                       const std::vector<unsigned char>& cpub,
                       const std::vector<unsigned char>& hpub,
                       const std::vector<unsigned char>& secret,
                       std::string& hostAuth);

/// Seal one message into a length-prefixed record. Returns false if the message
/// is too large or the channel has no keys.
bool SealMessage(Channel& channel, const std::string& message,
                 std::vector<unsigned char>& record);

/// Take one message out of `buffer` if a whole record is present, removing it.
/// Returns false when more bytes are needed; `fatal` distinguishes that from a
/// record that failed to authenticate, which must end the connection rather than
/// be skipped -- a channel that quietly drops what it cannot open is a channel an
/// attacker can silence one message at a time. The record is decrypted where it
/// lies, so after a fatal failure `buffer` holds nothing worth reading.
bool OpenMessage(Channel& channel, std::string& buffer, std::string& message,
                 bool& fatal);

}  // namespace solstream::media
