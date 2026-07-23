import Cocoa
import AppKit
import SolStreamLogging

/// SolStream macOS Client entry point.
///
/// Phase 2 architecture:
///   - Single NSApplication with multiple NSWindows (one per streamed app)
///   - Each window has a CAMetalLayer-backed view for video rendering
///   - Local NSView event monitoring for input (no CGEventTap, no Accessibility)
///   - VideoToolbox hardware decoding
///   - AudioUnit renderer for audio playback
///   - moonlight-common-c for SRTP/RTSP stream protocol
///
struct SolStreamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate

        // Check for test flags.
        if CommandLine.arguments.contains("--test-screenshot") {
            // Run the app in test mode: create window, take screenshot, save, exit.
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

        // For dev/testing: show a demo window.
        startStreaming(
            host: "192.168.1.100",
            appName: "Demo",
            width: 1280,
            height: 720
        )

        // In test mode: take a screenshot and exit.
        if testMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.captureTestScreenshot()
            }
        }
    }

    /// Capture a screenshot of the first stream window and save to /tmp.
    private func captureTestScreenshot() {
        guard let window = streamWindows.first?.window else {
            Logger.error("No stream window to capture")
            NSApp.terminate(nil)
            return
        }

        // Give the window server a moment to render the window fully.
        window.orderFrontRegardless()

        // Capture the entire window (title bar + chrome + content)
        // using the CoreGraphics window server API from within this process.
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
    }
}
