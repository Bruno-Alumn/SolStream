import XCTest
@testable import AgentChannel

/// What the Mac says when the PC won't quit an app.
final class QuitAppTests: XCTestCase {

    /// The host's own reason is the most specific there is.
    func testTheHostsReasonIsShown() {
        let reason = "File Explorer is also the PC's taskbar and desktop."
        XCTAssertEqual(AgentConnection.quitRefusal(["type": "quit", "ok": false, "reason": reason]),
                       reason)
    }

    /// A host from before `quit` doesn't know the command: that is about
    /// updating the PC, not about the app.
    func testAnOldHostIsToldToUpdate() {
        let said = AgentConnection.quitRefusal(["type": "error", "message": "unknown cmd"])
        XCTAssertTrue(said.contains("too old"), said)
        XCTAssertTrue(said.contains("Update"), said)
    }

    /// The window closed on the PC between the menu and the request.
    func testAWindowAlreadyGoneSaysSo() {
        let said = AgentConnection.quitRefusal(["type": "error", "message": "no such window"])
        XCTAssertTrue(said.contains("already closed"), said)
    }

    func testAnythingElseStillSaysSomething() {
        XCTAssertFalse(AgentConnection.quitRefusal([:]).isEmpty)
        XCTAssertFalse(AgentConnection.quitRefusal(["ok": false, "reason": ""]).isEmpty)
    }
}
