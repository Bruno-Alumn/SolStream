import AppKit
import XCTest
@testable import InputCapture
@testable import VideoDecoder

/// A Japanese, Chinese or Korean input method on the Mac composes on the
/// Mac, and only what it settles on reaches the PC.
final class InputMethodTests: XCTestCase {
    private func key(_ characters: String, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false,
                         keyCode: keyCode)!
    }

    /// Only keys that type go to an input method that is not composing:
    /// Return, Tab, Escape and the arrows go on to the PC as keys.
    func testOnlyKeysThatTypeGoToTheInputMethod() {
        XCTAssertTrue(InputCapture.typesCharacters(key("k")))
        XCTAssertTrue(InputCapture.typesCharacters(key(" ", keyCode: 0x31)))
        XCTAssertTrue(InputCapture.typesCharacters(key("1", keyCode: 0x12)))
        XCTAssertFalse(InputCapture.typesCharacters(key("\r", keyCode: 0x24)))
        XCTAssertFalse(InputCapture.typesCharacters(key("\t", keyCode: 0x30)))
        XCTAssertFalse(InputCapture.typesCharacters(key("\u{1B}", keyCode: 0x35)))
        XCTAssertFalse(InputCapture.typesCharacters(key("\u{F702}", keyCode: 0x7B)), "←")
        XCTAssertFalse(InputCapture.typesCharacters(key("\u{F704}", keyCode: 0x7A)), "F1")
    }

    /// The word being composed is shown, not typed; what is settled on is
    /// typed, and the shown word goes.
    func testAComposedWordIsShownThenTypedWhenSettled() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var shown: [String?] = []
        var typed: [String] = []
        view.onMarkedText = { shown.append($0) }
        view.onInsertText = { typed.append($0) }

        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 1))
        view.setMarkedText(NSAttributedString(string: "かな"),
                           selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(typed, [], "nothing reaches the PC while it is being composed")

        view.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(typed, ["仮名"])
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(shown, ["か", "かな", nil])
    }

    /// Dropping the word -- Escape in the input method -- types nothing.
    func testADroppedWordTypesNothing() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        var typed: [String] = []
        var shown: [String?] = []
        view.onInsertText = { typed.append($0) }
        view.onMarkedText = { shown.append($0) }
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(typed, [])
        XCTAssertEqual(shown, ["ni", nil])
        XCTAssertFalse(view.hasMarkedText())
    }
}
