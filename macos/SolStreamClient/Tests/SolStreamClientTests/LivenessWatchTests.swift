import XCTest
@testable import SolStreamClient

/// The stream watchdog, in decoded-picture counts and clock readings.
final class LivenessWatchTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    /// What the watchdog says at each of its half-second checks, from one
    /// second after the start, with `delivered(t)` pictures decoded by then.
    private func run(until end: TimeInterval,
                     delivered: (TimeInterval) -> UInt64) -> [(TimeInterval, LivenessWatch.Action)] {
        var watch = LivenessWatch(startedAt: start)
        var said: [(TimeInterval, LivenessWatch.Action)] = []
        var t: TimeInterval = 1.0
        while t <= end {
            let action = watch.check(delivered: delivered(t), now: at(t))
            if action != .quiet { said.append((t, action)) }
            t += 0.5
        }
        return said
    }

    func testAStreamThatStopsIsStalledAndThenLost() {
        // Pictures until 2 s, then none.
        let said = run(until: 10) { t in t < 2 ? UInt64(t * 60) : 120 }
        XCTAssertEqual(said.map(\.1), [
            .stalled(seconds: 1.0, request: 1),
            .stalled(seconds: 1.5, request: 2),
            .stalled(seconds: 2.0, request: 3),
            .stalled(seconds: 2.5, request: 4),
            .stalled(seconds: 3.0, request: 5),
            .lost(seconds: 3.5),
        ])
        // The count last moved at 2 s, the stall is first seen at 2.5 s, and a
        // second after that it is said.
        XCTAssertEqual(said.first?.0, 3.5)
    }

    func testPicturesAfterAStallAreReportedAndTheCountStartsAgain() {
        // Pictures, a gap from 2 s to 4.5 s, then pictures, then none again.
        let said = run(until: 8) { t in
            if t < 2 { return 100 + UInt64(t * 60) }
            if t < 4.5 { return 300 }
            if t < 6 { return 300 + UInt64(t * 60) }
            return 1000
        }
        XCTAssertEqual(said.map(\.1), [
            .stalled(seconds: 1.0, request: 1),
            .stalled(seconds: 1.5, request: 2),
            .resumed,
            .stalled(seconds: 1.0, request: 1),
            .stalled(seconds: 1.5, request: 2),
        ])
    }

    /// A session that never decodes a picture used to be left alone for good:
    /// no request, no "Lost the stream", no Try Again. After the grace period
    /// it is a stall that began at the start.
    func testASessionThatNeverDecodesAPictureIsStalledAndThenLost() {
        let said = run(until: 10) { _ in 0 }
        XCTAssertEqual(said.map(\.0), [3.0, 3.5, 4.0, 4.5, 5.0, 5.5])
        XCTAssertEqual(said.map(\.1), [
            .stalled(seconds: 3.0, request: 1),
            .stalled(seconds: 3.5, request: 2),
            .stalled(seconds: 4.0, request: 3),
            .stalled(seconds: 4.5, request: 4),
            .stalled(seconds: 5.0, request: 5),
            .lost(seconds: 5.5),
        ])
    }

    /// A first picture inside the grace period: nothing to say at all.
    func testAFirstPictureWithinTheGracePeriodSaysNothing() {
        let said = run(until: 2.5) { t in t < 2 ? 0 : UInt64(t * 60) }
        XCTAssertTrue(said.isEmpty)
    }

    /// A first picture after a stall was reported is a resumption.
    func testAFirstPictureAfterTheWatchdogSpokeIsReportedAsResumed() {
        let said = run(until: 5) { t in t < 4 ? 0 : 1 }
        XCTAssertEqual(said.map(\.1), [
            .stalled(seconds: 3.0, request: 1),
            .stalled(seconds: 3.5, request: 2),
            .resumed,
        ])
    }
}
