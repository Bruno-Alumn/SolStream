import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import MediaSession
import StreamConnection
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
    private var audioRenderer: AudioRenderer?

    /// Supplied by the focused window so the stats line can report input.
    ///
    /// Private, and written only through `setPointerStats`, because the reader
    /// takes `sinkLock` and the writer used not to. A closure is two words — a
    /// function pointer and a context — and storing one retains the incoming
    /// context while releasing the outgoing one; a concurrent read can retain a
    /// context that is being released to zero.
    private var pointerStats: (() -> (Int, Int))?

    func setPointerStats(_ block: (() -> (Int, Int))?) {
        sinkLock.lock()
        pointerStats = block
        sinkLock.unlock()
    }

    private(set) var audioFramesPlayed: UInt64 = 0

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
            guard let self, let renderer = self.audioRenderer else { return }
            renderer.playAudio(pcm)
            self.audioFramesPlayed &+= 1
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
        audioRenderer = AudioRenderer()

        onPhase?(.waitingForVideo)
        guard media.start() else {
            onPhase?(.failed("Could not open the media socket."))
            isRunning = false
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

    func stop(waitUntilDone: Bool = false) {
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
        audioRenderer?.stop()
        audioRenderer = nil
        Log.info("[session] stopped — \(mediaCounters.frames) frames, "
                 + "\(mediaCounters.dropped) damaged, \(audioFramesPlayed) audio packets")
    }

    // MARK: - Input

    /// One input event, as SMTInput built it. The sequence number, the
    /// redundancy and the repeat timer are MediaClient's.
    func sendInput(_ event: Data) {
        media.sendInput(event)
    }

    func requestKeyframe() {
        media.requestKeyframe()
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

    var attachedWindowCount: Int {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        return sinks.count
    }
}
