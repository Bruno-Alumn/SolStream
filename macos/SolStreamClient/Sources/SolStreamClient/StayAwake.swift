import Foundation

/// Keeps the Mac's display on while a stream is open.
///
/// A film watched in a streamed browser is a stream nobody touches the Mac
/// through, and nothing said the Mac was busy: after the display-off idle time
/// the screen went dark, and if the Mac then slept, the stream dropped and came
/// back to a frozen frame until the watchdogs gave up on it. An activity with
/// idle display sleep disabled is what a video player holds, and it lets the
/// Mac sleep when the lid closes or the user asks.
final class StayAwake {
    private let begin: (String) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?

    init(begin: @escaping (String) -> NSObjectProtocol = {
             ProcessInfo.processInfo.beginActivity(
                 options: [.idleDisplaySleepDisabled, .userInitiated], reason: $0)
         },
         end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin
        self.end = end
    }

    var isHeld: Bool { activity != nil }

    /// Held once however often it is asked: Switch App and Retry start a
    /// stream over one already held.
    func hold() {
        guard activity == nil else { return }
        activity = begin("Streaming from the PC")
    }

    func release() {
        guard let activity else { return }
        end(activity)
        self.activity = nil
    }

    deinit { release() }
}
