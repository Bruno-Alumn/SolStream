import AppKit
import XCTest
@testable import AgentChannel
@testable import SolStreamClient
import VideoDecoder

/// Fewer pictures from the PC while no stream window is seen, and the full
/// rate the moment one is.
final class HiddenRateTests: XCTestCase {
    private var rate = HiddenRate()

    private func hidden(at now: TimeInterval, launching: Bool = false) -> HiddenRate.Action {
        rate.update(anyShown: false, launching: launching, now: now)
    }

    private func shown(at now: TimeInterval, launching: Bool = false) -> HiddenRate.Action {
        rate.update(anyShown: true, launching: launching, now: now)
    }

    func testNothingWhileAWindowIsSeen() {
        XCTAssertEqual(shown(at: 0), .none)
        XCTAssertEqual(shown(at: 60), .none)
        XCTAssertFalse(rate.lowered)
    }

    func testLoweredAfterTwoSecondsOutOfSight() {
        XCTAssertEqual(hidden(at: 10), .check(after: 2))
        XCTAssertEqual(hidden(at: 11.5), .check(after: 0.5))
        XCTAssertEqual(hidden(at: 12), .lower)
        XCTAssertTrue(rate.lowered)
        XCTAssertEqual(hidden(at: 20), .none, "asked once")
    }

    func testRestoredTheMomentOneIsSeen() {
        _ = hidden(at: 0)
        XCTAssertEqual(hidden(at: 3), .lower)
        XCTAssertEqual(shown(at: 3.1), .restore)
        XCTAssertFalse(rate.lowered)
        XCTAssertEqual(shown(at: 4), .none, "asked once")
    }

    func testAMomentOutOfSightChangesNothing() {
        XCTAssertEqual(hidden(at: 0), .check(after: 2))
        XCTAssertEqual(shown(at: 1), .none, "never lowered, so nothing to restore")
        XCTAssertEqual(hidden(at: 1.5), .check(after: 2), "the two seconds start again")
        XCTAssertEqual(hidden(at: 3.5), .lower)
    }

    func testTheFullRateGoesBeforeALaunch() {
        _ = hidden(at: 0)
        XCTAssertEqual(hidden(at: 2), .lower)
        XCTAssertEqual(hidden(at: 5, launching: true), .restore,
                       "asked behind the launch, the restore would wait for it")
        XCTAssertEqual(hidden(at: 30, launching: true), .none, "and nothing lowered meanwhile")
        XCTAssertEqual(hidden(at: 31), .lower, "out of sight all along: lowered at once")
    }

    func testALaunchFromWindowsSeenLowersNothingAfter() {
        XCTAssertEqual(shown(at: 0, launching: true), .none)
        XCTAssertEqual(shown(at: 20), .none)
    }

    func testANewSessionIsLoweredAgain() {
        _ = hidden(at: 0)
        XCTAssertEqual(hidden(at: 2), .lower)
        rate.sessionStarted()
        XCTAssertFalse(rate.lowered)
        XCTAssertEqual(hidden(at: 2.5), .lower, "the new session runs at the full rate")
    }

    func testANewSessionWhileSeenAsksNothing() {
        rate.sessionStarted()
        XCTAssertEqual(shown(at: 0), .none)
    }

    func testTheRateIsOneTheWatchdogsTakeForAPicture() {
        // A second with no picture is a stall on the Mac; three with none is
        // a broken encoder on the PC.
        // The PC raises anything under 5 to 5.
        XCTAssertGreaterThanOrEqual(HiddenRate.hiddenRate, 5)
        XCTAssertLessThan(1.0 / Double(HiddenRate.hiddenRate), LivenessWatch.stallThreshold)
    }

    // MARK: What counts as seen

    func testWhatMacOSCallsSeen() {
        XCTAssertTrue(AppWindow.isShown(occlusion: .visible, miniaturized: false))
        XCTAssertFalse(AppWindow.isShown(occlusion: [], miniaturized: false),
                       "covered, or on another Space")
        XCTAssertFalse(AppWindow.isShown(occlusion: .visible, miniaturized: true),
                       "on its way into the Dock")
        XCTAssertFalse(AppWindow.isShown(occlusion: [], miniaturized: true))
    }

    // MARK: Drawing

    func testDrawingPausesAndResumes() {
        _ = NSApplication.shared
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(view.isDrawingPaused)
        view.setDrawingPaused(true)
        XCTAssertTrue(view.isDrawingPaused)
        // Resuming with no frame kept draws nothing and does not trip.
        view.setDrawingPaused(false)
        XCTAssertFalse(view.isDrawingPaused)
    }

    func testAFrameWhilePausedIsKeptNotScheduled() throws {
        _ = NSApplication.shared
        let view = MetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.setDrawingPaused(true)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        let frame = try XCTUnwrap(buffer)
        view.displayFrame(frame)
        // Nothing went to the main thread to draw it; resuming draws it, off
        // screen here, without waiting for another.
        let drained = expectation(description: "main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(view.isDrawingPaused)
        view.setDrawingPaused(false)
        XCTAssertFalse(view.isDrawingPaused)
    }

    // MARK: The host's say

    func testOnlyAHostThatSaysSoIsAsked() {
        XCTAssertTrue(AgentConnection.takesRateCap(inReply: ["rateCap": 1]))
        XCTAssertFalse(AgentConnection.takesRateCap(inReply: ["scancodes": 2]),
                       "an older host answers `media rate` with unknown op")
        XCTAssertFalse(AgentConnection.takesRateCap(inReply: ["rateCap": 0]))
    }
}
