import XCTest
@testable import MediaSession

/// Sound packets are played in order, once each, with silence for what was
/// lost.
final class AudioSequencerTests: XCTestCase {
    func testInOrderPacketsPlayWithNothingMissing() {
        var sequencer = AudioSequencer()
        XCTAssertEqual(sequencer.admit(10), .play(missing: 0))
        XCTAssertEqual(sequencer.admit(11), .play(missing: 0))
    }

    func testAGapIsCountedAsMissing() {
        var sequencer = AudioSequencer()
        _ = sequencer.admit(10)
        XCTAssertEqual(sequencer.admit(13), .play(missing: 2))
    }

    func testDuplicatesAndLatePacketsAreDropped() {
        var sequencer = AudioSequencer()
        _ = sequencer.admit(10)
        _ = sequencer.admit(12)
        XCTAssertEqual(sequencer.admit(12), .drop, "a duplicate")
        XCTAssertEqual(sequencer.admit(11), .drop, "a late one, already filled")
    }

    func testTheCountWrapsAround() {
        var sequencer = AudioSequencer()
        _ = sequencer.admit(UInt32.max)
        XCTAssertEqual(sequencer.admit(0), .play(missing: 0))
    }

    func testAFarJumpIsANewCountNotLoss() {
        var sequencer = AudioSequencer()
        _ = sequencer.admit(5000)
        XCTAssertEqual(sequencer.admit(1), .play(missing: 0), "a host that started counting again")
        XCTAssertEqual(sequencer.admit(2), .play(missing: 0))
    }
}
