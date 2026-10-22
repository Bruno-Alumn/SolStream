// KeyframeHold.swift — which pictures reach the decoder, and when to ask for a
// keyframe.
//
// The host's P-frames each refer to the picture before them, and its keyframes
// come only on request. So a picture that never arrives breaks every picture
// after it until an IDR, and the Mac's whole answer to loss is to hold the last
// good picture on screen and ask for one. This is that rule, kept apart from
// MediaClient's socket, threads and locks so that every decision in it is a
// function of frame ids and clock readings and can be tested with nothing else.

import Foundation

struct KeyframeHold {

    enum Verdict: Equatable {
        /// Hand the picture to the decoder.
        case decode
        /// Keep it from the decoder; a keyframe has already been asked for.
        case hold
        /// Keep it from the decoder, and ask the host for a keyframe now.
        case holdAndAsk
        /// Nothing to do: damage the stream has already been repaired past.
        case ignore
    }

    /// A lost run reports every picture in it at once, and one request covers
    /// the lot.
    static let burstMs: Double = 20
    /// Still holding this long after asking: the request or the IDR was lost.
    /// Just past the host's 200 ms limit, so the repeat is never the one it
    /// ignores.
    static let reaskMs: Double = 250

    /// P-frames are being kept from the decoder until an IDR arrives.
    private(set) var holding = false
    /// The last IDR handed to the decoder.
    private(set) var lastIdr: UInt32?
    /// When the host was last asked for a keyframe, in uptime nanoseconds.
    private var askedAt: UInt64?

    /// A complete picture.
    mutating func picture(frameId: UInt32, isIdr: Bool, now: UInt64) -> Verdict {
        if isIdr {
            holding = false
            lastIdr = frameId
            return .decode
        }
        return holding ? .hold : .decode
    }

    /// A picture that will never be complete.
    mutating func damaged(frameId: UInt32, now: UInt64) -> Verdict {
        // Older than the IDR that already repaired the stream: nothing still to
        // come refers to it. This used to set the hold regardless, and a report
        // that arrived just after the IDR -- the picture before it timing out
        // 25 ms after its last fragment, which on a LAN is routinely later than
        // the IDR lands -- froze every picture after that good IDR. The ask
        // that went with it fell inside the host's 200 ms limit and was
        // ignored, so the freeze lasted until the 250 ms repeat brought another
        // IDR. The reassembler now gives that picture up silently when the IDR
        // completes; this is for a late fragment that starts one again.
        if let lastIdr, frameId < lastIdr { return .ignore }
        holding = true
        return ask(now) ? .holdAndAsk : .hold
    }

    /// Whether the timer should ask again.
    mutating func reaskDue(now: UInt64) -> Bool {
        guard holding, let askedAt else { return false }
        guard Self.millis(from: askedAt, to: now) > Self.reaskMs else { return false }
        self.askedAt = now
        return true
    }

    /// Ask now unless a request went out within the last burst.
    private mutating func ask(_ now: UInt64) -> Bool {
        if let askedAt, Self.millis(from: askedAt, to: now) <= Self.burstMs {
            return false
        }
        askedAt = now
        return true
    }

    /// Never negative. The caller reads the clock before taking the lock this
    /// is mutated under, so a stamp another thread wrote in between can be
    /// newer than `now`, and UInt64 subtraction traps on underflow.
    static func millis(from stamp: UInt64, to now: UInt64) -> Double {
        now > stamp ? Double(now - stamp) / 1e6 : 0
    }
}
