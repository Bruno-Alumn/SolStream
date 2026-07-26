import AppKit
import SolStreamLogging
import VideoDecoder
import InputCapture
import StreamConnection

/// A native macOS window showing one Windows application.
///
/// It owns no stream of its own: it attaches to a shared `StreamSession` and
/// presents the sub-rectangle of the canvas where the agent has placed its
/// window. Several of these can exist over a single stream.
final class AppWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var inputCapture: InputCapture?

    private let session: StreamSession
    private let agent: AgentConnection
    private let remoteWindowID: UInt64
    private let display: RemoteDisplay

    /// Where this window's client area sits on the capture display.
    private(set) var tile: CGRect

    /// Coalesces live-resize into one placement request per settle.
    private var resizeWork: DispatchWorkItem?

    var onClose: (() -> Void)?

    init(session: StreamSession, agent: AgentConnection,
         remote: RemoteWindow, display: RemoteDisplay, tile: CGRect) {
        self.session = session
        self.agent = agent
        self.remoteWindowID = remote.id
        self.display = display
        self.tile = tile
        super.init()
        build(title: remote.title)
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// Point this window at a different region of the canvas.
    func setTile(_ rect: CGRect) {
        tile = rect
        let crop = CGRect(x: rect.minX - CGFloat(display.x),
                          y: rect.minY - CGFloat(display.y),
                          width: rect.width, height: rect.height)
        metalView?.sourceRect = crop
        inputCapture?.sourceRect = crop
        inputCapture?.canvasSize = session.canvasSize
        // Deliberately NO contentAspectRatio. The remote window resizes to match
        // whatever shape we are dragged into, so locking the aspect would stop
        // the very thing that makes this feel native — stretch either axis and
        // the Windows app reflows, exactly as a local window would.
    }

    // MARK: - Window

    private func build(title: String) {
        let content = NSRect(x: 0, y: 0, width: tile.width / 2, height: tile.height / 2)
        let window = NSWindow(contentRect: content,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 320, height: 200)
        // Without this the window server never delivers mouse-moved events, so
        // hovering would move nothing on the host.
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        let view = MetalView(frame: content)
        window.contentView = view
        metalView = view

        let capture = InputCapture()
        capture.attach(to: view)
        capture.onInput = { [weak self] packet in
            self?.session.connection.sendInput(packet)
        }
        inputCapture = capture

        self.window = window
        session.attach(view)
        setTile(tile)

        // Nothing may cover the tile: the crop would stream it as though it
        // were part of the app.
        agent.setTopmost(windowID: remoteWindowID, true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Resizing the macOS window resizes the real Windows window. Debounced:
        // live-resize fires continuously, and SetWindowPos per frame would make
        // the host app thrash.
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyResize() }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func applyResize() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        // Ask for the size in host pixels, using the window's backing scale so a
        // Retina window does not request half the pixels it can display.
        let scale = screen.backingScaleFactor
        let size = window.contentView?.bounds.size ?? .zero
        let requested = CGRect(x: tile.minX, y: tile.minY,
                               width: (size.width * scale).rounded(),
                               height: (size.height * scale).rounded())
        guard requested.width >= 1, requested.height >= 1 else { return }

        agent.place(windowID: remoteWindowID, at: requested) { [weak self] achieved in
            guard let self, let achieved else { return }
            DispatchQueue.main.async {
                // Follow what the host actually did: an app with a minimum size
                // will refuse, and the crop must match reality, not the request.
                self.setTile(achieved)
                Log.info("[window] resized to \(Int(achieved.width))x\(Int(achieved.height))")
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        inputCapture?.enableCapture()
        // Give the host window focus too, so keystrokes land in the right app.
        agent.focus(windowID: remoteWindowID)
    }

    func windowDidResignKey(_ notification: Notification) {
        inputCapture?.disableCapture()
    }

    func windowWillClose(_ notification: Notification) {
        agent.setTopmost(windowID: remoteWindowID, false)
        if let metalView {
            session.detach(metalView)
        }
        inputCapture?.disableCapture()
        onClose?()
    }

    // MARK: - Status

    func setStatus(_ title: String, detail: String? = nil) {
        metalView?.setStatus(title, detail: detail)
    }

    func setError(_ title: String, detail: String? = nil) {
        metalView?.setError(title, detail: detail)
    }

    func hideStatus() {
        metalView?.hideStatus()
    }
}
