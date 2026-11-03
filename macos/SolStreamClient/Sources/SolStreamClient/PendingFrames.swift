import Foundation

/// Frames waiting for the decoder, in the order they came.
///
/// Every frame but an IDR builds on the one before, so none is skipped: an IDR
/// replaces whatever still waits -- nothing before it is needed any more --
/// and a backlog the decoder cannot catch up with is dropped whole, after which
/// nothing is let through until the next IDR, which the caller asks for.
struct PendingFrames {
    /// More than this waiting is a decoder that has stalled -- a rebuild after
    /// a wake, a hardware queue that will not empty -- not one a frame behind.
    static let maxBacklog = 8

    enum Verdict: Equatable { case queued, droppedFrame, droppedBacklog }

    private(set) var frames: [(data: Data, isIdr: Bool)] = []
    private var waitingForIdr = false
    private var stopped = false

    var hasFrames: Bool { !frames.isEmpty }

    mutating func push(_ data: Data, isIdr: Bool) -> Verdict {
        guard !stopped else { return .droppedFrame }
        if isIdr {
            frames.removeAll()
            waitingForIdr = false
            frames.append((data, true))
            return .queued
        }
        if waitingForIdr { return .droppedFrame }
        if frames.count >= Self.maxBacklog {
            frames.removeAll()
            waitingForIdr = true
            return .droppedBacklog
        }
        frames.append((data, false))
        return .queued
    }

    mutating func takeAll() -> [(data: Data, isIdr: Bool)] {
        defer { frames.removeAll() }
        return frames
    }

    /// No more frames, and those waiting are dropped.
    mutating func stop() {
        stopped = true
        frames.removeAll()
    }
}
