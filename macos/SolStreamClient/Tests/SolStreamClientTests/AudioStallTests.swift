import XCTest
@testable import AudioRenderer

/// When CoreAudio has stopped taking sound while packets go on arriving.
final class AudioStallTests: XCTestCase {
    private let second: UInt64 = 1_000_000_000
    private let tick: UInt64 = 20_000_000   // a packet every 20 ms

    /// Packets every 20 ms for `seconds`, starting at `from`, with nothing
    /// played. Whether any of them was called a stall.
    private func packets(from: UInt64, for seconds: Double, hasPlayed: Bool = true,
                         since: inout UInt64, last: inout UInt64) -> Bool {
        var now = from
        var stalled = false
        while now < from + UInt64(seconds * 1e9) {
            stalled = AudioRenderer.stalled(playedLately: false, hasPlayed: hasPlayed,
                                            since: &since, lastPacket: &last, now: now) || stalled
            now += tick
        }
        return stalled
    }

    func testTwoSecondsOfPacketsWithNothingPlayedIsAStall() {
        var since: UInt64 = 0, last: UInt64 = 0
        XCTAssertFalse(packets(from: 10 * second, for: 1.9, since: &since, last: &last))
        XCTAssertTrue(packets(from: 10 * second + UInt64(1.9e9), for: 0.3,
                              since: &since, last: &last))
    }

    /// The host sends nothing while the PC is quiet: a short sound, three
    /// seconds of silence and the next sound are not two seconds of stall.
    func testASilenceBetweenSoundsIsNotAStall() {
        var since: UInt64 = 0, last: UInt64 = 0
        XCTAssertFalse(packets(from: 10 * second, for: 0.03, since: &since, last: &last))
        XCTAssertFalse(packets(from: 13 * second, for: 0.5, since: &since, last: &last))
    }

    /// A device that has not read once since the unit started is starting --
    /// an AirPlay speaker connecting -- not stalled.
    func testNothingIsAStallBeforeTheDeviceHasReadOnce() {
        var since: UInt64 = 0, last: UInt64 = 0
        XCTAssertFalse(packets(from: 10 * second, for: 5, hasPlayed: false,
                               since: &since, last: &last))
    }

    /// Played in between: the clock starts again.
    func testPlayingResetsIt() {
        var since: UInt64 = 0, last: UInt64 = 0
        XCTAssertFalse(packets(from: 10 * second, for: 1.5, since: &since, last: &last))
        XCTAssertFalse(AudioRenderer.stalled(playedLately: true, hasPlayed: true, since: &since,
                                             lastPacket: &last, now: 11 * second + UInt64(5e8)))
        XCTAssertFalse(packets(from: 11 * second + UInt64(5.2e8), for: 1.5,
                               since: &since, last: &last))
    }
}
