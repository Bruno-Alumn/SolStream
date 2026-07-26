import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import InputCapture
import StreamConnection

/// A window that renders one streamed host session.
///
/// Owns the decode → render path and the connection state machine's UI
/// reflection: the overlay shows pairing PINs, handshake progress, and errors
/// until the first frame arrives, at which point it gets out of the way.
final class StreamWindow: NSObject {
    private let host: String
    private let config: StreamConnection.Config

    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var videoDecoder: VideoDecoder?
    private var inputCapture: InputCapture?
    private var streamConnection: StreamConnection?

    private var isStreaming = false
    /// Once frames are flowing, earlier phases must not put the overlay back.
    private var hasReceivedVideo = false

    /// Called when the window closes so the app can decide whether to quit.
    var onClose: (() -> Void)?

    init(host: String, config: StreamConnection.Config = .init()) {
        self.host = host
        self.config = config
        super.init()
        setupWindow()
    }

    deinit {
        stopStreaming()
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Streaming

    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true
        hasReceivedVideo = false

        metalView?.setStatus("Connecting to \(host)", detail: "Checking pairing…")

        let decoder = VideoDecoder { [weak self] pixelBuffer in
            self?.metalView?.displayFrame(pixelBuffer)
        }
        videoDecoder = decoder
        // No AudioRenderer yet: Sunshine sends Opus over RTP and the renderer
        // only accepts PCM, so starting it would just hold the output device
        // open playing silence.

        let connection = StreamConnection(
            host: host,
            config: config,
            onVideoFrame: { [weak self] frame in
                self?.videoDecoder?.decode(frame.annexB, isIDR: frame.isIDR)
            },
            onAudioData: { _ in
                // Sunshine sends Opus in RTP; the renderer only takes PCM, so
                // audio stays muted until an Opus decoder is wired up.
            }
        )

        decoder.onKeyframeNeeded = { [weak connection] in
            connection?.requestKeyframe()
        }

        connection.onPhase = { [weak self] phase in
            self?.apply(phase: phase)
        }
        connection.onStatus = { [weak self] message in
            guard let self else { return }
            // Same late-arrival race as the phase updates: once video is on
            // screen, an older status must not put "Waiting for video" back in
            // the title bar.
            guard !self.hasReceivedVideo else { return }
            self.window?.subtitle = message
        }
        connection.onHandshakeComplete = { success in
            Log.info("[window] handshake \(success ? "complete" : "failed")")
        }

        streamConnection = connection
        metalView?.onRetry = { [weak self] in
            self?.restart()
        }
        connection.connect()

        Log.info("[window] streaming from \(host)")
    }

    /// `waitUntilDone` is required when the app is terminating — see
    /// StreamConnection.disconnect(waitUntilDone:).
    func stopStreaming(waitUntilDone: Bool = false) {
        guard isStreaming else { return }
        isStreaming = false

        streamConnection?.disconnect(waitUntilDone: waitUntilDone)
        // Drain and invalidate before dropping the reference: the VideoToolbox
        // callback holds an unretained pointer to the decoder.
        videoDecoder?.shutdown()

        streamConnection = nil
        videoDecoder = nil

        Log.info("[window] stopped streaming from \(host)")
    }

    private func restart() {
        stopStreaming()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.startStreaming()
        }
    }

    /// Mirror the connection phase into the overlay.
    private func apply(phase: StreamConnection.Phase) {
        guard let metalView else { return }

        if case .streaming = phase {
            hasReceivedVideo = true
        } else if hasReceivedVideo {
            // A resumed session delivers video before PLAY returns, so the
            // handshake's own phase updates can arrive *after* .streaming.
            // Only a hard failure may take the overlay back.
            if case .failed = phase {} else { return }
        }

        switch phase {
        case .idle:
            metalView.setStatus("Idle", busy: false)
        case .checkingPairing:
            metalView.setStatus("Connecting to \(host)", detail: "Checking pairing…")
        case .awaitingPin(let pin):
            metalView.setStatus("Enter this PIN in Sunshine",
                                detail: "Open https://\(host):47990 → PIN, then type the code above.",
                                pin: pin)
        case .pairing:
            metalView.setStatus("Pairing with \(host)", detail: "Exchanging keys…")
        case .launching:
            metalView.setStatus("Starting the session", detail: "Asking \(host) to launch the app…")
        case .handshaking(let step):
            metalView.setStatus("Negotiating stream", detail: step)
        case .waitingForVideo:
            metalView.setStatus("Waiting for video", detail: "The host is starting its encoder…")
        case .streaming:
            metalView.hideStatus()
            window?.subtitle = ""
        case .failed(let message):
            metalView.setError("Couldn't start the stream", detail: message)
        }
    }

    // MARK: - Window

    private func setupWindow() {
        let contentRect = NSRect(x: 0, y: 0,
                                 width: CGFloat(config.width) / 2,
                                 height: CGFloat(config.height) / 2)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "SolStream — \(host)"
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 640, height: 360)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentAspectRatio = NSSize(width: config.width, height: config.height)

        let metalView = MetalView(frame: contentRect)
        window.contentView = metalView
        self.metalView = metalView

        inputCapture = InputCapture()
        inputCapture?.attach(to: metalView)

        window.delegate = self
        self.window = window
    }
}

// MARK: - NSWindowDelegate

extension StreamWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopStreaming()
        onClose?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        inputCapture?.enableCapture()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never let local input leak to the remote host while unfocused.
        inputCapture?.disableCapture()
    }
}
