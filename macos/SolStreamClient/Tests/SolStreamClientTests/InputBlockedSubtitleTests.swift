import XCTest
@testable import SolStreamClient

/// While the PC says its input is blocked, every stream window says so in
/// its subtitle, ahead of a window covering the picture.
final class InputBlockedSubtitleTests: XCTestCase {
    func testTheSubtitleSaysWhatMatters() {
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: false, occludedBy: nil), "")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: false, occludedBy: ""), "")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: false, occludedBy: "Task Manager"),
                       "⚠ Task Manager in front")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: true, occludedBy: nil),
                       "⚠ Input blocked on the PC")
        XCTAssertEqual(AppWindow.subtitle(inputBlocked: true, occludedBy: "Task Manager"),
                       "⚠ Input blocked on the PC")
    }
}
