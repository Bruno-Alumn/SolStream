import XCTest
import MediaSession
@testable import SolStreamClient

/// How often a stream that keeps ending is restarted, and what is said when
/// one cannot be opened.
final class StreamRecoveryTests: XCTestCase {
    /// Five restarts in two minutes, then no more -- across pictures, which
    /// the per-attempt count was not: it reset at each first picture.
    func testRestartsAreLimitedInAWindowOfTime() {
        var restarts: [Date] = []
        let start = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<5 {
            XCTAssertFalse(AppDelegate.restartsExhausted(&restarts, now: start + Double(i) * 10))
        }
        XCTAssertTrue(AppDelegate.restartsExhausted(&restarts, now: start + 50))
        XCTAssertEqual(restarts.count, 5, "a refused restart is not counted")
        // Two minutes after the first, there is room again.
        XCTAssertFalse(AppDelegate.restartsExhausted(&restarts, now: start + 121))
    }

    /// Each reason the stream could not be opened says what to do about it.
    func testEachStartFailureSaysWhatToDo() {
        let unresolved = StreamSession.startFailureText(.unresolved, host: "DESKTOP-PC")
        XCTAssertTrue(unresolved.contains("couldn't find DESKTOP-PC"))
        XCTAssertTrue(unresolved.contains("online"))
        let ipv6 = StreamSession.startFailureText(.noIPv4, host: "DESKTOP-PC")
        XCTAssertTrue(ipv6.contains("IPv4"))
        XCTAssertTrue(ipv6.contains("100."))
        XCTAssertFalse(ipv6.contains("quit and reopen"))
        XCTAssertTrue(StreamSession.startFailureText(.socket, host: "x").contains("quit and reopen"))
        XCTAssertTrue(StreamSession.startFailureText(nil, host: "x").contains("Try Again"))
    }
}
