import AppKit
import XCTest
import DesignSystem

/// A status line is said when its words change, and only then.
@MainActor
final class AnnouncerTests: XCTestCase {
    func testSaidOnceUntilItChanges() {
        var said: [String] = []
        let voice = DS.Announcer { text, _ in said.append(text) }
        XCTAssertTrue(voice.say("Not answering."))
        XCTAssertFalse(voice.say("Not answering."), "a refresh with the same words repeated them")
        XCTAssertTrue(voice.say("Pairing needed."))
        XCTAssertFalse(voice.say(""))
        voice.reset()
        XCTAssertTrue(voice.say("Pairing needed."))
        XCTAssertEqual(said, ["Not answering.", "Pairing needed.", "Pairing needed."])
    }

    func testThePriorityIsPassedOn() {
        var priorities: [NSAccessibilityPriorityLevel] = []
        let voice = DS.Announcer { _, priority in priorities.append(priority) }
        voice.say("Couldn't open it.", priority: .high)
        voice.say("Starting…")
        XCTAssertEqual(priorities, [.high, .medium])
    }
}
