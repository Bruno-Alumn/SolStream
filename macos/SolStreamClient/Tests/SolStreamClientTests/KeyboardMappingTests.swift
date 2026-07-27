import AppKit
import XCTest
@testable import InputCapture
@testable import StreamConnection

/// Checks the keyboard translation: Command carries Windows Control, the
/// Windows key is unreachable, and SolStream's own shortcuts stay on this Mac.
final class KeyboardMappingTests: XCTestCase {
    private let capture = InputCapture()

    private func key(_ macKeyCode: UInt16) -> InputCapture.ModifierKey {
        guard let match = capture.modifierKeys.first(where: { $0.macKeyCode == macKeyCode }) else {
            fatalError("no modifier mapping for mac key 0x\(String(macKeyCode, radix: 16))")
        }
        return match
    }

    private let leftCommand: UInt16 = 0x37
    private let rightCommand: UInt16 = 0x36
    private let leftControl: UInt16 = 0x3B
    private let rightControl: UInt16 = 0x3E

    // MARK: - The mapping itself

    /// The Windows key raises Windows' own shell over the top of the
    /// application being streamed, which is the one thing a window pretending to
    /// be a local application must never do.
    func testNoKeyCanReachTheWindowsKey() {
        let windowsKey: Set<UInt16> = [0x5B, 0x5C]
        for entry in capture.modifierKeys {
            XCTAssertFalse(windowsKey.contains(entry.windowsKeyCode),
                           "mac key 0x\(String(entry.macKeyCode, radix: 16)) still sends the Windows key")
        }
    }

    func testCommandSendsControl() {
        XCTAssertEqual(key(leftCommand).windowsKeyCode, 0xA2)   // VK_LCONTROL
        XCTAssertEqual(key(rightCommand).windowsKeyCode, 0xA3)  // VK_RCONTROL
    }

    /// Muscle memory from either side has to work, so Control still means
    /// Control — which is what makes two physical keys share one Windows key.
    func testControlStillSendsControl() {
        XCTAssertEqual(key(leftControl).windowsKeyCode, 0xA2)
        XCTAssertEqual(key(rightControl).windowsKeyCode, 0xA3)
    }

    // MARK: - Two keys, one Windows key

    /// Letting go of ⌘ while ⌃ is still held must not tell the host Control is
    /// up: the user is still pressing it, and the host would drop out of the
    /// chord and type the next letter into the document.
    func testReleasingCommandKeepsControlDownWhileControlIsHeld() {
        let bothDown = key(leftCommand).deviceMask | key(leftControl).deviceMask
        // ⌘ has just come up; ⌃ is still down in the reported flags.
        let afterCommandUp = bothDown & ~key(leftCommand).deviceMask
        XCTAssertTrue(InputCapture.otherKeyHolds(key(leftCommand), flags: afterCommandUp,
                                                 among: capture.modifierKeys),
                      "the key-up for ⌘ would have released a Control the hand is still holding")
    }

    func testReleasingTheLastOneDoesSendTheKeyUp() {
        XCTAssertFalse(InputCapture.otherKeyHolds(key(leftControl), flags: 0,
                                                  among: capture.modifierKeys))
    }

    /// The left and right halves are separate Windows keys, so one must not
    /// suppress the other.
    func testTheTwoSidesAreIndependent() {
        let rightControlDown = key(rightControl).deviceMask
        XCTAssertFalse(InputCapture.otherKeyHolds(key(leftCommand), flags: rightControlDown,
                                                  among: capture.modifierKeys))
    }

    /// Shift is nobody else's key code, so it is never suppressed.
    func testShiftIsUnaffected() {
        let everythingElse = capture.modifierKeys
            .filter { $0.macKeyCode != 0x38 }
            .reduce(UInt(0)) { $0 | $1.deviceMask }
        XCTAssertFalse(InputCapture.otherKeyHolds(key(0x38), flags: everythingElse,
                                                  among: capture.modifierKeys))
    }

    // MARK: - What stays on this Mac

    func testCommandQIsReserved() {
        XCTAssertTrue(InputCapture.isReserved(keyCode: 0x0C, flags: [.command]))
    }

    /// ⌃⌘ is SolStream's own prefix, so the menu items moved onto it are never
    /// forwarded — and because ⌃ and ⌘ are both Control on the host, the host
    /// loses nothing by it.
    func testControlCommandIsReserved() {
        for code: UInt16 in [0x03 /* F */, 0x0D /* W */, 0x1F /* O */, 0x02 /* D */] {
            XCTAssertTrue(InputCapture.isReserved(keyCode: code, flags: [.control, .command]))
        }
    }

    /// The whole point of the remap: ⌘C, ⌘V, ⌘Z, ⌘F and the rest belong to the
    /// streamed application.
    func testOrdinaryCommandShortcutsGoToTheHost() {
        for code: UInt16 in [0x08 /* C */, 0x09 /* V */, 0x06 /* Z */, 0x03 /* F */,
                             0x0D /* W */, 0x01 /* S */, 0x00 /* A */] {
            XCTAssertFalse(InputCapture.isReserved(keyCode: code, flags: [.command]),
                           "⌘ + 0x\(String(code, radix: 16)) was kept on the Mac")
        }
    }

    /// Only bare ⌘Q. Anything else on Q is the application's.
    func testShiftCommandQIsNotReserved() {
        XCTAssertFalse(InputCapture.isReserved(keyCode: 0x0C, flags: [.shift, .command]))
        XCTAssertFalse(InputCapture.isReserved(keyCode: 0x0C, flags: [.option, .command]))
    }

    func testNothingWithoutCommandIsReserved() {
        XCTAssertFalse(InputCapture.isReserved(keyCode: 0x0C, flags: []))
        XCTAssertFalse(InputCapture.isReserved(keyCode: 0x03, flags: [.control]))
    }

    // MARK: - The bitmask on the wire

    func testCommandReportsAsControl() {
        XCTAssertEqual(InputCapture.modifiers(from: [.command]).rawValue,
                       InputProtocol.Modifiers.control.rawValue)
    }

    /// `.meta` is the Windows key. Nothing may set it.
    func testMetaIsNeverSet() {
        let everything: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        XCTAssertFalse(InputCapture.modifiers(from: everything).contains(.meta))
    }

    func testTheOtherModifiersAreUnchanged() {
        let both = InputCapture.modifiers(from: [.shift, .option])
        XCTAssertTrue(both.contains(.shift))
        XCTAssertTrue(both.contains(.alt))
        XCTAssertFalse(both.contains(.control))
    }

    // MARK: - What actually goes on the wire

    /// Drives real `NSEvent`s through the capture and reads back the packets,
    /// so these assert the bytes a keystroke produces rather than restating the
    /// mapping table in a second place.
    private final class Wire {
        let capture = InputCapture()
        private let window: NSWindow
        private(set) var packets: [(code: UInt16, pressed: Bool, modifiers: UInt8)] = []

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSView(frame: window.contentLayoutRect)
            window.contentView = view
            capture.attach(to: view)
            capture.enableCapture()
            capture.onInput = { [weak self] data in
                // NV_INPUT_HEADER is 8 bytes: size, then the magic. The key code
                // is little-endian at offset 9, the modifier byte at 11.
                guard data.count >= 12 else { return }
                let bytes = [UInt8](data)
                let magic = UInt32(bytes[4]) | UInt32(bytes[5]) << 8
                          | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
                self?.packets.append((code: UInt16(bytes[9]) | UInt16(bytes[10]) << 8,
                                      pressed: magic == 3,
                                      modifiers: bytes[11]))
            }
        }

        /// - Parameter deviceFlags: the raw modifier word, public bits plus the
        ///   device-dependent bit for the exact physical key.
        @discardableResult
        func send(_ type: NSEvent.EventType, keyCode: UInt16, deviceFlags: UInt) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: deviceFlags),
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode) else {
                XCTFail("could not build a \(type) event")
                return false
            }
            return capture.handleKeyEvent(event)
        }
    }

    private let commandFlag: UInt = 0x0010_0000
    private let controlFlag: UInt = 0x0004_0000
    private let leftCommandBit: UInt = 0x0000_0008
    private let leftControlBit: UInt = 0x0000_0001

    /// The headline: ⌘C reaches Windows as Ctrl+C.
    func testCommandCReachesTheHostAsControlC() {
        let wire = Wire()
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.keyDown, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.keyUp, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)

        XCTAssertEqual(wire.packets.map(\.code), [0xA2, 0x43, 0x43, 0xA2])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, true, false, false])
        // The C carries the Control bit, and never the Windows-key bit.
        XCTAssertEqual(wire.packets[1].modifiers, InputProtocol.Modifiers.control.rawValue)
    }

    /// A ⌘ chord whose key-up macOS never delivers must not leave the host
    /// holding the key: Windows auto-repeats a key it never sees released.
    func testAMissingKeyUpIsCoveredWhenCommandComesUp() {
        let wire = Wire()
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.keyDown, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit)
        // No .keyUp for C at all — the case this exists for.
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)

        let releases = wire.packets.filter { !$0.pressed }.map(\.code)
        XCTAssertTrue(releases.contains(0x43), "C was left held down on the host")
        XCTAssertTrue(releases.contains(0xA2))
    }

    /// Holding ⌃ and ⌘ together and letting one go must not tell the host
    /// Control is up — the hand is still on the other one.
    func testLettingGoOfOneOfTwoControlKeysSendsNothing() {
        let wire = Wire()
        wire.send(.flagsChanged, keyCode: leftControl, deviceFlags: controlFlag | leftControlBit)
        wire.send(.flagsChanged, keyCode: leftCommand,
                  deviceFlags: controlFlag | commandFlag | leftControlBit | leftCommandBit)
        XCTAssertEqual(wire.packets.count, 1, "the second key sent a duplicate Control down")

        // ⌘ up, ⌃ still down.
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: controlFlag | leftControlBit)
        XCTAssertEqual(wire.packets.count, 1, "Control was released while it was still held")

        // And now the last one.
        wire.send(.flagsChanged, keyCode: leftControl, deviceFlags: 0)
        XCTAssertEqual(wire.packets.count, 2)
        XCTAssertEqual(wire.packets.last?.code, 0xA2)
        XCTAssertEqual(wire.packets.last?.pressed, false)
    }

    /// A forwarded keystroke is consumed, so it cannot also work a menu or move
    /// focus on this Mac. SolStream's own shortcuts are left alone.
    func testForwardedKeysAreConsumedAndReservedOnesAreNot() {
        let wire = Wire()
        XCTAssertTrue(wire.send(.keyDown, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit),
                      "⌘C was left to act on this Mac as well")
        XCTAssertFalse(wire.send(.keyDown, keyCode: 0x0C, deviceFlags: commandFlag | leftCommandBit),
                       "⌘Q was swallowed, so the application cannot be quit")
        XCTAssertFalse(wire.send(.keyDown, keyCode: 0x0D,
                                 deviceFlags: controlFlag | commandFlag),
                       "⌃⌘W was swallowed, so the window cannot be closed")
    }
}
