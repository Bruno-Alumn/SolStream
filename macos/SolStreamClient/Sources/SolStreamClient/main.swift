import Cocoa
import AppKit
import SolStreamLogging
import MediaSession
import AgentChannel

/// SolStream macOS client entry point.
struct SolStreamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

SolStreamApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var streamWindows: [StreamWindow] = []
    private var connectWindow: ConnectWindow?
    private var agent: AgentConnection?
    private var session: StreamSession?
    private var appWindows: [AppWindow] = []
    private var picker: AppPicker?
    private var clipboard: ClipboardBridge?

    /// Set once from the command line, then reused when the picker sends us
    /// round the loop again.
    private var agentHostOverride: String?
    private var displayQuery: String?
    private var baseConfig = StreamConfig()

    /// `--host <ip>` connects immediately; `--test-screenshot` grabs the window
    /// and exits (used by the UI tests).
    private var testMode = false
    /// Set by --test-dropdown so the capture targets the list, not the window
    /// behind it.
    private var dropdownWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        Log.startSession(version: "v0.3")

        let arguments = CommandLine.arguments
        testMode = arguments.contains("--test-screenshot")

        // --screenshot-after <seconds> waits long enough for real frames to
        // arrive before capturing, which is how a live stream gets verified.
        var captureDelay: TimeInterval = 2.0
        if let index = arguments.firstIndex(of: "--screenshot-after"),
           index + 1 < arguments.count,
           let seconds = TimeInterval(arguments[index + 1]) {
            captureDelay = seconds
            testMode = true
        }

        var config = StreamConfig()
        // --bitrate is the only stream knob left. The packet size is fixed by
        // the MTU and the header, and there is no Sunshine port to point at.
        if let index = arguments.firstIndex(of: "--bitrate"),
           index + 1 < arguments.count,
           let kbps = Int(arguments[index + 1]) {
            config.bitrateKbps = kbps
            Log.info("[stream] bitrate \(kbps) kbit/s")
        }

        let host = arguments.firstIndex(of: "--host").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        let appWindowQuery = arguments.firstIndex(of: "--app-window").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        // The agent may be reached somewhere other than the stream host — over
        // an SSH port forward during development, for instance, which avoids
        // opening an inbound firewall port on the Windows box.
        let agentHost = arguments.firstIndex(of: "--agent-host").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }

        // --agent-token supplies the host's shared secret once; it is remembered
        // per host afterwards. It is shown on SolStream's own window on the
        // host, under "Pairing token", with a Copy button beside it.
        if let index = arguments.firstIndex(of: "--agent-token"),
           index + 1 < arguments.count {
            let host = arguments.firstIndex(of: "--host").flatMap { hostIndex in
                hostIndex + 1 < arguments.count ? arguments[hostIndex + 1] : nil
            }
            let target = (arguments.firstIndex(of: "--agent-host").flatMap { agentIndex in
                agentIndex + 1 < arguments.count ? arguments[agentIndex + 1] : nil
            }) ?? host
            if let target {
                AgentConnection.rememberToken(arguments[index + 1], for: target)
                Log.info("[agent] token stored for \(target)")
            }
        }

        // --launch starts an installed application by name, skipping the picker.
        let launchQuery = arguments.firstIndex(of: "--launch").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }

        // --display picks which host display to park applications on, by device
        // name or adapter substring. Without it a virtual display wins, because
        // that is the one nothing else can be dragged across.
        let displayQuery = arguments.firstIndex(of: "--display").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }

        self.agentHostOverride = agentHost
        self.displayQuery = displayQuery
        self.baseConfig = config

        // --desktop is the old whole-screen mirror, kept for diagnosing the
        // stream itself. It shows the task bar and everything else on the
        // display, which is exactly what single-application mode exists to avoid,
        // so it is not the default any more.
        if let host, arguments.contains("--desktop") {
            // Ask for a canvas shaped like this Mac. Sunshine letterboxes to
            // preserve the source aspect, so a 16:9 request against a 3:2 display
            // is where the black bars down each side came from.
            var desktop = config
            if let screen = NSScreen.main {
                let scale = screen.backingScaleFactor
                desktop.width = Int((screen.frame.width * scale).rounded())
                desktop.height = Int((screen.frame.height * scale).rounded())
                Log.info("[desktop] requesting \(desktop.width)x\(desktop.height) to match this Mac")
            }
            startStreaming(host: host, agentHost: agentHost ?? host,
                           displayQuery: displayQuery, config: desktop)
        } else if let host, let launchQuery {
            startLaunching(host: host, agentHost: agentHost ?? host, matching: launchQuery)
        } else if let host, let appWindowQuery {
            startSingleApp(host: host, agentHost: agentHost ?? host,
                           matching: appWindowQuery, displayQuery: displayQuery,
                           config: config)
        } else if let host {
            showPicker(host: host)
        } else {
            showConnectWindow()
        }

        // --test-input drives the host pointer to a known spot shortly before
        // the screenshot, so the cursor's position in the captured frame proves
        // input reached the host.
        if arguments.contains("--test-input") {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(1, captureDelay - 2)) { [weak self] in
                self?.streamWindows.first?.sendTestPointer(normalizedX: 0.75, normalizedY: 0.75)
            }
        }

        // --test-dropdown photographs the host list, which is otherwise only
        // reachable with the mouse.
        if arguments.contains("--test-dropdown") {
            testMode = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, captureDelay - 1.5)) {
                [weak self] in
                self?.dropdownWindow = self?.connectWindow?.openDropdownForTesting()
            }
        }

        if testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay) { [weak self] in
                self?.captureTestScreenshot()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous: the process is about to exit and the host needs to see
        // us go, or it stays busy for every other client.
        streamWindows.forEach { $0.stopStreaming(waitUntilDone: true) }
        session?.stop(waitUntilDone: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Flow

    private func showConnectWindow() {
        let window = ConnectWindow { [weak self] host in
            self?.showPicker(host: host)
        }
        connectWindow = window
        window.show()
    }

    /// Connect to the agent and ask what the host can show.
    ///
    /// This is the ordinary way in: pick one application, get one window. The
    /// agent is consulted before any stream starts, because the encode canvas has
    /// to match the capture display exactly for crops to be pixel-exact.
    private func showPicker(host: String) {
        let agentHost = agentHostOverride ?? host
        let agent = AgentConnection(host: agentHost)
        self.agent = agent

        let picker = AppPicker(host: host, onChoose: { [weak self] choice in
            self?.open(choice: choice, host: host, agent: agent)
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.picker = nil
            self.agent = nil
            agent.disconnect()
            if self.appWindows.isEmpty && !self.testMode {
                self.showConnectWindow()
            }
        })
        picker.agent = agent
        self.picker = picker
        picker.show()

        // [weak agent] throughout: `agent` stores these closures, so a strong
        // capture makes it retain itself — deinit never runs, the socket is never
        // cancelled, and in onDisplays below the AppPicker and its icon cache
        // (raw BGRA, one entry per window and per Start Menu app scrolled past)
        // are pinned to it as well.
        agent.onState = { [weak picker, weak agent] state in
            switch state {
            case .failed(let message):
                DispatchQueue.main.async {
                    // No prefix: `explain` already names the host and says what
                    // to do about it, and prefixing produced "Can't reach the
                    // SolStream agent on X: No answer from X."
                    picker?.showFailure(message)
                }
            case .needsToken(let host, let rejected):
                DispatchQueue.main.async {
                    // Over the picker, so it arrives as a sheet on the window
                    // the person is already looking at rather than as a panel
                    // from nowhere.
                    TokenPrompt.present(host: host, rejected: rejected,
                                        over: picker?.window) { token in
                        guard let token else {
                            picker?.showFailure("\(host) needs a pairing token to go any further.")
                            return
                        }
                        agent?.supplyToken(token)
                    }
                }
            default:
                break
            }
        }

        // Both lists, then show them together — a half-populated picker that
        // grows under the cursor is worse than a moment's wait.
        let fill: () -> Void = { [weak self, weak agent, weak picker] in
            guard let agent else { return }
            agent.windows { windows in
                agent.apps { apps in
                    DispatchQueue.main.async {
                        guard self != nil else { return }
                        picker?.present(windows: windows, apps: apps)
                    }
                }
            }
        }
        agent.onDisplays = { _ in fill() }
        // The same fill, driven by the host noticing a window come or go. Without
        // it the list is whatever was open at the moment of connecting: an
        // application quit on the PC stays offerable and one started there cannot
        // be picked at all.
        agent.onWindowsChanged = fill
        agent.connect()
    }

    /// The picker's launch path without the picker, for `--launch` and tests.
    private func startLaunching(host: String, agentHost: String, matching query: String) {
        let agent = AgentConnection(host: agentHost)
        self.agent = agent

        agent.onState = { state in
            switch state {
            case .failed(let message):
                // No suffix: `explain` already says what to do about a genuine
                // unreachable host, and a refusal is not unreachability — a
                // hint to check the agent is running reads as nonsense when the
                // agent answered and was turned down for impersonation.
                Log.error("[app] \(message)")
            case .needsToken(let host, _):
                // No window to ask in on this path, so say what to do instead of
                // waiting for an answer that cannot arrive.
                Log.error("[app] \(host) needs a pairing token. It is on "
                          + "SolStream's own window on that PC, under \"Pairing "
                          + "token\"; start SolStream here once with "
                          + "--agent-token <token>.")
            default:
                break
            }
        }
        agent.onDisplays = { [weak self, weak agent] _ in
            guard let agent else { return }
            agent.apps { apps in
                guard let match = apps.first(where: {
                    $0.name.localizedCaseInsensitiveContains(query)
                }) else {
                    Log.error("[app] no installed application matched \"\(query)\"")
                    return
                }
                Log.info("[app] launching \"\(match.name)\"")
                DispatchQueue.main.async { [weak self] in
                    self?.open(choice: .launch(match), host: host, agent: agent)
                }
            }
        }
        agent.connect()
    }

    private func open(choice: AppPicker.Choice, host: String, agent: AgentConnection) {
        switch choice {
        case .running(let window):
            attach(window, host: host, agent: agent)

        case .launch(let app):
            // If it is already open, attach to it instead of starting it.
            //
            // Launching an application that is already running usually produces
            // no new window — it raises the one it has, or opens a tab in it — so
            // the host waits out its whole launch timeout before giving up, and
            // the Mac then attaches anyway. That is around 25 seconds of
            // "Starting…" to reach the same place. Checking first makes it
            // instant, and picking an application that is already running is a
            // request to see it, not to start a second copy.
            picker?.showBusy("Opening \(app.name) on \(host)…")
            agent.windows { [weak self] windows in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let existing = windows.first(where: {
                        $0.title.localizedCaseInsensitiveContains(app.name)
                    }) {
                        Log.info("[app] \"\(app.name)\" is already open; attaching to "
                                 + "\"\(existing.title)\"")
                        self.attach(existing, host: host, agent: agent)
                        return
                    }
                    self.launch(app: app, host: host, agent: agent)
                }
            }
        }
    }

    private func launch(app: RemoteApp, host: String, agent: AgentConnection) {
        picker?.showBusy("Starting \(app.name) on \(host)…")
        agent.launch(path: app.path) { [weak self] id in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let id else {
                    // Still not necessarily a failure: an application can open its
                    // window under a title that does not contain the name we
                    // matched on before launching, so try once more now.
                    agent.windows { windows in
                        DispatchQueue.main.async {
                            guard let existing = windows.first(where: {
                                $0.title.localizedCaseInsensitiveContains(app.name)
                            }) else {
                                self.picker?.clearBusy()
                                self.picker?.showFailure("\(app.name) didn't open a window.")
                                return
                            }
                            Log.info("[app] \"\(app.name)\" was already open; "
                                     + "attaching to \"\(existing.title)\"")
                            self.attach(existing, host: host, agent: agent)
                        }
                    }
                    return
                }
                // Re-enumerate rather than trusting the launch reply: the window
                // list carries the title and caption geometry the stream window
                // needs, and the app may have retitled itself in the moment since
                // it appeared.
                agent.windows { windows in
                    DispatchQueue.main.async {
                        guard let target = windows.first(where: { $0.id == id }) else {
                            self.picker?.clearBusy()
                            self.picker?.showFailure("\(app.name) opened a window that vanished.")
                            return
                        }
                        self.attach(target, host: host, agent: agent)
                    }
                }
            }
        }
    }

    /// Dismiss the picker and stream one window.
    private func attach(_ window: RemoteWindow, host: String, agent: AgentConnection) {
        picker?.close()
        picker = nil
        start(host: host, agent: agent, targets: [window])
    }

    /// The canvas this Mac wants the host to render at.
    ///
    /// Its screen in points times the backing scale factor: that is exactly how
    /// many pixels a full-screen window here can show, so anything larger is
    /// bitrate spent on pixels that get thrown away and anything smaller is
    /// upscaled. Clamped to NVENC's H.264 maximum, above which a session
    /// negotiates fine and then never delivers a frame.
    private static func desiredCanvas() -> CGSize? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        let limit: CGFloat = 4096
        return CGSize(width: min((screen.frame.width * scale).rounded(), limit),
                      height: min((screen.frame.height * scale).rounded(), limit))
    }

    /// Resolve the capture display, size it to this Mac, then open the windows.
    private func start(host: String, agent: AgentConnection, targets: [RemoteWindow]) {
        guard let capture = Self.selectDisplay(from: agent.displays, preferring: displayQuery) else {
            Log.error("[app] host reported no displays")
            return
        }
        Log.info("[app] capture display \(capture.name) "
                 + "\(capture.width)x\(capture.height) @ \(capture.x),\(capture.y) "
                 + "[\(capture.adapter)]\(capture.isVirtual ? " virtual" : "")")
        Log.info("[app] Sunshine's output_name must resolve to \(capture.name)")

        // Only ever resize a virtual display. A physical monitor is somebody's
        // actual screen, and changing its mode to suit a remote client would be
        // rude at best.
        guard capture.isVirtual, let wanted = Self.desiredCanvas(),
              Int(wanted.width) != capture.width || Int(wanted.height) != capture.height else {
            openApps(host: host, agent: agent, targets: targets,
                     display: capture, config: baseConfig)
            return
        }

        Log.info("[app] asking the host to render at \(Int(wanted.width))x\(Int(wanted.height))")
        agent.setCanvas(display: capture.name,
                        width: Int(wanted.width), height: Int(wanted.height)) { [weak self] achieved in
            guard let self else { return }
            guard achieved != nil else {
                Log.info("[app] host kept \(capture.width)x\(capture.height)")
                DispatchQueue.main.async {
                    self.openApps(host: host, agent: agent, targets: targets,
                                  display: capture, config: self.baseConfig)
                }
                return
            }
            // Re-enumerate rather than patching the size in: a mode change can move
            // the display's origin too, and every tile is expressed in
            // virtual-desktop coordinates.
            agent.refreshDisplays { displays in
                DispatchQueue.main.async {
                    let updated = displays.first { $0.name == capture.name } ?? capture
                    Log.info("[app] host now rendering at \(updated.width)x\(updated.height) "
                             + "@ \(updated.x),\(updated.y)")
                    self.openApps(host: host, agent: agent, targets: targets,
                                  display: updated, config: self.baseConfig)
                }
            }
        }
    }

    /// `--desktop`: the whole-screen mirror, kept for diagnosing the stream
    /// itself rather than for daily use.
    ///
    /// It goes through the agent like everything else now. There is no path to
    /// a picture that does not start with the agent agreeing a key, which is
    /// the point: the media socket has no authentication of its own to fall
    /// back on, by design.
    private func startStreaming(host: String, agentHost: String,
                                displayQuery: String?, config: StreamConfig = .init()) {
        let agent = AgentConnection(host: agentHost)
        self.agent = agent
        agent.onState = { state in
            if case .failed(let message) = state { Log.error("[desktop] \(message)") }
        }
        agent.onDisplays = { [weak self, weak agent] displays in
            guard let self, let agent,
                  let capture = Self.selectDisplay(from: displays, preferring: displayQuery) else {
                Log.error("[desktop] host reported no displays")
                return
            }
            var sized = config
            sized.width = capture.width
            sized.height = capture.height
            Task { @MainActor [weak self] in
                guard let self else { return }
                let request = AgentConnection.MediaRequest(
                    display: capture.name, fps: sized.frameRate,
                    bitrate: sized.bitrateKbps * 1000, audio: sized.audio)
                guard let media = await agent.openMediaSession(request), media.streaming else {
                    Log.error("[desktop] \(host) would not start streaming")
                    return
                }
                let session = StreamSession(host: host, config: sized, session: media)
                self.session = session
                let streamWindow = StreamWindow(host: host, config: sized, session: session)
                streamWindow.onClose = { [weak self, weak streamWindow] in
                    guard let self else { return }
                    self.streamWindows.removeAll { $0 === streamWindow }
                    self.session = nil
                    if self.streamWindows.isEmpty && !self.testMode {
                        self.showConnectWindow()
                    }
                }
                self.streamWindows.append(streamWindow)
                streamWindow.show()
                streamWindow.startStreaming()
            }
        }
        agent.connect()
    }

    /// Stream one or more Windows applications, each in its own native window.
    ///
    /// The agent is consulted BEFORE the stream launches, because the encode
    /// canvas has to match the capture display exactly: when it does, Sunshine's
    /// scale factor is 1.0 and every crop is pixel-exact rather than resampled.
    private func startSingleApp(host: String, agentHost: String, matching query: String,
                                displayQuery: String?, config: StreamConfig) {
        let queries = query.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        let agent = AgentConnection(host: agentHost)
        self.agent = agent

        agent.onState = { state in
            switch state {
            case .failed(let message):
                // No suffix: `explain` already says what to do about a genuine
                // unreachable host, and a refusal is not unreachability — a
                // hint to check the agent is running reads as nonsense when the
                // agent answered and was turned down for impersonation.
                Log.error("[app] \(message)")
            case .needsToken(let host, _):
                // No window to ask in on this path, so say what to do instead of
                // waiting for an answer that cannot arrive.
                Log.error("[app] \(host) needs a pairing token. It is on "
                          + "SolStream's own window on that PC, under \"Pairing "
                          + "token\"; start SolStream here once with "
                          + "--agent-token <token>.")
            default:
                break
            }
        }

        agent.onDisplays = { [weak self, weak agent] displays in
            guard let self, let agent,
                  let capture = Self.selectDisplay(from: displays, preferring: displayQuery) else {
                Log.error("[app] host reported no displays")
                return
            }
            Log.info("[app] capture display \(capture.name) "
                     + "\(capture.width)x\(capture.height) @ \(capture.x),\(capture.y) "
                     + "[\(capture.adapter)]\(capture.isVirtual ? " virtual" : "")")
            // The host encodes exactly this display, because the media session
            // names it. There is no separate configuration that could disagree
            // with where the windows are being placed -- which is what the line
            // that used to be here existed to warn about.

            agent.windows { [weak self] windows in
                guard let self else { return }
                let targets = queries.compactMap { needle in
                    windows.first { $0.title.localizedCaseInsensitiveContains(needle) }
                }
                guard !targets.isEmpty else {
                    Log.error("[app] nothing matched \(queries). Candidates:")
                    // With geometry. "nothing matched" and "matched something
                    // the wrong size" are different problems, and the second one
                    // is invisible without this.
                    for window in windows {
                        Log.error("[app]   \(window.title) "
                                  + "[\(window.x),\(window.y) \(window.width)x\(window.height)]")
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.openApps(host: host, agent: agent, targets: targets,
                                  display: capture, config: config)
                }
            }
        }

        agent.connect()
    }

    /// Lay the chosen windows out side by side on the capture display, then open
    /// one native window per app over a single shared stream.
    private func openApps(host: String, agent: AgentConnection,
                          targets: [RemoteWindow], display: RemoteDisplay,
                          config baseConfig: StreamConfig) {
        var config = baseConfig
        // The encode canvas matches the capture display, which makes the scale
        // factor 1.0 and every crop pixel-exact. Fixed for the session: the
        // encoder's output type is set once, so changing it means a new encoder
        // and a new parameter set. Resizing a window therefore resizes the
        // WINDOW within a fixed canvas — no mode change, no reconnect, no black
        // frame.
        // Clamped to NVENC's H.264 maximum. Above it the handshake succeeds and no
        // frame ever arrives, with the reason only in Sunshine's own log — and a
        // 16" MacBook Pro at More Space asks for 4112x2658, so this is reachable
        // with ordinary hardware rather than a pathological setup.
        let encoderLimit = 4096
        config.width = min(display.width, encoderLimit)
        config.height = min(display.height, encoderLimit)
        if config.width != display.width || config.height != display.height {
            Log.info("[canvas] capture display is \(display.width)x\(display.height); "
                     + "clamped to \(config.width)x\(config.height) for the encoder")
        }

        Self.reportIdealCanvas(display: display)

        // The media session is agreed on the agent channel before any window is
        // shown. There is no PIN, no certificate exchange and no RTSP: two
        // programs that ship together and have already authenticated each other
        // do not need introducing again, so the only thing that can fail here is
        // the host declining to capture.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let request = AgentConnection.MediaRequest(
                display: display.name,
                fps: config.frameRate,
                bitrate: config.bitrateKbps * 1000,
                audio: config.audio)
            guard let media = await agent.openMediaSession(request) else {
                Log.error("[app] \(host) refused the media session")
                return
            }
            guard media.streaming else {
                Log.error("[app] \(host) agreed keys but did not start: "
                          + (media.message ?? "no reason given"))
                return
            }
            self.presentApps(host: host, agent: agent, targets: targets,
                             display: display, config: config, media: media)
        }
    }

    private func presentApps(host: String, agent: AgentConnection, targets: [RemoteWindow],
                             display: RemoteDisplay, config: StreamConfig,
                             media: AgentConnection.MediaSession) {
        // Only while something is actually streamed: syncing a clipboard with a
        // machine the user is not looking at would be surprising.
        let bridge = ClipboardBridge(agent: agent)
        clipboard = bridge
        bridge.start()

        let session = StreamSession(host: host, config: config, session: media)
        self.session = session
        session.start()

        let tiles = Self.tileLayout(count: targets.count, on: display)

        for (index, target) in targets.enumerated() {
            let tile = tiles[index]

            let appWindow = AppWindow(session: session, agent: agent, remote: target,
                                      display: display, tile: tile)
            appWindow.onClose = { [weak self, weak appWindow] in
                guard let self else { return }
                self.appWindows.removeAll { $0 === appWindow }
                guard self.appWindows.isEmpty else { return }
                self.session?.stop()
                self.session = nil
                self.clipboard?.stop()
                self.clipboard = nil
                // Back to the picker rather than quitting: closing one
                // application is not a reason to disconnect from the host.
                if !self.testMode {
                    self.agent = nil
                    agent.disconnect()
                    self.showPicker(host: host)
                }
            }
            appWindow.setStatus("Connecting to \(host)", detail: target.title)
            // A StreamSession cannot be restarted in place — stop() releases the
            // decoder and start() does not build another — so recovering means a
            // new session. Closing the windows runs the path that already exists
            // for that, back to the picker with the host connection still up,
            // where the same application is one click away.
            appWindow.onRetry = { [weak self] in
                guard let self else { return }
                Log.info("[app] retry after a lost stream; returning to the picker")
                self.appWindows.forEach { $0.close() }
            }
            appWindows.append(appWindow)
            appWindow.show()

            // Size the host window to this one and pin it there. The window owns
            // its own geometry so the initial placement and a later drag go
            // through identical code, and the lock is taken only once the window
            // is where it belongs — it enforces whatever geometry it finds.
            appWindow.placeAndLock()
            agent.focus(windowID: target.id)
            Log.info("[app] \"\(target.title)\" -> tile \(tile)")
        }

        // The watchdog speaks only once frames have been arriving and then stop,
        // so it never argues with onPhase about a stream that has not started.
        session.onLiveness = { [weak self] liveness in
            guard let self else { return }
            switch liveness {
            case .live:
                self.appWindows.forEach { $0.hideStatus() }
            case .stalled(let seconds):
                self.appWindows.forEach {
                    $0.setStatus("Reconnecting…",
                                 detail: "No picture for \(seconds)s — asking \(host) for a new frame")
                }
            case .lost:
                self.appWindows.forEach {
                    $0.setError("Lost the stream",
                                detail: "\(host) stopped sending video and did not answer "
                                        + "requests for a new frame.")
                }
            }
        }

        // Not on `.streaming`: that only means video is arriving. A resumed
        // session is already sending it, so the first frame can land before PLAY
        // returns and the control stream exists — and synthetic keys sent then
        // go nowhere at all.
        // The host pushes this whenever its cursor changes shape. Applied to
        // every window: the cursor is global to the host, and only the one the
        // pointer is actually over can show it anyway.
        agent.onCursorShape = { [weak self] shape in
            guard let self else { return }
            let cursor = HostCursor.macCursor(for: shape)
            self.appWindows.forEach { $0.setRemoteCursor(cursor) }
        }

        // Closing the application on the Windows side ends the stream, without
        // waiting for the once-a-second poll to catch up. Closing the last
        // window stops the session and returns to the picker, which is the same
        // path as closing it from this end — quitting one application is not a
        // reason to disconnect from the host.
        agent.onWindowClosed = { [weak self] id in
            self?.appWindows.first { $0.remoteWindowID == id }?
                .hostWindowClosed(noticedBy: "pushed by the host")
        }

        // Named in the title bar of the window it is covering, not broadcast:
        // with two windows open, only one of them may be behind a dialog.
        agent.onOccluded = { [weak self] id, name in
            self?.appWindows.first { $0.remoteWindowID == id }?
                .setOccludedBy(name.isEmpty ? nil : name)
        }

        // The host forgets every window it was managing when the socket drops,
        // so a reconnect has to say it all again.
        agent.onReconnected = { [weak self] in
            self?.appWindows.forEach { $0.reassertOnHost() }
        }

        // No host-cursor toggle any more. The capture session is created with
        // IsCursorCaptureEnabled(false), so the host's pointer is never in the
        // picture at all -- and this Mac draws a real cursor from the shape the
        // agent pushes. The Sunshine keyboard shortcut that used to flip it, and
        // the belief tracking that went with it, are gone with the protocol.

        session.onPhase = { [weak self] phase in
            guard let self else { return }
            switch phase {
            case .streaming:
                self.appWindows.forEach { $0.hideStatus() }
            case .failed(let message):
                self.appWindows.forEach { $0.setError("Stream failed", detail: message) }
            case .waitingForVideo:
                self.appWindows.forEach { $0.setStatus("Waiting for video") }
            default:
                break
            }
        }
    }

    /// Get the host to approve its own pairing PIN.
    ///
    /// Sunshine's own flow asks the user to open its web UI, get past a
    /// self-signed certificate warning, create credentials and find the PIN page.
    /// The agent is already on the host and can hand the PIN to Sunshine directly,
    /// so all of that disappears. If the host has no stored credentials the PIN is
    /// shown as before — degraded, but never worse than the original flow.
    private func brokerPairing(pin: String, host: String, agent: AgentConnection) {
        let name = Host.current().localizedName ?? "SolStream client"
        appWindows.forEach { $0.setStatus("Pairing with \(host)", detail: "Asking the host to approve…") }
        Log.info("[pair] asking the agent to approve PIN for \"\(name)\"")

        agent.pair(pin: pin, clientName: name) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .paired:
                    Log.info("[pair] the host approved this Mac; no PIN entry needed")
                    self.appWindows.forEach {
                        $0.setStatus("Paired", detail: "Starting the stream…")
                    }
                case .needsHostSetup(let detail):
                    Log.info("[pair] host cannot approve automatically: \(detail)")
                    self.appWindows.forEach {
                        $0.setPairingPin(pin, host: host, reason:
                            "Run SolStream.exe --set-sunshine-credentials on the host "
                            + "once to skip this step in future.")
                    }
                case .failed(let detail):
                    Log.error("[pair] brokered pairing failed: \(detail)")
                    self.appWindows.forEach { $0.setPairingPin(pin, host: host, reason: detail) }
                }
            }
        }
    }

    /// Choose which host display to stream.
    ///
    /// A virtual display wins by default. It is the only one that can be sized
    /// to this Mac exactly, and because no user ever drags a window onto it by
    /// accident, nothing can appear inside a crop that is not the streamed app.
    /// The primary display is the fallback, not the preference.
    private static func selectDisplay(from displays: [RemoteDisplay],
                                      preferring query: String?) -> RemoteDisplay? {
        if let query, !query.isEmpty {
            let match = displays.first {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.adapter.localizedCaseInsensitiveContains(query)
            }
            if let match {
                // Honour the request — it is explicit — but do not let it be
                // quiet. Windows placed on a display Sunshine is not encoding
                // are cropped out of the wrong pixels, and the result looks like
                // a working stream of something else entirely.
                if !match.isCaptured, let captured = displays.first(where: { $0.isCaptured }) {
                    Log.error("[app] \(match.name) is not the display being streamed —"
                              + " that is \(captured.name). Every window will be cropped"
                              + " from the wrong pixels. Drop --display, or point"
                              + " Sunshine's output_name at \(match.name).")
                }
                return match
            }
            Log.error("[app] no display matched \"\(query)\"; falling back. Candidates: "
                      + displays.map { "\($0.name) [\($0.adapter)]" }.joined(separator: ", "))
        }
        // The host's own answer first. The agent configures Sunshine, so it knows
        // which display is being encoded; guessing from "virtual, else primary"
        // agreed with it only by luck, and disagreed outright against a Sunshine
        // the user had set up themselves on the stock ports.
        return displays.first(where: { $0.isCaptured })
            ?? displays.first(where: { $0.isVirtual })
            ?? displays.first(where: { $0.isPrimary })
            ?? displays.first
    }

    /// Compare the capture display against what this Mac can actually show.
    ///
    /// One-to-one crispness needs the host display to have as many pixels as the
    /// macOS window can display — that is points times the backing scale factor.
    /// A fixed-EDID dummy plug cannot offer arbitrary modes, which is the real
    /// argument for a virtual display over a dongle.
    private static func reportIdealCanvas(display: RemoteDisplay) {
        guard let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let physical = CGSize(width: (screen.frame.width * scale).rounded(),
                              height: (screen.frame.height * scale).rounded())
        Log.info("""
            [canvas] host display \(display.width)x\(display.height); this Mac is \
            \(Int(screen.frame.width))x\(Int(screen.frame.height)) points @\(scale)x \
            = \(Int(physical.width))x\(Int(physical.height)) physical
            """)
        if display.width < Int(physical.width) || display.height < Int(physical.height) {
            Log.info("""
                [canvas] a full-screen window would be upscaled. For 1:1, set the \
                capture display to \(Int(physical.width))x\(Int(physical.height)).
                """)
        } else {
            Log.info("[canvas] capture display covers this Mac; full-screen is 1:1")
        }
    }

    /// Non-overlapping tiles. Non-overlap is the whole point: the crop shows
    /// whatever is at those coordinates, so two windows sharing pixels would
    /// each show the other.
    private static func tileLayout(count: Int, on display: RemoteDisplay) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(ceil(Double(count).squareRoot()))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let width = CGFloat(display.width) / CGFloat(columns)
        let height = CGFloat(display.height) / CGFloat(rows)

        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(x: (CGFloat(display.x) + CGFloat(column) * width).rounded(),
                          y: (CGFloat(display.y) + CGFloat(row) * height).rounded(),
                          width: width.rounded(),
                          height: height.rounded())
        }
    }

    // MARK: - Menu

    /// Move a menu item onto ⌃⌘, SolStream's own prefix.
    ///
    /// Bare ⌘ belongs to the streamed application: ⌘ is sent to Windows as
    /// Control, so ⌘W closes a browser tab over there and ⌘F opens Find. Leaving
    /// this application's own shortcuts on bare ⌘ would mean a Mac user reaching
    /// for "close this tab" got their whole session torn down instead.
    ///
    /// ⌘Q is the one exception and stays where macOS puts it: quitting has to
    /// work from anywhere, and a Windows application that wanted Ctrl+Q can be
    /// quit from its own menus.
    @discardableResult
    private static func reserve(_ item: NSMenuItem) -> NSMenuItem {
        item.keyEquivalentModifierMask = [.control, .command]
        return item
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SolStream", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reveal Log in Finder",
                        action: #selector(revealLog), keyEquivalent: "")
        appMenu.addItem(withTitle: "Forget Paired PCs…",
                        action: #selector(forgetHosts), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SolStream",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit exists so that ⌘V works.
        //
        // macOS routes cut/copy/paste/select-all through menu key equivalents:
        // with no Edit menu they are not merely missing from a menu bar nobody
        // looks at, they DO NOTHING. The token prompt says "Paste the line it
        // prints below" and pasting was impossible — a first connection to a new
        // host meant typing 32 hex characters by hand, or giving up.
        //
        // It does not collide with the streamed application. InputCapture's
        // local monitor runs ahead of menu key-equivalent matching and consumes
        // every ⌘ combination it forwards, so ⌘V in a streamed window still
        // reaches Windows as Ctrl+V; and while the picker or a prompt is
        // focused, no stream window is key, so the monitor is not even
        // installed and the menu handles it.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Host carries everything that acts on the connection rather than on a
        // window, so "which PC am I on" never has to be inferred from a title bar.
        let hostMenuItem = NSMenuItem()
        let hostMenu = NSMenu(title: "Host")
        Self.reserve(hostMenu.addItem(withTitle: "Switch App…",
                                      action: #selector(switchApp), keyEquivalent: "o"))
        Self.reserve(hostMenu.addItem(withTitle: "Disconnect",
                                      action: #selector(disconnectHost), keyEquivalent: "d"))
        hostMenu.addItem(.separator())
        hostMenu.addItem(withTitle: "Forget Paired Hosts…",
                         action: #selector(forgetHosts), keyEquivalent: "")
        hostMenuItem.submenu = hostMenu
        mainMenu.addItem(hostMenuItem)

        // One NSWindow per streamed application, so the standard Window menu is
        // already the list of what is open — AppKit maintains it for us.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        // ⌃⌘F is the system's own full-screen shortcut, so this is where it
        // should have been all along.
        Self.reserve(windowMenu.addItem(withTitle: "Enter Full Screen",
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f"))
        Self.reserve(windowMenu.addItem(withTitle: "Close",
                                        action: #selector(NSWindow.performClose(_:)),
                                        keyEquivalent: "w"))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    /// Back to the picker without dropping the host connection. Closing the last
    /// application window already routes there, so this is that path taken
    /// deliberately rather than a second one.
    @objc private func switchApp() {
        guard !appWindows.isEmpty else { return }
        appWindows.forEach { $0.close() }
    }

    @objc private func disconnectHost() {
        // Detach the close callbacks first. A window's onClose is delivered on the
        // NEXT main-loop turn — deliberately, so it cannot deallocate the window
        // inside its own delegate method — and it routes back to the picker. Left
        // attached, disconnecting would show the connect window and then have a
        // picker appear over it, reconnecting to the host just left.
        let windows = appWindows
        appWindows.removeAll()
        windows.forEach {
            $0.onClose = nil
            $0.close()
        }

        clipboard?.stop()
        clipboard = nil
        session?.stop()
        session = nil
        agent?.disconnect()
        agent = nil
        picker?.close()
        picker = nil
        showConnectWindow()
    }


    /// Flush before revealing: the point of the menu item is that someone is
    /// about to open the file, and the last few lines are usually the ones that
    /// matter.
    @objc private func revealLog() {
        Log.flush()
        guard let url = Log.fileURL else {
            let alert = NSAlert()
            alert.messageText = "No log file"
            alert.informativeText = "SolStream could not create a log directory in ~/Library/Logs."
            alert.runModal()
            return
        }
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }

    // "Hide the PC's Cursor" is gone. The capture session is created with
    // IsCursorCaptureEnabled(false), so the host's pointer is never in the
    // picture and this Mac draws a real one from the shape the agent pushes.
    // There is nothing left for the menu item to toggle.

    @objc private func forgetHosts() {
        let alert = NSAlert()
        alert.messageText = "Forget paired PCs?"
        alert.informativeText = """
            SolStream will forget the pairing token it holds for each PC. \
            You will need to enter the token again — it is shown on SolStream's \
            own window on that PC, under "Pairing token".
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("SolStream.agentToken.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        Log.info("[agent] every stored pairing token forgotten")
    }

    // MARK: - Test support

    private func captureTestScreenshot() {
        // Prefer a stream window; fall back to whatever window is on screen so
        // the connect window can be captured too.
        guard let window = dropdownWindow
                ?? streamWindows.first?.window
                ?? appWindows.first?.window
                ?? NSApp.windows.first(where: { $0.isVisible }) else {
            Log.error("No window to capture")
            NSApp.terminate(nil)
            return
        }

        window.orderFrontRegardless()
        guard let image = CGWindowListCreateImage(
            .infinite, .optionIncludingWindow, CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            Log.error("CGWindowListCreateImage failed")
            NSApp.terminate(nil)
            return
        }

        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            let path = "/tmp/solstream_internal_screenshot.png"
            try? data.write(to: URL(fileURLWithPath: path))
            Log.info("Test screenshot saved to \(path) (\(data.count) bytes)")
        }
        NSApp.terminate(nil)
    }
}
