import XCTest
@testable import AudioRenderer

/// When CoreAudio has stopped taking sound while packets go on arriving.
final class AudioStallTests: XCTestCase {
    func testTwoSecondsOfNothingPlayedIsAStall() {
        var since: UInt64 = 0
        let second: UInt64 = 1_000_000_000
        XCTAssertFalse(AudioRenderer.stalled(playedLately: true, since: &since, now: 10 * second))
        XCTAssertEqual(since, 0)
        // Nothing played: the clock starts, and two seconds is not yet enough.
        XCTAssertFalse(AudioRenderer.stalled(playedLately: false, since: &since, now: 10 * second))
        XCTAssertFalse(AudioRenderer.stalled(playedLately: false, since: &since, now: 12 * second))
        XCTAssertTrue(AudioRenderer.stalled(playedLately: false, since: &since, now: 12 * second + 1))
        // Said once, then counted again from the start.
        XCTAssertEqual(since, 0)
        XCTAssertFalse(AudioRenderer.stalled(playedLately: false, since: &since, now: 13 * second))
        // Played again in between: not a stall.
        XCTAssertFalse(AudioRenderer.stalled(playedLately: true, since: &since, now: 14 * second))
        XCTAssertFalse(AudioRenderer.stalled(playedLately: false, since: &since, now: 15 * second))
        XCTAssertFalse(AudioRenderer.stalled(playedLately: false, since: &since, now: 16 * second))
    }
}
