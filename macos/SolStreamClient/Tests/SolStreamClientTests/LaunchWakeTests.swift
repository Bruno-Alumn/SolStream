import XCTest
@testable import SolStreamClient

/// A launcher clicked while the PC sleeps wakes it, tries the connection again
/// every few seconds, and gives up after a minute.
final class LaunchWakeTests: XCTestCase {
    func testRetriesForAMinuteThenGivesUp() {
        XCTAssertEqual(LaunchWake.step(elapsed: LaunchWake.retryEvery), .retry)
        XCTAssertEqual(LaunchWake.step(elapsed: LaunchWake.wait - 1), .retry)
        XCTAssertEqual(LaunchWake.step(elapsed: LaunchWake.wait), .giveUp)
        XCTAssertLessThan(LaunchWake.retryEvery, LaunchWake.wait)
    }

    func testSaysWhatIsHappeningAndWhatToCheck() {
        let waking = LaunchWake.waking("gaming-pc", app: "Excel")
        XCTAssertTrue(waking.contains("Waking gaming-pc"))
        XCTAssertTrue(waking.contains("Excel"))
        let gaveUp = LaunchWake.gaveUp("gaming-pc")
        XCTAssertTrue(gaveUp.contains("Wake-on-LAN"))
        XCTAssertTrue(gaveUp.contains("signed in"))
    }

    func testStopsWhenTold() {
        let wake = LaunchWake(retry: {}, gaveUp: {})
        XCTAssertTrue(wake.isRunning)
        wake.stop()
        XCTAssertFalse(wake.isRunning)
    }
}

import Network
@testable import AgentChannel

/// Only a PC that does not answer at all is woken: one that refused is
/// awake, and a name that did not resolve is not a PC to wake.
final class MightBeAsleepTests: XCTestCase {
    func testWakesOnlyWhatLooksAsleep() {
        XCTAssertTrue(AgentConnection.mightBeAsleep(.posix(.ETIMEDOUT)))
        XCTAssertTrue(AgentConnection.mightBeAsleep(.posix(.EHOSTDOWN)))
        XCTAssertTrue(AgentConnection.mightBeAsleep(.posix(.EHOSTUNREACH)))
        XCTAssertFalse(AgentConnection.mightBeAsleep(.posix(.ECONNREFUSED)))
        XCTAssertFalse(AgentConnection.mightBeAsleep(.posix(.ENETUNREACH)))
        XCTAssertFalse(AgentConnection.mightBeAsleep(.dns(-65554)))
    }
}
