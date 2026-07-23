import Foundation
import AppKit
import SolStreamLogging
import VideoDecoder
import AudioRenderer
import InputCapture
import StreamConnection

/// A per-application window that renders the streamed desktop content.
///
/// Each streamed app on the Windows host gets its own NSWindow on macOS.
/// The window contains a MetalView (CAMetalLayer-backed) that renders
/// decoded video frames, and captures local keyboard/mouse input via
/// NSView event monitoring (no CGEventTap or Accessibility permission).
final class StreamWindow: NSObject {
    private let host: String
    private let appName: String
    private let frameRate: Int

    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var videoDecoder: VideoDecoder?
    private var audioRenderer: AudioRenderer?
    private var inputCapture: InputCapture?
    private var streamConnection: StreamConnection?

    private var isStreaming = false

    init(
        host: String,
        appName: String,
        width: Int,
        height: Int,
        frameRate: Int = 60
    ) {
        self.host = host
        self.appName = appName
        self.frameRate = frameRate
        super.init()
        setupWindow(width: width, height: height)
    }

    deinit {
        stopStreaming()
    }

    /// Show the streaming window.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Start the stream connection.
    func startStreaming() {
        guard !isStreaming else { return }

        metalView?.setStatus("Connecting to \(host)...")

        // Create frame callback: called by decoder when a new frame is ready.
        let onFrame: (CVPixelBuffer) -> Void = { [weak self] pixelBuffer in
            DispatchQueue.main.async {
                self?.metalView?.displayFrame(pixelBuffer)
            }
        }

        // Create the decoder.
        videoDecoder = VideoDecoder(frameCallback: onFrame)

        // Create the audio renderer.
        audioRenderer = AudioRenderer()

        // Create the stream connection (SRTP, control channel).
        streamConnection = StreamConnection(
            host: host,
            port: 47989,  // Sunshine control port
            videoPort: 47998,  // RTP video port
            audioPort: 48000,  // RTP audio port
            onVideoData: { [weak self] data in
                self?.videoDecoder?.decode(data)
            },
            onAudioData: { [weak self] data in
                self?.audioRenderer?.playAudio(data)
            }
        )

        isStreaming = true
        streamConnection?.connect()

        Log.info("Stream started: \(appName) from \(host)")
    }

    /// Stop the stream.
    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false

        streamConnection?.disconnect()
        videoDecoder?.flush()
        audioRenderer?.stop()

        streamConnection = nil
        videoDecoder = nil
        audioRenderer = nil

        Log.info("Stream stopped: \(appName)")
    }

    // MARK: - Private

    private func setupWindow(width: Int, height: Int) {
        let windowRect = NSRect(
            x: 0, y: 0,
            width: CGFloat(width),
            height: CGFloat(height)
        )

        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable,
            .fullSizeContentView
        ]

        let window = NSWindow(
            contentRect: windowRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = "SolStream — \(appName)"
        window.minSize = NSSize(width: 640, height: 480)

        // Create the Metal-backed content view.
        let metalView = MetalView(frame: windowRect)
        window.contentView = metalView
        self.metalView = metalView

        // Wire up input capture on the content view.
        inputCapture = InputCapture()
        if let inputCapture {
            inputCapture.attach(to: metalView)
        }

        window.delegate = self
        self.window = window
    }
}

// MARK: - NSWindowDelegate

extension StreamWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        stopStreaming()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // The window became focused — enable input capture.
        inputCapture?.enableCapture()
        Log.debug("Input capture enabled")
    }

    func windowDidResignKey(_ notification: Notification) {
        // The window lost focus — disable input capture.
        // This ensures no local input leaks to the remote host.
        inputCapture?.disableCapture()
        Log.debug("Input capture disabled")
    }
}


