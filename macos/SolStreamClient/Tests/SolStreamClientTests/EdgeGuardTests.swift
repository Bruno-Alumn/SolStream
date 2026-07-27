import XCTest
@testable import InputCapture

/// Checks that the host pointer is kept clear of the streamed window's resize
/// border.
///
/// The border is the one part of the picture that must not be reachable: a drag
/// starting there begins a resize on the host, and the size belongs to the macOS
/// window frame. Getting the guard wrong in the other direction is just as bad —
/// an inverted safe rectangle would pin every position to a single point and the
/// pointer would stop moving entirely.
final class EdgeGuardTests: XCTestCase {
    private let crop = CGRect(x: 2560, y: 0, width: 3600, height: 2338)

    func testCentreIsUntouched() {
        let point = InputCapture.canvasPoint(unit: CGPoint(x: 0.5, y: 0.5),
                                             source: crop, edgeGuard: 16)
        XCTAssertEqual(point.x, crop.midX, accuracy: 0.5)
        XCTAssertEqual(point.y, crop.midY, accuracy: 0.5)
    }

    func testEdgesArePushedInsideTheBorder() {
        let topLeft = InputCapture.canvasPoint(unit: CGPoint(x: 0, y: 0),
                                               source: crop, edgeGuard: 16)
        XCTAssertEqual(topLeft.x, crop.minX + 16, accuracy: 0.5)
        XCTAssertEqual(topLeft.y, crop.minY + 16, accuracy: 0.5)

        let bottomRight = InputCapture.canvasPoint(unit: CGPoint(x: 1, y: 1),
                                                   source: crop, edgeGuard: 16)
        XCTAssertEqual(bottomRight.x, crop.maxX - 16, accuracy: 0.5)
        XCTAssertEqual(bottomRight.y, crop.maxY - 16, accuracy: 0.5)
    }

    func testNoGuardLeavesTheFullCropReachable() {
        let corner = InputCapture.canvasPoint(unit: CGPoint(x: 0, y: 0),
                                              source: crop, edgeGuard: 0)
        XCTAssertEqual(corner.x, crop.minX, accuracy: 0.5)
        XCTAssertEqual(corner.y, crop.minY, accuracy: 0.5)
    }

    /// A crop smaller than two guards must not produce an inverted rectangle —
    /// that would pin every position to one spot and freeze the pointer.
    func testGuardGivesWayOnATinyCrop() {
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        for unit in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            let point = InputCapture.canvasPoint(unit: unit, source: tiny, edgeGuard: 40)
            XCTAssertTrue(tiny.insetBy(dx: -0.5, dy: -0.5).contains(point),
                          "\(point) escaped a 10x10 crop")
        }
        // Still monotonic: the two ends must not collapse onto each other in a
        // way that reverses them.
        let left = InputCapture.canvasPoint(unit: CGPoint(x: 0, y: 0.5), source: tiny, edgeGuard: 40)
        let right = InputCapture.canvasPoint(unit: CGPoint(x: 1, y: 0.5), source: tiny, edgeGuard: 40)
        XCTAssertLessThanOrEqual(left.x, right.x)
    }
}
