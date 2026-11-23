import Foundation

/// What waits behind a launch on the agent channel.
///
/// The host answers `launch` only once the app has a window, up to half a
/// minute later, and it answers in order: a `focus` sent meanwhile for a
/// window already streaming is not done until the launch is. Ten clicks
/// between stream windows in that time were ten focuses, done one after the
/// other once the app was up, the keyboard ending wherever the last landed a
/// moment later. Held here instead, newest only, and sent once the last
/// launch has its answer. Pure, for the tests.
public struct LaunchHold: Equatable {
    /// Launches sent and not answered.
    public private(set) var launches = 0
    /// The window the newest focus asked for while a launch was out.
    public private(set) var heldFocus: UInt64?

    public init() {}

    public var isLaunching: Bool { launches > 0 }

    public mutating func launchStarted() {
        launches += 1
    }

    /// A launch has its answer. The focus to send now, when it was the last.
    public mutating func launchEnded() -> UInt64? {
        launches = max(0, launches - 1)
        guard launches == 0 else { return nil }
        defer { heldFocus = nil }
        return heldFocus
    }

    /// A focus is asked for. True when it goes now; false when it is held,
    /// in place of any held before.
    public mutating func focus(_ windowID: UInt64) -> Bool {
        guard isLaunching else { return true }
        heldFocus = windowID
        return false
    }
}
