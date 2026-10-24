// agent_crypto.h — the agent channel's cryptography: the auth v2 proof, and
// the SMT/1 key schedule the media session is keyed by.
//
// Kept out of main.cpp because none of it needs a socket or a window. The
// token is passed in rather than read from a global, so what each step is
// keyed with is said at the call.
//
// The token never crosses the wire: the client proves it holds it with an HMAC
// over a per-connection challenge (ProofMatches), and the same exchange agrees
// the forward-secret keys the channel is encrypted with from then on.
// docs/architecture.md has the whole handshake.

#pragma once

#include <windows.h>
#include <bcrypt.h>

#include <string>
#include <vector>

namespace solstream {

/// Auth v2: whether `proof_hex` proves the client holds `token_hex`.
///
/// proof = HMAC-SHA256(tokenBytes, "SolStream agent auth v2" || challenge || cnonce)
///
/// The challenge is fresh per connection, so a recorded proof is worth nothing
/// on the next one; the client's own nonce is in there because the same values
/// seed the media key schedule later and neither side should be able to fix all
/// of that input by itself.
bool ProofMatches(const std::string& token_hex, const std::string& challenge_hex,
                  const std::string& cnonce_hex, const std::string& proof_hex);

// ── SMT/1 key schedule ───────────────────────────────────────────────────────
//
// Pinned by the frozen cross-language vector in spike/smt-vectors: if any of
// this drifts, that vector stops matching and says so before a socket is
// involved. See docs/transport-smt1.md for why each input is there.

/// SHA-256 through BCrypt, or empty if BCrypt refuses.
std::vector<unsigned char> Sha256(const std::vector<unsigned char>& data);

/// RFC 5869. Extract is one HMAC; expand is the T(n) chain. Written out rather
/// than using BCRYPT_HKDF_ALGORITHM because when two languages disagree, an
/// extract and an expand you can read are far easier to bisect than one opaque
/// call -- and they did have to be bisected once already.
std::vector<unsigned char> HkdfExpand(const std::vector<unsigned char>& prk,
                                      const std::vector<unsigned char>& info,
                                      size_t length);

/// A fresh P-256 key pair. `publicPoint` comes back as 0x04||X||Y, 65 bytes --
/// the uncompressed form the wire carries, which is BCrypt's blob with its
/// 8-byte header swapped for the 0x04 tag.
BCRYPT_KEY_HANDLE NewEcdhKeyPair(std::vector<unsigned char>& publicPoint);

/// The ECDH shared secret as the x-coordinate, BIG-endian.
///
/// *** BCRYPT_KDF_RAW_SECRET RETURNS IT LITTLE-ENDIAN. *** CryptoKit, and every
/// specification, means big-endian, and the same BCrypt API is inconsistent with
/// itself -- BCRYPT_ECCKEY_BLOB's X, Y and d are all big-endian. Without the
/// reverse in here the two ends derive different keys, every packet fails its
/// tag, and nothing says why. Measured, not assumed: spike/smt-vectors prints
/// both.
std::vector<unsigned char> EcdhSecret(BCRYPT_KEY_HANDLE mine,
                                      const std::vector<unsigned char>& peerPoint);

/// 108 bytes: two directional keys, two nonce fixed fields, a session id and the
/// two authentication tags each side uses to prove it derived the same thing.
/// `token_hex` is the pairing token, which joins the input key material.
std::vector<unsigned char> DeriveMediaKeys(const std::vector<unsigned char>& cpub,
                                           const std::vector<unsigned char>& hpub,
                                           const std::vector<unsigned char>& cnonce,
                                           const std::vector<unsigned char>& hnonce,
                                           unsigned long long hcount,
                                           const std::vector<unsigned char>& secret,
                                           unsigned short epoch,
                                           const std::string& token_hex);

}  // namespace solstream
