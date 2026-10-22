import CoreGraphics
import XCTest
@testable import InputCapture

/// The wheel translation: units, the horizontal sign, and what rounding keeps.
final class ScrollUnitsTests: XCTestCase {
    /// AppKit's positive deltaY is up, like Windows' WHEEL; its positive
    /// deltaX is left, the opposite of Windows' HWHEEL.
    func testVerticalPassesThroughAndHorizontalIsNegated() {
        let wheel = InputCapture.wheelUnits(deltaX: 1, deltaY: 1, precise: false, residual: .zero)
        XCTAssertEqual(wheel.vertical, 48)  // one line, 40 pt, at 1.2 units a point
        XCTAssertEqual(wheel.horizontal, -48)
    }

    /// A slow trackpad scroll arrives as fractions of a point; rounding each
    /// event alone sent nothing at all.
    func testTrackpadFractionsAccumulate() {
        var residual = CGPoint.zero
        var total = 0
        for _ in 0..<10 {
            let wheel = InputCapture.wheelUnits(deltaX: 0, deltaY: 0.5, precise: true,
                                                residual: residual)
            residual = wheel.residual
            total += wheel.vertical
        }
        // 10 × 0.5 pt × 1.2 units/pt: nothing lost, whatever the rounding.
        XCTAssertEqual(Double(total) + Double(residual.y), 6, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(total, 5)
        XCTAssertLessThan(abs(residual.y), 1)
    }

    /// A trackpad moves the content as far as the fingers, as on the Mac: a
    /// 100-point swipe is 120 units, which Chromium scrolls 100 DIP, one Mac
    /// point each.
    func testATrackpadSwipeMovesContentAsFarAsTheFingers() {
        let wheel = InputCapture.wheelUnits(deltaX: 0, deltaY: 100, precise: true, residual: .zero)
        XCTAssertEqual(wheel.vertical, 120)
    }
}
