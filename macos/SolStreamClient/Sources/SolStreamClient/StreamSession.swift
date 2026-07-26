import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import StreamConnection

/// One Sunshine session, feeding any number of windows.
///
/// This is what makes multiple application windows affordable. Sunshine serves
/// a single stream of the whole capture display, and it refuses a second
/// `/launch` outright ("An app is already running on this host"), so N windows
/// cannot mean N streams. Instead there is one connection and one hardware
/// decode, and every window blits a different sub-rectangle of the same decoded
/// frame — so a second window costs a blit, not a decoder.
final class StreamSession {
    let host: String

    /// The full streamed canvas, in pixels. Windows express their crops in it.
    private(set) var canvasSize: CGSize

    /// Implicitly unwrapped so the frame closure can capture self during init:
    /// every stored property has a value (nil) by the time it is built.
    private(set) var connectionRef: StreamConnection!
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

    var onPhase: ((StreamConnection.Phase) -> Void)?

    var connection: StreamConnection { connectionRef }

    init(host: String, config: StreamConnection.Config) {
        self.host = host
        self.canvasSize = CGSize(width: config.width, height: config.height)

        // One decoder, fanned out to every attached window. Each window carries
        // its own sourceRect, so they all read the same CVPixelBuffer and blit
        // different regions of it.
        let decoder = VideoDecoder { [weak self] pixelBuffer in
            guard let self else { return }
            self.sinkLock.lock()
            let views = self.sinks
            self.sinkLock.unlock()
            for view in views {
                view.displayFrame(pixelBuffer)
            }
        }
        self.decoder = decoder

        connectionRef = StreamConnection(
            host: host,
            config: config,
            onVideoFrame: { [weak decoder] frame in
                decoder?.decode(frame.annexB, isIDR: frame.isIDR)
            },
            onAudioData: { _ in
                // Sunshine sends Opus; no decoder wired up yet.
            }
        )
        decoder.onKeyframeNeeded = { [weak self] in
            self?.connectionRef.requestKeyframe()
        }
    }

    /// Start the stream. Frames go to every attached window.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        connection.onPhase = { [weak self] phase in
            self?.onPhase?(phase)
        }
        connection.connect()
        Log.info("[session] started for \(host), canvas \(Int(canvasSize.width))x\(Int(canvasSize.height))")
    }

    func stop(waitUntilDone: Bool = false) {
        guard isRunning else { return }
        isRunning = false
        connection.disconnect(waitUntilDone: waitUntilDone)
        // Drain the decoder before dropping the sinks: its callback runs on a
        // VideoToolbox thread and is what hands frames to the views.
        decoder?.shutdown()
        decoder = nil
        sinkLock.lock()
        sinks.removeAll()
        sinkLock.unlock()
        Log.info("[session] stopped")
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
