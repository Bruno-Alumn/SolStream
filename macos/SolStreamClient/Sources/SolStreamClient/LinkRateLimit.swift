import Foundation

/// How many links from the PC are opened: ten in any minute, and the rest
/// held back, the first of each run of them said so the person knows why a
/// click did nothing.
struct LinkRateLimit {
    enum Verdict: Equatable { case open, firstHeldBack, heldBack }

    static let perMinute = 10
    static let note = "SolStream held back some links from the PC: more than ten opened in a "
        + "minute. Click them again in a moment."

    /// When each of the last links opened, in seconds of a clock that only
    /// goes forward: the wall clock stepping back an hour would otherwise hold
    /// every link back for that hour.
    private var opened: [TimeInterval] = []
    private var told = false

    mutating func take(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Verdict {
        opened.removeAll { now - $0 >= 60 }
        if opened.count < Self.perMinute {
            opened.append(now)
            told = false
            return .open
        }
        if told { return .heldBack }
        told = true
        return .firstHeldBack
    }
}
