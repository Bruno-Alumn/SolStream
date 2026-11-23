import AppKit
import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// Add App: the picker over a running stream, what it lists, when it may be
/// chosen, and what waits behind a launch on the channel.
final class AddAppTests: XCTestCase {
    private let display = RemoteDisplay(name: #"\\.\DISPLAY13"#, adapter: "Virtual Display Driver",
                                        x: 3440, y: 0, width: 3600, height: 2338,
                                        isPrimary: false, isCaptured: true)
    private var canvas: CGRect { AppDelegate.displayRect(display) }

    private func window(_ id: UInt64) -> RemoteWindow {
        RemoteWindow(id: id, pid: 100, title: "App \(id)", className: "Window",
                     x: 0, y: 0, width: 800, height: 600,
                     isOccluded: false, occludedBy: nil, captionInset: 31)
    }

    // MARK: Menu

    func testAddAppNeedsAStreamWindowsCanBeAddedTo() {
        XCTAssertTrue(AppDelegate.addAppAllowed(gate: .open(hidesCard: true), launching: false))
        XCTAssertTrue(AppDelegate.addAppAllowed(gate: .open(hidesCard: false), launching: false),
                      "a stalled picture still takes a window; its card stays up")
        XCTAssertFalse(AppDelegate.addAppAllowed(gate: .refuse("the stream has ended"),
                                                 launching: false))
        XCTAssertFalse(AppDelegate.addAppAllowed(gate: .refuse("nothing is streaming now"),
                                                 launching: false))
    }

    func testNotWhileAnAppIsStartingForIt() {
        XCTAssertFalse(AppDelegate.addAppAllowed(gate: .open(hidesCard: true), launching: true),
                       "a second launch waits behind the first on the PC")
    }

    func testTheDelegateHasTheAction() {
        XCTAssertTrue(AppDelegate().responds(to: NSSelectorFromString("addApp")))
    }

    // MARK: Picker

    func testThePickerSaysItAdds() {
        XCTAssertEqual(AppPicker.wording(adding: false).heading, "Choose an application")
        XCTAssertEqual(AppPicker.wording(adding: false).back, "Back")
        XCTAssertEqual(AppPicker.wording(adding: true).heading, "Add a window to the stream")
        XCTAssertEqual(AppPicker.wording(adding: true).back, "Cancel")
    }

    func testTheWindowCarriesItForTheWindowMenu() {
        _ = NSApplication.shared
        let picker = AppPicker(host: "pc", adding: true, onChoose: { _ in }, onCancel: {})
        XCTAssertTrue(picker.adding)
        XCTAssertEqual(picker.window.subtitle, "Add a window to the stream")
        let plain = AppPicker(host: "pc", onChoose: { _ in }, onCancel: {})
        XCTAssertFalse(plain.adding)
        XCTAssertEqual(plain.window.subtitle, "Choose an application")
    }

    func testStreamedWindowsAreNotListed() {
        let listed = AppDelegate.addable([window(1), window(2), window(3)], streamed: [2, 9])
        XCTAssertEqual(listed.map(\.id), [1, 3])
        XCTAssertEqual(AppDelegate.addable([window(1)], streamed: []).map(\.id), [1])
    }

    // MARK: Room before a launch

    func testRoomForAnotherOnAStreamWithSpace() {
        let one = [CGRect(x: canvas.minX, y: canvas.minY, width: 1200, height: 900)]
        guard case .add(let frame) = AppDelegate.roomForAnother(streamed: one, canvas: canvas) else {
            return XCTFail("a display with most of it free has room")
        }
        XCTAssertTrue(canvas.contains(frame))
        XCTAssertFalse(frame.intersects(one[0]))
    }

    func testNoLaunchOnAFullStream() {
        let eight = (0..<TileAllocator.maxWindows).map {
            CGRect(x: canvas.minX + CGFloat($0) * 10, y: canvas.minY, width: 5, height: 5)
        }
        XCTAssertEqual(AppDelegate.roomForAnother(streamed: eight, canvas: canvas), .full)
    }

    func testNoLaunchWithNoRoomLeft() {
        XCTAssertEqual(AppDelegate.roomForAnother(streamed: [canvas], canvas: canvas), .noRoom)
    }

    func testWhatARefusalSays() {
        XCTAssertNil(AppDelegate.refusal(.add(.zero), adding: "Notepad"))
        XCTAssertNil(AppDelegate.refusal(.alreadyStreamed, adding: "Notepad"),
                     "a window on screen already only comes forward")
        XCTAssertEqual(AppDelegate.refusal(.full, adding: "Notepad"),
                       "SolStream can show \(TileAllocator.maxWindows) windows from a PC at once. "
                           + "Close one to add Notepad.")
        XCTAssertTrue(AppDelegate.refusal(.noRoom, adding: "Notepad")?.contains("no room") == true)
    }

    // MARK: What waits behind a launch

    func testFocusGoesAtOnceWithNoLaunchOut() {
        var hold = LaunchHold()
        XCTAssertFalse(hold.isLaunching)
        XCTAssertTrue(hold.focus(7))
        XCTAssertNil(hold.heldFocus)
    }

    func testOnlyTheNewestFocusWaitsForTheLaunch() {
        var hold = LaunchHold()
        hold.launchStarted()
        XCTAssertTrue(hold.isLaunching)
        XCTAssertFalse(hold.focus(1))
        XCTAssertFalse(hold.focus(2))
        XCTAssertFalse(hold.focus(3))
        XCTAssertEqual(hold.launchEnded(), 3, "the window clicked last is the one that gets it")
        XCTAssertFalse(hold.isLaunching)
        XCTAssertNil(hold.launchEnded(), "sent once, not again")
        XCTAssertTrue(hold.focus(4))
    }

    func testHeldUntilTheLastLaunchIsAnswered() {
        var hold = LaunchHold()
        hold.launchStarted()
        hold.launchStarted()
        XCTAssertFalse(hold.focus(5))
        XCTAssertNil(hold.launchEnded(), "the second launch is still ahead of it")
        XCTAssertTrue(hold.isLaunching)
        XCTAssertEqual(hold.launchEnded(), 5)
    }

    func testALaunchWithNothingHeldSendsNothing() {
        var hold = LaunchHold()
        hold.launchStarted()
        XCTAssertNil(hold.launchEnded())
        XCTAssertNil(hold.launchEnded(), "an extra answer does not go below none")
        XCTAssertEqual(hold.launches, 0)
    }
}
