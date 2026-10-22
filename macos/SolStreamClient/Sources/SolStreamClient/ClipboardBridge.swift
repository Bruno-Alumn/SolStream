import AppKit
import SolStreamLogging
import MediaSession
import AgentChannel

/// Keeps the Mac's clipboard and the host's in step, in both directions.
///
/// Polled rather than pushed, because neither side offers a usable change
/// notification across a network: macOS exposes a change counter and Windows a
/// sequence number, and comparing two integers costs nothing. Only a change
/// transfers anything.
///
/// When it polls is what decides whether a paste gets the right text. ⌘V
/// reaches the PC over the media channel the moment it is pressed, and the
/// clipboard used to follow on the next one-second tick, so copying in Safari,
/// switching to the stream and pasting often pasted what the PC had before —
/// and the same the other way round. So a stream window taking the keyboard
/// sends a Mac copy that was held back at once, and one losing it brings the
/// PC's latest copy over at once, before the paste in the other application.
/// While a stream window has the keyboard, and for a moment after, the host is
/// asked four times a second; otherwise once.
///
/// The hard part is not copying text, it is not fighting yourself. Writing a value
/// to a clipboard bumps that clipboard's counter, which on the next tick looks
/// exactly like the user having copied something — so a naive version ping-pongs
/// the same string between the two machines forever. Every write records what was
/// written, and an observed change matching the last thing we wrote is ignored.
/// That record means "what both clipboards hold" and nothing else: the moment
/// either side holds something that did not cross, it is forgotten, so that
/// copying the old text again is a change worth sending.
///
/// One thing it deliberately does not carry, in either direction: a clipboard
/// that has become empty. The agent reports the host's clipboard as text, and a
/// clipboard holding an image — or a file, or anything else that is not text —
/// is reported as text that is empty, because the protocol has no way to say
/// "there is something here, it is simply not text". Copying that emptiness
/// across would therefore wipe the Mac's clipboard every time somebody copied a
/// picture on the PC, taking with it whatever they had copied a moment before.
/// So an empty value is left alone at both ends, and clearing one clipboard does
/// not clear the other. Distinguishing "empty" from "not text" needs a signal
/// the agent does not send yet.
///
/// Nothing a password manager copies crosses, in either direction. On the Mac
/// that is anything marked concealed, transient or auto-generated (the
/// nspasteboard.org convention, and the older names it lists); on the PC it is
/// the formats Windows defines for the same purpose, which the host checks and
/// answers as private. Mac to PC is narrower still: a Mac copy is sent only
/// once one of SolStream's windows has the keyboard — copying in another
/// application is not a request to put it on the PC, but switching to the
/// stream and pasting is. Nor is it sent the moment it is seen. A password
/// manager writes in steps, the text and then the marker that says it is a
/// password, and the change counter moves only at the first; read between
/// the two, a password looks like any other copy. So a copy waits out
/// `settleTime` from when it is first seen, and its types are read again
/// before it goes.
///
/// Each machine gets its own line endings: CRLF on the PC, where a bare LF is
/// no line break at all to a classic edit control, and LF here, where a CR
/// left over from Windows shows up in a terminal or an editor. Converted at
/// both ends, because either end may be a version that does not: the
/// conversions change nothing when applied twice.
final class ClipboardBridge {
    /// The two things the bridge asks of the host. Closures rather than the
    /// connection itself, so that the tests can answer for it.
    struct Host {
        var read: (_ since: Int?,
                   _ completion: @escaping (AgentConnection.RemoteClipboard?) -> Void) -> Void
        var write: (_ text: String, _ completion: @escaping (Int?) -> Void) -> Void

        init(read: @escaping (Int?, @escaping (AgentConnection.RemoteClipboard?) -> Void) -> Void,
             write: @escaping (String, @escaping (Int?) -> Void) -> Void) {
            self.read = read
            self.write = write
        }

        init(agent: AgentConnection) {
            self.init(read: { agent.clipboard(since: $0, completion: $1) },
                      write: { agent.setClipboard($0, completion: $1) })
        }
    }

    private let host: Host
    private let pasteboard: NSPasteboard

    private var timer: Timer?
    private var lastLocalChangeCount: Int
    private var lastRemoteSequence: Int?
    /// The last value this bridge put on either clipboard, while both still
    /// hold it. An echo of it is ours, not the user's. Kept in the Mac's line
    /// endings, so the PC's copy of the same text is recognised as the same.
    ///
    /// Forgotten once either side holds something that did not cross — a
    /// password, an image, a copy made while sync was off. Kept, it would turn
    /// away the same text copied again, and the paste would get what the
    /// other machine has instead.
    private var lastSyncedText: String?
    private var inFlight = false
    /// A sync asked for while a request was on the wire, run as soon as it is
    /// answered rather than left to the next tick.
    private var syncAgain = false
    /// The next answer from the host is a baseline to remember, not a change
    /// to copy over.
    private var adoptsRemoteBaseline = false
    /// Whether a Mac copy may go to the PC right now: one of the stream's
    /// windows has the keyboard.
    private let mayPush: () -> Bool

    /// Until when the host is asked every `briskInterval` rather than every
    /// `idleInterval`.
    private var briskUntil = Date.distantPast
    /// Until when the host is not asked at all, after it could not answer.
    /// Most often that is another program holding the PC's clipboard open,
    /// and the host spends up to a fifth of a second retrying before it says
    /// so, with its other commands -- focus, placement -- waiting behind it.
    /// Asked again at the brisk pace, that would be most of every second.
    private var quietUntil = Date.distantPast
    static let briskInterval: TimeInterval = 0.25
    static let idleInterval: TimeInterval = 1.0
    /// How long the brisk pace outlasts the stream having the keyboard. ⌘C
    /// pressed just before ⌘Tab can reach the PC's clipboard after the sync the
    /// switch itself asked for, and this is what still brings it over in time.
    private static let briskSpell: TimeInterval = 2.0

    /// How long a Mac copy keeps the same change count, from when the bridge
    /// first sees it, before it may be sent. A password manager's steps are
    /// moments apart; a ⌘V after a ⌘Tab is not that quick.
    static let settleTime: TimeInterval = 0.1
    private let settleTime: TimeInterval
    /// The Mac copy waiting out `settleTime`: its change count, and when the
    /// bridge first saw it.
    private var unsettledCopy: (changeCount: Int, seenAt: Date)?
    /// Looks at that copy again the moment it has settled, rather than at the
    /// next tick, while the stream has the keyboard: a paste may be waiting.
    private var settleTimer: Timer?

    private static let privateTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
        // The older names, from before the convention, which some
        // applications still set on their own: 1Password's, the one
        // TextExpander and Butler share, TypeIt4Me's and Typinator's.
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
        NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
        NSPasteboard.PasteboardType("com.typeit4me.clipping"),
        NSPasteboard.PasteboardType("Pasteboard generator type"),
    ]

    /// Whether a pasteboard holding these types is to stay on this Mac.
    ///
    /// `NSPasteboard.types` is the union over every item, so a marker on any
    /// one of them keeps the whole copy here.
    static func isPrivate(types: [NSPasteboard.PasteboardType]?) -> Bool {
        !privateTypes.isDisjoint(with: types ?? [])
    }

    // Both walk Unicode scalars rather than Characters: Swift treats CRLF as a
    // single Character, so a Character-wise search for "\n" never finds the
    // one inside it.

    /// Text as Windows keeps it: every LF preceded by a CR. One already
    /// preceded by a CR is left alone.
    static func windowsLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\n") else { return text }
        var out = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            if scalar == "\n" && previous != "\r" { out.append("\r") }
            out.append(scalar)
            previous = scalar
        }
        return String(out)
    }

    /// Text as the Mac keeps it: CRLF folded to LF, and with it any run of CRs
    /// before an LF — what an edit control's soft line break, or a CRLF
    /// converted twice, leaves. So what comes out holds no CRLF, and folding
    /// it again changes nothing. A CR not followed by an LF is left alone.
    static func macLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            // The CRs at the end of what is out so far are the ones right
            // before this LF.
            if scalar == "\n" {
                while out.last == "\r" { out.removeLast() }
            }
            out.append(scalar)
        }
        return String(out)
    }

    convenience init(agent: AgentConnection, mayPush: @escaping () -> Bool) {
        self.init(host: Host(agent: agent), pasteboard: .general, mayPush: mayPush)
    }

    /// - Parameter settleTime: `ClipboardBridge.settleTime`, other than in
    ///   the tests that are not about it.
    init(host: Host, pasteboard: NSPasteboard, settleTime: TimeInterval = ClipboardBridge.settleTime,
         mayPush: @escaping () -> Bool) {
        self.host = host
        self.pasteboard = pasteboard
        self.settleTime = settleTime
        self.mayPush = mayPush
        self.lastLocalChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    var isRunning: Bool { timer != nil }

    /// How often the host is being asked right now; nil while stopped.
    var pollInterval: TimeInterval? { timer?.timeInterval }

    /// - Parameter resuming: sync is being turned on in Settings with a stream
    ///   already open, rather than the stream opening with it on.
    ///
    /// Said by the caller rather than worked out here, because a bridge that
    /// has never run is not proof of a stream that is just opening: one that
    /// opened with sync off is built and left stopped, and turning sync on
    /// later is its first start.
    func start(resuming: Bool) {
        guard timer == nil else { return }
        // Turned on mid-stream: whatever either side copied while sync was
        // off stays where it was copied, and the next copy is the first to
        // cross. Picking up either one would overwrite the other machine's
        // clipboard with something copied there when it was not being synced
        // -- the very thing having it off asked for. A stream opening with
        // sync on pulls the PC's clipboard over, as it always has.
        if resuming {
            lastLocalChangeCount = pasteboard.changeCount
            adoptsRemoteBaseline = true
            lastSyncedText = nil
        }
        schedule(every: Self.idleInterval)
        Log.info("[clipboard] syncing with the host")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        settleTimer?.invalidate()
        settleTimer = nil
        syncAgain = false
    }

    /// Sync now rather than at the next tick: one of the stream's windows has
    /// just taken the keyboard or given it up, which is when a paste on the
    /// other machine is about to follow. See the note on the class.
    func syncNow() {
        guard isRunning else { return }
        briskUntil = Date().addingTimeInterval(Self.briskSpell)
        // Worth one more try even straight after a failure: a paste is about
        // to depend on it.
        quietUntil = .distantPast
        tickWhenFree()
    }

    /// A tick now, or as soon as the request on the wire is answered.
    private func tickWhenFree() {
        if inFlight {
            syncAgain = true
        } else {
            tick()
        }
    }

    /// A tick at `date`, when the copy waiting out `settleTime` has done so.
    private func lookAgain(at date: Date) {
        guard settleTimer == nil else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.settleTimer = nil
            self.tickWhenFree()
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// The timer at `interval`, replaced only when the interval changes.
    private func schedule(every interval: TimeInterval) {
        if let timer, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The request on the wire has its answer; a sync asked for meanwhile
    /// goes now.
    private func settle() {
        inFlight = false
        if syncAgain {
            syncAgain = false
            tick()
        }
    }

    private func tick() {
        // Reached from an answer as well as from the timer, and an answer can
        // arrive after a stop.
        guard isRunning else { return }
        let now = Date()
        let streamHasKeyboard = mayPush()
        if streamHasKeyboard { briskUntil = now.addingTimeInterval(Self.briskSpell) }
        schedule(every: now < briskUntil ? Self.briskInterval : Self.idleInterval)
        guard !inFlight else { return }

        // Local change wins when both moved: what was just copied on this
        // machine is the more recent intent.
        let changeCount = pasteboard.changeCount
        if changeCount != lastLocalChangeCount {
            if Self.isPrivate(types: pasteboard.types) {
                lastLocalChangeCount = changeCount
                lastSyncedText = nil
                Log.info("[clipboard] a private item was copied; not sending it to the host")
                return
            }
            // Not trusted the moment it is seen: its marker may be on its way.
            // See the note on the class.
            let seenAt = unsettledCopy.flatMap { $0.changeCount == changeCount ? $0.seenAt : nil }
                ?? now
            unsettledCopy = (changeCount, seenAt)
            let settlesAt = seenAt.addingTimeInterval(settleTime)
            if now < settlesAt {
                if streamHasKeyboard { lookAgain(at: settlesAt) }
                return
            }
            // Held until a SolStream window has the keyboard, and the PC's
            // clipboard is not pulled over it meanwhile — that would overwrite
            // what was just copied here.
            guard streamHasKeyboard else { return }
            // Cut to the host's budget while the lines are still the Mac's.
            // Windows' are a byte longer each, and cut after converting, a copy
            // that fits would lose its tail.
            let local = pasteboard.string(forType: .string)
                .map { AgentConnection.clipboardPayload(Self.macLineEndings($0)) }
            // Looked at once more, after the text: sent only while it is still
            // the copy that settled, and still not private. Otherwise the next
            // tick sees what it has become.
            guard pasteboard.changeCount == changeCount,
                  !Self.isPrivate(types: pasteboard.types) else { return }
            lastLocalChangeCount = changeCount
            // Nothing to send is not the same as nothing to say, and neither is
            // sent: a Mac clipboard holding an image has no string on it at all
            // and `local` is nil, while one the user has emptied has a string of
            // no length. Sending the second would clear the host's clipboard, and
            // the host cannot tell that apart from the first — see the note on
            // the class, and the matching guard on the remote side below.
            if let local, !local.text.isEmpty, local.text != lastSyncedText {
                if local.truncated {
                    Log.info("[clipboard] trimmed to \(local.text.utf8.count) bytes for the host")
                }
                let sent = local.text
                lastSyncedText = sent
                inFlight = true
                host.write(Self.windowsLineEndings(sent)) { [weak self] sequence in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let sequence {
                            // Adopt the sequence our own write produced, so it is
                            // not read back as a remote change on the next tick.
                            self.lastRemoteSequence = sequence
                        } else if self.lastSyncedText == sent {
                            // Not taken — most often another program holding
                            // the PC's clipboard open — so the PC does not hold
                            // it, and the same text copied again goes again.
                            self.lastSyncedText = nil
                        }
                        self.settle()
                    }
                }
                return
            }
            if local.map({ $0.text.isEmpty }) ?? true {
                // An image, or nothing: either way the Mac no longer holds
                // what crossed last.
                lastSyncedText = nil
            }
        }

        guard now >= quietUntil else { return }
        inFlight = true
        // A copy made here while the answer is on its way is newer than
        // anything the answer can say.
        let changeCountAsked = pasteboard.changeCount
        host.read(lastRemoteSequence) { [weak self] remote in
            DispatchQueue.main.async {
                guard let self else { return }
                // After the answer is applied, so a sync waiting on it starts
                // from what it said.
                defer { self.settle() }
                // Not with a sync waiting on this answer: that was asked for
                // because a paste is about to depend on it.
                if remote == nil && !self.syncAgain {
                    self.quietUntil = Date().addingTimeInterval(Self.idleInterval)
                }
                // Asked for before a stop and answered after it: sync is off
                // now, so the answer is not applied.
                guard let remote, self.isRunning else { return }
                self.lastRemoteSequence = remote.sequence
                if self.adoptsRemoteBaseline {
                    self.adoptsRemoteBaseline = false
                    return
                }
                guard !remote.isUnchanged else { return }
                // Said once per copy: the next poll passes this sequence back,
                // and the host answers "unchanged" without looking again.
                if remote.isPrivate {
                    self.lastSyncedText = nil
                    Log.info("[clipboard] a private item was copied on the host; "
                             + "not bringing it to the Mac")
                    return
                }
                // Empty text is not an empty clipboard — it is also how an image
                // on the host arrives. See the note on the class: this is why the
                // Mac's clipboard is left alone rather than cleared.
                let text = Self.macLineEndings(remote.text)
                guard !text.isEmpty else {
                    self.lastSyncedText = nil
                    return
                }
                guard text != self.lastSyncedText else { return }
                // Local change wins when both moved, here too: the Mac's copy
                // goes to the PC in its turn.
                guard self.pasteboard.changeCount == changeCountAsked else {
                    self.lastSyncedText = nil
                    return
                }

                self.lastSyncedText = text
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                // Writing bumps the local counter; record it now so this write is
                // not mistaken for the user copying something next tick.
                self.lastLocalChangeCount = self.pasteboard.changeCount
                if remote.wasTruncated {
                    Log.info("[clipboard] the host truncated its clipboard text to fit "
                             + "its transfer limit")
                }
            }
        }
    }
}
