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

    private var framesDelivered: UInt64 = 0
    private let frameCountLock = NSLock()
    private var watchdog: DispatchSourceTimer?
    private var lastSeenFrameCount: UInt64 = 0
    private var stalledSince: Date?
    private var keyframeRequests = 0
    private var reportedLost = false
    private var sawFirstFrame = false

    /// At 60fps a frame is due every 16ms, so a second of silence is not a
    /// hiccup. Long enough not to fire on a garbage-collection pause, short
    /// enough that the user has not yet started clicking things twice.
    private static let stallThreshold: TimeInterval = 1.0
    /// Most stalls are one undecodable frame, and a keyframe fixes them without
    /// anybody noticing. Past five seconds of asking, the problem is the
    /// connection and no amount of further asking will produce a picture.
    private static let maxKeyframeRequests = 5

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
        self.media = MediaClient(keys: session.keys, host: host, port: session.port)

        // One decoder, fanned out to every attached window. Each window carries
        // its own sourceRect, so they all read the same CVPixelBuffer and blit
        // different regions of it.
        let decoder = VideoDecoder { [weak self] pixelBuffer in
            guard let self else { return }
            self.frameCountLock.lock()
            self.framesDelivered &+= 1
            self.frameCountLock.unlock()
            self.sinkLock.lock()
            let views = self.sinks
            self.sinkLock.unlock()
            for view in views {
                view.displayFrame(pixelBuffer)
            }
        }
        self.decoder = decoder

        media.onVideo = { [weak self, weak decoder] annexB, isIdr in
            decoder?.decode(annexB, isIDR: isIdr)
            guard let self else { return }
            if !self.sawFirstFrame {
                self.sawFirstFrame = true
                DispatchQueue.main.async { self.onPhase?(.streaming) }
            }
        }
        media.onAudio = { [weak self] pcm, _ in
            guard let self else { return }
            // Copied out under the lock and played outside it: the copy is what
            // keeps the renderer alive for the length of the call, and holding
            // a lock across playAudio would put the receive thread and the main
            // thread's stop() in each other's way two hundred times a second.
            self.audioLock.lock()
            let renderer = self.audioRenderer
            self.audioLock.unlock()
            guard let renderer else { return }
            renderer.playAudio(pcm)
            self.frameCountLock.lock()
            self.audioFramesPlayedStorage &+= 1
            self.frameCountLock.unlock()
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
        decoder.onKeyframeNeeded = { [weak self] in
            self?.media.requestKeyframe()
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
            audioLock.lock()
            audioRenderer = AudioRenderer()
            audioLock.unlock()
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

        if delivered != lastSeenFrameCount {
            lastSeenFrameCount = delivered
            if stalledSince != nil {
                Log.info("[watchdog] frames resumed")
                stalledSince = nil
                keyframeRequests = 0
                reportedLost = false
                report(.live)
            }
            return
        }

        // Nothing has arrived yet at all. That is the phase's story to tell — it
        // already shows "Waiting for video" — and a watchdog shouting over it
        // would only be a second opinion on the same fact.
        guard delivered > 0 else { return }

        guard let since = stalledSince else {
            stalledSince = Date()
            return
        }
        let stalled = Date().timeIntervalSince(since)
        guard stalled >= Self.stallThreshold else { return }

        if keyframeRequests < Self.maxKeyframeRequests {
            keyframeRequests += 1
            Log.info("[watchdog] no frames for \(String(format: "%.1f", stalled))s; "
                     + "asking for a keyframe (\(keyframeRequests)/\(Self.maxKeyframeRequests))")
            media.requestKeyframe()
            report(.stalled(seconds: Int(stalled)))
        } else if !reportedLost {
            reportedLost = true
            Log.error("[watchdog] no frames for \(String(format: "%.1f", stalled))s "
                      + "after \(keyframeRequests) keyframe requests; giving up on recovery")
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

    // MARK: - Input

    /// One input event, as SMTInput built it. The sequence number, the
    /// redundancy and the repeat timer are MediaClient's.
    func sendInput(_ event: Data) {
        media.sendInput(event)
    }


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
