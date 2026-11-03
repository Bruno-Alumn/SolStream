import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// What the window says when the PC says its input is blocked.
final class InputBlockedTests: XCTestCase {
    func testEachReasonSaysWhatToDo() {
        let secure = AppDelegate.inputBlockedNote("secureDesktop", app: nil)
        XCTAssertTrue(secure?.contains("Answer it at the PC") == true)
        XCTAssertTrue(AppDelegate.inputBlockedNote("screenSaver", app: nil)?
            .contains("screen saver") == true)
        let elevated = AppDelegate.inputBlockedNote("elevated", app: "Taskmgr.exe")
        XCTAssertTrue(elevated?.hasPrefix("Taskmgr.exe runs as administrator") == true)
        XCTAssertTrue(AppDelegate.inputBlockedNote("elevated", app: "")?
            .hasPrefix("The app in front") == true)
        XCTAssertEqual(AppDelegate.inputBlockedNote(nil, app: nil),
                       "SolStream can control the PC again.")
        // A reason a newer host might add is not guessed at.
        XCTAssertNil(AppDelegate.inputBlockedNote("somethingNew", app: nil))
    }

    /// Listed in the auth line, so the host sends it; and skippable, so an
    /// unexpected one cannot desync the reply queue.
    func testThePushIsUnderstoodAndSkippable() {
        XCTAssertTrue(AgentConnection.understoodPushes.split(separator: " ").contains("inputBlocked"))
        XCTAssertTrue(AgentConnection.skippablePushes.contains("inputBlocked"))
    }
}
