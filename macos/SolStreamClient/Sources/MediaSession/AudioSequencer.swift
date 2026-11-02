import Foundation

/// Which sound packets to play, by their sequence numbers.
///
/// They were played in the order they arrived: a late one out of order, a
/// duplicate twice, and a lost one not at all, the timeline closing up over
/// the hole. The host numbers only the packets it sends -- silence it skips
/// is not numbered -- so a gap is loss.
public struct AudioSequencer: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Play it, after `missing` packets' worth of silence.
        case play(missing: Int)
        /// Already played, or older than one that was.
        case drop
    }

    /// A jump this large is not loss but a new count -- a host restarted
    /// within the session -- and is taken as the new start.
    static let resetGap = 256

    private var last: UInt32?

    public init() {}

    public mutating func admit(_ sequence: UInt32) -> Decision {
        guard let last else {
            self.last = sequence
            return .play(missing: 0)
        }
        let step = Int32(bitPattern: sequence &- last)
        if step <= 0 && -Int(step) < Self.resetGap { return .drop }
        self.last = sequence
        if step <= 0 || Int(step) > Self.resetGap { return .play(missing: 0) }
        return .play(missing: Int(step) - 1)
    }
}
