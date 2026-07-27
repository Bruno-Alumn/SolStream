import AppKit
import Carbon
import StreamConnection

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
    /// coordinates: Sunshine rescales from the reference rectangle we declare
    /// onto the captured display, and it knows nothing about our crop.
    public var sourceRect: CGRect?
    public var canvasSize: CGSize?

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

    /// Modifier keys need their own left/right virtual key codes, and each one
    /// maps to the flag whose transition announces it.
    private struct ModifierKey {
        let macKeyCode: UInt16
        let windowsKeyCode: UInt16
        /// The DEVICE-DEPENDENT mask for this specific physical key. The public
        /// flags (.shift, .control…) are shared by the left and right keys, so
        /// releasing one while the other is held reads as "still down" and
        /// would emit a key DOWN — leaving that key stuck on the host forever.
        let deviceMask: UInt
    }

    private let modifierKeys: [ModifierKey] = [
        ModifierKey(macKeyCode: 0x38, windowsKeyCode: 0xA0, deviceMask: 0x0000_0002),  // L shift
        ModifierKey(macKeyCode: 0x3C, windowsKeyCode: 0xA1, deviceMask: 0x0000_0004),  // R shift
        ModifierKey(macKeyCode: 0x3B, windowsKeyCode: 0xA2, deviceMask: 0x0000_0001),  // L ctrl
        ModifierKey(macKeyCode: 0x3E, windowsKeyCode: 0xA3, deviceMask: 0x0000_2000),  // R ctrl
        ModifierKey(macKeyCode: 0x3A, windowsKeyCode: 0xA4, deviceMask: 0x0000_0020),  // L alt
        ModifierKey(macKeyCode: 0x3D, windowsKeyCode: 0xA5, deviceMask: 0x0000_0040),  // R alt
        ModifierKey(macKeyCode: 0x37, windowsKeyCode: 0x5B, deviceMask: 0x0000_0008),  // L cmd → L win
        ModifierKey(macKeyCode: 0x36, windowsKeyCode: 0x5C, deviceMask: 0x0000_0010),  // R cmd → R win
    ]

    /// Counters that separate "AppKit never delivered the event" from
    /// "delivered but rejected", which are otherwise indistinguishable.
    public private(set) var mouseMovedSeen = 0
    public private(set) var positionsSent = 0

    /// Non-modifier keys currently held, so they can be released on focus loss.
    /// Sunshine hands key-down straight to SendInput, and Windows auto-repeats
    /// a key it never sees released — so a missed key-up repeats forever.
    private var heldKeys: Set<UInt16> = []

    public init() {}

    deinit {
        disableCapture()
    }

    /// Attach to the view whose bounds define the input coordinate space.
    public func attach(to view: NSView) {
        self.targetView = view
    }

    /// Enable capture. Called when the window becomes key.
    public func enableCapture() {
        guard !isCapturing, targetView?.window != nil else { return }
        isCapturing = true
        installMonitors()
    }

    /// Disable capture. Called when the window resigns key.
    public func disableCapture() {
        guard isCapturing else { return }
        isCapturing = false
        releaseHeldKeys()
        removeMonitors()
    }

    // MARK: - Monitors

    private func installMonitors() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
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

    private func handleKeyEvent(_ event: NSEvent) {
        guard isCapturing else { return }

        switch event.type {
        case .keyDown, .keyUp:
            guard let windowsKey = keyCodeMap[event.keyCode] else { return }
            let pressed = event.type == .keyDown
            if pressed {
                heldKeys.insert(windowsKey)
            } else {
                heldKeys.remove(windowsKey)
            }
            onInput?(InputProtocol.key(code: windowsKey,
                                       pressed: pressed,
                                       modifiers: modifiers(from: event.modifierFlags)))

        case .flagsChanged:
            // A modifier press and release both arrive as .flagsChanged; which
            // it was is only knowable by diffing against the previous state —
            // and it must be diffed against the device-dependent bit for this
            // exact key, not the shared .shift/.control/... flag.
            let flags = event.modifierFlags
            let deviceFlags = flags.rawValue
            if let key = modifierKeys.first(where: { $0.macKeyCode == event.keyCode }) {
                let isDown = (deviceFlags & key.deviceMask) != 0
                onInput?(InputProtocol.key(code: key.windowsKeyCode,
                                           pressed: isDown,
                                           modifiers: modifiers(from: flags)))
            }
            lastModifierFlags = flags
            lastDeviceFlags = deviceFlags

        default:
            break
        }
    }

    /// Release everything still held when focus leaves. Without this the host
    /// keeps the key down — and Windows auto-repeats a key it never sees
    /// released, so a single missed key-up types forever.
    private func releaseHeldKeys() {
        for code in heldKeys {
            onInput?(InputProtocol.key(code: code, pressed: false, modifiers: []))
        }
        heldKeys.removeAll()

        for key in modifierKeys where (lastDeviceFlags & key.deviceMask) != 0 {
            onInput?(InputProtocol.key(code: key.windowsKeyCode, pressed: false, modifiers: []))
        }
        lastModifierFlags = []
        lastDeviceFlags = 0
    }

    private func modifiers(from flags: NSEvent.ModifierFlags) -> InputProtocol.Modifiers {
        var result: InputProtocol.Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.command) { result.insert(.meta) }
        return result
    }

    // MARK: - Mouse

    private func handleMouseEvent(_ event: NSEvent) {
        guard isCapturing, let view = targetView else { return }

        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if event.type == .mouseMoved { mouseMovedSeen += 1 }
            sendPosition(for: event, in: view)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Position first: Windows clicks wherever the pointer currently is.
            sendPosition(for: event, in: view)
            if let button = button(for: event) {
                onInput?(InputProtocol.mouseButton(button, pressed: true))
            }

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            sendPosition(for: event, in: view)
            if let button = button(for: event) {
                onInput?(InputProtocol.mouseButton(button, pressed: false))
            }

        case .scrollWheel:
            // Windows counts a wheel click as 120 units.
            let vertical = Int((event.scrollingDeltaY * 12).rounded())
            let horizontal = Int((event.scrollingDeltaX * 12).rounded())
            if vertical != 0 { onInput?(InputProtocol.scroll(amount: vertical)) }
            if horizontal != 0 { onInput?(InputProtocol.horizontalScroll(amount: horizontal)) }

        default:
            break
        }
    }

    /// Send the pointer position in the view's own coordinate space.
    ///
    /// The packet carries the reference rectangle alongside the coordinates and
    /// Sunshine rescales onto the captured surface, so view points work
    /// directly — no DPI or stream-resolution maths needed here. macOS
    /// coordinates are bottom-left origin, Windows is top-left, hence the flip.
    private func sendPosition(for event: NSEvent, in view: NSView) {
        let point = view.convert(event.locationInWindow, from: nil)
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        let source = sourceRect ?? CGRect(origin: .zero, size: canvasSize ?? bounds.size)
        let canvas = canvasSize ?? source.size
        guard canvas.width > 0, canvas.height > 0 else { return }

        // Ignore events outside the video surface rather than clamping them to
        // the edge, which would drag the host pointer along the border.
        guard let unit = Self.unitPoint(viewPoint: point, viewSize: bounds.size,
                                        source: source, isFlipped: view.isFlipped) else { return }

        let x = Int((source.minX + unit.x * source.width).rounded())
        let y = Int((source.minY + unit.y * source.height).rounded())

        positionsSent += 1
        onInput?(InputProtocol.mouseMoveAbsolute(x: x, y: y,
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

    private func button(for event: NSEvent) -> InputProtocol.MouseButton? {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: return .left
        case .rightMouseDown, .rightMouseUp: return .right
        case .otherMouseDown, .otherMouseUp: return event.buttonNumber == 2 ? .middle : nil
        default: return nil
        }
    }
}
