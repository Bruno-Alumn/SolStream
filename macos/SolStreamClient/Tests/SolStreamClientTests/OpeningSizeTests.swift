import XCTest
@testable import SolStreamClient

/// What size a streamed window opens at.
///
/// The rule used to be "the application's size, clamped to the screen", and the
/// clamp was the bug: an application maximised on the PC — and one parked on a
/// 3600x2338 virtual display usually is — opened edge to edge on the Mac, which
/// reads as full screen rather than as a window.
final class OpeningSizeTests: XCTestCase {
    /// A 14" MacBook's visible frame, in points, menu bar already subtracted.
    private let visible = CGSize(width: 1512, height: 945)

    func testAWindowMaximisedOnTheVirtualDisplayDoesNotFillTheScreen() {
        let size = AppWindow.openingSize(hostPixels: CGSize(width: 3600, height: 2338),
                                         scale: 2, visible: visible)
        XCTAssertLessThan(size.width, visible.width)
        XCTAssertLessThan(size.height, visible.height)
        // And by a visible margin, not a rounding error: the point is that the
        // desktop is still there around it.
        XCTAssertLessThanOrEqual(size.width, visible.width * 0.75)
        XCTAssertLessThanOrEqual(size.height, visible.height * 0.75)
    }

    func testShrinkingKeepsTheApplicationsProportions() {
        let host = CGSize(width: 3600, height: 2338)
        let size = AppWindow.openingSize(hostPixels: host, scale: 2, visible: visible)
        XCTAssertEqual(size.width / size.height, host.width / host.height, accuracy: 0.01)
    }

    /// The old behaviour was right for anything that fits, and stays right.
    func testAnApplicationThatAlreadyFitsOpensAtItsOwnSize() {
        // Character Map: 940x761 host pixels on a 2x display.
        let size = AppWindow.openingSize(hostPixels: CGSize(width: 940, height: 761),
                                         scale: 2, visible: visible)
        XCTAssertEqual(size.width, 470, accuracy: 1)
        XCTAssertEqual(size.height, 381, accuracy: 1)
    }

    /// Only ever smaller. Stretching a small application up to a "nicer" size
    /// would be worse than whatever size it chose for itself.
    func testASmallApplicationIsNeverGrown() {
        let size = AppWindow.openingSize(hostPixels: CGSize(width: 400, height: 300),
                                         scale: 2, visible: visible)
        XCTAssertEqual(size.width, 200, accuracy: 1)
        XCTAssertEqual(size.height, 150, accuracy: 1)
    }

    /// The host has not said how big the window is yet, so the caller passes the
    /// whole tile — or nothing at all. Neither may produce a zero-sized window.
    func testNoHostSizeYetFallsBackToTheOpeningFraction() {
        let size = AppWindow.openingSize(hostPixels: .zero, scale: 2, visible: visible)
        XCTAssertEqual(size.width, visible.width * AppWindow.openingScreenFraction, accuracy: 1)
        XCTAssertEqual(size.height, visible.height * AppWindow.openingScreenFraction, accuracy: 1)
    }

    func testANonsenseScaleDoesNotProduceAnEmptyWindow() {
        let size = AppWindow.openingSize(hostPixels: CGSize(width: 1920, height: 1080),
                                         scale: 0, visible: visible)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    /// A 1x display is a real configuration, and the scale is read from the
    /// screen rather than assumed to be 2 for exactly this reason.
    ///
    /// Sized to fit under the cap at BOTH scales, or the 1x case is capped, the
    /// 2x case is not, and the factor of two between them disappears — which is
    /// the shrink working, not the scale being ignored.
    func testTheBackingScaleIsHonoured() {
        let host = CGSize(width: 800, height: 600)
        let onePoint = AppWindow.openingSize(hostPixels: host, scale: 1, visible: visible)
        let twoPoint = AppWindow.openingSize(hostPixels: host, scale: 2, visible: visible)
        XCTAssertEqual(onePoint.width, 800, accuracy: 1)
        XCTAssertEqual(twoPoint.width * 2, onePoint.width, accuracy: 1)
    }
}
