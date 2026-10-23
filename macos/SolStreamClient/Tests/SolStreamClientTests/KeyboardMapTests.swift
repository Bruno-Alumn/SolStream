import AppKit
import XCTest
@testable import AgentChannel
@testable import InputCapture
@testable import MediaSession

/// Keys by position: which PC key each Mac key is, and how a host that takes
/// scan codes -- and one that does not -- is told it.
final class KeyboardMapTests: XCTestCase {
    private func scan(_ mac: UInt16, iso: Bool = false) -> UInt16? {
        KeyboardMap.scanCode(forMacKey: mac, isISO: iso)
    }

    private func vk(_ mac: UInt16, iso: Bool = false) -> UInt16? {
        KeyboardMap.windowsKey(forMacKey: mac, isISO: iso)
    }

    // MARK: - Positions

    /// The keys a German or French user types on land on the PC key at the
    /// same place, so the PC's own layout gives them their letters. The key
    /// marked Z on a German keyboard is kVK_ANSI_Y, and must arrive as the
    /// PC's key at that place -- 0x15 -- not as VK_Y.
    func testLettersGoByPlace() {
        XCTAssertEqual(scan(0x10), 0x15)  // kVK_ANSI_Y: German Z
        XCTAssertEqual(scan(0x06), 0x2C)  // kVK_ANSI_Z: German Y
        XCTAssertEqual(scan(0x0C), 0x10)  // kVK_ANSI_Q: French A
        XCTAssertEqual(scan(0x00), 0x1E)  // kVK_ANSI_A: French Q
        XCTAssertEqual(scan(0x0D), 0x11)  // kVK_ANSI_W: French Z, and forward in ZQSD
        XCTAssertEqual(scan(0x29), 0x27)  // kVK_ANSI_Semicolon: German Ö
        XCTAssertEqual(scan(0x21), 0x1A)  // kVK_ANSI_LeftBracket: German Ü
        XCTAssertEqual(scan(0x27), 0x28)  // kVK_ANSI_Quote: UK's ' and German Ä
    }

    /// The keys that are extended on a PC keyboard carry 0xE0.
    func testExtendedKeysCarryTheirPrefix() {
        XCTAssertEqual(scan(0x7B), 0xE04B)  // ←
        XCTAssertEqual(scan(0x7E), 0xE048)  // ↑
        XCTAssertEqual(scan(0x73), 0xE047)  // Home
        XCTAssertEqual(scan(0x75), 0xE053)  // forward delete
        XCTAssertEqual(scan(0x4C), 0xE01C)  // the keypad's Enter
        XCTAssertEqual(scan(0x4B), 0xE035)  // the keypad's /
        // Return and the keypad's Enter stay apart.
        XCTAssertEqual(scan(0x24), 0x1C)
    }

    /// macOS swaps two key codes on an ISO keyboard: the key left of 1 says
    /// kVK_ISO_Section and the one beside the left shift says kVK_ANSI_Grave.
    func testTheISOKeyboardsTwoKeysSwap() {
        XCTAssertEqual(scan(KeyboardMap.isoSection, iso: true), 0x29)  // left of 1
        XCTAssertEqual(scan(KeyboardMap.grave, iso: true), 0x56)       // beside the shift
        XCTAssertEqual(vk(KeyboardMap.isoSection, iso: true), 0xC0)
        XCTAssertEqual(vk(KeyboardMap.grave, iso: true), 0xE2)        // VK_OEM_102
    }

    /// A US keyboard's grave key is left of 1; a PC ISO keyboard that macOS
    /// takes for ANSI reports its extra key as kVK_ISO_Section.
    func testOnAnANSIKeyboardTheyDoNot() {
        XCTAssertEqual(scan(KeyboardMap.grave), 0x29)
        XCTAssertEqual(scan(KeyboardMap.isoSection), 0x56)
        XCTAssertEqual(vk(KeyboardMap.grave), 0xC0)
        XCTAssertEqual(vk(KeyboardMap.isoSection), 0xE2)
    }

    /// The keys that used to be dropped with a beep: the keypad, Help (a PC
    /// keyboard's Insert), F13 to F20, Menu and the JIS keys.
    func testTheKeysThatUsedToBeDroppedReachTheHost() {
        let keypadDigits: [UInt16: (scan: UInt16, vk: UInt16)] = [
            0x52: (0x52, 0x60), 0x53: (0x4F, 0x61), 0x54: (0x50, 0x62), 0x55: (0x51, 0x63),
            0x56: (0x4B, 0x64), 0x57: (0x4C, 0x65), 0x58: (0x4D, 0x66), 0x59: (0x47, 0x67),
            0x5B: (0x48, 0x68), 0x5C: (0x49, 0x69),
        ]
        for (mac, want) in keypadDigits {
            XCTAssertEqual(scan(mac), want.scan, "keypad key 0x\(String(mac, radix: 16))")
            XCTAssertEqual(vk(mac), want.vk, "keypad key 0x\(String(mac, radix: 16))")
        }
        XCTAssertEqual(scan(0x41), 0x53)  // .
        XCTAssertEqual(scan(0x43), 0x37)  // *
        XCTAssertEqual(scan(0x45), 0x4E)  // +
        XCTAssertEqual(scan(0x4E), 0x4A)  // -
        XCTAssertEqual(scan(0x51), 0x59)  // =
        XCTAssertEqual(scan(0x47), 0x45)  // Clear, where a PC keyboard has Num Lock

        XCTAssertEqual(scan(0x72), 0xE052)  // Help → Insert
        XCTAssertEqual(vk(0x72), 0x2D)
        XCTAssertEqual(scan(0x6E), 0xE05D)  // Menu
        XCTAssertEqual(vk(0x6E), 0x5D)

        let f13to20: [UInt16] = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]
        XCTAssertEqual(f13to20.compactMap { scan($0) },
                       [0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x6B])
        XCTAssertEqual(f13to20.compactMap { vk($0) }, Array(0x7C...0x83))

        XCTAssertEqual(scan(0x5D), 0x7D)  // ¥
        XCTAssertEqual(scan(0x5E), 0x73)  // _
        XCTAssertEqual(scan(0x5F), 0x7E)  // the keypad's comma
        XCTAssertEqual(vk(0x5F), 0xBC)    // as the main keyboard's, which types a comma
        XCTAssertEqual(scan(0x66), 0xF1)  // Eisu
        XCTAssertEqual(scan(0x68), 0xF2)  // Kana
        XCTAssertEqual(vk(0x66), 0x1A)    // VK_IME_OFF
        XCTAssertEqual(vk(0x68), 0x16)    // VK_IME_ON
    }

    /// Every key reaches a host of either kind: the two tables cover the same
    /// keys, on either kind of keyboard.
    func testBothTablesCoverTheSameKeys() {
        for mac in KeyboardMap.mappedMacKeys {
            for iso in [false, true] {
                XCTAssertNotNil(InputCapture.hostKey(forMacKey: mac, isISO: iso),
                                "mac key 0x\(String(mac, radix: 16)) is in only one table")
            }
        }
    }

    /// Two Mac keys on the same PC key would make one of them unreachable by
    /// position and leave a held key released by the other.
    func testNoTwoKeysShareAPlace() {
        for iso in [false, true] {
            var seen: [UInt16: UInt16] = [:]
            for mac in KeyboardMap.mappedMacKeys {
                guard let code = scan(mac, iso: iso) else { continue }
                if let other = seen[code] {
                    XCTFail("0x\(String(mac, radix: 16)) and 0x\(String(other, radix: 16))"
                            + " are both 0x\(String(code, radix: 16))")
                }
                seen[code] = mac
            }
        }
    }

    /// The Windows key raises Windows' own shell over the streamed
    /// application. Nothing may reach it, by name or by place.
    func testNothingReachesTheWindowsKey() {
        for mac in KeyboardMap.mappedMacKeys {
            for iso in [false, true] {
                XCTAssertFalse([0xE05B, 0xE05C].contains(scan(mac, iso: iso)))
                XCTAssertFalse([0x5B, 0x5C].contains(vk(mac, iso: iso)))
            }
        }
        for key in InputCapture.modifierKeys {
            XCTAssertFalse([0xE05B, 0xE05C].contains(key.scanCode))
        }
    }

    /// Command is Control by position too, side for side.
    func testCommandIsControlByPlace() {
        let byMac = Dictionary(uniqueKeysWithValues: InputCapture.modifierKeys.map { ($0.macKeyCode, $0) })
        XCTAssertEqual(byMac[0x37]?.scanCode, 0x1D)    // left ⌘
        XCTAssertEqual(byMac[0x36]?.scanCode, 0xE01D)  // right ⌘
        XCTAssertEqual(byMac[0x3B]?.scanCode, 0x1D)    // left ⌃
        XCTAssertEqual(byMac[0x3D]?.scanCode, 0xE038)  // right ⌥, AltGr on a European PC
    }

    // MARK: - The wire

    func testAScanKeyIsItsOwnKind() {
        XCTAssertEqual([UInt8](SMTInput.scanKey(code: 0xE04B, pressed: true, modifiers: [.shift])),
                       [SMTInput.Kind.keyScan.rawValue, 4, 0xE0, 0x4B, 1, 0x01])
        XCTAssertEqual(SMTInput.Kind.keyScan.rawValue, 8)
    }

    /// A host says it takes scan codes in its `media open` reply. One that
    /// predates them says nothing, and is sent virtual keys.
    func testOnlyAHostThatSaysSoIsSentScanCodes() {
        let old: [String: Any] = ["type": "media", "ok": true, "ver": 1, "hpub": "04",
                                  "hnonce": "00", "hcount": "41", "hauth": "00",
                                  "streaming": true, "hport": 47631]
        XCTAssertFalse(AgentConnection.takesScanCodes(inReply: old))
        var new = old
        new["scancodes"] = 1
        XCTAssertTrue(AgentConnection.takesScanCodes(inReply: new))
        new["scancodes"] = 2
        XCTAssertTrue(AgentConnection.takesScanCodes(inReply: new))
        new["scancodes"] = 0
        XCTAssertFalse(AgentConnection.takesScanCodes(inReply: new))
        new["scancodes"] = "yes"
        XCTAssertFalse(AgentConnection.takesScanCodes(inReply: new))
        // As JSONSerialization hands it over.
        let parsed = try? JSONSerialization.jsonObject(
            with: Data(#"{"type":"media","ok":true,"scancodes":1,"hport":47631}"#.utf8))
        XCTAssertTrue(AgentConnection.takesScanCodes(inReply: parsed as? [String: Any] ?? [:]))
    }

    /// Real `NSEvent`s through the capture, read back off the wire.
    private final class Wire {
        let capture = InputCapture()
        private let window: NSWindow
        private(set) var packets: [(kind: UInt8, code: UInt16, pressed: Bool)] = []

        init(scanCodes: Bool, iso: Bool = false) {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
            let view = NSView(frame: window.contentLayoutRect)
            window.contentView = view
            capture.attach(to: view)
            capture.sendsScanCodes = scanCodes
            capture.keyboardIsISO = { _ in iso }
            capture.enableCapture()
            capture.onInput = { [weak self] data in
                let bytes = [UInt8](data)
                guard bytes.count >= 6,
                      bytes[0] == SMTInput.Kind.key.rawValue
                        || bytes[0] == SMTInput.Kind.keyScan.rawValue else { return }
                self?.packets.append((kind: bytes[0],
                                      code: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                                      pressed: bytes[4] != 0))
            }
        }

        func send(_ type: NSEvent.EventType, keyCode: UInt16, deviceFlags: UInt = 0) {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: deviceFlags),
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: keyCode) else {
                return XCTFail("could not build a \(type) event")
            }
            capture.handleKeyEvent(event)
        }
    }

    private let commandFlag: UInt = 0x0010_0000
    private let leftCommandBit: UInt = 0x0000_0008

    /// ⌘C to a host that takes scan codes: Control and C by place.
    func testCommandCByPlace() {
        let wire = Wire(scanCodes: true)
        wire.send(.flagsChanged, keyCode: 0x37, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.keyDown, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.keyUp, keyCode: 0x08, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.flagsChanged, keyCode: 0x37)
        XCTAssertEqual(wire.packets.map(\.kind), Array(repeating: SMTInput.Kind.keyScan.rawValue,
                                                       count: 4))
        XCTAssertEqual(wire.packets.map(\.code), [0x1D, 0x2E, 0x2E, 0x1D])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, true, false, false])
    }

    /// The same keystroke to a host that predates scan codes goes as it always
    /// did, by virtual key.
    func testAnOlderHostStillGetsVirtualKeys() {
        let wire = Wire(scanCodes: false)
        wire.send(.keyDown, keyCode: 0x10)
        wire.send(.keyUp, keyCode: 0x10)
        XCTAssertEqual(wire.packets.map(\.kind), [SMTInput.Kind.key.rawValue,
                                                  SMTInput.Kind.key.rawValue])
        XCTAssertEqual(wire.packets.map(\.code), [0x59, 0x59])  // VK_Y
    }

    /// The ISO keyboard's key beside the left shift reaches the PC's key there.
    func testTheISOKeyByPlace() {
        let wire = Wire(scanCodes: true, iso: true)
        wire.send(.keyDown, keyCode: KeyboardMap.grave)
        wire.send(.keyUp, keyCode: KeyboardMap.grave)
        XCTAssertEqual(wire.packets.map(\.code), [0x56, 0x56])
    }

    /// A key held as the window loses the keyboard is released the way the
    /// host was told it.
    func testAHeldKeyIsReleasedByPlace() {
        let wire = Wire(scanCodes: true)
        wire.send(.keyDown, keyCode: 0x7B)  // ←
        wire.capture.disableCapture()
        XCTAssertEqual(wire.packets.map(\.code), [0xE04B, 0xE04B])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, false])
    }
}
