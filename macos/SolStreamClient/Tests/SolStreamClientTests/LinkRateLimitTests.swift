import XCTest
@testable import SolStreamClient

/// Ten links from the PC a minute; the first one held back is said.
final class LinkRateLimitTests: XCTestCase {
    func testTenAMinuteThenHeldBackAndSaidOnce() {
        var limit = LinkRateLimit()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<10 {
            XCTAssertEqual(limit.take(at: start.addingTimeInterval(Double(i))), .open)
        }
        XCTAssertEqual(limit.take(at: start.addingTimeInterval(10)), .firstHeldBack)
        XCTAssertEqual(limit.take(at: start.addingTimeInterval(11)), .heldBack)
        // A minute after the first, one slot is free again.
        XCTAssertEqual(limit.take(at: start.addingTimeInterval(60)), .open)
        XCTAssertEqual(limit.take(at: start.addingTimeInterval(60.5)), .heldBack)
        // Quiet for a minute: all ten again, and the next hold is said again.
        let later = start.addingTimeInterval(200)
        for i in 0..<10 {
            XCTAssertEqual(limit.take(at: later.addingTimeInterval(Double(i) / 10)), .open)
        }
        XCTAssertEqual(limit.take(at: later.addingTimeInterval(2)), .firstHeldBack)
    }
}
