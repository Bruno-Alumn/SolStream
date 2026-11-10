import AppKit
import CoreVideo
import XCTest
@testable import VideoDecoder

/// A frame handed over before a card went up is drawn under the card; it does
/// not take the card down.
final class StatusCardTests: XCTestCase {
    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferMetalCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                            attributes, &buffer)
        return try XCTUnwrap(buffer)
    }

    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testAFrameFromBeforeTheCardLeavesItUp() throws {
        let view = MetalView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.displayFrame(try pixelBuffer())
        view.setStatus("Applying settings…")
        drainMain()
        XCTAssertTrue(view.isShowingStatus)
    }

    func testAFrameAfterTheCardTakesItDown() throws {
        let view = MetalView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.setStatus("Waiting for video")
        view.displayFrame(try pixelBuffer())
        drainMain()
        XCTAssertFalse(view.isShowingStatus)
    }

    /// An error says the stream has ended; a frame still arriving does not
    /// take it, or its Try Again, away.
    func testAFrameLeavesAnErrorUp() throws {
        let view = MetalView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        view.setError("Lost the connection")
        view.displayFrame(try pixelBuffer())
        drainMain()
        XCTAssertTrue(view.isShowingStatus)
        // Taken down when the app says so.
        view.hideStatus()
        XCTAssertFalse(view.isShowingStatus)
    }

    private func visibleButtons(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ v: NSView) {
            if let button = v as? NSButton, !button.isHiddenOrHasHiddenAncestor { found.append(button.title) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// A busy card that has lasted offers the way back to the apps beside its
    /// spinner; an error after it says Try Again, as before.
    func testALingeringBusyCardOffersAWayOut() {
        let view = MetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.onRetry = {}
        view.setStatus("Reconnecting…", detail: "Waiting for the PC to answer.")
        XCTAssertEqual(visibleButtons(in: view), [])
        view.offerWayOut()
        XCTAssertEqual(visibleButtons(in: view), ["Back to Apps"])
        view.setError("Lost the connection")
        XCTAssertEqual(visibleButtons(in: view), ["Try Again"])
    }

    /// Without a way back to offer, nothing is offered.
    func testNoWayOutWithoutAHandler() {
        let view = MetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.setStatus("Reconnecting…")
        view.offerWayOut()
        XCTAssertEqual(visibleButtons(in: view), [])
    }

}
