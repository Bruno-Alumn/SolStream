import Cocoa
import AppKit
import SolStreamLogging
import StreamConnection

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

    /// `--host <ip>` connects immediately; `--test-screenshot` grabs the window
    /// and exits (used by the UI tests).
    private var testMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        Log.info("SolStream macOS client v0.3 started")

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

        // --packet-size tunes the video payload per datagram, for links with a
        // smaller MTU than the 1024 default assumes.
        var config = StreamConnection.Config()
        if let index = arguments.firstIndex(of: "--packet-size"),
           index + 1 < arguments.count,
           let size = Int(arguments[index + 1]) {
            config.packetSize = size
            Log.info("packet size overridden to \(size)")
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

        if let host, let appWindowQuery {
            startSingleApp(host: host, agentHost: agentHost ?? host,
                           matching: appWindowQuery, config: config)
        } else if let host {
            startStreaming(host: host, config: config)
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Flow

    private func showConnectWindow() {
        let window = ConnectWindow { [weak self] host in
            self?.startStreaming(host: host)
        }
        connectWindow = window
        window.show()
    }

    private func startStreaming(host: String, config: StreamConnection.Config = .init()) {
        let streamWindow = StreamWindow(host: host, config: config)
        streamWindow.onClose = { [weak self, weak streamWindow] in
            guard let self else { return }
            self.streamWindows.removeAll { $0 === streamWindow }
            if self.streamWindows.isEmpty && !self.testMode {
                self.showConnectWindow()
            }
        }
        streamWindows.append(streamWindow)
        streamWindow.show()
        streamWindow.startStreaming()
    }

    /// Stream a single Windows application window.
    ///
    /// The agent is consulted BEFORE the stream is launched, because the encode
    /// canvas has to match the capture display exactly. Sunshine scales the
    /// captured display into the requested viewport; asking for the display's
    /// own size makes that scale 1:1, so the crop is pixel-exact instead of
    /// resampled.
    private func startSingleApp(host: String, agentHost: String, matching query: String,
                                config: StreamConnection.Config) {
        let agent = AgentConnection(host: agentHost)
        self.agent = agent

        agent.onState = { state in
            if case .failed(let message) = state {
                Log.error("[app] agent unreachable: \(message) — is SolStreamAgent running?")
            }
        }

        agent.onDisplays = { [weak self] displays in
            guard let self, let capture = displays.first(where: { $0.isPrimary }) ?? displays.first else {
                Log.error("[app] host reported no displays")
                return
            }
            Log.info("[app] capture display \(capture.name) \(capture.width)x\(capture.height)")

            agent.windows { [weak self] windows in
                guard let self else { return }
                let matches = windows.filter {
                    $0.title.localizedCaseInsensitiveContains(query)
                }
                guard let target = matches.first else {
                    Log.error("[app] no window matching \"\(query)\". Candidates:")
                    for window in windows { Log.error("[app]   \(window.title)") }
                    return
                }
                Log.info("[app] target \"\(target.title)\" id=\(target.id) at \(target.frame)")

                DispatchQueue.main.async {
                    self.launchSingleApp(host: host, agent: agent,
                                         window: target, display: capture, config: config)
                }
            }
        }

        agent.connect()
    }

    private func launchSingleApp(host: String, agent: AgentConnection,
                                 window: RemoteWindow, display: RemoteDisplay,
                                 config baseConfig: StreamConnection.Config) {
        // Encode at the display's native size so Sunshine does not rescale.
        var config = baseConfig
        config.width = display.width
        config.height = display.height

        let streamWindow = StreamWindow(host: host, config: config)
        streamWindow.onClose = { [weak self, weak streamWindow] in
            guard let self else { return }
            self.streamWindows.removeAll { $0 === streamWindow }
        }
        streamWindows.append(streamWindow)
        streamWindow.window?.title = window.title
        streamWindow.show()
        streamWindow.startStreaming()

        let canvas = CGSize(width: display.width, height: display.height)

        // Put the window at a known place on the capture display rather than
        // trusting where the user left it, then crop to the rectangle the host
        // actually achieved — an app with a minimum size may not accept ours.
        let requested = Self.layoutRect(for: window, on: display)
        agent.place(windowID: window.id, at: requested) { [weak streamWindow] achieved in
            let placed = achieved ?? requested
            // Raise it, so on a shared display it is at least on top. On a
            // dedicated capture display nothing else is there to occlude it.
            agent.focus(windowID: window.id)

            let crop = CGRect(x: placed.minX - CGFloat(display.x),
                              y: placed.minY - CGFloat(display.y),
                              width: placed.width, height: placed.height)
            DispatchQueue.main.async {
                streamWindow?.setSourceRect(crop, canvasSize: canvas)
                Log.info("[app] placed at \(placed); cropping \(display.width)x\(display.height) to \(crop)")
            }
        }
    }

    /// Where to put a window on the capture display.
    ///
    /// For now: centred at its current size, clamped to the display. Once there
    /// is a dedicated capture display this becomes the tiling layout manager
    /// that guarantees windows never overlap.
    private static func layoutRect(for window: RemoteWindow,
                                   on display: RemoteDisplay) -> CGRect {
        let width = min(CGFloat(window.width), CGFloat(display.width))
        let height = min(CGFloat(window.height), CGFloat(display.height))
        let x = CGFloat(display.x) + (CGFloat(display.width) - width) / 2
        let y = CGFloat(display.y) + (CGFloat(display.height) - height) / 2
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About SolStream", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Reveal Identity in Finder",
                        action: #selector(revealIdentity), keyEquivalent: "")
        appMenu.addItem(withTitle: "Forget Paired Hosts…",
                        action: #selector(forgetHosts), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SolStream",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Enter Full Screen",
                           action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func revealIdentity() {
        let path = ClientIdentity.shared.certPath
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    @objc private func forgetHosts() {
        let alert = NSAlert()
        alert.messageText = "Forget paired hosts?"
        alert.informativeText = """
            SolStream will forget the TLS keys it pinned for each host. \
            Your client identity is kept, so hosts that still trust this Mac \
            won't ask for a PIN again.
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ClientIdentity.shared.forgetKnownHosts()
    }

    // MARK: - Test support

    private func captureTestScreenshot() {
        // Prefer a stream window; fall back to whatever window is on screen so
        // the connect window can be captured too.
        guard let window = streamWindows.first?.window
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
