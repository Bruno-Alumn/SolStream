import AppKit
import XCTest
import InputCapture
@testable import SolStreamClient

/// The stats popover carries the mouse-mode toggle; it has to be there, sized
/// to hold it, and say what the chosen mode does.
final class QualityPillTests: XCTestCase {

    func testThePopoverOffersTheMouseModeAndFitsIt() throws {
        let pill = QualityPill()
        let detail = pill.buildDetail()
        detail.appearance = NSAppearance(named: .darkAqua)

        let toggles = Self.all(NSSegmentedControl.self, in: detail)
        XCTAssertEqual(toggles.count, 1, "no mouse-mode toggle in the popover")
        XCTAssertEqual(toggles.first?.segmentCount, 2)
        for toggle in toggles {
            XCTAssertTrue(detail.bounds.contains(toggle.convert(toggle.bounds, to: detail)),
                          "the toggle is cut off by the popover's edge")
        }

        // A picture to look at, for whoever changes this layout next, on the
        // dark ground the real popover has.
        let backdrop = NSView(frame: detail.bounds)
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        backdrop.addSubview(detail)
        backdrop.layoutSubtreeIfNeeded()
        if let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) {
            backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("solstream-quality-popover.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
    }
}
