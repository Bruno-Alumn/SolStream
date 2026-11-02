import XCTest
@testable import InputCapture

/// A trackpad pinch reaches the PC as Ctrl and the wheel, in whole notches.
final class PinchZoomTests: XCTestCase {
    func testAPinchIsWholeNotchesWithTheRestCarried() {
        // 0.12 of magnification is one notch.
        let first = InputCapture.pinchUnits(magnification: 0.12, residual: 0)
        XCTAssertEqual(first.units, 120)
        XCTAssertEqual(first.residual, 0, accuracy: 0.0001)

        // Less than a notch sends nothing, and is not lost.
        let small = InputCapture.pinchUnits(magnification: 0.05, residual: 0)
        XCTAssertEqual(small.units, 0)
        let next = InputCapture.pinchUnits(magnification: 0.08, residual: small.residual)
        XCTAssertEqual(next.units, 120)
        XCTAssertEqual(next.residual, 10, accuracy: 0.0001)
    }

    func testPinchingInIsTheWheelTowardsTheUser() {
        let out = InputCapture.pinchUnits(magnification: -0.25, residual: 0)
        XCTAssertEqual(out.units, -240)
        XCTAssertEqual(out.residual, -10, accuracy: 0.0001)
    }

    func testAPinchToTwiceTheSizeIsAboutEightNotches() {
        XCTAssertEqual(InputCapture.pinchUnits(magnification: 1, residual: 0).units, 960)
    }
}
