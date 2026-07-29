// vectors.swift — SMT/1's key schedule, computed on the Mac, printed as hex.
//
// Step 1 of the build order, and it deliberately touches no socket. Two
// implementations of one key schedule in two languages agree or they do not, and
// the failure mode when they do not is the worst kind this project can have:
// both ends derive different keys, every packet fails its authentication tag,
// and there is nothing in either log that says "the ECDH shared secret came back
// byte-reversed". It looks exactly like a network fault.
//
// The specific trap this exists to catch: BCryptDeriveKey with
// BCRYPT_KDF_RAW_SECRET is documented to return the ECDH shared secret in
// LITTLE-endian, while CryptoKit's sharedSecretFromKeyAgreement returns the
// x-coordinate big-endian, which is what every specification means by "the
// shared secret". One `std::reverse` decides whether this project works.
//
// Run:  swift spike/smt-vectors/vectors.swift

import Foundation
import CryptoKit

// ── The fixed vector ─────────────────────────────────────────────────────────
//
// Private scalars chosen to be obviously reproducible rather than random: a
// vector nobody can retype by hand is a vector nobody checks. Both are far below
// the P-256 group order, so both are valid keys.

let clientScalar = Data(repeating: 0x11, count: 32)
let hostScalar   = Data(repeating: 0x22, count: 32)
let clientNonce  = Data(repeating: 0xAA, count: 32)
let hostNonce    = Data(repeating: 0xBB, count: 32)
let hostCount: UInt64 = 42
// The agent token, as the 16 bytes behind its 32 hex characters.
let tokenBytes = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                       0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func hex<T: Sequence>(_ b: T) -> String where T.Element == UInt8 {
    b.map { String(format: "%02x", $0) }.joined()
}
func be64(_ v: UInt64) -> Data {
    var out = Data(count: 8)
    for i in 0..<8 { out[i] = UInt8((v >> (56 - 8 * i)) & 0xFF) }
    return out
}
func be48(_ v: UInt64) -> Data {
    var out = Data(count: 6)
    for i in 0..<6 { out[i] = UInt8((v >> (40 - 8 * i)) & 0xFF) }
    return out
}

// ── ECDH ─────────────────────────────────────────────────────────────────────

let clientPriv = try! P256.KeyAgreement.PrivateKey(rawRepresentation: clientScalar)
let hostPriv   = try! P256.KeyAgreement.PrivateKey(rawRepresentation: hostScalar)

// x963Representation is 0x04 || X || Y — 65 bytes, the uncompressed point form
// the wire carries and the form BCrypt wants after its 8-byte blob header is
// stripped.
let cpub = clientPriv.publicKey.x963Representation
let hpub = hostPriv.publicKey.x963Representation

let sharedFromClient = try! clientPriv.sharedSecretFromKeyAgreement(with: hostPriv.publicKey)
let sharedFromHost   = try! hostPriv.sharedSecretFromKeyAgreement(with: clientPriv.publicKey)
let Z = sharedFromClient.withUnsafeBytes { Data($0) }
precondition(Z == sharedFromHost.withUnsafeBytes { Data($0) },
             "ECDH is not symmetric, which is impossible and means the vector is wrong")

// ── Transcript, extract, expand ──────────────────────────────────────────────
//
// The token goes into the INPUT KEY MATERIAL, not only into the transcript. That
// is what buys backward secrecy against a token leak: an attacker who later
// steals the token still cannot derive any past session's keys without also
// having had the ECDH private half, which was discarded when the session ended.

var transcript = Data("SMT/1".utf8)
transcript += cpub
transcript += hpub
transcript += clientNonce
transcript += hostNonce
transcript += be64(hostCount)
let transcriptHash = Data(SHA256.hash(data: transcript))

var ikm = Z
ikm += tokenBytes

let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm),
                               salt: transcriptHash)

/// One epoch's worth of key material. The epoch is inside `info`, so adding
/// rekeying later is a loop counter and not a redesign.
func expand(epoch: UInt16) -> Data {
    var info = Data("SMT/1 keys v1".utf8)
    info.append(UInt8(epoch >> 8))
    info.append(UInt8(epoch & 0xFF))
    info += transcriptHash
    return HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: 108)
        .withUnsafeBytes { Data($0) }
}

let okm = expand(epoch: 0)
let kH2C  = okm[0..<32]            // host -> client
let kC2H  = okm[32..<64]           // client -> host
let fH2C  = okm[64..<70]           // nonce fixed field, host -> client
let fC2H  = okm[70..<76]           // nonce fixed field, client -> host
let sid   = okm[76..<80]           // session id; its low byte is the wire sessTag
let hostAuth   = okm[80..<92]      // each side proves it derived the same keys
let clientAuth = okm[92..<104]

// ── One sealed datagram ──────────────────────────────────────────────────────
//
// The eight cleartext header bytes are the AAD verbatim, so a forged epoch,
// session tag or counter fails the tag rather than being silently accepted.

let epoch: UInt8 = 0
let counter: UInt64 = 1
var header = Data()
header.append((1 << 4) | (epoch & 0x0F))     // version 1, epoch 0
header.append(sid.last!)                      // sessTag = low byte of the session id
header += be48(counter)

let nonce = Data(fH2C) + be48(counter)        // F(direction, epoch) || BE48(i)
let plaintext = Data([0x01]) + Data("SMT/1 ping".utf8)

let sealed = try! AES.GCM.seal(plaintext,
                               using: SymmetricKey(data: kH2C),
                               nonce: try! AES.GCM.Nonce(data: nonce),
                               authenticating: header)

// ── Print ────────────────────────────────────────────────────────────────────

print("=== SMT/1 key schedule vector, computed by CryptoKit ===")
print("cpub            \(hex(cpub))")
print("hpub            \(hex(hpub))")
print("Z (ecdh x, BE)  \(hex(Z))")
print("transcriptHash  \(hex(transcriptHash))")
print("prk             \(hex(prk.withUnsafeBytes { Data($0) }))")
print("okm[0..108]     \(hex(okm))")
print("  kH2C          \(hex(kH2C))")
print("  kC2H          \(hex(kC2H))")
print("  fH2C          \(hex(fH2C))")
print("  fC2H          \(hex(fC2H))")
print("  sid           \(hex(sid))")
print("  hostAuth      \(hex(hostAuth))")
print("  clientAuth    \(hex(clientAuth))")
print("header          \(hex(header))")
print("nonce           \(hex(nonce))")
print("plaintext       \(hex(plaintext))")
print("ciphertext      \(hex(sealed.ciphertext))")
print("tag             \(hex(sealed.tag))")
print("datagram        \(hex(header + sealed.ciphertext + sealed.tag))")
