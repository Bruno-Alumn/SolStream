import XCTest
@testable import SolStreamClient

/// The app menu's update item says when an update is waiting, for the
/// person who never sees the connect window.
final class UpdateMenuTitleTests: XCTestCase {
    func testTitlesFollowTheUpdater() {
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .idle), "Check for Updates…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .upToDate), "Check for Updates…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .checking), "Check for Updates…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .failed("no network")), "Check for Updates…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .available("1.0.9")), "Update 1.0.9 Available…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .downloading("1.0.9", 0.5)),
                       "Update 1.0.9 Available…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .waitingForStream("1.0.9")),
                       "Update 1.0.9 Installs After the Stream…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .installed("1.0.9")), "Update 1.0.9 Installed…")
        XCTAssertEqual(AppDelegate.updateMenuTitle(for: .ready("1.0.9")), "Install Update 1.0.9…")
    }

    /// Settings says the update line once per stage, whatever its percentage.
    func testStagesIgnoreTheirDetail() {
        XCTAssertEqual(SettingsPane.updateStage(.downloading("1.0.9", 0.1)),
                       SettingsPane.updateStage(.downloading("1.0.9", 0.9)))
        XCTAssertNotEqual(SettingsPane.updateStage(.downloading("1.0.9", 0.9)),
                          SettingsPane.updateStage(.ready("1.0.9")))
    }

}
