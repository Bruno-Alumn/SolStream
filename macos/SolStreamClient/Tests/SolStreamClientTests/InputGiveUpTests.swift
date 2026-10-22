import XCTest
@testable import MediaSession

/// What of the unacknowledged input outlives the moment MediaClient stops
/// repeating a host that is not answering: the releases still owed, so a key
/// let go of during a Wi-Fi roam is not left held on the PC.
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
}
