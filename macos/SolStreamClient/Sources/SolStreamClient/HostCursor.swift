import AppKit
import Foundation

/// Which macOS cursor stands in for the Windows one.
///
/// The host captures without its pointer (IsCursorCaptureEnabled(false)) and
/// pushes the cursor's shape instead, so this Mac draws a real, local cursor
/// with no round trip behind it.
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
