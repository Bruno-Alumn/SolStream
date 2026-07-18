import Cocoa
import AppKit

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
@main
struct SolStreamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var streamWindows: [StreamWindow] = []
    private let streamManager = StreamManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        // Create the main configuration window (or show pairing UI).
        // For Phase 2, the user enters the Windows host address and
        // pairing PIN here.

        Logger.info("SolStream macOS Client v0.2 started")

        // In a real Phase 2 build, this would show a connection dialog.
        // For now, create a demo stream window.
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
