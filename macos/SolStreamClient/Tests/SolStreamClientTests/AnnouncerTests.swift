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

    /// A line whose words move within one stage -- a download's percentage --
    /// is said once per stage.
    func testOncePerKey() {
        var said: [String] = []
        let voice = DS.Announcer { text, _ in said.append(text) }
        voice.say("Downloading 1.0.9… 1%", key: "downloading")
        voice.say("Downloading 1.0.9… 2%", key: "downloading")
        voice.say("Ready to install 1.0.9.", key: "ready")
        XCTAssertEqual(said, ["Downloading 1.0.9… 1%", "Ready to install 1.0.9."])
    }

    /// Only where a line settles is said.
    func testOnlyTheSettledLineIsSaid() {
        var said: [String] = []
        let voice = DS.Announcer { text, _ in said.append(text) }
        voice.sayWhenSettled("The first connection asks for the token.", after: 0.1)
        voice.sayWhenSettled("Reachable and paired.", after: 0.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(said, ["Reachable and paired."])
        voice.sayWhenSettled("Not answering.", after: 0.1)
        voice.hush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(said, ["Reachable and paired."])
    }

}
