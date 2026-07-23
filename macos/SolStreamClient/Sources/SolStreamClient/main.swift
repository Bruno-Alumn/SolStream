import Cocoa
import AppKit
import SolStreamLogging

/// SolStream macOS Client entry point.
struct SolStreamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Check for test flags.
        if CommandLine.arguments.contains("--test-screenshot") {
            delegate.testMode = true
        }

        app.run()
    }
}

// Entry point
SolStreamApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var streamWindows: [StreamWindow] = []

    /// When true, the app exits after taking a test screenshot.
    var testMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Logger.info("SolStream macOS Client v0.2 started")

        if testMode {
            // Test mode: skip dialog, connect to localhost, take screenshot, exit.
            startStreaming(
                host: "127.0.0.1",
                appName: "Test",
                width: 1280,
                height: 720
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.captureTestScreenshot()
            }
            return
        }

        // Show connection dialog.
        showConnectDialog()
    }

    /// Simple connection dialog using NSAlert (AppKit built-in, zero deps).
    private func showConnectDialog() {
        let alert = NSAlert()
        alert.messageText = "Connect to SolStream"
        alert.informativeText = "Enter the host address of the Windows machine."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Quit")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "100.101.102.103"
        field.stringValue = "100.101.102.103"
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            Logger.info("User quit from connection dialog")
            NSApp.terminate(nil)
            return
        }

        let host = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else {
            showConnectDialog()  // Try again if empty
            return
        }

        startStreaming(host: host, appName: "Remote App", width: 1280, height: 720)
    }

    /// Capture a screenshot of the first stream window and save to /tmp.
    private func captureTestScreenshot() {
        guard let window = streamWindows.first?.window else {
            Logger.error("No stream window to capture")
            NSApp.terminate(nil)
            return
        }

        window.orderFrontRegardless()
        let windowNumber = CGWindowID(window.windowNumber)
        Logger.info("Capturing window #\(windowNumber)")

        guard let cgImage = CGWindowListCreateImage(
            .infinite,
            .optionIncludingWindow,
            windowNumber,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            Logger.error("Could not capture window via CGWindowListCreateImage")
            NSApp.terminate(nil)
            return
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            Logger.error("Could not encode PNG")
            NSApp.terminate(nil)
            return
        }

        let outputPath = "/tmp/solstream_internal_screenshot.png"
        do {
            try data.write(to: URL(fileURLWithPath: outputPath))
            Logger.info("Test screenshot saved to \(outputPath) (\(data.count) bytes)")
        } catch {
            Logger.error("Failed to save screenshot: \(error)")
        }

        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        for window in streamWindows {
            window.stopStreaming()
        }
    }

    /// Start streaming an application window from the host.
    func startStreaming(
        host: String,
        appName: String,
        width: Int,
        height: Int,
        frameRate: Int = 60
    ) {
        let streamWindow = StreamWindow(
            host: host,
            appName: appName,
            width: width,
            height: height,
            frameRate: frameRate
        )
        streamWindows.append(streamWindow)
        streamWindow.show()
        streamWindow.startStreaming()
    }
}
