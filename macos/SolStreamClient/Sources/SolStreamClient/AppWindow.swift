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

    /// The capture display, in virtual-desktop coordinates. Nothing outside this
    /// is in the stream at all.
    private var displayRect: CGRect {
        CGRect(x: display.x, y: display.y, width: display.width, height: display.height)
    }

    /// One `place` in flight at a time — see `requestResize`.
    private var resizeInFlight = false
    private var resizeAgain = false
    private var wantsSettle = false

    /// Watches for the application being closed on the host.
    private var lifeTimer: Timer?
    private var isClosing = false
    /// Set while this window is being resized to match the host, so the resize
    /// handler does not bounce the request straight back at it.
    private var isMatchingHostSize = false

    private let pill = QualityPill()
    private var qualityTimer: Timer?
    private var lastFrameCount: UInt64 = 0
    private var lastByteCount: UInt64 = 0
    private var lastSample = Date()

    var onClose: (() -> Void)?

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
            stats.hostDisplay = "\(self.display.name.replacingOccurrences(of: "\\\\.\\", with: "")) "
                + "· \(self.display.width)×\(self.display.height)"
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
    private func startWatchingForExit() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing else { return }
            self.agent.windowStatus(id: self.remoteWindowID) { [weak self] status in
                // A dropped agent connection reports nil, not death. Closing the
                // window on a transient failure would be worse than doing nothing.
                guard let status else { return }
                guard status.isAlive else {
                    DispatchQueue.main.async { self?.hostWindowClosed(noticedBy: "poll") }
                    return
                }
                DispatchQueue.main.async { self?.reportOcclusion(status) }
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
    /// tile arrives looking exactly like part of the application. A Windows
    /// firewall prompt did precisely that during testing: half the streamed
    /// window became a dialog about Sunshine, with nothing on this end to say it
    /// was not the application's own.
    ///
    /// Said in the title bar rather than on the status overlay, and that is the
    /// whole reason this works at all. The overlay is for a window with no
    /// picture in it: `MetalView.present()` hides it on every frame it draws,
    /// unconditionally. Being covered on the host is the opposite situation —
    /// the covering window is inside the captured rectangle, so frames go on
    /// arriving at sixty a second for the entire time the warning is true — and
    /// the warning was therefore wiped about sixteen milliseconds after it was
    /// put up, every time, on a window that was still busily drawing. Nobody
    /// ever saw one. The subtitle is not touched by the video path and stays
    /// until this method takes it down, which is what a condition that persists
    /// needs; it is also where the host's own `occluded` push already says the
    /// same thing, so the two routes no longer contradict each other.
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

    private func build(title: String, naturalSize: CGSize) {
        // Open at the size the application already is, not at the size of the
        // tile it is allowed to grow into.
        //
        // The tile for a single application is the whole capture display, so
        // sizing from it stretched every launched application to fill a 3600px
        // screen — Character Map opened at 940x761 and was immediately blown up
        // to 3600x2196, where it drew its grid in one corner and left the rest
        // grey. The window still resizes to anything; it just starts where the
        // application put itself.
        //
        // Host pixels to points is the backing scale, not a hardcoded 2.
        //
        // Then capped well short of the screen rather than at it. Clamping each
        // axis to the visible frame meant any application that happened to be
        // maximised on the PC — and one parked on a 3600x2338 virtual display
        // usually is — opened edge to edge on the Mac. That reads as full screen,
        // which is not what opening a window should do: it covers everything
        // else, and there is nowhere left to drag it by.
        //
        // Shrunk by one factor on both axes, so a window that has to come down
        // keeps the application's proportions instead of being squashed on
        // whichever axis was the tighter fit.
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
        // NSWindow created directly defaults to releasing itself on close, which
        // is a hangover from manual retain/release: ARC then releases it again
        // from the property below and the process dies in objc_release at the next
        // autorelease-pool drain. Only invisible while windows were closed solely
        // at app termination, when the process exits before that drain happens.
        window.isReleasedWhenClosed = false
        // Solar's `ground`, so the strip above the application is the same
        // graphite as every other SolStream window rather than a black of its
        // own. It resolves to the dark value, because of the appearance below.
        window.backgroundColor = DS.ground
        // Say out loud that this chrome is dark, because the line above made it
        // so without telling anyone.
        //
        // `titlebarAppearsTransparent` stops the title bar drawing its own
        // material, so the ground above shows through the whole strip.
        // In the dark appearance that is invisible — AppKit picks a light
        // `labelColor` and the title reads fine. In the LIGHT appearance it
        // picks black, and draws the title in black on near-black: the window came up
        // with traffic lights, a quality pill, and no name at all. Verified on
        // the running client, twice in each direction — switching the Mac to
        // Dark made "Character Map" appear and switching back made it vanish.
        //
        // Deliberately not fixed by dropping the dark background. That would
        // hand the strip back to the system material, which is the lighter fix
        // on paper but leaves a video window in a light frame and risks a pale
        // flash during a live resize drag. Naming the appearance keeps the
        // chrome exactly as designed and costs nothing: it also resolves the
        // pill's design tokens to their dark variants, which is what belongs on
        // a dark bar — in light mode the pill was grey on grey.
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

        let capture = InputCapture()
        capture.attach(to: view)
        capture.onInput = { [weak self] packet in
            self?.session.sendInput(packet)
        }
        inputCapture = capture

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
        // Resizing the macOS window resizes the real Windows window, and it does
        // it *while* the drag is happening rather than after it. This used to be
        // debounced by 200ms, which meant the host only caught up once the drag
        // ended: until then the window showed the last frame stretched to a shape
        // it was never rendered at, which is exactly the moment the illusion is
        // most obviously an illusion.
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
        // Retina window does not request half the pixels it can display.
        let scale = screen.backingScaleFactor
        let size = window.contentView?.bounds.size ?? .zero

        // Never ask for more than the capture display holds. The host will
        // happily size a window past the edge of its display, and the part that
        // hangs off is simply not in the captured frame — so the crop ends up
        // partly outside the canvas and the window fills with desktop.
        let maxWidth = CGFloat(display.width)
        let maxHeight = CGFloat(display.height)
        let wanted = CGSize(width: min((size.width * scale).rounded(), maxWidth),
                            height: min((size.height * scale).rounded(), maxHeight))
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
                self.applyMinimumSize(placement.minimumSize, scale: scale)
                if placement.resizeBorder > 0 {
                    self.inputCapture?.edgeGuard = placement.resizeBorder
                }
                let visible = achieved.intersection(self.displayRect)
                guard visible.width >= 1, visible.height >= 1 else { return }
                self.setTile(visible)
                if matchBack {
                    self.matchWindow(to: visible, scale: scale)
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
    }

    /// The stats line reports whichever window is actually taking input.
    private func installPointerStats() {
        session.setPointerStats { [weak self] in
            guard let capture = self?.inputCapture else { return (0, 0, 0) }
            return (capture.mouseMovedSeen, capture.positionsSent,
                    capture.droppedWhileResizing)
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
        // The quality poll was stepped straight past here. Its block captures
        // [weak self], so the window itself still went away and the leak never
        // showed up as a retain cycle — but RunLoop.main kept the timer forever
        // and went on waking the main thread once a second, per closed window,
        // for the rest of the process's life.
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
        // slot. It is what used to happen only when the socket dropped, and it
        // is why closing a window no longer needs to drop it.
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

    // There was a `setPairingPin(_:host:reason:)` here, the last thing in this
    // application that could put the words "Enter this PIN in Sunshine" and a
    // link to port 47990 on screen. Nothing calls it: SolStream pairs with a
    // token the host shows in its own window, and there is no PIN and no web UI
    // to send anybody to. See the note where `brokerPairing` used to be.

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
