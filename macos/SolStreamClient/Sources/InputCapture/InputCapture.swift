import AppKit
import Carbon
import MediaSession
import SolStreamLogging

/// Turns local macOS keyboard and mouse events into SMT/1 input events.
///
/// Uses ONLY local NSView monitoring (`addLocalMonitorForEvents`), never a
/// CGEventTap, which means no Accessibility permission is required and events
/// are captured only while our window is key — local interaction can never leak
/// to the remote host while you are using another app.
public final class InputCapture {
    /// Receives ready-to-send packets built by `InputProtocol`.
    public var onInput: ((Data) -> Void)?

    /// The region of the streamed canvas this view displays, in canvas pixels,
    /// and the canvas's full size. Pointer positions must be sent in canvas
    /// coordinates.
    ///
    /// The contract changed with the transport and this comment did not, which
    /// for a coordinate contract is the worst kind of stale: it said the host
    /// rescales from a reference rectangle the packet declares. SMT/1 carries no
    /// reference rectangle. `kInputMouseAbs` is two 16-bit values normalised
    /// 0..65535 across the host's TARGET — the streamed window's DWM frame bounds
    /// for a window capture, the monitor rectangle for a display capture — and
    /// `InputInjector::ScreenPoint` is the only thing that turns those into
    /// pixels. So this side owes it a fraction of the canvas, and the crop is
    /// this side's business alone.
    public var sourceRect: CGRect?
    public var canvasSize: CGSize?

    /// How far inside the crop to keep the host pointer, in canvas pixels.
    ///
    /// The outer band of a window is its resize grab area, and a drag starting
    /// there begins a resize on the host — which is not something the user
    /// should be able to do from inside the picture, since the macOS window
    /// frame is what owns the size. Positions are pinned to the inside of this
    /// band rather than dropped, so the pointer still tracks right up to the
    /// edge of the usable area; it simply never lands on the border itself, and
    /// so never turns into a resize arrow or starts a drag there.
    public var edgeGuard: CGFloat = 0

    private weak var targetView: NSView?
    private var keyboardMonitor: Any?
    private var mouseMonitor: Any?
    private var isCapturing = false

    // MARK: Pointer mode

    /// How the mouse reaches the host.
    ///
    /// Desktop sends where the pointer IS: an absolute position inside the
    /// picture, so the host cursor lands exactly under the Mac's -- right for
    /// every ordinary application. Games want the opposite. A first-person game
    /// reads raw motion and recentres its own cursor, so absolute positions
    /// either do nothing or snap the view about, and the Mac's cursor leaving
    /// the window stops the turn dead. Gaming captures the mouse on a click
    /// inside the picture -- hidden, held still, only movement sent -- until
    /// ⌃⌥ releases it, or the window stops being the key one. With
    /// `followsHostCursor` it also follows the game: see `CapturePolicy`.
    public enum PointerMode: String, CaseIterable {
        case desktop, gaming
    }

    public static let pointerModeChanged = Notification.Name("SolStream.pointerModeChanged")
    private static let pointerModeKey = "SolStream.pointerMode"

    /// One mode for every streamed window, remembered across launches.
    public static var pointerMode: PointerMode {
        get {
            UserDefaults.standard.string(forKey: pointerModeKey)
                .flatMap(PointerMode.init(rawValue:)) ?? .desktop
        }
        set {
            guard newValue != pointerMode else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: pointerModeKey)
            Log.info("[input] pointer mode: \(newValue.rawValue)")
            NotificationCenter.default.post(name: pointerModeChanged, object: nil)
        }
    }

    private static let sensitivityKey = "SolStream.gamingSensitivity"
    private static let followsCursorKey = "SolStream.followsHostCursor"

    /// Multiplier on relative motion while the mouse is captured for a game,
    /// remembered across launches. 1 is the Mac's own feel.
    public static var gamingSensitivity: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: sensitivityKey) as? Double ?? 1
            return min(max(stored, 0.25), 4)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.25), 4), forKey: sensitivityKey)
            NotificationCenter.default.post(name: pointerModeChanged, object: nil)
        }
    }

    /// In gaming mode, capture the mouse while the PC hides its cursor and give
    /// it back the moment the PC shows one -- a game's pause menu -- rather than
    /// only on a click and on ⌃⌥. On by default; a host too old to report its
    /// cursor's visibility simply never triggers it.
    public static var followsHostCursor: Bool {
        get { UserDefaults.standard.object(forKey: followsCursorKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: followsCursorKey)
            NotificationCenter.default.post(name: pointerModeChanged, object: nil)
        }
    }

    /// The mouse is captured for a game: cursor hidden and decoupled.
    public private(set) var isPointerCaptured = false
    /// Sub-pixel motion carried between events, so slow movement is not lost
    /// to rounding.
    private var relativeResidual = CGPoint.zero
    /// `gamingSensitivity`, read when the mouse is taken and when it changes
    /// rather than from the defaults on every move of a 1000 Hz mouse.
    private var sensitivity = CGFloat(InputCapture.gamingSensitivity)
    /// `pointerMode` and `followsHostCursor`, read when capture starts and
    /// when they change, for the same reason.
    private var mode = InputCapture.pointerMode
    private var followsCursor = InputCapture.followsHostCursor
    /// Runs on the main thread, and so before the post that changed a
    /// setting returns: nothing reads the copies above stale.
    private var modeObserver: NSObjectProtocol?
    private var policy = CapturePolicy()

    /// Whether the host reports its cursor going away and coming back, so
    /// gaming mode can follow it. Set by the owner when the host says so on a
    /// push of its own; otherwise learned from watching it do both.
    public var hostReportsCursorVisibility: Bool {
        get { policy.hostReportsVisibility }
        set { policy.hostReportsVisibility = newValue }
    }

    /// Told when the mouse is taken (true) and given back (false), so the
    /// window can say how to get it back.
    public var onPointerCaptureChanged: ((Bool) -> Void)?

    /// What capturing does to the real cursor: decouples it from the mouse,
    /// so it stays put while the mouse still reports motion, and hides it, so
    /// it is not a stray arrow over the game -- or undoes both. Replaceable so
    /// the tests can take the mouse without taking it from whoever runs them.
    var lockSystemPointer: (Bool) -> Void = { locked in
        CGAssociateMouseAndMouseCursorPosition(locked ? 0 : 1)
        if locked { NSCursor.hide() } else { NSCursor.unhide() }
    }

    /// Where a test says the pointer is, as a unit point in the picture, or
    /// nil for not over it. Unset, the window server is asked.
    var pointerStandIn: (() -> CGPoint?)?

    /// The modifier keys the host was last brought to, as device bits, so
    /// transitions can be turned into individual key down/up events; see
    /// `heldModifierBits`.
    private var lastDeviceFlags: UInt = 0

    /// The host takes keys by position, as scan codes, and so is sent them
    /// that way: the PC's own layout then decides what a key types. Set by the
    /// owner from the session's answer. A host that predates it is sent the
    /// Windows virtual key at the key's place on a US keyboard, which is all it
    /// takes. See `KeyboardMap`.
    public var sendsScanCodes = false

    /// Whether a key event came from an ISO keyboard, which decides two keys'
    /// places. Replaceable so the tests do not depend on the keyboard of the
    /// Mac that runs them.
    var keyboardIsISO: (NSEvent) -> Bool = InputCapture.isISOKeyboard

    /// One key, named both ways a host can be told it.
    struct HostKey: Hashable {
        let windowsKey: UInt16
        let scanCode: UInt16
    }

    /// The host key for a macOS key code, or nil for one with no PC key.
    static func hostKey(forMacKey code: UInt16, isISO: Bool) -> HostKey? {
        KeyboardMap.hostKey(forMacKey: code, isISO: isISO)
    }

    /// The kind of keyboard an event was typed on. The event says, for the
    /// keyboard that sent it, and a Mac can have an ANSI one built in and an
    /// ISO one plugged in; the last keyboard used stands in when it does not.
    static func isISOKeyboard(_ event: NSEvent) -> Bool {
        KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType(of: event)))
            == PhysicalKeyboardLayoutType(kKeyboardISO)
    }

    /// The keyboard type an event names, or the last keyboard used's when it
    /// names none.
    private static func keyboardType(of event: NSEvent?) -> Int64 {
        if let fromEvent = event?.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType),
           fromEvent > 0 {
            return fromEvent
        }
        return Int64(LMGetKbdType())
    }

    /// The packet for one key, in whichever form the host takes.
    func keyPacket(_ key: HostKey, pressed: Bool, modifiers: SMTInput.Modifiers) -> Data {
        sendsScanCodes
            ? SMTInput.scanKey(code: key.scanCode, pressed: pressed, modifiers: modifiers)
            : SMTInput.key(code: key.windowsKey, pressed: pressed, modifiers: modifiers)
    }

    /// Key codes already reported by `noteUnmapped`, so a held key says it once.
    private var reportedUnmappedKeys: Set<UInt16> = []

    /// Modifier keys need their own left/right virtual key codes, and each one
    /// maps to the flag whose transition announces it.
    struct ModifierKey {
        let macKeyCode: UInt16
        let windowsKeyCode: UInt16
        /// The same key by position, for a host that takes scan codes.
        let scanCode: UInt16
        /// The DEVICE-DEPENDENT mask for this specific physical key. The public
        /// flags (.shift, .control…) are shared by the left and right keys, so
        /// releasing one while the other is held reads as "still down" and
        /// would emit a key DOWN — leaving that key stuck on the host forever.
        let deviceMask: UInt

        var hostKey: HostKey { HostKey(windowsKey: windowsKeyCode, scanCode: scanCode) }
    }

    /// Command carries Windows Control, and nothing carries the Windows key.
    ///
    /// ⌘C and Ctrl+C are the same gesture on the two systems, so mapping ⌘ to the
    /// Windows key — which is what a literal position-for-position mapping gives
    /// — means every shortcut a Mac user knows does nothing, and the ones that do
    /// fire are the Start menu and the window-snapping overlay. Mapping it to
    /// Control instead makes copy, paste, undo, save, find and select-all
    /// universal, which is the whole point of the window looking native.
    ///
    /// The Windows key is then unreachable on purpose: there is no key left to
    /// put it on, and it is the one key whose whole job is to raise Windows' own
    /// shell over the top of the application being streamed.
    ///
    /// Mac Control keeps mapping to Windows Control too, so muscle memory from
    /// either side works. That makes two physical keys share one Windows key,
    /// which `modifierChanges` exists to handle.
    ///
    /// Left then right, family by family in `modifierFamilies`' order.
    static let modifierKeys: [ModifierKey] = [
        ModifierKey(macKeyCode: 0x38, windowsKeyCode: 0xA0, scanCode: 0x2A,
                    deviceMask: 0x0000_0002),  // L shift
        ModifierKey(macKeyCode: 0x3C, windowsKeyCode: 0xA1, scanCode: 0x36,
                    deviceMask: 0x0000_0004),  // R shift
        ModifierKey(macKeyCode: 0x3B, windowsKeyCode: 0xA2, scanCode: 0x1D,
                    deviceMask: 0x0000_0001),  // L ctrl
        ModifierKey(macKeyCode: 0x3E, windowsKeyCode: 0xA3, scanCode: 0xE01D,
                    deviceMask: 0x0000_2000),  // R ctrl
        ModifierKey(macKeyCode: 0x3A, windowsKeyCode: 0xA4, scanCode: 0x38,
                    deviceMask: 0x0000_0020),  // L alt
        ModifierKey(macKeyCode: 0x3D, windowsKeyCode: 0xA5, scanCode: 0xE038,
                    deviceMask: 0x0000_0040),  // R alt
        ModifierKey(macKeyCode: 0x37, windowsKeyCode: 0xA2, scanCode: 0x1D,
                    deviceMask: 0x0000_0008),  // L cmd → L ctrl
        ModifierKey(macKeyCode: 0x36, windowsKeyCode: 0xA3, scanCode: 0xE01D,
                    deviceMask: 0x0000_0010),  // R cmd → R ctrl
    ]

    /// Each modifier's shared flag, and the device bits of its left and
    /// right keys.
    private static let modifierFamilies: [(flag: UInt, left: UInt, right: UInt)] =
        zip([NSEvent.ModifierFlags.shift, .control, .option, .command],
            stride(from: 0, to: modifierKeys.count, by: 2)).map { flag, left in
            (flag.rawValue, modifierKeys[left].deviceMask, modifierKeys[left + 1].deviceMask)
        }

    /// The device bits of the two ⌘ keys.
    private static let commandBits = modifierFamilies[3].left | modifierFamilies[3].right

    /// Which modifier keys an event's flags say are down, as device bits.
    ///
    /// The device bits name the key, left or right; the shared flag only says
    /// one of the two is down. An event that sets the flag without a device
    /// bit for it -- one made by software rather than by a keyboard -- is
    /// taken to hold whichever of the two was already known to be down, or
    /// else the left one. Without the flag, neither is down.
    static func heldModifierBits(_ flags: UInt, last: UInt) -> UInt {
        var held: UInt = 0
        for family in modifierFamilies where flags & family.flag != 0 {
            let both = family.left | family.right
            if flags & both != 0 {
                held |= flags & both
            } else if last & both != 0 {
                held |= last & both
            } else {
                held |= family.left
            }
        }
        return held
    }

    /// The modifier key events that take the host from `old` to `new`, both
    /// device bits from `heldModifierBits`: releases first, then presses, and
    /// each Windows key once.
    ///
    /// Control and Command both become Windows Control, so letting go of one
    /// while the other is held sends nothing. A key-up there would release a
    /// key the user is still pressing: the host drops out of Control
    /// mid-chord, and the next letter gets typed into the document instead of
    /// running the shortcut. The symmetric case matters less but is skipped
    /// for the same reason -- a second key-down for a key already down is
    /// noise.
    static func modifierChanges(from old: UInt, to new: UInt,
                                among keys: [ModifierKey]) -> [(key: ModifierKey, pressed: Bool)] {
        func held(_ bits: UInt) -> [UInt16: ModifierKey] {
            var result: [UInt16: ModifierKey] = [:]
            for key in keys where bits & key.deviceMask != 0 && result[key.windowsKeyCode] == nil {
                result[key.windowsKeyCode] = key
            }
            return result
        }
        let before = held(old), after = held(new)
        let ups = before.keys.sorted().filter { after[$0] == nil }.map { (before[$0]!, false) }
        let downs = after.keys.sorted().filter { before[$0] == nil }.map { (after[$0]!, true) }
        return ups + downs
    }

    /// Combinations that belong to SolStream rather than to the streamed
    /// application, and so are neither sent to the host nor swallowed here.
    ///
    /// Everything else carrying ⌘ goes to Windows and is *not* also acted on
    /// locally — otherwise ⌘F would toggle full screen on this Mac at the same
    /// moment it opened Find on the host. The reserved set is small and stated
    /// as a rule rather than a list of key codes: ⌘Q, because macOS reserves it
    /// and a user who wants out of the application should always get out, and
    /// anything with ⌃⌘, which is SolStream's own prefix. Control and Command
    /// both being Windows Control means ⌃⌘ costs the host nothing: it collapses
    /// to a Control the application never sees a letter for.
    static func isReserved(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.contains(.command) else { return false }
        if flags.contains(.control) { return true }
        // ⌘Q, and only on its own — ⇧⌘Q and ⌥⌘Q mean nothing here and belong to
        // whatever is being streamed.
        return keyCode == 0x0C && !flags.contains(.shift) && !flags.contains(.option)
    }

    /// Counters that separate "AppKit never delivered the event" from
    /// "delivered but rejected", which are otherwise indistinguishable.
    public private(set) var mouseMovedSeen = 0
    public private(set) var positionsSent = 0
    /// Pointer events that landed outside the picture — the title bar, the
    /// letterbox, or anywhere else the key window hears about — and so were
    /// not sent. Without it "moved but nothing sent" reads as a fault.
    public private(set) var positionsOutside = 0
    /// Pointer events not sent because a game was reading raw motion and the
    /// mouse was not captured -- see `handleUncapturedOverGame`.
    public private(set) var withheldFromGame = 0

    /// What a scroll left over after rounding to whole Windows units, per
    /// axis. A trackpad reports fractions of a point, and rounding each event
    /// on its own threw slow scrolls away entirely.
    private var scrollResidual = CGPoint.zero

    /// Non-modifier keys currently held, so they can be released on focus loss.
    /// The host hands key-down straight to SendInput, and Windows auto-repeats a
    /// key it never sees released — so a missed key-up repeats forever. The host
    /// releases everything it is holding when a session ends, which covers the
    /// session going away; this covers the window merely losing focus, which it
    /// does not.
    ///
    /// By macOS key code, as the host was told it: a key's release is sent the
    /// way its press was, whatever else is held by then. `chord` marks a key
    /// pressed while ⌘ was down -- see `releaseChordKeys`.
    private var heldKeys: [UInt16: (key: HostKey, chord: Bool)] = [:]

    /// Whether a key is physically down on this Mac right now, by macOS key
    /// code. Replaceable so the tests decide rather than the keyboard of the
    /// Mac running them.
    var isKeyPhysicallyDown: (UInt16) -> Bool = { code in
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }

    /// `isKeyPhysicallyDown` has been seen to answer: it said a key was down
    /// while that key's own press was being handled. Until then its "up" is
    /// not taken at its word, because a macOS that puts the question behind
    /// a permission this app does not ask for answers "up" for every key --
    /// and believed, that would let go on the PC of keys the hand is still
    /// holding.
    private var keyStateAnswers = false

    /// Buttons currently down, for exactly the reason above. Capture stops the
    /// moment the window resigns key, so the matching mouse-up is never seen and
    /// the host is left holding the button — which on a desktop means a
    /// rubber-band selection or a drag that follows the cursor around forever.
    private var heldButtons: Set<SMTInput.MouseButton> = []

    public init() {}

    deinit {
        disableCapture()
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }

    /// Attach to the view whose bounds define the input coordinate space.
    public func attach(to view: NSView) {
        self.targetView = view
    }

    /// Enable capture. Called when the window becomes key.
    ///
    /// Deliberately does NOT require the view to be in a window yet. It used to,
    /// and that was a second way to lose the pointer for good: `becomeKey` can
    /// arrive while the view is still being put into its window, and since the
    /// window is already key nothing calls this again — so capture never starts,
    /// silently, for the whole life of that window. The monitors are app-local
    /// and every handler already guards on `targetView`, so there is nothing
    /// here that a window is needed for.
    public func enableCapture() {
        readMouseSettings()
        guard !isCapturing else { return }
        isCapturing = true
        if modeObserver == nil {
            modeObserver = NotificationCenter.default.addObserver(
                forName: Self.pointerModeChanged, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.sensitivity = CGFloat(Self.gamingSensitivity)
                self.readMouseSettings()
                // Desktop gives the mouse back; following switched on in a
                // menu does too. Asked of the pointer as it is, which is over
                // whatever control changed the setting, not the picture.
                self.apply(self.policy.wantsCapture(after: .reconsider,
                                                    self.moment(pointerInside: self.pointerIsOverPicture())),
                           because: "the mouse settings changed")
            }
        }
        installMonitors()
        syncCapsLock(to: NSEvent.modifierFlags.contains(.capsLock))
        // A game that already has its cursor hidden gets the mouse back as the
        // window comes forward, as one running on this Mac would -- if the
        // pointer is over the picture. Never after ⌃⌥, until a click.
        apply(policy.wantsCapture(after: .reconsider, moment(pointerInside: pointerIsOverPicture())),
              because: "the window became key with the PC's cursor hidden")
    }

    private func readMouseSettings() {
        mode = Self.pointerMode
        followsCursor = Self.followsHostCursor
    }

    /// Disable capture. Called when the window resigns key.
    public func disableCapture() {
        guard isCapturing else { return }
        isCapturing = false
        releasePointer("the window stopped being key")
        releaseHeldInput()
        removeMonitors()
        scrollResidual = .zero
    }

    // MARK: - Monitors

    private func installMonitors() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            // Returning nil consumes the event, which is the only way to stop a
            // keystroke doing something on this Mac *as well as* on the host.
            // Local monitors run ahead of menu key-equivalent matching, so a
            // combination swallowed here never reaches the main menu.
            (self?.handleKeyEvent(event) ?? false) ? nil : event
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                       .otherMouseDown, .otherMouseUp,
                       .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                       .otherMouseDragged, .scrollWheel]
        ) { [weak self] event in
            self?.handleMonitoredEvent(event)
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Keyboard

    /// - Returns: true when the event went to the host and must not also act on
    ///   this Mac.
    ///
    /// Not private so the translation can be tested against real `NSEvent`s
    /// rather than against a restatement of the mapping table: what matters is
    /// the bytes a ⌘C actually puts on the wire.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isCapturing else { return false }

        switch event.type {
        case .keyDown, .keyUp:
            // SolStream's own shortcuts are neither forwarded nor swallowed:
            // AppKit gets them exactly as it would if nothing were streaming.
            //
            // Except for a key the host already has down. Its repeats and its
            // release go to the host whatever is held with them by then: hold
            // W in a game, press ⌃⌘F for full screen, let go of W before ⌃⌘,
            // and W's release carries ⌃⌘ -- which made it a SolStream
            // shortcut, handed to AppKit, and W stayed held on the PC. A
            // repeat of it under ⌃⌘ would have reached the menu as ⌃⌘W, which
            // closes the window.
            let held = heldKeys[event.keyCode]
            guard held != nil
                    || !Self.isReserved(keyCode: event.keyCode, flags: event.modifierFlags) else {
                return false
            }
            // A key already down on the host is let go of as it was pressed.
            // Anything else is first asked whether a key typed it at all --
            // except the key after a dead key, see `followsDeadKey`.
            let afterDeadKey = followsDeadKey
            if event.type == .keyDown {
                followsDeadKey = Self.isDeadKeyPress(characters: event.characters,
                                                     ignoringModifiers: event.charactersIgnoringModifiers)
            }
            var keyCode = event.keyCode
            if held == nil, !(afterDeadKey && event.type == .keyDown) {
                switch keyOrigin(of: event) {
                case .key:
                    break
                case .standIn(let code):
                    keyCode = code
                case .text(let text):
                    // Nothing was pressed on the host, so a release has
                    // nothing to let go of.
                    if event.type == .keyDown { sendText(text) }
                    return true
                }
            }
            guard let key = held?.key ?? Self.hostKey(forMacKey: keyCode,
                                                      isISO: keyboardIsISO(event)) else {
                noteUnmapped(event.keyCode)
                return false
            }
            // The modifiers this key is typed with, as the event says they
            // are, before the key itself: see `syncModifiers`.
            syncModifiers(to: event.modifierFlags)
            let pressed = event.type == .keyDown
            if pressed {
                if !keyStateAnswers, isKeyPhysicallyDown(event.keyCode) {
                    keyStateAnswers = true
                }
                // macOS does not reliably deliver the key-up for a key released
                // while ⌘ is still held, and a key-down the host never sees
                // released auto-repeats forever. Which keys were part of a ⌘
                // chord is recorded here so they can be let go when ⌘ is.
                heldKeys[event.keyCode] = (key, held?.chord
                                                ?? event.modifierFlags.contains(.command))
            } else {
                heldKeys[event.keyCode] = nil
            }
            onInput?(keyPacket(key, pressed: pressed,
                               modifiers: Self.modifiers(from: event.modifierFlags)))
            // Everything that reached the host is consumed. The window is a
            // Windows application as far as the keyboard is concerned, so ⇥ must
            // not move focus around our own view tree and Space must not press
            // whichever control AppKit happens to think is focused.
            return true

        case .flagsChanged:
            // A modifier press and release both arrive as .flagsChanged; which
            // it was is only knowable by diffing against the previous state —
            // and it must be diffed against the device-dependent bit for this
            // exact key, not the shared .shift/.control/... flag.
            let flags = event.modifierFlags
            if event.keyCode == Self.capsLockKeyCode {
                syncCapsLock(to: flags.contains(.capsLock))
            }
            // ⌃⌥ lets a captured mouse go -- the chord VMware and Parallels
            // taught everyone, and one no game binds on its own. Still
            // forwarded below: the host must see the modifiers come up again.
            if isPointerCaptured,
               flags.intersection([.control, .option, .command, .shift]) == [.control, .option] {
                apply(policy.wantsCapture(after: .releaseChord, moment(pointerInside: true)),
                      because: "⌃⌥")
            }
            syncModifiers(to: flags)
            // Never swallowed: AppKit tracks modifier state from these, and a
            // window that stops seeing them is one that thinks ⌘ is still down
            // long after it was let go.
            return false

        default:
            return false
        }
    }

    // MARK: - Text that no key typed

    /// The last key pressed typed nothing: a dead key, waiting for the next
    /// key to say what it makes -- ´ then e making é.
    ///
    /// That next key is always sent as a key, whatever its text. The dead key
    /// itself went to the PC by position, and the PC's layout is composing
    /// with it; the next key's text may be the Mac's composed é, which no
    /// single key types, and sent as text it would land beside the PC's own
    /// ´ instead of finishing it. By position, the PC composes it the way
    /// its layout does.
    private var followsDeadKey = false

    /// A dead key's press types nothing yet but still names its key: its
    /// `charactersIgnoringModifiers` is the accent, or the letter under ⌥.
    /// A posted event with no text at all names nothing, and is not one --
    /// counted as one, it would send the program's next character by
    /// position, as the A key.
    static func isDeadKeyPress(characters: String?, ignoringModifiers: String?) -> Bool {
        (characters ?? "").isEmpty && !(ignoringModifiers ?? "").isEmpty
    }

    /// Where a key event's character came from.
    enum KeyOrigin: Equatable {
        /// A key: sent by position, as every key typed on a keyboard is.
        case key
        /// No key, but a character a key exists for -- Return, Tab, Delete,
        /// Escape -- which is sent as that key, by its Mac key code.
        case standIn(UInt16)
        /// No key: the text itself is sent, and the PC types it as it is.
        case text(String)
    }

    /// Whether a key event came from a key, or only carries text.
    ///
    /// Software can post a key event that names no real key: it sets the
    /// event's text and leaves the key code at 0, which is the A key. An
    /// automation tool typing "echo Hello" into the window did exactly that,
    /// and since keys go by position, every letter reached the PC as A. The
    /// Character Viewer can do the same for a window that is not a text view.
    ///
    /// The test is whether the key could have typed the text: what the key
    /// types on this Mac's keyboard layout, with and without Shift, Caps Lock
    /// and Option, against the event's `charactersIgnoringModifiers`, which
    /// for a real key the system works out from that same layout with Shift
    /// alone. A real key always matches one of them; a posted event carries
    /// whatever text it was given, and an event's text is the one thing a
    /// keystroke made by software has to get right. Other signals were
    /// weighed and are not used. Where an event came from says nothing that
    /// can be relied on: its source state is whatever the poster chose, HID
    /// included, and its process ID is that of every program that remaps keys
    /// as well -- and a remapper's keys, which carry real key codes, must go
    /// by position like any other. Testing only key code 0 against "a" would
    /// miss the A key's place on AZERTY or a Cyrillic layout, and any poster
    /// that picks another code.
    ///
    /// Left as keys whatever their text: anything held with ⌘ or ⌃, so every
    /// shortcut goes by position as before; an event with no text, which is
    /// every dead key's press and every test before this one; the arrows and
    /// function keys, whose text is private-use code points no layout table
    /// gives; and anything the layout cannot be asked about. A control
    /// character no key could have typed is the key that types it -- an
    /// automation tool's "\r" is Return -- or, failing that, left alone.
    ///
    /// `keyTypes` is asked only when the answer depends on it, and returns
    /// everything the key types on the layout, or nil when it cannot say.
    static func keyOrigin(characters: String?, flags: NSEvent.ModifierFlags,
                          keyTypes: () -> Set<String>?) -> KeyOrigin {
        guard flags.isDisjoint(with: [.command, .control]),
              let characters, !characters.isEmpty else { return .key }
        let scalars = characters.unicodeScalars
        if scalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) { return .key }
        guard let typed = keyTypes(), !typed.isEmpty, !typed.contains(characters) else {
            return .key
        }
        if scalars.count == 1, let code = standInKey(for: scalars[scalars.startIndex]) {
            return .standIn(code)
        }
        if scalars.contains(where: isControl) { return .key }
        return .text(characters)
    }

    /// `keyOrigin` for an event, with this Mac's keyboard layout.
    private func keyOrigin(of event: NSEvent) -> KeyOrigin {
        Self.keyOrigin(characters: event.charactersIgnoringModifiers,
                       flags: event.modifierFlags) { [keyTypes] in
            keyTypes(event.keyCode, event)
        }
    }

    /// Everything a key types on the keyboard layout in use. Replaceable so
    /// the tests do not depend on the layout of the Mac that runs them.
    var keyTypes: (UInt16, NSEvent) -> Set<String>? = {
        InputCapture.charactersOnLayout(keyCode: $0, event: $1)
    }

    /// What a key types on the current keyboard layout with each state of
    /// Shift, Caps Lock and Option, dead keys given as their own character;
    /// nil when the layout has no table to ask.
    static func charactersOnLayout(keyCode: UInt16, event: NSEvent?) -> Set<String>? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let table = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(table) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(truncatingIfNeeded: Self.keyboardType(of: event))
        var typed: Set<String> = []
        for shift in [0, shiftKey] {
            for caps in [0, alphaLock] {
                for option in [0, optionKey] {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var units = [UniChar](repeating: 0, count: 8)
                    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown),
                                                UInt32(((shift | caps | option) >> 8) & 0xFF),
                                                keyboardType,
                                                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeys, units.count, &length, &units)
                    if status == noErr, length > 0 {
                        typed.insert(String(utf16CodeUnits: units, count: length))
                    }
                }
            }
        }
        return typed
    }

    /// The Mac key that types a control character, for one no key typed.
    static func standInKey(for scalar: Unicode.Scalar) -> UInt16? {
        switch scalar {
        case "\r", "\n", "\u{03}": return 0x24  // Return
        case "\t": return 0x30                  // Tab
        case "\u{08}", "\u{7F}": return 0x33    // Delete, which is Backspace
        case "\u{1B}": return 0x35              // Escape
        default: return nil
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Send text that no key typed: the Character Viewer, dictation, or an
    /// event `keyOrigin` found carried only text.
    ///
    /// As characters, which the host types with KEYEVENTF_UNICODE whatever
    /// its layout -- the way every host on SMT/1 has taken them. A line break
    /// and a tab go as Return and Tab instead, since a Windows application
    /// acts on those keys and may ignore the bare characters; other control
    /// characters are dropped. Nothing about the modifiers is sent: a
    /// character comes complete, and Alt held under one could make a menu of
    /// it.
    public func sendText(_ text: String) {
        guard isCapturing, let send = onInput else { return }
        var run = String.UnicodeScalarView()
        func flush() {
            guard !run.isEmpty else { return }
            SMTInput.text(String(run)).forEach(send)
            run.removeAll()
        }
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            if let code = Self.standInKey(for: scalar) {
                // \r\n is one line break.
                if scalar == "\n", previous == "\r" { continue }
                flush()
                guard let key = Self.hostKey(forMacKey: code, isISO: false) else { continue }
                let state = Self.modifiers(from: modifierFlagsNow())
                send(keyPacket(key, pressed: true, modifiers: state))
                send(keyPacket(key, pressed: false, modifiers: state))
            } else if !Self.isControl(scalar), !(0xF700...0xF8FF).contains(scalar.value) {
                run.append(scalar)
            }
        }
        flush()
    }

    /// Say, once per key code, that a key was dropped instead of sent.
    ///
    /// `KeyboardMap` covers every key a Mac or PC keyboard plugged into one
    /// sends, but not the ones nothing on a PC corresponds to -- fn, the media
    /// keys when they arrive as keys at all -- nor any a future keyboard adds.
    /// Anything missing from it is handed back to AppKit and never reaches the
    /// host, and from the user's side of the picture that is indistinguishable
    /// from the streamed application ignoring the key — a dead key, with
    /// nothing in any log to say so. This does not map anything; it only turns
    /// a silent drop into a line naming the macOS key code, which is the one
    /// fact needed to add it. Once per code, because a key held down repeats
    /// and the report is worth no more the hundredth time.
    private func noteUnmapped(_ keyCode: UInt16) {
        guard reportedUnmappedKeys.insert(keyCode).inserted else { return }
        let hex = String(keyCode, radix: 16, uppercase: true)
        Log.warning("[input] macOS key code 0x\(hex) is not in the key map,"
                    + " so it was not sent to the host")
    }

    static let capsLockKeyCode: UInt16 = 0x39
    static let windowsCapsLock: UInt16 = 0x14  // VK_CAPITAL
    static let scanCapsLock: UInt16 = 0x3A

    /// Which host this capture's keys go to, so the guess below is kept per
    /// PC rather than shared by every one this Mac has streamed from.
    public var hostName = ""

    /// Whether an event handed to `onInput` now reaches a running session.
    /// Set by the owner; until a session has started, events are dropped.
    public var acceptsInput: () -> Bool = { true }

    /// What this Mac last told each host its Caps Lock is, for a host that
    /// predates scan codes and so can only be sent presses. Shared by every
    /// window on a host, because it has one keyboard state. Windows starts
    /// with it off, which is the assumption until something is sent.
    static var hostCapsLock: [String: Bool] = [:]

    /// Bring the host's Caps Lock to `on`.
    ///
    /// Caps Lock is a toggle on Windows — one press and release flips it — and
    /// the letters are sent as plain key codes, so without this a Mac typing
    /// with Caps Lock on produced lower case on the PC. Called from the Caps
    /// Lock `.flagsChanged`, when capture starts, which covers it being
    /// switched while another application had the keyboard, and when a
    /// session starts.
    ///
    /// A host that takes scan codes is told the STATE, as Caps Lock's own key
    /// carrying the Caps Lock bit, and every key after it carries the bit too:
    /// the host presses its Caps Lock only when its own differs, so nothing on
    /// this side has to guess, and a lost event is put right by the next key.
    ///
    /// An older host can only be sent a press, on top of a guess at its state.
    /// The guess is moved only for a press that reached a running session: it
    /// used to be moved first, so a stream opened with Caps Lock on -- the
    /// window takes the keyboard before the session is running, and the press
    /// went nowhere -- left the PC typing lower case, and every later press
    /// flipped both sides and kept them inverted.
    func syncCapsLock(to on: Bool) {
        guard let send = onInput else { return }
        if sendsScanCodes {
            let state: SMTInput.Modifiers = on ? [.capsLock] : []
            send(SMTInput.scanKey(code: Self.scanCapsLock, pressed: true, modifiers: state))
            send(SMTInput.scanKey(code: Self.scanCapsLock, pressed: false, modifiers: state))
            return
        }
        guard on != (Self.hostCapsLock[hostName] ?? false), acceptsInput() else { return }
        Self.hostCapsLock[hostName] = on
        send(SMTInput.key(code: Self.windowsCapsLock, pressed: true, modifiers: []))
        send(SMTInput.key(code: Self.windowsCapsLock, pressed: false, modifiers: []))
    }

    /// The modifiers held on this Mac right now. Replaceable so the tests
    /// decide rather than the keyboard of the Mac running them.
    var modifierFlagsNow: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    /// A session has just started, or restarted, under this capture: events
    /// sent before it were dropped. Brings the host's Caps Lock and modifiers
    /// into line if this window has the keyboard.
    ///
    /// The host holds nothing at the start of a session -- one that ended
    /// let go of everything it held -- so what this side remembers it being
    /// told is forgotten first. Remembered, a Shift held across a restart was
    /// never pressed on the new session: every event said Shift, nothing
    /// changed, and the PC typed lower case until Shift was pressed again.
    /// Forgotten, what is still held is pressed, and nothing else is sent: no
    /// release, and on a first start with nothing held, nothing at all.
    public func inputBecameLive() {
        guard isCapturing else { return }
        forgetHostState()
        let flags = modifierFlagsNow()
        syncCapsLock(to: flags.contains(.capsLock))
        syncModifiers(to: flags)
    }

    /// Bring the host's modifier keys to what `flags` says is held, sending
    /// only what changed.
    ///
    /// Called for every modifier change, and also for every key and every
    /// click, with the flags that event carries. A modifier's own
    /// `.flagsChanged` is not always seen: local monitors miss what a nested
    /// tracking loop takes -- hold ⌥, open a menu in the menu bar, let go of
    /// ⌥ there -- and a modifier already held when the window took the
    /// keyboard sent nothing at all. Either way the host was left with Alt
    /// held, or without the Shift the letter was typed with, until that key
    /// was pressed again. Every event says what is really held, so the next
    /// one puts it right.
    private func syncModifiers(to flags: NSEvent.ModifierFlags) {
        let held = Self.heldModifierBits(flags.rawValue, last: lastDeviceFlags)
        if held != lastDeviceFlags {
            let modifiers = Self.modifiers(from: flags)
            for change in Self.modifierChanges(from: lastDeviceFlags, to: held,
                                               among: Self.modifierKeys) {
                onInput?(keyPacket(change.key.hostKey, pressed: change.pressed,
                                   modifiers: modifiers))
            }
        }
        let commandWentUp = lastDeviceFlags & Self.commandBits != 0 && !flags.contains(.command)
        lastDeviceFlags = held
        if commandWentUp {
            releaseChordKeys()
        }
    }

    /// Let go of anything pressed during a ⌘ chord, now that ⌘ itself is up.
    ///
    /// Belt and braces against the one macOS behaviour that would leave a key
    /// stuck down on the host: key-up delivery while Command is held. If the
    /// key-ups did arrive there is nothing here to release.
    ///
    /// The same goes for a key pressed BEFORE ⌘ and let go of while it was
    /// held, which is not a chord key: so any other key the host still has
    /// down that this Mac's keyboard says is up is let go of too -- once the
    /// keyboard has been seen to say, see `keyStateAnswers`. One still
    /// physically held is left alone, and its own release will follow.
    ///
    /// A chord key the keyboard says is still held is left alone as well.
    /// They were all let go of, which in a game that crouches on ⌘ stopped
    /// the character walking: hold ⌘, hold W, let go of ⌘ while still
    /// walking, and W was up on the PC until macOS repeated it -- or for good,
    /// with key repeat off.
    private func releaseChordKeys() {
        for code in heldKeys.filter({ $0.value.chord }).keys.sorted() {
            if keyStateAnswers, isKeyPhysicallyDown(code) {
                heldKeys[code]?.chord = false
                continue
            }
            guard let held = heldKeys.removeValue(forKey: code) else { continue }
            onInput?(keyPacket(held.key, pressed: false, modifiers: []))
        }
        guard keyStateAnswers else { return }
        for code in heldKeys.keys.sorted() where !isKeyPhysicallyDown(code) {
            guard let held = heldKeys.removeValue(forKey: code) else { continue }
            onInput?(keyPacket(held.key, pressed: false, modifiers: []))
        }
    }

    /// Release everything still held when focus leaves. Without this the host
    /// keeps the key down — and Windows auto-repeats a key it never sees
    /// released, so a single missed key-up types forever.
    private func releaseHeldInput() {
        for held in heldKeys.values {
            onInput?(keyPacket(held.key, pressed: false, modifiers: []))
        }
        for button in heldButtons {
            onInput?(SMTInput.mouseButton(button, pressed: false))
        }
        // Deduplicated: Control and Command share a Windows key code, so a hand
        // holding both would otherwise send two ups for it.
        var released: Set<UInt16> = []
        for key in Self.modifierKeys where (lastDeviceFlags & key.deviceMask) != 0 {
            guard released.insert(key.windowsKeyCode).inserted else { continue }
            onInput?(keyPacket(key.hostKey, pressed: false, modifiers: []))
        }
        forgetHostState()
    }

    /// Forget every key, button and modifier the host was told is down: it
    /// has just been let go of them, or a new session holds none.
    private func forgetHostState() {
        heldKeys.removeAll()
        heldButtons.removeAll()
        lastDeviceFlags = 0
        followsDeadKey = false
    }

    /// The modifier bitmask that rides along with a key event.
    ///
    /// Command reports as Control, matching the key codes: a packet that said
    /// "Control is not down" while sending Control's key code would describe a
    /// keyboard nobody is holding. `.meta` is never set — that bit means the
    /// Windows key, which no key on this Mac can reach. Caps Lock is its
    /// state, which a host taking scan codes matches its own to.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> SMTInput.Modifiers {
        var result: SMTInput.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) || flags.contains(.command) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        return result
    }

    // MARK: - Mouse

    /// Pointer events dropped because a resize was in progress. Reported with
    /// the rest of the input counters, so a pause that never ended is visible
    /// rather than deduced.
    ///
    /// Pointer input pauses while the macOS window frame is dragged: the user
    /// is resizing the window, not working in the application, and the pointer
    /// sitting on the host window's own edge while both sides are being
    /// resized makes the host start a resize of its own on top of ours.
    ///
    /// Asked of AppKit's `inLiveResize` on every event rather than remembered.
    /// A flag set from `windowWillStartLiveResize` and cleared from
    /// `windowDidEndLiveResize` used to be the gate, and AppKit does not
    /// guarantee that pair: a drag ended any other way left the pointer dead
    /// for the rest of the window's life, with the video still perfect and not
    /// one line in any log to say why.
    public private(set) var droppedWhileResizing: UInt64 = 0

    /// Emit one absolute pointer position from a unit point inside the picture,
    /// through the same crop, guard and canvas mapping a real mouse move uses.
    ///
    /// For `--test-input`, which proves the pointer end to end on the path every
    /// real session uses.
    @discardableResult
    public func sendUnitPosition(x: Double, y: Double) -> Bool {
        guard let source = sourceRect, let canvas = canvasSize,
              canvas.width > 0, canvas.height > 0 else { return false }
        sendCanvasPoint(unit: CGPoint(x: x, y: y), source: source, canvas: canvas)
        return true
    }

    /// A press, told apart from every other: which, and when.
    private struct Press: Equatable {
        let type: NSEvent.EventType
        let timestamp: TimeInterval
        let number: Int
    }

    /// The last press the monitor saw, and the last press handled, so each
    /// press is sent once.
    private var lastMonitoredPress: Press?
    private var lastHandledPress: Press?

    private static let buttonDowns: Set<NSEvent.EventType> =
        [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let drags: Set<NSEvent.EventType> =
        [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]

    private static func press(_ event: NSEvent) -> Press? {
        guard buttonDowns.contains(event.type) else { return nil }
        return Press(type: event.type, timestamp: event.timestamp, number: event.eventNumber)
    }

    /// What the mouse monitor does with an event. Not private so the tests
    /// can stand in for the monitor.
    ///
    /// Everything but the left button's press is handled here. That press
    /// waits for the stream view, because AppKit hands the view a left press
    /// only when it has not made the press the start of a resize or a move
    /// of the window -- and only AppKit knows where that is. The window has
    /// no visible border, and the band it resizes from lies over the edge of
    /// the picture, wider at the rounded corners: a press there that went to
    /// the PC was followed by a resize that swallowed its release, and the
    /// PC held the left button down -- every move a drag, a console's
    /// QuickEdit selection freezing its output. Guessing the band from here
    /// missed part of it.
    func handleMonitoredEvent(_ event: NSEvent) {
        if let press = Self.press(event) { lastMonitoredPress = press }
        guard event.type != .leftMouseDown else { return }
        handleMouseEvent(event)
    }

    /// A press the stream view was handed: every left press that is a click
    /// in the picture, and any other press the monitor did not see.
    ///
    /// A press the monitor did not see is the one that made the window key.
    /// The monitor is installed when the window becomes key -- and a click on
    /// a window that is not key makes it key on the way to the view, after
    /// the monitors have already been run. So the click that brought the
    /// window forward never reached the PC: the first digit typed into
    /// Calculator on the PC was lost, every time the window was clicked into.
    /// The view now takes that first click (`acceptsFirstMouse`) and hands
    /// it here, and a click on a stream window does in the PC application
    /// what it would on a Mac tool window: focus and click at once. In gaming
    /// mode that click takes the mouse, if a click would, and goes no
    /// further: a click that only meant "this window" must not fire in a
    /// game.
    public func handleViewPress(_ event: NSEvent) {
        guard let press = Self.press(event), press != lastHandledPress else { return }
        lastHandledPress = press
        let monitored = press == lastMonitoredPress
        // The monitor has already sent the other buttons' presses.
        guard event.type == .leftMouseDown || !monitored else { return }
        handleMouseEvent(event, firstMouse: !monitored)
    }

    /// Let go on the PC of every button it still holds: AppKit's resize
    /// loop, or anything else, took the release the monitor needed.
    ///
    /// Called when a live resize ends, and on a move with no button down on
    /// this Mac: a safety net under `handleMonitoredEvent`, for a release
    /// lost after a press the PC was given -- a resize AppKit begins
    /// anyway, a tracking loop of anything else's.
    public func releaseStrandedButtons(_ reason: String) {
        guard !heldButtons.isEmpty else { return }
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            onInput?(SMTInput.mouseButton(button, pressed: false))
        }
        Log.info("[input] let go of \(heldButtons.count) button(s) on the PC (\(reason))")
        heldButtons.removeAll()
    }

    /// The Mac's buttons held right now. Replaceable so the tests decide
    /// rather than the mouse of the Mac running them.
    var buttonsPressedNow: () -> Int = { NSEvent.pressedMouseButtons }

    /// Not private so the packets a click or a move produces can be tested
    /// against real `NSEvent`s, as `handleKeyEvent`'s are.
    func handleMouseEvent(_ event: NSEvent, firstMouse: Bool = false) {
        guard isCapturing, let view = targetView else { return }
        // The monitor is application-wide, so with two streamed windows open a
        // click on the other one arrives here too — and converted into THIS
        // view's coordinates it lands somewhere arbitrary on the host. A button
        // already held is the exception: its release must always get through,
        // or the host is left with a button stuck down.
        if let window = event.window, window !== view.window, heldButtons.isEmpty {
            return
        }
        if view.inLiveResize || (view.window?.inLiveResize ?? false) {
            droppedWhileResizing &+= 1
            return
        }

        if event.type == .mouseMoved, !heldButtons.isEmpty, buttonsPressedNow() == 0 {
            releaseStrandedButtons("a move with no button down")
        }
        // A drag whose press the PC was not given -- one that began a resize
        // or a move of the window, or was made outside the picture -- is not
        // the PC's either, and nor is its release, below.
        if !isPointerCaptured, heldButtons.isEmpty, Self.drags.contains(event.type) {
            return
        }
        if firstMouse, mode == .gaming {
            if !isPointerCaptured {
                _ = takesPointer(on: event, in: view, deliversClick: false)
            }
            return
        }
        if isPointerCaptured {
            handleCapturedPointer(event, in: view)
            return
        }
        if mode == .gaming {
            if takesPointer(on: event, in: view) { return }
            if gameReadsMotion {
                handleUncapturedOverGame(event)
                return
            }
        }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if event.type == .mouseMoved { mouseMovedSeen += 1 }
            // A drag follows the pointer out of the window; a bare move does not,
            // so letting go of the mouse outside leaves the host cursor exactly
            // where the drag left it.
            sendPosition(for: event, in: view, clampToEdge: !heldButtons.isEmpty)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Position first: Windows clicks wherever the pointer currently is.
            // And only click at all if that position landed inside the picture.
            // The monitor is application-wide, so it also sees clicks on the
            // title bar, the quality pill and the status overlay -- all outside
            // the video -- and those used to reach the host as clicks at
            // whatever coordinate the pointer was last moved to.
            guard sendPosition(for: event, in: view) else { return }
            pressButton(event)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            releaseButton(event, positionIn: view)

        case .scrollWheel:
            // Position first, and only scroll at all if that position landed
            // inside the picture — exactly as for a button, and for the same
            // reason. The monitor is application-wide, so it also sees the wheel
            // turned over the title bar, the quality pill and the status
            // overlay, and every one of those used to scroll the streamed
            // application instead of doing nothing. Sending the position first
            // matters here beyond the check: the host injects the wheel with
            // SendInput, and Windows delivers a wheel event to whatever window
            // is under the cursor, so the pointer has to be where the wheel was
            // turned before the wheel arrives.
            guard sendPosition(for: event, in: view) else { return }
            sendWheel(event)

        default:
            break
        }
    }

    /// Press a button on the host, with the modifiers it was pressed with: a
    /// Shift-click is a Shift-click only if the host has Shift.
    private func pressButton(_ event: NSEvent) {
        guard let button = button(for: event) else { return }
        syncModifiers(to: event.modifierFlags)
        heldButtons.insert(button)
        onInput?(SMTInput.mouseButton(button, pressed: true))
    }

    /// Release a button on the host -- only one it was told is down, since a
    /// lone release is not something to hand an application. Given a view,
    /// the position goes first.
    private func releaseButton(_ event: NSEvent, positionIn view: NSView? = nil) {
        guard let button = button(for: event), heldButtons.remove(button) != nil else { return }
        if let view { sendPosition(for: event, in: view) }
        onInput?(SMTInput.mouseButton(button, pressed: false))
    }

    private func sendWheel(_ event: NSEvent) {
        let wheel = Self.wheelUnits(deltaX: event.scrollingDeltaX,
                                    deltaY: event.scrollingDeltaY,
                                    precise: event.hasPreciseScrollingDeltas,
                                    residual: scrollResidual)
        scrollResidual = wheel.residual
        if wheel.vertical != 0 { onInput?(SMTInput.scroll(amount: wheel.vertical)) }
        if wheel.horizontal != 0 { onInput?(SMTInput.horizontalScroll(amount: wheel.horizontal)) }
    }

    // MARK: - Following the host's cursor

    /// When gaming mode holds the mouse, decided from facts alone.
    ///
    /// Kept apart from the side effects -- hiding the Mac's cursor, decoupling
    /// it from the mouse -- so the rule can be tested without a mouse. The rule
    /// is what went wrong: a game's pause menu showed its cursor, the Mac went
    /// on holding the mouse, and the menu had no pointer at all.
    ///
    /// Following the host means its cursor decides. Hidden -- GLFW's null
    /// cursor, ShowCursor(FALSE) -- is a game reading raw motion, so the mouse
    /// is taken as soon as the pointer is over the picture. Shown is a menu, so
    /// the mouse is given back, and a click in it is just a click.
    struct CapturePolicy: Equatable {
        /// What the host last said: its cursor is off the screen.
        private(set) var hostCursorHidden = false

        /// The host reports its cursor going away as well as its shape, so a
        /// shape from it can be trusted to mean "shown".
        ///
        /// An agent that does says so on every push, and the owner sets this
        /// from that. Otherwise it is learned from seeing the host both hide
        /// its cursor and show one -- both, not just "hidden": an agent older
        /// than the report only ever sends shapes, and one that misread a PC
        /// with no mouse could say "hidden" for ever. Following either would
        /// leave a click unable to take the mouse, or nothing able to give it
        /// back; until then a click takes it and ⌃⌥ releases it, as before.
        var hostReportsVisibility = false
        private var seenHidden = false
        private var seenShown = false

        /// ⌃⌥ let the mouse go while the game still had its cursor hidden.
        ///
        /// Held until the next click in the picture, or until the game shows a
        /// cursor and so ends the spell it was asking for: otherwise the very
        /// next move over the picture would take the mouse straight back.
        private(set) var releasedByHand = false

        enum Event: Equatable {
            /// The host pushed its cursor: hidden, or a shape.
            case hostCursor(hidden: Bool)
            /// A button went down.
            case click
            /// The pointer moved.
            case pointerMoved
            /// ⌃⌥ while the mouse was held.
            case releaseChord
            /// Nothing from the hand: focus or a setting changed.
            case reconsider
        }

        /// What the policy does not remember for itself.
        struct Moment {
            var mode: PointerMode
            var followsHostCursor: Bool
            /// The window is key and its input is being captured.
            var isActive: Bool
            /// The Mac's pointer is over the picture -- or, for anything but a
            /// click, a button is held.
            var pointerInside: Bool
            var isCaptured: Bool
        }

        /// Whether the host's cursor decides, rather than clicks and ⌃⌥ alone.
        func isFollowing(_ followsHostCursor: Bool) -> Bool {
            followsHostCursor && hostReportsVisibility
        }

        /// Take in `event`, and say whether the mouse should now be held.
        mutating func wantsCapture(after event: Event, _ now: Moment) -> Bool {
            switch event {
            case .hostCursor(let hidden):
                hostCursorHidden = hidden
                if hidden {
                    seenHidden = true
                } else {
                    seenShown = true
                    releasedByHand = false
                }
                if seenHidden && seenShown { hostReportsVisibility = true }
            case .click where now.pointerInside:
                releasedByHand = false
            case .releaseChord:
                releasedByHand = true
                return false
            default:
                break
            }
            return Self.shouldCapture(mode: now.mode,
                                      following: isFollowing(now.followsHostCursor),
                                      hostHidden: hostCursorHidden,
                                      isActive: now.isActive,
                                      pointerInside: now.pointerInside,
                                      releasedByHand: releasedByHand,
                                      isCaptured: now.isCaptured,
                                      clicked: event == .click)
        }

        /// The rule itself, with nothing remembered.
        static func shouldCapture(mode: PointerMode, following: Bool, hostHidden: Bool,
                                  isActive: Bool, pointerInside: Bool, releasedByHand: Bool,
                                  isCaptured: Bool, clicked: Bool) -> Bool {
            guard isActive, mode == .gaming else { return false }
            guard following else {
                // Clicks and ⌃⌥ alone: a click in the picture takes the mouse,
                // and only letting go gives it back.
                return isCaptured || (clicked && pointerInside)
            }
            // A cursor on the PC is a menu, and a menu needs a pointer.
            guard hostHidden else { return false }
            if isCaptured { return true }
            if clicked { return pointerInside }
            return pointerInside && !releasedByHand
        }
    }

    /// The host's cursor went off the screen, or came back as a shape.
    ///
    /// Called for every cursor push. In gaming mode, following the host, the
    /// game hiding its cursor takes the mouse if the pointer is over the
    /// picture, and the game showing one -- a pause menu, an inventory -- gives
    /// it back.
    ///
    /// Given back, the Mac's cursor reappears where it was taken, and the PC's
    /// is somewhere else: only motion was sent while the mouse was held, and
    /// Minecraft, for one, centres its cursor as a menu opens. The menu would
    /// then highlight the button under a pointer nobody can see until the
    /// first move. So the PC's cursor is put under the Mac's at once -- safe
    /// now, because a game that shows a cursor has stopped reading raw motion.
    public func hostCursorVisibilityChanged(hidden: Bool) {
        let wasHidden = policy.hostCursorHidden
        // Only gaming mode ever takes the mouse, so only it asks where the
        // pointer is.
        let inside = isCapturing && mode == .gaming
            && (pointerIsOverPicture() || !heldButtons.isEmpty)
        apply(policy.wantsCapture(after: .hostCursor(hidden: hidden), moment(pointerInside: inside)),
              because: hidden ? "the PC hid its cursor" : "the PC showed its cursor")
        guard wasHidden, !hidden, isCapturing, !isPointerCaptured, mode == .gaming,
              policy.isFollowing(followsCursor),
              let pointer = pointerUnitPoint() else { return }
        sendUnitPosition(x: pointer.x, y: pointer.y)
    }

    /// The game has its cursor hidden and is reading raw motion, and the mouse
    /// is not captured: ⌃⌥ let it go, or the pointer is over something
    /// covering the picture. Only asked once a captured mouse has been ruled
    /// out.
    private var gameReadsMotion: Bool {
        policy.isFollowing(followsCursor) && policy.hostCursorHidden
    }

    /// Pointer events while `gameReadsMotion`, which mostly go nowhere.
    ///
    /// The host injects an absolute position as a jump of its cursor, which a
    /// game reading raw motion turns into a swing of its camera: the pointer
    /// travelling up to the title bar after ⌃⌥ would turn the player round,
    /// and the wheel on the way change what they hold. Neither is sent. A click
    /// in the picture has already taken the mouse back, in `takesPointer`; a
    /// release still goes, as the button alone, so nothing is left held down.
    private func handleUncapturedOverGame(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            releaseButton(event)
        default:
            if event.type == .mouseMoved { mouseMovedSeen += 1 }
            withheldFromGame += 1
        }
    }

    private func moment(pointerInside: Bool) -> CapturePolicy.Moment {
        CapturePolicy.Moment(mode: mode, followsHostCursor: followsCursor,
                             isActive: isCapturing, pointerInside: pointerInside,
                             isCaptured: isPointerCaptured)
    }

    private func apply(_ wanted: Bool, because reason: String) {
        if wanted {
            capturePointer(reason)
        } else {
            releasePointer(reason)
        }
    }

    /// Capture the mouse if this event is the one gaming mode takes it on.
    ///
    /// - Parameter deliversClick: false for a click that only brought the
    ///   window forward, which takes the mouse and is not itself sent.
    /// - Returns: true when the event has been handled as a captured one.
    private func takesPointer(on event: NSEvent, in view: NSView,
                              deliversClick: Bool = true) -> Bool {
        let isClick = Self.buttonDowns.contains(event.type)
        let isMove = event.type == .mouseMoved || Self.drags.contains(event.type)
        guard isClick || isMove else { return false }
        // A click must land in the picture itself; a move may be a drag that
        // has carried a held button out of it.
        let inside = pictureUnitPoint(for: event, in: view) != nil
            || (isMove && !heldButtons.isEmpty)
        guard policy.wantsCapture(after: isClick ? .click : .pointerMoved,
                                  moment(pointerInside: inside)) else { return false }
        // The key window hears every move, wherever the pointer is -- over
        // another application's window covering the picture, too. A click is
        // delivered to the window it lands on, so only a move has to ask
        // whether the picture is really what is under the pointer. Asked only
        // now, when the answer would take the mouse.
        if isMove, heldButtons.isEmpty, !pointerIsOverPicture() { return false }

        if policy.isFollowing(followsCursor) {
            // The game has its cursor hidden and is reading motion, not
            // position: an absolute position now would turn its camera. So the
            // mouse is taken first, and this event goes as a captured one --
            // a click as the button alone.
            capturePointer(isClick ? "a click in the picture" : "the PC's cursor is hidden")
            if deliversClick { handleCapturedPointer(event, in: view) }
            return true
        }
        // The click that captures is also delivered: it is usually the one
        // that focuses the game, or fires. The position sent first puts the
        // host cursor where it was clicked, and motion is relative from there.
        sendPosition(for: event, in: view)
        capturePointer("a click in the picture")
        return !deliversClick
    }

    /// Where the Mac's pointer is in the picture right now, as 0...1 from its
    /// top-left -- or nil when it is not over the picture, or is under
    /// something drawn above it: the stats popover, another window. Always nil
    /// during a resize: decoupling the cursor would stop the frame under the
    /// hand dragging it.
    private func pointerUnitPoint() -> CGPoint? {
        if let pointerStandIn { return pointerStandIn() }
        guard let view = targetView, let window = view.window,
              !window.inLiveResize else { return nil }
        let onScreen = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: onScreen, belowWindowWithWindowNumber: 0)
                == window.windowNumber else { return nil }
        let point = view.convert(window.convertPoint(fromScreen: onScreen), from: nil)
        return Self.unitPoint(viewPoint: point, viewSize: view.bounds.size,
                              source: source(for: view), isFlipped: view.isFlipped)
    }

    private func pointerIsOverPicture() -> Bool {
        pointerUnitPoint() != nil
    }

    /// Where an event falls in the picture, or nil when it is outside it.
    private func pictureUnitPoint(for event: NSEvent, in view: NSView) -> CGPoint? {
        Self.unitPoint(viewPoint: view.convert(event.locationInWindow, from: nil),
                       viewSize: view.bounds.size, source: source(for: view),
                       isFlipped: view.isFlipped)
    }

    /// The part of the canvas a view shows: `sourceRect`, or else the whole
    /// canvas -- or the view's own size, before the canvas is known.
    private func source(for view: NSView) -> CGRect {
        sourceRect ?? CGRect(origin: .zero, size: canvasSize ?? view.bounds.size)
    }

    // MARK: - Captured pointer

    private func capturePointer(_ reason: String) {
        guard !isPointerCaptured else { return }
        isPointerCaptured = true
        relativeResidual = .zero
        sensitivity = CGFloat(Self.gamingSensitivity)
        lockSystemPointer(true)
        Log.info("[input] mouse captured for gaming (\(reason)); ⌃⌥ releases it")
        onPointerCaptureChanged?(true)
    }

    /// Give the mouse back to the Mac. Safe to call whether or not it is held.
    public func releasePointer(_ reason: String? = nil) {
        guard isPointerCaptured else { return }
        isPointerCaptured = false
        lockSystemPointer(false)
        Log.info("[input] mouse released" + (reason.map { " (\($0))" } ?? ""))
        onPointerCaptureChanged?(false)
    }

    /// Motion while captured, in canvas pixels, and what rounding left over.
    ///
    /// NSEvent's deltas are in points and already carry the Mac's pointer
    /// acceleration, which is what the hand on the mouse is calibrated to.
    /// Scaled by how many canvas pixels one point of this view shows, so a
    /// turn feels the same whatever size the window is, then by the chosen
    /// sensitivity.
    static func relativeMotion(deltaX: CGFloat, deltaY: CGFloat, pixelsPerPoint: CGFloat,
                               sensitivity: CGFloat, residual: CGPoint)
        -> (dx: Int, dy: Int, residual: CGPoint) {
        let scale = pixelsPerPoint * sensitivity
        let x = residual.x + deltaX * scale
        let y = residual.y + deltaY * scale
        let dx = Int(x.rounded(.towardZero))
        let dy = Int(y.rounded(.towardZero))
        return (dx, dy, CGPoint(x: x - CGFloat(dx), y: y - CGFloat(dy)))
    }

    private func handleCapturedPointer(_ event: NSEvent, in view: NSView) {
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            mouseMovedSeen += 1
            let perPoint = view.bounds.width > 0 ? source(for: view).width / view.bounds.width : 1
            let motion = Self.relativeMotion(deltaX: event.deltaX, deltaY: event.deltaY,
                                             pixelsPerPoint: perPoint, sensitivity: sensitivity,
                                             residual: relativeResidual)
            relativeResidual = motion.residual
            if motion.dx != 0 || motion.dy != 0 {
                positionsSent += 1
                onInput?(SMTInput.mouseMoveRelative(deltaX: motion.dx, deltaY: motion.dy))
            }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressButton(event)

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // The mouse can be taken between a press and its release -- the
            // game hiding its cursor, or the window coming forward under a
            // click it never forwarded -- so this may have no press to match.
            releaseButton(event)

        case .scrollWheel:
            sendWheel(event)

        default:
            break
        }
    }

    /// A scroll event in Windows wheel units, carrying what rounding left over.
    ///
    /// Windows counts a wheel click as 120 units, and Chromium -- Edge, Chrome
    /// and every Electron app -- scrolls 100 device-independent pixels for it.
    /// The streamed window shows the capture display at one Mac point per
    /// host DIP (a 200% display in a Retina window), so 1.2 units a point
    /// moves the content exactly as far as the fingers moved on the trackpad,
    /// which is what macOS does. At 12 a point, as this was, content ran ten
    /// times further than the hand.
    ///
    /// A wheel mouse reports lines, one per notch, and each is a whole Windows
    /// notch of 120: a game counts notches -- Minecraft changes hotbar slot
    /// once per 120, and less than that does nothing -- and every Windows app
    /// expects a wheel to arrive that way.
    ///
    /// The axes do not share a sign convention. AppKit's positive deltaY is
    /// up and its positive deltaX is LEFT (NSEvent.h: "-1 for swipe right and
    /// 1 for swipe left"); Windows' positive WHEEL is up and its positive
    /// HWHEEL is right. So vertical passes straight through and horizontal is
    /// negated — sending both unchanged scrolled sideways the wrong way.
    static let unitsPerPoint: CGFloat = 1.2
    static let unitsPerLine: CGFloat = 120

    static func wheelUnits(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                           residual: CGPoint)
        -> (horizontal: Int, vertical: Int, residual: CGPoint) {
        let unit: CGFloat = precise ? unitsPerPoint : unitsPerLine
        // What is left over is carried only the way it was going. Carried
        // against a turn of the wheel, a leftover of 0.9 made the first notch
        // back 119, which Minecraft and anything else counting whole notches
        // ignores -- one lost step at every change of direction.
        func carried(_ left: CGFloat, toward delta: CGFloat) -> CGFloat {
            left != 0 && delta != 0 && (left > 0) != (delta > 0) ? 0 : left
        }
        let x = carried(residual.x, toward: -deltaX) - deltaX * unit
        let y = carried(residual.y, toward: deltaY) + deltaY * unit
        let horizontal = Int(x.rounded(.towardZero))
        let vertical = Int(y.rounded(.towardZero))
        return (horizontal, vertical,
                CGPoint(x: x - CGFloat(horizontal), y: y - CGFloat(vertical)))
    }

    /// Send the pointer position in the view's own coordinate space.
    ///
    /// View points are turned into a fraction of the canvas here, because that is
    /// all the wire carries: `sourceRect` says which part of the canvas this view
    /// is showing, and the host normalises the result across its own target. No
    /// reference rectangle travels with the packet — see `sourceRect`. macOS
    /// coordinates are bottom-left origin, Windows is top-left, hence the flip.
    /// - Parameter clampToEdge: pin an outside point to the edge of the picture
    ///   rather than refusing it. Used while a button is held: the host still has
    ///   that button down, and a selection or drag that stops tracking the moment
    ///   the pointer leaves the window is worse than one that tracks to the edge
    ///   and waits there.
    /// - Returns: whether a position actually went to the host. False means the
    ///   event was outside the picture, and a click there is not a click on the
    ///   remote application.
    @discardableResult
    private func sendPosition(for event: NSEvent, in view: NSView,
                              clampToEdge: Bool = false) -> Bool {
        let point = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }

        let source = self.source(for: view)
        let canvas = canvasSize ?? source.size
        guard canvas.width > 0, canvas.height > 0 else { return false }

        // Ignore events outside the video surface rather than clamping them to
        // the edge, which would drag the host pointer along the border — unless a
        // drag is in progress, where stopping is the worse of the two.
        let mapped = clampToEdge
            ? Self.clampedUnitPoint(viewPoint: point, viewSize: bounds.size,
                                    source: source, isFlipped: view.isFlipped)
            : Self.unitPoint(viewPoint: point, viewSize: bounds.size,
                             source: source, isFlipped: view.isFlipped)
        guard let unit = mapped else {
            positionsOutside += 1
            return false
        }
        sendCanvasPoint(unit: unit, source: source, canvas: canvas)
        return true
    }

    /// Send a unit point within the crop as an absolute position on the
    /// canvas, kept clear of its edges by `edgeGuard`.
    private func sendCanvasPoint(unit: CGPoint, source: CGRect, canvas: CGSize) {
        let target = Self.canvasPoint(unit: unit, source: source, edgeGuard: edgeGuard)
        positionsSent += 1
        onInput?(SMTInput.mouseMoveAbsolute(x: Int(target.x.rounded()),
                                            y: Int(target.y.rounded()),
                                            referenceWidth: Int(canvas.width),
                                            referenceHeight: Int(canvas.height)))
    }

    /// Where a point in the view falls within the video, as 0...1 from its
    /// top-left. Nil when the point is outside the picture.
    ///
    /// The video layer scales with `.resizeAspect`, so whenever the crop's shape
    /// does not match the view's, the picture is letterboxed and sits inside a
    /// smaller box than the view. Measuring from the view's edges then introduces
    /// an error that GROWS with distance from the centre — the pointer drifts
    /// further the further it travels, which is exactly how this presents.
    ///
    /// The shapes normally match, because the host window is sized to follow this
    /// one. They stop matching for a few frames during a live resize, and
    /// whenever the host cannot give us the size we asked for.
    static func unitPoint(viewPoint: CGPoint, viewSize: CGSize,
                          source: CGRect, isFlipped: Bool) -> CGPoint? {
        guard let unit = rawUnitPoint(viewPoint: viewPoint, viewSize: viewSize,
                                      source: source, isFlipped: isFlipped),
              (0...1).contains(unit.x), (0...1).contains(unit.y) else { return nil }
        return unit
    }

    /// The same mapping, but pinned to the edge instead of refused when the
    /// point falls outside the picture.
    static func clampedUnitPoint(viewPoint: CGPoint, viewSize: CGSize,
                                 source: CGRect, isFlipped: Bool) -> CGPoint? {
        guard let unit = rawUnitPoint(viewPoint: viewPoint, viewSize: viewSize,
                                      source: source, isFlipped: isFlipped) else { return nil }
        return CGPoint(x: min(max(unit.x, 0), 1), y: min(max(unit.y, 0), 1))
    }

    /// The mapping itself, neither refused nor pinned outside the picture;
    /// nil only when there is no picture to map into.
    private static func rawUnitPoint(viewPoint: CGPoint, viewSize: CGSize,
                                     source: CGRect, isFlipped: Bool) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0,
              source.width > 0, source.height > 0 else { return nil }

        let fit = min(viewSize.width / source.width, viewSize.height / source.height)
        let shown = CGSize(width: source.width * fit, height: source.height * fit)
        guard shown.width > 0, shown.height > 0 else { return nil }

        let inset = CGPoint(x: (viewSize.width - shown.width) / 2,
                            y: (viewSize.height - shown.height) / 2)
        // macOS is bottom-left origin, Windows is top-left, hence the flip.
        let fromTop = isFlipped ? viewPoint.y : viewSize.height - viewPoint.y
        return CGPoint(x: (viewPoint.x - inset.x) / shown.width,
                       y: (fromTop - inset.y) / shown.height)
    }

    /// Turn a unit position within the crop into a canvas coordinate, kept
    /// `edgeGuard` pixels clear of the crop's own edges.
    ///
    /// The outer band of a window is its resize grab area, so a pointer that can
    /// reach it can start a host-side resize — which belongs to the macOS window
    /// frame, not to the picture. Pinned rather than dropped, so the pointer
    /// still tracks to the edge of the usable area instead of freezing short of
    /// it.
    static func canvasPoint(unit: CGPoint, source: CGRect, edgeGuard: CGFloat) -> CGPoint {
        // A crop narrower than two guards would invert the safe rectangle, so
        // the guard gives way rather than the geometry.
        let insetX = min(edgeGuard, max(0, (source.width - 1) / 2))
        let insetY = min(edgeGuard, max(0, (source.height - 1) / 2))
        let safe = source.insetBy(dx: insetX, dy: insetY)
        return CGPoint(x: min(max(source.minX + unit.x * source.width, safe.minX), safe.maxX),
                       y: min(max(source.minY + unit.y * source.height, safe.minY), safe.maxY))
    }

    private func button(for event: NSEvent) -> SMTInput.MouseButton? {
        Self.button(for: event.type, number: event.buttonNumber)
    }

    /// Which host button a Mac button event is.
    ///
    /// AppKit numbers the thumb buttons of a five-button mouse 3 (back) and 4
    /// (forward), and Windows calls them XBUTTON1 and XBUTTON2 -- which is what
    /// the wire's `extra1` and `extra2` become on the host. They used to be
    /// dropped here, so back and forward did nothing in a browser on the PC
    /// and a game bound to Mouse4 or Mouse5 never saw them. Anything beyond
    /// the fifth has no Windows button to be, and is still not sent.
    static func button(for type: NSEvent.EventType, number: Int) -> SMTInput.MouseButton? {
        switch type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp:
            switch number {
            case 2: return .middle
            case 3: return .extra1
            case 4: return .extra2
            default: return nil
            }
        default: return nil
        }
    }
}
