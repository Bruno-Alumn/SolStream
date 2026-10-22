import XCTest
@testable import SolStreamClient

/// What the stream windows say when the picture is in trouble, given what the
/// agent channel is doing. See StreamTrouble.swift.
final class StreamNoticeTests: XCTestCase {

    private let host = "test-pc"

    func testTheChannelsOutlook() {
        XCTAssertEqual(AppDelegate.outlook(isConnected: true, willReconnect: true), .up)
        XCTAssertEqual(AppDelegate.outlook(isConnected: false, willReconnect: true), .returning)
        XCTAssertEqual(AppDelegate.outlook(isConnected: false, willReconnect: false), .gone)
        XCTAssertEqual(AppDelegate.outlook(isConnected: true, willReconnect: false), .gone,
                       "a channel being torn down for good is not up")
    }

    func testAMediaFailureWhileTheChannelComesBackSaysReconnectingNotStreamFailed() {
        let notice = AppDelegate.notice(for: .failed("The host stopped answering."),
                                        channel: .returning, host: host,
                                        canRestart: true, finalErrorShown: false)
        XCTAssertEqual(notice, .status(title: "Reconnecting…",
                                       detail: "Waiting for \(host) to answer"))
        // Even with the restarts used up: `onReconnected` counts afresh.
        XCTAssertEqual(AppDelegate.notice(for: .failed("x"), channel: .returning, host: host,
                                          canRestart: false, finalErrorShown: false), notice)
        XCTAssertEqual(AppDelegate.notice(for: .restartFailed(nil), channel: .returning,
                                          host: host, canRestart: false,
                                          finalErrorShown: false), notice)
        XCTAssertEqual(AppDelegate.notice(for: .lost, channel: .returning, host: host,
                                          canRestart: true, finalErrorShown: false), notice)
    }

    func testTheWatchdogNeverPaintsOverAFinalConnectionError() {
        for trouble: AppDelegate.StreamTrouble in [.stalled(seconds: 2), .lost,
                                                   .failed("The host stopped answering."),
                                                   .restartFailed(nil)] {
            XCTAssertEqual(AppDelegate.notice(for: trouble, channel: .gone, host: host,
                                              canRestart: true, finalErrorShown: true), .keep,
                           "\(trouble) replaced the reason the connection was lost")
        }
    }

    func testAChannelGoneWithoutSayingWhyStillLeavesTryAgain() {
        // A refusal that reported no reason: the windows must not be left on
        // a spinner nothing will ever clear.
        for trouble: AppDelegate.StreamTrouble in [.stalled(seconds: 2), .lost, .failed("x")] {
            guard case .error = AppDelegate.notice(for: trouble, channel: .gone, host: host,
                                                   canRestart: true, finalErrorShown: false) else {
                return XCTFail("\(trouble) with the channel gone did not end in an error")
            }
        }
    }

    func testWithTheChannelUpTheStreamIsRestartedUntilTheTriesRunOut() {
        XCTAssertEqual(AppDelegate.notice(for: .lost, channel: .up, host: host,
                                          canRestart: true, finalErrorShown: false), .restart)
        XCTAssertEqual(AppDelegate.notice(for: .failed("gone quiet"), channel: .up, host: host,
                                          canRestart: true, finalErrorShown: false), .restart)
        XCTAssertEqual(AppDelegate.notice(for: .failed("gone quiet"), channel: .up, host: host,
                                          canRestart: false, finalErrorShown: false),
                       .error(title: "Stream failed", detail: "gone quiet"))
        XCTAssertEqual(AppDelegate.notice(for: .restartFailed("no display"), channel: .up,
                                          host: host, canRestart: false, finalErrorShown: false),
                       .error(title: "Lost the stream", detail: "no display"))
        XCTAssertEqual(AppDelegate.notice(for: .restartFailed(nil), channel: .up,
                                          host: host, canRestart: false, finalErrorShown: false),
                       .error(title: "Lost the stream",
                              detail: "\(host) did not start streaming again."))
        XCTAssertEqual(AppDelegate.notice(for: .stalled(seconds: 3), channel: .up, host: host,
                                          canRestart: true, finalErrorShown: false),
                       .status(title: "Reconnecting…",
                               detail: "No picture for 3s — asking \(host) for a new frame"))
    }
}
