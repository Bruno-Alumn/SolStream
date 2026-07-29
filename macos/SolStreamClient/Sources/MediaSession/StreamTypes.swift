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

    public init(width: Int = 1920, height: Int = 1080, frameRate: Int = 60,
                bitrateKbps: Int = 20000, audio: Bool = true) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateKbps = bitrateKbps
        self.audio = audio
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
