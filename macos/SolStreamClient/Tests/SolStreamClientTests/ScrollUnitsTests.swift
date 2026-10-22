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

    /// Each notch of a wheel mouse is a whole Windows notch, so a game that
    /// counts notches (Minecraft's hotbar) moves one slot per notch.
    func testEveryWheelNotchIsAWholeWindowsNotch() {
        var residual = CGPoint.zero
        var notches: [Int] = []
        for _ in 0..<3 {
            let wheel = InputCapture.wheelUnits(deltaX: 0, deltaY: -1, precise: false, residual: residual)
            residual = wheel.residual
            notches.append(wheel.vertical)
        }
        XCTAssertEqual(notches, [-120, -120, -120])
    }

    /// A leftover from the last scroll is never spent against a new direction:
    /// it made the first notch back 119, which a game counting notches drops.
    func testTurningTheWheelBackIsStillAWholeNotch() {
        // An accelerated notch as macOS delivers it, in 16.16 fixed point.
        let fast = InputCapture.wheelUnits(deltaX: 0, deltaY: 1.399993896484375, precise: false,
                                           residual: .zero)
        XCTAssertEqual(fast.vertical, 167)
        let back = InputCapture.wheelUnits(deltaX: 0, deltaY: -1, precise: false, residual: fast.residual)
        XCTAssertEqual(back.vertical, -120)

        // A touch on the trackpad, then the wheel the other way.
        let touch = InputCapture.wheelUnits(deltaX: 0, deltaY: 0.5, precise: true, residual: .zero)
        XCTAssertEqual(touch.vertical, 0)
        let notch = InputCapture.wheelUnits(deltaX: 0, deltaY: -1, precise: false, residual: touch.residual)
        XCTAssertEqual(notch.vertical, -120)

        // The same way, it still counts.
        let more = InputCapture.wheelUnits(deltaX: 0, deltaY: 1, precise: false, residual: fast.residual)
        XCTAssertEqual(more.vertical, 120)
        let sideways = InputCapture.wheelUnits(deltaX: 1.399993896484375, deltaY: 0, precise: false,
                                               residual: .zero)
        let sidewaysBack = InputCapture.wheelUnits(deltaX: -1, deltaY: 0, precise: false,
                                                   residual: sideways.residual)
        XCTAssertEqual(sidewaysBack.horizontal, 120)
    }
}
