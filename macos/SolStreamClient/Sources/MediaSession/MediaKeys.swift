// MediaKeys.swift — SMT/1's key schedule on the Mac.
//
// The other half of what windows/SolStreamAgent/main.cpp derives, and pinned by
// the same frozen vector (spike/smt-vectors): if either drifts, that vector stops
// matching and says so before a socket is involved.
//
// There is no second pairing step and no user-visible ceremony. The agent
// channel has already authenticated both ends, so the media keys come from an
// ephemeral ECDH over that channel with the token mixed into the input key
// material -- which is what makes a token stolen later useless against a session
// that has already ended.

import Foundation
import CryptoKit
import SolStreamLogging

/// Everything one session needs, cut from a single 108-byte expansion.
public struct MediaKeys: Sendable {
    /// Host to client, and client to host. Separate keys, so a datagram captured
    /// in one direction can never be replayed into the other.
    public let hostToClient: SymmetricKey
    public let clientToHost: SymmetricKey
    /// The nonce's fixed field per direction, six bytes, never transmitted.
    public let fixedHostToClient: Data
    public let fixedClientToHost: Data
    /// Low byte goes on the wire as `sessTag`; it is a demux hint and never an
    /// authority, because the authentication tag is always the authority.
    public let sessionId: UInt32
    /// Each side proves it derived the same 108 bytes rather than discovering it
    /// did not, one failed packet at a time, with nothing in any log to say so.
    public let hostAuth: Data
    public let clientAuth: Data

    public var sessionTag: UInt8 { UInt8(sessionId & 0xFF) }
}

public enum MediaKeySchedule {

    /// Derive the session from the handshake both ends just exchanged.
    ///
    /// - Parameters:
    ///   - secret: the ECDH shared secret, x-coordinate big-endian. CryptoKit
    ///     hands it over that way; Windows does not, and reverses it.
    ///   - token: the agent token, as its 32 hex characters.
    public static func derive(clientPublic: Data,
                              hostPublic: Data,
                              clientNonce: Data,
                              hostNonce: Data,
                              hostCount: UInt64,
                              secret: Data,
                              token: String,
                              epoch: UInt16 = 0) -> MediaKeys? {
        guard clientPublic.count == 65, hostPublic.count == 65,
              clientNonce.count == 32, hostNonce.count == 32, secret.count == 32,
              let tokenBytes = Data(smtHex: token) else { return nil }

        var transcript = Data("SMT/1".utf8)
        transcript += clientPublic
        transcript += hostPublic
        transcript += clientNonce
        transcript += hostNonce
        for i in 0..<8 { transcript.append(UInt8((hostCount >> (56 - 8 * i)) & 0xFF)) }
        let transcriptHash = Data(SHA256.hash(data: transcript))

        // The token is INPUT KEY MATERIAL, not merely transcript. Mixing it here
        // rather than only into the hash is what buys backward secrecy: an
        // attacker who steals it later still cannot derive a past session's keys
        // without the ECDH private half, which that session discarded.
        var ikm = secret
        ikm += tokenBytes
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm),
                                       salt: transcriptHash)

        var info = Data("SMT/1 keys v1".utf8)
        info.append(UInt8(epoch >> 8))
        info.append(UInt8(epoch & 0xFF))
        info += transcriptHash
        let okm = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info,
                                      outputByteCount: 108)
            .withUnsafeBytes { Data($0) }

        let sid = okm[76..<80].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return MediaKeys(hostToClient: SymmetricKey(data: okm[0..<32]),
                         clientToHost: SymmetricKey(data: okm[32..<64]),
                         fixedHostToClient: Data(okm[64..<70]),
                         fixedClientToHost: Data(okm[70..<76]),
                         sessionId: sid,
                         hostAuth: Data(okm[80..<92]),
                         clientAuth: Data(okm[92..<104]))
    }
}

extension Data {
    /// Lowercase hex, which is what every field on the agent channel uses.
    public var smtHex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(smtHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}
