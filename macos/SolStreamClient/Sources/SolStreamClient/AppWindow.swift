import AppKit
import DesignSystem
import SolStreamLogging
import VideoDecoder
import InputCapture
import MediaSession
import AgentChannel

/// A native macOS window showing one Windows application.
///
/// It owns no stream of its own: it attaches to a shared `StreamSession` and
/// presents the sub-rectangle of the canvas where the agent has placed its
/// window. Several of these can exist over a single stream.
final class AppWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var inputCapture: InputCapture?

    /// Not `let`: when the stream is lost and restarted, the window stays and
    /// moves to the new session — see `rebind(to:)`.
    private var session: StreamSession
    private let agent: AgentConnection
    /// The host window this one is showing. Not private: the agent pushes
    /// closures by id, and the owner has to know which window it means.
    let remoteWindowID: UInt64
    private let display: RemoteDisplay

    /// Where this window's client area sits on the capture display.
    private(set) var tile: CGRect

    /// The title bar the application draws inside its own window, in host
    /// pixels at the top of `tile`, as the host last measured it; zero when it
    /// draws none there.
    private var hostTitleBar: CGFloat = 0
    /// Whether that strip is left out of the picture. Off until chosen in the
    /// pill's popover, then kept per program -- see `adoptTitleBar`.
    private var hidesTitleBar = false
    /// The program that owns the host window, "Discord.exe", once the host
    /// has named it.
    private var program = ""
    /// The last placement, so a change to the crop can apply its limits again.
    private var lastPlacement: AgentConnection.Placement?

    /// The capture display, in virtual-desktop coordinates. Nothing outside this
    /// is in the stream at all.
    private var displayRect: CGRect {
        CGRect(x: display.x, y: display.y, width: display.width, height: display.height)
    }

    /// One `place` in flight at a time — see `requestResize`.
    private var resizeInFlight = false
    /// The one automatic fit after opening has been scheduled; see `settleOnce`.
    private var didSettle = false
    private var resizeAgain = false
    private var wantsSettle = false

    /// Watches for the application being closed on the host.
    private var lifeTimer: Timer?
    private var statusInFlight = false
    private var isClosing = false
    /// Set while this window is being resized to match the host, so the resize
    /// handler does not bounce the request straight back at it.
    private var isMatchingHostSize = false

    private let pill = QualityPill()
    /// Says how to get the mouse back, the first time this window takes it.
    private let captureHint = CaptureHint()
    private var hasExplainedCapture = false
    private var qualityTimer: Timer?
    private var lastFrameCount: UInt64 = 0
    private var lastByteCount: UInt64 = 0
    private var lastSample = Date()

    var onClose: (() -> Void)?
    /// This window has taken the keyboard or given it up. A paste is likely to
    /// follow on whichever machine now has it, which is the moment the
    /// clipboard has to be in step.
    var onKeyboardChange: (() -> Void)?

    /// Backstop for any path that deallocates the window without a close
    /// notification — a run-loop timer outlives its target quite happily.
    deinit {
        lifeTimer?.invalidate()
        qualityTimer?.invalidate()
    }

    init(session: StreamSession, agent: AgentConnection,
         remote: RemoteWindow, display: RemoteDisplay, tile: CGRect) {
        self.session = session
        self.agent = agent
        self.remoteWindowID = remote.id
        self.display = display
        self.tile = tile
        super.init()
        build(title: remote.title,
              naturalSize: remote.naturalSize)
        pill.onTitleBarChosen = { [weak self] hides in self?.setHidesTitleBar(hides) }

        if remote.hidesCaptionWhenCropped {
            Log.info("[window] \"\(remote.title)\" has a standard title bar "
                     + "(\(remote.captionInset)px), which the crop already excludes")
        } else {
            // Not a failure: Explorer, Chrome, Discord and friends draw their
            // caption inside the client area, sharing that strip with tabs and
            // the address bar. Cropping the buttons away would take those too, so
            // the buttons stay unless the person hides the strip from the pill --
            // and closing from inside the stream has to work.
            Log.info("[window] \"\(remote.title)\" draws its own title bar, so its "
                     + "window buttons stay visible; watching for it to be closed")
        }
        startWatchingForExit()
    }

    /// Sample the stream once a second for the pill.
    ///
    /// Rates are differenced from cumulative counters rather than read from a
    /// running average, so a stall shows up as the number falling to zero instead
    /// of decaying slowly towards it.
    private func startPollingQuality() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastSample)
            guard elapsed > 0.2 else { return }

            let snapshot = self.session.mediaCounters
            let frames = snapshot.frames &- self.lastFrameCount
            let bytes = snapshot.bytes &- self.lastByteCount
            self.lastFrameCount = snapshot.frames
            self.lastByteCount = snapshot.bytes
            self.lastSample = now

            var stats = QualityPill.Stats()
            stats.fps = Int((Double(frames) / elapsed).rounded())
            stats.bitrateMbps = Double(bytes) * 8 / elapsed / 1_000_000
            stats.latencyMs = snapshot.latencyMs
            stats.droppedFrames = snapshot.dropped
            stats.totalFrames = snapshot.frames
            stats.audioActive = snapshot.audioFrames > 0
            stats.hostIgnoresSoundQuality = self.session.hostIgnoresSoundQuality
            stats.hostSendsWholePC = self.session.hostSendsWholePC
            stats.hostDisplay = "\(self.display.name.replacingOccurrences(of: "\\\\.\\", with: "")) "
                + "· \(self.display.width)×\(self.display.height)"
            stats.hostReportsCursor = self.inputCapture?.hostReportsCursorVisibility ?? false
            self.pill.stats = stats
        }
        RunLoop.main.add(timer, forMode: .common)
        qualityTimer = timer
    }

    /// End the session because the application has gone on the host.
    ///
    /// Called from the host's push and from the poll below, whichever notices
    /// first; `isClosing` makes the second one a no-op. `noticedBy` says which
    /// did, because "the push never arrived and the backstop caught it a second
    /// later" and "the push worked" look identical from the outside.
    func hostWindowClosed(noticedBy route: String) {
        guard !isClosing else { return }
        Log.info("[window] the host application closed (\(route)); ending the stream")
        close()
    }

    /// Poll the host for this window still existing.
    ///
    /// A backstop behind the host's own push, not the primary route: the agent
    /// reports a closure the moment its watcher sees it, and this catches the
    /// case where that notice never arrives — a push sent while the socket was
    /// being replaced, or an agent old enough not to send one at all.
    ///
    /// Every five seconds, and never more than one in flight: the push covers
    /// the common case, and a host stuck on a slow request must not have a
    /// queue of these building up behind it.
    private func startWatchingForExit() {
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing, !self.statusInFlight else { return }
            self.statusInFlight = true
            self.agent.windowStatus(id: self.remoteWindowID) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.statusInFlight = false
                    // A dropped agent connection reports nil, not death. Closing
                    // the window on a transient failure would be worse than
                    // doing nothing.
                    guard let status else { return }
                    if status.isAlive {
                        self.reportOcclusion(status)
                    } else {
                        self.hostWindowClosed(noticedBy: "poll")
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lifeTimer = timer
    }

    /// Where the next streamed window should be placed, so two of them do not
    /// land on top of each other.
    ///
    /// Every window is built at the same default rectangle, so streaming two
    /// applications opened one exactly behind the other: the log said two
    /// windows were attached, the screen showed one, and the second was only
    /// reachable through the Window menu. AppKit's own cascade is the answer it
    /// uses for document windows, which is the same problem.
    private static var cascadePoint = NSPoint.zero

    /// How much of the screen a window may take when it opens. Not a limit on
    /// the window — it resizes to anything afterwards — just a starting size that
    /// leaves the desktop visible around it.
    static let openingScreenFraction: CGFloat = 0.72

    /// The size, in points, that a window showing a host window this big should
    /// open at. Pure, so the rule can be tested without a screen.
    static func openingSize(hostPixels: CGSize, scale: CGFloat, visible: CGSize) -> CGSize {
        let room = CGSize(width: visible.width * openingScreenFraction,
                          height: visible.height * openingScreenFraction)
        guard hostPixels.width > 0, hostPixels.height > 0, scale > 0 else {
            return room
        }
        let points = CGSize(width: hostPixels.width / scale, height: hostPixels.height / scale)
        // One factor for both axes: a window that has to come down keeps the
        // application's proportions instead of being squashed on whichever axis
        // was the tighter fit. Never above 1 — this only ever shrinks, because
        // stretching a small application to a "nicer" size would be worse than
        // any size it chose for itself.
        let shrink = min(1, min(room.width / points.width, room.height / points.height))
        return CGSize(width: (points.width * shrink).rounded(),
                      height: (points.height * shrink).rounded())
    }

    func show() {
        if let window {
            if Self.cascadePoint == .zero {
                // Centre the first one, then cascade from there.
                //
                // The window is built at origin (0,0), which in macOS is the
                // BOTTOM-left of the screen. That went unnoticed while every
                // streamed window was very nearly screen-sized — it had nowhere
                // to sit but roughly where it belonged. Opening applications at
                // their own size made it plain: Character Map appeared in the
                // bottom-left corner, half of it below the edge of the display.
                window.center()
                Self.cascadePoint = window.cascadeTopLeft(from: .zero)
            } else {
                Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// Whether the last poll said something was covering the host window, so
    /// the overlay is only touched when the answer changes.
    private var wasOccluded = false

    /// Say when something on the PC is covering the streamed window.
    ///
    /// The crop is a rectangle on a shared display, so anything drawn over the
    /// tile — a firewall prompt, say — arrives looking exactly like part of the
    /// application.
    ///
    /// Said in the title bar, not on the status overlay: `MetalView.present()`
    /// hides the overlay on every frame, and a covered window goes on
    /// delivering frames. The subtitle is also where the host's own `occluded`
    /// push says it, so the two routes agree.
    private func reportOcclusion(_ status: RemoteWindowStatus) {
        guard !isClosing, status.isOccluded != wasOccluded else { return }
        wasOccluded = status.isOccluded
        if status.isOccluded {
            let culprit = status.occludedBy.flatMap { $0.isEmpty ? nil : $0 }
            Log.info("[window] something on the host is covering this window"
                     + (culprit.map { ": \($0)" } ?? ""))
            // The host does not always know what is on top — an unnamed window,
            // or one belonging to a process it cannot open — and "covered by
            // something" is still worth saying when the name is missing.
            setOccludedBy(culprit ?? "Something")
        } else {
            Log.info("[window] the host window is clear again")
            setOccludedBy(nil)
        }
    }

    /// Show the cursor the host is showing, so hovering a text field over the
    /// stream gives an I-beam here too.
    func setRemoteCursor(_ cursor: NSCursor) {
        metalView?.remoteCursor = cursor
    }

    /// The host's cursor changed: its shape, by name, as the agent pushes it,
    /// or "hidden" when it has none on screen.
    ///
    /// Hidden still draws an arrow over the picture -- see
    /// `HostCursor.macCursor` -- and goes to the input capture, which in
    /// gaming mode takes the mouse for the game and gives it back when a shape
    /// returns.
    ///
    /// The host speaks only on a change, so this wants calling once as the
    /// window opens as well, with the last push the connection heard: a game
    /// already in play has nothing new to say, and a window that never hears
    /// "hidden" takes the mouse on a click and keeps it through the first
    /// pause menu. Nothing is kept from one window for the next instead: no
    /// window hears the pushes sent while the picker has the connection, so
    /// whatever was kept would be stale.
    /// - Parameter reportsHidden: the push said the host reports a hidden
    ///   cursor at all, so gaming mode follows it from here rather than after
    ///   seeing a whole hide and show.
    func hostCursorChanged(_ shape: String, reportsHidden: Bool = false) {
        setRemoteCursor(HostCursor.macCursor(for: shape))
        guard let capture = inputCapture else { return }
        if reportsHidden { capture.hostReportsCursorVisibility = true }
        capture.hostCursorVisibilityChanged(hidden: HostCursor.isHidden(shape))
    }

    /// Show the note on the first capture, and take it away when the mouse is
    /// given back: by then it is out of date.
    private func pointerCaptureChanged(_ captured: Bool) {
        guard captured else {
            captureHint.dismiss()
            return
        }
        guard !hasExplainedCapture else { return }
        hasExplainedCapture = true
        captureHint.flash()
    }

    /// Point this window at a different region of the canvas: the host
    /// window's client area, of which the picture shows `picture(of:)`.
    func setTile(_ rect: CGRect) {
        tile = rect
        let shown = picture(of: rect)
        let crop = CGRect(x: shown.minX - CGFloat(display.x),
                          y: shown.minY - CGFloat(display.y),
                          width: shown.width, height: shown.height)
        metalView?.sourceRect = crop
        inputCapture?.sourceRect = crop
        inputCapture?.canvasSize = session.canvasSize
        // Deliberately NO contentAspectRatio. The remote window resizes to match
        // whatever shape we are dragged into, so locking the aspect would stop
        // the very thing that makes this feel native — stretch either axis and
        // the Windows app reflows, exactly as a local window would.
    }

    // MARK: - The application's own title bar

    /// Host pixels left off the top of the host window's client area.
    private var hiddenStrip: CGFloat { hidesTitleBar ? hostTitleBar : 0 }

    /// The part of the host window's client area `rect` that the picture shows:
    /// all of it, or all but the application's own title bar. The crop and the
    /// pointer both follow this, so a click lands where it was aimed either way.
    private func picture(of rect: CGRect) -> CGRect {
        let strip = min(hiddenStrip, max(rect.height - 1, 0))
        return CGRect(x: rect.minX, y: rect.minY + strip,
                      width: rect.width, height: rect.height - strip)
    }

    /// Take the host's measurement of the application's own title bar, and the
    /// choice kept for this program the first time the host names it.
    private func adoptTitleBar(_ placement: AgentConnection.Placement) {
        if program.isEmpty, !placement.program.isEmpty {
            program = placement.program
            hidesTitleBar = StreamSettings.shared.hidesTitleBar(of: program)
            if hidesTitleBar {
                Log.info("[window] leaving \(program)'s own title bar out of the picture, as chosen before")
            }
        }
        hostTitleBar = placement.titleBarHeight
        pill.hidesTitleBar = hostTitleBar > 0 ? hidesTitleBar : nil
    }

    /// Leave the application's own title bar out of the picture, or put it back.
    ///
    /// This window loses or gains the strip and the host window keeps its size,
    /// so the application does not lay itself out again, and nothing goes to
    /// the host but the pointer's new mapping.
    private func setHidesTitleBar(_ hides: Bool) {
        guard hides != hidesTitleBar, !isClosing else { return }
        hidesTitleBar = hides
        if !program.isEmpty {
            StreamSettings.shared.setHidesTitleBar(hides, of: program)
        }
        Log.info("[window] \(hides ? "hiding" : "showing") the application's own title bar "
                 + "(\(Int(hostTitleBar)) px)")
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let shown = picture(of: tile)
        if let lastPlacement {
            applySizeLimits(lastPlacement, achieved: shown, scale: scale)
        }
        setTile(tile)
        matchWindow(to: shown, scale: scale)
    }

    // MARK: - Window

    private func build(title: String, naturalSize: CGSize) {
        // Open at the size the application already is, not at the size of the
        // tile it may grow into (for one application that is the whole capture
        // display), converted by the backing scale and capped well short of
        // the screen — see `openingSize`.
        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let wanted = naturalSize.width > 0 && naturalSize.height > 0 ? naturalSize : tile.size
        let content = NSRect(origin: .zero,
                             size: Self.openingSize(hostPixels: wanted, scale: scale,
                                                    visible: visible))
        let window = NSWindow(contentRect: content,
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        // An NSWindow created directly releases itself on close, which ARC then
        // releases again from the property below: a crash at the next drain.
        window.isReleasedWhenClosed = false
        // Solar's `ground` behind a transparent title bar, held in the dark
        // appearance whatever the Mac's: a video frame belongs in a dark frame,
        // and in the light appearance AppKit would draw the title black on
        // near-black and the pill grey on grey.
        window.backgroundColor = DS.ground
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 320, height: 200)
        // Without this the window server never delivers mouse-moved events, so
        // hovering would move nothing on the host.
        window.acceptsMouseMovedEvents = true
        window.delegate = self

        let view = MetalView(frame: content)
        window.contentView = view
        metalView = view

        // Over the picture rather than in the title bar: it is about the
        // pointer, which has just vanished from exactly there.
        view.addSubview(captureHint)
        NSLayoutConstraint.activate([
            captureHint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captureHint.topAnchor.constraint(equalTo: view.topAnchor, constant: DS.Space.x4),
            captureHint.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor,
                                               constant: -2 * DS.Space.x4),
        ])

        let capture = InputCapture()
        capture.attach(to: view)
        capture.sendsScanCodes = session.hostTakesScanCodes
        capture.hostName = session.host
        capture.onInput = { [weak self] packet in
            self?.session.sendInput(packet)
        }
        capture.acceptsInput = { [weak self] in
            self?.session.acceptsInput ?? false
        }
        capture.onPointerCaptureChanged = { [weak self] captured in
            self?.pointerCaptureChanged(captured)
        }
        inputCapture = capture
        // An emoji from the Character Viewer, or dictation, goes to the PC
        // as the text it is. The view must have the keyboard focus for the
        // system to offer either.
        view.onInsertText = { [weak capture] text in capture?.sendText(text) }
        window.initialFirstResponder = view
        window.makeFirstResponder(view)

        // The quality pill lives in the title bar accessory so it sits in the
        // chrome rather than over the application, and never moves as the window
        // resizes.
        let accessory = NSTitlebarAccessoryViewController()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 78, height: 22))
        pill.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
            pill.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        accessory.view = holder
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)

        self.window = window
        session.attach(view)
        setTile(tile)
        startPollingQuality()

        // Nothing may cover the tile: the crop would stream it as though it
        // were part of the app.
        agent.setTopmost(windowID: remoteWindowID, true)
        // The resize lock is taken AFTER the first placement, not here: locking
        // records the window's current geometry as the one to enforce, and until
        // it has been placed on its tile that is the wrong rectangle.
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        // Resizing the macOS window resizes the real Windows window while the
        // drag is happening, not after it, at whatever rate the host keeps up
        // with — see `requestResize`.
        guard !isMatchingHostSize else { return }
        requestResize()
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        // The user is dragging the frame, not working in the application. Left
        // running, the pointer sits on the host window's own edge while both
        // sides are being resized, and the host starts a resize of its own on
        // top of ours — which is where the glitching during a drag comes from.
        inputCapture?.isSuspended = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        inputCapture?.isSuspended = false
        guard !isMatchingHostSize else { return }
        // The final size matters more than any intermediate one, and the last
        // live update may have been coalesced away — so always send one more,
        // and this time let the window settle onto whatever the host managed.
        requestResize(settle: true)
    }

    /// Push this window's size to the host, at whatever rate the host keeps up
    /// with.
    ///
    /// Sends immediately when nothing is outstanding; if the user keeps dragging
    /// while a `place` is in flight, that is remembered and one more goes out
    /// when the reply lands. The rate then self-adapts to the round trip instead
    /// of guessing an interval, and no more than one request is ever queued
    /// behind the user's hand — a queue is what would make the window lag rather
    /// than track.
    private func requestResize(settle: Bool = false) {
        if settle { wantsSettle = true }
        guard !resizeInFlight else {
            resizeAgain = true
            return
        }
        resizeInFlight = true
        resizeAgain = false
        let settling = wantsSettle
        wantsSettle = false
        syncGeometry(matchBack: settling) { [weak self] in
            guard let self else { return }
            self.resizeInFlight = false
            if self.resizeAgain || self.wantsSettle { self.requestResize() }
        }
    }

    /// Say everything the host has forgotten.
    ///
    /// A dropped agent connection runs `UnlockAll` on the host, which hands
    /// every managed window its resize border back, drops it out of the topmost
    /// band and puts it back where it was before the session — on the real
    /// desktop, not the virtual display this crop is taken from. So a reconnect
    /// is not just a socket coming back: without this the picture stays live
    /// while showing whatever now occupies those pixels.
    func reassertOnHost() {
        guard !isClosing else { return }
        Log.info("[window] agent reconnected; re-applying this window's placement")
        agent.setTopmost(windowID: remoteWindowID, true)
        placeAndLock()
    }

    /// Place the host window to match this one, then stop it being resized there.
    ///
    /// The initial placement goes through exactly the same path as a drag, so
    /// there is one rule for how big the host window is: whatever this window is.
    /// Placing the raw tile instead would size the host window to the entire
    /// display while this one is smaller, and the mismatch is drawn as bars.
    func placeAndLock() {
        syncGeometry { [weak self] in
            // `isClosing`, or a `place` still in flight when the user closes the
            // window comes back afterwards and locks a window that has already
            // been released. The host claims a fresh slot, records a restore
            // obligation against the already-restored state, and strips the
            // resize border again — and nothing will ever send `lock off` for
            // that id, because this object is gone. The application is left
            // running with no resize border and no maximise box, snapped back by
            // the watcher every time it is dragged. `place` is a cross-process
            // SetWindowPos that blocks on the target's message pump, so on an
            // application still starting up the window is easy to close first.
            guard let self, !self.isClosing else { return }
            self.agent.setResizeLock(windowID: self.remoteWindowID, true)
            self.settleOnce()
        }
    }

    /// One more fit, a moment after the window first opens.
    ///
    /// The first placement lands while the application is still reacting to
    /// the move: carried onto the 200% capture display it gets WM_DPICHANGED,
    /// and many applications -- Electron and Chromium ones especially -- lay
    /// themselves out again a beat later, at a size or position the first
    /// reply never saw. The picture and this window then disagreed until the
    /// user nudged the window edge, which is exactly the "resize it once and it
    /// updates" chore this does for them. Same path as that nudge, and a no-op
    /// when nothing moved.
    private func settleOnce() {
        guard !didSettle else { return }
        didSettle = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.isClosing,
                  !(self.window?.inLiveResize ?? false) else { return }
            self.requestResize(settle: true)
        }
    }

    /// - Parameter matchBack: whether to snap this window onto the size the host
    ///   actually achieved. Never mid-drag: the user's hand owns the window
    ///   then, and resizing it under them fights the drag.
    private func syncGeometry(matchBack: Bool = true, _ completion: (() -> Void)? = nil) {
        guard let window, let screen = window.screen ?? NSScreen.main else {
            completion?()
            return
        }
        // Ask for the size in host pixels, using the window's backing scale so a
        // Retina window does not request half the pixels it can display -- and
        // with the application's own title bar on top when the picture leaves
        // it out, so what shows is as big as this window.
        let scale = screen.backingScaleFactor
        let size = window.contentView?.bounds.size ?? .zero
        let strip = hiddenStrip

        // Never ask for more than the capture display holds. The host will
        // happily size a window past the edge of its display, and the part that
        // hangs off is simply not in the captured frame — so the crop ends up
        // partly outside the canvas and the window fills with desktop.
        let maxWidth = CGFloat(display.width)
        let maxHeight = CGFloat(display.height)
        let wanted = CGSize(width: min((size.width * scale).rounded(), maxWidth),
                            height: min((size.height * scale).rounded() + strip, maxHeight))
        let origin = CGPoint(x: min(tile.minX, CGFloat(display.x) + maxWidth - wanted.width),
                             y: min(tile.minY, CGFloat(display.y) + maxHeight - wanted.height))
        let requested = CGRect(origin: origin, size: wanted)
        guard requested.width >= 1, requested.height >= 1 else {
            completion?()
            return
        }

        agent.place(windowID: remoteWindowID, at: requested) { [weak self] placement in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { completion?() }
                guard let placement else { return }
                let achieved = placement.frame
                // Follow what the host actually did, then clip to the canvas.
                //
                // An application can refuse to be as small as we asked — and it
                // can refuse to be small enough to FIT. A DPI-unaware application
                // on a 200% display is scaled by Windows, so LibreOffice's
                // ~1417px minimum height becomes 2834 real pixels, taller than
                // this whole display. Only the part on the display is captured,
                // so the visible rectangle is what the crop and this window must
                // both follow. Matching the unclipped size instead is what draws
                // bars: the window ends up a different shape from the picture.
                let visible = achieved.intersection(self.displayRect)
                self.adoptTitleBar(placement)
                self.lastPlacement = placement
                let shown = self.picture(of: visible)
                self.applySizeLimits(placement, achieved: shown, scale: scale)
                if placement.resizeBorder > 0 {
                    self.inputCapture?.edgeGuard = placement.resizeBorder
                }
                guard visible.width >= 1, visible.height >= 1 else { return }
                self.setTile(visible)
                if matchBack {
                    self.matchWindow(to: shown, scale: scale)
                }
                if visible != achieved {
                    Log.info("[window] host window \(Int(achieved.width))x\(Int(achieved.height))"
                             + " does not fit the display; showing "
                             + "\(Int(visible.width))x\(Int(visible.height))")
                } else {
                    // Both numbers, always. This logged only what the host
                    // achieved, so a placement that missed by fifty pixels and one
                    // that landed exactly wrote indistinguishable lines — and since
                    // this window then resizes itself to match whatever came back,
                    // there was nothing anywhere to say the two ends had agreed on
                    // the wrong rectangle. `missed` is the host's own residual
                    // after it has corrected itself as far as it can, so anything
                    // above zero is the application refusing the size rather than
                    // SolStream getting it wrong.
                    let asked = "\(Int(requested.width))x\(Int(requested.height))"
                    let got = "\(Int(achieved.width))x\(Int(achieved.height))"
                    if placement.missed > 2 {
                        Log.info("[window] asked the host for \(asked), settled at \(got)"
                                 + " at \(Int(achieved.minX)),\(Int(achieved.minY))"
                                 + " — \(placement.missed) px out, so the application"
                                 + " is refusing that size")
                    } else {
                        Log.info("[window] host window \(got)"
                                 + " at \(Int(achieved.minX)),\(Int(achieved.minY))")
                    }
                }
            }
        }
    }

    /// Hold this window to the sizes the host application accepts.
    ///
    /// A window the application cannot resize -- no sizing border, a dialog
    /// laid out once -- is held at exactly the size it is: dragging it smaller
    /// here would only crop its controls off on the PC, which is what letting
    /// any size through used to do. A resizable one gets the application's own
    /// minimum and, when it declares one, its maximum -- less the
    /// application's own title bar when the picture leaves it out.
    ///
    /// - Parameter achieved: what the picture shows of the host window.
    private func applySizeLimits(_ placement: AgentConnection.Placement,
                                 achieved: CGRect, scale: CGFloat) {
        guard let window, scale > 0 else { return }
        let strip = hiddenStrip
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.size
        func points(_ pixels: CGSize) -> NSSize {
            var size = NSSize(width: (pixels.width / scale).rounded(),
                              height: (pixels.height / scale).rounded())
            if let screen {
                size.width = min(size.width, screen.width)
                size.height = min(size.height, screen.height)
            }
            return size
        }

        if !placement.isResizable {
            guard achieved.width >= 1, achieved.height >= 1 else { return }
            let fixed = points(achieved.size)
            guard window.contentMinSize != fixed || window.contentMaxSize != fixed
                  || window.styleMask.contains(.resizable) else { return }
            window.contentMinSize = fixed
            window.contentMaxSize = fixed
            window.styleMask.remove(.resizable)
            Log.info("[window] the host application cannot be resized; holding this window at "
                     + "\(Int(fixed.width))x\(Int(fixed.height)) points")
            return
        }

        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        applyMinimumSize(CGSize(width: placement.minimumSize.width,
                                height: max(placement.minimumSize.height - strip, 1)),
                         scale: scale)
        var maximum = placement.maximumSize
        if maximum.height > 0 { maximum.height = max(maximum.height - strip, 1) }
        if maximum.width > 0 || maximum.height > 0 {
            let limit = points(CGSize(width: maximum.width > 0 ? maximum.width : .greatestFiniteMagnitude,
                                      height: maximum.height > 0 ? maximum.height : .greatestFiniteMagnitude))
            let ceiling = NSSize(width: max(limit.width, window.contentMinSize.width),
                                 height: max(limit.height, window.contentMinSize.height))
            if window.contentMaxSize != ceiling {
                window.contentMaxSize = ceiling
                Log.info("[window] host maximum is \(Int(maximum.width))x\(Int(maximum.height)); "
                         + "this window stops at \(Int(ceiling.width))x\(Int(ceiling.height)) points")
            }
        }
    }

    /// Teach this window the size the host application refuses to go below.
    ///
    /// The value is reported by the host window itself (WM_GETMINMAXINFO), not
    /// inferred. Inferring it from "we asked for less and got more" is what the
    /// first version did, and that is indistinguishable from a placement that
    /// simply failed — in which case the size read back is the host window's
    /// current one, and a floor the size of the whole display gets latched. The
    /// macOS window then cannot be dragged smaller at all, which is exactly how
    /// it went wrong.
    ///
    /// Clamped to the screen regardless. A minimum larger than the display can
    /// only be wrong, and it is the one mistake here the user cannot undo by
    /// dragging.
    private func applyMinimumSize(_ hostPixels: CGSize, scale: CGFloat) {
        guard let window, scale > 0,
              hostPixels.width > 0, hostPixels.height > 0 else { return }
        var target = NSSize(width: (hostPixels.width / scale).rounded(),
                            height: (hostPixels.height / scale).rounded())
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size {
            target.width = min(target.width, visible.width)
            target.height = min(target.height, visible.height)
        }
        guard target != window.contentMinSize else { return }
        window.contentMinSize = target
        Log.info("[window] host minimum is \(Int(hostPixels.width))x\(Int(hostPixels.height)); "
                 + "this window stops at \(Int(target.width))x\(Int(target.height)) points")
    }

    /// Make this window exactly as tall and wide as the crop it is showing.
    ///
    /// The video layer scales with .resizeAspect, so any difference in shape
    /// between the crop and this window is drawn as bars down the sides or along
    /// the top. It also throws the pointer off, because the video no longer fills
    /// the view it is being measured against. Snapping to what the host achieved
    /// keeps the two in step — including when the host refuses a size, which is
    /// common: applications have minimum sizes and some resize in whole rows.
    func matchWindow(to achieved: CGRect, scale: CGFloat) {
        guard let window, scale > 0 else { return }
        let target = NSSize(width: (achieved.width / scale).rounded(),
                            height: (achieved.height / scale).rounded())
        let current = window.contentView?.bounds.size ?? .zero
        // A point of slack: rounding between points and pixels must not start a
        // resize war between this window and the host.
        guard abs(target.width - current.width) > 1 || abs(target.height - current.height) > 1 else {
            return
        }
        isMatchingHostSize = true
        window.setContentSize(target)
        // Cleared on the next turn, not here: AppKit does not promise to deliver
        // windowDidResize synchronously, and a late one would be read as the user
        // dragging — which sends the size straight back to the host and can leave
        // the two of them handing it to each other.
        DispatchQueue.main.async { [weak self] in self?.isMatchingHostSize = false }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        inputCapture?.enableCapture()
        installPointerStats()
        // Give the host window focus too, so keystrokes land in the right app.
        agent.focus(windowID: remoteWindowID)
        onKeyboardChange?()
    }

    /// The stats line reports whichever window is actually taking input.
    ///
    /// The capture is held strongly, not reached through `self`: the session
    /// is stopped after the last window has been released, and through a weak
    /// `self` every normal close logged "pointer 0 sent of 0 moves" whatever
    /// the hand had done. No cycle — the capture holds this window weakly.
    private func installPointerStats() {
        guard let capture = inputCapture else { return }
        session.setPointerStats {
            (capture.mouseMovedSeen, capture.positionsSent, capture.droppedWhileResizing)
        }
    }

    /// Move to a new stream after the old one was lost, keeping the window, its
    /// place on the host and its input exactly as they are.
    ///
    /// The counters restart with the session, and they are differenced with
    /// `&-` for the pill: left at the old session's totals, the first sample
    /// wraps to nearly 2^64 frames and the Int conversion traps.
    func rebind(to fresh: StreamSession) {
        guard !isClosing, let metalView else { return }
        session.detach(metalView)
        session = fresh
        fresh.attach(metalView)
        // The host may have been updated in between, and the new session's
        // answer is the one that holds.
        inputCapture?.sendsScanCodes = fresh.hostTakesScanCodes
        setTile(tile)
        lastFrameCount = 0
        lastByteCount = 0
        lastSample = Date()
        if window?.isKeyWindow == true {
            installPointerStats()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        inputCapture?.disableCapture()
        onKeyboardChange?()
    }

    /// The session under this window has started: anything the keyboard sent
    /// before it -- the window takes the keyboard as it is shown, ahead of the
    /// session -- went nowhere, so what must be in step is put in step now.
    func inputBecameLive() {
        inputCapture?.inputBecameLive()
    }

    /// Drive the host pointer to a known point in the picture, for `--test-input`.
    func sendTestPointer(normalizedX: Double, normalizedY: Double) {
        let sent = inputCapture?.sendUnitPosition(x: normalizedX, y: normalizedY) ?? false
        Log.info("[input] test pointer -> \(normalizedX), \(normalizedY)"
                 + (sent ? "" : " — REFUSED: no crop or canvas set"))
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        lifeTimer?.invalidate()
        lifeTimer = nil
        // RunLoop.main keeps a repeating timer until it is invalidated.
        qualityTimer?.invalidate()
        qualityTimer = nil
        // Nothing to cancel: a resize in flight completes into a closing window
        // and `isClosing` stops it doing anything.
        resizeAgain = false
        wantsSettle = false
        // ORDER MATTERS, AND THIS IS THE WHOLE RESTORE. `lock off` reaches
        // UnlockWindow on the host, which puts back the window style, the
        // topmost bit, and the placement that carries the window off the virtual
        // capture display and on to the monitor it came from -- then frees the
        // slot, which is why closing a window does not need to drop the socket.
        //
        // `topmost off` goes FIRST because the host's topmost handler claims a
        // slot before it looks at what it was asked for: sent afterwards it
        // re-claims the slot `lock off` has just freed, records a restore
        // obligation against the already-restored window, and leaks one of the
        // eight slots for the life of the connection.
        agent.setTopmost(windowID: remoteWindowID, false)
        agent.setResizeLock(windowID: remoteWindowID, false)
        if let metalView {
            session.detach(metalView)
        }
        inputCapture?.disableCapture()
        if let capture = inputCapture {
            Log.info("[input] \"\(window?.title ?? "")\": \(capture.mouseMovedSeen) moves, "
                     + "\(capture.positionsSent) positions sent, "
                     + "\(capture.positionsOutside) outside the picture, "
                     + "\(capture.withheldFromGame) withheld from a game, "
                     + "\(capture.droppedWhileResizing) dropped mid-resize")
        }

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
        metalView?.setStatus(title, detail: detail, busy: true)
    }

    func setError(_ title: String, detail: String? = nil) {
        metalView?.setError(title, detail: detail)
    }

    func hideStatus() {
        metalView?.hideStatus()
    }

    /// Name what is sitting on top of this window on the PC, or pass nil once
    /// nothing is.
    ///
    /// Worth saying out loud because the picture alone does not explain itself.
    /// The covering window is inside the captured rectangle, so it does arrive in
    /// the video — but a Windows dialog appearing inside what is supposed to be
    /// one application's window reads as SolStream having broken, and when it is
    /// system-modal it silently eats every click while the application behind it
    /// goes on looking completely normal.
    /// The window's own subtitle rather than another view in the title bar
    /// accessory: that accessory is a fixed-width holder with the quality pill
    /// pinned to its trailing edge, so a label placed beside the pill has no room
    /// and is silently clipped to nothing. AppKit sizes and truncates the
    /// subtitle itself, next to the title, and cannot lose it.
    func setOccludedBy(_ name: String?) {
        guard let name, !name.isEmpty else {
            window?.subtitle = ""
            return
        }
        // Kept short on purpose. AppKit centres the title and the quality pill
        // sits in a right-hand accessory, so a long subtitle runs under the pill
        // on a narrow window instead of being truncated clear of it.
        window?.subtitle = "⚠ \(name) in front"
    }

    /// Handler for the overlay's "Try Again" button. Only shown alongside an
    /// error, so setting this does not put a button in front of a working
    /// stream.
    var onRetry: (() -> Void)? {
        get { metalView?.onRetry }
        set { metalView?.onRetry = newValue }
    }
}

/// A short note over the picture the first time a window takes the mouse.
///
/// Gaming mode can take the mouse without a click -- the game hiding its
/// cursor, the window coming forward over it -- and a pointer that vanishes
/// the moment it touches the window, with nothing on screen to say why, reads
/// as a fault. Once per window: after that the user knows. A view of its own,
/// not the status overlay, which `MetalView.present()` hides on every frame.
final class CaptureHint: DS.Box {
    static let text = "The game has the mouse. ⌃⌥ gives it back."

    private var pendingDismiss: DispatchWorkItem?

    init() {
        super.init(fill: DS.surface, stroke: DS.edge, radius: DS.Metric.buttonRadius)
        let label = DS.label(Self.text, font: DS.caption, colour: DS.textSecondary)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.x3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.x3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A note about the picture never takes a click meant for it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show the note, and take it away again after `seconds`.
    func flash(for seconds: TimeInterval = 2.5) {
        pendingDismiss?.cancel()
        isHidden = false
        fade(to: 1)
        let dismiss = DispatchWorkItem { [weak self] in self?.dismiss() }
        pendingDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: dismiss)
    }

    func dismiss() {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        guard !isHidden else { return }
        fade(to: 0) { [weak self] in
            // Unless a flash arrived during the fade.
            guard let self, self.pendingDismiss == nil else { return }
            self.isHidden = true
        }
    }

    private func fade(to alpha: CGFloat, then completion: (() -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}
