import AppKit
import XCTest
@testable import AgentChannel
@testable import MediaSession
@testable import SolStreamClient

/// The PC picker's spoken value, the stream-ended message, and what is
/// remembered at quit.
final class UIPolishTwoTests: XCTestCase {
    func testThePickerSaysWhatIsKnownOfThePC() {
        XCTAssertEqual(HostDropdown.spokenValue(title: "DESKTOP", detail: "Not answering"),
                       "DESKTOP, Not answering")
        XCTAssertEqual(HostDropdown.spokenValue(title: "DESKTOP", detail: "  "), "DESKTOP")
    }

    func testTheClosedPickerReadsItsDetail() {
        let dropdown = HostDropdown()
        dropdown.setSelection(address: "10.0.0.2", name: "DESKTOP",
                              detail: [.words("Not answering")], dotState: .idle)
        let value = dropdown.accessibilityValue() as? String ?? ""
        XCTAssertTrue(value.hasPrefix("DESKTOP"), value)
        XCTAssertTrue(value.contains("Not answering"), value)
    }

    /// Try Again goes back to the app list; the message no longer promises
    /// that it opens the app again.
    func testTheEndedMessageSaysWhatTryAgainDoes() {
        for reason in [MediaClient.EndReason.hostEnded, .silent] {
            let text = StreamSession.endedMessage(reason)
            XCTAssertTrue(text.contains("goes back to the app list"), text)
            XCTAssertFalse(text.contains("Try Again to open"), text)
        }
    }

    func testQuitRemembersWhatIsOnScreenOrStillOpening() {
        let notepad = AppLink(host: "pc", app: RemoteApp(name: "Notepad", path: #"C:\Notepad.lnk"#))
        let excel = AppLink(host: "pc", app: RemoteApp(name: "Excel", path: #"C:\Excel.lnk"#))
        XCTAssertEqual(AppDelegate.linkToRemember(streaming: notepad, waitingToOpen: excel), notepad)
        XCTAssertEqual(AppDelegate.linkToRemember(streaming: nil, waitingToOpen: excel), excel)
        XCTAssertNil(AppDelegate.linkToRemember(streaming: nil, waitingToOpen: nil))
    }
}
