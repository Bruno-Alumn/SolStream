import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// A launch held up by Windows' administrator prompt says so, rather than
/// that the app opened no window.
final class LaunchTroubleTests: XCTestCase {
    func testTheHostsReasonsAreRead() {
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "approval"), .needsApproval)
        XCTAssertEqual(AgentConnection.LaunchTrouble(reason: "declined"), .declined)
        XCTAssertNil(AgentConnection.LaunchTrouble(reason: nil), "an older host gives none")
        XCTAssertNil(AgentConnection.LaunchTrouble(reason: "something new"))
    }

    func testTheWordsSayWhatToDo() {
        let waiting = AppDelegate.launchTroubleText(.needsApproval, app: "Game", host: "pc")
        XCTAssertTrue(waiting.contains("Open windows"))
        XCTAssertTrue(waiting.contains("Run as administrator"))
        let declined = AppDelegate.launchTroubleText(.declined, app: "Game", host: "pc")
        XCTAssertTrue(declined.contains("declined"))
    }
}
