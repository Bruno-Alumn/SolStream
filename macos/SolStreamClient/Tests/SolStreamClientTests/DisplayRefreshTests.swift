import CoreGraphics
import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// What opening an app does with the PC's answer to "which displays".
final class DisplayRefreshTests: XCTestCase {
    private let virtual = RemoteDisplay(name: #"\\.\DISPLAY13"#, adapter: "Virtual Display Driver",
                                        x: 3440, y: 0, width: 3600, height: 2338,
                                        isPrimary: false, isCaptured: true)

    func testNoAnswerFallsBackOnTheListHeld() {
        XCTAssertEqual(AppDelegate.displaysToUse(answer: nil, held: [virtual]), [virtual],
                       "a request that failed, or a reply with no list, is no answer")
    }

    func testAnEmptyAnswerIsAnAnswer() {
        XCTAssertEqual(AppDelegate.displaysToUse(answer: [], held: [virtual]), [],
                       "a PC with no display says so, rather than streaming one that has gone")
    }

    func testAResizedDisplayIsTakenAsThePCListsIt() {
        let listed = virtual.resized(width: 3024, height: 1964)
        XCTAssertEqual(AppDelegate.resizedCapture(virtual, listed: [listed],
                                                  achieved: CGSize(width: 1, height: 1)), listed)
    }

    func testWithNoListingTheCanvasReplysSizeIsUsed() {
        let updated = AppDelegate.resizedCapture(virtual, listed: nil,
                                                 achieved: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(updated.width, 3024)
        XCTAssertEqual(updated.height, 1964, "never the old size, which every crop would use")
        XCTAssertEqual(updated.name, virtual.name)
        let notListed = AppDelegate.resizedCapture(virtual, listed: [],
                                                   achieved: CGSize(width: 3024, height: 1964))
        XCTAssertEqual(notListed.width, 3024)
    }
}
