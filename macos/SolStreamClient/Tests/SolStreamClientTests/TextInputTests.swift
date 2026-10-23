import AppKit
import XCTest
@testable import InputCapture
@testable import MediaSession
@testable import VideoDecoder

/// Text that no key typed -- keystrokes posted by another program, the
/// Character Viewer, dictation -- reaches the PC as that text, while every
/// real key still goes by position.
final class TextInputTests: XCTestCase {
    private typealias Origin = InputCapture.KeyOrigin

    /// What the keys used here type on a US layout, with and without Shift,
    /// Caps Lock and Option.
    private static let usLayout: [UInt16: Set<String>] = [
        0x00: ["a", "A", "å", "Å"],
        0x0E: ["e", "E", "´"],
        0x09: ["v", "V", "√", "◊"],
        0x24: ["\r"],
        0x7B: ["\u{1C}"],
    ]

    private func origin(_ characters: String?, keyCode: UInt16 = 0,
                        flags: NSEvent.ModifierFlags = []) -> Origin {
        InputCapture.keyOrigin(characters: characters, flags: flags) {
            Self.usLayout[keyCode]
        }
    }

    // MARK: - Which events carry only text

    /// The case that was reported: an automation tool's keystrokes all name
    /// key code 0, which is A, and carry their text.
    func testKeyCodeZeroCarryingOtherTextIsText() {
        XCTAssertEqual(origin("e"), .text("e"))
        XCTAssertEqual(origin("H"), .text("H"))
        XCTAssertEqual(origin("😀"), .text("😀"))
        XCTAssertEqual(origin("é"), .text("é"))
    }

    /// Whatever a key types on the layout is that key, in any state of
    /// Shift, Caps Lock and Option.
    func testWhatTheKeyTypesIsTheKey() {
        XCTAssertEqual(origin("a"), .key)
        XCTAssertEqual(origin("A"), .key)
        XCTAssertEqual(origin("e", keyCode: 0x0E), .key)
        XCTAssertEqual(origin("E", keyCode: 0x0E, flags: .shift), .key)
        XCTAssertEqual(origin("´", keyCode: 0x0E, flags: .option), .key)
    }

    /// Shortcuts go by position whatever they carry, so ⌘V is Control+V even
    /// when a program posted it on the wrong key.
    func testAnythingWithCommandOrControlIsAKey() {
        XCTAssertEqual(origin("v", flags: .command), .key)
        XCTAssertEqual(origin("v", flags: .control), .key)
        XCTAssertEqual(origin("\u{16}", flags: .control), .key)
    }

    /// A dead key's press carries no text, the arrows and function keys
    /// carry private-use code points, and a layout that cannot be asked
    /// cannot say otherwise: all of them are keys.
    func testWhatCannotBeToldApartIsAKey() {
        XCTAssertEqual(origin(""), .key)
        XCTAssertEqual(origin(nil), .key)
        XCTAssertEqual(origin("\u{F702}", keyCode: 0x7B), .key)
        XCTAssertEqual(InputCapture.keyOrigin(characters: "e", flags: []) { nil }, .key)
        XCTAssertEqual(InputCapture.keyOrigin(characters: "e", flags: []) { [] }, .key)
    }

    /// A line break, tab, backspace or escape that no key typed is the key
    /// that types it; any other control character stays a key.
    func testControlCharactersAreTheirKeys() {
        XCTAssertEqual(origin("\r"), .standIn(0x24))
        XCTAssertEqual(origin("\n"), .standIn(0x24))
        XCTAssertEqual(origin("\t"), .standIn(0x30))
        XCTAssertEqual(origin("\u{7F}"), .standIn(0x33))
        XCTAssertEqual(origin("\u{08}"), .standIn(0x33))
        XCTAssertEqual(origin("\u{1B}"), .standIn(0x35))
        XCTAssertEqual(origin("\r", keyCode: 0x24), .key)
        XCTAssertEqual(origin("\u{19}"), .key)
    }

    /// The real layout, whatever it is on the Mac running this, answers --
    /// and every layout's space bar types a space.
    func testTheLayoutIsAsked() throws {
        let space = try XCTUnwrap(InputCapture.charactersOnLayout(keyCode: 0x31, event: nil))
        XCTAssertTrue(space.contains(" "), "the space bar types \(space)")
    }

    // MARK: - On the wire

    private final class Wire {
        enum Packet: Equatable {
            case scan(UInt16, Bool)
            case vk(UInt16, Bool)
            case text(String)
        }

        let capture = InputCapture()
        private let window: NSWindow
        private(set) var packets: [Packet] = []

        init(scanCodes: Bool = true) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSView(frame: window.contentLayoutRect)
            window.contentView = view
            capture.attach(to: view)
            capture.sendsScanCodes = scanCodes
            capture.keyboardIsISO = { _ in false }
            capture.modifierFlagsNow = { [] }
            capture.keyTypes = { code, _ in TextInputTests.usLayout[code] }
            capture.enableCapture()
            capture.onInput = { [weak self] data in self?.record(data) }
        }

        func clear() { packets.removeAll() }

        /// A key event as a program posts one, or as a keyboard sends it.
        @discardableResult
        func send(_ type: NSEvent.EventType, keyCode: UInt16, text: String,
                  ignoringModifiers: String? = nil, flags: UInt = 0) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0, windowNumber: 0, context: nil,
                characters: text, charactersIgnoringModifiers: ignoringModifiers ?? text,
                isARepeat: false, keyCode: keyCode) else {
                XCTFail("could not build a \(type) event")
                return false
            }
            return capture.handleKeyEvent(event)
        }

        /// What a program typing `text` posts: each character down and up on
        /// key code 0.
        func type(_ text: String) {
            for character in text {
                send(.keyDown, keyCode: 0, text: String(character))
                send(.keyUp, keyCode: 0, text: String(character))
            }
        }

        private func record(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count >= 2, let kind = SMTInput.Kind(rawValue: bytes[0]) else { return }
            let body = Array(bytes.dropFirst(2))
            switch kind {
            case .keyScan, .key:
                guard body.count >= 3 else { return }
                let code = UInt16(body[0]) << 8 | UInt16(body[1])
                packets.append(kind == .keyScan ? .scan(code, body[2] != 0)
                                                : .vk(code, body[2] != 0))
            case .text:
                var units: [UInt16] = []
                for at in stride(from: 0, to: body.count - 1, by: 2) {
                    units.append(UInt16(body[at]) << 8 | UInt16(body[at + 1]))
                }
                let text = String(decoding: units, as: UTF16.self)
                // Runs of text are joined: where a run was divided is not
                // something the PC can see.
                if case .text(let before)? = packets.last {
                    packets[packets.count - 1] = .text(before + text)
                } else {
                    packets.append(.text(text))
                }
            default:
                return
            }
        }
    }

    /// "echo Hello from a Mac" typed by a program arrives as that text, not
    /// as twenty-one presses of A.
    ///
    /// Except each "a", which key code 0 does type: that event cannot be
    /// told from the A key itself, so it goes as the A key does, by position,
    /// and types an "a" wherever the PC's layout has one there.
    func testPostedKeystrokesArriveAsTheirText() {
        let wire = Wire()
        wire.clear()
        wire.type("echo Hello from a Mac")
        XCTAssertEqual(wire.packets, [.text("echo Hello from "),
                                      .scan(0x1E, true), .scan(0x1E, false), .text(" M"),
                                      .scan(0x1E, true), .scan(0x1E, false), .text("c")])
    }

    /// A posted line break presses Return, by position, once.
    func testAPostedReturnPressesReturn() {
        let wire = Wire()
        wire.clear()
        wire.type("ls\r")
        XCTAssertEqual(wire.packets, [.text("ls"), .scan(0x1C, true), .scan(0x1C, false)])
    }

    /// The same text posted to an old host: it has always taken text, and a
    /// Return goes as the virtual key it takes.
    func testAnOldHostGetsTextToo() {
        let wire = Wire(scanCodes: false)
        wire.clear()
        wire.type("é\r")
        XCTAssertEqual(wire.packets, [.text("é"), .vk(0x0D, true), .vk(0x0D, false)])
    }

    /// Real keys are untouched: E by position, A by position, ⌘V as
    /// Control and V.
    func testRealKeysStillGoByPosition() {
        let wire = Wire()
        wire.clear()
        XCTAssertTrue(wire.send(.keyDown, keyCode: 0x0E, text: "e"))
        wire.send(.keyUp, keyCode: 0x0E, text: "e")
        wire.send(.keyDown, keyCode: 0x00, text: "a")
        wire.send(.keyUp, keyCode: 0x00, text: "a")
        XCTAssertEqual(wire.packets, [.scan(0x12, true), .scan(0x12, false),
                                      .scan(0x1E, true), .scan(0x1E, false)])

        wire.clear()
        let command: UInt = 0x0010_0000 | 0x0000_0008
        wire.send(.flagsChanged, keyCode: 0x37, text: "", flags: command)
        wire.send(.keyDown, keyCode: 0x09, text: "v", flags: command)
        wire.send(.keyUp, keyCode: 0x09, text: "v", flags: command)
        wire.send(.flagsChanged, keyCode: 0x37, text: "", flags: 0)
        XCTAssertEqual(wire.packets, [.scan(0x1D, true), .scan(0x2F, true),
                                      .scan(0x2F, false), .scan(0x1D, false)])
    }

    /// A dead key and the key it composes with both go by position, even if
    /// the second carries the composed é: sent as text, it would land beside
    /// the PC's own ´ rather than finish it. A posted character after them is
    /// text again.
    func testTheKeyAfterADeadKeyIsAKey() {
        let wire = Wire()
        wire.clear()
        // German ´, at the US = key's place: it types nothing yet.
        wire.send(.keyDown, keyCode: 0x18, text: "", ignoringModifiers: "´")
        wire.send(.keyUp, keyCode: 0x18, text: "", ignoringModifiers: "´")
        // Then e, carrying what the Mac composed.
        wire.send(.keyDown, keyCode: 0x0E, text: "é", ignoringModifiers: "é")
        wire.send(.keyUp, keyCode: 0x0E, text: "é", ignoringModifiers: "é")
        XCTAssertEqual(wire.packets, [.scan(0x0D, true), .scan(0x0D, false),
                                      .scan(0x12, true), .scan(0x12, false)])
        wire.clear()
        wire.type("x")
        XCTAssertEqual(wire.packets, [.text("x")])
    }

    /// A text-only event is consumed, so it cannot also act on this Mac, and
    /// its release sends nothing: nothing was pressed.
    func testTextIsConsumedAndItsReleaseSendsNothing() {
        let wire = Wire()
        wire.clear()
        XCTAssertTrue(wire.send(.keyDown, keyCode: 0, text: "x"))
        XCTAssertTrue(wire.send(.keyUp, keyCode: 0, text: "x"))
        XCTAssertEqual(wire.packets, [.text("x")])
    }

    /// The Character Viewer and dictation insert text: an emoji goes whole,
    /// a line break as Return, and other control characters not at all.
    func testInsertedTextIsSentAsText() {
        let wire = Wire()
        wire.clear()
        wire.capture.sendText("Hi 👋🏽\r\nthere\u{07}\tok")
        XCTAssertEqual(wire.packets, [.text("Hi 👋🏽"), .scan(0x1C, true), .scan(0x1C, false),
                                      .text("there"), .scan(0x0F, true), .scan(0x0F, false),
                                      .text("ok")])
    }

    /// Nothing is sent from a window that does not have the keyboard.
    func testNoTextWithoutTheKeyboard() {
        let wire = Wire()
        wire.capture.disableCapture()
        wire.clear()
        wire.capture.sendText("hello")
        XCTAssertEqual(wire.packets, [])
    }

    // MARK: - The stream view

    /// The view hands over what the system inserts, and takes the keyboard
    /// focus only when something is listening for it.
    func testTheStreamViewPassesInsertedTextOn() {
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(view.acceptsFirstResponder)
        var inserted: [String] = []
        view.onInsertText = { inserted.append($0) }
        XCTAssertTrue(view.acceptsFirstResponder)
        XCTAssertFalse(view.hasMarkedText())
        view.insertText("🎉", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText(NSAttributedString(string: "dictated"),
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(inserted, ["🎉", "dictated"])
    }
}
