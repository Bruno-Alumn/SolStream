import XCTest
@testable import SolStreamClient

/// Add to Dock says what happened when the app is in the Dock already.
final class AddToDockFeedbackTests: XCTestCase {
    func testTheDockIsAskedByPath() {
        let launcher = URL(fileURLWithPath: "/Users/me/Applications/SolStream Apps/Notepad (PC).app")
        let tile: [String: Any] = ["tile-data": ["file-data": [
            "_CFURLString": "file:///Users/me/Applications/SolStream%20Apps/Notepad%20(PC).app/"]]]
        let other: [String: Any] = ["tile-data": ["file-data": [
            "_CFURLString": "file:///Applications/Safari.app/"]]]
        XCTAssertTrue(AppLauncher.dockHolds([other, tile], launcher))
        XCTAssertFalse(AppLauncher.dockHolds([other], launcher))
    }
}
