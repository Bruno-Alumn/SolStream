import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import MediaSession
import AgentChannel
import AudioRenderer

/// One SMT/1 session, feeding any number of windows.
///
/// This is what makes multiple application windows affordable. The host encodes
/// one picture of the capture display, and every window blits a different
/// sub-rectangle of the same decoded frame — so a second window costs a blit,
/// not a decoder.
///
/// What changed underneath it: there is no Sunshine, no PIN, no certificate, no
/// RTSP and no Reed-Solomon FEC. `AgentConnection.openMediaSession` agreed a key
/// on the channel that had already authenticated both ends, and everything below
/// is a UDP socket carrying AES-256-GCM.
final class StreamSession {
    let host: String

    /// The full streamed canvas, in pixels. Windows express their crops in it.
    private(set) var canvasSize: CGSize

    private let media: MediaClient
    private var decoder: VideoDecoder?

    /// Strong on purpose.
    ///
    /// This was an `NSHashTable.weakObjects()` so closed windows would drop out
    /// by themselves, and that crashed: `allObjects` on a weak NSHashTable can
    /// hand back an object that is already being deallocated, because zeroing the
    /// weak entry is not atomic with reading the table. The decode callback runs
    /// on a VideoToolbox thread while a window deallocates on the main thread, so
    /// the returned array retained a freed view and the process died in
    /// objc_release the next time the pool drained. Windows always detach in
    /// windowWillClose, so explicit removal is both sufficient and predictable.
    private var sinks: [MetalView] = []
    private let sinkLock = NSLock()

    private var isRunning = false
    /// Guarded by `audioLock`. The audio callback runs on MediaClient's receive
    /// thread and the main thread stores over this in `start()` and `stop()`,
    /// and a strong stored property is not a word: loading one retains, storing
    /// one releases the value that was there. A reader racing the store in
    /// `stop()` can retain a renderer whose count is already on its way to zero
    /// and then play into freed memory. The same hazard `pointerStats` below
    /// describes, on the object with a live CoreAudio unit inside it.
    private var audioRenderer: AudioRenderer?
    private let audioLock = NSLock()
    /// Whether the host was asked for its speakers at all. Kept from the config
    /// because `start()` is where the renderer is built, and building one for a
    /// session that asked for no audio takes the output device to play nothing.
    private let wantsAudio: Bool
    /// Pushes volume, mute and buffering into the live renderer. Main thread
    /// only. A block observer is held by NotificationCenter until removed, so
    /// it is removed wherever the renderer is let go.
    private var settingsObserver: NSObjectProtocol?

    /// Supplied by the focused window so the stats line can report input.
    ///
    /// Private, and written only through `setPointerStats`, because the reader
    /// takes `sinkLock` and the writer used not to. A closure is two words — a
    /// function pointer and a context — and storing one retains the incoming
    /// context while releasing the outgoing one; a concurrent read can retain a
    /// context that is being released to zero.
    private var pointerStats: (() -> (Int, Int, UInt64))?

    func setPointerStats(_ block: (() -> (Int, Int, UInt64))?) {
        sinkLock.lock()
        pointerStats = block
        sinkLock.unlock()
    }

    /// Guarded by `frameCountLock`, and read through `audioPacketsPlayed`.
    ///
    /// It was a plain `private(set)` incremented on MediaClient's receive thread
    /// two hundred times a second and read by `stop()` on the main thread. A
    /// 64-bit read racing a 64-bit write is undefined in the language whatever
    /// arm64 does with the instruction, and the only consumer is one log line at
    /// the end of the session — so the lock costs nothing and the race bought
    /// nothing.
    private var audioFramesPlayedStorage: UInt64 = 0

    var audioFramesPlayed: UInt64 {
        frameCountLock.lock()
        defer { frameCountLock.unlock() }
        return audioFramesPlayedStorage
    }

    /// Whether a sound packet has been played yet, so the first one can say
    /// in the log what the host is really sending. Guarded by
    /// `frameCountLock`, written on the receive thread like the count beside it.
    private var playedAudio = false

    /// What the Mac asked the host for, for that log line.
    private let requestedAudio: AudioEncoding

    /// The Mac asked for compressed sound and the host said it will send PCM:
    /// a host that predates the choice ignores it. Fixed for the session, and
    /// taken from the host's answer rather than from the Settings, which may
    /// already hold the next quality while this session is still the old one.
    let hostIgnoresSoundQuality: Bool

    static func hostIgnoresSoundQuality(asked config: StreamConfig,
                                        answered codec: AudioEncoding.Codec) -> Bool {
        config.audio && config.audioEncoding.codec != .pcm && codec == .pcm
    }

    /// The Mac asked for the streamed apps' sound alone and the host said it
    /// will send the whole PC's, which a Windows older than build 20348 does
    /// whatever it is asked. Fixed for the session, as the answer is.
    let hostSendsWholePC: Bool

    static func hostSendsWholePC(asked config: StreamConfig, answered source: AudioSource) -> Bool {
        config.audio && config.audioSource == .apps && source == .system
    }

    /// The host said it takes keys by position, so the PC's own keyboard
    /// layout decides what they type. Fixed for the session, as the host's
    /// answer is; a host that predates it is sent keys by virtual key.
    let hostTakesScanCodes: Bool

    var onPhase: ((StreamPhase) -> Void)?

    /// What the watchdog has to say about the picture.
    enum Liveness: Equatable {
        /// Frames stopped; the host has been asked for a fresh keyframe.
        case stalled(seconds: Int)
        /// Asked repeatedly and nothing came back. Only a reconnect will help.
        case lost
        /// Frames again.
        case live
    }

    var onLiveness: ((Liveness) -> Void)?

    // MARK: - Watchdog

    /// Pictures the decoder has produced. Guarded by `frameCountLock`.
    private var framesDelivered: UInt64 = 0
    private let frameCountLock = NSLock()
    private var watchdog: DispatchSourceTimer?
    /// Only ever touched by the watchdog's timer, which runs one event at a
    /// time; made fresh as the watchdog starts.
    private var liveness = LivenessWatch(startedAt: Date())

    private var counters = MediaCounters()
    private let counterLock = NSLock()

    var mediaCounters: MediaCounters {
        counterLock.lock()
        defer { counterLock.unlock() }
        return counters
    }

    init(host: String, config: StreamConfig, session: AgentConnection.MediaSession) {
        self.host = host
        self.canvasSize = CGSize(width: config.width, height: config.height)
        self.wantsAudio = config.audio
        self.requestedAudio = config.audioEncoding
        self.hostIgnoresSoundQuality = Self.hostIgnoresSoundQuality(asked: config,
                                                                    answered: session.audioCodec)
        self.hostSendsWholePC = Self.hostSendsWholePC(asked: config, answered: session.audioSource)
        self.hostTakesScanCodes = session.takesScanCodes
        // Said once a session, because it decides what every key types and
        // nothing on screen shows which way they are going.
        Log.info("[input] keys go to \(host) "
                 + (session.takesScanCodes ? "by position, so the PC's layout decides what they type"
                                           : "by US-layout name; it predates sending them by position"))
        self.media = MediaClient(keys: session.keys, host: host, port: session.port)

        // One decoder, fanned out to every attached window. Each window carries
        // its own sourceRect, so they all read the same CVPixelBuffer and blit
        // different regions of it.
        let decoder = VideoDecoder { [weak self] pixelBuffer in
            guard let self else { return }
            self.frameCountLock.lock()
            self.framesDelivered &+= 1
            let first = self.framesDelivered == 1
            self.frameCountLock.unlock()
            // Live when a picture has been DECODED. It was when one was handed
            // to the decoder, and at the start of a session that was a P-frame
            // the decoder could do nothing with: "Waiting for video" went, and
            // the recovery count was reset, over a black window. If the
            // keyframe that would have fixed it never decoded either, nothing
            // ever said so.
            if first {
                DispatchQueue.main.async { self.onPhase?(.streaming) }
            }
            self.sinkLock.lock()
            let views = self.sinks
            self.sinkLock.unlock()
            for view in views {
                view.displayFrame(pixelBuffer)
            }
        }
        self.decoder = decoder

        media.onVideo = { [weak decoder] annexB, isIdr in
            decoder?.decode(annexB, isIDR: isIdr)
        }
        media.onAudio = { [weak self] packet in
            guard let self else { return }
            // Copied out under the lock and played outside it: the copy is what
            // keeps the renderer alive for the length of the call, and holding
            // a lock across playAudio would put the receive thread and the main
            // thread's stop() in each other's way two hundred times a second.
            self.audioLock.lock()
            let renderer = self.audioRenderer
            self.audioLock.unlock()
            guard let renderer else { return }
            // By the packet's own format, never by what was asked for: a host
            // that predates Opus sends PCM whatever it is asked.
            switch packet.format {
            case .pcm16: renderer.playAudio(packet.payload)
            case .opus: renderer.playOpus(packet.payload)
            }
            self.frameCountLock.lock()
            self.audioFramesPlayedStorage &+= 1
            let first = !self.playedAudio
            self.playedAudio = true
            self.frameCountLock.unlock()
            if first {
                Log.info("[audio] the host sends \(packet.format == .opus ? "Opus" : "PCM")"
                         + " (asked for \(self.requestedAudio.summary))")
            }
        }
        media.onStats = { [weak self] stats in
            guard let self else { return }
            self.counterLock.lock()
            self.counters.frames = stats.framesComplete
            self.counters.dropped = stats.framesDamaged
            self.counters.bytes = stats.bytesReceived
            self.counters.audioFrames = stats.audioPackets
            self.counters.latencyMs = stats.rttMs > 0 ? Int(stats.rttMs.rounded()) : nil
            self.counterLock.unlock()
        }
        media.onEnded = { [weak self] in
            DispatchQueue.main.async {
                self?.onPhase?(.failed("The host stopped answering."))
            }
        }
        // Holding as well as asking: until the IDR, every P-frame would only
        // fail in a decoder that has lost what it refers to.
        decoder.onKeyframeNeeded = { [weak self] in
            self?.media.holdUntilKeyframe()
        }
    }

    /// Start the stream. Frames go to every attached window.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Started here rather than in init: the renderer holds the output device
        // open, and a session that is built but never run should not take it.
        //
        // And only when audio was asked for. `config.audio` false means the
        // host is sending none, so the renderer that was built anyway opened the
        // default output device, kept a CoreAudio unit running and had nothing
        // whatever to play through it for the length of the session.
        if wantsAudio {
            // Configured before the socket opens, so the first sound already
            // plays at the chosen level and with the chosen cushion.
            let renderer = AudioRenderer()
            loggedAudio = nil   // every session says what it starts with
            applyAudioSettings(to: renderer)
            audioLock.lock()
            audioRenderer = renderer
            audioLock.unlock()
            observeAudioSettings()
        }

        onPhase?(.waitingForVideo)
        guard media.start() else {
            onPhase?(.failed("Could not open the media socket."))
            isRunning = false
            // Hand the output device back here, because nothing else ever will.
            // `stop()` returns immediately while `isRunning` is false — which it
            // is again by the line above — so the teardown down there never runs
            // for a session that failed to start, and the renderer sat on the
            // device until the whole session was released.
            stopObservingAudioSettings()
            audioLock.lock()
            let renderer = audioRenderer
            audioRenderer = nil
            audioLock.unlock()
            renderer?.stop()
            return
        }
        startWatchdog()
        Log.info("[session] started for \(host), canvas \(Int(canvasSize.width))x\(Int(canvasSize.height))")
    }

    /// Notice when the picture stops, and try the cheap fix before saying so.
    ///
    /// A stalled stream used to look exactly like a still one: the last frame
    /// stayed on screen indefinitely, with no spinner, no error and no way to
    /// tell a frozen stream from an application that simply was not redrawing.
    /// The overwhelmingly common cause is a single frame that could not be
    /// decoded — a dropped packet in a reference frame — after which every
    /// later frame refers to something the decoder does not have. Asking for a
    /// keyframe fixes that outright, so ask before reporting anything.
    private func startWatchdog() {
        // Before the timer exists, so its first event sees this session's start.
        liveness = LivenessWatch(startedAt: Date())
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(500), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        watchdog = timer
        timer.resume()
    }

    private func checkLiveness() {
        frameCountLock.lock()
        let delivered = framesDelivered
        frameCountLock.unlock()

        let what = delivered == 0 ? "no picture yet" : "no frames"
        switch liveness.check(delivered: delivered, now: Date()) {
        case .quiet:
            break
        case .resumed:
            Log.info("[watchdog] frames resumed")
            report(.live)
        case .stalled(let stalled, let request):
            Log.info("[watchdog] \(what) for \(String(format: "%.1f", stalled))s; "
                     + "asking for a keyframe (\(request)/\(LivenessWatch.maxKeyframeRequests))")
            media.requestKeyframe()
            report(.stalled(seconds: Int(stalled)))
        case .lost(let stalled):
            Log.error("[watchdog] \(what) for \(String(format: "%.1f", stalled))s "
                      + "after \(LivenessWatch.maxKeyframeRequests) keyframe requests; "
                      + "giving up on recovery")
            report(.lost)
        }
    }

    private func report(_ liveness: Liveness) {
        DispatchQueue.main.async { [weak self] in
            self?.onLiveness?(liveness)
        }
    }

    /// Tear the session down. Synchronous, always: `media.stop()` sends the BYE,
    /// shuts the socket down and waits up to a second for the receive thread to
    /// leave, which is what `applicationWillTerminate` relies on -- the host has
    /// to see the BYE or it stays busy for the next client.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        watchdog?.cancel()
        watchdog = nil
        // Silence the socket before releasing anything its callbacks touch. The
        // audio callback runs on the receive thread roughly 200 times a second
        // and dereferences `audioRenderer`; stopping the client first is what
        // makes releasing it afterwards safe rather than probably safe.
        media.stop()
        // Drain the decoder before dropping the sinks: its callback runs on a
        // VideoToolbox thread and is what hands frames to the views.
        decoder?.shutdown()
        decoder = nil
        sinkLock.lock()
        sinks.removeAll()
        sinkLock.unlock()
        stopObservingAudioSettings()
        audioLock.lock()
        let renderer = audioRenderer
        audioRenderer = nil
        audioLock.unlock()
        renderer?.stop()
        // The pointer numbers were collected all along and never once read, so
        // "my clicks stopped working" left no trace on this side at all — the
        // whole diagnosis had to come from the host. `dropped` being large is
        // the specific signature of a resize pause that never ended.
        sinkLock.lock()
        let pointer = pointerStats?()
        sinkLock.unlock()
        let pointerNote = pointer.map { moved, sent, dropped in
            ", pointer \(sent) sent of \(moved) moves"
                + (dropped > 0 ? ", \(dropped) dropped mid-resize" : "")
        } ?? ""
        Log.info("[session] stopped — \(mediaCounters.frames) frames, "
                 + "\(mediaCounters.dropped) damaged, \(audioFramesPlayed) audio packets"
                 + pointerNote)
    }

    deinit {
        stopObservingAudioSettings()
    }

    // MARK: - Sound settings

    /// Volume, mute and buffering apply to a playing stream as they are. Sound
    /// on or off does not -- the host's audio capture is fixed when the media
    /// session opens -- and is whoever restarts the session's business.
    ///
    /// `StreamSettings.volume` is where the slider sits, and this is the one
    /// place it becomes a gain, so the popover and the Settings window share
    /// one loudness curve.
    private func applyAudioSettings(to renderer: AudioRenderer) {
        let settings = StreamSettings.shared
        let remote = StreamSettings.isRemote(host: host)
        let buffering = settings.audioBuffering.resolved(remote: remote)
        renderer.volume = AudioRenderer.amplitude(forPosition: settings.volume)
        renderer.isMuted = settings.isMuted
        renderer.buffering = buffering

        // A stream that is silent because mute was remembered from yesterday,
        // or the volume left at nothing, otherwise logs exactly like one that
        // plays. Said when the session starts and again whenever mute or the
        // buffering changes, but not for the volume alone: a slider drag
        // changes it on every mouse move.
        let state = LoggedAudio(muted: settings.isMuted, buffering: buffering)
        guard state != loggedAudio else { return }
        loggedAudio = state
        let percent = Int((settings.volume * 100).rounded())
        Log.info("[audio] volume \(percent)%\(state.muted ? ", muted" : ""), "
                 + "buffering \(buffering.rawValue) "
                 + "(\(settings.audioBuffering.rawValue)\(remote ? ", remote" : ""))")
    }

    private struct LoggedAudio: Equatable {
        var muted: Bool
        var buffering: AudioRenderer.Buffering
    }

    /// What `applyAudioSettings` last logged. Main thread only.
    private var loggedAudio: LoggedAudio?

    private func observeAudioSettings() {
        guard settingsObserver == nil else { return }
        // Every change is applied, whatever it was: all three setters are
        // cheap and idempotent, and sorting out which setting moved would only
        // be a second copy of StreamSettings' keys to keep in step.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: StreamSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.audioLock.lock()
            let renderer = self.audioRenderer
            self.audioLock.unlock()
            if let renderer { self.applyAudioSettings(to: renderer) }
        }
    }

    private func stopObservingAudioSettings() {
        guard let settingsObserver else { return }
        NotificationCenter.default.removeObserver(settingsObserver)
        self.settingsObserver = nil
    }

    // MARK: - Input

    /// One input event, as SMTInput built it. The sequence number, the
    /// redundancy and the repeat timer are MediaClient's.
    func sendInput(_ event: Data) {
        media.sendInput(event)
    }

    /// Whether `sendInput` reaches the host now. False before `start()` and
    /// after `stop()`, when MediaClient drops what it is given.
    var acceptsInput: Bool { media.isRunning }


    // MARK: - Sinks

    func attach(_ view: MetalView) {
        sinkLock.lock()
        if !sinks.contains(where: { $0 === view }) {
            sinks.append(view)
        }
        let count = sinks.count
        sinkLock.unlock()
        Log.info("[session] \(count) window(s) attached")
    }

    func detach(_ view: MetalView) {
        sinkLock.lock()
        sinks.removeAll { $0 === view }
        let remaining = sinks.count
        sinkLock.unlock()
        Log.info("[session] \(remaining) window(s) attached")
    }

}

/// The watchdog's arithmetic, apart from its timer and the decoder so it can be
/// tested with frame counts and clock readings.
struct LivenessWatch {
    /// At 60fps a frame is due every 16ms, so a second of silence is not a
    /// hiccup. Long enough not to fire on a garbage-collection pause, short
    /// enough that the user has not yet started clicking things twice.
    static let stallThreshold: TimeInterval = 1.0
    /// Most stalls are one undecodable frame, and a keyframe fixes them without
    /// anybody noticing. Past five seconds of asking, the problem is the
    /// connection and no amount of further asking will produce a picture.
    static let maxKeyframeRequests = 5
    /// How long a session may go without decoding its first picture before
    /// that is treated as a stall that began when it started.
    ///
    /// It used to be exempt for as long as it lasted, on the grounds that
    /// "Waiting for video" was already saying so. But a session whose keyframe
    /// never decodes -- one that arrives damaged every time on a lossy relay,
    /// or a decoder that cannot be built -- then waited for ever: a black
    /// window on a first connection, and a frozen one after a restart, with no
    /// request from here, no "Lost the stream" and no Try Again. A first
    /// picture normally takes a round trip and a keyframe, well inside this.
    static let firstPictureGrace: TimeInterval = 3.0

    enum Action: Equatable {
        /// Nothing to say.
        case quiet
        /// Pictures again after a stall was reported.
        case resumed
        /// No pictures for `seconds`; ask for keyframe number `request`.
        case stalled(seconds: TimeInterval, request: Int)
        /// Still nothing after every request. Only a new session will help.
        case lost(seconds: TimeInterval)
    }

    private let startedAt: Date
    private var lastSeenFrameCount: UInt64 = 0
    private var stalledSince: Date?
    private var keyframeRequests = 0
    private var reportedLost = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func check(delivered: UInt64, now: Date) -> Action {
        if delivered != lastSeenFrameCount {
            lastSeenFrameCount = delivered
            guard stalledSince != nil else { return .quiet }
            stalledSince = nil
            keyframeRequests = 0
            reportedLost = false
            return .resumed
        }

        if stalledSince == nil {
            if delivered > 0 {
                stalledSince = now
                return .quiet
            }
            // Nothing decoded yet. "Waiting for video" says so for the grace
            // period; past it, the stall is counted from the start.
            guard now.timeIntervalSince(startedAt) >= Self.firstPictureGrace else {
                return .quiet
            }
            stalledSince = startedAt
        }
        let stalled = now.timeIntervalSince(stalledSince ?? now)
        guard stalled >= Self.stallThreshold else { return .quiet }

        if keyframeRequests < Self.maxKeyframeRequests {
            keyframeRequests += 1
            return .stalled(seconds: stalled, request: keyframeRequests)
        }
        guard !reportedLost else { return .quiet }
        reportedLost = true
        return .lost(seconds: stalled)
    }
}
