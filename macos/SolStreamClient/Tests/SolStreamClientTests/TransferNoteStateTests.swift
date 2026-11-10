import XCTest
@testable import SolStreamClient

/// The foot-of-window note: a flash for its time over progress held beneath.
final class TransferNoteStateTests: XCTestCase {
    func testAFlashOutlastsProgressAndProgressComesBack() {
        var note = TransferNoteState()
        note.hold("Receiving a.jpg… 0%", as: .receiving)
        note.flash("a.jpg didn't arrive.")
        note.hold("Receiving b.jpg… 0%", as: .receiving)
        note.hold("Receiving b.jpg… 3%", as: .receiving)
        XCTAssertEqual(note.shown, "a.jpg didn't arrive.", "the report was wiped by the next file")
        note.expireFlash()
        XCTAssertEqual(note.shown, "Receiving b.jpg… 3%")
    }

    /// A send and a receive at once: the one begun first is shown, without
    /// flipping on every update, and the other once it ends.
    func testTwoTransfersDoNotFlip() {
        var note = TransferNoteState()
        note.hold("Sending x… 10%", as: .sending)
        note.hold("Receiving y… 5%", as: .receiving)
        note.hold("Sending x… 11%", as: .sending)
        note.hold("Receiving y… 6%", as: .receiving)
        XCTAssertEqual(note.shown, "Sending x… 11%")
        note.hold(nil, as: .sending)
        note.flash("1 file copied to the PC.")
        note.hold("Receiving y… 7%", as: .receiving)
        XCTAssertEqual(note.shown, "1 file copied to the PC.")
        note.expireFlash()
        XCTAssertEqual(note.shown, "Receiving y… 7%")
        note.hold(nil, as: .receiving)
        XCTAssertNil(note.shown)
    }

    func testANewerFlashReplacesTheOlder() {
        var note = TransferNoteState()
        note.flash("one")
        note.flash("two")
        XCTAssertEqual(note.shown, "two")
        note.expireFlash()
        XCTAssertNil(note.shown)
    }
}
