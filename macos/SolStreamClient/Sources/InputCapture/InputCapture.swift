import AppKit
import Carbon
import MediaSession
import SolStreamLogging

/// Turns local macOS keyboard and mouse events into GameStream input packets.
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

    /// Modifier flags as of the last `.flagsChanged`, so transitions can be
    /// turned into individual key down/up events.
    private var lastModifierFlags: NSEvent.ModifierFlags = []
    private var lastDeviceFlags: UInt = 0

    /// macOS virtual key code → Windows virtual key code.
    private let keyCodeMap: [UInt16: UInt16] = [
        // Letters
        0x00: 0x41, 0x0B: 0x42, 0x08: 0x43, 0x02: 0x44, 0x0E: 0x45, 0x03: 0x46,
        0x05: 0x47, 0x04: 0x48, 0x22: 0x49, 0x26: 0x4A, 0x28: 0x4B, 0x25: 0x4C,
        0x2E: 0x4D, 0x2D: 0x4E, 0x1F: 0x4F, 0x23: 0x50, 0x0C: 0x51, 0x0F: 0x52,
        0x01: 0x53, 0x11: 0x54, 0x20: 0x55, 0x09: 0x56, 0x0D: 0x57, 0x07: 0x58,
        0x10: 0x59, 0x06: 0x5A,

        // Digits
        0x1D: 0x30, 0x12: 0x31, 0x13: 0x32, 0x14: 0x33, 0x15: 0x34,
        0x17: 0x35, 0x16: 0x36, 0x1A: 0x37, 0x1C: 0x38, 0x19: 0x39,

        // Editing and navigation
        0x24: 0x0D,  // Return
        0x30: 0x09,  // Tab
        0x31: 0x20,  // Space
        0x33: 0x08,  // Backspace
        0x35: 0x1B,  // Escape
        0x75: 0x2E,  // Forward delete
        0x73: 0x24,  // Home
        0x77: 0x23,  // End
        0x74: 0x21,  // Page up
        0x79: 0x22,  // Page down
        0x7B: 0x25, 0x7C: 0x27, 0x7D: 0x28, 0x7E: 0x26,  // ← → ↓ ↑

        // Punctuation (US layout)
        0x1B: 0xBD,  // -
        0x18: 0xBB,  // =
        0x21: 0xDB,  // [
        0x1E: 0xDD,  // ]
        0x2A: 0xDC,  // \
        0x29: 0xBA,  // ;
        0x27: 0xDE,  // '
        0x2B: 0xBC,  // ,
        0x2F: 0xBE,  // .
        0x2C: 0xBF,  // /
        0x32: 0xC0,  // `

        // Function keys
        0x7A: 0x70, 0x78: 0x71, 0x63: 0x72, 0x76: 0x73, 0x60: 0x74, 0x61: 0x75,
        0x62: 0x76, 0x64: 0x77, 0x65: 0x78, 0x6D: 0x79, 0x67: 0x7A, 0x6F: 0x7B,
    ]

    /// Key codes already reported by `noteUnmapped`, so a held key says it once.
    private var reportedUnmappedKeys: Set<UInt16> = []

    /// Modifier keys need their own left/right virtual key codes, and each one
    /// maps to the flag whose transition announces it.
    struct ModifierKey {
        let macKeyCode: UInt16
        let windowsKeyCode: UInt16
        /// The DEVICE-DEPENDENT mask for this specific physical key. The public
        /// flags (.shift, .control…) are shared by the left and right keys, so
        /// releasing one while the other is held reads as "still down" and
        /// would emit a key DOWN — leaving that key stuck on the host forever.
        let deviceMask: UInt
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
    /// which `otherKeyHolds` exists to handle.
    let modifierKeys: [ModifierKey] = [
        ModifierKey(macKeyCode: 0x38, windowsKeyCode: 0xA0, deviceMask: 0x0000_0002),  // L shift
        ModifierKey(macKeyCode: 0x3C, windowsKeyCode: 0xA1, deviceMask: 0x0000_0004),  // R shift
        ModifierKey(macKeyCode: 0x3B, windowsKeyCode: 0xA2, deviceMask: 0x0000_0001),  // L ctrl
        ModifierKey(macKeyCode: 0x3E, windowsKeyCode: 0xA3, deviceMask: 0x0000_2000),  // R ctrl
        ModifierKey(macKeyCode: 0x3A, windowsKeyCode: 0xA4, deviceMask: 0x0000_0020),  // L alt
        ModifierKey(macKeyCode: 0x3D, windowsKeyCode: 0xA5, deviceMask: 0x0000_0040),  // R alt
        ModifierKey(macKeyCode: 0x37, windowsKeyCode: 0xA2, deviceMask: 0x0000_0008),  // L cmd → L ctrl
        ModifierKey(macKeyCode: 0x36, windowsKeyCode: 0xA3, deviceMask: 0x0000_0010),  // R cmd → R ctrl
    ]

    /// Is some *other* physical Mac key that maps to the same Windows key still
    /// down?
    ///
    /// Control and Command both become Windows Control, so releasing one while
    /// the other is held would send a key-up for a key the user is still
    /// pressing: the host drops out of Control mid-chord, and the next letter
    /// gets typed into the document instead of running the shortcut. The
    /// symmetric case matters less but is skipped for the same reason — a second
    /// key-down for a key already down is noise.
    static func otherKeyHolds(_ key: ModifierKey, flags: UInt,
                              among keys: [ModifierKey]) -> Bool {
        keys.contains {
            $0.windowsKeyCode == key.windowsKeyCode
                && $0.macKeyCode != key.macKeyCode
                && (flags & $0.deviceMask) != 0
        }
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

    /// Non-modifier keys currently held, so they can be released on focus loss.
    /// The host hands key-down straight to SendInput, and Windows auto-repeats a
    /// key it never sees released — so a missed key-up repeats forever. The host
    /// releases everything it is holding when a session ends, which covers the
    /// session going away; this covers the window merely losing focus, which it
    /// does not.
    private var heldKeys: Set<UInt16> = []

    /// The subset of `heldKeys` pressed while ⌘ was down — see `releaseChordKeys`.
    private var chordKeys: Set<UInt16> = []

    /// Buttons currently down, for exactly the reason above. Capture stops the
    /// moment the window resigns key, so the matching mouse-up is never seen and
    /// the host is left holding the button — which on a desktop means a
    /// rubber-band selection or a drag that follows the cursor around forever.
    private var heldButtons: Set<SMTInput.MouseButton> = []

    public init() {}

    deinit {
        disableCapture()
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
        guard !isCapturing else { return }
        isCapturing = true
        installMonitors()
    }

    /// Disable capture. Called when the window resigns key.
    public func disableCapture() {
        guard isCapturing else { return }
        isCapturing = false
        releaseHeldInput()
        removeMonitors()
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
            self?.handleMouseEvent(event)
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
            guard !Self.isReserved(keyCode: event.keyCode, flags: event.modifierFlags) else {
                return false
            }
            guard let windowsKey = keyCodeMap[event.keyCode] else {
                noteUnmapped(event.keyCode)
                return false
            }
            let pressed = event.type == .keyDown
            if pressed {
                heldKeys.insert(windowsKey)
                // macOS does not reliably deliver the key-up for a key released
                // while ⌘ is still held, and a key-down the host never sees
                // released auto-repeats forever. Which keys were part of a ⌘
                // chord is recorded here so they can be let go when ⌘ is.
                if event.modifierFlags.contains(.command) { chordKeys.insert(windowsKey) }
            } else {
                heldKeys.remove(windowsKey)
                chordKeys.remove(windowsKey)
            }
            onInput?(SMTInput.key(code: windowsKey,
                                       pressed: pressed,
                                       modifiers: modifiers(from: event.modifierFlags)))
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
            let deviceFlags = flags.rawValue
            if let key = modifierKeys.first(where: { $0.macKeyCode == event.keyCode }),
               !Self.otherKeyHolds(key, flags: deviceFlags, among: modifierKeys) {
                let isDown = (deviceFlags & key.deviceMask) != 0
                onInput?(SMTInput.key(code: key.windowsKeyCode,
                                           pressed: isDown,
                                           modifiers: modifiers(from: flags)))
            }
            if lastModifierFlags.contains(.command) && !flags.contains(.command) {
                releaseChordKeys()
            }
            lastModifierFlags = flags
            lastDeviceFlags = deviceFlags
            // Never swallowed: AppKit tracks modifier state from these, and a
            // window that stops seeing them is one that thinks ⌘ is still down
            // long after it was let go.
            return false

        default:
            return false
        }
    }

    /// Say, once per key code, that a key was dropped instead of sent.
    ///
    /// `keyCodeMap` is a US layout and nothing more: no numpad, nothing from F13
    /// upwards, and not the extra key an ISO keyboard carries beside the left
    /// shift. Anything missing from it is handed back to AppKit and never
    /// reaches the host, and from the user's side of the picture that is
    /// indistinguishable from the streamed application ignoring the key — a
    /// dead key, with nothing in any log to say so. This does not map anything;
    /// it only turns a silent drop into a line naming the macOS key code, which
    /// is the one fact needed to add it. Once per code, because a key held down
    /// repeats and the report is worth no more the hundredth time.
    private func noteUnmapped(_ keyCode: UInt16) {
        guard reportedUnmappedKeys.insert(keyCode).inserted else { return }
        let hex = String(keyCode, radix: 16, uppercase: true)
        Log.warning("[input] macOS key code 0x\(hex) is not in the US-layout key map,"
                    + " so it was not sent to the host")
    }

    /// Let go of anything pressed during a ⌘ chord, now that ⌘ itself is up.
    ///
    /// Belt and braces against the one macOS behaviour that would leave a key
    /// stuck down on the host: key-up delivery while Command is held. If the
    /// key-ups did arrive there is nothing here to release.
    private func releaseChordKeys() {
        for code in chordKeys {
            heldKeys.remove(code)
            onInput?(SMTInput.key(code: code, pressed: false, modifiers: []))
        }
        chordKeys.removeAll()
    }

    /// Release everything still held when focus leaves. Without this the host
    /// keeps the key down — and Windows auto-repeats a key it never sees
    /// released, so a single missed key-up types forever.
    private func releaseHeldInput() {
        for code in heldKeys {
            onInput?(SMTInput.key(code: code, pressed: false, modifiers: []))
        }
        heldKeys.removeAll()
        chordKeys.removeAll()

        for button in heldButtons {
            onInput?(SMTInput.mouseButton(button, pressed: false))
        }
        heldButtons.removeAll()

        // Deduplicated: Control and Command share a Windows key code, so a hand
        // holding both would otherwise send two ups for it.
        var released: Set<UInt16> = []
        for key in modifierKeys where (lastDeviceFlags & key.deviceMask) != 0 {
            guard released.insert(key.windowsKeyCode).inserted else { continue }
            onInput?(SMTInput.key(code: key.windowsKeyCode, pressed: false, modifiers: []))
        }
        lastModifierFlags = []
        lastDeviceFlags = 0
    }

    /// The modifier bitmask that rides along with a key event.
    ///
    /// Command reports as Control, matching the key codes: a packet that said
    /// "Control is not down" while sending Control's key code would describe a
    /// keyboard nobody is holding. `.meta` is never set — that bit means the
    /// Windows key, which no key on this Mac can reach.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> SMTInput.Modifiers {
        var result: SMTInput.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) || flags.contains(.command) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.alt) }
        return result
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> SMTInput.Modifiers {
        Self.modifiers(from: flags)
    }

    // MARK: - Mouse

    /// A hint that the macOS window frame is being dragged.
    ///
    /// Pointer input pauses for the duration: the user is resizing the window,
    /// not working in the application, and the pointer sitting on the host
    /// window's own edge while both sides are being resized makes the host start
    /// a resize of its own on top of ours.
    ///
    /// A HINT, AND NOT THE ANSWER ON ITS OWN. This used to be the whole gate,
    /// set from `windowWillStartLiveResize` and cleared from
    /// `windowDidEndLiveResize` — and AppKit does not guarantee that pair. A drag
    /// interrupted by the window being closed, by the frame being set from the
    /// host mid-drag, or by anything else that ends the resize session another
    /// way leaves the flag set, and then the pointer is dead for the rest of the
    /// window's life. Every symptom of that is "I can resize the window but I
    /// cannot click or scroll in it", with the video still perfect and not one
    /// line in any log to say why. `inLiveResize` is the same fact asked of
    /// AppKit instead of remembered, so it cannot get stuck.
    public var isSuspended = false

    /// Pointer events dropped because a resize was in progress. Reported with
    /// the rest of the input counters, so a pause that never ended is visible
    /// rather than deduced.
    public private(set) var droppedWhileResizing: UInt64 = 0

    /// Emit one absolute pointer position from a unit point inside the picture,
    /// through the same crop, guard and canvas mapping a real mouse move uses.
    ///
    /// For `--test-input`. Only the whole-desktop mirror could be driven before
    /// this, and that is not the path anyone uses — so the application-window
    /// path, which is every real session, had never once had its pointer proven
    /// end to end.
    @discardableResult
    public func sendUnitPosition(x: Double, y: Double) -> Bool {
        guard let source = sourceRect, let canvas = canvasSize,
              canvas.width > 0, canvas.height > 0 else { return false }
        let target = Self.canvasPoint(unit: CGPoint(x: x, y: y), source: source,
                                      edgeGuard: edgeGuard)
        positionsSent += 1
        onInput?(SMTInput.mouseMoveAbsolute(x: Int(target.x.rounded()),
                                            y: Int(target.y.rounded()),
                                            referenceWidth: Int(canvas.width),
                                            referenceHeight: Int(canvas.height)))
        return true
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard isCapturing, let view = targetView else { return }
        // The monitor is application-wide, so with two streamed windows open a
        // click on the other one arrives here too — and converted into THIS
        // view's coordinates it lands somewhere arbitrary on the host. A button
        // already held is the exception: its release must always get through,
        // or the host is left with a button stuck down.
        if let window = event.window, window !== view.window, heldButtons.isEmpty {
            return
        }
        if isSuspended || view.inLiveResize || (view.window?.inLiveResize ?? false) {
            droppedWhileResizing &+= 1
            // The flag alone is not trusted: if nothing is actually being
            // dragged, whatever set it has gone away without clearing it.
            if isSuspended && !view.inLiveResize && !(view.window?.inLiveResize ?? false) {
                isSuspended = false
                Log.info("[input] the resize pause outlived the resize; resuming"
                         + " (\(droppedWhileResizing) pointer events dropped)")
            } else {
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
            if let button = button(for: event) {
                heldButtons.insert(button)
                onInput?(SMTInput.mouseButton(button, pressed: true))
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            sendPosition(for: event, in: view)
            if let button = button(for: event) {
                heldButtons.remove(button)
                onInput?(SMTInput.mouseButton(button, pressed: false))
            }

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
            // Windows counts a wheel click as 120 units, and macOS reports the
            // two kinds of scroll in different units: a trackpad gives points,
            // a wheel mouse gives lines, one line per detent. Sending both at
            // the trackpad's scale meant a real mouse wheel moved the host a
            // tenth of a notch per click -- technically scrolling, in practice
            // a wheel that does nothing.
            let unit: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 120
            let vertical = Int((event.scrollingDeltaY * unit).rounded())
            let horizontal = Int((event.scrollingDeltaX * unit).rounded())
            if vertical != 0 { onInput?(SMTInput.scroll(amount: vertical)) }
            if horizontal != 0 { onInput?(SMTInput.horizontalScroll(amount: horizontal)) }

        default:
            break
        }
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

        let source = sourceRect ?? CGRect(origin: .zero, size: canvasSize ?? bounds.size)
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
        guard let unit = mapped else { return false }

        let target = Self.canvasPoint(unit: unit, source: source, edgeGuard: edgeGuard)
        let x = Int(target.x.rounded())
        let y = Int(target.y.rounded())

        positionsSent += 1
        onInput?(SMTInput.mouseMoveAbsolute(x: x, y: y,
                                                 referenceWidth: Int(canvas.width),
                                                 referenceHeight: Int(canvas.height)))
        return true
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
        guard viewSize.width > 0, viewSize.height > 0,
              source.width > 0, source.height > 0 else { return nil }

        let fit = min(viewSize.width / source.width, viewSize.height / source.height)
        let shown = CGSize(width: source.width * fit, height: source.height * fit)
        guard shown.width > 0, shown.height > 0 else { return nil }

        let inset = CGPoint(x: (viewSize.width - shown.width) / 2,
                            y: (viewSize.height - shown.height) / 2)
        // macOS is bottom-left origin, Windows is top-left, hence the flip.
        let fromTop = isFlipped ? viewPoint.y : viewSize.height - viewPoint.y

        let unit = CGPoint(x: (viewPoint.x - inset.x) / shown.width,
                           y: (fromTop - inset.y) / shown.height)
        guard (0...1).contains(unit.x), (0...1).contains(unit.y) else { return nil }
        return unit
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

    /// The same mapping, but pinned to the edge instead of refused when the
    /// point falls outside the picture.
    static func clampedUnitPoint(viewPoint: CGPoint, viewSize: CGSize,
                                 source: CGRect, isFlipped: Bool) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0,
              source.width > 0, source.height > 0 else { return nil }

        let fit = min(viewSize.width / source.width, viewSize.height / source.height)
        let shown = CGSize(width: source.width * fit, height: source.height * fit)
        guard shown.width > 0, shown.height > 0 else { return nil }

        let inset = CGPoint(x: (viewSize.width - shown.width) / 2,
                            y: (viewSize.height - shown.height) / 2)
        let fromTop = isFlipped ? viewPoint.y : viewSize.height - viewPoint.y
        return CGPoint(x: min(max((viewPoint.x - inset.x) / shown.width, 0), 1),
                       y: min(max((fromTop - inset.y) / shown.height, 0), 1))
    }

    private func button(for event: NSEvent) -> SMTInput.MouseButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp: return event.buttonNumber == 2 ? .middle : nil
        default: return nil
        }
    }
}
