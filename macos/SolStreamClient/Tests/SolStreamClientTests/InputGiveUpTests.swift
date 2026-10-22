import XCTest
@testable import MediaSession

/// What of the unacknowledged input outlives the moment MediaClient stops
/// repeating a host that is not answering, and newer input pushing it out of
/// every datagram: the releases still owed, so a key let go of during a Wi-Fi
/// roam is not left held on the PC.
final class InputGiveUpTests: XCTestCase {
    private let wDown = SMTInput.scanKey(code: 0x11, pressed: true, modifiers: [])
    private let wUp = SMTInput.scanKey(code: 0x11, pressed: false, modifiers: [])
    private let aDown = SMTInput.key(code: 0x41, pressed: true, modifiers: [])
    private let aUp = SMTInput.key(code: 0x41, pressed: false, modifiers: [])
    private let leftDown = SMTInput.mouseButton(.left, pressed: true)
    private let leftUp = SMTInput.mouseButton(.left, pressed: false)
    private let move = SMTInput.mouseMoveRelative(deltaX: 3, deltaY: 1)

    private func seqs(_ events: [(seq: UInt32, blob: Data)]) -> [UInt32] { events.map(\.seq) }

    func testWhatAnEventHolds() {
        XCTAssertEqual(SMTInput.holdTarget(of: wDown)?.releases, false)
        XCTAssertEqual(SMTInput.holdTarget(of: wUp)?.releases, true)
        XCTAssertEqual(SMTInput.holdTarget(of: wDown)?.target, SMTInput.holdTarget(of: wUp)?.target)
        XCTAssertEqual(SMTInput.holdTarget(of: leftUp)?.releases, true)
        XCTAssertEqual(SMTInput.holdTarget(of: SMTInput.mouseButton(.extra2, pressed: false))?.releases,
                       true)
        // Different keys, buttons and kinds are different targets.
        XCTAssertNotEqual(SMTInput.holdTarget(of: wUp)?.target, SMTInput.holdTarget(of: aUp)?.target)
        XCTAssertNotEqual(SMTInput.holdTarget(of: leftUp)?.target,
                          SMTInput.holdTarget(of: SMTInput.mouseButton(.right, pressed: false))?.target)
        XCTAssertNotEqual(SMTInput.holdTarget(of: SMTInput.key(code: 0x11, pressed: false, modifiers: []))?
                            .target,
                          SMTInput.holdTarget(of: wUp)?.target)
        // Nothing held by a move, a scroll or text, nor by a malformed event.
        XCTAssertNil(SMTInput.holdTarget(of: move))
        XCTAssertNil(SMTInput.holdTarget(of: SMTInput.scroll(amount: 120)))
        XCTAssertNil(SMTInput.holdTarget(of: SMTInput.text("a")[0]))
        XCTAssertNil(SMTInput.holdTarget(of: Data([SMTInput.Kind.key.rawValue, 2, 0x00, 0x41])))
        XCTAssertNil(SMTInput.holdTarget(of: Data([SMTInput.Kind.button.rawValue, 5, 1, 0])))
        XCTAssertNil(SMTInput.holdTarget(of: Data()))
    }

    /// W let go of and the button let go of are owed; a press, a move, and a
    /// key pressed again since are not.
    func testOnlyTheReleasesStillOwedAreKept() {
        let events: [(seq: UInt32, blob: Data)] = [
            (1, leftDown), (2, wDown), (3, move), (4, wUp), (5, aDown), (6, leftUp),
        ]
        XCTAssertEqual(seqs(SMTInput.releasesStillOwed(events)), [4, 6])
    }

    /// A release with a newer press of the same key after it is not owed: sent
    /// late, it would let go of a key the hand is holding.
    func testAReleaseSupersededByAPressIsNotKept() {
        let events: [(seq: UInt32, blob: Data)] = [(1, wUp), (2, wDown)]
        XCTAssertTrue(SMTInput.releasesStillOwed(events).isEmpty)
        let again: [(seq: UInt32, blob: Data)] = [(1, wUp), (2, wDown), (3, wUp)]
        XCTAssertEqual(seqs(SMTInput.releasesStillOwed(again)), [3])
    }

    /// Kept, and repeated, for five seconds from when each was first kept,
    /// however often the give-up comes round.
    func testAReleaseIsKeptForFiveSeconds() {
        let pending: [(seq: UInt32, blob: Data)] = [(7, aDown), (8, aUp), (9, move)]
        let start: UInt64 = 1_000_000_000
        var kept = MediaClient.keptPastGivingUp(pending, keptSince: [:], now: start)
        XCTAssertEqual(seqs(kept.events), [8])
        XCTAssertEqual(kept.keptSince, [8: start])

        let later = start + MediaClient.releaseKeepNanos - 1
        kept = MediaClient.keptPastGivingUp(kept.events, keptSince: kept.keptSince, now: later)
        XCTAssertEqual(seqs(kept.events), [8], "the stamp moved, so it would be kept for ever")
        XCTAssertEqual(kept.keptSince, [8: start])

        kept = MediaClient.keptPastGivingUp(kept.events, keptSince: kept.keptSince,
                                            now: start + MediaClient.releaseKeepNanos)
        XCTAssertTrue(kept.events.isEmpty)
        XCTAssertTrue(kept.keptSince.isEmpty)
    }

    /// A release kept from an earlier give-up and one new to this one each
    /// keep their own time.
    func testEachReleaseKeepsItsOwnTime() {
        let start: UInt64 = 2_000_000_000
        let pending: [(seq: UInt32, blob: Data)] = [(3, wUp), (10, leftUp)]
        let kept = MediaClient.keptPastGivingUp(pending, keptSince: [3: start],
                                                now: start + MediaClient.releaseKeepNanos)
        XCTAssertEqual(seqs(kept.events), [10])
        XCTAssertEqual(kept.keptSince, [10: start + MediaClient.releaseKeepNanos])
    }

    /// Nothing owed, nothing kept: the give-up empties the tail as it did.
    func testWithNoReleaseOwedNothingIsKept() {
        let pending: [(seq: UInt32, blob: Data)] = [(1, move), (2, aDown)]
        let kept = MediaClient.keptPastGivingUp(pending, keptSince: [:], now: 5)
        XCTAssertTrue(kept.events.isEmpty)
    }

    // MARK: - Every datagram, while input keeps coming

    /// What `sendInput` does with each new event: add it, then carry and keep
    /// what `inputBatch` says. Returns each datagram's sequence numbers.
    private struct Sender {
        var unacked: [(seq: UInt32, blob: Data)] = []
        var keptSince: [UInt32: UInt64] = [:]
        var nextSeq: UInt32 = 1

        mutating func send(_ blob: Data, at now: UInt64) -> [UInt32] {
            unacked.append((nextSeq, blob))
            nextSeq += 1
            let out = MediaClient.inputBatch(unacked, keptSince: keptSince, now: now)
            unacked = out.unacked
            keptSince = out.keptSince
            return out.batch.map(\.seq)
        }
    }

    /// W let go of in a network gap while the mouse goes on moving: W-up is in
    /// every datagram, ahead of the newest eight, and outlives the tail of
    /// thirty-two. It used to be in none after the eighth move.
    func testAReleaseFollowedByFortyMovesIsStillSentAndKept() {
        var sender = Sender()
        let start: UInt64 = 1_000_000_000
        _ = sender.send(wDown, at: start)
        _ = sender.send(wUp, at: start)
        for n in 1...40 {
            let batch = sender.send(move, at: start + UInt64(n) * 10_000_000)
            XCTAssertTrue(batch.contains(2), "W-up was not sent with move \(n)")
            // W-up, then the newest eight, in sequence order.
            let newest = Array((sender.nextSeq > 8 ? sender.nextSeq - 8 : 1) ..< sender.nextSeq)
            XCTAssertEqual(batch, newest.contains(2) ? newest : [2] + newest)
        }
        XCTAssertTrue(sender.unacked.contains { $0.seq == 2 }, "W-up was trimmed away")
        XCTAssertFalse(sender.unacked.contains { $0.seq == 1 }, "W-down was kept past the tail")
        XCTAssertEqual(sender.unacked.count, 33, "the tail of thirty-two, and W-up")
        // Its time is when it fell behind the newest eight.
        XCTAssertEqual(sender.keptSince[2], start + 8 * 10_000_000)
    }

    /// For five seconds from then, and no longer: an acknowledgement held back
    /// by an older event the host never got would otherwise have it repeated
    /// for the rest of the session.
    func testAReleaseBehindTheNewestIsCarriedForFiveSeconds() {
        var sender = Sender()
        _ = sender.send(wUp, at: 0)
        for _ in 1...8 { _ = sender.send(move, at: 1) }
        XCTAssertEqual(sender.keptSince[1], 1)
        let justBefore = sender.send(move, at: MediaClient.releaseKeepNanos)
        XCTAssertTrue(justBefore.contains(1))
        let after = sender.send(move, at: 1 + MediaClient.releaseKeepNanos)
        XCTAssertFalse(after.contains(1), "carried past its five seconds")
        // Still in the tail, so still kept, with its time: not carried again.
        XCTAssertTrue(sender.unacked.contains { $0.seq == 1 })
        XCTAssertEqual(sender.keptSince[1], 1)
        // And let go of when the tail moves on.
        for _ in 1...32 { _ = sender.send(move, at: 2 * MediaClient.releaseKeepNanos) }
        XCTAssertFalse(sender.unacked.contains { $0.seq == 1 })
        XCTAssertNil(sender.keptSince[1])
    }

    /// W pressed again since: its old release is owed no longer, and sent late
    /// it would let go of the W now held.
    func testAReleaseSupersededIsNoLongerCarried() {
        var sender = Sender()
        _ = sender.send(wUp, at: 0)
        for _ in 1...10 { _ = sender.send(move, at: 0) }
        XCTAssertTrue(sender.send(move, at: 0).contains(1))
        let batch = sender.send(wDown, at: 0)
        XCTAssertFalse(batch.contains(1))
        XCTAssertNil(sender.keptSince[1])
    }

    /// More releases owed than the eight newest events: every one is carried.
    func testMoreThanEightReleasesAreAllCarried() {
        let keys: [UInt16] = Array(0x10...0x1B)
        var sender = Sender()
        for key in keys {
            _ = sender.send(SMTInput.scanKey(code: key, pressed: true, modifiers: []), at: 0)
        }
        for key in keys {
            _ = sender.send(SMTInput.scanKey(code: key, pressed: false, modifiers: []), at: 0)
        }
        let releases = Array(UInt32(keys.count + 1)...UInt32(2 * keys.count))
        let batch = sender.send(move, at: 0)
        XCTAssertEqual(batch, releases + [batch.last!], "a release was left out")
    }

    /// A datagram too big for the link loses its oldest text first, never a
    /// release still owed nor the newest event; a batch over the limit used
    /// to be not sent at all.
    func testABatchIsCutToOneDatagram() {
        let text = SMTInput.text(String(repeating: "a", count: 127))[0]
        XCTAssertEqual(text.count, 256)
        var pending: [(seq: UInt32, blob: Data)] = [(1, wUp)]
        for seq in UInt32(2)...9 { pending.append((seq, text)) }
        let batch = MediaClient.inputBatch(pending, keptSince: [:], now: 0).batch
        let size = 4 + batch.reduce(0) { $0 + 4 + $1.blob.count }
        XCTAssertLessThanOrEqual(size, SMT.maxPlaintext)
        XCTAssertEqual(batch.first?.seq, 1, "the release went")
        XCTAssertEqual(batch.last?.seq, 9, "the newest event went")
        XCTAssertEqual(batch.map(\.seq), batch.map(\.seq).sorted())
        XCTAssertEqual(batch.count, 1 + 5)
    }

    // MARK: - The timer

    /// What the timer does over `ticks`, `sinceSentMs` after the last new
    /// event, starting from `unacked`.
    private func run(_ unacked: [(seq: UInt32, blob: Data)], ticks: ClosedRange<Int>,
                     sinceSentMs: Double, now: UInt64 = 0)
        -> (unacked: [(seq: UInt32, blob: Data)], sentOn: [Int: [UInt32]]) {
        var tail = unacked
        var keptSince: [UInt32: UInt64] = [:]
        var sentOn: [Int: [UInt32]] = [:]
        for tick in ticks {
            let step = MediaClient.repeatStep(tail, inputAck: 0, sinceSentMs: sinceSentMs,
                                              keptSince: keptSince, tick: tick, now: now)
            tail = step.unacked
            keptSince = step.keptSince
            if !step.repeats.isEmpty { sentOn[tick] = step.repeats.map(\.seq) }
        }
        return (tail, sentOn)
    }

    /// Within 300 ms of new input, the datagram it went in is sent again on
    /// every tick.
    func testTheTimerRepeatsEveryTickWhileInputIsFresh() {
        let pending: [(seq: UInt32, blob: Data)] = [(7, aDown), (8, aUp), (9, move)]
        let result = run(pending, ticks: 1...20, sinceSentMs: 100)
        XCTAssertEqual(result.sentOn.count, 20)
        XCTAssertEqual(result.sentOn[13], [7, 8, 9])
        XCTAssertEqual(result.unacked.map(\.seq), [7, 8, 9])
    }

    /// After the give-up, the release survives and goes every tenth tick; the
    /// press and the move are gone.
    func testAReleaseSurvivesTheGiveUpAndRepeatsEveryTenthTick() {
        let pending: [(seq: UInt32, blob: Data)] = [(7, aDown), (8, aUp), (9, move)]
        let result = run(pending, ticks: 1...30, sinceSentMs: 301)
        XCTAssertEqual(result.unacked.map(\.seq), [8], "the release was dropped at the give-up")
        XCTAssertEqual(result.sentOn, [10: [8], 20: [8], 30: [8]])
    }

    /// With nothing owed, the give-up sends nothing more and keeps nothing.
    func testTheGiveUpWithNothingOwedGoesQuiet() {
        let result = run([(1, move), (2, aDown)], ticks: 1...20, sinceSentMs: 301)
        XCTAssertTrue(result.unacked.isEmpty)
        XCTAssertTrue(result.sentOn.isEmpty)
    }

    /// Every release kept past the give-up is sent, not the newest eight of
    /// them.
    func testEveryKeptReleaseIsRepeatedNotJustEight() {
        let keys: [UInt16] = Array(0x10...0x1B)
        let pending = keys.enumerated().map { index, key in
            (seq: UInt32(index + 1), blob: SMTInput.scanKey(code: key, pressed: false, modifiers: []))
        }
        let result = run(pending, ticks: 1...10, sinceSentMs: 301)
        XCTAssertEqual(result.sentOn[10], Array(1...UInt32(keys.count)))
    }

    /// And not after five seconds.
    func testKeptReleasesStopAfterFiveSeconds() {
        let start: UInt64 = 1_000_000_000
        var step = MediaClient.repeatStep([(8, aUp)], inputAck: 0, sinceSentMs: 301, keptSince: [:],
                                          tick: 10, now: start)
        XCTAssertEqual(step.repeats.map(\.seq), [8])
        step = MediaClient.repeatStep(step.unacked, inputAck: 0, sinceSentMs: 301,
                                      keptSince: step.keptSince, tick: 20,
                                      now: start + MediaClient.releaseKeepNanos)
        XCTAssertTrue(step.unacked.isEmpty)
        XCTAssertTrue(step.repeats.isEmpty)
    }

    /// What the host has acknowledged is neither kept nor sent.
    func testTheTimerSkipsWhatTheHostHas() {
        let step = MediaClient.repeatStep([(7, aDown), (8, aUp)], inputAck: 7, sinceSentMs: 0,
                                          keptSince: [:], tick: 1, now: 0)
        XCTAssertEqual(step.repeats.map(\.seq), [8])
    }
}
