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
        /// Nothing to do: a picture older than one already decoded, or damage
        /// that an IDR already decoded, or one on its way, makes good.
        case ignore
    }

    /// A lost run reports every picture in it at once, and one request covers
    /// the lot.
    static let burstMs: Double = 20
    /// The host acts on one keyframe request per this long, and drops the rest
    /// without a word.
    static let hostLimitMs: Double = 200
    /// Still holding this long after asking: the request or the IDR was lost.
    /// Just past the host's 200 ms limit, so the repeat is never the one it
    /// ignores.
    static let reaskMs: Double = 250
    /// On a path whose round trip is longer than that, the IDR cannot have
    /// begun to arrive by then. A round trip, then a frame period or so to
    /// capture and encode it, and room for jitter.
    static let reaskMarginMs: Double = 100
    /// The round trip to go on before one has been measured. MediaClient's
    /// reads 0 until the first pong, and taken at its word that is the
    /// shortest path there is: over a relayed path with a round trip longer
    /// than a quarter-second, the opening request was repeated before the
    /// IDR it asked for could have begun to arrive, after the host's limit
    /// had run out, and a second full IDR followed the first at the start of
    /// every session. On a LAN the first pong is back within milliseconds, so
    /// this only ever holds back a slow path's repeat -- or one where the
    /// first ping or its pong was lost, and that is still repeated, a little
    /// later.
    static let unmeasuredRttMs: Double = 500

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
    /// When the host was last sent a keyframe request it acted on, as far as
    /// this side can tell, in uptime nanoseconds, or nil before the first
    /// request. The repeat is counted from this. See `sent`.
    private var askedAt: UInt64?
    /// When the last request of any kind went out, for one per burst.
    private var sentAt: UInt64?
    /// When an IDR, or a fragment of one, last arrived: the sign that the host
    /// acted on a request sent before it.
    private var idrSeenAt: UInt64?
    /// The IDR whose fragments are arriving while the hold is on, and when the
    /// latest of them came.
    private var arrivingIdr: (frameId: UInt32, at: UInt64)?

    /// A complete picture.
    mutating func picture(frameId: UInt32, isIdr: Bool, now: UInt64) -> Verdict {
        if isIdr {
            idrSeenAt = now
            holding = false
            lastIdr = frameId
            lastDecoded = frameId
            arrivingIdr = nil
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
        if let idr = arrivingIdr {
            // The same for one older than an IDR that is on its way: asking
            // again could only bring a second one.
            if frameId < idr.frameId { return .ignore }
            // And the one on its way is what broke, so it is no longer coming.
            if frameId == idr.frameId { arrivingIdr = nil }
        }
        holding = true
        return ask(now) ? .holdAndAsk : .hold
    }

    /// The decoder lost the pictures the next ones refer to: a session that
    /// failed and had to be rebuilt. Nothing short of an IDR helps it.
    mutating func lostReference(now: UInt64) -> Verdict {
        holding = true
        return ask(now) ? .holdAndAsk : .hold
    }

    /// A fragment of an IDR. While the hold is on, that is the answer to the
    /// request arriving, and it counts as progress.
    mutating func idrArriving(frameId: UInt32, now: UInt64) {
        guard holding else { return }
        if let lastDecoded, frameId <= lastDecoded { return }
        idrSeenAt = now
        arrivingIdr = (frameId, now)
    }

    /// Whether to ask (again) now: at once when nothing has been asked yet,
    /// which is the session opening, and otherwise once the last request the
    /// host can have acted on has gone unanswered for a quarter-second -- or a
    /// round trip and a little more, where that is longer. `rttMs` is nil
    /// until a round trip has been measured.
    ///
    /// Unanswered means no fragment of the IDR either. The repeat used to fire
    /// on the clock alone, and over a relayed path -- a 150-200 ms round trip,
    /// and 60-120 ms more for a 200-300 KB IDR to arrive at the paced rate --
    /// it went out while the IDR it was repeating was landing, the host's limit
    /// had expired, and a second full IDR followed the first into the narrowest
    /// path there is. Counting from the latest fragment instead, the repeat
    /// comes only once the IDR has stopped arriving; and an IDR that broke on
    /// the way is reported damaged, which asks at once.
    mutating func reaskDue(now: UInt64, rttMs: Double?) -> Bool {
        guard holding else { return false }
        if var since = askedAt {
            if let idr = arrivingIdr, idr.at > since { since = idr.at }
            let rtt = rttMs ?? Self.unmeasuredRttMs
            let interval = max(Self.reaskMs, rtt + Self.reaskMarginMs)
            if Self.millis(from: since, to: now) <= interval { return false }
        }
        sent(now)
        return true
    }

    /// Ask now unless a request went out within the last burst.
    private mutating func ask(_ now: UInt64) -> Bool {
        if let sentAt, Self.millis(from: sentAt, to: now) <= Self.burstMs {
            return false
        }
        sent(now)
        return true
    }

    /// A request is going out now.
    ///
    /// One inside the host's limit still goes: it is one datagram, and if the
    /// request before it was lost on the way, it is the one the host acts on.
    /// But once an IDR has arrived since the request before it, the host
    /// acted on that one and has all but certainly ignored this, so it does
    /// not restart the repeat. It used to: on a LAN a requested IDR that
    /// breaks on the way is reported damaged 100-170 ms after the request that
    /// brought it, and the repeat then came a quarter-second after the request
    /// the host ignored rather than the one it acted on -- about 150 ms more
    /// of a frozen picture. The same for fresh damage soon after a repair.
    ///
    /// With no IDR since, the request before may never have reached the host,
    /// and this one is then the one it acts on. Counting the repeat from the
    /// lost one brought it up to 200 ms early: over a 300 ms round trip,
    /// before the IDR could begin to arrive and past the host's limit, so a
    /// second full IDR; on a LAN, inside the limit, so one the host ignored.
    private mutating func sent(_ now: UInt64) {
        sentAt = now
        if let askedAt, Self.millis(from: askedAt, to: now) <= Self.hostLimitMs,
           let idrSeenAt, idrSeenAt > askedAt {
            return
        }
        askedAt = now
    }

    /// Never negative. A caller is free to read the clock before taking the
    /// lock this is mutated under, and a stamp another thread wrote in between
    /// is then newer than `now`; UInt64 subtraction traps on underflow.
    static func millis(from stamp: UInt64, to now: UInt64) -> Double {
        now > stamp ? Double(now - stamp) / 1e6 : 0
    }
}
