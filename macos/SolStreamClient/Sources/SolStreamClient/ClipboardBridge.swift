import AppKit
import CryptoKit
import ImageIO
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
/// Pictures cross too, as PNG, when there is no text: a copy with both -- a
/// web page's selection -- is its text. They go in chunks after the poll
/// says there is one (`hasImage`), so the poll itself stays a few bytes. A
/// copied file in Finder carries its icon as a picture, and that icon is not
/// what was copied, so a copy of files sends nothing.
///
/// One thing it deliberately does not carry, in either direction: a clipboard
/// that has become empty. A host that predates pictures reports one as text
/// that is empty, the same as nothing at all, and copying that emptiness
/// across would wipe the Mac's clipboard every time somebody copied a picture
/// on the PC. So an empty value is left alone at both ends, and clearing one
/// clipboard does not clear the other.
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
        /// The text with its formatting. Without it, the formatting stays here.
        var writeRich: ((_ text: String, _ rich: AgentConnection.RichText,
                         _ completion: @escaping (Int?) -> Void) -> Void)?
        /// The host's picture for a clipboard sequence, as PNG.
        var readImage: (_ sequence: Int, _ completion: @escaping (Data?) -> Void) -> Void
        /// A PNG onto the host's clipboard; the sequence that made.
        var writeImage: (_ png: Data, _ completion: @escaping (Int?) -> Void) -> Void

        init(read: @escaping (Int?, @escaping (AgentConnection.RemoteClipboard?) -> Void) -> Void,
             write: @escaping (String, @escaping (Int?) -> Void) -> Void,
             readImage: @escaping (Int, @escaping (Data?) -> Void) -> Void = { $1(nil) },
             writeImage: @escaping (Data, @escaping (Int?) -> Void) -> Void = { $1(nil) },
             writeRich: ((String, AgentConnection.RichText,
                          @escaping (Int?) -> Void) -> Void)? = nil) {
            self.read = read
            self.write = write
            self.writeRich = writeRich
            self.readImage = readImage
            self.writeImage = writeImage
        }

        init(agent: AgentConnection) {
            self.init(read: { agent.clipboard(since: $0, completion: $1) },
                      write: { agent.setClipboard($0, completion: $1) },
                      readImage: { agent.clipboardImage(sequence: $0, completion: $1) },
                      writeImage: { agent.setClipboardImage($0, completion: $1) },
                      writeRich: { agent.setClipboard($0, rich: $1, completion: $2) })
        }
    }

    private let host: Host
    private let pasteboard: NSPasteboard

    private var timer: Timer?
    private var lastLocalChangeCount: Int {
        didSet { Self.handledChangeCounts[pasteboard.name] = lastLocalChangeCount }
    }
    /// The Mac copy the last bridge on each pasteboard had dealt with. A
    /// bridge is built for every stream, every Switch App and every Retry;
    /// see `init`.
    private static var handledChangeCounts: [NSPasteboard.Name: Int] = [:]
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
    /// The same for a picture, by its PNG's digest. At most one of the two is
    /// set: each is what both clipboards hold.
    private var lastSyncedImage: String?
    /// The host sequence whose picture failed to come once and was asked for
    /// again; see `pullImage`.
    private var retriedImageSequence: Int?
    /// The Mac copy that the host failed to take once and is sent again; see
    /// `sendAgainOnce`.
    private var retriedChangeCount: Int?
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
        // Something copied on the Mac since the last bridge dealt with the
        // clipboard is a copy waiting to cross, not a baseline. Taken as the
        // baseline, the first read brought the PC's clipboard over it: copy a
        // link, open the stream or Switch App, and the link was gone from both
        // machines. So it goes to the PC once the stream has the keyboard, and
        // the PC's is only adopted. With no bridge before it there is nothing
        // to tell an old copy from a new one, and the PC's comes over as it
        // always has.
        if let handled = Self.handledChangeCounts[pasteboard.name],
           handled != pasteboard.changeCount {
            self.lastLocalChangeCount = handled
            self.adoptsRemoteBaseline = true
        } else {
            self.lastLocalChangeCount = pasteboard.changeCount
            noteFilesAtBaseline()
        }
        Self.handledChangeCounts[pasteboard.name] = self.lastLocalChangeCount
    }

    /// Files already on the clipboard when this bridge takes it as its
    /// baseline -- copied in Finder before the stream opened -- are not a
    /// copy to cross, but ⌘V on the PC still won't paste them: said when
    /// the stream first takes the keyboard.
    private func noteFilesAtBaseline() {
        if pasteboard.types?.contains(.fileURL) == true, !Self.isPrivate(types: pasteboard.types) {
            filesNoteAtBaseline = pasteboard.changeCount
        }
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
            noteFilesAtBaseline()
            adoptsRemoteBaseline = true
            lastSyncedText = nil
            lastSyncedImage = nil
        }
        schedule(every: Self.idleInterval)
        Log.info("[clipboard] syncing with the host")
    }

    /// Sync is off: whatever is copied on the Mac from now until a bridge
    /// next starts is not a copy waiting to cross, so the next bridge must not
    /// treat it as one. Called when sync is turned off, and for a bridge built
    /// with it off.
    func forgetHandledCopies() {
        Self.handledChangeCounts[pasteboard.name] = nil
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
        if streamHasKeyboard, filesNoteAtBaseline == changeCount, changeCount == lastLocalChangeCount {
            filesNoteAtBaseline = nil
            tellFilesCopied(changeCount)
        }
        if changeCount != lastLocalChangeCount {
            if Self.isPrivate(types: pasteboard.types) {
                lastLocalChangeCount = changeCount
                lastSyncedText = nil
                lastSyncedImage = nil
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
            //
            // A copy of files is not text, though Finder puts their names on
            // the clipboard as a string too: sent, the PC's clipboard became
            // "report.pdf" in place of whatever it held.
            let isFiles = pasteboard.types?.contains(.fileURL) ?? false
            let local = isFiles ? nil : pasteboard.string(forType: .string)
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
                    onTextCut?(Self.cutForPCNote)
                }
                let sent = local.text
                lastSyncedText = sent
                lastSyncedImage = nil
                inFlight = true
                let rich = local.truncated ? AgentConnection.RichText()
                                           : Self.richText(on: pasteboard)
                let done: (Int?) -> Void = { [weak self] sequence in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if let sequence {
                            // Adopt the sequence our own write produced, so it is
                            // not read back as a remote change on the next tick.
                            self.lastRemoteSequence = sequence
                            // A sequence of our own is a baseline already; the next read is a
                            // real answer, and a copy made on the PC since must come over.
                            self.adoptsRemoteBaseline = false
                        } else if self.lastSyncedText == sent {
                            // Not taken — most often another program holding
                            // the PC's clipboard open — so the PC does not hold
                            // it, and the same text copied again goes again.
                            self.lastSyncedText = nil
                            self.sendAgainOnce(changeCount)
                        }
                        self.settle()
                    }
                }
                let text = Self.windowsLineEndings(sent)
                if let writeRich = host.writeRich, !rich.isEmpty {
                    writeRich(text, rich, done)
                } else {
                    host.write(text, done)
                }
                return
            }
            if local.map({ $0.text.isEmpty }) ?? true {
                // An image, or nothing: either way the Mac no longer holds
                // what crossed last.
                lastSyncedText = nil
            }
            var tooLarge = false
            if local == nil, let png = Self.png(on: pasteboard, tooLarge: &tooLarge) {
                let digest = Self.digest(png)
                if digest != lastSyncedImage {
                    pushImage(png, digest: digest, changeCount: changeCount)
                    return
                }
            } else {
                // Text, files, a picture too big to send, or nothing: the Mac
                // no longer holds the picture that crossed last.
                lastSyncedImage = nil
                if tooLarge, toldTooLarge != changeCount {
                    toldTooLarge = changeCount
                    onPictureTooLarge?()
                }
                if isFiles { tellFilesCopied(changeCount) }
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
                // from what it said -- or after the picture it named, which
                // settles for itself.
                var handedOff = false
                defer { if !handedOff { self.settle() } }
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
                    self.lastSyncedImage = nil
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
                    if remote.hasImage {
                        // The answer is settled when the picture has come.
                        handedOff = true
                        self.pullImage(sequence: remote.sequence, changeCountAsked: changeCountAsked)
                    } else {
                        self.lastSyncedImage = nil
                    }
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
                self.lastSyncedImage = nil
                self.pasteboard.clearContents()
                self.pasteboard.setString(text, forType: .string)
                // Its formatting beside it, for an app that pastes formatted.
                Self.put(remote.rich, on: self.pasteboard)
                // Writing bumps the local counter; record it now so this write is
                // not mistaken for the user copying something next tick.
                self.lastLocalChangeCount = self.pasteboard.changeCount
                if remote.wasTruncated {
                    Log.info("[clipboard] the host truncated its clipboard text to fit "
                             + "its transfer limit")
                    self.onTextCut?(Self.cutFromPCNote)
                }
            }
        }
    }

    /// The formatting on the pasteboard beside its text: HTML and RTF, as
    /// browsers, Mail, Notes and TextEdit put them. `travelling()` leaves out
    /// what would not fit.
    static func richText(on pasteboard: NSPasteboard) -> AgentConnection.RichText {
        let html = pasteboard.string(forType: .html)
        let rtf = pasteboard.data(forType: .rtf).flatMap { String(data: $0, encoding: .ascii) }
        return AgentConnection.RichText(html: html, rtf: rtf).travelling()
    }

    /// HTML that says it is UTF-8, as it is. Windows' HTML Format is UTF-8 by
    /// definition and Chrome's and Edge's say nothing more, while AppKit reads
    /// undeclared HTML as Latin-1: "café" pasted as "cafÃ©". Chrome on the Mac
    /// puts the same declaration in front of its own copies.
    static func declaringUTF8(_ html: String) -> String {
        let head = html.prefix(1024).lowercased()
        return head.contains("charset") ? html : "<meta charset=\"utf-8\">" + html
    }

    /// The PC's formatting onto the pasteboard, after its text.
    static func put(_ rich: AgentConnection.RichText, on pasteboard: NSPasteboard) {
        if let html = rich.html {
            pasteboard.setString(declaringUTF8(html), forType: .html)
        }
        if let rtf = rich.rtf, let data = rtf.data(using: .ascii) {
            pasteboard.setData(data, forType: .rtf)
        }
    }

    /// Something other than the bridge put `sequence` on the host's
    /// clipboard: files dropped on a window. What the Mac holds now, sent or
    /// waiting to be, does not go over them -- a URL copied in Safari before
    /// the drop would otherwise replace the files the moment the window took
    /// the keyboard, and ⌘V would paste the URL.
    func adopt(remoteSequence sequence: Int) {
        lastRemoteSequence = sequence
        adoptsRemoteBaseline = false
        lastLocalChangeCount = pasteboard.changeCount
        // A write of the Mac's copy that fails after this must not send it
        // over what was just put on the PC's clipboard.
        retriedChangeCount = pasteboard.changeCount
        unsettledCopy = nil
        lastSyncedText = nil
        lastSyncedImage = nil
    }

    // MARK: - Pictures

    /// Pixels past which a picture is not sent: 7680x4320, the most the host
    /// reads (kMaxClipboardImagePixels). A screenshot of a 6K display at its
    /// largest scaled size is 7520x4230 and fits. Past it, a picture whose PNG
    /// fit in 32 MB went over in full, sixty-odd round trips, to be refused.
    static let maxPicturePixels = 7680 * 4320

    /// Its pixel count, from the header alone: nothing is decoded.
    static func pixelCount(of data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return width * height
    }

    /// A picture copied on the Mac was too big to send, said once per copy:
    /// otherwise ⌘V on the PC pastes what was there before, and nothing says why.
    var onPictureTooLarge: (() -> Void)?
    private var toldTooLarge: Int?

    /// Files copied in Finder, said once per copy when the stream takes the
    /// keyboard: they are not sent -- the PC's clipboard would get their
    /// names -- so ⌘V there pasted what it had before, and nothing said why,
    /// or that dropping them on the window sends them.
    var onFilesCopied: ((String) -> Void)?
    private var toldFiles: Int?
    /// The baseline's change count while its files are still to be said.
    private var filesNoteAtBaseline: Int?
    static let filesCopiedNote =
        "Copied files don't paste on the PC. Drag them onto this window to send them."
    /// Folders, apps and packages are refused by a drop too: they go zipped.
    static let foldersCopiedNote =
        "Copied folders don't paste on the PC. Compress one, then drag the .zip onto this window."

    /// The note for the copy on `pasteboard`: the folders' only when every
    /// item is known to be one.
    static func filesCopiedNote(on pasteboard: NSPasteboard) -> String {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let allFolders = !urls.isEmpty && urls.allSatisfy {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return allFolders ? foldersCopiedNote : filesCopiedNote
    }

    private func tellFilesCopied(_ changeCount: Int) {
        guard toldFiles != changeCount else { return }
        toldFiles = changeCount
        onFilesCopied?(Self.filesCopiedNote(on: pasteboard))
    }

    /// Text too long to carry whole was cut to fit, with the note to show:
    /// otherwise a paste of a long log silently loses its end.
    var onTextCut: ((String) -> Void)?
    static let cutForPCNote =
        "The text you copied was too long to send whole. The PC has its first 256 KB."
    static let cutFromPCNote =
        "The text copied on the PC was too long to send whole. This Mac has its first 256 KB."

    /// What the stream window says when that happens.
    static let pictureTooLargeNote =
        "That picture is too big to paste on the PC (the most is 7680 × 4320 and 32 MB). "
        + "Save it as a file and drop it on the window instead."

    static func png(on pasteboard: NSPasteboard) -> Data? {
        var tooLarge = false
        return png(on: pasteboard, tooLarge: &tooLarge)
    }

    /// The picture on `pasteboard` as PNG, if it holds one and is not a copy
    /// of files -- whose icons Finder puts beside them -- and it is not too
    /// big to send; `tooLarge` says when that is why there is none.
    static func png(on pasteboard: NSPasteboard, tooLarge: inout Bool) -> Data? {
        let types = pasteboard.types ?? []
        guard !types.contains(.fileURL) else { return nil }
        let direct = pasteboard.data(forType: .png)
        if let direct, let pixels = pixelCount(of: direct), pixels > maxPicturePixels {
            Log.info("[clipboard] a picture of \(pixels) pixels is too large to send to the host")
            tooLarge = true
            return nil
        }
        let png = direct
            ?? pasteboard.data(forType: .tiff).flatMap { tiff -> Data? in
                guard let picture = NSBitmapImageRep(data: tiff) else { return nil }
                // Encoded on the main thread, as the stream takes the keyboard:
                // a photo of tens of megapixels held the whole app for seconds,
                // only for the PNG to come out over the limit and be dropped.
                // Its size is read from the header first, which costs nothing.
                let pixels = picture.pixelsWide * picture.pixelsHigh
                guard pixels <= maxPicturePixels else {
                    Log.info("[clipboard] a \(picture.pixelsWide)x\(picture.pixelsHigh) picture "
                             + "is too large to send to the host")
                    tooLarge = true
                    return nil
                }
                return picture.representation(using: .png, properties: [:])
            }
        guard let png, !png.isEmpty else { return nil }
        guard png.count <= AgentConnection.maxClipboardImageBytes else {
            // Said, not skipped in silence: otherwise ⌘V on the PC pastes
            // what was there before, and nothing anywhere says why.
            Log.info("[clipboard] a picture of \(png.count / 1_048_576) MB is over the "
                     + "\(AgentConnection.maxClipboardImageBytes / 1_048_576) MB the host takes; "
                     + "not sending it")
            tooLarge = true
            return nil
        }
        return png
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac's picture to the PC.
    private func pushImage(_ png: Data, digest: String, changeCount: Int) {
        lastSyncedImage = digest
        lastSyncedText = nil
        inFlight = true
        Log.info("[clipboard] sending a picture to the host (\(png.count) bytes)")
        host.writeImage(png) { [weak self] sequence in
            DispatchQueue.main.async {
                guard let self else { return }
                if let sequence {
                    self.lastRemoteSequence = sequence
                    // A sequence of our own is a baseline already; the next read is a
                    // real answer, and a copy made on the PC since must come over.
                    self.adoptsRemoteBaseline = false
                } else if self.lastSyncedImage == digest {
                    self.lastSyncedImage = nil
                    self.sendAgainOnce(changeCount)
                }
                self.settle()
            }
        }
    }

    /// A copy the host did not take -- most often another program holding the
    /// PC's clipboard open for longer than the host waits -- goes once more at
    /// the next tick. It was counted as handled when it went, so without this
    /// it never went again, and a paste on the PC got what was there before.
    /// Once: one the host cannot take at all is not sent every second.
    private func sendAgainOnce(_ changeCount: Int) {
        guard isRunning, pasteboard.changeCount == changeCount,
              lastLocalChangeCount == changeCount, retriedChangeCount != changeCount
        else { return }
        retriedChangeCount = changeCount
        Log.info("[clipboard] the PC did not take the copy; sending it once more")
        // Anything but this count: the next tick sees it as unhandled.
        lastLocalChangeCount = changeCount - 1
        // Not at once: whatever held the PC's clipboard most likely still does.
        // The copy settles again first, as a new one would.
        unsettledCopy = (changeCount, Date())
    }

    /// The PC's picture to the Mac, unless the Mac copied something since the
    /// poll that named it.
    private func pullImage(sequence: Int, changeCountAsked: Int) {
        host.readImage(sequence) { [weak self] png in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.settle() }
                guard let png else {
                    // Asked again at the next poll, once: most often another
                    // program had the PC's clipboard open. A picture the host
                    // cannot send at all is not asked for every second.
                    if self.lastRemoteSequence == sequence, self.retriedImageSequence != sequence {
                        self.retriedImageSequence = sequence
                        self.lastRemoteSequence = nil
                    }
                    return
                }
                guard self.isRunning else { return }
                let digest = Self.digest(png)
                guard digest != self.lastSyncedImage else { return }
                guard self.pasteboard.changeCount == changeCountAsked else {
                    self.lastSyncedImage = nil
                    return
                }
                self.lastSyncedImage = digest
                self.lastSyncedText = nil
                self.pasteboard.clearContents()
                // PNG alone. macOS offers it as TIFF to whatever reads only
                // that, converting in the reader's process. A TIFF made here,
                // on the main thread, was a hundred-odd megabytes for a
                // picture near the host's limit and held the stream as long.
                self.pasteboard.setData(png, forType: .png)
                self.lastLocalChangeCount = self.pasteboard.changeCount
                Log.info("[clipboard] brought a picture from the host (\(png.count) bytes)")
            }
        }
    }
}
