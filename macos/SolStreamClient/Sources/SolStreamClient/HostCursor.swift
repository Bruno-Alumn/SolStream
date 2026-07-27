import AppKit
import Foundation
import SolStreamLogging
import StreamConnection

/// Whether the host draws its own mouse cursor into the frames it sends.
///
/// Two cursors on screen is the default experience: macOS draws one locally and
/// Sunshine composites the Windows one into the video. They never quite line up,
/// because the remote one is a whole round trip behind, and the lag is most
/// obvious exactly when the pointer is moving. Hiding the host's leaves the
/// local cursor doing the work, which is what makes a streamed window feel like
/// a local one.
///
/// Sunshine has no configuration setting for this and no way to ask what it is
/// currently doing: `display_cursor` is a process-global that it *flips* when
/// the client sends Ctrl+Alt+Shift+N (`apply_shortcut` in `input.cpp`). It
/// swallows the N, so nothing reaches the application underneath.
///
/// A flip with no way to read the current value means the client has to
/// remember what it believes the host is doing, per host, and only send the
/// shortcut when the belief disagrees with the preference. That converges as
/// long as nothing else touches it. Two things can: pressing the shortcut on
/// the Windows machine directly, and restarting Sunshine, which puts the global
/// back to visible. Either leaves the belief one flip stale, and one use of the
/// menu item puts it right again.
enum HostCursor {
    private static let preferenceKey = "SolStream.hideHostCursor"

    private static func beliefKey(for host: String) -> String {
        "SolStream.hostCursorHidden.\(host)"
    }

    /// Hiding is the default. The point of the window is to feel like a local
    /// application, and two cursors — one of them a round trip behind — is the
    /// most obvious way it does not.
    ///
    /// Registered rather than written, so it remains a default the user can
    /// override rather than a value stored on their behalf. Call once at launch.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [preferenceKey: true])
    }

    /// The user's preference, applied to every host.
    static var hidePreferred: Bool {
        get { UserDefaults.standard.bool(forKey: preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// What we last left this host's cursor doing, and which Sunshine process we
    /// left it that way on.
    ///
    /// Stored together on purpose. `display_cursor` lives in Sunshine's process
    /// and starts out true, so a restart silently undoes whatever we did — and a
    /// belief that outlived the process it described is worse than none, because
    /// it stops the client ever trying again. Tying the two means a new instance
    /// simply reads as "visible", which is exactly what it is.
    static func believedHidden(for host: String, instance: String) -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: beliefKey(for: host)) else {
            return false
        }
        let parts = stored.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == instance else { return false }
        return parts[1] == "1"
    }

    private static func setBelief(_ hidden: Bool, for host: String, instance: String) {
        UserDefaults.standard.set("\(instance):\(hidden ? 1 : 0)", forKey: beliefKey(for: host))
    }

    /// Bring a host into line with the preference, sending the shortcut only if
    /// it is not already there. Call from `onControlConnected`, not from the
    /// streaming phase: video can be arriving before the channel these keys
    /// travel on exists.
    static func apply(to connection: StreamConnection, host: String, instance: String) {
        guard hidePreferred != believedHidden(for: host, instance: instance) else { return }
        flip(on: connection, host: host, instance: instance)
    }

    /// Flip the host cursor, recording the new belief only if the keys actually
    /// went out.
    ///
    /// The belief used to be recorded unconditionally, which is worse than not
    /// tracking it at all: a send that went nowhere left the client certain the
    /// host had changed, so it never tried again and the setting appeared to do
    /// nothing for the rest of that host's life.
    @discardableResult
    static func flip(on connection: StreamConnection, host: String, instance: String) -> Bool {
        guard sendShortcut(on: connection) else {
            Log.error("[cursor] control channel not ready; cursor preference not applied")
            return false
        }
        let nowHidden = !believedHidden(for: host, instance: instance)
        setBelief(nowHidden, for: host, instance: instance)
        Log.info("[cursor] asked \(host) to \(nowHidden ? "hide" : "show") its cursor")
        return true
    }

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

    // MARK: - The shortcut

    private static let leftControl: UInt16 = 0xA2
    private static let leftAlt: UInt16 = 0xA4
    private static let leftShift: UInt16 = 0xA0
    private static let letterN: UInt16 = 0x4E

    /// Ctrl+Alt+Shift+N as real key events.
    ///
    /// It has to be actual key-downs for the modifiers, not just the modifier
    /// bits on the N: Sunshine builds `shortcutFlags` in `update_shortcutFlags`
    /// from the key stream itself and only consults that, so a lone N carrying
    /// the right bitmask would be typed into the application instead.
    /// - Returns: false if there is no control channel yet, in which case
    ///   nothing was sent at all.
    private static func sendShortcut(on connection: StreamConnection) -> Bool {
        let held: InputProtocol.Modifiers = [.control, .alt, .shift]

        // The first send is the probe: if the control channel is not up, none of
        // the rest would arrive either, and half a modifier combination left on
        // the host would be worse than nothing.
        guard connection.sendInput(InputProtocol.key(code: leftControl, pressed: true,
                                                     modifiers: [.control])) else {
            return false
        }
        connection.sendInput(InputProtocol.key(code: leftAlt, pressed: true, modifiers: [.control, .alt]))
        connection.sendInput(InputProtocol.key(code: leftShift, pressed: true, modifiers: held))
        connection.sendInput(InputProtocol.key(code: letterN, pressed: true, modifiers: held))
        connection.sendInput(InputProtocol.key(code: letterN, pressed: false, modifiers: held))
        // Released in the reverse order, so the host never sees a modifier
        // outlive the combination it was part of.
        connection.sendInput(InputProtocol.key(code: leftShift, pressed: false, modifiers: [.control, .alt]))
        connection.sendInput(InputProtocol.key(code: leftAlt, pressed: false, modifiers: [.control]))
        connection.sendInput(InputProtocol.key(code: leftControl, pressed: false, modifiers: []))
        return true
    }
}
