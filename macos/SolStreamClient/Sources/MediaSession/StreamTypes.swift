// StreamTypes.swift — what the application asks for, and what it is told back.
//
// These used to live inside StreamConnection, which is the GameStream client.
// They are here because they describe a stream rather than a protocol, and
// because the thing that owns them now is SMT/1.
//
// Two phases are gone with GameStream and are not coming back: `awaitingPin`
// and `pairing`. Two programs that ship together and have already authenticated
// each other on the agent channel do not need introducing again, so there is no
// PIN to type and no certificate to exchange.

import Foundation

public struct StreamConfig: Sendable {
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var bitrateKbps: Int
    /// Whether to ask the host for its speaker output as well as its picture.
    public var audio: Bool
    /// How the host is asked to send it, when it is asked for at all.
    public var audioEncoding: AudioEncoding

    public init(width: Int = 1920, height: Int = 1080, frameRate: Int = 60,
                bitrateKbps: Int = 20000, audio: Bool = true,
                audioEncoding: AudioEncoding = .pcm) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps
        self.audio = audio
        self.audioEncoding = audioEncoding
    }
}

/// How the host sends its sound: raw, or as Opus at a bitrate.
///
/// A request, not a promise. A host that predates Opus has never heard of the
/// fields this becomes and sends PCM whatever it is asked, so what is actually
/// played is decided per packet, by its format byte; see `SMTAudioPacket`.
public struct AudioEncoding: Equatable, Sendable {
    public enum Codec: String, Sendable {
        case pcm, opus
    }

    public var codec: Codec
    /// Opus's target, in bit/s. PCM's is fixed by its format: 48 kHz, two
    /// channels, sixteen bits.
    public var bitrate: Int
    /// The sound in one packet. Longer is fewer packets and less overhead --
    /// each costs 68 bytes of headers whatever it carries, which at 64 kbit/s
    /// is most of the stream at 10 ms -- and more delay.
    public var frameMilliseconds: Int

    /// What every host sent before Opus: 5 ms packets of 16-bit stereo.
    public static let pcm = AudioEncoding(codec: .pcm, bitrate: 1_536_000, frameMilliseconds: 5)

    public static func opus(bitrate: Int, frameMilliseconds: Int) -> AudioEncoding {
        AudioEncoding(codec: .opus, bitrate: bitrate, frameMilliseconds: frameMilliseconds)
    }

    public init(codec: Codec, bitrate: Int, frameMilliseconds: Int) {
        self.codec = codec
        self.bitrate = bitrate
        self.frameMilliseconds = frameMilliseconds
    }

    /// For the log: "Opus 128 kbit/s, 10 ms" or "PCM".
    public var summary: String {
        switch codec {
        case .pcm: return "PCM"
        case .opus: return "Opus \(bitrate / 1000) kbit/s, \(frameMilliseconds) ms"
        }
    }
}

public enum StreamPhase: Equatable, Sendable {
    case idle
    case opening
    case waitingForVideo
    case streaming
    case failed(String)
}

/// What the quality pill reports. Counted here rather than derived from the
/// decoder, so "arrived" and "displayed" stay distinguishable.
public struct MediaCounters: Sendable {
    public var frames: UInt64 = 0
    public var dropped: UInt64 = 0
    public var bytes: UInt64 = 0
    public var audioFrames: UInt64 = 0
    public var latencyMs: Int?

    public init() {}
}
