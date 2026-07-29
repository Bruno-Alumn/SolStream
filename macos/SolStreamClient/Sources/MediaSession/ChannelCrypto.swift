// ChannelCrypto.swift — encrypting the agent channel with what auth v2 agreed.
//
// The other half of windows/SolStreamAgent/media/channel.h. TCP 47630 carries
// window titles, application names, the display layout, the cursor shape and the
// entire clipboard, and until this existed it carried all of it in the clear —
// beside a media path that had been AES-256-GCM since the day it was written.
//
// Still no extra round trip. Auth v2 already leaves both ends holding the token,
// a host-chosen challenge and a client-chosen nonce; the proof message now also
// carries an ephemeral P-256 public point and the reply carries the host's. Both
// travel in the clear, which is what they are for.
//
//   Z   = ECDH(ephemeral)                              — discarded immediately
//   PRK = HKDF-Extract(salt: SHA256("SolStream channel v2" || challenge
//                                   || cnonce || cpub || hpub),
//                      ikm:  Z || tokenBytes)
//   okm = HKDF-Expand(PRK, "SolStream channel keys v2", 100)
//
// THE EPHEMERAL HALF IS WHAT MAKES THIS FORWARD SECRET; the token is what keeps
// it authenticated. The first version of this file derived from the token alone
// and said so: anyone who later learned it could decrypt a recorded session.
// They cannot now, because the other half was thrown away when the connection
// closed.
//
// The token also defeats the obvious attack on an unauthenticated
// Diffie-Hellman. Someone in the middle can substitute their own point, but
// without the token they cannot derive the keys either end will use — so the two
// ends derive different ones, every record fails its tag, and the connection
// drops. A detected failure, not a silent compromise.
//
// `hostAuth` is the only thing in the handshake that authenticates the HOST to
// this Mac: the challenge-response proves this Mac to the host and not the other
// way round. The host returns its twelve bytes and this refuses to switch if
// they disagree.
//
// Framing, once it is on: four big-endian length bytes, then the sealed record —
// an eight-byte SMT/1 header, the ciphertext, and a sixteen-byte tag. One JSON
// message per record. Newline framing is not merely unnecessary after this
// point, it is unusable: ciphertext contains 0x0A as often as any other byte.
//
// FOUR bytes, not two. Two would cap a record at 65,535 bytes and the clipboard
// alone is allowed 256 KB, so a large paste would have dropped the connection —
// in the encrypted path only, which is the worst way for a size limit to differ.

import Foundation
import CryptoKit

public final class ChannelCrypto {

    /// The largest message the channel will carry: the same 4 MB the plaintext
    /// path allowed, so encryption changes nothing about what fits.
    public static let maxMessage = 4 * 1024 * 1024

    public enum Failure: Error {
        /// A record that did not authenticate, or a length this side never
        /// writes. Both mean the stream is no longer what it claims to be, and
        /// neither can be skipped: a channel that silently drops what it cannot
        /// open is one an attacker can silence a message at a time.
        case tampered
        case tooLarge
    }

    private let toHost: SMTDirection
    private let fromHost: SMTDirection
    private let sessionTag: UInt8
    /// What the host must return to prove it derived the same 100 bytes.
    public let hostAuth: String
    /// TCP delivers in order and exactly once, so the next record's counter is
    /// known rather than guessed. A replay window here would be answering a
    /// question the transport below has already answered.
    private var expectedCounter: UInt64 = 0

    /// - Parameter secret: the raw ECDH shared secret, x-coordinate big-endian.
    ///   CryptoKit hands it over that way.
    public init?(token: String, challenge: String, clientNonce: String,
                 clientPublic: Data, hostPublic: Data, secret: Data) {
        guard let tokenBytes = Data(smtHex: token), !tokenBytes.isEmpty,
              !challenge.isEmpty, !clientNonce.isEmpty,
              clientPublic.count == 65, hostPublic.count == 65,
              secret.count == 32 else { return nil }

        // The salt binds the keys to THIS connection and to THESE points.
        // Everything in it is fresh per connection, so neither end can force a
        // key it has seen before and no third party can swap a point without
        // changing what both ends derive.
        var transcript = Data("SolStream channel v2".utf8)
        transcript += Data(challenge.utf8)
        transcript += Data(clientNonce.utf8)
        transcript += clientPublic
        transcript += hostPublic
        let salt = Data(SHA256.hash(data: transcript))

        // Z FIRST, THEN THE TOKEN. The ephemeral half buys forward secrecy; the
        // token keeps it authenticated. Either alone gives up one of the two.
        var ikm = secret
        ikm += tokenBytes
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm),
                                       salt: salt)
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                      info: Data("SolStream channel keys v2".utf8),
                                      outputByteCount: 100)
            .withUnsafeBytes { Data($0) }

        toHost = SMTDirection(key: SymmetricKey(data: okm[32..<64]),
                              fixed: Data(okm[70..<76]))
        fromHost = SMTDirection(key: SymmetricKey(data: okm[0..<32]),
                                fixed: Data(okm[64..<70]))
        sessionTag = okm[75]
        hostAuth = Data(okm[76..<88]).smtHex
    }

    /// Seal one message into a length-prefixed record.
    public func seal(_ message: Data) throws -> Data {
        try seal(message, using: toHost)
    }

    /// The record the HOST would write, for tests that need to play that side.
    /// There is no host implementation in Swift, and a second hand-written copy
    /// of this framing in the test file would be a copy that could agree with
    /// itself while disagreeing with the agent.
    func sealAsHost(_ message: Data) throws -> Data {
        try seal(message, using: fromHost)
    }

    private func seal(_ message: Data, using direction: SMTDirection) throws -> Data {
        guard message.count <= Self.maxMessage else { throw Failure.tooLarge }
        guard let sealed = SMTPacket.seal(message, direction: direction,
                                          sessionTag: sessionTag) else {
            throw Failure.tooLarge
        }
        var record = Data(capacity: 4 + sealed.count)
        for shift in [24, 16, 8, 0] {
            record.append(UInt8((sealed.count >> shift) & 0xFF))
        }
        record.append(sealed)
        return record
    }

    /// Take one message off the front of `buffer` if a whole record is there.
    /// Returns nil when more bytes are needed; throws when the stream is no
    /// longer trustworthy.
    public func open(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let base = buffer.startIndex
        var sealedLength = 0
        for i in 0..<4 { sealedLength = sealedLength << 8 | Int(buffer[base + i]) }
        guard sealedLength >= SMT.overhead,
              sealedLength <= Self.maxMessage + SMT.overhead else {
            throw Failure.tampered
        }
        guard buffer.count >= 4 + sealedLength else { return nil }

        let record = buffer.subdata(in: (base + 4)..<(base + 4 + sealedLength))
        // A fresh window each time: the counter must be exactly the next one, so
        // a sliding window would accept a reordering TCP cannot produce.
        var window = SMTReplayWindow()
        guard let (plaintext, counter) = SMTPacket.open(record, direction: fromHost,
                                                        window: &window),
              counter == expectedCounter else {
            throw Failure.tampered
        }
        expectedCounter &+= 1
        buffer.removeSubrange(base..<(base + 4 + sealedLength))
        return plaintext
    }
}
