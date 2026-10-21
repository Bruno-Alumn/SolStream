import CoreGraphics
import XCTest
@testable import InputCapture

/// The wheel translation: units, the horizontal sign, and what rounding keeps.
final class ScrollUnitsTests: XCTestCase {
    /// AppKit's positive deltaY is up, like Windows' WHEEL; its positive
    /// deltaX is left, the opposite of Windows' HWHEEL.
    func testVerticalPassesThroughAndHorizontalIsNegated() {
        let wheel = InputCapture.wheelUnits(deltaX: 1, deltaY: 1, precise: false, residual: .zero)
        XCTAssertEqual(wheel.vertical, 120)
        XCTAssertEqual(wheel.horizontal, -120)
    }

    /// A slow trackpad scroll arrives as fractions of a point; rounding each
    /// event alone sent nothing at all.
    func testTrackpadFractionsAccumulate() {
        var residual = CGPoint.zero
        var total = 0
        for _ in 0..<10 {
            let wheel = InputCapture.wheelUnits(deltaX: 0, deltaY: 0.05, precise: true,
                                                residual: residual)
            residual = wheel.residual
            total += wheel.vertical
        }
        XCTAssertEqual(total, 6)  // 10 × 0.05 pt × 12 units/pt
        XCTAssertLessThan(abs(residual.y), 1)
    }
}
