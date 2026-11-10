import AppKit
import XCTest
@testable import SolStreamClient

/// Forgetting the pairings takes the removed launchers' tiles off the Dock,
/// and a note shown again while it fades out stays shown.
final class DockTileAndNoteTests: XCTestCase {
    private func tile(_ path: String) -> [String: Any] {
        ["tile-type": "file-tile",
         "tile-data": ["file-data": ["_CFURLString": URL(fileURLWithPath: path, isDirectory: true)
            .absoluteString, "_CFURLStringType": 15]] as [String: Any]]
    }

    /// Only the removed launchers' own tiles go; everything else stays, in order.
    func testOnlyTheRemovedLaunchersTilesGo() {
        let safari = tile("/Applications/Safari.app")
        let notepad = tile("/Users/me/Applications/SolStream Apps/Notepad (PC).app")
        let excel = tile("/Users/me/Applications/SolStream Apps/Excel (PC).app")
        let spacer: [String: Any] = ["tile-type": "spacer-tile"]
        let kept = AppLauncher.tiles(
            [safari, notepad, spacer, excel],
            without: [URL(fileURLWithPath: "/Users/me/Applications/SolStream Apps/Notepad (PC).app")])
        XCTAssertEqual(kept.count, 3)
        XCTAssertEqual(kept.compactMap { AppLauncher.url(ofTile: $0) },
                       [safari, excel].compactMap { AppLauncher.url(ofTile: $0) })
        XCTAssertEqual(AppLauncher.tiles([safari], without: []).count, 1)
    }

    /// Held during the fade-out of an earlier dismissal: still shown when the
    /// fade has finished.
    @MainActor
    func testANoteHeldDuringItsFadeStaysShown() {
        let note = CaptureHint(text: "first")
        note.hold()
        note.dismiss()
        note.text = "second"
        note.hold()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertFalse(note.isHidden, "the fade-out hid a note held after it began")
    }

    @MainActor
    func testADismissedNoteHides() {
        let note = CaptureHint(text: "first")
        note.hold()
        note.dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(note.isHidden)
    }
}
