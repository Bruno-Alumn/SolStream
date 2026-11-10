import XCTest
@testable import SolStreamClient

/// The update card links to what an update brings, from the repository's
/// own release page.
final class WhatsNewTests: XCTestCase {
    func testTheNotesAreTheReleasesOwnPage() {
        XCTAssertEqual(UpdateSource.releaseNotes(for: "1.0.9")?.absoluteString,
                       "https://github.com/Bruno-Alumn/SolStream/releases/tag/v1.0.9")
        XCTAssertEqual(UpdateSource.releaseNotes(for: "1.1.0-beta.2")?.absoluteString,
                       "https://github.com/Bruno-Alumn/SolStream/releases/tag/v1.1.0-beta.2")
        for odd in ["", "1.0/../../x", "1.0 9", "1.0?x=1", "1.0#a", "1.０"] {
            XCTAssertNil(UpdateSource.releaseNotes(for: odd), odd)
        }
    }

    /// Shown for an update on offer, on its way or in; not while checking,
    /// once up to date, or after a failure.
    func testTheLinkIsForAnUpdateThere() {
        let shown: [Updater.State] = [
            .available("1.0.9"), .downloading("1.0.9", 0.5), .ready("1.0.9"),
            .waitingForStream("1.0.9"), .installing("1.0.9"), .installed("1.0.9"),
            .manualInstall("1.0.9", reason: "x"),
        ]
        for state in shown { XCTAssertEqual(SettingsPane.notesVersion(for: state), "1.0.9") }
        for state: Updater.State in [.idle, .checking, .upToDate, .failed("x")] {
            XCTAssertNil(SettingsPane.notesVersion(for: state))
        }
    }
}
