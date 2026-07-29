// SMTPacket.swift — SMT/1's packet layer on the Mac.
//
// The other half of windows/SolStreamAgent/media/smt.h, pinned by the same
// frozen vector in spike/smt-vectors: eight cleartext bytes, AES-256-GCM, the
// tag last, and the header as the AAD verbatim.
//
//   off  w  field
//    0   1  verEpoch   high nibble = version (1); low nibble = key epoch mod 16
//    1   1  sessTag    low byte of the derived 32-bit session id
//    2   6  counter    48-bit big-endian, per-direction AEAD invocation number
//    8   N  ciphertext
//  8+N  16  tag
//
// The packet TYPE is the first plaintext byte and therefore inside the AEAD. An
// observer cannot tell video from input from a keepalive, and a forger cannot
// turn one into another.

import Foundation
import CryptoKit

public enum SMT {
    public static let headerBytes = 8
    public static let tagBytes = 16
    public static let overhead = headerBytes + tagBytes
    /// 1500 MTU less IPv4+UDP (28) less the SMT overhead (24).
    public static let maxPlaintext = 1448

    public static let typePing: UInt8 = 0x01
    public static let typePong: UInt8 = 0x02
    public static let typeVideo: UInt8 = 0x10
    public static let typeAudio: UInt8 = 0x20
    public static let typeInput: UInt8 = 0x30
    public static let typeFeedback: UInt8 = 0x40
    public static let typeHostStat: UInt8 = 0x41
    public static let typeBye: UInt8 = 0x50

    public static let flagFrameStart: UInt8 = 0x01
    public static let flagFrameEnd: UInt8 = 0x04
    public static let flagIdr: UInt8 = 0x08
}

/// One direction's sealing state.
///
/// The counter is never reset, including across a rekey: everything above it
/// indexes on it, and 2^48 invocations at 2500 packets a second is 3,570 years.
public final class SMTDirection {
    let key: SymmetricKey
    let fixed: Data
    private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey, fixed: Data) {
        self.key = key
        self.fixed = fixed
    }

    func nextCounter() -> UInt64 {
        defer { counter &+= 1 }
        return counter
    }
}

/// A 1024-packet sliding replay window, recorded only AFTER the AEAD opens.
///
/// A counter that is merely old still has to fail authentication to prove it is
/// a replay rather than a reordering. Recording before the tag is checked would
/// let anyone puncture the window with garbage.
public struct SMTReplayWindow {
    private var highest: UInt64 = 0
    private var bits = [UInt64](repeating: 0, count: 16)
    private var started = false

    public init() {}

    public func seenOrTooOld(_ counter: UInt64) -> Bool {
        guard started else { return false }
        if counter > highest { return false }
        let behind = highest - counter
        if behind >= 1024 { return true }
        return (bits[Int(behind / 64)] >> (behind % 64)) & 1 == 1
    }

    public mutating func record(_ counter: UInt64) {
        if !started {
            started = true
            highest = counter
            bits[0] = 1
            return
        }
        if counter > highest {
            let shift = counter - highest
            var slid = [UInt64](repeating: 0, count: 16)
            if shift < 1024 {
                for slot in 0..<1024 where (bits[slot / 64] >> (slot % 64)) & 1 == 1 {
                    let moved = UInt64(slot) + shift
                    if moved < 1024 { slid[Int(moved / 64)] |= 1 << (moved % 64) }
                }
            }
            bits = slid
            highest = counter
            bits[0] |= 1
            return
        }
        let behind = highest - counter
        if behind < 1024 { bits[Int(behind / 64)] |= 1 << (behind % 64) }
    }
}

public enum SMTPacket {

    static func be(_ value: UInt64, _ width: Int) -> Data {
        var out = Data(count: width)
        for i in 0..<width {
            out[i] = UInt8((value >> (8 * (width - 1 - i))) & 0xFF)
        }
        return out
    }

    static func readBE(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Build one datagram.
    public static func seal(_ plaintext: Data, direction: SMTDirection,
                            sessionTag: UInt8) -> Data? {
        let counter = direction.nextCounter()
        var header = Data(capacity: SMT.headerBytes)
        header.append((1 << 4) | 0)      // version 1, epoch 0
        header.append(sessionTag)
        header.append(be(counter, 6))

        guard let nonce = try? AES.GCM.Nonce(data: direction.fixed + be(counter, 6)),
              let box = try? AES.GCM.seal(plaintext, using: direction.key,
                                          nonce: nonce, authenticating: header)
        else { return nil }
        return header + box.ciphertext + box.tag
    }

    /// Verify and decrypt. Returns nil for anything that does not authenticate,
    /// which includes a forged header, because the header is the AAD.
    public static func open(_ datagram: Data, direction: SMTDirection,
                            window: inout SMTReplayWindow) -> (Data, UInt64)? {
        guard datagram.count >= SMT.overhead else { return nil }
        let bytes = [UInt8](datagram)
        guard bytes[0] >> 4 == 1 else { return nil }
        let counter = readBE(bytes[2..<8])
        guard !window.seenOrTooOld(counter) else { return nil }

        let header = datagram.prefix(SMT.headerBytes)
        let body = datagram.dropFirst(SMT.headerBytes).dropLast(SMT.tagBytes)
        let tag = datagram.suffix(SMT.tagBytes)
        guard let nonce = try? AES.GCM.Nonce(data: direction.fixed
                                                 + datagram.subdata(in: datagram.startIndex + 2
                                                                    ..< datagram.startIndex + 8)),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
              let plain = try? AES.GCM.open(box, using: direction.key,
                                            authenticating: header)
        else { return nil }
        window.record(counter)
        return (plain, counter)
    }
}
