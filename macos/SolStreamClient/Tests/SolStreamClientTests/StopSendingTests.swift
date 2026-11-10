import AppKit
import XCTest
@testable import InputCapture
@testable import SolStreamClient

/// A send to the PC can be stopped from the menu, and says so.
final class StopSendingTests: XCTestCase {
    func testTheProgressSaysHowToStop() {
        XCTAssertEqual(AppWindow.sendingText(1, name: "film.mov", percent: 40),
                       "Sending film.mov to the PC… 40% · ⌃⌘. stops")
        XCTAssertTrue(AppWindow.busySendingText.contains("⌃⌘."))
    }

    /// Stopped is said as stopped, with where what crossed is.
    func testAStopIsSaidAsAStop() {
        XCTAssertEqual(AppWindow.stoppedText(received: 0),
                       "Stopped sending. Nothing was left on the PC.")
        XCTAssertEqual(AppWindow.stoppedText(received: 1),
                       "Stopped sending. The file sent before is in Downloads\\SolStream on the PC.")
        XCTAssertEqual(AppWindow.stoppedText(received: 3),
                       "Stopped sending. The 3 files sent before are in Downloads\\SolStream on the PC.")
    }

    /// ⌃⌘. is a key a stream keeps for the Mac, and the menu's action is the
    /// delegate's own.
    func testTheKeyStaysOnTheMac() {
        XCTAssertTrue(InputCapture.isReserved(keyCode: 0x2F, flags: [.control, .command],
                                              characters: "."))
        XCTAssertTrue(AppDelegate().responds(to: #selector(AppDelegate.stopSendingFiles)))
    }
}
