import XCTest
@testable import SolStreamClient

/// A window follows its app into full screen on the PC, and back out only
/// from a full screen it went into for the app.
final class FullScreenFollowTests: XCTestCase {
    private func follow(_ on: Bool, full: Bool, forHost: Bool) -> AppWindow.FullScreenFollow {
        AppWindow.followFullScreen(hostOn: on, isFullScreen: full, enteredForHost: forHost)
    }

    func testFollowsTheAppIn() {
        XCTAssertEqual(follow(true, full: false, forHost: false), .enter)
    }

    func testAlreadyFullScreenStays() {
        XCTAssertEqual(follow(true, full: true, forHost: false), .stay)
        XCTAssertEqual(follow(true, full: true, forHost: true), .stay)
    }

    func testFollowsTheAppOutOfAFullScreenItCausedOnly() {
        XCTAssertEqual(follow(false, full: true, forHost: true), .leave)
        // The user put it there: it stays.
        XCTAssertEqual(follow(false, full: true, forHost: false), .stay)
        XCTAssertEqual(follow(false, full: false, forHost: false), .stay)
    }

    func testWaitsOutAnAnimation() {
        XCTAssertEqual(AppWindow.followFullScreen(hostOn: false, isFullScreen: true,
                                                  enteredForHost: true, transitioning: true), .wait)
        XCTAssertEqual(AppWindow.followFullScreen(hostOn: true, isFullScreen: false,
                                                  enteredForHost: false, transitioning: true), .wait)
    }
}
