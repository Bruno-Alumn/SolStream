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
    private var connectWindow: ConnectWindow?
    private var agent: AgentConnection?
    private var session: StreamSession?
    private var appWindows: [AppWindow] = []
    private var picker: AppPicker?
    private var clipboard: ClipboardBridge?

    /// What the running stream was opened with, so a lost one can be opened
    /// again without going back through the picker. See `recoverMedia`.
    private var mediaRequest: AgentConnection.MediaRequest?
    private var streamConfig: StreamConfig?
    private var streamDisplay: RemoteDisplay?
    private var streamHost: String?
    private var recoveringMedia = false
    private var mediaRecoveryAttempts = 0
    /// The agent channel's final failure is on the stream windows, and the
    /// picture's own troubles must not paint over it. See `notice(for:)`.
    private var connectionLostShown = false

    /// Fields a command-line flag set, which the Settings window does not
    /// override; see `StreamSettings.apply`.
    private var settingsOverrides: Set<StreamSettings.Override> = []
    private var settingsWindow: SettingsWindow?
    private var settingsObservers: [NSObjectProtocol] = []
    /// A settings change waiting out its debounce; see `scheduleMediaRestart`.
    private var pendingRestart: DispatchWorkItem?

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
        observeSettings()
        // The bundle's version, which packaging stamps from the repository's
        // VERSION file -- the one place a version is written. Not the pretend
        // one: the log has to say what is really running.
        Log.startSession(version: "v" + Updater.bundleVersion(.main))

        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        testMode = arguments.contains("--test-screenshot")

        // --screenshot-after <seconds> waits long enough for real frames to
        // arrive before capturing, which is how a live stream gets verified.
        var captureDelay: TimeInterval = 2.0
        if let seconds = value(after: "--screenshot-after").flatMap(TimeInterval.init) {
            captureDelay = seconds
            testMode = true
        }

        // Each of these wins over the Settings window for this run: the test
        // harness, and anybody debugging from a terminal, must get exactly what
        // they typed, whatever was last chosen in the window.
        var config = StreamConfig()
        var overrides: Set<StreamSettings.Override> = []
        if let kbps = value(after: "--bitrate").flatMap(Int.init) {
            config.bitrateKbps = kbps
            overrides.insert(.bitrate)
            Log.info("[stream] bitrate \(kbps) kbit/s")
        }
        if let fps = value(after: "--fps").flatMap(Int.init), fps > 0 {
            config.frameRate = fps
            overrides.insert(.frameRate)
            Log.info("[stream] \(fps) fps")
        }
        if arguments.contains("--no-audio") {
            config.audio = false
            overrides.insert(.audio)
            Log.info("[stream] no sound from the host")
        }
        if let name = value(after: "--sound-quality") {
            // By the name Settings stores (dataSaver, standard, high, lossless)
            // or the one it shows, so either can be typed.
            let all = StreamSettings.SoundQuality.allCases
            if let quality = all.first(where: {
                $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                    || $0.title.caseInsensitiveCompare(name) == .orderedSame
            }) {
                config.audioEncoding = quality.encoding
                overrides.insert(.soundQuality)
                Log.info("[stream] sound quality \(quality.title): \(quality.encoding.summary)")
            } else {
                Log.error("[stream] --sound-quality \(name) is not one of "
                          + all.map(\.rawValue).joined(separator: ", ") + "; using Settings")
            }
        }
        if let from = value(after: "--sound-from") {
            // "apps" for the streamed apps' sound alone, "pc" for everything.
            switch from.lowercased() {
            case "apps", "app":
                config.audioSource = .apps
                overrides.insert(.soundSource)
                Log.info("[stream] sound from the streamed apps only")
            case "pc", "system":
                config.audioSource = .system
                overrides.insert(.soundSource)
                Log.info("[stream] sound from the whole PC")
            default:
                Log.error("[stream] --sound-from \(from) is not apps or pc; using Settings")
            }
        }
        settingsOverrides = overrides
        QualityPill.commandLineOverrides = overrides

        let host = value(after: "--host")
        // The agent may be reached somewhere other than the stream host — over
        // an SSH port forward during development, for instance.
        let agentHost = value(after: "--agent-host")

        // --agent-token supplies the host's shared secret once; it is remembered
        // per host afterwards. It is shown on SolStream's own window on the
        // host, under "Pairing token".
        if let token = value(after: "--agent-token"), let target = agentHost ?? host {
            AgentConnection.rememberToken(token, for: target)
            Log.info("[agent] token stored for \(target)")
        }

        self.agentHostOverride = agentHost
        // --display picks which host display to park applications on, by device
        // name or adapter substring.
        self.displayQuery = value(after: "--display")
        self.baseConfig = config

        if let host, let launchQuery = value(after: "--launch") {
            // Starts an installed application by name, skipping the picker.
            startLaunching(host: host, agentHost: agentHost ?? host, matching: launchQuery)
        } else if let host, let appWindowQuery = value(after: "--app-window") {
            startSingleApp(host: host, agentHost: agentHost ?? host, matching: appWindowQuery)
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
                self?.appWindows.first?.sendTestPointer(normalizedX: 0.75, normalizedY: 0.75)
            }
        }

        // --test-close-after <seconds> closes the streamed window exactly as the
        // red traffic-light button does — window.close(), so windowWillClose and
        // onClose run unchanged — and then leaves the app up so the picker that
        // follows can be read. Driving the real button needs accessibility
        // permission and a synthetic click; this is the same code path without
        // either, and the path is the whole point of the test.
        if let after = value(after: "--test-close-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                Log.info("[test] closing the streamed window")
                self?.appWindows.first?.close()
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
        } else {
            // Not in the test paths: they photograph the app on a timer, and
            // a check would put network traffic and log lines into a run that
            // is meant to show one thing.
            MainActor.assumeIsolated { Updater.shared.start() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous: the process is about to exit and the host needs to see
        // us go, or it stays busy for every other client.
        session?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// A click on the Dock icon with nothing on screen brings back whichever
    /// window the app is at. Closing the connect window while Settings was
    /// open, then Settings, used to leave a running app with no window and no
    /// way back to one but ⌘Q.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Stream windows are only out of sight when minimised, and AppKit's
        // own answer to the click is to bring one of those back.
        guard !flag, appWindows.isEmpty, !testMode else { return true }
        if let picker {
            picker.show()
        } else {
            showConnectWindow()
        }
        return false
    }

    // MARK: - Flow

    private func showConnectWindow() {
        // One at a time. Replacing one that was still open dropped its
        // controller and left its window up, with nothing behind its buttons.
        if let connectWindow, connectWindow.isOpen {
            connectWindow.bringToFront()
            return
        }
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
    /// - Parameter existing: a live connection to carry into the picker rather
    ///   than replacing. Closing a streamed window is not leaving the host, and
    ///   building a second connection to the same agent is what produced the
    ///   spurious "already streaming to another Mac".
    private func showPicker(host: String, reusing existing: AgentConnection? = nil) {
        let agentHost = agentHostOverride ?? host
        let agent = existing ?? AgentConnection(host: agentHost)
        // The stream's callbacks must not survive into the picker: they are
        // stored on the connection and it goes on receiving the host's pushes.
        agent.resetCallbacks()
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
        // capture makes it retain itself — and pins the picker and its icon
        // cache with it. Delivered on the main thread.
        agent.onState = { [weak self, weak picker, weak agent] state in
            switch state {
            case .failed(let message):
                // `explain` already names the host and says what to do.
                picker?.showFailure(message)
            case .waiting(let message):
                picker?.showWaiting(message)
            case .needsToken(let host, let rejected):
                // A sheet on the picker the person is already looking at.
                // `report` delivers on the main queue.
                MainActor.assumeIsolated {
                    self?.promptForToken(host: host, rejected: rejected, over: picker?.window,
                                         agent: agent) { picker?.showFailure($0) }
                }
            default:
                break
            }
        }

        // Both lists, then show them together — a half-populated picker that
        // grows under the cursor is worse than a moment's wait. The Start Menu
        // is fetched when the picker opens and then reused: it rarely changes
        // and it is the expensive half, while the host's `windowsChanged` push
        // fires for every window opened or closed anywhere on the PC.
        var cachedApps: [RemoteApp]?
        let fill: (_ includeApps: Bool) -> Void = { [weak self, weak agent, weak picker] includeApps in
            guard let agent else { return }
            let reuse = includeApps ? nil : cachedApps
            agent.windows { windows in
                let present: ([RemoteApp]) -> Void = { apps in
                    DispatchQueue.main.async {
                        guard self != nil else { return }
                        cachedApps = apps
                        picker?.present(windows: windows, apps: apps)
                    }
                }
                if let reuse { present(reuse) } else { agent.apps(completion: present) }
            }
        }
        agent.onDisplays = { _ in fill(true) }
        agent.onWindowsChanged = { fill(false) }
        if existing == nil {
            agent.connect()
        } else if agent.isConnected {
            // A reused socket produces no second `hello`, so the unprompted
            // `displays` push that normally drives the first fill never comes.
            fill(true)
        } else if !agent.willReconnect {
            // Refused for good (busy, impersonation) or already closed: nothing
            // is coming, so do not leave the spinner up.
            picker.showFailure("The connection to \(host) was lost. Go back and connect again.")
        }
        // Otherwise the connection is in its reconnect backoff: the spinner
        // stays, the reconnect's own greeting fills the list, and `onState`
        // puts a real failure on screen. Asking now would get empty lists,
        // which the picker would draw as a confident "0 windows open".
    }

    /// Ask for the pairing token over `parent`, or report that there is none.
    @MainActor
    private func promptForToken(host: String, rejected: Bool, over parent: NSWindow?,
                                agent: AgentConnection?,
                                onRefused: @escaping (String) -> Void) {
        TokenPrompt.present(host: host, rejected: rejected, over: parent) { token in
            guard let token else {
                onRefused("\(host) needs a pairing token to go any further.")
                return
            }
            agent?.supplyToken(token)
        }
    }

    /// For the command-line paths, which have no window to ask in.
    private static func logAgentState(_ state: AgentConnection.State) {
        switch state {
        case .failed(let message):
            Log.error("[app] \(message)")
        case .waiting(let message):
            Log.info("[app] \(message)")
        case .needsToken(let host, _):
            Log.error("[app] \(host) needs a pairing token. It is on SolStream's own window "
                      + "on that PC, under \"Pairing token\"; start SolStream here once with "
                      + "--agent-token <token>.")
        default:
            break
        }
    }

    /// The picker's launch path without the picker, for `--launch` and tests.
    private func startLaunching(host: String, agentHost: String, matching query: String) {
        let agent = AgentConnection(host: agentHost)
        self.agent = agent
        agent.onState = Self.logAgentState
        agent.onDisplays = { [weak self, weak agent] _ in
            guard let agent else { return }
            // Once only. The host greets EVERY connection with `displays`,
            // including the one after a reconnect, and this is the entry point
            // to the whole open flow. Cleared before the work: `apps` is a
            // round trip and a second push can land inside it.
            agent.onDisplays = nil
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
            // request to see it, not to start a second copy. Only a window
            // that is surely its own, though, or the one that could be; see
            // `LaunchMatch`.
            picker?.showBusy("Opening \(app.name) on \(host)…")
            agent.windows { [weak self] windows in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let existing = LaunchMatch.existing(app.name, in: windows) {
                        Log.info("[app] \"\(app.name)\" is already open; attaching to "
                                 + "\"\(existing.title)\"")
                        self.attach(existing, host: host, agent: agent)
                        return
                    }
                    self.launch(app: app, host: host, agent: agent,
                                knownPIDs: Set(windows.map(\.pid)))
                }
            }
        }
    }

    private func launch(app: RemoteApp, host: String, agent: AgentConnection,
                        knownPIDs: Set<Int>) {
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
                            guard let existing = LaunchMatch.afterLaunch(
                                app.name, in: windows, knownPIDs: knownPIDs) else {
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

    /// Stream one window, keeping the picker up until there is one to look at.
    ///
    /// The picker is closed in `presentApps`, as a window is about to appear, so
    /// every failure on the way — no display, a refused or dead media session —
    /// puts its reason on the picker the person is still looking at.
    private func attach(_ window: RemoteWindow, host: String, agent: AgentConnection) {
        picker?.showBusy("Opening \(window.title) on \(host)…")
        start(host: host, agent: agent, targets: [window])
    }

    /// NVENC's H.264 maximum, and now a number both ends have to agree on.
    ///
    /// Above it the handshake succeeds and no frame ever arrives, with the
    /// reason only in the host's own log — and a 16" MacBook Pro at More Space
    /// asks for 4112x2658, so this is reachable with ordinary hardware rather
    /// than a pathological setup. Every request the Mac sends is clamped to it
    /// per axis, and the host clamps to the same figure, so the two arrive at
    /// the same canvas rather than at two that merely resemble each other.
    private static let encoderLimit = 4096

    static func clampedToEncoder(width: Int, height: Int) -> (width: Int, height: Int) {
        (min(width, encoderLimit), min(height, encoderLimit))
    }

    /// How many pixels a full-screen window on this Mac can show: its screen in
    /// points times the backing scale factor.
    private static func screenPixels() -> (width: Int, height: Int)? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        return (Int((screen.frame.width * scale).rounded()),
                Int((screen.frame.height * scale).rounded()))
    }

    /// The canvas this Mac wants the host to render at: anything larger is
    /// bitrate spent on pixels that get thrown away and anything smaller is
    /// upscaled. Clamped to the encoder's maximum.
    private static func desiredCanvas() -> CGSize? {
        guard let pixels = screenPixels() else { return nil }
        let clamped = clampedToEncoder(width: pixels.width, height: pixels.height)
        return CGSize(width: clamped.width, height: clamped.height)
    }

    /// Resolve the capture display, size it to this Mac, then open the windows.
    ///
    /// The displays are asked for again first. The connection outlives each
    /// visit to the picker, and the list from its greeting never saw a virtual
    /// display set up on the PC since -- so the Mac went on warning that there
    /// was none, and streaming the real monitor. A plain request, which every
    /// host answers; failing that, the list already held.
    private func start(host: String, agent: AgentConnection, targets: [RemoteWindow]) {
        agent.refreshDisplays { [weak self] displays in
            DispatchQueue.main.async {
                self?.start(host: host, agent: agent, targets: targets,
                            displays: displays.isEmpty ? agent.displays : displays)
            }
        }
    }

    private func start(host: String, agent: AgentConnection, targets: [RemoteWindow],
                       displays: [RemoteDisplay]) {
        guard let capture = Self.selectDisplay(from: displays, preferring: displayQuery) else {
            Log.error("[app] host reported no displays")
            picker?.clearBusy()
            picker?.showFailure("\(host) did not offer a display to capture.")
            return
        }
        Log.info("[app] capture display \(capture.name) "
                 + "\(capture.width)x\(capture.height) @ \(capture.x),\(capture.y) "
                 + "[\(capture.adapter)]\(capture.isVirtual ? " virtual" : "")")
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

    /// Stream one or more Windows applications, each in its own native window.
    ///
    /// The agent is consulted BEFORE the stream launches, because the encode
    /// canvas has to match the capture display exactly: when it does, the
    /// scale factor is 1.0 and every crop is pixel-exact rather than resampled.
    private func startSingleApp(host: String, agentHost: String, matching query: String) {
        let queries = query.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        let agent = AgentConnection(host: agentHost)
        self.agent = agent
        agent.onState = Self.logAgentState

        agent.onDisplays = { [weak self, weak agent] displays in
            guard let self, let agent,
                  let capture = Self.selectDisplay(from: displays,
                                                   preferring: self.displayQuery) else {
                Log.error("[app] host reported no displays")
                return
            }
            // Once only — see `startLaunching`. Cleared after the guard, so a
            // push that carried no usable display still leaves a way in.
            agent.onDisplays = nil
            Log.info("[app] capture display \(capture.name) "
                     + "\(capture.width)x\(capture.height) @ \(capture.x),\(capture.y) "
                     + "[\(capture.adapter)]\(capture.isVirtual ? " virtual" : "")")

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
                                  display: capture, config: self.baseConfig)
                }
            }
        }

        agent.connect()
    }

    /// Get permission before streaming a real monitor, because the crop the user
    /// is shown is not the boundary of what leaves the host.
    ///
    /// Returns true when the session may go ahead: always on a virtual display,
    /// and on a real one only if the person at this Mac said so having been told
    /// what it means. `isVirtual` is the right test rather than `isCaptured` —
    /// `isCaptured` says the host is encoding this display, which is true in
    /// exactly the case being warned about; what makes a display safe to encode
    /// whole is that no ordinary window can be on it.
    ///
    /// Not a silent downgrade to something safer, either. Refusing outright
    /// would make SolStream useless on every PC without the display driver, and
    /// quietly streaming a different display would mean the crops come out of
    /// the wrong pixels — so the choice is put to the person whose desktop it is.
    private func confirmWholeDisplayCapture(host: String, display: RemoteDisplay,
                                            targets: [RemoteWindow]) -> Bool {
        guard !display.isVirtual else { return true }

        let names = targets.map { $0.title }.joined(separator: ", ")
        Log.error("[app] \(display.name) [\(display.adapter)] is a real monitor, not a "
                  + "virtual display. The stream carries the whole of it, so everything "
                  + "on that monitor is sent and not just \(names).")

        // The test paths never see the alert, and must not: they drive the app
        // from the command line and photograph it on a timer, and `runModal`
        // stops that timer ever firing — the run would hang rather than fail.
        // The log line above is the whole of the warning there.
        guard !testMode else { return true }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Streaming this would send the whole of \(display.name)"
        alert.informativeText = """
            \(host) has no virtual display for SolStream to put \(names) on, so it will \
            capture that whole monitor and show you a piece of the picture. Everything \
            else on the monitor is captured with it — every other window, and anything \
            that opens there while you are connected — and all of it crosses the network.

            Installing the virtual display driver on \(host) is what makes streaming one \
            application send one application.
            """
        // "Don't Stream" first, so it is the default and Return is the safe
        // answer to a question about somebody's desktop.
        alert.addButton(withTitle: "Don't Stream")
        alert.addButton(withTitle: "Stream the Whole Monitor")
        let proceed = alert.runModal() == .alertSecondButtonReturn
        Log.info("[app] whole-monitor capture was \(proceed ? "accepted" : "refused")")
        return proceed
    }

    /// Lay the chosen windows out side by side on the capture display, then open
    /// one native window per app over a single shared stream.
    private func openApps(host: String, agent: AgentConnection,
                          targets: [RemoteWindow], display: RemoteDisplay,
                          config baseConfig: StreamConfig) {
        // What is really being sent, said before any of it is sent.
        //
        // "Stream one application" is not a capture boundary. The host encodes
        // ONE DISPLAY and each window below shows a crop of the decoded frame,
        // so every pixel of that display is encoded, encrypted and put on the
        // wire whatever the crops happen to show. On the virtual display that
        // costs nobody anything, because nothing else is ever on it — which is
        // the whole reason the virtual display exists. On a real monitor it
        // means the entire desktop of the person sitting at that PC crosses the
        // network while this application's own interface says one application is
        // being streamed. The host falls back to a real monitor by itself
        // whenever the virtual display driver is missing or stopped, and says so
        // only in its own log, on the machine nobody is looking at.
        guard confirmWholeDisplayCapture(host: host, display: display, targets: targets) else {
            picker?.clearBusy()
            picker?.showFailure("Nothing was streamed. \(display.name) on \(host) is a real "
                                + "monitor, so everything on it would have been sent, not "
                                + "just \(targets.count == 1 ? "this window" : "these windows").")
            return
        }

        // What the Settings window chose, under whatever the command line set.
        var config = StreamSettings.shared.apply(to: baseConfig, host: host,
                                                 overrides: settingsOverrides)
        Log.info("[stream] \(Self.describe(config))")
        // The encode canvas matches the capture display, which makes the scale
        // factor 1.0 and every crop pixel-exact. Fixed for the session: the
        // encoder's output type is set once, so changing it means a new encoder
        // and a new parameter set. Resizing a window therefore resizes the
        // WINDOW within a fixed canvas — no mode change, no reconnect, no black
        // frame.
        // Clamped to the encoder's maximum; see `encoderLimit`.
        (config.width, config.height) = Self.clampedToEncoder(width: display.width,
                                                              height: display.height)
        if config.width != display.width || config.height != display.height {
            Log.info("[canvas] capture display is \(display.width)x\(display.height); "
                     + "clamped to \(config.width)x\(config.height) for the encoder")
        }

        Self.reportIdealCanvas(display: display)

        // The media session is agreed on the agent channel, which has already
        // authenticated both ends, before any window is shown — so the only
        // thing that can fail here is the host declining to capture.
        Task { @MainActor [weak self] in
            guard let self else { return }
            var request = AgentConnection.MediaRequest(
                display: display.name,
                fps: config.frameRate,
                bitrate: config.bitrateKbps * 1000,
                audio: config.audio,
                audioEncoding: config.audioEncoding,
                audioSource: config.audioSource)
            // The canvas, said out loud: it is the size every crop is expressed
            // in, so the host must encode exactly this and not the raw source.
            request.width = config.width
            request.height = config.height
            // The negotiation is the start of the stream: an install that
            // finishes during it must not quit the app halfway through, with
            // no session yet for quitting to close. Set back on each way out
            // that ends without a window; `presentApps` keeps it set.
            Updater.shared.isStreaming = true
            guard let media = await agent.openMediaSession(request) else {
                Updater.shared.isStreaming = false
                Log.error("[app] \(host) refused the media session")
                self.picker?.clearBusy()
                self.picker?.showFailure("\(host) refused to start streaming.")
                return
            }
            guard media.streaming else {
                Updater.shared.isStreaming = false
                Log.error("[app] \(host) agreed keys but did not start: "
                          + (media.message ?? "no reason given"))
                self.picker?.clearBusy()
                self.picker?.showFailure("\(host) agreed to stream and then did not: "
                                         + (media.message ?? "it gave no reason"))
                return
            }
            self.mediaRequest = request
            self.presentApps(host: host, agent: agent, targets: targets,
                             display: display, config: config, media: media)
        }
    }

    private func presentApps(host: String, agent: AgentConnection, targets: [RemoteWindow],
                             display: RemoteDisplay, config: StreamConfig,
                             media: AgentConnection.MediaSession) {
        // The host has agreed to stream and windows are about to be shown, so
        // the picker has done its job. It was kept open all the way through the
        // negotiation so that a refusal had somewhere to be said; see `attach`.
        picker?.close()
        picker = nil
        // The picker's refresh goes with it. Left installed, every window the
        // host opened or closed during the stream — and every reconnect's
        // greeting — re-enumerated windows and the Start Menu for a picker
        // nobody can see. Returning to the picker installs them again.
        agent.onDisplays = nil
        agent.onWindowsChanged = nil

        // Only while something is actually streamed, and Mac-to-PC only while
        // one of these windows has the keyboard: copying a password in another
        // application must not send it to the PC. Built whatever Settings says,
        // and started only if it says so, so that turning sync on mid-stream
        // has a bridge to start; see `applyClipboardSetting`.
        let bridge = ClipboardBridge(agent: agent) { [weak self] in
            self?.appWindows.contains { $0.window?.isKeyWindow == true } ?? false
        }
        clipboard = bridge
        if StreamSettings.shared.syncsClipboard {
            bridge.start(resuming: false)
        } else {
            Log.info("[clipboard] sync is off in Settings")
        }

        let session = StreamSession(host: host, config: config, session: media)
        self.session = session
        streamConfig = config
        streamDisplay = display
        streamHost = host
        mediaRecoveryAttempts = 0
        // Nothing downloads or installs while this is set; see Updater.
        MainActor.assumeIsolated { Updater.shared.isStreaming = true }

        let tiles = Self.tileLayout(count: targets.count, on: display)

        for (index, target) in targets.enumerated() {
            let tile = tiles[index]

            let appWindow = AppWindow(session: session, agent: agent, remote: target,
                                      display: display, tile: tile)
            appWindow.onClose = { [weak self, weak appWindow] in
                guard let self else { return }
                self.appWindows.removeAll { $0 === appWindow }
                guard self.appWindows.isEmpty else { return }
                // End the media session by asking, not by dropping the socket.
                // The UDP BYE alone only sets `running = false` on the host: the
                // capture, encoder, sender and receive threads, the socket and
                // the keys all survive until something starts a new session, and
                // any key or mouse button still held is never released.
                self.session?.stop()
                self.session = nil
                self.mediaRequest = nil
                self.streamConfig = nil
                self.streamDisplay = nil
                self.streamHost = nil
                self.pendingRestart?.cancel()
                self.pendingRestart = nil
                agent.closeMediaSession()
                self.clipboard?.stop()
                self.clipboard = nil
                // An update the person asked for during the stream installs
                // from here, and relaunches.
                MainActor.assumeIsolated { Updater.shared.isStreaming = false }
                // KEEP THE AGENT CONNECTION. The host's one-client gate cannot
                // tell a new connection from the last one's teardown still
                // running, and answers "busy". Nothing needs the disconnect: the
                // close path already sent `lock off`, which restores the window.
                if !self.testMode {
                    self.showPicker(host: host, reusing: agent)
                }
            }
            // Gaining the keyboard sends a Mac copy held back until now, before
            // the ⌘V that follows; losing it brings the PC's last copy over
            // before the paste in whatever application is next.
            appWindow.onKeyboardChange = { [weak self] in
                self?.clipboard?.syncNow()
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
            // What the host last said about its cursor, before the window can
            // become key: it only pushes on change, and the push that said a
            // game had hidden it went to the picker.
            if let shape = agent.lastCursorShape {
                appWindow.hostCursorChanged(shape, reportsHidden: agent.cursorReportsHidden)
            }
            appWindow.show()

            // Size the host window to this one and pin it there. The window owns
            // its own geometry so the initial placement and a later drag go
            // through identical code, and the lock is taken only once the window
            // is where it belongs — it enforces whatever geometry it finds.
            appWindow.placeAndLock()
            agent.focus(windowID: target.id)
            Log.info("[app] \"\(target.title)\" -> tile \(tile)")
        }

        wire(session, host: host, agent: agent)

        // The host pushes this whenever its cursor changes shape. Applied to
        // every window: the cursor is global to the host, and only the one the
        // pointer is actually over can show it anyway.
        agent.onCursorShape = { [weak self, weak agent] shape in
            let reportsHidden = agent?.cursorReportsHidden ?? false
            self?.appWindows.forEach { $0.hostCursorChanged(shape, reportsHidden: reportsHidden) }
        }

        // Closing the application on the Windows side ends the stream, without
        // waiting for the poll to catch up. Closing the last
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

        // The picker's state handler went with it; a stream needs its own. A
        // token the host stops accepting is asked for over the windows, and a
        // refusal no retry can fix is said rather than waited on.
        connectionLostShown = false
        agent.onState = { [weak self, weak agent] state in
            guard let self else { return }
            switch state {
            case .needsToken(let host, let rejected):
                let parent = self.appWindows.first { $0.window?.isKeyWindow == true }?.window
                    ?? self.appWindows.first?.window
                MainActor.assumeIsolated {
                    self.promptForToken(host: host, rejected: rejected, over: parent,
                                        agent: agent) { reason in
                        self.appWindows.forEach { $0.setError("Can't reconnect", detail: reason) }
                    }
                }
            case .failed(let message) where agent?.willReconnect == false:
                self.connectionLostShown = true
                self.appWindows.forEach { $0.setError("Lost the connection", detail: message) }
            case .waiting(let message):
                // The host is still holding the connection this Mac lost; the
                // channel knocks again by itself and says when it gives up.
                self.appWindows.forEach { $0.setStatus("Reconnecting…", detail: message) }
            default:
                break
            }
        }

        // The host forgets every window it was managing when the socket drops,
        // so a reconnect has to say it all again.
        agent.onReconnected = { [weak self, weak agent] in
            guard let self, let agent else { return }
            self.appWindows.forEach { $0.reassertOnHost() }
            // The host ends the media session whenever the agent channel drops
            // — a Wi-Fi blip, a missed heartbeat, a host restart — so the
            // picture is gone even though the windows came back. Ask again.
            self.mediaRecoveryAttempts = 0
            self.recoverMedia(host: host, agent: agent)
        }

        // STARTED LAST, AND THAT IS THE POINT. `start()` calls `onPhase`
        // synchronously — `.waitingForVideo`, and `.failed` when the socket
        // will not open at all — so starting it up where the session is built,
        // before this handler exists and before there is a window to put a
        // message in, threw both away. The one failure the user most needs to
        // hear about was the one that vanished: the windows stayed on
        // "Connecting to <host>" for ever, with the reason only in the log.
        //
        // Nothing above this line needs the socket. The host does not send a
        // byte until the client's first packet reaches it — that ping is what
        // gets through the NAT — so the only cost of starting here is the few
        // milliseconds spent building the windows.
        session.start()
        // The window shown above took the keyboard before there was a session
        // to send to.
        appWindows.forEach { $0.inputBecameLive() }

        // The request was built before the host was asked, and Settings can be
        // open beside the picker while it answers. A change made in that wait
        // found no windows to restart, so it is caught up with here; the
        // debounce and the recovery guards treat it like any other.
        if let request = mediaRequest,
           Self.applying(StreamSettings.shared, to: request, config: config, host: host,
                         overrides: settingsOverrides) != nil {
            Log.info("[app] settings changed while the stream was opening")
            scheduleMediaRestart()
        }
    }

    /// The session's own reports, routed to the windows — and, when the picture
    /// is lost, into `recoverMedia` rather than straight to an error.
    ///
    /// Split out of `presentApps` because a recovered session needs exactly the
    /// same handlers as the first one.
    private func wire(_ session: StreamSession, host: String, agent: AgentConnection) {
        // The watchdog speaks once frames have been arriving and then stop, or
        // once a new session has gone a few seconds without its first picture
        // -- "Waiting for video" says so until then.
        session.onLiveness = { [weak self, weak agent] liveness in
            guard let self else { return }
            switch liveness {
            case .live:
                self.mediaRecoveryAttempts = 0
                self.appWindows.forEach { $0.hideStatus() }
            case .stalled(let seconds):
                self.show(self.notice(for: .stalled(seconds: seconds), agent: agent, host: host))
            case .lost:
                if self.mediaRecoveryAttempts >= 3 {
                    // Three restarts in a row and not one picture from any of
                    // them. A restart that shows one starts the count again
                    // (`.streaming`), so this is a stream that cannot be got
                    // back by restarting it, and Try Again is the honest offer
                    // rather than a fourth "Reconnecting…" and a fifth.
                    self.appWindows.forEach {
                        $0.setError("Lost the stream",
                                    detail: "No picture from \(host) after three restarts.")
                    }
                    return
                }
                // With the agent channel down too, `onReconnected` recovers.
                let notice = self.notice(for: .lost, agent: agent, host: host)
                if case .restart = notice, let agent {
                    self.recoverMedia(host: host, agent: agent)
                } else {
                    self.show(notice)
                }
            }
        }

        session.onPhase = { [weak self, weak agent] phase in
            guard let self else { return }
            switch phase {
            case .streaming:
                // A session that reaches its first frame has recovered, so the
                // next loss starts counting from zero. Only `.live` reset this
                // before, and a fresh session never reports `.live`, so three
                // recoveries over a long stream used up every retry it had.
                self.mediaRecoveryAttempts = 0
                self.appWindows.forEach { $0.hideStatus() }
            case .failed(let message):
                let notice = self.notice(for: .failed(message), agent: agent, host: host)
                if case .restart = notice, let agent {
                    Log.info("[app] stream failed (\(message)); restarting it")
                    // On the next turn: `start()` reports a socket that will not
                    // open synchronously, from inside itself, and tearing the
                    // session down from in there would run `stop()` mid-`start()`.
                    DispatchQueue.main.async { [weak self] in
                        self?.recoverMedia(host: host, agent: agent)
                    }
                } else {
                    // Not "Stream failed" while the channel is coming back by
                    // itself: its Try Again closes the windows that
                    // `onReconnected` is about to restore.
                    self.show(notice)
                }
            case .waitingForVideo:
                self.appWindows.forEach { $0.setStatus("Waiting for video") }
            default:
                break
            }
        }
    }

    /// `AppDelegate.notice(for:channel:...)`, with what this stream knows put in.
    /// - Parameter canRestart: in place of whether the recovery has tries left.
    private func notice(for trouble: StreamTrouble, agent: AgentConnection?, host: String,
                        canRestart: Bool? = nil) -> StreamNotice {
        let channel = agent.map {
            Self.outlook(isConnected: $0.isConnected, willReconnect: $0.willReconnect)
        } ?? .gone
        return Self.notice(for: trouble, channel: channel, host: host,
                           canRestart: canRestart ?? (mediaRecoveryAttempts < 3),
                           finalErrorShown: connectionLostShown)
    }

    /// Put a notice on every stream window. `.restart` is for the caller to act
    /// on, and shows nothing here.
    private func show(_ notice: StreamNotice) {
        switch notice {
        case .status(let title, let detail):
            appWindows.forEach { $0.setStatus(title, detail: detail) }
        case .error(let title, let detail):
            appWindows.forEach { $0.setError(title, detail: detail) }
        case .restart, .keep:
            break
        }
    }

    /// Open a new media session for the windows already on screen.
    ///
    /// A `StreamSession` cannot be restarted in place — `stop()` releases the
    /// decoder and `start()` does not build another — so this builds a fresh
    /// one from a fresh `media open` and moves every window onto it. The host's
    /// `Start` stops whatever session it had first, so asking again is always
    /// safe. Bounded: after three tries in a row the windows say so and keep
    /// the Retry button, which goes back to the picker as before.
    /// - Parameter status: what the windows say meanwhile, when it is not a
    ///   reconnect -- a restart to apply new settings, which nothing went wrong
    ///   to cause.
    private func recoverMedia(host: String, agent: AgentConnection,
                              status: (title: String, detail: String)? = nil) {
        // Every caller is a handler the session or the agent delivers on main.
        dispatchPrecondition(condition: .onQueue(.main))
        guard !recoveringMedia, !appWindows.isEmpty,
              let request = mediaRequest, let config = streamConfig,
              let display = streamDisplay else { return }

        // A host that came back from a restart may have a different display
        // under the same name, or none. The crops and tiles are in the old
        // display's pixels, so streaming the new one would show the wrong part
        // of it: back to the picker instead. Current after a reconnect, because
        // `onReconnected` fires only once the greeting's display list is in.
        let displays = agent.displays
        if !displays.isEmpty, !displays.contains(where: {
            $0.name == display.name && $0.width == display.width && $0.height == display.height
        }) {
            Log.info("[app] \(display.name) changed while the stream was down; "
                     + "returning to the picker")
            appWindows.forEach {
                $0.setError("Lost the stream",
                            detail: "\(host)'s display changed. Try Again to pick the app again.")
            }
            return
        }

        recoveringMedia = true
        mediaRecoveryAttempts += 1
        let attempt = mediaRecoveryAttempts
        Log.info("[app] restarting the stream from \(host) (attempt \(attempt))")
        let status = status ?? ("Reconnecting…", "Restarting the stream from \(host)")
        appWindows.forEach {
            $0.setStatus(status.title, detail: status.detail)
        }
        // Handlers off first: stopping the old session reports `.failed`
        // asynchronously, which would land in here again.
        if let old = session {
            old.onPhase = nil
            old.onLiveness = nil
            old.stop()
        }
        session = nil

        Task { @MainActor [weak self, weak agent] in
            guard let self, let agent else { return }
            let media = agent.isConnected ? await agent.openMediaSession(request) : nil
            self.recoveringMedia = false
            // The windows may all have closed during the wait.
            guard !self.appWindows.isEmpty, self.session == nil else { return }
            guard let media, media.streaming else {
                // The channel dropping under the open is the usual reason it
                // failed, and then `onReconnected` tries again with a fresh
                // count: say so, rather than offer a Try Again that would
                // close these windows first.
                let notice = self.notice(for: .restartFailed(media?.message), agent: agent,
                                         host: host, canRestart: attempt < 3)
                if case .restart = notice {
                    let delay = Double(1 << attempt)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak agent] in
                        guard let self, let agent, self.session == nil else { return }
                        self.recoverMedia(host: host, agent: agent)
                    }
                } else {
                    self.show(notice)
                }
                return
            }
            let fresh = StreamSession(host: host, config: config, session: media)
            self.session = fresh
            self.wire(fresh, host: host, agent: agent)
            self.appWindows.forEach { $0.rebind(to: fresh) }
            fresh.start()
            self.appWindows.forEach { $0.inputBecameLive() }
            Log.info("[app] stream restarted")
        }
    }

    // MARK: - Settings

    private func observeSettings() {
        let center = NotificationCenter.default
        settingsObservers = [
            // From the popover on a streamed window, which has no business
            // owning a window of its own.
            center.addObserver(forName: StreamSettings.openSettingsRequest, object: nil,
                               queue: .main) { [weak self] _ in
                self?.showSettings()
            },
            center.addObserver(forName: StreamSettings.didChange, object: nil,
                               queue: .main) { [weak self] note in
                let restarts = note.userInfo?[StreamSettings.restartsStreamKey] as? Bool ?? false
                self?.settingsChanged(restartsStream: restarts)
            },
        ]
    }

    /// One window, made the first time it is asked for and brought forward
    /// every time after.
    @objc private func showSettings() {
        let settings = settingsWindow ?? SettingsWindow()
        settingsWindow = settings
        settings.show()
    }

    /// Settings, where the Updates card shows the check as it runs and what it
    /// found -- rather than an alert, which would have to be dismissed to be
    /// rid of and could not show a download's progress.
    @objc private func checkForUpdates() {
        showSettings()
        MainActor.assumeIsolated { Updater.shared.checkNow() }
    }

    /// Volume, buffering and the mouse are applied by whoever owns them as they
    /// change. What is left here is the clipboard, and the changes the host can
    /// only take by opening the stream again.
    private func settingsChanged(restartsStream: Bool) {
        applyClipboardSetting()
        if restartsStream, !appWindows.isEmpty {
            scheduleMediaRestart()
        }
    }

    /// Start or stop the running stream's clipboard bridge to match Settings.
    private func applyClipboardSetting() {
        guard let clipboard else { return }
        let wanted = StreamSettings.shared.syncsClipboard
        guard wanted != clipboard.isRunning else { return }
        if wanted {
            // Only ever mid-stream here -- the bridge exists only while one is
            // open -- so this is sync coming on over clipboards that were left
            // alone, whether or not it was on when the stream opened.
            clipboard.start(resuming: true)
        } else {
            clipboard.stop()
            Log.info("[clipboard] sync turned off in Settings")
        }
    }

    /// Restart the picture once the settings have stopped moving.
    ///
    /// A quality pop-up stepped through three choices, or 30 and 60 tried back
    /// to back, is one restart rather than a blackout per click: each restart
    /// costs the windows their picture until the host's first keyframe.
    private func scheduleMediaRestart(after delay: TimeInterval = 0.3) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingRestart = nil
            self?.restartMedia(reason: "settings changed")
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Open the stream again with what Settings now says, keeping the windows.
    ///
    /// Frame rate, bitrate, whether the PC captures its sound and how it
    /// encodes it are fixed on the host when a media session opens, so a new
    /// value needs a new session.
    /// This rebuilds the stored request from the settings and hands it to
    /// `recoverMedia`, which already knows how to swap a session under windows
    /// that stay where they are.
    private func restartMedia(reason: String) {
        guard !appWindows.isEmpty, let host = streamHost, let agent,
              let request = mediaRequest, let config = streamConfig else { return }
        // A recovery in flight is opening a session with the old request, and
        // a second open would race it. Once it settles, this comes round again.
        guard !recoveringMedia else {
            scheduleMediaRestart()
            return
        }
        guard let fresh = Self.applying(StreamSettings.shared, to: request, config: config,
                                        host: host, overrides: settingsOverrides) else {
            // Balanced at home is the same 20 Mbps as Automatic: nothing to do.
            return
        }
        mediaRequest = fresh.request
        streamConfig = fresh.config
        Log.info("[app] \(reason); restarting the stream at \(Self.describe(fresh.config))")
        // With the agent down, `onReconnected` brings the stream back and
        // reads the request just stored. With it up, this opens the session
        // now -- including when recovery has given up and the windows say
        // "Lost the stream", which is exactly when a lower quality or 30 fps
        // is reached for. A retry still waiting out its backoff is dropped
        // when it fires: by `recoverMedia` while this one is in flight, and by
        // its own check for a session once this one has succeeded.
        guard agent.isConnected else { return }
        mediaRecoveryAttempts = 0
        recoverMedia(host: host, agent: agent,
                     status: ("Applying settings…", "Restarting the picture from \(host)"))
    }

    /// `request` and `config` with the settings' frame rate, bitrate, sound,
    /// sound quality and sound source, or nil when the stream already has them
    /// all -- in which case there is nothing to restart for.
    ///
    /// The sound's quality and source count only while there is sound: with it off, the
    /// host captures none to encode, and the restart that turns it back on
    /// picks the new quality up with it.
    static func applying(_ settings: StreamSettings, to request: AgentConnection.MediaRequest,
                         config: StreamConfig, host: String,
                         overrides: Set<StreamSettings.Override>)
        -> (request: AgentConnection.MediaRequest, config: StreamConfig)? {
        let fresh = settings.apply(to: config, host: host, overrides: overrides)
        let soundChanged = fresh.audio != config.audio
            || (fresh.audio && (fresh.audioEncoding != config.audioEncoding
                                || fresh.audioSource != config.audioSource))
        guard fresh.frameRate != config.frameRate || fresh.bitrateKbps != config.bitrateKbps
                || soundChanged else { return nil }
        var updated = request
        updated.fps = fresh.frameRate
        updated.bitrate = fresh.bitrateKbps * 1000
        updated.audio = fresh.audio
        updated.audioEncoding = fresh.audioEncoding
        updated.audioSource = fresh.audioSource
        return (updated, fresh)
    }

    static func describe(_ config: StreamConfig) -> String {
        "\(config.frameRate) fps, \(config.bitrateKbps) kbit/s, "
            + (config.audio ? "sound \(config.audioEncoding.summary)"
                + (config.audioSource == .apps ? " from the streamed apps" : " from the whole PC")
                : "sound off")
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
                // quiet. Windows placed on a display the host is not encoding are
                // cropped out of the wrong pixels, and the result looks like a
                // working stream of something else entirely.
                //
                // `isCaptured` is what the host says it would capture by default.
                // The media session names its own display, so a --display that
                // disagrees is honoured end to end -- but the host's own window
                // rescue and its stranded-dialog logic key off the default, so
                // saying so is still worth a line.
                if !match.isCaptured, let captured = displays.first(where: { $0.isCaptured }) {
                    Log.error("[app] \(match.name) is not the display this host captures"
                              + " by default — that is \(captured.name). Windows opened"
                              + " on \(match.name) are outside what the host rescues"
                              + " stranded dialogs from. Drop --display to use"
                              + " \(captured.name).")
                }
                return match
            }
            Log.error("[app] no display matched \"\(query)\"; falling back. Candidates: "
                      + displays.map { "\($0.name) [\($0.adapter)]" }.joined(separator: ", "))
        }
        // The host's own answer first: it resolves its capture display at startup
        // and reports which one that is, so guessing from "virtual, else primary"
        // could only ever agree with it by luck.
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
        guard let physical = screenPixels() else { return }
        Log.info("[canvas] host display \(display.width)x\(display.height); this Mac "
                 + "shows \(physical.width)x\(physical.height) physical")
        if display.width < physical.width || display.height < physical.height {
            Log.info("[canvas] a full-screen window would be upscaled. For 1:1, set the "
                     + "capture display to \(physical.width)x\(physical.height).")
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
        appMenu.addItem(withTitle: "About SolStream",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…",
                        action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘, as in every Mac application, and not moved onto ⌃⌘: it is not
        // reserved the way ⌘Q is, so while a streamed window has the keyboard
        // it reaches the PC as Ctrl+, -- many Windows applications' own
        // settings -- and the menu bar, or the stream's popover, is the way in
        // from there.
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reveal Log in Finder",
                        action: #selector(revealLog), keyEquivalent: "")
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
        hostMenu.addItem(withTitle: "Forget Paired PCs…",
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
        pendingRestart?.cancel()
        pendingRestart = nil
        streamHost = nil
        MainActor.assumeIsolated { Updater.shared.isStreaming = false }
        agent?.disconnect()
        agent = nil
        picker?.close()
        picker = nil
        showConnectWindow()
    }

    /// Whether a Host menu item has anything to act on. Disconnect was on with
    /// nothing connected, and choosing it built a second connect window.
    static func hostMenuAllows(_ action: Selector?, connected: Bool, streaming: Bool) -> Bool {
        switch action {
        case #selector(disconnectHost): return connected || streaming
        case #selector(switchApp): return streaming
        default: return true
        }
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
        TokenStore.removeAll()
        Log.info("[agent] every stored pairing token forgotten")
    }

    // MARK: - Test support

    private func captureTestScreenshot() {
        // Prefer a stream window; fall back to whatever window is on screen so
        // the connect window can be captured too.
        guard let window = dropdownWindow
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        Self.hostMenuAllows(menuItem.action,
                            connected: agent != nil || picker != nil || session != nil,
                            streaming: !appWindows.isEmpty)
    }
}
