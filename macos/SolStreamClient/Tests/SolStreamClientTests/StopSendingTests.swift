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
        // A long name gives way in its middle, so the hint is not what is cut.
        let long = AppWindow.sendingText(1, name: "Screen Recording 2026-11-11 at 10.42.13.mov",
                                         percent: 5)
        XCTAssertTrue(long.hasSuffix("5% · ⌃⌘. stops"))
        XCTAssertTrue(long.contains("…") && long.contains("42.13.mov"), long)
        XCTAssertEqual(AppWindow.shortName("short.txt"), "short.txt")
    }

    /// Stopped is said as stopped, with where what crossed is.
    func testAStopIsSaidAsAStop() {
        XCTAssertEqual(AppWindow.stoppedText(received: 0),
                       "Stopped sending. Nothing was left on the PC.")
        XCTAssertEqual(AppWindow.stoppedText(received: 1),
                       "Stopped sending. The file already across is in Downloads\\SolStream on the PC.")
        XCTAssertEqual(AppWindow.stoppedText(received: 3, leftOut: 1),
                       "Stopped sending. The 3 files already across are in Downloads\\SolStream "
                       + "on the PC. One item was left out too: only files can be sent, not folders.")
    }

    /// ⌃⌘. is a key a stream keeps for the Mac, and the menu's action is the
    /// delegate's own.
    func testTheKeyStaysOnTheMac() {
        XCTAssertTrue(InputCapture.isReserved(keyCode: 0x2F, flags: [.control, .command],
                                              characters: "."))
        XCTAssertTrue(AppDelegate().responds(to: #selector(AppDelegate.stopSendingFiles)))
    }
}
