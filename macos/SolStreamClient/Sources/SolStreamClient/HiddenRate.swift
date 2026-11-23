import Foundation

/// When to ask the PC for fewer pictures, and when for the full rate again.
///
/// With every stream window minimised, on another Space or covered, nothing
/// the PC sends is seen, and it went on capturing, encoding and sending 60 a
/// second -- the GPU, the network and this Mac's decoder all busy for no one.
/// Two seconds of that and the PC is asked for `hiddenRate`; the moment any
/// window can be seen again it is asked for the full rate, and the picture it
/// sends first is a keyframe. Two seconds, so a window dragged across a Space
/// or under another for a moment does not change anything.
///
/// The PC answers launches on the same thread as everything else, so a
/// request sent behind one waits for it: nothing is lowered while a launch is
/// out, and the full rate is asked for before one goes. A new media session
/// -- a recovery, a reconnect, new settings -- starts at the full rate, so it
/// is lowered again if the windows are still out of sight. Pure, for the
/// tests: the owner feeds it what it sees and does what it says.
struct HiddenRate: Equatable {
    /// Pictures a second while nothing is seen: enough that the decoder,
    /// the watchdog (a second with none is a stall) and the PC's own encoder
    /// check (three seconds with none is a broken encoder) never take it for
    /// trouble.
    static let hiddenRate = 5
    /// How long everything has to be out of sight first.
    static let delay: TimeInterval = 2

    enum Action: Equatable {
        case none
        /// Ask the PC for `hiddenRate`.
        case lower
        /// Ask the PC for the session's own rate.
        case restore
        /// Ask again in this many seconds: everything is out of sight, but
        /// not for long enough yet.
        case check(after: TimeInterval)
    }

    /// Since when nothing has been seen; nil while something is.
    private(set) var hiddenSince: TimeInterval?
    /// The PC was asked for `hiddenRate`, and not since for the full rate.
    private(set) var lowered = false

    /// What to do, given whether any stream window can be seen and whether
    /// a launch is out, at `now` (any steady clock, in seconds).
    mutating func update(anyShown: Bool, launching: Bool, now: TimeInterval) -> Action {
        guard !anyShown else {
            hiddenSince = nil
            return restoreIfLowered()
        }
        if hiddenSince == nil { hiddenSince = now }
        // A launch holds the channel: a restore asked behind it would wait
        // for it, so the full rate goes first, and nothing is lowered until
        // it is answered.
        guard !launching else { return restoreIfLowered() }
        guard !lowered else { return .none }
        let waited = now - (hiddenSince ?? now)
        guard waited >= Self.delay else { return .check(after: Self.delay - waited) }
        lowered = true
        return .lower
    }

    /// A new media session, which the PC starts at its own rate. What is out
    /// of sight stays so, and is lowered again at the next `update`.
    mutating func sessionStarted() {
        lowered = false
    }

    private mutating func restoreIfLowered() -> Action {
        guard lowered else { return .none }
        lowered = false
        return .restore
    }
}
