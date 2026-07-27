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

    /// Watches for the application being closed on the host.
    private var lifeTimer: Timer?
    private var isClosing = false

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

        if remote.hidesCaptionWhenCropped {
            Log.info("[window] \"\(remote.title)\" has a standard title bar "
                     + "(\(remote.captionInset)px), which the crop already excludes")
        } else {
            // Not a failure: Explorer, Chrome, Discord and friends draw their
            // caption inside the client area, sharing that strip with tabs and
            // the address bar. Cropping the buttons away would take those too, so
            // the buttons stay — and closing from inside the stream has to work.
            Log.info("[window] \"\(remote.title)\" draws its own title bar, so its "
                     + "window buttons stay visible; watching for it to be closed")
        }
        startWatchingForExit()
    }

    /// Poll the host for this window still existing.
    ///
    /// Necessary whenever the application's own close button reaches the stream:
    /// the user can quit it from inside the video, and without this the macOS
    /// window would sit there showing whatever now occupies those pixels.
    private func startWatchingForExit() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            self.agent.windowStatus(id: self.remoteWindowID) { [weak self] status in
                // A dropped agent connection reports nil, not death. Closing the
                // window on a transient failure would be worse than doing nothing.
                guard let status, !status.isAlive else { return }
                DispatchQueue.main.async {
                    guard let self, !self.isClosing else { return }
                    Log.info("[window] the host application closed; ending the stream")
                    self.close()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
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
        // NSWindow created directly defaults to releasing itself on close, which
        // is a hangover from manual retain/release: ARC then releases it again
        // from the property below and the process dies in objc_release at the next
        // autorelease-pool drain. Only invisible while windows were closed solely
        // at app termination, when the process exits before that drain happens.
        window.isReleasedWhenClosed = false
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
        isClosing = true
        lifeTimer?.invalidate()
        lifeTimer = nil
        resizeWork?.cancel()
        agent.setTopmost(windowID: remoteWindowID, false)
        if let metalView {
            session.detach(metalView)
        }
        inputCapture?.disableCapture()

        // Deferred, and capturing the closure rather than self: onClose drops
        // this object's last strong reference, because the owner removes it from
        // its array. Calling it inline would deallocate self part-way through its
        // own delegate method, and NSWindow.delegate is a weak reference so
        // AppKit is not keeping us alive either.
        window?.delegate = nil
        let notify = onClose
        onClose = nil
        DispatchQueue.main.async { notify?() }
    }

    // MARK: - Status

    func setStatus(_ title: String, detail: String? = nil) {
        metalView?.setStatus(title, detail: detail)
    }

    func setError(_ title: String, detail: String? = nil) {
        metalView?.setError(title, detail: detail)
    }

    /// The fallback when the host cannot approve its own pairing: show the PIN and
    /// say where it goes.
    func setPairingPin(_ pin: String, host: String, reason: String?) {
        var detail = "Open https://\(host):47990 → PIN and enter the code above."
        if let reason, !reason.isEmpty {
            detail += "\n\(reason)"
        }
        metalView?.setStatus("Enter this PIN in Sunshine", detail: detail, pin: pin)
    }

    func hideStatus() {
        metalView?.hideStatus()
    }
}
