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
        XCTAssertTrue(missing.contains("isn't on pc any more"))
        XCTAssertTrue(missing.contains("Choose another app"))
        let refused = AppDelegate.launchTroubleText(.refused, app: "Game", host: "pc")
        XCTAssertTrue(refused.contains("Open it on the PC"))
    }
}
