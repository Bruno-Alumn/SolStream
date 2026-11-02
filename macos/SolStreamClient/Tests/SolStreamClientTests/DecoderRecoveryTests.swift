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

    /// A Mac that cannot decode the stream fails on every IDR. Asking for the
    /// next one at once after each made the host send five a second for as
    /// long as the window stayed open; after the first, each wait doubles.
    func testIdrsThatKeepFailingAreAskedForLessOften() {
        var recovery = SessionRecovery()
        XCTAssertEqual(recovery.keyframeWait(0.5), 0)

        XCTAssertTrue(recovery.admit(isIdr: true))
        XCTAssertTrue(recovery.sessionDropped(beforeIdr: false))
        XCTAssertEqual(recovery.keyframeWait(0.5), 0, "one bad IDR is a glitch: ask at once")

        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            XCTAssertTrue(recovery.admit(isIdr: true))
            XCTAssertTrue(recovery.sessionDropped(beforeIdr: false))
            waits.append(recovery.keyframeWait(0.5))
        }
        XCTAssertEqual(waits, [0.5, 1, 2, 4, 8, 10, 10, 10])
    }

    /// Any picture out of the session means the stream decodes: the next
    /// failure is a glitch again, asked about at once.
    func testAPictureEndsTheBackOff() {
        var recovery = SessionRecovery()
        for _ in 0..<4 {
            _ = recovery.admit(isIdr: true)
            _ = recovery.sessionDropped(beforeIdr: false)
        }
        XCTAssertGreaterThan(recovery.keyframeWait(0.5), 0)
        recovery.pictureDecoded()
        XCTAssertEqual(recovery.failedKeyframes, 0)
        _ = recovery.admit(isIdr: true)
        _ = recovery.sessionDropped(beforeIdr: false)
        XCTAssertEqual(recovery.keyframeWait(0.5), 0)
    }

    /// A healthy stream's IDRs, each followed by pictures, never back off.
    func testAHealthyStreamNeverWaits() {
        var recovery = SessionRecovery()
        for _ in 0..<10 {
            XCTAssertTrue(recovery.admit(isIdr: true))
            recovery.pictureDecoded()
            XCTAssertTrue(recovery.admit(isIdr: false))
        }
        XCTAssertEqual(recovery.keyframeWait(0.5), 0)
    }

    /// IDRs that found no session to decode in failed to build, which has its
    /// own back-off; they are not this Mac failing to decode the stream.
    func testIdrsThatNeverReachedASessionDoNotCount() {
        var recovery = SessionRecovery()
        for _ in 0..<5 {
            XCTAssertTrue(recovery.admit(isIdr: true))
            recovery.keyframeNotTried()
        }
        XCTAssertEqual(recovery.failedKeyframes, 0)
        _ = recovery.admit(isIdr: true)
        _ = recovery.sessionDropped(beforeIdr: false)
        XCTAssertEqual(recovery.keyframeWait(0.5), 0, "the first real failure is asked about at once")
    }
}
