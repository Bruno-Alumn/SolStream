import AppKit
import SolStreamLogging
import StreamConnection

/// Keeps the Mac's clipboard and the host's in step, in both directions.
///
/// Polled rather than pushed, because neither side offers a usable change
/// notification across a network: macOS exposes a change counter and Windows a
/// sequence number, and comparing two integers once a second costs nothing. Only a
/// change transfers anything.
///
/// The hard part is not copying text, it is not fighting yourself. Writing a value
/// to a clipboard bumps that clipboard's counter, which on the next tick looks
/// exactly like the user having copied something — so a naive version ping-pongs
/// the same string between the two machines forever. Every write records what was
/// written, and an observed change matching the last thing we wrote is ignored.
final class ClipboardBridge {
    private let agent: AgentConnection
    private let pasteboard = NSPasteboard.general

    private var timer: Timer?
    private var lastLocalChangeCount: Int
    private var lastRemoteSequence: Int?
    /// The last value this bridge put on either clipboard. An echo of it is ours,
    /// not the user's.
    private var lastSyncedText: String?
    private var inFlight = false

    var isEnabled = true

    init(agent: AgentConnection) {
        self.agent = agent
        self.lastLocalChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.info("[clipboard] syncing with the host")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isEnabled, !inFlight else { return }

        // Local change wins when both moved: the user is here, so what they just
        // copied on this machine is the more recent intent.
        if pasteboard.changeCount != lastLocalChangeCount {
            lastLocalChangeCount = pasteboard.changeCount
            let local = pasteboard.string(forType: .string)
            if let local, !local.isEmpty, local != lastSyncedText {
                lastSyncedText = local
                inFlight = true
                agent.setClipboard(local) { [weak self] sequence in
                    DispatchQueue.main.async {
                        self?.inFlight = false
                        // Adopt the sequence our own write produced, so it is not
                        // read back as a remote change on the next tick.
                        if let sequence { self?.lastRemoteSequence = sequence }
                    }
                }
                return
            }
        }

        inFlight = true
        agent.clipboard(since: lastRemoteSequence) { [weak self] remote in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard let remote else { return }
                self.lastRemoteSequence = remote.sequence
                guard !remote.isUnchanged, !remote.text.isEmpty,
                      remote.text != self.lastSyncedText else { return }

                self.lastSyncedText = remote.text
                self.pasteboard.clearContents()
                self.pasteboard.setString(remote.text, forType: .string)
                // Writing bumps the local counter; record it now so this write is
                // not mistaken for the user copying something next tick.
                self.lastLocalChangeCount = self.pasteboard.changeCount
                if remote.wasTruncated {
                    Log.info("[clipboard] host text was truncated at 1 MB")
                }
            }
        }
    }
}
