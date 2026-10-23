import AppKit
import XCTest
@testable import InputCapture
@testable import MediaSession

/// Checks the keyboard translation: Command carries Windows Control, the
/// Windows key is unreachable, and SolStream's own shortcuts stay on this Mac.
final class KeyboardMappingTests: XCTestCase {
    private func key(_ macKeyCode: UInt16) -> InputCapture.ModifierKey {
        guard let match = InputCapture.modifierKeys.first(where: { $0.macKeyCode == macKeyCode }) else {
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
        for entry in InputCapture.modifierKeys {
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
                       SMTInput.Modifiers.control.rawValue)
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
                // An SMT/1 event: kind, body length, then the body. A key event's
                // body is a big-endian virtual key code, the up/down byte and the
                // modifier bitmask. The sequence number is added by MediaClient,
                // which is the only thing that knows what has been acknowledged --
                // so it is not here.
                let bytes = [UInt8](data)
                guard bytes.count >= 6, bytes[0] == SMTInput.Kind.key.rawValue else { return }
                self?.packets.append((code: UInt16(bytes[2]) << 8 | UInt16(bytes[3]),
                                      pressed: bytes[4] != 0,
                                      modifiers: bytes[5]))
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
        XCTAssertEqual(wire.packets[1].modifiers, SMTInput.Modifiers.control.rawValue)
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

    // MARK: - A key held across a SolStream shortcut

    private let leftCommandAndControl: UInt = 0x0010_0000 | 0x0004_0000 | 0x0000_0008 | 0x0000_0001
    private let wKey: UInt16 = 0x0D  // W, whose ⌃⌘ is SolStream's close-window

    /// Hold W, press ⌃⌘, let go of W first: W's release carries ⌃⌘ and must
    /// still reach the host, or W stays held there.
    func testTheReleaseOfAKeyHeldBeforeAShortcutReachesTheHost() {
        let wire = Wire()
        wire.send(.keyDown, keyCode: wKey, deviceFlags: 0)
        wire.send(.flagsChanged, keyCode: leftControl, deviceFlags: controlFlag | leftControlBit)
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: leftCommandAndControl)
        XCTAssertTrue(wire.send(.keyUp, keyCode: wKey, deviceFlags: leftCommandAndControl),
                      "W's release was handed to AppKit as ⌃⌘W")
        let w = wire.packets.filter { $0.code == 0x57 }
        XCTAssertEqual(w.map(\.pressed), [true, false])
    }

    /// And a repeat of it under ⌃⌘ is the key still being held, not the
    /// shortcut that closes the window.
    func testARepeatOfAHeldKeyIsNotAShortcut() {
        let wire = Wire()
        wire.send(.keyDown, keyCode: wKey, deviceFlags: 0)
        XCTAssertTrue(wire.send(.keyDown, keyCode: wKey, deviceFlags: leftCommandAndControl),
                      "a repeat of W reached the menu as ⌃⌘W")
        // A fresh press under ⌃⌘ is still SolStream's.
        XCTAssertFalse(wire.send(.keyDown, keyCode: 0x03, deviceFlags: leftCommandAndControl))
    }

    /// A key pressed before ⌘ whose release macOS never delivered is let go of
    /// when ⌘ comes up, if this Mac's keyboard says it is up -- and kept if
    /// the hand is still on it.
    func testAKeyLetGoOfUnderCommandIsReleasedWithIt() {
        for stillHeld in [false, true] {
            let wire = Wire()
            var down: Set<UInt16> = []
            wire.capture.isKeyPhysicallyDown = { down.contains($0) }
            down.insert(wKey)
            wire.send(.keyDown, keyCode: wKey, deviceFlags: 0)
            wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
            // W let go of, or not -- and no key-up for it either way.
            if !stillHeld { down.remove(wKey) }
            wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)
            let w = wire.packets.filter { $0.code == 0x57 }
            XCTAssertEqual(w.map(\.pressed), stillHeld ? [true] : [true, false],
                           stillHeld ? "a key still held was released" : "W was left held on the host")
        }
    }

    /// A key pressed during ⌘ and still held when ⌘ comes up stays down on the
    /// host -- crouch on ⌘, walk on W, stand up -- and its own release lets
    /// go of it. One the keyboard says is up is let go of with ⌘, as before.
    func testAChordKeyStillHeldIsKeptWhenCommandComesUp() {
        for stillHeld in [false, true] {
            let wire = Wire()
            var down: Set<UInt16> = [wKey]
            wire.capture.isKeyPhysicallyDown = { down.contains($0) }
            wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
            wire.send(.keyDown, keyCode: wKey, deviceFlags: commandFlag | leftCommandBit)
            if !stillHeld { down.remove(wKey) }
            wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)
            XCTAssertEqual(wire.packets.filter { $0.code == 0x57 }.map(\.pressed),
                           stillHeld ? [true] : [true, false],
                           stillHeld ? "a key still held was released" : "W was left held on the host")
            guard stillHeld else { continue }
            down.remove(wKey)
            wire.send(.keyUp, keyCode: wKey, deviceFlags: 0)
            XCTAssertEqual(wire.packets.filter { $0.code == 0x57 }.map(\.pressed), [true, false])
        }
    }

    /// A keyboard state that never once said a key was down -- a macOS that
    /// keeps it behind a permission -- is not believed when it says one is up.
    func testAKeyboardStateThatNeverAnswersIsNotBelieved() {
        let wire = Wire()
        wire.capture.isKeyPhysicallyDown = { _ in false }
        wire.send(.keyDown, keyCode: wKey, deviceFlags: 0)
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
        wire.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)
        XCTAssertEqual(wire.packets.filter { $0.code == 0x57 }.map(\.pressed), [true],
                       "a key the hand may still be holding was let go of")
    }

    // MARK: - Modifiers put right by the next event

    private let shiftFlag: UInt = 0x0002_0000
    private let leftShiftBit: UInt = 0x0000_0002
    private let rightShiftBit: UInt = 0x0000_0004
    private let optionFlag: UInt = 0x0008_0000
    private let leftOptionBit: UInt = 0x0000_0020

    /// The device bits name the key; the shared flag alone is taken as the
    /// key already known to be down, or the left one; no flag, no key.
    func testWhichModifierKeysAnEventHolds() {
        XCTAssertEqual(InputCapture.heldModifierBits(shiftFlag | rightShiftBit, last: 0), rightShiftBit)
        XCTAssertEqual(InputCapture.heldModifierBits(shiftFlag, last: rightShiftBit), rightShiftBit)
        XCTAssertEqual(InputCapture.heldModifierBits(shiftFlag, last: 0), leftShiftBit)
        XCTAssertEqual(InputCapture.heldModifierBits(0, last: leftShiftBit | leftOptionBit), 0)
        // Nothing but the modifiers' own bits: Caps Lock and the rest are not keys held.
        XCTAssertEqual(InputCapture.heldModifierBits(NSEvent.ModifierFlags.capsLock.rawValue
                                                     | NSEvent.ModifierFlags.function.rawValue,
                                                     last: 0), 0)
        XCTAssertEqual(InputCapture.heldModifierBits(commandFlag | controlFlag
                                                     | leftCommandBit | leftControlBit, last: 0),
                       leftCommandBit | leftControlBit)
    }

    /// Control and Command share Windows Control: the changes say it once.
    func testTheChangesSayEachWindowsKeyOnce() {
        let keys = InputCapture.modifierKeys
        let both = leftCommandBit | leftControlBit
        XCTAssertEqual(InputCapture.modifierChanges(from: 0, to: both, among: keys)
                        .map { [$0.key.windowsKeyCode, $0.pressed ? 1 : 0] }, [[0xA2, 1]])
        XCTAssertTrue(InputCapture.modifierChanges(from: both, to: leftControlBit, among: keys).isEmpty)
        XCTAssertEqual(InputCapture.modifierChanges(from: leftShiftBit, to: leftOptionBit, among: keys)
                        .map { [$0.key.windowsKeyCode, $0.pressed ? 1 : 0] },
                       [[0xA0, 0], [0xA4, 1]], "releases go before presses")
    }

    /// ⌥ let go of while a menu was tracking never reached the monitor. The
    /// next key says ⌥ is up, and the host hears so before the key.
    func testAMissedReleaseIsPutRightByTheNextKey() {
        let wire = Wire()
        wire.send(.flagsChanged, keyCode: 0x3A, deviceFlags: optionFlag | leftOptionBit)
        // No .flagsChanged for ⌥ coming up.
        wire.send(.keyDown, keyCode: 0x00, deviceFlags: 0)
        XCTAssertEqual(wire.packets.map(\.code), [0xA4, 0xA4, 0x41])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, false, true])
    }

    /// ⇧ held as the window took the keyboard sent nothing; the letter typed
    /// with it brings it down first, and its release takes it up again.
    func testAModifierAlreadyHeldIsSentWithTheFirstKey() {
        let wire = Wire()
        wire.send(.keyDown, keyCode: 0x00, deviceFlags: shiftFlag | leftShiftBit)
        XCTAssertEqual(wire.packets.map(\.code), [0xA0, 0x41])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, true])
        wire.send(.flagsChanged, keyCode: 0x38, deviceFlags: 0)
        XCTAssertEqual(wire.packets.last?.code, 0xA0)
        XCTAssertEqual(wire.packets.last?.pressed, false)
    }

    /// Nothing changed, nothing sent: a key typed with the modifiers already
    /// in step goes alone.
    func testModifiersInStepSendNothingExtra() {
        let wire = Wire()
        wire.send(.flagsChanged, keyCode: 0x38, deviceFlags: shiftFlag | leftShiftBit)
        wire.send(.keyDown, keyCode: 0x00, deviceFlags: shiftFlag | leftShiftBit)
        wire.send(.keyUp, keyCode: 0x00, deviceFlags: shiftFlag | leftShiftBit)
        XCTAssertEqual(wire.packets.map(\.code), [0xA0, 0x41, 0x41])
    }

    // MARK: - A session that starts or restarts

    /// ⇧ held across a restart: the new session holds nothing, so ⇧ is
    /// pressed on it again, and its release still follows.
    func testAModifierHeldAcrossARestartIsPressedAgain() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let wire = Wire()
        let shift = NSEvent.ModifierFlags(rawValue: shiftFlag | leftShiftBit)
        wire.capture.modifierFlagsNow = { shift }
        wire.send(.flagsChanged, keyCode: 0x38, deviceFlags: shift.rawValue)
        wire.capture.inputBecameLive()
        XCTAssertEqual(wire.packets.map(\.code), [0xA0, 0xA0])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, true], "⇧ was not pressed on the new session")
        wire.send(.keyDown, keyCode: 0x00, deviceFlags: shift.rawValue)
        wire.send(.flagsChanged, keyCode: 0x38, deviceFlags: 0)
        XCTAssertEqual(wire.packets.map(\.code), [0xA0, 0xA0, 0x41, 0xA0])
        XCTAssertEqual(wire.packets.last?.pressed, false)
    }

    /// What the old session held is forgotten without a word: nothing still
    /// held means nothing sent, release or press -- and so a first start with
    /// nothing held sends nothing at all.
    func testAStartSendsNoStrayReleases() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let first = Wire()
        first.capture.modifierFlagsNow = { [] }
        first.capture.inputBecameLive()
        XCTAssertTrue(first.packets.isEmpty)

        let restarted = Wire()
        restarted.capture.modifierFlagsNow = { [] }
        restarted.send(.flagsChanged, keyCode: leftCommand, deviceFlags: commandFlag | leftCommandBit)
        restarted.send(.keyDown, keyCode: wKey, deviceFlags: commandFlag | leftCommandBit)
        let before = restarted.packets.count
        restarted.capture.inputBecameLive()
        XCTAssertEqual(restarted.packets.count, before, "the restart sent what the host no longer holds")
        // ⌘ coming up now has nothing of the old session's to let go of.
        restarted.send(.flagsChanged, keyCode: leftCommand, deviceFlags: 0)
        XCTAssertEqual(restarted.packets.count, before)
    }

    // MARK: - Caps Lock, to a host that predates scan codes

    /// Caps Lock is a toggle on Windows, so each change on the Mac is one
    /// press and release of VK_CAPITAL — and a repeat of the same state is
    /// nothing at all.
    func testCapsLockTogglesTheHost() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let wire = Wire()
        let capsFlag = NSEvent.ModifierFlags.capsLock.rawValue

        wire.send(.flagsChanged, keyCode: InputCapture.capsLockKeyCode, deviceFlags: capsFlag)
        XCTAssertEqual(wire.packets.map(\.code), [0x14, 0x14])
        XCTAssertEqual(wire.packets.map(\.pressed), [true, false])

        wire.send(.flagsChanged, keyCode: InputCapture.capsLockKeyCode, deviceFlags: capsFlag)
        XCTAssertEqual(wire.packets.count, 2, "the same state toggled the host again")

        wire.send(.flagsChanged, keyCode: InputCapture.capsLockKeyCode, deviceFlags: 0)
        XCTAssertEqual(wire.packets.map(\.code), [0x14, 0x14, 0x14, 0x14])
        XCTAssertEqual(InputCapture.hostCapsLock[""], false)
    }

    /// Switched while another application had the keyboard: the next window to
    /// take capture brings the host into line.
    func testCapsLockSyncsWhenCaptureStarts() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let capture = InputCapture()
        var codes: [UInt16] = []
        capture.onInput = { data in
            let bytes = [UInt8](data)
            if bytes.count >= 6, bytes[0] == SMTInput.Kind.key.rawValue {
                codes.append(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
            }
        }
        capture.syncCapsLock(to: true)
        XCTAssertEqual(codes, [0x14, 0x14])
        XCTAssertEqual(InputCapture.hostCapsLock[""], true)
        capture.syncCapsLock(to: true)
        XCTAssertEqual(codes.count, 2)
    }

    /// The window takes the keyboard as it is shown, before the session runs,
    /// and a press sent then goes nowhere. It must not be counted as having
    /// reached the PC -- that was the inversion: the Mac sure the PC had Caps
    /// Lock on, the PC typing lower case, and every press after flipping both.
    func testAPressThatWentNowhereIsNotCounted() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let capture = InputCapture()
        var live = false
        var codes: [UInt16] = []
        capture.acceptsInput = { live }
        capture.onInput = { data in
            guard live else { return }  // as MediaClient drops it
            let bytes = [UInt8](data)
            if bytes.count >= 6 { codes.append(UInt16(bytes[2]) << 8 | UInt16(bytes[3])) }
        }
        capture.syncCapsLock(to: true)
        XCTAssertNil(InputCapture.hostCapsLock[""], "a dropped press was counted")

        // The session starts; the same state is now sent, and counted.
        live = true
        capture.syncCapsLock(to: true)
        XCTAssertEqual(codes, [0x14, 0x14])
        XCTAssertEqual(InputCapture.hostCapsLock[""], true)
    }

    /// Each PC has a Caps Lock of its own, so what one was told says nothing
    /// about another.
    func testEachHostIsKeptApart() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        var sent = 0
        let first = InputCapture()
        first.hostName = "pc-one.example"
        first.onInput = { _ in sent += 1 }
        first.syncCapsLock(to: true)
        XCTAssertEqual(sent, 2)

        let second = InputCapture()
        second.hostName = "pc-two.example"
        second.onInput = { _ in sent += 1 }
        second.syncCapsLock(to: true)
        XCTAssertEqual(sent, 4, "the second PC was taken to have Caps Lock on already")
        XCTAssertEqual(InputCapture.hostCapsLock["pc-one.example"], true)
        XCTAssertEqual(InputCapture.hostCapsLock["pc-two.example"], true)
    }

    // MARK: - Caps Lock, to a host that takes scan codes

    /// Scan-code events, read back off the wire with their modifiers.
    private func scanPackets(_ capture: InputCapture) -> () -> [(code: UInt16, pressed: Bool, modifiers: UInt8)] {
        var packets: [(code: UInt16, pressed: Bool, modifiers: UInt8)] = []
        capture.onInput = { data in
            let bytes = [UInt8](data)
            guard bytes.count >= 6, bytes[0] == SMTInput.Kind.keyScan.rawValue else { return }
            packets.append((UInt16(bytes[2]) << 8 | UInt16(bytes[3]), bytes[4] != 0, bytes[5]))
        }
        return { packets }
    }

    /// Such a host is told the STATE, not asked for a press, and every time:
    /// it presses its own Caps Lock only if it differs, so a repeat costs
    /// nothing and nothing here has to guess.
    func testAScanCodeHostIsToldTheState() {
        InputCapture.hostCapsLock = [:]
        defer { InputCapture.hostCapsLock = [:] }
        let capture = InputCapture()
        capture.sendsScanCodes = true
        let packets = scanPackets(capture)
        capture.syncCapsLock(to: true)
        capture.syncCapsLock(to: true)
        capture.syncCapsLock(to: false)
        XCTAssertEqual(packets().map(\.code), Array(repeating: InputCapture.scanCapsLock, count: 6))
        XCTAssertEqual(packets().map(\.pressed), [true, false, true, false, true, false])
        let caps = SMTInput.Modifiers.capsLock.rawValue
        XCTAssertEqual(packets().map(\.modifiers), [caps, caps, caps, caps, 0, 0])
        XCTAssertTrue(InputCapture.hostCapsLock.isEmpty, "a guess was kept for a host that needs none")
    }

    /// And every key carries it, which is what puts a lost one right.
    func testEveryKeyCarriesTheCapsLockState() {
        let capture = InputCapture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSView(frame: window.contentLayoutRect)
        window.contentView = view
        capture.attach(to: view)
        capture.sendsScanCodes = true
        capture.enableCapture()
        defer { capture.disableCapture() }
        let packets = scanPackets(capture)
        for (flags, caps) in [(NSEvent.ModifierFlags.capsLock.rawValue, true), (UInt(0), false)] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x00)!
            capture.handleKeyEvent(event)
            XCTAssertEqual(packets().last?.code, 0x1E)
            XCTAssertEqual((packets().last?.modifiers ?? 0) & SMTInput.Modifiers.capsLock.rawValue != 0,
                           caps)
        }
    }

    func testTheCapsLockBitIsClearOfTheOthers() {
        XCTAssertEqual(SMTInput.Modifiers.capsLock.rawValue, 0x10)
        XCTAssertTrue(InputCapture.modifiers(from: [.capsLock]).contains(.capsLock))
        XCTAssertEqual(InputCapture.modifiers(from: [.capsLock, .shift]).rawValue, 0x11)
    }
}
