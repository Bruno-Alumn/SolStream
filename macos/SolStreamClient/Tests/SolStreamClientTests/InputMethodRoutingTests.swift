import AppKit
import XCTest
@testable import InputCapture
@testable import MediaSession

/// Which keys go to the Mac's input method and which to the PC, with real
/// `NSEvent`s through the capture and a stand-in input method.
final class InputMethodRoutingTests: XCTestCase {
    private final class Rig {
        let capture = InputCapture()
        private let window: NSWindow
        /// Key codes sent to the PC, pressed or not.
        private(set) var toPC: [(code: UInt16, pressed: Bool)] = []
        /// Key codes the input method was handed.
        private(set) var toInputMethod: [UInt16] = []
        var selected = true
        var composing = false
        /// What the stand-in answers: taken, or passed on.
        var takes = true

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSView(frame: window.contentLayoutRect)
            window.contentView = view
            capture.attach(to: view)
            capture.sendsScanCodes = false
            capture.keyboardIsISO = { _ in false }
            capture.enableCapture()
            capture.inputMethodIsSelected = { [unowned self] in self.selected }
            capture.inputMethodComposing = { [unowned self] in self.composing }
            capture.inputMethodHandles = { [unowned self] event in
                self.toInputMethod.append(event.keyCode)
                return self.takes
            }
            capture.onInput = { [weak self] data in
                let bytes = [UInt8](data)
                guard bytes.count >= 6, bytes[0] == SMTInput.Kind.key.rawValue else { return }
                self?.toPC.append((code: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                                   pressed: bytes[4] != 0))
            }
        }

        func press(_ keyCode: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
            key(.keyDown, keyCode, characters, flags)
            key(.keyUp, keyCode, characters, flags)
        }

        func key(_ type: NSEvent.EventType, _ keyCode: UInt16, _ characters: String,
                 _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                         timestamp: 0, windowNumber: 0, context: nil,
                                         characters: characters,
                                         charactersIgnoringModifiers: characters,
                                         isARepeat: false, keyCode: keyCode)!
            capture.handleKeyEvent(event)
        }
    }

    private let kKey: UInt16 = 0x28, returnKey: UInt16 = 0x24, spaceKey: UInt16 = 0x31

    func testWithNoInputMethodSelectedKeysGoToThePC() {
        let rig = Rig()
        rig.selected = false
        rig.press(kKey, "k")
        XCTAssertEqual(rig.toInputMethod, [])
        XCTAssertEqual(rig.toPC.map(\.pressed), [true, false])
    }

    func testATypingKeyAndItsReleaseGoToTheInputMethod() {
        let rig = Rig()
        rig.press(kKey, "k")
        XCTAssertEqual(rig.toInputMethod, [kKey])
        XCTAssertTrue(rig.toPC.isEmpty, "the PC got a key the input method had")
    }

    func testReturnWithNothingComposedIsThePCs() {
        let rig = Rig()
        rig.press(returnKey, "\r")
        XCTAssertEqual(rig.toInputMethod, [])
        XCTAssertEqual(rig.toPC.count, 2)
    }

    func testReturnWhileComposingSettlesTheWord() {
        let rig = Rig()
        rig.composing = true
        rig.press(returnKey, "\r")
        XCTAssertEqual(rig.toInputMethod, [returnKey])
        XCTAssertTrue(rig.toPC.isEmpty)
    }

    /// Korean's Return after a syllable: settled, then passed on.
    func testAKeyTheInputMethodPassesOnGoesToThePC() {
        let rig = Rig()
        rig.composing = true
        rig.takes = false
        rig.press(returnKey, "\r")
        XCTAssertEqual(rig.toInputMethod, [returnKey])
        XCTAssertEqual(rig.toPC.map(\.pressed), [true, false])
    }

    func testOptionChordsAreTheAltOfThePC() {
        let rig = Rig()
        rig.press(0x03, "ƒ", flags: .option)
        XCTAssertEqual(rig.toInputMethod, [])
        XCTAssertFalse(rig.toPC.isEmpty)
    }

    func testSpaceWithNothingComposedIsTheSpaceKey() {
        let rig = Rig()
        rig.press(spaceKey, " ")
        XCTAssertEqual(rig.toInputMethod, [])
        XCTAssertEqual(rig.toPC.count, 2)
        rig.composing = true
        rig.press(spaceKey, " ")
        XCTAssertEqual(rig.toInputMethod, [spaceKey], "while composing, Space picks a candidate")
    }

    /// A key already down on the PC is let go of there, whatever is
    /// selected by the time it comes up.
    func testAKeyHeldOnThePCIsReleasedThereAfterSwitching() {
        let rig = Rig()
        rig.selected = false
        rig.key(.keyDown, kKey, "k")
        rig.selected = true
        rig.key(.keyUp, kKey, "k")
        XCTAssertEqual(rig.toInputMethod, [])
        XCTAssertEqual(rig.toPC.map(\.pressed), [true, false])
    }
}
