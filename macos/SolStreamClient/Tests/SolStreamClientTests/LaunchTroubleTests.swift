import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// A launch held up by Windows' administrator prompt says so, rather than
/// that the app opened no window.
final class LaunchTroubleTests: XCTestCase {
    func testTheHostsReasonsAreRead() {
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "approval"), .needsApproval)
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "declined"), .declined)
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "missing"), .missing)
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "refused"), .refused)
        XCTAssertNil(AgentConnection.LaunchTrouble(reason: nil), "an older host gives none")
        XCTAssertNil(AgentConnection.LaunchTrouble(reason: "something new"))
    }

    func testTheWordsSayWhatToDo() {
        let waiting = AppDelegate.launchTroubleText(.needsApproval, app: "Game", host: "pc")
        XCTAssertTrue(waiting.contains("Open window row"))
        XCTAssertTrue(waiting.contains("Run as administrator"))
        let declined = AppDelegate.launchTroubleText(.declined, app: "Game", host: "pc")
        XCTAssertTrue(declined.contains("declined"))
        // Gone is not "try again": choose another, or reinstall.
        let missing = AppDelegate.launchTroubleText(.missing, app: "Game", host: "pc")
        XCTAssertTrue(missing.contains("can't be found on pc"))
        XCTAssertTrue(missing.contains("drive that isn't connected"))
        XCTAssertTrue(missing.contains("Choose another app"))
        let refused = AppDelegate.launchTroubleText(.refused, app: "Game", host: "pc")
        XCTAssertTrue(refused.contains("Open it on the PC"))
    }

    /// The PC's reason for a picture that would not start is read for what
    /// to do, never shown as it is.
    func testAStreamThatWouldNotStartSaysWhatToDo() {
        let capture = AppDelegate.startTroubleText("the display could not be captured", host: "pc")
        XCTAssertTrue(capture.contains("unlocked"))
        let encoder = AppDelegate.startTroubleText(
            "the hardware HEVC encoder would not open at 4096x2560", host: "pc")
        XCTAssertTrue(encoder.contains("H.264"))
        XCTAssertFalse(encoder.contains("4096"))
        let port = AppDelegate.startTroubleText("UDP port 47999 is taken", host: "pc")
        XCTAssertTrue(port.contains("Restart the PC"))
        let other = AppDelegate.startTroubleText(nil, host: "pc")
        XCTAssertTrue(other.contains("Restart SolStream on the PC"))
    }

    /// Quit can be refused by the app; Force Quit only by Windows.
    func testAQuitRefusalSaysWhatToDoNext() {
        let reply: [String: Any] = ["type": "quit", "ok": false]
        XCTAssertTrue(AgentConnection.quitRefusal(reply).contains("Force Quit"))
        XCTAssertTrue(AgentConnection.quitRefusal(reply, force: true).contains("restart the PC"))
    }
}
