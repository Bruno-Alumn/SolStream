import AppKit
import Foundation

/// Which macOS cursor stands in for the Windows one.
///
/// This file used to be about something else entirely: hiding the HOST's
/// cursor. Sunshine composited the Windows pointer into the video, so two
/// cursors were on screen at once and one of them was a round trip behind. It
/// had no setting for it and no way to report its current state — the only
/// control was a Ctrl+Alt+Shift+N shortcut that FLIPPED a process-global — so
/// this file carried a per-host belief about what the host was probably doing,
/// and a menu item to correct the belief when it drifted.
///
/// All of that is gone. SolStream's capture session is created with
/// IsCursorCaptureEnabled(false), so the host's pointer is never in the picture,
/// and the agent pushes the cursor's SHAPE so this Mac can draw a real one. What
/// is left is the shape mapping.
enum HostCursor {

    // MARK: - Shape

    /// The macOS cursor closest to a Windows one.
    ///
    /// Approximate by necessity: the two sets do not correspond. Windows has
    /// diagonal resize cursors and a four-way move cursor that AppKit exposes no
    /// public equivalent for before macOS 15, and macOS has no busy pointer an
    /// application is allowed to set — the spinner belongs to the system and
    /// means *this* app is not responding, which would be a lie. Those fall back
    /// to the arrow rather than to something that looks deliberate and is wrong.
    static func macCursor(for shape: String) -> NSCursor {
        switch shape {
        case "ibeam":      return .iBeam
        case "hand":       return .pointingHand
        case "crosshair":  return .crosshair
        case "resizeWE":   return .resizeLeftRight
        case "resizeNS":   return .resizeUpDown
        case "no":         return .operationNotAllowed
        case "uparrow":    return .resizeUp
        case "help":       return .contextualMenu
        // "wait", "appstarting", "move", "resizeNWSE", "resizeNESW" and anything
        // an application drew itself all land here.
        default:           return .arrow
        }
    }

}
