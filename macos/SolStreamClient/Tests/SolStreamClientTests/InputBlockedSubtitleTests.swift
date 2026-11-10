import XCTest
@testable import SolStreamClient

/// While the PC says its input is blocked, every stream window says so in
/// its subtitle, ahead of a window covering the picture.
final class InputBlockedSubtitleTests: XCTestCase {
    func testTheSubtitleSaysWhatMatters() {
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: nil, occludedBy: nil), "")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: nil, occludedBy: ""), "")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: nil, occludedBy: "Task Manager"),
                       "⚠ Task Manager in front")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: "Input blocked on the PC", occludedBy: nil),
                       "⚠ Input blocked on the PC")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: "Input blocked on the PC",
                                          occludedBy: "Task Manager"),
                       "⚠ Input blocked on the PC")
    }

    /// An administrator's app in front is named, since clicking another app
    /// clears it; the other reasons are input blocked outright.
    func testTheShortWords() {
        XCTAssertEqual(AppDelegate.inputBlockedShort("elevated", app: "Task Manager"),
                       "Task Manager runs as administrator")
        XCTAssertEqual(AppDelegate.inputBlockedShort("elevated", app: nil), "Input blocked on the PC")
        XCTAssertEqual(AppDelegate.inputBlockedShort("secureDesktop", app: nil),
                       "Input blocked on the PC")
        XCTAssertNil(AppDelegate.inputBlockedShort(nil, app: nil))
    }

}
