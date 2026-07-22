import AppKit
import Carbon

/// Captures local keyboard and mouse input via NSView event monitoring.
///
/// KEY DESIGN DECISION: This uses ONLY local NSView monitoring
/// (addLocalMonitorForEventsMatchingMask), NOT CGEventTap. This means:
/// - NO Accessibility permission required
/// - Input is only captured when the SolStream window is key/focused
/// - No risk of kCGEventTapDisabledByTimeout
/// - No risk of leaking local interactions to the remote host when unfocused
///
/// The input capture is enabled/disabled by the StreamWindow:
///   enabled = window is key (focused)
///   disabled = window is not key
public final class InputCapture {
    private weak var targetView: NSView?
    private var keyboardMonitor: Any?
    private var mouseMonitor: Any?
    private var isCapturing = false

    /// Key code translation table (macOS HID → Windows virtual key codes).
    /// This maps the most common keys. A full table is in the protocol spec.
    private let keyCodeMap: [UInt16: UInt8] = [
        // Letters (lowercase, same as uppercase in HID)
        0x00: 0x41,  // a
        0x0B: 0x42,  // b
        0x08: 0x43,  // c
        0x02: 0x44,  // d
        0x0E: 0x45,  // e
        0x03: 0x46,  // f
        0x05: 0x47,  // g
        0x04: 0x48,  // h
        0x22: 0x49,  // i
        0x26: 0x4A,  // j
        0x28: 0x4B,  // k
        0x25: 0x4C,  // l
        0x2E: 0x4D,  // m
        0x2D: 0x4E,  // n
        0x1F: 0x4F,  // o
        0x23: 0x50,  // p
        0x0C: 0x51,  // q
        0x0F: 0x52,  // r
        0x01: 0x53,  // s
        0x11: 0x54,  // t
        0x20: 0x55,  // u
        0x09: 0x56,  // v
        0x0D: 0x57,  // w
        0x07: 0x58,  // x
        0x10: 0x59,  // y
        0x06: 0x5A,  // z

        // Numbers
        0x1D: 0x30,  // 0
        0x12: 0x31,  // 1
        0x13: 0x32,  // 2
        0x14: 0x33,  // 3
        0x15: 0x34,  // 4
        0x17: 0x35,  // 5
        0x16: 0x36,  // 6
        0x1A: 0x37,  // 7
        0x1C: 0x38,  // 8
        0x19: 0x39,  // 9

        // Special keys
        0x24: 0x0D,  // Return
        0x30: 0x09,  // Tab
        0x31: 0x20,  // Space
        0x33: 0x08,  // Delete (Backspace)
        0x35: 0x1B,  // Escape
        0x37: 0x5B,  // Command → Left Windows key
        0x38: 0x10,  // Left Shift
        0x3A: 0x12,  // Left Alt (Option)
        0x3B: 0x11,  // Left Control
        0x3C: 0x10,  // Right Shift
        0x3D: 0x12,  // Right Alt (Option)
        0x3E: 0x11,  // Right Control

        // Arrow keys
        0x7B: 0x25,  // Left Arrow
        0x7C: 0x26,  // Right Arrow
        0x7D: 0x28,  // Down Arrow
        0x7E: 0x27,  // Up Arrow

        // Function keys
        0x7A: 0x70,  // F1
        0x78: 0x71,  // F2
        0x63: 0x72,  // F3
        0x76: 0x73,  // F4
        0x60: 0x74,  // F5
        0x61: 0x75,  // F6
        0x62: 0x76,  // F7
        0x64: 0x77,  // F8
        0x65: 0x78,  // F9
        0x6D: 0x79,  // F10
        0x67: 0x7A,  // F11
        0x6F: 0x7B,  // F12
    ]

    public init() {}

    deinit {
        disableCapture()
    }

    /// Attach input capture to a view. The view must be part of a window.
    public func attach(to view: NSView) {
        self.targetView = view
    }

    /// Enable input capture. Called when the window becomes key.
    public func enableCapture() {
        guard !isCapturing, targetView?.window != nil else { return }
        isCapturing = true
        installMonitors()
    }

    /// Disable input capture. Called when the window resigns key.
    public func disableCapture() {
        guard isCapturing else { return }
        isCapturing = false
        removeMonitors()
    }

    // MARK: - Private

    private func installMonitors() {
        guard let window = targetView?.window else { return }

        // Keyboard: local monitor captures all key events when window is focused.
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            self?.handleKeyEvent(event)
            return event  // Don't swallow — the window still needs the event
        }

        // Mouse: local monitor for mouse events.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                       .mouseMoved, .leftMouseDragged, .rightMouseDragged,
                       .scrollWheel]
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

    // MARK: - Event Handlers

    private func handleKeyEvent(_ event: NSEvent) {
        guard isCapturing else { return }

        switch event.type {
        case .keyDown:
            // Send key down
            if let vkCode = keyCodeMap[event.keyCode] {
                sendInput(.keyDown(vkCode))
            }
            // Handle command-key equivalents (for system shortcuts we let through)
            // We send the raw scancode for Windows to interpret.

        case .keyUp:
            if let vkCode = keyCodeMap[event.keyCode] {
                sendInput(.keyUp(vkCode))
            }

        case .flagsChanged:
            // Modifier keys (Shift, Control, Option, Command)
            let mods = event.modifierFlags
            let wasPressed: Bool = {
                // For flagsChanged, event.isARepeat indicates the new state
                // Actually, we track explicitly.
                return false  // Simplified for Phase 2
            }()
            // In a full implementation, track modifier state transitions.
            // For Phase 2, we send all flags on every flagsChanged event.
            let modifierFlags = encodeModifiers(mods)
            sendInput(.modifiers(modifierFlags))

        default:
            break
        }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard isCapturing, let view = targetView else { return }

        let location = view.convert(event.locationInWindow, from: nil)
        let localPoint = view.bounds

        // Convert to relative coordinates (0..1) for Windows DPI scaling.
        let relX = Float(location.x / localPoint.width)
        let relY = Float(location.y / localPoint.height)

        switch event.type {
        case .leftMouseDown:
            sendInput(.mouseButton(relX, relY, .left, true))
        case .leftMouseUp:
            sendInput(.mouseButton(relX, relY, .left, false))
        case .rightMouseDown:
            sendInput(.mouseButton(relX, relY, .right, true))
        case .rightMouseUp:
            sendInput(.mouseButton(relX, relY, .right, false))
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            sendInput(.mouseMove(relX, relY))
        case .scrollWheel:
            let deltaX = Float(event.scrollingDeltaX)
            let deltaY = Float(event.scrollingDeltaY)
            sendInput(.scrollWheel(deltaX, deltaY))
        default:
            break
        }
    }

    // MARK: - Input Encoding

    enum InputAction {
        case keyDown(UInt8)
        case keyUp(UInt8)
        case modifiers(UInt32)
        case mouseMove(Float, Float)           // relative X, Y (0..1)
        case mouseButton(Float, Float, MouseButton, Bool)
        case scrollWheel(Float, Float)          // delta X, delta Y
    }

    enum MouseButton {
        case left, right, middle
    }

    private func encodeModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.shift)     { result |= 0x01 }
        if flags.contains(.control)   { result |= 0x02 }
        if flags.contains(.option)    { result |= 0x04 }
        if flags.contains(.command)   { result |= 0x08 }
        return result
    }

    private func sendInput(_ action: InputAction) {
        // In Phase 2, this serializes the action into the binary input
        // protocol packet and sends it via UDP to the Windows host
        // (port 47990, AES-GCM encrypted).
        //
        // For now, this is a placeholder that encodes the action but
        // does not send it (no UDP socket yet — that's the StreamConnection's
        // responsibility in a full implementation).
        //
        // The input packet format is defined in the architecture spec:
        //   - Keyboard:  { type: 0x01, vkCode, flags }
        //   - Mouse:     { type: 0x02, relX, relY, buttons }
        //   - Scroll:    { type: 0x03, deltaX, deltaY }
        _ = action  // Placeholder — wire up to StreamConnection in full build.
    }
}
