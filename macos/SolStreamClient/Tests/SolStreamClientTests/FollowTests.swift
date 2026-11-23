import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// What the Mac does with a window a streamed application opens on the PC:
/// show a dialog over its window, give anything else a tile, or leave it.
final class FollowTests: XCTestCase {
    /// The virtual display as the PC reports it: right of a real monitor, so
    /// nothing here may take the origin to be zero.
    private let display = CGRect(x: 3440, y: 0, width: 3600, height: 2338)

    private func opened(id: UInt64 = 900, parent: UInt64 = 42, owned: Bool = true,
                        x: Int = 3440 + 800, y: Int = 500, w: Int = 900, h: Int = 600,
                        title: String = "Save As") -> OpenedWindow {
        OpenedWindow(id: id, parent: parent, pid: 4120, owned: owned,
                     x: x, y: y, width: w, height: h, title: title)
    }

    private func decide(_ window: OpenedWindow, streamed: Set<UInt64> = [42],
                        mirrored: Set<UInt64> = []) -> Follow.Decision {
        Follow.decide(window, streamed: streamed, mirrored: mirrored, display: display)
    }

    // MARK: - Owned or not

    func testADialogOnTheCaptureDisplayIsShownOverItsWindow() {
        XCTAssertEqual(decide(opened()), .mirror)
    }

    func testAWindowTheMacOpenedGetsATileEvenOnTheCaptureDisplay() {
        guard case .tile = decide(opened(owned: false, title: "Sign in")) else {
            return XCTFail("an unowned follower should be added to the stream")
        }
    }

    func testAnUnownedWindowOnTheRealMonitorGetsATile() {
        guard case .tile = decide(opened(owned: false, x: 100, y: 100)) else {
            return XCTFail("an unowned follower should be added to the stream")
        }
    }

    // MARK: - Menus and tooltips

    /// A menu, a tooltip or a tool window would take the keyboard as a Mac
    /// window, which ends the menu on the PC; it is left in its window's
    /// picture. Seen live: a folder tooltip in Paint's Open dialog.
    func testAPopUpIsNeverShownOrAdded() {
        let tip = OpenedWindow(id: 901, parent: 42, pid: 4120, owned: true, x: 3440 + 800,
                               y: 500, width: 120, height: 24, title: "", popup: true)
        guard case .ignore(let reason) = decide(tip) else {
            return XCTFail("a pop-up must not be mirrored")
        }
        XCTAssertTrue(reason.contains("menu"))
        let offDisplay = OpenedWindow(id: 902, parent: 42, pid: 4120, owned: true, x: 100,
                                      y: 100, width: 300, height: 400, title: "", popup: true)
        guard case .ignore = decide(offDisplay) else {
            return XCTFail("a pop-up off the capture display must not get a tile")
        }
        let unowned = OpenedWindow(id: 903, parent: 42, pid: 4120, owned: false, x: 100,
                                   y: 100, width: 300, height: 400, title: "", popup: true)
        guard case .ignore = decide(unowned) else {
            return XCTFail("a pop-up must not get a tile")
        }
    }

    // MARK: - The keyboard

    func testAMirrorTakesTheKeyboardOnlyFromItsOwnWindow() {
        XCTAssertTrue(Follow.mirrorTakesKeyboard(appActive: true, parentHasKeyboard: true))
        // Another stream window has it, or another Mac app does.
        XCTAssertFalse(Follow.mirrorTakesKeyboard(appActive: true, parentHasKeyboard: false))
        XCTAssertFalse(Follow.mirrorTakesKeyboard(appActive: false, parentHasKeyboard: true))
        XCTAssertFalse(Follow.mirrorTakesKeyboard(appActive: false, parentHasKeyboard: false))
    }

    func testAQuietFollowerDoesNotBringSolStreamForward() {
        XCTAssertFalse(Follow.showActivates(quietly: true, appActive: false))
        XCTAssertTrue(Follow.showActivates(quietly: true, appActive: true))
        // One the user asked for comes forward either way.
        XCTAssertTrue(Follow.showActivates(quietly: false, appActive: false))
        XCTAssertTrue(Follow.showActivates(quietly: false, appActive: true))
    }

    // MARK: - On the capture display or not

    func testADialogOnTheRealMonitorGetsATile() {
        guard case .tile(let reason) = decide(opened(x: 200, y: 300)) else {
            return XCTFail("a dialog off the capture display cannot be mirrored")
        }
        XCTAssertTrue(reason.contains("capture display"))
    }

    func testADialogHangingOffTheDisplayGetsATile() {
        // Over the right-hand edge by a hundred pixels: its crop would show
        // black there.
        guard case .tile = decide(opened(x: 3440 + 3600 - 800, w: 900)) else {
            return XCTFail("a dialog partly off the capture display should get a tile")
        }
        // Over the top edge, as a dialog centred on a tall parent can be.
        guard case .tile = decide(opened(y: -40)) else {
            return XCTFail("a dialog partly off the capture display should get a tile")
        }
    }

    func testADialogRoundingOverTheEdgeIsStillOnIt() {
        XCTAssertEqual(decide(opened(x: 3440 - 1, y: 0, w: 900, h: 2338 + 1)), .mirror)
        XCTAssertTrue(Follow.onCaptureDisplay(display, display: display))
        XCTAssertFalse(Follow.onCaptureDisplay(display.offsetBy(dx: 3, dy: 0), display: display))
        XCTAssertFalse(Follow.onCaptureDisplay(.zero, display: display))
    }

    // MARK: - Never followed

    func testAWindowAlreadyStreamedIsLeftAlone() {
        guard case .ignore(let reason) = decide(opened(id: 7), streamed: [42, 7]) else {
            return XCTFail("a window streamed already must not be followed")
        }
        XCTAssertTrue(reason.contains("already"))
    }

    func testADialogAlreadyShownIsLeftAlone() {
        guard case .ignore = decide(opened(id: 900), mirrored: [900]) else {
            return XCTFail("a dialog shown already must not be shown twice")
        }
    }

    func testAWindowOfAnotherStreamIsLeftAlone() {
        guard case .ignore(let reason) = decide(opened(parent: 5)) else {
            return XCTFail("a window that goes with nothing streamed here must be left")
        }
        XCTAssertTrue(reason.contains("5"))
        guard case .ignore = decide(opened(parent: 42), streamed: []) else {
            return XCTFail("with nothing streamed, nothing follows")
        }
    }

    func testAWindowNamedAsItsOwnParentIsLeftAlone() {
        guard case .ignore = decide(opened(id: 42, parent: 42), streamed: [42]) else {
            return XCTFail("a window cannot follow itself")
        }
    }

    func testAWindowWithNoSizeIsLeftAlone() {
        guard case .ignore = decide(opened(w: 0)) else {
            return XCTFail("a window with no area has nothing to show")
        }
        guard case .ignore = decide(opened(owned: false, h: 0)) else {
            return XCTFail("a window with no area has nothing to show")
        }
    }

    // MARK: - Where the dialog goes on the Mac

    /// The parent shows 1600×1000 PC pixels in 800×500 points -- a Retina
    /// window matched to its picture -- with its content's bottom-left at
    /// (300, 400) on the Mac's screen.
    private let parentPicture = CGRect(x: 3440 + 100, y: 200, width: 1600, height: 1000)
    private let parentContent = CGRect(x: 300, y: 400, width: 800, height: 500)

    func testTheDialogKeepsItsOffsetFromItsWindow() {
        // 400 px right and 200 px down from the parent's picture, 400×300.
        let dialog = CGRect(x: 3440 + 500, y: 400, width: 400, height: 300)
        let frame = Follow.childFrame(of: dialog, parentPicture: parentPicture,
                                      parentContent: parentContent)
        // 200 pt right of the content's left edge (300), its top 100 pt below
        // the content's top (900), and 200×150 pt.
        XCTAssertEqual(frame, CGRect(x: 500, y: 650, width: 200, height: 150))
    }

    func testADialogLargerThanItsWindowHangsOverItsEdges() {
        // Up and left of the parent's picture, and bigger than it.
        let dialog = CGRect(x: 3440, y: 100, width: 2000, height: 1200)
        let frame = Follow.childFrame(of: dialog, parentPicture: parentPicture,
                                      parentContent: parentContent)
        XCTAssertEqual(frame, CGRect(x: 250, y: 350, width: 1000, height: 600))
    }

    func testInFullScreenTheOffsetIsFromThePictureNotTheBars() {
        // The same picture fitted into a wider view: 0.5 by its height, so
        // 800 pt wide, centred with 100 pt bars either side.
        let wide = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let dialog = CGRect(x: parentPicture.minX, y: parentPicture.minY, width: 200, height: 100)
        let frame = Follow.childFrame(of: dialog, parentPicture: parentPicture, parentContent: wide)
        XCTAssertEqual(frame, CGRect(x: 100, y: 450, width: 100, height: 50))
    }

    func testNothingToPlaceAgainstIsNoFrame() {
        let dialog = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertNil(Follow.childFrame(of: dialog, parentPicture: .zero, parentContent: parentContent))
        XCTAssertNil(Follow.childFrame(of: dialog, parentPicture: parentPicture, parentContent: .zero))
        XCTAssertNil(Follow.childFrame(of: .zero, parentPicture: parentPicture,
                                       parentContent: parentContent))
    }

    func testOnlyWhatIsOnTheDisplayIsShown() {
        let hanging = CGRect(x: 3440 - 2, y: 10, width: 500, height: 400)
        XCTAssertEqual(Follow.shown(hanging, on: display),
                       CGRect(x: 3440, y: 10, width: 498, height: 400))
        XCTAssertNil(Follow.shown(CGRect(x: 0, y: 0, width: 100, height: 100), on: display))
    }

    // MARK: - What it is called

    func testItTakesItsOwnTitleOrItsWindowsWhenItHasNone() {
        XCTAssertEqual(Follow.title(opened(title: "Save As"), parentTitle: "Notepad"), "Save As")
        XCTAssertEqual(Follow.title(opened(title: ""), parentTitle: "Notepad"), "Notepad")
        XCTAssertEqual(Follow.title(opened(title: "  "), parentTitle: "Notepad"), "Notepad")
    }

    func testTheLogNamesTitleIdAndParent() {
        let line = Follow.describe(opened(id: 263412, parent: 42, owned: false, title: "Sign in"))
        XCTAssertTrue(line.contains("\"Sign in\""))
        XCTAssertTrue(line.contains("263412"))
        XCTAssertTrue(line.contains("42"))
    }

    // MARK: - Built from the push and the host's answer

    func testAFollowerOnATileTakesWhereTheHostLastFoundIt() {
        let status = AgentConnection.windowStatus(
            from: ["type": "window", "alive": true, "x": 10, "y": 20, "w": 1280, "h": 900,
                   "captionInset": 31, "minimized": false],
            alive: true)
        let window = RemoteWindow.following(opened(owned: false, title: "Sign in"), status: status)
        XCTAssertEqual(window.id, 900)
        XCTAssertEqual(window.title, "Sign in")
        XCTAssertEqual(window.frame, CGRect(x: 10, y: 20, width: 1280, height: 900))
        XCTAssertEqual(window.captionInset, 31)
    }

    func testWithoutAnAnswerItTakesThePush() {
        let window = RemoteWindow.following(opened(x: 5, y: 6, w: 700, h: 500))
        XCTAssertEqual(window.frame, CGRect(x: 5, y: 6, width: 700, height: 500))
        XCTAssertEqual(window.captionInset, 0)
    }

    func testTheWindowReplyCarriesWhereItIs() {
        let status = AgentConnection.windowStatus(
            from: ["type": "window", "alive": true, "minimized": true, "visible": true,
                   "x": -1200, "y": 340, "w": 640, "h": 480, "captionInset": 0],
            alive: true)
        XCTAssertEqual(status.frame, CGRect(x: -1200, y: 340, width: 640, height: 480))
        XCTAssertTrue(status.isMinimized)
        let old = AgentConnection.windowStatus(from: ["type": "window", "alive": true], alive: true)
        XCTAssertNil(old.frame)
        XCTAssertFalse(old.isMinimized)
    }
}
