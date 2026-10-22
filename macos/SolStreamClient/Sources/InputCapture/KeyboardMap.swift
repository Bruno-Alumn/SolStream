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
/// The two tables cover the same keys, so a key reaches a host of either kind.
enum KeyboardMap {
    /// macOS key code → set-1 scan code, with 0xE0 in the high byte for an
    /// extended key.
    ///
    /// The ISO keyboard's two odd keys are not here; see `scanCode`.
    private static let scanCodes: [UInt16: UInt16] = [
        // Letters, at their positions on a US keyboard
        0x00: 0x1E,  // A
        0x0B: 0x30,  // B
        0x08: 0x2E,  // C
        0x02: 0x20,  // D
        0x0E: 0x12,  // E
        0x03: 0x21,  // F
        0x05: 0x22,  // G
        0x04: 0x23,  // H
        0x22: 0x17,  // I
        0x26: 0x24,  // J
        0x28: 0x25,  // K
        0x25: 0x26,  // L
        0x2E: 0x32,  // M
        0x2D: 0x31,  // N
        0x1F: 0x18,  // O
        0x23: 0x19,  // P
        0x0C: 0x10,  // Q
        0x0F: 0x13,  // R
        0x01: 0x1F,  // S
        0x11: 0x14,  // T
        0x20: 0x16,  // U
        0x09: 0x2F,  // V
        0x0D: 0x11,  // W
        0x07: 0x2D,  // X
        0x10: 0x15,  // Y
        0x06: 0x2C,  // Z

        // The number row
        0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x17: 0x06,
        0x16: 0x07, 0x1A: 0x08, 0x1C: 0x09, 0x19: 0x0A, 0x1D: 0x0B,
        0x1B: 0x0C,  // -
        0x18: 0x0D,  // =

        // The punctuation around the letters
        0x21: 0x1A,  // [
        0x1E: 0x1B,  // ]
        0x2A: 0x2B,  // \  (on an ISO keyboard, the key left of Return)
        0x29: 0x27,  // ;
        0x27: 0x28,  // '
        0x2B: 0x33,  // ,
        0x2F: 0x34,  // .
        0x2C: 0x35,  // /

        // Editing and navigation
        0x24: 0x1C,    // Return
        0x30: 0x0F,    // Tab
        0x31: 0x39,    // Space
        0x33: 0x0E,    // Backspace
        0x35: 0x01,    // Escape
        0x72: 0xE052,  // Help, which is Insert on a PC keyboard plugged into a Mac
        0x75: 0xE053,  // Forward delete
        0x73: 0xE047,  // Home
        0x77: 0xE04F,  // End
        0x74: 0xE049,  // Page up
        0x79: 0xE051,  // Page down
        0x7B: 0xE04B, 0x7C: 0xE04D, 0x7D: 0xE050, 0x7E: 0xE048,  // ← → ↓ ↑
        0x6E: 0xE05D,  // Menu

        // Function keys
        0x7A: 0x3B, 0x78: 0x3C, 0x63: 0x3D, 0x76: 0x3E, 0x60: 0x3F, 0x61: 0x40,
        0x62: 0x41, 0x64: 0x42, 0x65: 0x43, 0x6D: 0x44, 0x67: 0x57, 0x6F: 0x58,
        0x69: 0x64, 0x6B: 0x65, 0x71: 0x66, 0x6A: 0x67,  // F13-F16
        0x40: 0x68, 0x4F: 0x69, 0x50: 0x6A, 0x5A: 0x6B,  // F17-F20

        // The keypad. The host types its digits and point whatever the PC's
        // Num Lock says, as a Mac keypad always does, and its '=' -- which a
        // PC keypad does not have -- as the character. Clear is the key a PC
        // keyboard has Num Lock on, and is Num Lock to it.
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B,  // 0-4
        0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47, 0x5B: 0x48, 0x5C: 0x49,  // 5-9
        0x41: 0x53,    // .
        0x43: 0x37,    // *
        0x45: 0x4E,    // +
        0x4E: 0x4A,    // -
        0x4B: 0xE035,  // /
        0x4C: 0xE01C,  // Enter
        0x51: 0x59,    // =
        0x47: 0x45,    // Clear

        // JIS
        0x5D: 0x7D,  // ¥
        0x5E: 0x73,  // _ (ろ)
        0x5F: 0x7E,  // the keypad's comma
        0x66: 0xF1,  // 英数 (Eisu), which the host turns into IME off
        0x68: 0xF2,  // かな (Kana), which the host turns into IME on
    ]

    /// macOS key code → Windows virtual key, by the key's label on a US
    /// keyboard. What a host that predates scan codes takes.
    ///
    /// The ISO keyboard's two odd keys are not here; see `windowsKey`.
    private static let windowsKeys: [UInt16: UInt16] = [
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
        0x72: 0x2D,  // Help → Insert
        0x75: 0x2E,  // Forward delete
        0x73: 0x24,  // Home
        0x77: 0x23,  // End
        0x74: 0x21,  // Page up
        0x79: 0x22,  // Page down
        0x7B: 0x25, 0x7C: 0x27, 0x7D: 0x28, 0x7E: 0x26,  // ← → ↓ ↑
        0x6E: 0x5D,  // Menu (VK_APPS)

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

        // Function keys
        0x7A: 0x70, 0x78: 0x71, 0x63: 0x72, 0x76: 0x73, 0x60: 0x74, 0x61: 0x75,
        0x62: 0x76, 0x64: 0x77, 0x65: 0x78, 0x6D: 0x79, 0x67: 0x7A, 0x6F: 0x7B,
        0x69: 0x7C, 0x6B: 0x7D, 0x71: 0x7E, 0x6A: 0x7F,  // F13-F16
        0x40: 0x80, 0x4F: 0x81, 0x50: 0x82, 0x5A: 0x83,  // F17-F20

        // The keypad. Digits as VK_NUMPAD0-9, which type digits whatever
        // the PC's Num Lock says.
        0x52: 0x60, 0x53: 0x61, 0x54: 0x62, 0x55: 0x63, 0x56: 0x64,
        0x57: 0x65, 0x58: 0x66, 0x59: 0x67, 0x5B: 0x68, 0x5C: 0x69,
        0x41: 0x6E,  // .
        0x43: 0x6A,  // *
        0x45: 0x6B,  // +
        0x4E: 0x6D,  // -
        0x4B: 0x6F,  // /
        0x4C: 0x0D,  // Enter
        0x51: 0xBB,  // =, as the main keyboard's
        0x47: 0x90,  // Clear → Num Lock

        // JIS
        0x5D: 0xDC,  // ¥ (VK_OEM_5 on a Japanese layout)
        0x5E: 0xE2,  // _ (VK_OEM_102)
        0x5F: 0xBC,  // the keypad's comma, as the main keyboard's; VK_SEPARATOR typed nothing
        0x66: 0x1A,  // Eisu → VK_IME_OFF
        0x68: 0x16,  // Kana → VK_IME_ON
    ]

    /// kVK_ISO_Section and kVK_ANSI_Grave.
    static let isoSection: UInt16 = 0x0A
    static let grave: UInt16 = 0x32

    /// The key left of 1, and the one an ISO keyboard has between the left
    /// shift and Z, by scan code.
    private static let scanLeftOfOne: UInt16 = 0x29
    private static let scanISOExtra: UInt16 = 0x56

    /// The key's scan code, or nil for a key a PC keyboard has no place for.
    ///
    /// - Parameter isISO: the key came from an ISO keyboard. macOS swaps two
    ///   key codes on those: the key left of 1 reports kVK_ISO_Section and the
    ///   key beside the left shift reports kVK_ANSI_Grave, the other way round
    ///   from what their names say. A US (ANSI) keyboard has no key beside the
    ///   shift and reports its grave key left of 1 as kVK_ANSI_Grave; a PC ISO
    ///   keyboard taken for ANSI reports its extra key as kVK_ISO_Section.
    static func scanCode(forMacKey code: UInt16, isISO: Bool) -> UInt16? {
        switch code {
        case isoSection: return isISO ? scanLeftOfOne : scanISOExtra
        case grave: return isISO ? scanISOExtra : scanLeftOfOne
        default: return scanCodes[code]
        }
    }

    /// The key's Windows virtual key by its US label, or nil for a key that
    /// has none. The same two keys swap as in `scanCode`: the key left of 1 is
    /// VK_OEM_3, the US grave, and the extra ISO key is VK_OEM_102.
    static func windowsKey(forMacKey code: UInt16, isISO: Bool) -> UInt16? {
        let leftOfOne: UInt16 = 0xC0, isoExtra: UInt16 = 0xE2
        switch code {
        case isoSection: return isISO ? leftOfOne : isoExtra
        case grave: return isISO ? isoExtra : leftOfOne
        default: return windowsKeys[code]
        }
    }

    /// Every macOS key code either table names, for the tests to hold the two
    /// tables to each other.
    static var mappedMacKeys: Set<UInt16> {
        Set(scanCodes.keys).union(windowsKeys.keys).union([isoSection, grave])
    }
}
