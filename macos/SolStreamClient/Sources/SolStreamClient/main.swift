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

        if let index = arguments.firstIndex(of: "--host"), index + 1 < arguments.count {
            startStreaming(host: arguments[index + 1], config: config)
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
