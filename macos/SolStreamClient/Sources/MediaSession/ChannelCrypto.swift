// ChannelCrypto.swift — encrypting the agent channel with what auth v2 agreed.
//
// The other half of windows/SolStreamAgent/media/channel.h. TCP 47630 carries
// window titles, application names, the display layout, the cursor shape and the
// entire clipboard, and until this existed it carried all of it in the clear —
// beside a media path that had been AES-256-GCM since the day it was written.
//
// No new handshake. Auth v2 already leaves both ends holding the token, a
// host-chosen challenge and a client-chosen nonce, and already proves possession
// without transmitting the token. Those three key the channel under a different
// label, so this costs no extra round trip.
//
//   PRK = HKDF-Extract(salt: SHA256("SolStream channel v1" || challenge || cnonce),
//                      ikm:  tokenBytes)
//   okm = HKDF-Expand(PRK, "SolStream channel keys v1", 76)
//
// NOT forward secret, and the header on the Windows side says so too: an
// attacker who later learns the token can decrypt a recorded session, because
// there is no ephemeral key here. The media path mixes in an ECDH secret that is
// discarded when the session ends; doing the same for the channel means a
// Diffie-Hellman before the channel is encrypted, and it is worth doing. What
// this removes is passive disclosure to anyone on the path, which was true of
// every session at once.
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
    /// TCP delivers in order and exactly once, so the next record's counter is
    /// known rather than guessed. A replay window here would be answering a
    /// question the transport below has already answered.
    private var expectedCounter: UInt64 = 0

    public init?(token: String, challenge: String, clientNonce: String) {
        guard let tokenBytes = Data(smtHex: token), !tokenBytes.isEmpty,
              !challenge.isEmpty, !clientNonce.isEmpty else { return nil }

        // The salt binds the keys to THIS connection: the challenge is fresh
        // from the host and the nonce fresh from this Mac, so neither end can
        // force a key it has seen before.
        var transcript = Data("SolStream channel v1".utf8)
        transcript += Data(challenge.utf8)
        transcript += Data(clientNonce.utf8)
        let salt = Data(SHA256.hash(data: transcript))

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: tokenBytes),
                                       salt: salt)
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk,
                                      info: Data("SolStream channel keys v1".utf8),
                                      outputByteCount: 76)
            .withUnsafeBytes { Data($0) }

        toHost = SMTDirection(key: SymmetricKey(data: okm[32..<64]),
                              fixed: Data(okm[70..<76]))
        fromHost = SMTDirection(key: SymmetricKey(data: okm[0..<32]),
                                fixed: Data(okm[64..<70]))
        sessionTag = okm[75]
    }

    /// Seal one message into a length-prefixed record.
    public func seal(_ message: Data) throws -> Data {
        guard message.count <= Self.maxMessage else { throw Failure.tooLarge }
        guard let sealed = SMTPacket.seal(message, direction: toHost,
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
