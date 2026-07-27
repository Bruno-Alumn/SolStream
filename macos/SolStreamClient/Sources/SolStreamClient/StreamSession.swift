import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import StreamConnection
import AudioRenderer

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

    private var audioDecoder: OpusDecoder?
    private var audioRenderer: AudioRenderer?
    private var lastAudioSequence: UInt16?
    /// Supplied by the focused window so the stats line can report input.
    var pointerStats: (() -> (Int, Int))?
    private(set) var audioFramesDecoded: UInt64 = 0
    private(set) var audioParityDropped: UInt64 = 0
    private(set) var audioGaps: UInt64 = 0

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
            onAudioData: { [weak self] datagram in
                self?.handleAudio(datagram)
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

        // Started here rather than in init: the renderer holds the output device
        // open, and a session that is built but never run should not take it.
        audioDecoder = OpusDecoder()
        if audioDecoder != nil {
            audioRenderer = AudioRenderer()
        }

        connection.onPhase = { [weak self] phase in
            self?.onPhase?(phase)
        }
        connection.onAudioStats = { [weak self] in
            (self?.audioFramesDecoded ?? 0, self?.audioParityDropped ?? 0)
        }
        // Pointer counters come from whichever window is capturing. Without this
        // the stats line reported moved=0/sent=0 for the single-application path
        // no matter how much the mouse moved — only the old whole-desktop window
        // ever set it, which made input look broken when it was working.
        connection.onPointerStats = { [weak self] in
            guard let self else { return (0, 0) }
            self.sinkLock.lock()
            defer { self.sinkLock.unlock() }
            return self.pointerStats?() ?? (0, 0)
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
        audioRenderer?.stop()
        audioRenderer = nil
        audioDecoder = nil
        Log.info("[session] stopped — audio: \(audioFramesDecoded) frames decoded, "
                 + "\(audioParityDropped) parity shards dropped, \(audioGaps) gap(s)")
    }

    // MARK: - Audio

    /// Turn one audio datagram into sound.
    ///
    /// Sunshine sends Opus behind a 12-byte RTP header, and interleaves
    /// Reed-Solomon parity shards into the same stream as separate packets with
    /// their own type. Feeding a parity shard to the decoder produces noise, so
    /// they are dropped: recovering a lost audio frame from parity is not worth
    /// the machinery when the frames are 5ms long and a gap is inaudible.
    ///
    /// Audio is not encrypted here — the SDP asks only for SS_ENC_CONTROL_V2, so
    /// Sunshine leaves audio in the clear.
    private func handleAudio(_ datagram: Data) {
        guard datagram.count > Self.rtpHeaderSize else { return }
        let packetType = datagram[datagram.startIndex + 1] & 0x7F
        guard packetType == Self.audioPacketType else {
            if packetType == Self.audioFecPacketType { audioParityDropped &+= 1 }
            return
        }

        let sequence = UInt16(datagram[datagram.startIndex + 2]) << 8
                     | UInt16(datagram[datagram.startIndex + 3])
        if let last = lastAudioSequence, sequence != last &+ 1 {
            // A gap means the next frame does not continue the last one.
            audioDecoder?.reset()
            audioGaps &+= 1
        }
        lastAudioSequence = sequence

        let opus = datagram.subdata(in: datagram.startIndex + Self.rtpHeaderSize ..< datagram.endIndex)
        guard let pcm = audioDecoder?.decode(opus) else { return }
        audioFramesDecoded &+= 1
        audioRenderer?.playAudio(pcm)
    }

    private static let rtpHeaderSize = 12
    private static let audioPacketType: UInt8 = 97
    private static let audioFecPacketType: UInt8 = 127

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
