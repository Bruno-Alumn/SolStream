import XCTest
import VideoToolbox
@testable import MediaSession
@testable import VideoDecoder

/// What the decoder does after a failure that cost it its session, in statuses
/// and keyframe flags: no VideoToolbox session is made.
final class DecoderRecoveryTests: XCTestCase {

    func testTheStatusesThatNeedANewSession() {
        XCTAssertTrue(SessionRecovery.dropsSession(kVTInvalidSessionErr))
        XCTAssertTrue(SessionRecovery.dropsSession(kVTVideoDecoderMalfunctionErr))
        XCTAssertTrue(SessionRecovery.dropsSession(kVTVideoDecoderBadDataErr))
        XCTAssertFalse(SessionRecovery.dropsSession(noErr))
        XCTAssertFalse(SessionRecovery.dropsSession(kVTVideoDecoderNotAvailableNowErr))
    }

    /// A rebuilt session has no reference pictures, so the P-frames after a
    /// failure are not decoded into it; each one used to fail and cost another
    /// session. The IDR is decoded and ends the wait.
    func testAfterAFailureOnlyAnIdrIsDecoded() {
        var recovery = SessionRecovery()
        XCTAssertTrue(recovery.admit(isIdr: false), "a healthy session takes anything")

        XCTAssertTrue(recovery.sessionDropped(beforeIdr: false), "asks for the IDR")
        XCTAssertTrue(recovery.awaitingIdr)
        XCTAssertFalse(recovery.admit(isIdr: false))
        XCTAssertFalse(recovery.admit(isIdr: false))

        XCTAssertTrue(recovery.admit(isIdr: true))
        XCTAssertFalse(recovery.awaitingIdr)
        XCTAssertTrue(recovery.admit(isIdr: false))
    }

    /// The previous picture's failure is found waiting just as an IDR is about
    /// to be decoded. The IDR rebuilds the session itself, so asking for
    /// another one would only bring a second IDR for nothing.
    func testAFailureFoundJustBeforeAnIdrAsksForNothing() {
        var recovery = SessionRecovery()
        XCTAssertFalse(recovery.sessionDropped(beforeIdr: true))
        XCTAssertFalse(recovery.awaitingIdr)
        XCTAssertTrue(recovery.admit(isIdr: true))
        XCTAssertTrue(recovery.admit(isIdr: false))
    }

    /// The same, while already waiting: the IDR still ends the wait.
    func testAnIdrEndsTheWaitEvenWithAFailureFoundBeforeIt() {
        var recovery = SessionRecovery()
        XCTAssertTrue(recovery.sessionDropped(beforeIdr: false))
        XCTAssertFalse(recovery.admit(isIdr: false))
        XCTAssertFalse(recovery.sessionDropped(beforeIdr: true))
        XCTAssertTrue(recovery.admit(isIdr: true))
        XCTAssertTrue(recovery.admit(isIdr: false))
    }

    /// The decoder's request holds P-frames back before they reach it, as
    /// damage does, and asks once per burst.
    func testADecoderThatLostItsReferencesHoldsPFramesUntilTheIdr() {
        let t0: UInt64 = 5_000_000_000
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: t0)
        XCTAssertEqual(hold.picture(frameId: 2, isIdr: false, now: t0 + 16_000_000), .decode)

        XCTAssertEqual(hold.lostReference(now: t0 + 20_000_000), .holdAndAsk)
        XCTAssertEqual(hold.lostReference(now: t0 + 25_000_000), .hold)
        XCTAssertEqual(hold.picture(frameId: 3, isIdr: false, now: t0 + 32_000_000), .hold)
        XCTAssertEqual(hold.picture(frameId: 4, isIdr: true, now: t0 + 60_000_000), .decode)
        XCTAssertEqual(hold.picture(frameId: 5, isIdr: false, now: t0 + 76_000_000), .decode)
    }
}
