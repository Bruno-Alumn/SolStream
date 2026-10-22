// SMTAudio.swift — one packet of the host's sound, as SMT/1 carries it.
//
// The other half of windows/SolStreamAgent/media/audio.h. Sixteen bytes of
// header, then one packet of sound:
//
//   off  w  field
//    0   1  type = 0x20
//    1   1  flags (none yet)
//    2   1  channels
//    3   1  format: 1 = signed 16-bit little-endian PCM, interleaved
//                   2 = one Opus packet (RFC 6716), 48 kHz
//    4   4  sequence, big-endian
//    8   4  timestamp in microseconds since the session started
//   12   4  sample rate
//   16   N  the sound
//
// The format is in every packet, and the packet is what decides how it is
// played -- not what the Mac asked for. A host that predates Opus ignores the
// request and goes on sending format 1, and that has to play exactly as it
// always did rather than be handed to a decoder expecting something else.

import Foundation

public struct SMTAudioPacket: Equatable, Sendable {
    public enum Format: UInt8, Sendable {
        case pcm16 = 1
        case opus = 2
    }

    public static let headerBytes = 16

    public var format: Format
    public var channels: Int
    public var sequence: UInt32
    public var timestampMicros: UInt32
    public var sampleRate: UInt32
    public var payload: Data

    public init(format: Format, channels: Int = 2, sequence: UInt32, timestampMicros: UInt32 = 0,
                sampleRate: UInt32 = 48_000, payload: Data) {
        self.format = format
        self.channels = channels
        self.sequence = sequence
        self.timestampMicros = timestampMicros
        self.sampleRate = sampleRate
        self.payload = payload
    }

    /// Parse a decrypted audio packet, type byte included.
    ///
    /// Nil for anything that is not one: too short to hold a header and some
    /// sound, the wrong type, or a format this build does not know. An unknown
    /// format is dropped rather than guessed at, because guessing at audio is
    /// white noise at full scale.
    public init?(plaintext: Data) {
        guard plaintext.count > Self.headerBytes else { return nil }
        let b = [UInt8](plaintext.prefix(Self.headerBytes))
        guard b[0] == SMT.typeAudio, let format = Format(rawValue: b[3]), b[2] > 0 else {
            return nil
        }
        self.format = format
        channels = Int(b[2])
        sequence = UInt32(SMTPacket.readBE(b[4..<8]))
        timestampMicros = UInt32(SMTPacket.readBE(b[8..<12]))
        sampleRate = UInt32(SMTPacket.readBE(b[12..<16]))
        payload = Data(plaintext.dropFirst(Self.headerBytes))
    }

    /// The packet as the host lays it out. The host is what builds these; this
    /// is here so the layout is written down once on this side too, and so the
    /// tests can feed the parser exactly what goes on the wire.
    public var plaintext: Data {
        Data([SMT.typeAudio, 0, UInt8(clamping: channels), format.rawValue])
            + SMTPacket.be(UInt64(sequence), 4)
            + SMTPacket.be(UInt64(timestampMicros), 4)
            + SMTPacket.be(UInt64(sampleRate), 4)
            + payload
    }
}
