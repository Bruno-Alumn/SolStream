import XCTest
@testable import SolStreamClient

/// Ten links from the PC a minute; the first of each run held back is said.
final class LinkRateLimitTests: XCTestCase {
    func testTenAMinuteThenHeldBackAndSaidOnce() {
        var limit = LinkRateLimit()
        let start: TimeInterval = 1_000
        for i in 0..<10 {
            XCTAssertEqual(limit.take(at: start + Double(i)), .open)
        }
        XCTAssertEqual(limit.take(at: start + 10), .firstHeldBack)
        XCTAssertEqual(limit.take(at: start + 11), .heldBack)
        // A minute after the first, one slot is free again; held back again
        // after it, and said again, since one opened in between.
        XCTAssertEqual(limit.take(at: start + 60), .open)
        XCTAssertEqual(limit.take(at: start + 60.5), .firstHeldBack)
        XCTAssertEqual(limit.take(at: start + 60.6), .heldBack)
        // Quiet for a minute: all ten again.
        let later = start + 200
        for i in 0..<10 {
            XCTAssertEqual(limit.take(at: later + Double(i) / 10), .open)
        }
        XCTAssertEqual(limit.take(at: later + 2), .firstHeldBack)
    }
}
