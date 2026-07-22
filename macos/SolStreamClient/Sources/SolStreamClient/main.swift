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
        app.run()
    }
}

// Entry point
SolStreamApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var streamWindows: [StreamWindow] = []
    private let streamManager = StreamManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        Logger.info("SolStream macOS Client v0.2 started")

        // For dev/testing: show a demo window.
        // In production this would show a pairing/connection dialog.
        startStreaming(
            host: "192.168.1.100",
            appName: "Demo",
            width: 1280,
            height: 720
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        streamManager.disconnectAll()
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
            frameRate: frameRate,
            streamManager: streamManager
        )
        streamWindows.append(streamWindow)
        streamWindow.show()
    }
}
