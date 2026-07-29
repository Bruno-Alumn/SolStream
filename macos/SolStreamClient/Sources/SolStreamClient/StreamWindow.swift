import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import InputCapture
import MediaSession
import AgentChannel

/// A window that renders one streamed host session.
///
/// Owns the decode → render path and the connection state machine's UI
/// reflection: the overlay shows pairing PINs, handshake progress, and errors
/// until the first frame arrives, at which point it gets out of the way.
final class StreamWindow: NSObject {
    private let host: String
    private let config: StreamConfig

    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var inputCapture: InputCapture?
    private let session: StreamSession

    private var isStreaming = false
    /// Once frames are flowing, earlier phases must not put the overlay back.
    private var hasReceivedVideo = false

    /// Called when the window closes so the app can decide whether to quit.
    var onClose: (() -> Void)?

    /// Show only this region of the streamed canvas, in canvas pixels. This is
    /// what makes one Sunshine stream into a single-application window: the
    /// agent puts the app's client area at a known rectangle, and we present
    /// only that rectangle.
    func setSourceRect(_ rect: CGRect?, canvasSize: CGSize) {
        metalView?.sourceRect = rect
        inputCapture?.sourceRect = rect
        inputCapture?.canvasSize = canvasSize

        if let rect, rect.width > 0, rect.height > 0 {
            window?.contentAspectRatio = NSSize(width: rect.width, height: rect.height)
            window?.setContentSize(NSSize(width: rect.width / 2, height: rect.height / 2))
        }
    }

    init(host: String, config: StreamConfig, session: StreamSession) {
        self.host = host
        self.config = config
        self.session = session
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

        metalView?.setStatus("Connecting to \(host)", detail: "Opening the media session…")
        if let metalView { session.attach(metalView) }

        session.onPhase = { [weak self] phase in
            DispatchQueue.main.async { self?.apply(phase: phase) }
        }
        session.setPointerStats { [weak self] in
            guard let capture = self?.inputCapture else { return (0, 0, 0) }
            return (capture.mouseMovedSeen, capture.positionsSent,
                    capture.droppedWhileResizing)
        }
        inputCapture?.onInput = { [weak self] event in
            self?.session.sendInput(event)
        }
        metalView?.onRetry = { [weak self] in
            self?.restart()
        }
        session.start()
        Log.info("[window] streaming from \(host)")
    }

    /// `waitUntilDone` is kept for the terminating path, where the session has
    /// to be quiet before anything its callbacks touch is released.
    func stopStreaming(waitUntilDone: Bool = false) {
        guard isStreaming else { return }
        isStreaming = false
        if let metalView { session.detach(metalView) }
        session.stop(waitUntilDone: waitUntilDone)
        Log.info("[window] stopped streaming from \(host)")
    }

    /// Test hook: place the host pointer at a normalised position within the
    /// video surface, so input can be verified without a human at the keyboard.
    func sendTestPointer(normalizedX: Double, normalizedY: Double) {
        guard let view = metalView else { return }
        let bounds = view.bounds
        let event = SMTInput.mouseMoveAbsolute(
            x: Int(Double(bounds.width) * normalizedX),
            y: Int(Double(bounds.height) * normalizedY),
            referenceWidth: Int(bounds.width),
            referenceHeight: Int(bounds.height))
        session.sendInput(event)
        Log.info("[input] test pointer -> \(normalizedX), \(normalizedY)")
    }

    /// A StreamSession cannot be restarted in place — stop() releases the
    /// decoder and start() does not build another — so recovery means a new
    /// session, which is the caller's to make.
    var onRetryRequested: (() -> Void)?

    private func restart() {
        stopStreaming()
        onRetryRequested?()
    }

    /// Mirror the connection phase into the overlay.
    private func apply(phase: StreamPhase) {
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
        case .opening:
            metalView.setStatus("Connecting to \(host)", detail: "Agreeing a key…")
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
        // See AppWindow.build(): a directly-created NSWindow releases itself on
        // close, which double-releases against the strong property below.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 640, height: 360)
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        // NSWindow does not receive mouse-moved events unless it asks. Without
        // this the window server never sends them to us at all, so hovering
        // moves nothing on the host and the pointer only tracks while dragging.
        window.acceptsMouseMovedEvents = true
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
        Log.info("[input] capture enabled (window is key, acceptsMouseMoved="
                 + "\(window?.acceptsMouseMovedEvents == true))")
    }

    func windowDidResignKey(_ notification: Notification) {
        // Never let local input leak to the remote host while unfocused.
        inputCapture?.disableCapture()
    }
}
