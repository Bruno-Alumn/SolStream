import AppKit
import XCTest
@testable import InputCapture
@testable import MediaSession
@testable import AgentChannel

/// A Mac set to one keyboard layout and a PC set to another: with a host that
/// says "scancodes" 2, a key typed in Desktop mode goes with the character
/// this Mac's layout made, so a Spanish Mac's Ñ is Ñ on a US PC.
final class KeyCharacterTests: XCTestCase {

    private var savedMode: Any?

    override func setUp() {
        super.setUp()
        savedMode = UserDefaults.standard.object(forKey: "SolStream.pointerMode")
        InputCapture.pointerMode = .desktop
    }

    override func tearDown() {
        if let savedMode {
            UserDefaults.standard.set(savedMode, forKey: "SolStream.pointerMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "SolStream.pointerMode")
        }
        super.tearDown()
    }

    func testWhichCharactersGoWithTheirKey() {
        XCTAssertEqual(InputCapture.characterToSend(characters: "ñ", flags: []), "ñ")
        XCTAssertEqual(InputCapture.characterToSend(characters: "Ñ", flags: [.shift]), "Ñ")
        XCTAssertEqual(InputCapture.characterToSend(characters: "=", flags: [.shift]), "=")
        // ⌥2 is the Spanish Mac's @; ⌥F is the PC's Alt+F.
        XCTAssertEqual(InputCapture.characterToSend(characters: "@", flags: [.option]), "@")
        XCTAssertNil(InputCapture.characterToSend(characters: "ƒ", flags: [.option]))
        // Shortcuts, keys that are keys, the keypad and a plain space go by
        // position.
        XCTAssertNil(InputCapture.characterToSend(characters: "c", flags: [.command]))
        XCTAssertNil(InputCapture.characterToSend(characters: "c", flags: [.control]))
        XCTAssertNil(InputCapture.characterToSend(characters: "\r", flags: []))
        XCTAssertNil(InputCapture.characterToSend(characters: "\u{F702}", flags: [.function]))
        XCTAssertNil(InputCapture.characterToSend(characters: "1", flags: [.numericPad]))
        XCTAssertNil(InputCapture.characterToSend(characters: " ", flags: []))
        XCTAssertNil(InputCapture.characterToSend(characters: "", flags: []))
        // The accent a dead key makes before Space is a character.
        XCTAssertEqual(InputCapture.characterToSend(characters: "´", flags: []), "´")
        XCTAssertEqual(InputCapture.characterToSend(characters: "😀", flags: []), "😀")
        XCTAssertNil(InputCapture.characterToSend(characters: "´x", flags: []))
    }

    func testTheCharacterRidesAfterTheFourBytes() {
        let event = SMTInput.scanKey(code: 0x0027, pressed: true, modifiers: [], character: "ñ")
        XCTAssertEqual([UInt8](event), [SMTInput.Kind.keyScan.rawValue, 6, 0x00, 0x27, 1, 0, 0x00, 0xF1])
        let plain = SMTInput.scanKey(code: 0x0027, pressed: false, modifiers: [])
        XCTAssertEqual([UInt8](plain), [SMTInput.Kind.keyScan.rawValue, 4, 0x00, 0x27, 0, 0])
        // Still the same key to hold and let go of.
        XCTAssertEqual(SMTInput.holdTarget(of: event)?.target, SMTInput.holdTarget(of: plain)?.target)
    }

    func testTheHostsAnswerDecides() {
        XCTAssertFalse(AgentConnectionProbe.takes(["scancodes": 1]))
        XCTAssertTrue(AgentConnectionProbe.takes(["scancodes": 2]))
        XCTAssertFalse(AgentConnectionProbe.takes([:]))
    }

    // MARK: - Through the capture

    private func capture(characters: Bool) -> (InputCapture, () -> [[UInt8]]) {
        let capture = InputCapture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        capture.attach(to: view)
        capture.sendsScanCodes = true
        capture.sendsKeyCharacters = characters
        capture.keyboardIsISO = { _ in false }
        capture.enableCapture()
        var packets: [[UInt8]] = []
        capture.onInput = { data in
            let bytes = [UInt8](data)
            if bytes.first == SMTInput.Kind.keyScan.rawValue { packets.append(bytes) }
        }
        return (capture, { packets })
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ characters: String,
                     ignoring: String? = nil, flags: NSEvent.ModifierFlags = [],
                     repeat isARepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring ?? characters,
                         isARepeat: isARepeat, keyCode: code)!
    }

    /// The Ñ key, US ';' place: its press carries "ñ", its repeat too, and
    /// its release is the bare key.
    func testASpanishKeyGoesWithItsCharacter() {
        let (capture, packets) = capture(characters: true)
        defer { capture.disableCapture() }
        capture.handleKeyEvent(key(.keyDown, 0x29, "ñ"))
        capture.handleKeyEvent(key(.keyDown, 0x29, "ñ", repeat: true))
        capture.handleKeyEvent(key(.keyUp, 0x29, "ñ"))
        XCTAssertEqual(packets().count, 3)
        XCTAssertEqual(Array(packets()[0][2...]), [0x00, 0x27, 1, 0, 0x00, 0xF1])
        XCTAssertEqual(Array(packets()[1][2...]), [0x00, 0x27, 1, 0, 0x00, 0xF1])
        XCTAssertEqual(Array(packets()[2][2...]), [0x00, 0x27, 0, 0])
    }

    /// A host that predates it is sent the key alone, as before.
    func testAnOlderHostIsSentTheKeyAlone() {
        let (capture, packets) = capture(characters: false)
        defer { capture.disableCapture() }
        capture.keyTypes = { _, _ in ["ñ", "Ñ"] }
        capture.handleKeyEvent(key(.keyDown, 0x29, "ñ"))
        XCTAssertEqual(packets().map { $0.count }, [6])
    }

    /// In Gaming mode a key is a control, by position.
    func testGamingModeSendsKeysByPosition() {
        InputCapture.pointerMode = .gaming
        let (capture, packets) = capture(characters: true)
        defer { capture.disableCapture() }
        capture.keyTypes = { _, _ in ["ñ", "Ñ"] }
        capture.handleKeyEvent(key(.keyDown, 0x29, "ñ"))
        XCTAssertEqual(packets().map { $0.count }, [6])
    }

    /// ´ then e: nothing for the dead key, then é with the E key.
    func testADeadKeyIsComposedHere() {
        let (capture, packets) = capture(characters: true)
        defer { capture.disableCapture() }
        capture.handleKeyEvent(key(.keyDown, 0x21, "", ignoring: "´"))
        capture.handleKeyEvent(key(.keyUp, 0x21, "´"))
        XCTAssertTrue(packets().isEmpty, "the dead key went to the host")
        capture.handleKeyEvent(key(.keyDown, 0x0E, "é", ignoring: "e"))
        XCTAssertEqual(Array(packets().last![2...]), [0x00, 0x12, 1, 0, 0x00, 0xE9])
    }

    /// ⌘C stays a shortcut by position, with no character.
    func testShortcutsCarryNoCharacter() {
        let (capture, packets) = capture(characters: true)
        defer { capture.disableCapture() }
        capture.handleKeyEvent(key(.keyDown, 0x08, "c", flags: [.command]))
        XCTAssertEqual(packets().last.map { $0.count }, 6)
    }
}

/// `AgentConnection.takesKeyCharacters` without reaching into the module's
/// internals from every test.
private enum AgentConnectionProbe {
    static func takes(_ reply: [String: Any]) -> Bool {
        AgentConnection.takesKeyCharacters(inReply: reply)
    }
}
