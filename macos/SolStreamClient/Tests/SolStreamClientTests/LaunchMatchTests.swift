import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// An installed application picked to launch is attached to an open window
/// only when the window is surely its own.
final class LaunchMatchTests: XCTestCase {
    private func window(_ title: String, pid: Int = 100, id: UInt64 = 1) -> RemoteWindow {
        RemoteWindow(id: id, pid: pid, title: title, className: "Window",
                     x: 0, y: 0, width: 800, height: 600,
                     isOccluded: false, occludedBy: nil, captionInset: 31)
    }

    func testTheWaysAnApplicationTitlesItsOwnWindow() {
        XCTAssertTrue(LaunchMatch.isConfident(title: "Calculator", name: "Calculator"))
        XCTAssertTrue(LaunchMatch.isConfident(title: "calculator", name: "Calculator"))
        XCTAssertTrue(LaunchMatch.isConfident(title: "Untitled - Notepad", name: "Notepad"))
        XCTAssertTrue(LaunchMatch.isConfident(title: "Inbox — Mail", name: "Mail"))
        XCTAssertTrue(LaunchMatch.isConfident(title: "Steam - News", name: "Steam"))
    }

    func testATitleThatMerelyContainsTheNameIsNotTheApplication() {
        XCTAssertFalse(LaunchMatch.isConfident(
            title: "Inbox - someone@example.com - Gmail - Google Chrome", name: "Mail"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "new 1 - Notepad++", name: "Notepad"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "Document - WordPad", name: "Word"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "Discord tips - Microsoft Edge", name: "Discord"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "Photos backup", name: "Photos"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "Anything", name: ""))
    }

    func testBeforeLaunchingOnlyASureWindowIsAttached() {
        let windows = [window("new 1 - Notepad++", id: 1), window("Untitled - Notepad", id: 2)]
        XCTAssertEqual(LaunchMatch.existing("Notepad", in: windows)?.id, 2)
        XCTAssertNil(LaunchMatch.existing("Notepad", in: [window("new 1 - Notepad++")]),
                     "launched instead")
    }

    func testAfterALaunchANewProcessIsPreferred() {
        let windows = [window("Steam - News", pid: 10, id: 1),
                       window("Sign in to Steam", pid: 20, id: 2)]
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10])?.id, 2,
                       "the process that just started, though its title is loose")
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10, 20])?.id, 1,
                       "nothing new: only a sure title")
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [])?.id, 1,
                       "no list from before: nothing can be called new")
    }

    func testAfterALaunchANewProcessStillNeedsTheName() {
        let windows = [window("Steam tips - Google Chrome", pid: 10, id: 1),
                       window("Downloads", pid: 30, id: 3)]
        XCTAssertNil(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10]))
    }
}
