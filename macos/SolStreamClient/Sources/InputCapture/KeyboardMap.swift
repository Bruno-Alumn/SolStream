import Foundation

/// Where a key on this Mac's keyboard is on a PC's, in the two ways a host can
/// be told.
///
/// macOS key codes name physical positions -- kVK_ANSI_Z is the key at Z's
/// place on a US keyboard, whatever is printed on it -- so a key has one right
/// answer on a PC keyboard, and the question is only how to name it.
///
/// BY POSITION, as a set-1 scan code, is what a host that says "scancodes"
/// takes. Windows then reads the key through the PC's own layout exactly as it
/// does for a keyboard plugged into it: a German user's Z types 'z' on a
/// German PC, and a game bound to the key at W's place by scan code sees that
/// key whatever its label.
///
/// BY NAME, as a Windows virtual key, is all an older host takes. It names the
/// key at that position on a US keyboard, and Windows reads a virtual key by
/// its label in the PC's layout -- so anything but a US layout on the PC
/// scrambles letters and punctuation. Kept for those hosts, which it serves as
/// well as it ever did.
///
/// One table names every key both ways, so a key reaches a host of either kind.
enum KeyboardMap {
    typealias HostKey = InputCapture.HostKey

    /// A key by its set-1 scan code, with 0xE0 in the high byte for an
    /// extended key, then by its Windows virtual key -- the key's label on a
    /// US keyboard.
    private static func k(_ scanCode: UInt16, _ windowsKey: UInt16) -> HostKey {
        HostKey(windowsKey: windowsKey, scanCode: scanCode)
    }

    /// macOS key code → the key on a PC keyboard.
    ///
    /// The ISO keyboard's two odd keys are not here; see `hostKey`.
    private static let keys: [UInt16: HostKey] = [
        // Letters, at their positions on a US keyboard
        0x00: k(0x1E, 0x41),  // A
        0x0B: k(0x30, 0x42),  // B
        0x08: k(0x2E, 0x43),  // C
        0x02: k(0x20, 0x44),  // D
        0x0E: k(0x12, 0x45),  // E
        0x03: k(0x21, 0x46),  // F
        0x05: k(0x22, 0x47),  // G
        0x04: k(0x23, 0x48),  // H
        0x22: k(0x17, 0x49),  // I
        0x26: k(0x24, 0x4A),  // J
        0x28: k(0x25, 0x4B),  // K
        0x25: k(0x26, 0x4C),  // L
        0x2E: k(0x32, 0x4D),  // M
        0x2D: k(0x31, 0x4E),  // N
        0x1F: k(0x18, 0x4F),  // O
        0x23: k(0x19, 0x50),  // P
        0x0C: k(0x10, 0x51),  // Q
        0x0F: k(0x13, 0x52),  // R
        0x01: k(0x1F, 0x53),  // S
        0x11: k(0x14, 0x54),  // T
        0x20: k(0x16, 0x55),  // U
        0x09: k(0x2F, 0x56),  // V
        0x0D: k(0x11, 0x57),  // W
        0x07: k(0x2D, 0x58),  // X
        0x10: k(0x15, 0x59),  // Y
        0x06: k(0x2C, 0x5A),  // Z

        // The number row, 1 to 0
        0x12: k(0x02, 0x31), 0x13: k(0x03, 0x32), 0x14: k(0x04, 0x33),
        0x15: k(0x05, 0x34), 0x17: k(0x06, 0x35), 0x16: k(0x07, 0x36),
        0x1A: k(0x08, 0x37), 0x1C: k(0x09, 0x38), 0x19: k(0x0A, 0x39),
        0x1D: k(0x0B, 0x30),
        0x1B: k(0x0C, 0xBD),  // -
        0x18: k(0x0D, 0xBB),  // =

        // The punctuation around the letters, by its US label
        0x21: k(0x1A, 0xDB),  // [
        0x1E: k(0x1B, 0xDD),  // ]
        0x2A: k(0x2B, 0xDC),  // \  (on an ISO keyboard, the key left of Return)
        0x29: k(0x27, 0xBA),  // ;
        0x27: k(0x28, 0xDE),  // '
        0x2B: k(0x33, 0xBC),  // ,
        0x2F: k(0x34, 0xBE),  // .
        0x2C: k(0x35, 0xBF),  // /

        // Editing and navigation
        0x24: k(0x1C, 0x0D),    // Return
        0x30: k(0x0F, 0x09),    // Tab
        0x31: k(0x39, 0x20),    // Space
        0x33: k(0x0E, 0x08),    // Backspace
        0x35: k(0x01, 0x1B),    // Escape
        0x72: k(0xE052, 0x2D),  // Help, which is Insert on a PC keyboard plugged into a Mac
        0x75: k(0xE053, 0x2E),  // Forward delete
        0x73: k(0xE047, 0x24),  // Home
        0x77: k(0xE04F, 0x23),  // End
        0x74: k(0xE049, 0x21),  // Page up
        0x79: k(0xE051, 0x22),  // Page down
        0x7B: k(0xE04B, 0x25), 0x7C: k(0xE04D, 0x27),  // ← →
        0x7D: k(0xE050, 0x28), 0x7E: k(0xE048, 0x26),  // ↓ ↑
        0x6E: k(0xE05D, 0x5D),  // Menu (VK_APPS)

        // Function keys
        0x7A: k(0x3B, 0x70), 0x78: k(0x3C, 0x71), 0x63: k(0x3D, 0x72),
        0x76: k(0x3E, 0x73), 0x60: k(0x3F, 0x74), 0x61: k(0x40, 0x75),
        0x62: k(0x41, 0x76), 0x64: k(0x42, 0x77), 0x65: k(0x43, 0x78),
        0x6D: k(0x44, 0x79), 0x67: k(0x57, 0x7A), 0x6F: k(0x58, 0x7B),
        0x69: k(0x64, 0x7C), 0x6B: k(0x65, 0x7D),  // F13, F14
        0x71: k(0x66, 0x7E), 0x6A: k(0x67, 0x7F),  // F15, F16
        0x40: k(0x68, 0x80), 0x4F: k(0x69, 0x81),  // F17, F18
        0x50: k(0x6A, 0x82), 0x5A: k(0x6B, 0x83),  // F19, F20

        // The keypad. The host types its digits and point whatever the PC's
        // Num Lock says, as a Mac keypad always does -- an older host is sent
        // the digits as VK_NUMPAD0-9, which do the same -- and its '=', which a
        // PC keypad does not have, as the character. Clear is the key a PC
        // keyboard has Num Lock on, and is Num Lock to it.
        0x52: k(0x52, 0x60), 0x53: k(0x4F, 0x61), 0x54: k(0x50, 0x62),  // 0-2
        0x55: k(0x51, 0x63), 0x56: k(0x4B, 0x64), 0x57: k(0x4C, 0x65),  // 3-5
        0x58: k(0x4D, 0x66), 0x59: k(0x47, 0x67), 0x5B: k(0x48, 0x68),  // 6-8
        0x5C: k(0x49, 0x69),    // 9
        0x41: k(0x53, 0x6E),    // .
        0x43: k(0x37, 0x6A),    // *
        0x45: k(0x4E, 0x6B),    // +
        0x4E: k(0x4A, 0x6D),    // -
        0x4B: k(0xE035, 0x6F),  // /
        0x4C: k(0xE01C, 0x0D),  // Enter
        0x51: k(0x59, 0xBB),    // =, by name as the main keyboard's
        0x47: k(0x45, 0x90),    // Clear → Num Lock

        // JIS
        0x5D: k(0x7D, 0xDC),  // ¥ (VK_OEM_5 on a Japanese layout)
        0x5E: k(0x73, 0xE2),  // _ (ろ), VK_OEM_102
        // The keypad's comma; by name as the main keyboard's, since
        // VK_SEPARATOR typed nothing
        0x5F: k(0x7E, 0xBC),
        0x66: k(0xF1, 0x1A),  // 英数 (Eisu), which the host turns into IME off
        0x68: k(0xF2, 0x16),  // かな (Kana), which the host turns into IME on
    ]

    /// kVK_ISO_Section and kVK_ANSI_Grave.
    static let isoSection: UInt16 = 0x0A
    static let grave: UInt16 = 0x32

    /// The key left of 1 (VK_OEM_3, the US grave), and the one an ISO keyboard
    /// has between the left shift and Z (VK_OEM_102).
    private static let leftOfOne = k(0x29, 0xC0)
    private static let isoExtra = k(0x56, 0xE2)

    /// The key, or nil for a key a PC keyboard has no place for.
    ///
    /// - Parameter isISO: the key came from an ISO keyboard. macOS swaps two
    ///   key codes on those: the key left of 1 reports kVK_ISO_Section and the
    ///   key beside the left shift reports kVK_ANSI_Grave, the other way round
    ///   from what their names say. A US (ANSI) keyboard has no key beside the
    ///   shift and reports its grave key left of 1 as kVK_ANSI_Grave; a PC ISO
    ///   keyboard taken for ANSI reports its extra key as kVK_ISO_Section.
    static func hostKey(forMacKey code: UInt16, isISO: Bool) -> HostKey? {
        switch code {
        case isoSection: return isISO ? leftOfOne : isoExtra
        case grave: return isISO ? isoExtra : leftOfOne
        default: return keys[code]
        }
    }

    /// The key's scan code; see `hostKey`.
    static func scanCode(forMacKey code: UInt16, isISO: Bool) -> UInt16? {
        hostKey(forMacKey: code, isISO: isISO)?.scanCode
    }

    /// The key's Windows virtual key by its US label; see `hostKey`.
    static func windowsKey(forMacKey code: UInt16, isISO: Bool) -> UInt16? {
        hostKey(forMacKey: code, isISO: isISO)?.windowsKey
    }

    /// Every macOS key code the map names.
    static var mappedMacKeys: Set<UInt16> {
        Set(keys.keys).union([isoSection, grave])
    }
}
