import AppKit
import CoreGraphics
import XCTest
@testable import InputCapture
import MediaSession
@testable import SolStreamClient

/// Checks when gaming mode holds the mouse while following the PC's cursor.
///
/// The bug this guards: a game's pause menu showed its cursor and the Mac went
/// on holding the mouse, so the menu had no pointer at all. Driven through the
/// policy, then through real `NSEvent`s with the cursor lock stood in for --
/// nothing here hides, shows or decouples a real cursor.
final class GamingCursorTests: XCTestCase {
    private typealias Policy = InputCapture.CapturePolicy

    /// A key window in gaming mode, following the host, pointer over the picture.
    private func moment(mode: InputCapture.PointerMode = .gaming, follows: Bool = true,
                        active: Bool = true, inside: Bool = true,
                        captured: Bool) -> Policy.Moment {
        Policy.Moment(mode: mode, followsHostCursor: follows, isActive: active,
                      pointerInside: inside, isCaptured: captured)
    }

    /// A policy that has seen the host both hide and show its cursor, and so
    /// follows it, left with the cursor shown.
    private func provenPolicy() -> Policy {
        var policy = Policy()
        _ = policy.wantsCapture(after: .hostCursor(hidden: true), moment(active: false, captured: false))
        _ = policy.wantsCapture(after: .hostCursor(hidden: false), moment(active: false, captured: false))
        XCTAssertTrue(policy.hostReportsVisibility)
        return policy
    }

    // MARK: - The pause menu

    func testThePauseMenuRoundTrip() {
        var policy = provenPolicy()
        var captured = false

        // Into the world: the game hides its cursor and the mouse is taken.
        captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: captured))
        XCTAssertTrue(captured, "the game hid its cursor over the picture; the mouse should be taken")

        // Esc: the pause menu shows a cursor, and the Mac's comes back.
        captured = policy.wantsCapture(after: .hostCursor(hidden: false), moment(captured: captured))
        XCTAssertFalse(captured, "the pause menu shows a cursor; the mouse must be given back")

        // Clicking a menu button is only a click.
        captured = policy.wantsCapture(after: .click, moment(captured: captured))
        XCTAssertFalse(captured, "a click in the pause menu took the mouse away from the menu")
        captured = policy.wantsCapture(after: .pointerMoved, moment(captured: captured))
        XCTAssertFalse(captured)

        // Back to the game: hidden again, taken again.
        captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: captured))
        XCTAssertTrue(captured)
    }

    func testShapeChangesWhileCapturedKeepTheMouse() {
        var policy = provenPolicy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: false))
        XCTAssertTrue(captured)
        captured = policy.wantsCapture(after: .pointerMoved, moment(captured: captured))
        XCTAssertTrue(captured, "moving a held mouse must not let it go")
        captured = policy.wantsCapture(after: .click, moment(captured: captured))
        XCTAssertTrue(captured, "firing must not let it go")
    }

    func testAHideWithThePointerOutsideWaitsForThePicture() {
        var policy = provenPolicy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true),
                                           moment(inside: false, captured: false))
        XCTAssertFalse(captured, "the pointer was on the title bar; it should not be snatched there")
        captured = policy.wantsCapture(after: .pointerMoved, moment(inside: true, captured: captured))
        XCTAssertTrue(captured, "the game is reading motion; over the picture the mouse is the game's")
    }

    // MARK: - Letting go by hand

    func testReleasingByHandSticksUntilTheNextClick() {
        var policy = provenPolicy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: false))
        XCTAssertTrue(captured)

        captured = policy.wantsCapture(after: .releaseChord, moment(captured: captured))
        XCTAssertFalse(captured, "⌃⌥ must let the mouse go")
        XCTAssertTrue(policy.releasedByHand)

        // The cursor is still hidden, and the pointer is still over the picture.
        for _ in 0..<3 {
            captured = policy.wantsCapture(after: .pointerMoved, moment(captured: captured))
            XCTAssertFalse(captured, "the next move took the mouse straight back after ⌃⌥")
        }
        captured = policy.wantsCapture(after: .reconsider, moment(captured: captured))
        XCTAssertFalse(captured, "coming back to the window undid ⌃⌥ without a click")

        // A click outside the picture is not a click in the game.
        captured = policy.wantsCapture(after: .click, moment(inside: false, captured: captured))
        XCTAssertFalse(captured)

        captured = policy.wantsCapture(after: .click, moment(captured: captured))
        XCTAssertTrue(captured, "a click in the picture takes the mouse back")
        XCTAssertFalse(policy.releasedByHand)
    }

    func testTheGameShowingItsCursorEndsAReleaseByHand() {
        var policy = provenPolicy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: false))
        captured = policy.wantsCapture(after: .releaseChord, moment(captured: captured))
        XCTAssertFalse(captured)

        // A menu, then the game again: a new request for the mouse.
        captured = policy.wantsCapture(after: .hostCursor(hidden: false), moment(captured: captured))
        XCTAssertFalse(captured)
        captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: captured))
        XCTAssertTrue(captured)
    }

    // MARK: - Hosts that do not report, and settings

    func testAHostThatNeverHidesItsCursorKeepsClickToCapture() {
        // An agent older than "hidden": shapes only.
        var policy = Policy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: false), moment(captured: false))
        XCTAssertFalse(captured)
        XCTAssertFalse(policy.hostReportsVisibility)

        captured = policy.wantsCapture(after: .click, moment(captured: captured))
        XCTAssertTrue(captured, "with an older host gaming mode must still capture on a click")
        captured = policy.wantsCapture(after: .hostCursor(hidden: false), moment(captured: captured))
        XCTAssertTrue(captured, "a shape from an older host says nothing about a menu")
        captured = policy.wantsCapture(after: .releaseChord, moment(captured: captured))
        XCTAssertFalse(captured)
    }

    func testAHostThatOnlyEverSaysHiddenIsNotFollowed() {
        // A PC with no mouse plugged in can report its cursor hidden for ever.
        var policy = Policy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true), moment(captured: false))
        XCTAssertFalse(captured, "one report is not enough to take the mouse unasked")
        captured = policy.wantsCapture(after: .pointerMoved, moment(captured: captured))
        XCTAssertFalse(captured)
        captured = policy.wantsCapture(after: .click, moment(captured: captured))
        XCTAssertTrue(captured, "a click still takes it")

        // The pause menu then proves the host, and gives the mouse back.
        captured = policy.wantsCapture(after: .hostCursor(hidden: false), moment(captured: captured))
        XCTAssertTrue(policy.hostReportsVisibility)
        XCTAssertFalse(captured, "the first menu after joining a game in play must still free the mouse")
    }

    func testFollowingSwitchedOffKeepsClickToCapture() {
        var policy = provenPolicy()
        var captured = policy.wantsCapture(after: .hostCursor(hidden: true),
                                           moment(follows: false, captured: false))
        XCTAssertFalse(captured, "with following off a hidden cursor takes nothing")
        captured = policy.wantsCapture(after: .click, moment(follows: false, captured: captured))
        XCTAssertTrue(captured)
        captured = policy.wantsCapture(after: .hostCursor(hidden: false),
                                       moment(follows: false, captured: captured))
        XCTAssertTrue(captured, "with following off only ⌃⌥ lets go")
    }

    func testDesktopModeNeverCaptures() {
        var policy = provenPolicy()
        for event: Policy.Event in [.hostCursor(hidden: true), .pointerMoved, .click, .reconsider] {
            XCTAssertFalse(policy.wantsCapture(after: event, moment(mode: .desktop, captured: false)),
                           "desktop mode took the mouse on \(event)")
        }
        // Switching to desktop with the mouse held gives it back.
        XCTAssertFalse(policy.wantsCapture(after: .reconsider, moment(mode: .desktop, captured: true)))
    }

    func testAWindowThatIsNotKeyNeverHoldsTheMouse() {
        var policy = provenPolicy()
        XCTAssertFalse(policy.wantsCapture(after: .hostCursor(hidden: true),
                                           moment(active: false, captured: false)))
        XCTAssertFalse(policy.wantsCapture(after: .reconsider, moment(active: false, captured: true)),
                       "losing focus must give the mouse back")
        // Coming forward again over the game takes it, as a game on this Mac would.
        XCTAssertTrue(policy.wantsCapture(after: .reconsider, moment(captured: false)))
    }

    func testTheInstanceIgnoresTheHostWhileNotCapturing() {
        // No view, never key: a push must change nothing, and touch no cursor.
        let capture = InputCapture()
        capture.lockSystemPointer = { _ in XCTFail("a window that is not key took the mouse") }
        capture.hostCursorVisibilityChanged(hidden: false)
        capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertFalse(capture.isPointerCaptured)
        XCTAssertTrue(capture.hostReportsCursorVisibility)
    }

    // MARK: - Wire names and motion

    func testHiddenIsAKnownName() {
        XCTAssertTrue(HostCursor.isHidden("hidden"))
        XCTAssertFalse(HostCursor.isHidden("arrow"))
        XCTAssertFalse(HostCursor.isHidden("ibeam"))
    }

    func testSensitivityScalesMotionAndKeepsTheRemainder() {
        let base = InputCapture.relativeMotion(deltaX: 3, deltaY: -2, pixelsPerPoint: 2,
                                               sensitivity: 1, residual: .zero)
        XCTAssertEqual(base.dx, 6)
        XCTAssertEqual(base.dy, -4)

        let doubled = InputCapture.relativeMotion(deltaX: 3, deltaY: -2, pixelsPerPoint: 2,
                                                  sensitivity: 2, residual: .zero)
        XCTAssertEqual(doubled.dx, 12)
        XCTAssertEqual(doubled.dy, -8)

        // A slow hand at a low sensitivity still gets there, a pixel at a time.
        var residual = CGPoint.zero
        var travelled = 0
        for _ in 0..<8 {
            let step = InputCapture.relativeMotion(deltaX: 0.5, deltaY: 0, pixelsPerPoint: 1,
                                                   sensitivity: 0.5, residual: residual)
            travelled += step.dx
            residual = step.residual
        }
        XCTAssertEqual(travelled, 2, "sub-pixel motion was lost to rounding")
    }

    // MARK: - What goes on the wire

    /// Gaming mode and following are remembered in the defaults; put them
    /// back as they were, absent included.
    private static let defaultsKeys = ["SolStream.pointerMode", "SolStream.followsHostCursor"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
        }
    }

    override func tearDown() {
        for key in Self.defaultsKeys {
            UserDefaults.standard.set(savedDefaults[key], forKey: key)
        }
        super.tearDown()
    }

    func testADesktopClickSendsWhereThenTheButton() {
        InputCapture.pointerMode = .desktop
        let mouse = Mouse()
        mouse.click()
        XCTAssertEqual(mouse.packets, [.abs(400, 300), .press(1), .abs(400, 300), .release(1)])
        XCTAssertFalse(mouse.locked)
    }

    func testClickToCaptureSendsThePositionAndTheClick() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.press()
        XCTAssertEqual(mouse.packets, [.abs(400, 300), .abs(400, 300), .press(1)],
                       "the click that captures must still reach the game, where it was made")
        XCTAssertTrue(mouse.locked)
        mouse.packets.removeAll()

        mouse.move(by: CGPoint(x: 3, y: -2))
        XCTAssertEqual(mouse.packets, [.rel(6, -4)], "captured, the mouse sends motion only")
        mouse.packets.removeAll()

        mouse.releaseChord()
        XCTAssertFalse(mouse.locked, "⌃⌥ must let the mouse go")
        XCTAssertEqual(mouse.packets, [], "and must not send a position on its way")
    }

    func testAFollowedGameTakesTheMouseOnAMoveAndSendsOnlyMotion() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.pointer = nil
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertFalse(mouse.locked, "the pointer was off the picture")

        mouse.pointer = CGPoint(x: 0.5, y: 0.5)
        mouse.move(by: CGPoint(x: 3, y: -2))
        XCTAssertTrue(mouse.locked)
        XCTAssertEqual(mouse.packets, [.rel(6, -4)],
                       "a position here would have turned the game's camera")
    }

    func testTheClickThatRetakesTheMouseGoesAsTheButtonAlone() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertTrue(mouse.locked)
        mouse.releaseChord()
        XCTAssertFalse(mouse.locked)
        mouse.packets.removeAll()

        // On the way to the title bar: the game is still reading motion.
        mouse.move(by: CGPoint(x: 3, y: -2))
        mouse.scroll()
        XCTAssertEqual(mouse.packets, [], "hover after ⌃⌥ swung the game's camera or changed its weapon")
        XCTAssertFalse(mouse.locked)
        XCTAssertEqual(mouse.capture.withheldFromGame, 2)

        mouse.press()
        XCTAssertTrue(mouse.locked)
        XCTAssertEqual(mouse.packets, [.press(1)])
    }

    /// ⇧ the monitor never saw go down -- held as the window took the
    /// keyboard, or pressed while a menu was tracking -- is put right by the
    /// click it is held for, before the button: a Shift-click is a Shift-click
    /// only if the PC has Shift.
    func testAClickBringsShiftDownBeforeTheButton() {
        let shift: UInt = 0x0002_0000 | 0x0000_0002  // the flag, and the left key's bit
        InputCapture.pointerMode = .desktop
        let desktop = Mouse()
        desktop.withKeys.removeAll()
        desktop.press(flags: shift)
        XCTAssertEqual(desktop.withKeys, [.abs(400, 300), .key(0xA0, true), .press(1)])

        // And with the mouse captured for a game.
        InputCapture.pointerMode = .gaming
        let game = Mouse()
        game.click()
        XCTAssertTrue(game.locked)
        game.withKeys.removeAll()
        game.press(flags: shift)
        XCTAssertEqual(game.withKeys, [.key(0xA0, true), .press(1)])
    }

    func testAReleaseWithNoForwardedPressSendsNothing() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertTrue(mouse.locked)
        mouse.lift()
        XCTAssertEqual(mouse.packets, [], "a lone release is not something to hand a game")
    }

    func testShowingTheCursorPutsThePCsUnderTheMacs() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.pointer = CGPoint(x: 0.25, y: 0.75)
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertTrue(mouse.locked)
        mouse.packets.removeAll()

        mouse.capture.hostCursorVisibilityChanged(hidden: false)
        XCTAssertFalse(mouse.locked, "the pause menu must have a pointer")
        XCTAssertEqual(mouse.packets, [.abs(200, 450)],
                       "the menu's cursor must be where the Mac's reappears")

        // A shape changing within the menu is not a reason to move it again.
        mouse.packets.removeAll()
        mouse.capture.hostCursorVisibilityChanged(hidden: false)
        XCTAssertEqual(mouse.packets, [])
    }

    func testAWindowComingForwardOverAHiddenCursorTakesTheMouse() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.capture.disableCapture()
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertFalse(mouse.locked, "a window that is not key took the mouse")
        mouse.capture.enableCapture()
        XCTAssertTrue(mouse.locked)
        mouse.capture.disableCapture()
        XCTAssertFalse(mouse.locked, "losing focus must give the mouse back")
    }

    func testAMoveOverSomethingCoveringThePictureTakesNothing() {
        InputCapture.pointerMode = .gaming
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.pointer = nil
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        // Inside the picture by geometry, but under another window.
        mouse.move(by: CGPoint(x: 3, y: -2))
        XCTAssertFalse(mouse.locked, "the mouse was taken from under another window")
        XCTAssertEqual(mouse.packets, [])
    }

    func testFollowingOffKeepsHoverAsPositions() {
        InputCapture.pointerMode = .gaming
        InputCapture.followsHostCursor = false
        let mouse = Mouse()
        mouse.capture.hostReportsCursorVisibility = true
        mouse.capture.hostCursorVisibilityChanged(hidden: true)
        XCTAssertFalse(mouse.locked)
        mouse.move(by: .zero)
        XCTAssertEqual(mouse.packets, [.abs(400, 300)])
    }

    // MARK: - The note

    func testTheCaptureNoteFitsTheNarrowestWindow() throws {
        let hint = CaptureHint()
        hint.isHidden = false
        hint.alphaValue = 1
        let narrowest = NSSize(width: 320, height: 200)
        let backdrop = NSView(frame: NSRect(origin: .zero, size: narrowest))
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        backdrop.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            hint.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 16),
            hint.widthAnchor.constraint(lessThanOrEqualTo: backdrop.widthAnchor, constant: -32),
        ])
        backdrop.layoutSubtreeIfNeeded()
        let label = try XCTUnwrap(hint.subviews.first as? NSTextField)
        XCTAssertEqual(label.stringValue, CaptureHint.text)
        XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width - 0.5,
                                    "the note is cut short in the narrowest window")
        XCTAssertNil(hint.hitTest(NSPoint(x: hint.frame.midX, y: hint.frame.midY)),
                     "the note took a click meant for the picture")

        // A picture to look at, for whoever changes it next.
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(narrowest.width * scale),
            pixelsHigh: Int(narrowest.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = narrowest
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solstream-capture-hint.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// A capture in a window that is never shown, fed real `NSEvent`s, with its
/// packets read back. The real cursor is never touched: locking it is
/// recorded instead, and where the pointer is, is said rather than asked.
///
/// The picture is 400×300 points showing an 800×600 crop, so a point in the
/// middle is canvas pixel 400,300 and one point of motion is two pixels.
private final class Mouse {
    enum Packet: Equatable {
        case abs(Int, Int), rel(Int, Int), press(UInt8), release(UInt8), scroll
        /// A key by virtual key, and whether it went down.
        case key(UInt16, Bool)
    }

    let capture = InputCapture()
    /// What the mouse sent.
    var packets: [Packet] = []
    /// The same, with the keys in among it: ⌃⌥ is forwarded, and Caps Lock
    /// is synced as capture starts, so the keys are kept out of `packets`.
    var withKeys: [Packet] = []
    private(set) var locked = false
    /// Where the pointer is, as a unit point in the picture; nil for not over
    /// it, or under something else.
    var pointer: CGPoint? = CGPoint(x: 0.5, y: 0.5)
    private let window: NSWindow
    private let size = NSSize(width: 400, height: 300)

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                          backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = view
        capture.lockSystemPointer = { [weak self] in self?.locked = $0 }
        capture.pointerStandIn = { [weak self] in self?.pointer }
        capture.attach(to: view)
        capture.sourceRect = CGRect(x: 0, y: 0, width: 800, height: 600)
        capture.canvasSize = CGSize(width: 800, height: 600)
        capture.onInput = { [weak self] data in self?.record(data) }
        capture.enableCapture()
    }

    deinit {
        capture.disableCapture()
    }

    func click() {
        press()
        lift()
    }

    /// - Parameter flags: the raw modifier word the press carries.
    func press(flags: UInt = 0) { capture.handleMouseEvent(event(.leftMouseDown, flags: flags)) }
    func lift() { capture.handleMouseEvent(event(.leftMouseUp)) }

    /// A move to the middle of the picture, carrying `delta` in points.
    func move(by delta: CGPoint) {
        capture.handleMouseEvent(event(.mouseMoved, delta: delta))
    }

    func scroll() {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                               wheel1: 1, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return XCTFail("could not build a scroll") }
        capture.handleMouseEvent(event)
    }

    /// ⌃⌥, as the left Control and Option keys send it.
    func releaseChord() {
        let flags: UInt = 0x0004_0000 | 0x0008_0000 | 0x0000_0001 | 0x0000_0020
        guard let event = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: flags), timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 0x3A) else { return XCTFail("could not build ⌃⌥") }
        capture.handleKeyEvent(event)
    }

    /// A mouse event in the middle of the picture.
    ///
    /// Deltas can only be set on the CGEvent underneath, and the trip there
    /// and back moves the location by wherever the window server thinks this
    /// unshown window is -- so the location is put back by the difference.
    private func event(_ type: NSEvent.EventType, delta: CGPoint = .zero,
                       flags: UInt = 0) -> NSEvent {
        let wanted = NSPoint(x: size.width / 2, y: size.height / 2)
        let plain = NSEvent.mouseEvent(with: type, location: wanted,
                                       modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                                       timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1,
                                       pressure: type == .leftMouseUp ? 0 : 1)!
        guard delta != .zero, let cg = plain.cgEvent else { return plain }
        cg.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x))
        cg.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y))
        cg.setDoubleValueField(.mouseEventDeltaX, value: Double(delta.x))
        cg.setDoubleValueField(.mouseEventDeltaY, value: Double(delta.y))
        let landed = NSEvent(cgEvent: cg)!.locationInWindow
        cg.location = CGPoint(x: cg.location.x + (wanted.x - landed.x),
                              y: cg.location.y - (wanted.y - landed.y))
        return NSEvent(cgEvent: cg)!
    }

    private func record(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, let kind = SMTInput.Kind(rawValue: bytes[0]) else { return }
        let body = Array(bytes.dropFirst(2))
        func word(_ at: Int) -> Int { Int(body[at]) << 8 | Int(body[at + 1]) }
        func signed(_ at: Int) -> Int { Int(Int16(bitPattern: UInt16(word(at)))) }
        let packet: Packet
        switch kind {
        case .mouseAbs:
            // Back from 0...65535 to the 800×600 canvas.
            packet = .abs((word(0) * 800 + 32767) / 65535, (word(2) * 600 + 32767) / 65535)
        case .mouseRel:
            packet = .rel(signed(0), signed(2))
        case .button:
            packet = body[1] != 0 ? .press(body[0]) : .release(body[0])
        case .scrollV, .scrollH:
            packet = .scroll
        case .key where body.count >= 3:
            withKeys.append(.key(UInt16(word(0)), body[2] != 0))
            return
        default:
            return
        }
        packets.append(packet)
        withKeys.append(packet)
    }
}
