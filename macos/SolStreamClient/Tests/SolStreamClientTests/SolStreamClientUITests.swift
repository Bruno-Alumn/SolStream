import XCTest
import Cocoa
import SolStreamLogging

/// UI tests for SolStream macOS Client.
///
/// These tests launch the app binary with special test flags to verify
/// the app launches, shows a window, and can capture screenshots.
final class SolStreamClientUITests: XCTestCase {

    /// The built app binary: next to this test bundle, in whichever build
    /// directory -- arm64 or x86_64, debug or release -- it was built into.
    var appURL: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("SolStreamClient")
    }

    var appProcess: Process?

    /// Where this test's screenshot is written: its own, so runs side by side
    /// and a file left by an earlier run cannot pass for this one's.
    private var screenshotURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        screenshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-screenshot-\(UUID().uuidString).png")
    }

    override func tearDown() {
        killApp()
        try? FileManager.default.removeItem(at: screenshotURL)
        super.tearDown()
    }

    // MARK: - Tests

    /// Test that the app launches and shows a window by verifying
    /// the window exists in the window server list.
    func testAppLaunchesAndShowsWindow() throws {
        try launchApp()

        let windowInfo = try waitForWindow(timeout: 10)
        XCTAssertNotNil(windowInfo, "SolStream window should appear within 10 seconds")

        if let windowInfo {
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            print("✅ Found window owned by: '\(ownerName)'")
        }
    }

    /// Test that the app can capture a window screenshot internally
    /// via the --test-screenshot command-line flag.
    func testInternalScreenshotCapture() throws {
        // Launch the app with the test flag which takes a screenshot internally and exits.
        try launchApp(args: ["--test-screenshot", "--screenshot-path", screenshotURL.path])

        // Wait for the process to exit (it exits automatically after saving the screenshot).
        appProcess?.waitUntilExit()

        // Verify the screenshot file was created.
        let screenshotPath = screenshotURL.path
        let fileExists = FileManager.default.fileExists(atPath: screenshotPath)
        XCTAssertTrue(fileExists, "Screenshot file should exist after --test-screenshot mode")

        if fileExists {
            let attrs = try FileManager.default.attributesOfItem(atPath: screenshotPath)
            let fileSize = attrs[.size] as? Int ?? 0
            XCTAssertGreaterThan(fileSize, 1000, "Screenshot should be at least 1KB")
            print("✅ Internal screenshot file: \(fileSize) bytes")

            // Attach to test report.
            if let data = try? Data(contentsOf: URL(fileURLWithPath: screenshotPath)) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "SolStreamWindow_internal.png"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    /// Test that the app launches and its process is running.
    func testAppLaunches() throws {
        try launchApp()
        XCTAssertTrue(appProcess?.isRunning ?? false, "App process should be running")
        print("✅ App process is running (PID: \(appProcess?.processIdentifier ?? 0))")
    }

    // MARK: - Helpers

    private func launchApp(args: [String] = []) throws {
        let workDir = FileManager.default.currentDirectoryPath
        let app = appURL

        guard FileManager.default.isExecutableFile(atPath: app.path) else {
            XCTFail("App binary not found at \(app.path). Build the app first with 'swift build'")
            return
        }

        let process = Process()
        process.executableURL = app
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        appProcess = process
        print("🚀 App launched (PID: \(process.processIdentifier), args: \(args))")
    }

    private func killApp() {
        guard let process = appProcess, process.isRunning else {
            appProcess = nil
            return
        }
        process.terminate()
        process.waitUntilExit()
        appProcess = nil
        print("🛑 App terminated")
    }

    private func waitForWindow(timeout: TimeInterval) throws -> [String: Any]? {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if let windowInfo = findSolStreamWindow() {
                return windowInfo
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    private func findSolStreamWindow() -> [String: Any]? {
        guard let windowList = CGWindowListCopyWindowInfo(
            .optionOnScreenOnly, kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windowList {
            let ownerName = window[kCGWindowOwnerName as String] as? String ?? ""
            if ownerName.contains("SolStream") {
                return window
            }
        }
        return nil
    }
}
