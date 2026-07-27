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

    /// The user's preference, applied to every host.
    static var hidePreferred: Bool {
        get { UserDefaults.standard.bool(forKey: preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// What we last left this host's cursor doing.
    static func believedHidden(for host: String) -> Bool {
        UserDefaults.standard.bool(forKey: beliefKey(for: host))
    }

    private static func setBelief(_ hidden: Bool, for host: String) {
        UserDefaults.standard.set(hidden, forKey: beliefKey(for: host))
    }

    /// Bring a host into line with the preference, sending the shortcut only if
    /// it is not already there. Call from `onControlConnected`, not from the
    /// streaming phase: video can be arriving before the channel these keys
    /// travel on exists.
    static func apply(to connection: StreamConnection, host: String) {
        guard hidePreferred != believedHidden(for: host) else { return }
        flip(on: connection, host: host)
    }

    /// Flip the host cursor, recording the new belief only if the keys actually
    /// went out.
    ///
    /// The belief used to be recorded unconditionally, which is worse than not
    /// tracking it at all: a send that went nowhere left the client certain the
    /// host had changed, so it never tried again and the setting appeared to do
    /// nothing for the rest of that host's life.
    @discardableResult
    static func flip(on connection: StreamConnection, host: String) -> Bool {
        guard sendShortcut(on: connection) else {
            Log.error("[cursor] control channel not ready; cursor preference not applied")
            return false
        }
        let nowHidden = !believedHidden(for: host)
        setBelief(nowHidden, for: host)
        Log.info("[cursor] asked \(host) to \(nowHidden ? "hide" : "show") its cursor")
        return true
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
