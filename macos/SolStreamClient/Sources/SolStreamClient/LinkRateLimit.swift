import Foundation

/// How many links from the PC are opened: ten in any minute, and the rest
/// held back, the first of them said so the person knows why a click did
/// nothing.
struct LinkRateLimit {
    enum Verdict: Equatable { case open, firstHeldBack, heldBack }

    static let perMinute = 10
    static let note = "SolStream held back some links from the PC: more than ten opened in a "
        + "minute. Click them again in a moment."

    private var opened: [Date] = []
    private var told = false

    mutating func take(at now: Date) -> Verdict {
        opened.removeAll { now.timeIntervalSince($0) >= 60 }
        if opened.count < Self.perMinute {
            opened.append(now)
            if opened.count == 1 { told = false }
            return .open
        }
        if told { return .heldBack }
        told = true
        return .firstHeldBack
    }
}
