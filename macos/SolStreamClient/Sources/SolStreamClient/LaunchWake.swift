import Foundation

/// Waking a sleeping PC for a launcher.
///
/// A Dock launcher clicked while the PC sleeps used to show "not answering"
/// in red and leave it there: the Connect window's Wake button was the only
/// way to wake it, and the launcher never goes through that window. Now the
/// wake goes out by itself, the picker says the PC is waking, and the
/// connection is tried again every few seconds until the PC answers or a
/// minute is up -- when the picker lists the app, it opens as before.
final class LaunchWake {
    /// How long a PC is given to wake, as the Connect window gives it.
    static let wait: TimeInterval = 60
    /// How often the connection is tried meanwhile.
    static let retryEvery: TimeInterval = 5

    /// What to do on a tick `elapsed` seconds after the wake went out.
    enum Step: Equatable { case retry, giveUp }

    static func step(elapsed: TimeInterval) -> Step {
        elapsed < wait ? .retry : .giveUp
    }

    /// What the picker says while it waits.
    static func waking(_ host: String, app: String) -> String {
        "Waking \(host) to open \(app)… This can take up to a minute."
    }

    /// What it says when the minute is up.
    static func gaveUp(_ host: String) -> String {
        "\(host) didn't wake. Wake-on-LAN may be off on it, or it's on another network, "
            + "or nobody is signed in to Windows."
    }

    private let startedAt: Date
    private var timer: Timer?

    /// Starts retrying at once; `retry` and `gaveUp` run on the main thread.
    init(retry: @escaping () -> Void, gaveUp: @escaping () -> Void) {
        startedAt = Date()
        let timer = Timer(timeInterval: Self.retryEvery, repeats: true) { [weak self] _ in
            guard let self else { return }
            switch Self.step(elapsed: Date().timeIntervalSince(self.startedAt)) {
            case .retry:
                retry()
            case .giveUp:
                self.stop()
                gaveUp()
            }
        }
        // Common modes: a menu held open does not hold up the wait.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var isRunning: Bool { timer != nil }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}
