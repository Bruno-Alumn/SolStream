import Cocoa
import AppKit
import SolStreamLogging
import MediaSession
import AgentChannel
import DesignSystem
import VideoDecoder
import InputCapture

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
    /// `host`, or the address the connection reached when that is the one
    /// that says how far away the PC is; see `StreamSettings.route`.
    private func route(_ host: String) -> String {
        StreamSettings.route(host: host, reached: agent?.reachedIPv4)
    }

    /// Every pairing was forgotten this run: nothing is saved to reopen.
    private var forgotPairings = false
    /// The display stays on while a stream is open; see StayAwake.
    private let stayAwake = StayAwake()
    private var connectWindow: ConnectWindow?
    private var agent: AgentConnection?
    /// Files sent from the PC with Send to Mac; one per connection.
    private var fileReceiver: FileReceiver?
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
    /// When the stream was last restarted to recover it, newest last. The
    /// attempts above count from zero again at each first picture, so a PC
    /// that ends the stream a few seconds after every restart was restarted
    /// for ever; this counts them across pictures, in a window of time.
    private var mediaRestarts: [Date] = []
    /// See `mediaRestarts`.
    static let restartLimit = (count: 5, within: TimeInterval(120))
    /// The agent channel's final failure is on the stream windows, and the
    /// picture's own troubles must not paint over it. See `notice(for:)`.
    private var connectionLostShown = false

    /// An application asked for from outside the picker -- by a launcher,
    /// or as the one reopened at launch -- waiting for the picker's lists to
    /// be found in. See `open(link:)`.
    private var pendingOpen: AppLink?
    /// A pairing-token sheet is up, and over which window; see `promptForToken`.
    private var tokenPromptOpen = false
    private weak var tokenPromptParent: NSWindow?
    /// The PC being woken for `pendingOpen`; see `LaunchWake`. Kept once it
    /// has given up, so one launcher click wakes the PC once.
    private var launchWake: LaunchWake?
    /// Handed over before launching had finished, and opened once it has.
    private var queuedLink: AppLink?
    private var didFinishLaunching = false
    private var receivedLink = false
    /// Which PC the picker is showing, what it can launch, and how to have
    /// it list them again.
    private var pickerHost: String?
    private var pickerApps: [RemoteApp] = []
    private var refillPicker: (() -> Void)?
    /// What is being opened, then what the stream on screen is: kept at quit
    /// for next time, and what Add to Dock adds.
    private var openingLink: AppLink?
    private var streamLink: AppLink?
    private var lastStreamed: AppLink?
    /// Asking whether to leave one PC's stream for a launcher's (see `open`).
    private var askingToOpen = false
    /// Started with `--host`: a test, or someone at a terminal. Nothing they
    /// open is kept for next time.
    private var commandLineSession = false

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
    /// Where that grab is written; `--screenshot-path <path>` moves it, so
    /// runs side by side do not write over each other's.
    private var screenshotPath = "/tmp/solstream_internal_screenshot.png"
    /// Set by --test-dropdown so the capture targets the list, not the window
    /// behind it.
    private var dropdownWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Mac that slept stopped hearing the PC, and the stream's watchdog
        // counts awake time only: five seconds of "Reconnecting…" after every
        // wake. Restarted at once instead, when there is a stream to restart.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartStreamAfterWake() }
        }
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
        // --test-dropdown too, here rather than where it is acted on below:
        // the launch path, which reopens the last app outside a test, runs
        // before that.
        // And the app a UI test launches: it reopens no last app, saves none
        // at quit, and checks for no update -- the person's PC and settings
        // are not the test's to touch.
        testMode = arguments.contains("--test-screenshot") || arguments.contains("--test-dropdown")
            || TokenStore.environmentDirectory != nil
        if let path = value(after: "--screenshot-path") { screenshotPath = path }

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
        if let name = value(after: "--video-codec") {
            // Settings' names: automatic, h264, hevc. "hevc" offers H.264
            // second, as the setting does, so a PC without HEVC still streams.
            let all = StreamSettings.VideoCodecChoice.allCases
            if let choice = all.first(where: {
                $0.rawValue.caseInsensitiveCompare(name) == .orderedSame
                    || $0.title.caseInsensitiveCompare(name) == .orderedSame
            }) {
                config.videoCodecs = choice.codecs(
                    hardwareHEVC: VideoDecoder.decodesInHardware(.hevc))
                overrides.insert(.videoCodec)
                Log.info("[stream] video codec \(choice.title): offering "
                         + config.videoCodecs.map(\.title).joined(separator: ", "))
            } else {
                Log.error("[stream] --video-codec \(name) is not one of "
                          + all.map(\.rawValue).joined(separator: ", ") + "; using Settings")
            }
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
        // Fields a command-line flag set, which the Settings window does not
        // override; see `StreamSettings.apply`.
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

        commandLineSession = host != nil
        didFinishLaunching = true
        let queued = queuedLink
        queuedLink = nil
        // False when the system started SolStream to hand it a file: a
        // launcher's link, which is on its way if it is not here already.
        let defaultLaunch = notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"]
            as? Bool ?? true

        if let host, let launchQuery = value(after: "--launch") {
            // Starts an installed application by name, skipping the picker.
            startLaunching(host: host, agentHost: agentHost ?? host, matching: launchQuery)
        } else if let host, let appWindowQuery = value(after: "--app-window") {
            startSingleApp(host: host, agentHost: agentHost ?? host, matching: appWindowQuery)
        } else if let host {
            showPicker(host: host)
        } else if let queued {
            open(link: queued)
        } else if !defaultLaunch {
            // Started to be handed something -- a link, which may still be on
            // its way -- or by the system restoring the session at log-in,
            // which hands over nothing. A moment's wait tells the two apart,
            // and without a link it is an ordinary start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.receivedLink else { return }
                self.startWithoutLink()
            }
        } else {
            startWithoutLink()
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

    /// The last app again, or the connect window.
    private func startWithoutLink() {
        if StreamSettings.shared.reopensLastApp, !testMode, let last = AppLink.last() {
            Log.info("[app] reopening \"\(last.name)\" on \(last.host), as it was at quit")
            open(link: last)
        } else {
            showConnectWindow()
        }
    }

    /// What opens next time: what is on screen now, or, with nothing on
    /// screen, what a launcher or Reopen the Last App is still waking the PC
    /// for or connecting to -- not one already handed to the PC to start,
    /// which is `openingLink`'s and is kept after a failure too. Quitting during one wake that failed used to
    /// forget the app for good. Nothing at all, nothing does: an app walked
    /// away from -- Back, leaving the PC -- is no longer waiting.
    static func linkToRemember(streaming: AppLink?, waitingToOpen: AppLink?) -> AppLink? {
        streaming ?? waitingToOpen
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !commandLineSession, !testMode, !forgotPairings {
            AppLink.setLast(Self.linkToRemember(streaming: appWindows.isEmpty ? nil : streamLink,
                                                waitingToOpen: pendingOpen))
        }
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

    /// A launcher's link, handed over by the system: from a launcher in the
    /// Dock, Spotlight or Launchpad (`AppLauncher`), which opens it with
    /// `open -b`, or any file `open` names -- ignored unless it is one. No
    /// document types are declared, so Finder and the Dock hand SolStream
    /// nothing dropped or double-clicked.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !testMode else { return }
        // One application at a time, so the last one asked for.
        guard let link = urls.compactMap(Self.link(at:)).last else {
            Log.error("[app] asked to open \(urls.map(\.lastPathComponent)), which is not a "
                      + "SolStream link")
            return
        }
        receivedLink = true
        if didFinishLaunching {
            open(link: link)
        } else {
            queuedLink = link
        }
    }

    /// The link in a file, if it is one. Small, or it is not ours.
    static func link(at url: URL) -> AppLink? {
        guard url.isFileURL, url.pathExtension == AppLink.fileExtension,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 64 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return AppLink.decode(data)
    }

    // MARK: - Flow

    /// Open `link`'s application as though it had been picked, from whatever
    /// SolStream is showing.
    ///
    /// Through the picker, always: it is where a pairing token is asked for
    /// and where a PC that is asleep, or an app that is gone, is said -- so a
    /// launcher clicked with the PC off shows why, and the list to pick from
    /// instead. The picker finds the application in its lists when they come
    /// (`openPending`) and opens it as a click on its row would.
    private func open(link: AppLink) {
        NSApp.activate(ignoringOtherApps: true)
        if let streamLink, streamLink.likelySameApp(as: link), let window = appWindows.first?.window {
            Log.info("[app] \"\(link.name)\" is on screen already; bringing it forward")
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        Log.info("[app] asked to open \"\(link.name)\" on \(link.host)")
        if !appWindows.isEmpty, AppLink.sameHost(streamHost, link.host) {
            // One application at a time, as Switch App: the stream closes and
            // the picker comes back over the same connection, and opens this.
            pendingOpen = link
            switchApp()
            return
        }
        if let picker, let agent, AppLink.sameHost(pickerHost, link.host) {
            pendingOpen = link
            picker.show()
            // `isConnected` is a socket, not an answer: one stuck waiting
            // on a sleeping PC counts, and that is the case here.
            if !agent.isConnected || agent.lastFailureMightBeAsleep, let host = pickerHost {
                // A picker that has been failing to reach the PC since before
                // this click: a new request, so a new wake, and a new try.
                launchWake?.stop()
                launchWake = nil
                if !wakeForLauncher(host: host, agent: agent, picker: picker) {
                    agent.retryUnanswered()
                }
            }
            // Listed again only over a live connection. One still connecting
            // or reconnecting fills the list when it greets, and asking now
            // would answer with two empty lists -- shown as "0 windows open"
            // over whatever the picker was saying.
            if agent.isSessionUp { refillPicker?() }
            return
        }
        // Another PC while one is streaming: said first, not done -- a
        // misclick in Spotlight or a launcher left from another PC ended a
        // game mid-session.
        // Not over a stream that has already ended: there is nothing to end.
        if !appWindows.isEmpty, session != nil, !connectionLostShown, let current = streamHost {
            // One question at a time: a launcher clicked while this is up is
            // left, not stacked -- answered in the wrong order, the older click
            // won over the newer.
            guard !askingToOpen else {
                Log.info("[app] still asking about the last launcher; \"\(link.name)\" left")
                return
            }
            askingToOpen = true
            defer { askingToOpen = false }
            let alert = NSAlert()
            alert.messageText = "Open \(link.name) on \(link.host)?"
            alert.informativeText = "This ends the stream from \(current)"
                + (streamLink.map { " (\($0.name))" } ?? "") + "."
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                Log.info("[app] kept the stream from \(current) rather than open \"\(link.name)\"")
                return
            }
        }
        leaveHost()
        pendingOpen = link
        showPicker(host: link.host)
        // Said from the start, so a slow PC reads as one being reached for
        // this app rather than a list nobody asked for.
        picker?.showWaiting("Connecting to \(link.host) to open \(link.name)…")
    }

    /// Wake the PC a launcher asked for, when it does not answer and this Mac
    /// has learned how. True when the wake went out and the picker is
    /// waiting on it. Once per picker: a PC that did not wake in time is
    /// said as the failure it is.
    private func wakeForLauncher(host: String, agent: AgentConnection?,
                                 picker: AppPicker?) -> Bool {
        guard launchWake == nil, let agent, let picker, let link = pendingOpen,
              AppLink.sameHost(link.host, host), agent.lastFailureMightBeAsleep
        else { return false }
        let targets = WakeOnLAN.targets(for: host)
        guard !targets.isEmpty, WakeOnLAN.wake(targets) else { return false }
        Log.info("[app] \(host) is not answering; woke it to open \"\(link.name)\"")
        picker.showWaiting(LaunchWake.waking(host, app: link.name))
        launchWake = LaunchWake(retry: { [weak agent] in
            agent?.retryUnanswered()
        }, notWoken: { [weak picker] in
            Log.error("[app] \(host) did not answer within a minute of the wake; "
                      + "trying every half minute")
            picker?.showFailure(LaunchWake.notWoken(host), isConnection: true)
        })
        return true
    }

    /// The application `pendingOpen` asks for, now that the picker has lists
    /// to find it in.
    private func openPending(windows: [RemoteWindow], apps: [RemoteApp], host: String,
                             agent: AgentConnection) {
        guard let link = pendingOpen, AppLink.sameHost(link.host, host), let picker else { return }
        // No apps is a PC that has not answered yet, or a list that failed
        // to come, not one without the application: every PC has a Start
        // Menu. Taken as the answer, it said "isn't on the PC any more" for an
        // app that was, after one timed-out list; the next fill brings it.
        guard !apps.isEmpty else { return }
        pendingOpen = nil
        guard !picker.isOpening else {
            // One open at a time, as on the list itself; the picker is
            // showing the other one's progress.
            Log.info("[app] not opening \"\(link.name)\": something else is opening already")
            NSSound.beep()
            return
        }
        guard let choice = link.choice(windows: windows, apps: apps) else {
            Log.error("[app] \"\(link.name)\" is not on \(host) any more")
            picker.showFailure("\(link.name) isn't on \(host) any more. Choose another app.")
            return
        }
        picker.highlight(choice)
        open(choice: choice, host: host, agent: agent)
    }

    /// Make `link`'s launcher, with its icon from the PC, and put it in the
    /// Dock -- or, where the Dock cannot be changed, show it in Finder to be
    /// dragged there.
    /// - Parameter windowID: an open window of the app, whose icon stands in
    ///   when its shortcut gives none -- Steam's, on some PCs.
    private func addToDock(_ link: AppLink, windowID: UInt64?, agent: AgentConnection,
                           over parent: NSWindow?) {
        guard let path = link.path else {
            Self.inform("SolStream can't tell which app this window belongs to",
                        "Add the app itself to the Dock: right-click it under Installed apps.",
                        over: parent)
            return
        }
        // This SolStream, so a development build makes launchers for itself;
        // a bare binary has no bundle and stands in for the released one.
        let opener = Bundle.main.bundleIdentifier ?? "com.solstream.macclient"
        let fromWindow: (@escaping (CGImage?) -> Void) -> Void = { done in
            guard let windowID else { return done(nil) }
            agent.icon(windowID: windowID, completion: done)
        }
        func made(_ image: CGImage?) {
            DispatchQueue.main.async {
                do {
                    let launcher = try AppLauncher.make(link, icon: image, opener: opener)
                    // Said, either way it does not simply appear: a second
                    // Add to Dock did nothing visible at all, and a Dock that
                    // could not be changed opened Finder with no word why.
                    switch AppLauncher.addToDock(launcher) {
                    case .added:
                        break
                    case .alreadyThere:
                        Self.inform("\(link.name) is already in the Dock",
                                    "Its launcher has been refreshed from the PC.", over: parent)
                    case .failed:
                        // Said first, Finder after: revealed first, Finder came
                        // to the front and the reason was left behind it.
                        Self.inform("Drag \(launcher.deletingPathExtension().lastPathComponent) "
                                        + "to the Dock",
                                    "SolStream couldn't change the Dock on this Mac, so it "
                                        + "will show it in Finder for you to drag there.",
                                    over: parent) {
                            NSWorkspace.shared.activateFileViewerSelecting([launcher])
                        }
                    }
                } catch {
                    Log.error("[launcher] could not make one for \"\(link.name)\": \(error)")
                    Self.inform("Couldn't add \(link.name) to the Dock",
                                error.localizedDescription, over: parent)
                }
            }
        }
        agent.icon(path: path, size: 256) { shortcutIcon in
            guard shortcutIcon == nil else { return made(shortcutIcon) }
            fromWindow(made)
        }
    }

    private static func inform(_ message: String, _ detail: String, over parent: NSWindow?,
                               then done: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        // A sheet on a window still on screen: the picker can have been put
        // away while the icon was fetched, and a sheet on it would never show.
        if let parent, parent.isVisible {
            alert.beginSheetModal(for: parent) { _ in done?() }
        } else {
            alert.runModal()
            done?()
        }
    }

    @objc private func addStreamToDock() {
        guard let streamLink, let agent else { return }
        addToDock(streamLink, windowID: appWindows.first?.remoteWindowID, agent: agent,
                  over: appWindows.first { $0.window?.isKeyWindow == true }?.window)
    }

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
            self.forgetPicker()
            self.agent = nil
            agent.disconnect()
            // Off the PC: the session a stream left the picker in is over.
            if self.appWindows.isEmpty {
                MainActor.assumeIsolated { Updater.shared.isStreaming = false }
            }
            if self.appWindows.isEmpty && !self.testMode {
                self.showConnectWindow()
            }
        })
        picker.agent = agent
        picker.onAddToDock = { [weak self, weak agent, weak picker] choice in
            guard let self, let agent else { return }
            var windowID: UInt64?
            if case .running(let window) = choice { windowID = window.id }
            self.addToDock(AppLink.of(choice, host: host, apps: self.pickerApps),
                           windowID: windowID, agent: agent, over: picker?.window)
        }
        self.picker = picker
        pickerHost = host
        picker.show()

        // [weak agent] throughout: `agent` stores these closures, so a strong
        // capture makes it retain itself — and pins the picker and its icon
        // cache with it. Delivered on the main thread.
        agent.onState = { [weak self, weak picker, weak agent] state in
            switch state {
            case .failed(let message):
                guard let self else { return }
                // Asleep, for a launcher: woken, and tried again until it
                // answers. Each try that fails meanwhile is expected.
                if self.wakeForLauncher(host: host, agent: agent, picker: picker) {
                    return
                }
                if self.launchWake?.isRunning == true {
                    if agent?.willReconnect == true {
                        // Still no answer is the PC still waking; anything
                        // else -- refused, no such name, no route -- is said,
                        // and the tries go on.
                        if agent?.lastFailureMightBeAsleep == true { return }
                    } else {
                        // A refusal no retry can fix -- another Mac
                        // streaming -- ends the wait.
                        self.launchWake?.stop()
                    }
                }
                // `explain` already names the host and says what to do.
                picker?.showFailure(message, isConnection: true)
            case .connected:
                self?.launchWake?.stop()
                picker?.connectionIsBack()
            case .waiting(let message):
                // The PC answered: it is awake, and saying what it waits on.
                self?.launchWake?.stop()
                picker?.showWaiting(message)
            case .needsToken(let host, let rejected):
                // A sheet on the picker the person is already looking at.
                // `report` delivers on the main queue.
                MainActor.assumeIsolated {
                    self?.promptForToken(host: host, rejected: rejected, over: picker?.window,
                                         agent: agent) { message in
                        // Declined: whatever a launcher was waiting to open is
                        // no longer wanted, and must not open, or ask for the
                        // token again, at the next launch.
                        self?.pendingOpen = nil
                        self?.launchWake?.stop()
                        picker?.showFailure(message)
                    }
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
        // Which fill was asked for last. A full one waits on the slow Start
        // Menu, and a quicker windows-only one asked for meanwhile -- a window
        // opened on the PC -- used to be overwritten when the full one landed,
        // putting back the window list from before it.
        var latestFill = 0
        /// The windows the newest fill showed.
        var shownWindows: [RemoteWindow]?
        let fill: (_ includeApps: Bool) -> Void = { [weak self, weak agent, weak picker] includeApps in
            guard let agent else { return }
            latestFill += 1
            let mine = latestFill
            // An empty list is asked for again: it is what a failed request
            // gives, and reused, a launcher waiting on its app waited until
            // the next reconnect.
            let reuse = includeApps || cachedApps?.isEmpty == true ? nil : cachedApps
            agent.windows { windows in
                let present: ([RemoteApp]) -> Void = { apps in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // Reused, the newest list there is now: a full fill
                        // may have landed since this one was asked for.
                        let apps = reuse == nil ? apps : (cachedApps ?? apps)
                        // An empty answer is also what a failed request gives,
                        // and kept, it would list no apps until the next full
                        // fill; a good list is not replaced by one.
                        let fetched = reuse == nil
                        if !fetched || !apps.isEmpty || cachedApps == nil { cachedApps = apps }
                        guard mine == latestFill else {
                            // Its windows are older than the list on screen,
                            // but apps it fetched itself are newer: the Start
                            // Menu a reconnect re-read, which a quicker
                            // windows-only fill went ahead of with the old one.
                            if fetched, !apps.isEmpty, let shownWindows {
                                picker?.present(windows: shownWindows, apps: apps)
                                self.pickerApps = apps
                                self.openPending(windows: shownWindows, apps: apps,
                                                 host: host, agent: agent)
                            }
                            return
                        }
                        shownWindows = windows
                        picker?.present(windows: windows, apps: apps)
                        self.pickerApps = apps
                        self.openPending(windows: windows, apps: apps, host: host, agent: agent)
                    }
                }
                if let reuse { present(reuse) } else { agent.apps(completion: present) }
            }
        }
        // Each greeting is a connection to a PC that is awake: the time to
        // learn how to wake it later. See `WakeOnLAN`.
        agent.onDisplays = { [weak self, weak agent, weak picker] _ in
            // The host sends its displays only once it is satisfied: a token
            // sheet still up over this picker is answering a question nobody
            // is asking any more -- a stored token went through on a
            // reconnect -- and its Cancel would put "needs its pairing token"
            // over a connection that works.
            if let window = picker?.window {
                MainActor.assumeIsolated {
                    if TokenPrompt.withdraw(over: window), self?.tokenPromptParent === window {
                        self?.tokenPromptOpen = false
                        self?.tokenPromptParent = nil
                    }
                }
            }
            fill(true)
            if let agent { WakeOnLAN.learn(from: agent, host: host) }
        }
        agent.onWindowsChanged = { fill(false) }
        agent.onOpenLink = { [weak self] in self?.openLinkFromPC($0) }
        if existing == nil {
            // A new connection: the host says again what blocks it, if anything.
            inputBlockedNow = nil
            inputBlockedShown = false
            inputBlockedShort = nil
            appWindows.forEach { $0.setInputBlocked(nil) }
        }
        agent.onInputBlocked = { [weak self] reason, app in self?.inputBlocked(reason, app: app) }
        agent.onPushesReset = { [weak self] in self?.inputBlockedReset() }
        agent.onFileOffer = { [weak self, weak agent] id, name, size in
            guard let self, let agent else { return }
            self.receiveFile(FileReceiver.Offer(id: id, name: name, size: size), from: agent)
        }
        refillPicker = { fill(false) }
        if existing == nil {
            agent.connect()
        } else if agent.isSessionUp {
            // A reused socket produces no second `hello`, so the unprompted
            // `displays` push that normally drives the first fill never comes.
            // Only over one that has greeted: a socket still connecting greets
            // in its own time, and that greeting fills the list.
            fill(true)
        } else if !agent.willReconnect {
            // Refused for good (busy, impersonation) or already closed: nothing
            // is coming, so do not leave the spinner up.
            picker.showFailure(Self.openFailedOffline(host: host, reconnecting: false,
                                                      lastFailure: agent.lastFailureMessage))
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
        // One sheet at a time. A host drops a connection left waiting for a
        // token after two minutes, and its reconnect asks again: a second sheet
        // queued behind the first, and closing it after the first had paired
        // put "needs its pairing token" over a connection that was working.
        // But only while that sheet is still to be seen: its window closed or
        // hidden under it -- Disconnect, a launcher for another PC, Switch
        // App -- ends nothing, and a sheet that was never finished would
        // otherwise stop every later one, for any PC, until a restart.
        if tokenPromptOpen, let shown = tokenPromptParent, shown.isVisible,
           shown.attachedSheet != nil {
            return
        }
        tokenPromptOpen = true
        tokenPromptParent = parent
        TokenPrompt.present(host: host, rejected: rejected, over: parent) { [weak self] token in
            self?.tokenPromptOpen = false
            self?.tokenPromptParent = nil
            guard let token else {
                onRefused("\(host) needs its pairing token. It's on SolStream's window on "
                          + "the PC, under \"Pairing token\". Connect again to enter it.")
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
        openingLink = AppLink.of(choice, host: host, apps: pickerApps)
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

    /// Whether an open under way on `agent` is still wanted.
    ///
    /// An open is a chain of round trips to the PC, each answered later, and
    /// the picker it reports to can have been replaced meanwhile -- by a
    /// launcher clicked for another PC, or Disconnect. Every step checks that
    /// its connection is still the one in use before it touches the picker
    /// or goes on, so the old PC's progress, failure or stream never lands
    /// on the new one's picker.
    private func isCurrent(_ agent: AgentConnection) -> Bool {
        guard self.agent === agent else {
            Log.info("[app] dropping an open on a connection that has since been left")
            return false
        }
        return true
    }

    private func launch(app: RemoteApp, host: String, agent: AgentConnection,
                        knownPIDs: Set<Int>) {
        guard isCurrent(agent) else { return }
        picker?.showBusy("Starting \(app.name) on \(host)…")
        agent.launch(path: app.path) { [weak self] id, trouble in
            DispatchQueue.main.async {
                guard let self else { return }
                if let trouble {
                    // Nothing to look for: no window can have come of it yet.
                    self.failOpen(Self.launchTroubleText(trouble, app: app.name, host: host),
                                  for: agent)
                    return
                }
                guard let id else {
                    // Still not necessarily a failure: an application can open its
                    // window under a title that does not contain the name we
                    // matched on before launching, so try once more now.
                    agent.windows { windows in
                        DispatchQueue.main.async {
                            guard let existing = LaunchMatch.afterLaunch(
                                app.name, in: windows, knownPIDs: knownPIDs) else {
                                self.failOpen("\(app.name) didn't open a window. If it opened on the PC's own "
                                              + "screen, pick its Open window row; otherwise try again.",
                                              for: agent)
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
                            self.failOpen("\(app.name) closed its first window, a splash or "
                                          + "update screen. Once it's ready, pick it from the open "
                                          + "windows.", for: agent)
                            return
                        }
                        self.attach(target, host: host, agent: agent)
                    }
                }
            }
        }
    }

    /// Says on the picker, still up, why there is no stream to look at.
    private func failOpen(_ message: String, for agent: AgentConnection) {
        guard isCurrent(agent) else { return }
        picker?.clearBusy()
        // The list was held while the open ran; what opened or closed on the
        // PC meanwhile is shown now, not at its next change.
        if agent.isConnected {
            refillPicker?()
            picker?.showFailure(message)
        } else {
            // With no connection every request fails at once, and the open's
            // own words -- restart SolStream on the PC, the app opened no
            // window -- blamed the PC or the app for a dropped connection.
            picker?.showFailure(Self.openFailedOffline(host: agent.hostName,
                                                       reconnecting: agent.willReconnect,
                                                       lastFailure: agent.lastFailureMessage),
                                isConnection: true)
        }
    }

    /// What a launch held up by Windows' administrator prompt says.
    static func launchTroubleText(_ trouble: AgentConnection.LaunchTrouble, app: String,
                                  host: String) -> String {
        switch trouble {
        case .needsApproval:
            // Not "try again": once approved the app is already running, and a
            // second launch of one that needs administrator rights asks again.
            return "\(app) is waiting for an answer on \(host)'s own screen — usually "
                + "Windows asking for administrator permission, which can't be given from "
                + "here. Answer it at the PC, then pick \(app)'s Open window row. To avoid "
                + "this, turn off \"Run as administrator\" for the app on the PC."
        case .declined:
            return "\(app) needs administrator permission and \(host) declined. Open it again "
                + "and choose Yes on the PC."
        case .missing:
            // Not "uninstalled": a game on a drive that isn't plugged in, or
            // a network share that is down, looks the same from here.
            return "\(app) can't be found on \(host). It may have been uninstalled or moved, "
                + "or be on a drive that isn't connected. Choose another app, or check the PC."
        case .refused:
            return "Windows wouldn't start \(app) on \(host). Open it on the PC once to see "
                + "why, then try again."
        }
    }

    /// What to say when the PC agreed to stream but its picture would not
    /// start. Its reason is written for the log -- "the hardware HEVC encoder
    /// would not open at 4096x2560" -- so it is read for what to do, not shown.
    static func startTroubleText(_ reason: String?, host: String) -> String {
        let why = (reason ?? "").lowercased()
        if why.contains("graphics.capture is not available") {
            return "\(host)'s Windows can't capture apps. Update Windows on the PC, then open "
                + "the app again."
        }
        if why.contains("window could not be captured") {
            return "\(host) couldn't capture the app's window. Check it's still open and the PC "
                + "is unlocked, then open the app again."
        }
        if why.contains("could not be captured") || why.contains("nothing was ever captured") {
            return "\(host) couldn't capture the picture. Check the PC is unlocked with its "
                + "screen on, then open the app again."
        }
        if why.contains("encoder") {
            // HEVC that will not open falls back to H.264 on the PC before
            // it answers, so H.264 is worth saying only while HEVC failed.
            return why.contains("hevc")
                ? "The PC's graphics card couldn't encode HEVC. Choose H.264 in Settings, then "
                    + "open the app again."
                : "The PC's graphics card couldn't start encoding. Close anything recording "
                    + "on the PC, then open the app again."
        }
        // Not a bare "port": "the media keys would not import" has one.
        if why.contains("udp port") || why.contains("is taken") {
            return "Another program on \(host) is using SolStream's port. Restart the PC, then "
                + "connect again."
        }
        return "\(host) couldn't start the picture. Restart SolStream on the PC, then open the "
            + "app again."
    }

    /// What a failed open says when the connection is what failed.
    /// - Parameter lastFailure: what ended a connection that will not come
    ///   back, said again: shown a moment before, on a screen that has gone,
    ///   it is the one thing that says whether connecting again can help --
    ///   it cannot while another Mac is streaming.
    static func openFailedOffline(host: String, reconnecting: Bool,
                                  lastFailure: String? = nil) -> String {
        if reconnecting {
            return "The connection to \(host) dropped. SolStream is reconnecting; "
                + "try again once the list refreshes."
        }
        if let lastFailure, !lastFailure.isEmpty { return lastFailure }
        return "The connection to \(host) ended. Choose Back, then connect again."
    }

    /// Stream one window, keeping the picker up until there is one to look at.
    ///
    /// The picker is closed in `presentApps`, as a window is about to appear, so
    /// every failure on the way — no display, a refused or dead media session —
    /// puts its reason on the picker the person is still looking at.
    private func attach(_ window: RemoteWindow, host: String, agent: AgentConnection) {
        guard isCurrent(agent) else { return }
        picker?.showBusy("Opening \(window.title) on \(host)…")
        start(host: host, agent: agent, targets: [window])
    }

    /// NVENC's H.264 maximum, and now a number both ends have to agree on.
    ///
    /// Above it the handshake succeeds and no frame ever arrives, with the
    /// reason only in the host's own log — and a 16" MacBook Pro at More Space
    /// asks for 4112x2658, so this is reachable with ordinary hardware rather
    /// than a pathological setup. Every request the Mac sends is clamped to it,
    /// and the host clamps to the same figure -- per axis, which a request
    /// already inside it leaves alone -- so the two arrive at the same canvas
    /// rather than at two that merely resemble each other.
    private static let encoderLimit = 4096

    ///
    /// Both sides by the same factor, so a canvas keeps the display's shape:
    /// clamped each on its own, a 5120x1440 ultrawide became 4096x1440, and
    /// every crop of it came out narrower than its window -- drawn squeezed
    /// between bars. Even, as the encoder wants it.
    static func clampedToEncoder(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > encoderLimit || height > encoderLimit, width > 0, height > 0 else {
            return (width, height)
        }
        let scale = min(Double(encoderLimit) / Double(width), Double(encoderLimit) / Double(height))
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale).rounded(.down)) & ~1) }
        return (even(width), even(height))
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
                            displays: Self.displaysToUse(answer: displays, held: agent.displays))
            }
        }
    }

    /// The capture display after a canvas change: as the PC lists it now, or,
    /// with no listing to go on, at the size the canvas reply said it set --
    /// never at its old size, which every crop would then be worked out from.
    static func resizedCapture(_ capture: RemoteDisplay, listed: [RemoteDisplay]?,
                               achieved: CGSize?) -> RemoteDisplay {
        if let listed = listed?.first(where: { $0.name == capture.name }) { return listed }
        guard let achieved else { return capture }
        return capture.resized(width: Int(achieved.width), height: Int(achieved.height))
    }

    /// The displays to pick from: the PC's answer when it gave one, even an
    /// empty one, and the list already held only when there was no answer.
    static func displaysToUse(answer: [RemoteDisplay]?, held: [RemoteDisplay]) -> [RemoteDisplay] {
        answer ?? held
    }

    private func start(host: String, agent: AgentConnection, targets: [RemoteWindow],
                       displays: [RemoteDisplay]) {
        guard isCurrent(agent) else { return }
        guard let capture = Self.selectDisplay(from: displays, preferring: displayQuery) else {
            Log.error("[app] host reported no displays")
            failOpen("\(host) didn't offer a screen to capture. Check someone is signed in to "
                     + "Windows on the PC, then try again.", for: agent)
            return
        }
        Self.logCapture(capture)
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
                    let updated = Self.resizedCapture(capture, listed: displays, achieved: achieved)
                    Log.info("[app] host now rendering at \(updated.width)x\(updated.height) "
                             + "@ \(updated.x),\(updated.y)"
                             + (displays?.contains { $0.name == capture.name } == true
                                ? "" : " (not listed again; the size it said it set)"))
                    self.openApps(host: host, agent: agent, targets: targets,
                                  display: updated, config: self.baseConfig)
                }
            }
        }
    }

    private static func logCapture(_ capture: RemoteDisplay) {
        Log.info("[app] capture display \(capture.name) "
                 + "\(capture.width)x\(capture.height) @ \(capture.x),\(capture.y) "
                 + "[\(capture.adapter)]\(capture.isVirtual ? " virtual" : "")")
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
            Self.logCapture(capture)

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
        // Not `display.name`, which is Windows' device name, \\.\DISPLAY1.
        alert.messageText = "Streaming this would send everything on \(host)'s monitor"
        alert.informativeText = """
            \(host) has no virtual display for SolStream to put \(names) on, so it will \
            capture that whole monitor and show you a piece of the picture. Everything \
            else on the monitor is captured with it — every other window, and anything \
            that opens there while you are connected — and all of it crosses the network.

            SolStream's own virtual display on \(host) is what lets it send just the \
            app. Set it up from SolStream on the PC.
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
        guard isCurrent(agent) else { return }
        // The host encodes the whole display and each window shows a crop, so
        // on a real monitor everything on it is sent; asked before any of it is.
        guard confirmWholeDisplayCapture(host: host, display: display, targets: targets) else {
            failOpen("Nothing was streamed. Set up SolStream's virtual display on \(host) "
                     + "to send one app on its own.",
                     for: agent)
            return
        }

        // What the Settings window chose, under whatever the command line set.
        var config = StreamSettings.shared.apply(to: baseConfig, host: route(host),
                                                 overrides: QualityPill.commandLineOverrides)
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
                audioSource: config.audioSource,
                videoCodecs: config.videoCodecs)
            // The canvas, said out loud: it is the size every crop is expressed
            // in, so the host must encode exactly this and not the raw source.
            request.width = config.width
            request.height = config.height
            // The negotiation is the start of the stream: an install that
            // finishes during it must not quit the app halfway through, with
            // no session yet for quitting to close. Set back on each way out
            // that ends without a window; `presentApps` keeps it set.
            // Put back as it was on a way out with no window: still set when
            // this open came from the picker a stream was switched away from,
            // which is the same session (see `endStream`).
            let wasStreaming = Updater.shared.isStreaming
            Updater.shared.isStreaming = true
            guard let media = await agent.openMediaSession(request) else {
                // Only for the connection still in use: one left meanwhile
                // has had the flag set by whatever left it.
                if self.isCurrent(agent) { Updater.shared.isStreaming = wasStreaming }
                Log.error("[app] \(host) refused the media session")
                self.failOpen("\(host) didn't start streaming. Try again; if it keeps happening, "
                              + "restart SolStream on the PC.", for: agent)
                return
            }
            guard media.streaming else {
                if self.isCurrent(agent) { Updater.shared.isStreaming = wasStreaming }
                Log.error("[app] \(host) agreed keys but did not start: "
                          + (media.message ?? "no reason given"))
                self.failOpen(Self.startTroubleText(media.message, host: host), for: agent)
                return
            }
            // Agreed with a PC that has since been left: its connection is
            // gone, and the PC ends the stream with it.
            guard self.isCurrent(agent) else {
                // Left while the PC answered: whatever left it set the flag,
                // and a newer open may have set its own.
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
        // With it, a launcher's request still waiting: this open beat it.
        forgetPicker()
        streamLink = openingLink
        // The last app streamed this run, for the Dock menu's Reopen: what
        // is remembered at quit is the previous run's.
        if let opening = openingLink { lastStreamed = opening }
        // A stream after Forget Paired PCs is a pairing made again: what it
        // streams is worth reopening.
        forgotPairings = false
        openingLink = nil
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
        bridge.onPictureTooLarge = { [weak self] in
            self?.appWindows.first { $0.window?.isKeyWindow == true }?
                .tell(ClipboardBridge.pictureTooLargeNote)
        }
        bridge.onTextCut = { [weak self] note in
            guard let self else { return }
            (self.appWindows.first { $0.window?.isKeyWindow == true } ?? self.appWindows.first)?
                .tell(note)
        }
        if StreamSettings.shared.syncsClipboard {
            bridge.start(resuming: false)
        } else {
            bridge.forgetHandledCopies()
            Log.info("[clipboard] sync is off in Settings")
        }

        let session = StreamSession(host: host, config: config, session: media)
        self.session = session
        stayAwake.hold()
        streamConfig = config
        streamDisplay = display
        streamHost = host
        mediaRecoveryAttempts = 0
        mediaRestarts = []
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
                AppWindow.resetCascade()
                // End the media session by asking, not by dropping the socket.
                // The UDP BYE alone only sets `running = false` on the host: the
                // capture, encoder, sender and receive threads, the socket and
                // the keys all survive until something starts a new session, and
                // any key or mouse button still held is never released.
                // Still the session, as far as an update is concerned: the
                // picker comes straight back over the same connection, and an
                // install that quit the app now would take it away mid-Switch
                // App or mid-Retry. Leaving the picker ends it.
                self.endStream(keepsSession: !self.testMode) { agent.closeMediaSession() }
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
            appWindow.onHostClipboardSet = { [weak self] sequence in
                self?.clipboard?.adopt(remoteSequence: sequence)
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
            appWindow.setInputBlocked(inputBlockedShort)
            if let note = inputBlockedNow {
                appWindow.tell(note)
                inputBlockedShown = true
            }

            // Size the host window to this one and pin it there. The window owns
            // its own geometry so the initial placement and a later drag go
            // through identical code, and the lock is taken only once the window
            // is where it belongs — it enforces whatever geometry it finds.
            appWindow.placeAndLock()
            agent.focus(windowID: target.id)
            Log.info("[app] \"\(target.title)\" -> tile \(tile)")
        }

        // Once per PC while SolStream runs, on the window opened last, which
        // is the one in front: a reminder on every window would be nagging,
        // and the log keeps it either way. Not over the input-blocked note,
        // which matters more now; the next open says it instead.
        if inputBlockedNow == nil, let note = session.outdatedHostNote,
           let front = appWindows.last,
           toldOutdatedHosts.insert(AppLink.hostKey(host)).inserted {
            front.tell(note, for: 12)
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

        agent.onOpenLink = { [weak self] in self?.openLinkFromPC($0) }
        agent.onInputBlocked = { [weak self] reason, app in self?.inputBlocked(reason, app: app) }
        agent.onFileOffer = { [weak self, weak agent] id, name, size in
            guard let self, let agent else { return }
            self.receiveFile(FileReceiver.Offer(id: id, name: name, size: size), from: agent)
        }
        agent.onWindowTitle = { [weak self] id, title in
            self?.appWindows.first { $0.remoteWindowID == id }?.hostTitleChanged(title)
        }
        agent.onAttention = { [weak self] id in
            self?.appWindows.first { $0.remoteWindowID == id }?.hostAskedForAttention()
        }
        agent.onFullScreen = { [weak self] id, on in
            self?.appWindows.first { $0.remoteWindowID == id }?.hostFullScreenChanged(on)
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
                        self.showEnded("Can't reconnect", detail: reason)
                    }
                }
            case .failed(let message) where agent?.willReconnect == false:
                self.connectionLostShown = true
                self.showEnded("Lost the connection", detail: message)
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
            // Fired only once the greeting's display list is in, so the host is
            // satisfied: a token sheet still up over a stream window asks a
            // question nobody is asking any more, and its Cancel would end a
            // stream that just came back. As the picker does; see `showPicker`.
            MainActor.assumeIsolated {
                for window in self.appWindows.compactMap(\.window) {
                    if TokenPrompt.withdraw(over: window), self.tokenPromptParent === window {
                        self.tokenPromptOpen = false
                        self.tokenPromptParent = nil
                    }
                }
            }
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
           Self.applying(StreamSettings.shared, to: request, config: config, host: route(host),
                         overrides: QualityPill.commandLineOverrides) != nil {
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
                // Not over a connection that has ended for good: its pictures
                // are the last of a stream that is about to stop, and Try
                // Again is still the only way back.
                guard !self.connectionLostShown else { return }
                self.appWindows.forEach { $0.hideStatus() }
                // Pictures again after an error said the stream had ended.
                self.stayAwake.hold()
            case .stalled(let seconds):
                self.show(self.notice(for: .stalled(seconds: seconds), agent: agent, host: host))
            case .lost:
                if self.mediaRecoveryAttempts >= 3 {
                    // Three restarts in a row and not one picture from any of
                    // them. A restart that shows one starts the count again
                    // (`.streaming`), so this is a stream that cannot be got
                    // back by restarting it, and Try Again is the honest offer
                    // rather than a fourth "Reconnecting…" and a fifth.
                    self.showEnded("Lost the stream",
                                   detail: "No picture from \(host). Check the PC isn't locked "
                                       + "or showing a Windows prompt, and that nothing on the "
                                       + "network blocks SolStream, then choose Try Again.")
                    return
                }
                // With the agent channel down too, `onReconnected` recovers.
                let notice = self.notice(for: .lost, agent: agent, host: host)
                if case .restart = notice, let agent {
                    self.recoverMedia(host: host, agent: agent, countsTowardLimit: true)
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
                guard !self.connectionLostShown else { return }
                self.appWindows.forEach { $0.hideStatus() }
            case .failed(let message):
                let notice = self.notice(for: .failed(message), agent: agent, host: host)
                if case .restart = notice, let agent {
                    Log.info("[app] stream failed (\(message)); restarting it")
                    // On the next turn: `start()` reports a socket that will not
                    // open synchronously, from inside itself, and tearing the
                    // session down from in there would run `stop()` mid-`start()`.
                    DispatchQueue.main.async { [weak self] in
                        self?.recoverMedia(host: host, agent: agent, countsTowardLimit: true)
                    }
                } else {
                    // Not "Stream failed" while the channel is coming back by
                    // itself: its Try Again closes the windows that
                    // `onReconnected` is about to restore.
                    self.show(notice)
                }
            case .waitingForVideo:
                guard !self.connectionLostShown else { return }
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
    /// Every window says the stream has ended, and the display may sleep
    /// again: a window left saying so -- the PC shut down while nobody was
    /// at the Mac -- must not keep the screen on until someone comes back.
    private func showEnded(_ title: String, detail: String) {
        appWindows.forEach { $0.setError(title, detail: detail) }
        stayAwake.release()
    }

    private func show(_ notice: StreamNotice) {
        switch notice {
        case .status(let title, let detail):
            appWindows.forEach { $0.setStatus(title, detail: detail) }
        case .error(let title, let detail):
            showEnded(title, detail: detail)
        case .restart, .keep:
            break
        }
    }

    /// After the Mac wakes: the stream again, from a fresh media session,
    /// when there is one on screen and the channel is up -- otherwise the
    /// channel's own reconnect brings it back.
    ///
    /// Two seconds on, not at once: the network is often not back the moment
    /// the Mac is, and a restart then looked a name up on the main thread and
    /// failed for want of a route. And only for the session that was showing
    /// when the Mac woke, if no picture has come since: a stream already back
    /// by itself, or one a recovery started meanwhile, is left alone.
    private func restartStreamAfterWake() {
        guard let woken = session else { return }
        let framesAtWake = woken.mediaCounters.frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak woken] in
            guard let self, let woken, self.session === woken,
                  woken.mediaCounters.frames == framesAtWake,
                  !self.appWindows.isEmpty, !self.connectionLostShown,
                  let host = self.streamHost, let agent = self.agent, agent.isConnected
            else { return }
            Log.info("[app] no picture since the Mac woke; restarting the stream from \(host)")
            self.recoverMedia(host: host, agent: agent)
        }
    }

    /// Whether a recovering restart now would be one too many, given those in
    /// `restarts` -- which is pruned to the window and, when not, has now added.
    static func restartsExhausted(_ restarts: inout [Date], now: Date) -> Bool {
        restarts.removeAll { now.timeIntervalSince($0) > restartLimit.within }
        guard restarts.count < restartLimit.count else { return true }
        restarts.append(now)
        return false
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
    /// - Parameter countsTowardLimit: a stream that was running and ended --
    ///   lost, or failed -- rather than a retry, a reconnect or a wake: only
    ///   those are what `restartLimit` counts, so a few Wi-Fi blips or lid
    ///   closes never add up to giving up.
    private func recoverMedia(host: String, agent: AgentConnection,
                              status: (title: String, detail: String)? = nil,
                              countsTowardLimit: Bool = false) {
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
        // Where it is as well as how big: the same display back in another
        // place on the PC's desktop puts the app off the captured area, and
        // every tile is in desktop coordinates.
        if !displays.isEmpty, !displays.contains(where: {
            $0.name == display.name && $0.width == display.width && $0.height == display.height
                && $0.x == display.x && $0.y == display.y
        }) {
            Log.info("[app] \(display.name) changed while the stream was down; "
                     + "returning to the picker")
            showEnded("Lost the stream",
                      detail: "\(host)'s display changed. Try Again to pick the app again.")
            return
        }

        // A restart to recover, not one to apply settings: counted, and given
        // up on when the PC keeps ending the stream however often it starts.
        if countsTowardLimit {
            let now = Date()
            if Self.restartsExhausted(&mediaRestarts, now: now) {
                Log.error("[app] \(Self.restartLimit.count) restarts in "
                          + "\(Int(Self.restartLimit.within)) s; not restarting again")
                showEnded("The stream keeps stopping",
                          detail: "The stream from \(host) stopped \(Self.restartLimit.count) times in "
                              + "two minutes. Check the PC isn't locked or short of memory, and "
                              + "that no other Mac is connecting to it, then choose Try Again.")
                return
            }
        }

        recoveringMedia = true
        mediaRecoveryAttempts += 1
        let attempt = mediaRecoveryAttempts
        Log.info("[app] restarting the stream from \(host) (attempt \(attempt))")
        // Handlers off first: stopping the old session reports `.failed`
        // asynchronously, which would land in here again. And stopped before
        // the card goes up: a frame of the old stream handed over after it
        // took "Applying settings…" down, over a picture that had stopped.
        if let old = session {
            old.onPhase = nil
            old.onLiveness = nil
            old.stop()
        }
        session = nil
        let status = status ?? ("Reconnecting…", "Restarting the stream from \(host)")
        appWindows.forEach {
            $0.setStatus(status.title, detail: status.detail)
        }

        Task { @MainActor [weak self, weak agent] in
            guard let self, let agent else { return }
            let media = agent.isConnected ? await agent.openMediaSession(request) : nil
            self.recoveringMedia = false
            // The windows may all have closed during the wait -- Back to Apps
            // on a card that stayed -- and then the stream the PC has just
            // started is nobody's: closed, not left encoding for no one.
            guard !self.appWindows.isEmpty, self.session == nil else {
                if media?.streaming == true, self.appWindows.isEmpty {
                    agent.closeMediaSession()
                }
                return
            }
            // Nor is a stream started under "Lost the connection": its first
            // frame or "Waiting for video" would replace the card, and when
            // the PC ends it with the channel the window would be left with
            // neither a picture nor a Try Again.
            guard !self.connectionLostShown else { return }
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
        // Asked again even with an update in hand: a newer release may have
        // come out since, and the updater keeps a download it already has.
        MainActor.assumeIsolated { Updater.shared.checkNow() }
    }

    /// The app menu's update item, named for what choosing it will show. A
    /// launcher or "Reopen the last app" goes straight to the stream, past the
    /// connect window that says an update is waiting, so the menu says it too,
    /// in the words Settings, which choosing it opens, goes on to use.
    static func updateMenuTitle(for state: Updater.State) -> String {
        switch state {
        case .ready(let version): return "Install Update \(version)…"
        case .available(let version), .downloading(let version, _),
             .manualInstall(let version, _):
            return "Update \(version) Available…"
        case .waitingForStream(let version): return "Update \(version) Installs After the Stream…"
        case .installed(let version): return "Update \(version) Installed…"
        default: return "Check for Updates…"
        }
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
            clipboard.forgetHandledCopies()
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
        // Settings chosen anew: a stream that had kept stopping starts its
        // count again.
        mediaRestarts = []
        guard !appWindows.isEmpty, let host = streamHost, let agent,
              let request = mediaRequest, let config = streamConfig else { return }
        // A recovery in flight is opening a session with the old request, and
        // a second open would race it. Once it settles, this comes round again.
        guard !recoveringMedia else {
            scheduleMediaRestart()
            return
        }
        guard let fresh = Self.applying(StreamSettings.shared, to: request, config: config,
                                        host: route(host),
                                        overrides: QualityPill.commandLineOverrides) else {
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

    /// `request` and `config` with the settings' frame rate, bitrate, video
    /// codec, sound, sound quality and sound source, or nil when the stream already has them
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
                || fresh.videoCodecs != config.videoCodecs
                || soundChanged else { return nil }
        var updated = request
        updated.fps = fresh.frameRate
        updated.bitrate = fresh.bitrateKbps * 1000
        updated.videoCodecs = fresh.videoCodecs
        updated.audio = fresh.audio
        updated.audioEncoding = fresh.audioEncoding
        updated.audioSource = fresh.audioSource
        return (updated, fresh)
    }

    static func describe(_ config: StreamConfig) -> String {
        "\(config.frameRate) fps, \(config.bitrateKbps) kbit/s, "
            + config.videoCodecs.map(\.title).joined(separator: " or ") + ", "
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
        // Every Mac application's three, with their usual keys. ⌘H is not
        // reserved: from a streamed window it reaches the PC as Ctrl+H, as
        // every other ⌘ letter does, and from the picker or Settings it hides.
        appMenu.addItem(withTitle: "Hide SolStream",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
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
        hostMenu.addItem(withTitle: "Add App to Dock", action: #selector(addStreamToDock),
                         keyEquivalent: "")
        hostMenu.addItem(.separator())
        // The stream's two quick switches, also in the quality pill's popover.
        // Here as well, on ⌃⌘ keys a stream never takes: the pill hides with
        // the title bar in full screen, and with the mouse held for a game it
        // is out of reach until ⌃⌥ lets go.
        Self.reserve(hostMenu.addItem(withTitle: "Mute Sound",
                                      action: #selector(toggleMuteFromMenu), keyEquivalent: "k"))
        Self.reserve(hostMenu.addItem(withTitle: "Gaming Mouse",
                                      action: #selector(togglePointerModeFromMenu),
                                      keyEquivalent: "g"))
        hostMenu.addItem(.separator())
        // Closing the window only stops streaming it; these end it on the PC.
        // Force Quit is the ⌥ alternate, as in the Dock.
        for item in Self.quitItems(for: nil) {
            hostMenu.addItem(item)
        }
        hostMenu.addItem(.separator())
        hostMenu.addItem(withTitle: "Forget Paired PCs…",
                         action: #selector(forgetHosts), keyEquivalent: "")
        hostMenuItem.submenu = hostMenu
        mainMenu.addItem(hostMenuItem)

        // One NSWindow per streamed application, so the standard Window menu is
        // already the list of what is open — AppKit maintains it for us.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        // Minimize on ⌃⌘M, as Close is on ⌃⌘W: ⌘M alone is the PC's Ctrl+M.
        Self.reserve(windowMenu.addItem(withTitle: "Minimize",
                                        action: #selector(NSWindow.performMiniaturize(_:)),
                                        keyEquivalent: "m"))
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        // ⌃⌘F is the system's own full-screen shortcut, so this is where it
        // should have been all along.
        Self.reserve(windowMenu.addItem(withTitle: "Enter Full Screen",
                                        action: #selector(NSWindow.toggleFullScreen(_:)),
                                        keyEquivalent: "f"))
        Self.reserve(windowMenu.addItem(withTitle: "Close",
                                        action: #selector(NSWindow.performClose(_:)),
                                        keyEquivalent: "w"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        let helpMenu = HelpMenu.make(target: self, action: #selector(openHelpLink(_:)))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        // Named to AppKit, which puts the menu bar's search field at its head.
        NSApp.helpMenu = helpMenu

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
        leaveHost()
        showConnectWindow()
    }

    /// Off this PC, from whatever was showing, with nothing put up instead.
    private func leaveHost() {
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

        endStream()
        agent?.disconnect()
        agent = nil
        picker?.close()
        forgetPicker()
        if let connectWindow, connectWindow.isOpen { connectWindow.close() }
    }

    /// Also what the picker was asked to open: leaving it, by Back or for
    /// another PC, is not wanting that any more.
    private func forgetPicker() {
        pendingOpen = nil
        launchWake?.stop()
        launchWake = nil
        picker = nil
        pickerHost = nil
        pickerApps = []
        refillPicker = nil
    }

    /// Stop the stream and its clipboard sync, and forget what it was opened
    /// with. `closing` runs just before an update the person asked for during
    /// the stream is let go -- unless `keepsSession` holds it until the picker
    /// that follows is left -- which installs it and may relaunch the app.
    /// - Parameter keepsSession: the picker follows on the same connection, so
    ///   an update waiting for the stream to close goes on waiting until it is
    ///   left (`showPicker`'s cancel, `leaveHost`).
    private func endStream(keepsSession: Bool = false, closing: () -> Void = {}) {
        session?.stop()
        session = nil
        mediaRequest = nil
        streamLink = nil
        streamConfig = nil
        streamDisplay = nil
        streamHost = nil
        pendingRestart?.cancel()
        pendingRestart = nil
        clipboard?.stop()
        clipboard = nil
        stayAwake.release()
        closing()
        if !keepsSession {
            MainActor.assumeIsolated { Updater.shared.isStreaming = false }
        }
    }

    /// Mute Sound's and Gaming Mouse's tick, from the settings they switch;
    /// nil for any other item.
    static func streamSwitchState(_ action: Selector?, muted: Bool,
                                  mode: InputCapture.PointerMode) -> NSControl.StateValue? {
        switch action {
        case #selector(toggleMuteFromMenu): return muted ? .on : .off
        case #selector(togglePointerModeFromMenu): return mode == .gaming ? .on : .off
        default: return nil
        }
    }

    /// What a switch from the menu did, said to VoiceOver: from the keyboard
    /// nothing else on screen may say it.
    static func streamSwitchAnnouncement(muted: Bool) -> String {
        muted ? "Sound muted" : "Sound on"
    }

    static func streamSwitchAnnouncement(mode: InputCapture.PointerMode) -> String {
        mode == .gaming ? "Gaming mouse" : "Desktop mouse"
    }

    @objc func toggleMuteFromMenu() {
        let settings = StreamSettings.shared
        settings.toggleMute()
        MainActor.assumeIsolated { DS.announce(Self.streamSwitchAnnouncement(muted: settings.isMuted)) }
    }

    @objc func togglePointerModeFromMenu() {
        let settings = StreamSettings.shared
        settings.pointerMode = settings.pointerMode == .gaming ? .desktop : .gaming
        MainActor.assumeIsolated {
            DS.announce(Self.streamSwitchAnnouncement(mode: settings.pointerMode))
        }
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


    @objc func openHelpLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
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

    // MARK: - Quitting an app on the PC

    /// Quit and its ⌥ alternate, Force Quit, for `appWindow`, or for the
    /// stream in front when nil.
    private static func quitItems(for appWindow: AppWindow?) -> [NSMenuItem] {
        let name = appWindow?.window?.title
        let quit = NSMenuItem(title: name.map { "Quit \u{201C}\($0)\u{201D} on PC" } ?? "Quit App on PC",
                              action: #selector(quitStreamedApp(_:)), keyEquivalent: "")
        let force = NSMenuItem(title: name.map { "Force Quit \u{201C}\($0)\u{201D} on PC…" }
                                   ?? "Force Quit App on PC…",
                               action: #selector(forceQuitStreamedApp(_:)), keyEquivalent: "")
        force.keyEquivalentModifierMask = .option
        force.isAlternate = true
        quit.representedObject = appWindow
        force.representedObject = appWindow
        return [quit, force]
    }

    /// The stream a Quit item acts on: the one it names, else the one in front.
    private func quitTarget(_ sender: NSMenuItem) -> AppWindow? {
        if let named = sender.representedObject as? AppWindow {
            return appWindows.contains { $0 === named } ? named : nil
        }
        return appWindows.first { $0.window?.isKeyWindow == true } ?? appWindows.first
    }

    @objc private func quitStreamedApp(_ sender: NSMenuItem) {
        guard let target = quitTarget(sender) else { return }
        quit(target, force: false)
    }

    @objc private func forceQuitStreamedApp(_ sender: NSMenuItem) {
        guard let target = quitTarget(sender) else { return }
        let name = target.window?.title ?? "the app"
        let alert = NSAlert()
        alert.messageText = "Force quit \u{201C}\(name)\u{201D} on the PC?"
        alert.informativeText = "Anything not saved in it will be lost. Use this only "
            + "when the app has stopped responding."
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        quit(target, force: true)
    }

    /// Ask the PC to quit it. Its window closes on the Mac by itself once the
    /// app's window is gone there, or hidden, for an app that goes to the
    /// notification area instead; only a refusal needs saying.
    private func quit(_ target: AppWindow, force: Bool) {
        guard let agent else { return }
        let name = target.window?.title ?? "the app"
        Log.info("[quit] \(force ? "force quitting" : "quitting") \"\(name)\" on the PC")
        agent.quit(windowID: target.remoteWindowID, force: force) { reason in
            guard let reason else {
                target.quitRequested = true
                return
            }
            Log.info("[quit] the PC refused: \(reason)")
            let alert = NSAlert()
            alert.messageText = "Couldn\u{2019}t quit \u{201C}\(name)\u{201D}"
            alert.informativeText = reason
            alert.runModal()
        }
    }

    /// SolStream's own Dock menu. With nothing streaming it used to offer
    /// nothing at all: the apps added to the Dock, and the last one opened,
    /// could not be reached from SolStream's icon. Now it lists them to open,
    /// and while streaming also Switch App and Disconnect, above each app's
    /// Quit and Force Quit.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let entries = Self.dockOpenEntries(launchers: Self.dockLaunchers(),
                                           last: lastStreamed ?? AppLink.last(),
                                           streaming: appWindows.isEmpty ? nil : streamLink)
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(dockOpen(_:)),
                                  keyEquivalent: "")
            item.representedObject = entry.link
            item.target = self
            menu.addItem(item)
        }
        if !appWindows.isEmpty {
            if !entries.isEmpty { menu.addItem(.separator()) }
            for (title, action) in [("Switch App…", #selector(switchApp)),
                                    ("Disconnect", #selector(disconnectHost))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for appWindow in appWindows {
                for item in Self.quitItems(for: appWindow) {
                    item.target = self
                    menu.addItem(item)
                }
            }
        }
        return menu.items.isEmpty ? nil : menu
    }

    /// The apps the Dock menu offers to open: the last one opened first, as
    /// Reopen, unless it is among the launchers; then every launcher by name.
    /// Not the app on screen now, which is there already. Named with its PC
    /// where two PCs have an app of the same name.
    static func dockOpenEntries(launchers: [AppLink], last: AppLink?,
                                streaming: AppLink?) -> [(title: String, link: AppLink)] {
        let onScreen = { (link: AppLink) in streaming.map { $0.likelySameApp(as: link) } ?? false }
        // Each app once, whatever repeats the folder holds.
        var unique: [AppLink] = []
        for link in launchers where !onScreen(link) && !unique.contains(where: { $0.likelySameApp(as: link) }) {
            unique.append(link)
        }
        let sorted = unique.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let reopen = last.flatMap { last in
            onScreen(last) || unique.contains(where: { $0.likelySameApp(as: last) }) ? nil : last
        }
        let listed = sorted + (reopen.map { [$0] } ?? [])
        func title(_ link: AppLink, _ verb: String) -> String {
            let twins = listed.filter {
                $0.name.caseInsensitiveCompare(link.name) == .orderedSame
                    && !AppLink.sameHost($0.host, link.host)
            }
            return twins.isEmpty ? "\(verb) \(link.name)" : "\(verb) \(link.name) on \(link.host)"
        }
        var entries = sorted.map { (title: title($0, "Open"), link: $0) }
        if let reopen {
            entries.insert((title: title(reopen, "Reopen"), link: reopen), at: 0)
        }
        return entries
    }

    /// The apps added to the Dock: every launcher in their folder that reads.
    private static func dockLaunchers() -> [AppLink] {
        AppLauncher.all()
    }

    @objc private func dockOpen(_ sender: NSMenuItem) {
        guard !testMode, let link = sender.representedObject as? AppLink else { return }
        open(link: link)
    }

    /// A file sent from the PC: saved in Downloads › SolStream, and said in the
    /// stream window in front -- or, with none, by bouncing the Dock icon.
    private func receiveFile(_ offer: FileReceiver.Offer, from agent: AgentConnection) {
        if fileReceiver?.agent !== agent {
            let receiver = FileReceiver(agent: agent)
            receiver.onReport = { [weak self] text in
                Log.info("[files] \(text)")
                if let window = self?.appWindows.first(where: { $0.window?.isKeyWindow == true })
                    ?? self?.appWindows.first {
                    window.tell(text)
                }
                if !NSApp.isActive {
                    NSApp.requestUserAttention(.informationalRequest)
                }
            }
            // The old connection's queue: taken over, or said to be lost.
            fileReceiver?.replaced(by: receiver)
            fileReceiver = receiver
        }
        fileReceiver?.receive(offer)
    }

    /// A link clicked on the PC, with SolStream chosen as its browser there:
    /// opened in this Mac's own browser or mail app, if it is one it may open.
    /// At most ten a minute: the host already holds a burst to eight a
    /// second, and this keeps a program on the PC from opening tab after tab
    /// here. The first held back is said in the stream window.
    private var linkLimit = LinkRateLimit()

    /// What the PC last said blocks its input, kept so a stream window opened
    /// while it lasts says it too. Nil when nothing is in the way.
    var inputBlockedNow: String?
    /// Its few words for the stream windows' subtitles.
    var inputBlockedShort: String?
    /// PCs already told this run that their SolStream is older than this Mac's.
    var toldOutdatedHosts: Set<String> = []
    /// Whether a blocked note was shown, so "can control again" is said only
    /// after one.
    var inputBlockedShown = false

    /// What the stream window says when the PC says its input is blocked,
    /// and when it is not any more. Said in the window in front, or the
    /// first: input that goes nowhere looks like SolStream broken, and the
    /// fix is always on the PC.
    func inputBlocked(_ reason: String?, app: String?) {
        guard let note = Self.inputBlockedNote(reason, app: app) else { return }
        Log.info("[input] \(reason ?? "unblocked")\(app.map { " (\($0))" } ?? "")")
        inputBlockedNow = reason == nil ? nil : note
        inputBlockedShort = Self.inputBlockedShort(reason, app: app)
        appWindows.forEach { $0.setInputBlocked(inputBlockedShort) }
        if reason == nil && !inputBlockedShown { return }
        let window = appWindows.first { $0.window?.isKeyWindow == true } ?? appWindows.first
        // Held while it lasts: in full screen the subtitle is out of sight,
        // and the note is all there is to say why clicks go nowhere.
        window?.tell(note, for: reason == nil ? 8 : nil)
        MainActor.assumeIsolated { DS.announce(note) }
        inputBlockedShown = reason != nil && window != nil
    }

    /// The subtitle's few words for it: the app by name when it is an
    /// administrator's app in front, since clicking another one clears it.
    static func inputBlockedShort(_ reason: String?, app: String?) -> String? {
        guard let reason else { return nil }
        if reason == "elevated", let app, !app.isEmpty { return "\(app) runs as administrator" }
        return "Input blocked on the PC"
    }

    /// The socket came back: what the PC said blocked its input may have
    /// cleared while the Mac was away, and it says only what is true now.
    func inputBlockedReset() {
        guard inputBlockedNow != nil else { return }
        Log.info("[input] reconnected; forgetting the block the PC reported before")
        inputBlockedNow = nil
        inputBlockedShort = nil
        appWindows.forEach { $0.setInputBlocked(nil) }
    }

    static func inputBlockedNote(_ reason: String?, app: String?) -> String? {
        switch reason {
        case "screenSaver":
            return "The PC's screen saver is on, and SolStream can't control it. Wake the PC at "
                + "its own mouse or keyboard."
        case "secureDesktop":
            return "Windows is showing a secure screen -- a permission prompt, Ctrl+Alt+Del or "
                + "the lock screen -- that SolStream can't control. Answer it at the PC."
        case "elevated":
            let name = (app?.isEmpty == false ? app! : "The app in front")
            return "\(name) runs as administrator on the PC, so SolStream can't control it. "
                + "Use it at the PC, or click another app."
        case nil:
            return "SolStream can control the PC again."
        default:
            return nil
        }
    }

    func openLinkFromPC(_ text: String) {
        guard let url = AgentConnection.linkToOpen(text) else {
            Log.info("[links] the PC sent a link this Mac won't open; ignored")
            return
        }
        switch linkLimit.take() {
        case .open:
            Log.info("[links] opening a \(url.scheme ?? "") link from the PC")
            NSWorkspace.shared.open(url)
        case .firstHeldBack:
            Log.info("[links] more than ten links from the PC in a minute; holding the rest back")
            // Not only a key window: the links that did open took the focus.
            (appWindows.first { $0.window?.isKeyWindow == true } ?? appWindows.first)?
                .tell(LinkRateLimit.note)
        case .heldBack:
            Log.info("[links] held back a link from the PC")
        }
    }

    @objc private func forgetHosts() {
        let alert = NSAlert()
        alert.messageText = "Forget paired PCs?"
        alert.informativeText = """
            SolStream will forget the pairing token it holds for each PC, \
            and the list of PCs used before. You will need to enter the token again — it is shown on SolStream's \
            own window on that PC, under "Pairing token".
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        // The Dock launchers too, when asked: each would only ask for a token
        // now. Asked rather than done, since they are icons someone placed.
        let launchers = NSButton(checkboxWithTitle: "Also remove the Dock launchers for their apps",
                                 target: nil, action: nil)
        launchers.state = .off
        alert.accessoryView = launchers
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if launchers.state == .on {
            let removed = AppLauncher.removeAll()
            Log.info("[launcher] removed \(removed.count) launcher(s) with the pairings")
            AppLauncher.removeFromDock(removed)
        }
        TokenStore.removeAll()
        // And how to wake each one: a PC's hardware address is about that PC.
        WakeOnLAN.forgetAll()
        // And what to reopen: kept, the next launch connected to a PC just
        // forgotten, by itself, and asked for its token at once. A stream
        // open now is not saved at quit either, for the same reason.
        AppLink.setLast(nil)
        NotificationCenter.default.post(name: AppLauncher.didChange, object: nil)
        // And the list of PCs used before, which otherwise still offered the
        // ones just forgotten, the window opening on the last of them.
        ConnectWindow.forgetRecents()
        forgotPairings = true
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
            let path = screenshotPath
            try? data.write(to: URL(fileURLWithPath: path))
            Log.info("Test screenshot saved to \(path) (\(data.count) bytes)")
        }
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let state = Self.streamSwitchState(menuItem.action,
                                              muted: StreamSettings.shared.isMuted,
                                              mode: StreamSettings.shared.pointerMode) {
            menuItem.state = state
            return true
        }
        if menuItem.action == #selector(checkForUpdates) {
            menuItem.title = Self.updateMenuTitle(for: MainActor.assumeIsolated { Updater.shared.state })
            return true
        }
        if menuItem.action == #selector(addStreamToDock) {
            // Named, so it says what it will add.
            menuItem.title = streamLink.map { "Add \($0.name) to Dock" } ?? "Add App to Dock"
            return !appWindows.isEmpty && streamLink?.path != nil
        }
        if menuItem.action == #selector(quitStreamedApp(_:))
            || menuItem.action == #selector(forceQuitStreamedApp(_:)) {
            let target = quitTarget(menuItem)
            // The Host menu's pair names the app in front; the Dock's were
            // named when they were made.
            if menuItem.representedObject == nil {
                let force = menuItem.action == #selector(forceQuitStreamedApp(_:))
                let name = target?.window?.title
                menuItem.title = (force ? "Force Quit " : "Quit ")
                    + (name.map { "\u{201C}\($0)\u{201D}" } ?? "App")
                    + (force ? " on PC…" : " on PC")
            }
            return target != nil && agent != nil
        }
        return Self.hostMenuAllows(menuItem.action,
                            connected: agent != nil || picker != nil || session != nil,
                            streaming: !appWindows.isEmpty)
    }
}
