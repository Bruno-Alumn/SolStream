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
}
