import Foundation

/// Waking a sleeping PC for a launcher.
///
/// A Dock launcher clicked while the PC sleeps used to show "not answering"
/// in red and leave it there: the Connect window's Wake button was the only
/// way to wake it, and the launcher never goes through that window. Now the
/// wake goes out by itself, the picker says the PC is waking, and the
/// connection is tried again every few seconds until the PC answers --
/// when the picker lists the app, it opens as before. After a minute the
/// picker says the PC didn't wake, and it is tried every half minute after
/// that, so a PC slow to wake, or woken by hand, is still picked up.
final class LaunchWake {
    /// How long a PC is given to wake, as the Connect window gives it.
    static let wait: TimeInterval = 60
    /// How often the connection is tried meanwhile.
    static let retryEvery: TimeInterval = 5
    /// How often, in ticks, once the minute is up.
    static let slowTicks = 6

    /// What to do on tick `tick` (from 1), `elapsed` seconds after the wake
    /// went out, `saidSo` once the picker has said the PC didn't wake.
    enum Step: Equatable { case retry, sayNotWoken, rest }

    static func step(elapsed: TimeInterval, saidSo: Bool, tick: Int) -> Step {
        if elapsed < wait { return .retry }
        if !saidSo { return .sayNotWoken }
        return tick % slowTicks == 0 ? .retry : .rest
    }

    /// What the picker says while it waits.
    static func waking(_ host: String, app: String) -> String {
        "Waking \(host) to open \(app)… This can take up to a minute."
    }

    /// What it says when the minute is up.
    static func notWoken(_ host: String) -> String {
        "\(host) hasn't woken. Wake-on-LAN may be off on it, or it's on another network, "
            + "or nobody is signed in to Windows. SolStream keeps trying while this is open."
    }

    private let startedAt: Date
    private var timer: Timer?
    private var tick = 0
    private var saidSo = false

    /// Starts retrying at once; `retry` and `notWoken` run on the main thread.
    /// Runs until stopped: when the PC answers, or the picker goes.
    init(retry: @escaping () -> Void, notWoken: @escaping () -> Void) {
        startedAt = Date()
        let timer = Timer(timeInterval: Self.retryEvery, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            switch Self.step(elapsed: Date().timeIntervalSince(self.startedAt),
                             saidSo: self.saidSo, tick: self.tick) {
            case .retry:
                retry()
            case .sayNotWoken:
                self.saidSo = true
                notWoken()
            case .rest:
                break
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
