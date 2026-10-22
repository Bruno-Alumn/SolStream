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
    ///
    /// From the start, too: a P-frame before the first IDR has nothing to be
    /// decoded against. And at the start of every session the first picture to
    /// arrive WAS a P-frame, because a host that predates asking itself for an
    /// IDR when the Mac first speaks encodes its first one before it knows
    /// where the Mac is, and sends it nowhere. The decoder found no parameter
    /// sets in that P-frame and asked for an IDR on the next feedback tick,
    /// after the stream had already been called live. MediaClient now asks
    /// as the session opens instead, which such a host answers at once and a
    /// newer one, already sending, ignores under its rate limit.
    private(set) var holding = true
    /// The last IDR handed to the decoder.
    private(set) var lastIdr: UInt32?
    /// The last picture handed to the decoder.
    private(set) var lastDecoded: UInt32?
    /// When the host was last asked for a keyframe, in uptime nanoseconds, or
    /// nil before the first request.
    private var askedAt: UInt64?

    /// A complete picture.
    mutating func picture(frameId: UInt32, isIdr: Bool, now: UInt64) -> Verdict {
        if isIdr {
            holding = false
            lastIdr = frameId
            lastDecoded = frameId
            return .decode
        }
        // Older than a picture already decoded: nothing can use it.
        if let lastDecoded, frameId <= lastDecoded { return .ignore }
        if holding { return .hold }
        // Only the picture straight after the last one decoded. Every way a
        // picture can fail to arrive is reported as damage before the next one
        // gets here, and the hold is already on by then; this is what keeps a
        // P-frame from being decoded against a missing reference if one of them
        // ever is not.
        if let lastDecoded, frameId == lastDecoded &+ 1 {
            self.lastDecoded = frameId
            return .decode
        }
        holding = true
        return ask(now) ? .holdAndAsk : .hold
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

    /// Whether to ask (again) now: at once when nothing has been asked yet,
    /// which is the session opening, and otherwise once the last request has
    /// gone unanswered for a quarter-second.
    mutating func reaskDue(now: UInt64) -> Bool {
        guard holding else { return false }
        if let askedAt, Self.millis(from: askedAt, to: now) <= Self.reaskMs {
            return false
        }
        askedAt = now
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
