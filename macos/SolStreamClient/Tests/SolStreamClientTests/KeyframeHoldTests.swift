import XCTest
@testable import MediaSession

/// Which pictures reach the decoder after loss, and when the host is asked for
/// a keyframe. Frame ids and clock readings only: no socket, no decoder.
final class KeyframeHoldTests: XCTestCase {

    /// An arbitrary uptime, so a stamp of zero is never mistaken for "now".
    private let t0: UInt64 = 5_000_000_000

    private func ms(_ milliseconds: Double) -> UInt64 {
        t0 + UInt64(milliseconds * 1_000_000)
    }

    func testDamageHoldsPFramesAndAsksOncePerBurst() {
        var hold = KeyframeHold()
        XCTAssertEqual(hold.picture(frameId: 1, isIdr: true, now: ms(0)), .decode)
        XCTAssertEqual(hold.picture(frameId: 2, isIdr: false, now: ms(16)), .decode)

        // A run of three lost at once is one request, not three.
        XCTAssertEqual(hold.damaged(frameId: 3, now: ms(40)), .holdAndAsk)
        XCTAssertEqual(hold.damaged(frameId: 4, now: ms(41)), .hold)
        XCTAssertEqual(hold.damaged(frameId: 5, now: ms(45)), .hold)
        XCTAssertEqual(hold.picture(frameId: 6, isIdr: false, now: ms(50)), .hold)
        XCTAssertTrue(hold.holding)

        // The IDR ends it, and what follows it is decoded again.
        XCTAssertEqual(hold.picture(frameId: 7, isIdr: true, now: ms(80)), .decode)
        XCTAssertEqual(hold.picture(frameId: 8, isIdr: false, now: ms(96)), .decode)
        XCTAssertFalse(hold.holding)
    }

    /// The late report: the picture just before the IDR times out after the IDR
    /// has already landed. It used to put the hold back on and freeze every
    /// picture after a good IDR until the next one.
    func testDamageOlderThanTheIdrThatRepairedItIsIgnored() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 5, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 6, now: ms(100)), .holdAndAsk)
        XCTAssertEqual(hold.picture(frameId: 10, isIdr: true, now: ms(130)), .decode)

        XCTAssertEqual(hold.damaged(frameId: 9, now: ms(150)), .ignore)
        XCTAssertFalse(hold.holding)
        XCTAssertEqual(hold.picture(frameId: 11, isIdr: false, now: ms(160)), .decode)
        XCTAssertFalse(hold.reaskDue(now: ms(600), rttMs: 0), "nothing is owed, so nothing is asked")
    }

    func testDamageAfterTheIdrStillHolds() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 10, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 12, now: ms(40)), .holdAndAsk)
        XCTAssertEqual(hold.picture(frameId: 13, isIdr: false, now: ms(50)), .hold)
    }

    func testTheRequestIsRepeatedEveryQuarterSecondUntilAnIdrArrives() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertFalse(hold.reaskDue(now: ms(10), rttMs: 0), "not holding: nothing to repeat")

        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(100)), .holdAndAsk)
        XCTAssertFalse(hold.reaskDue(now: ms(300), rttMs: 0))
        XCTAssertTrue(hold.reaskDue(now: ms(351), rttMs: 0))
        XCTAssertFalse(hold.reaskDue(now: ms(400), rttMs: 0))
        XCTAssertTrue(hold.reaskDue(now: ms(602), rttMs: 0))

        _ = hold.picture(frameId: 9, isIdr: true, now: ms(650))
        XCTAssertFalse(hold.reaskDue(now: ms(2000), rttMs: 0))
    }

    /// A session opens holding, and asks at once. Before the first IDR there is
    /// nothing a P-frame could be decoded against.
    func testNothingIsDecodedBeforeTheFirstIdrAndTheFirstRequestIsImmediate() {
        var hold = KeyframeHold()
        XCTAssertTrue(hold.holding)
        XCTAssertTrue(hold.reaskDue(now: ms(0), rttMs: 0), "the opening request")
        XCTAssertFalse(hold.reaskDue(now: ms(10), rttMs: 0))

        XCTAssertEqual(hold.picture(frameId: 3, isIdr: false, now: ms(20)), .hold)
        XCTAssertEqual(hold.picture(frameId: 4, isIdr: false, now: ms(36)), .hold)
        XCTAssertTrue(hold.reaskDue(now: ms(251), rttMs: 0))

        XCTAssertEqual(hold.picture(frameId: 5, isIdr: true, now: ms(260)), .decode)
        XCTAssertEqual(hold.picture(frameId: 6, isIdr: false, now: ms(276)), .decode)
    }

    /// A P-frame whose predecessor never reached the decoder is not decoded,
    /// even if nothing reported the predecessor lost.
    func testOnlyThePictureStraightAfterTheLastOneDecodedIsDecoded() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.picture(frameId: 2, isIdr: false, now: ms(16)), .decode)
        XCTAssertEqual(hold.picture(frameId: 4, isIdr: false, now: ms(48)), .holdAndAsk)
        XCTAssertEqual(hold.picture(frameId: 5, isIdr: false, now: ms(64)), .hold)
        XCTAssertEqual(hold.picture(frameId: 6, isIdr: true, now: ms(90)), .decode)
        XCTAssertEqual(hold.picture(frameId: 7, isIdr: false, now: ms(106)), .decode)
    }

    func testAPictureOlderThanOneAlreadyDecodedIsIgnored() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 5, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.picture(frameId: 6, isIdr: false, now: ms(16)), .decode)
        XCTAssertEqual(hold.picture(frameId: 4, isIdr: false, now: ms(20)), .ignore)
        XCTAssertFalse(hold.holding)
        XCTAssertEqual(hold.picture(frameId: 7, isIdr: false, now: ms(32)), .decode)
    }

    /// Over a relayed path the IDR is still landing when a quarter-second is
    /// up. Its fragments count as the answer, so the request is not repeated
    /// into the middle of it.
    func testARequestIsNotRepeatedWhileItsIdrIsArriving() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(0)), .holdAndAsk)
        hold.idrArriving(frameId: 5, now: ms(200))
        hold.idrArriving(frameId: 5, now: ms(260))
        XCTAssertFalse(hold.reaskDue(now: ms(300), rttMs: 180))
        hold.idrArriving(frameId: 5, now: ms(320))
        XCTAssertFalse(hold.reaskDue(now: ms(400), rttMs: 180))
        XCTAssertEqual(hold.picture(frameId: 5, isIdr: true, now: ms(330)), .decode)
        XCTAssertFalse(hold.reaskDue(now: ms(900), rttMs: 180))
    }

    /// An IDR whose fragments stop coming is asked for again, counted from the
    /// last fragment rather than from the request.
    func testAnIdrThatStopsArrivingIsAskedForAgain() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(0)), .holdAndAsk)
        hold.idrArriving(frameId: 5, now: ms(200))
        XCTAssertFalse(hold.reaskDue(now: ms(449), rttMs: 0))
        XCTAssertTrue(hold.reaskDue(now: ms(451), rttMs: 0))
    }

    /// The IDR itself broke on the way: that is asked for at once, not left to
    /// the repeat.
    func testAnIdrThatBrokeOnTheWayIsAskedForAtOnce() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(0)), .holdAndAsk)
        hold.idrArriving(frameId: 5, now: ms(200))
        XCTAssertEqual(hold.damaged(frameId: 5, now: ms(230)), .holdAndAsk)
        // And it no longer counts as on its way.
        XCTAssertTrue(hold.reaskDue(now: ms(481), rttMs: 0))
    }

    /// Damage older than an IDR that is already arriving needs no request of
    /// its own; the IDR repairs it.
    func testDamageOlderThanAnArrivingIdrIsIgnored() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(0)), .holdAndAsk)
        hold.idrArriving(frameId: 6, now: ms(200))
        XCTAssertEqual(hold.damaged(frameId: 4, now: ms(240)), .ignore)
        XCTAssertTrue(hold.holding)
    }

    /// An IDR that nobody is waiting for -- the host's own -- is not progress on
    /// anything, and damage after it is still asked about.
    func testAnIdrArrivingWhileNotHoldingChangesNothing() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        hold.idrArriving(frameId: 4, now: ms(10))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(20)), .holdAndAsk)
    }

    /// Where a round trip is longer than the quarter-second, the repeat waits
    /// for the answer to have had time to start.
    func testALongRoundTripWaitsLongerBeforeAskingAgain() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(0)), .holdAndAsk)
        XCTAssertFalse(hold.reaskDue(now: ms(300), rttMs: 300))
        XCTAssertFalse(hold.reaskDue(now: ms(399), rttMs: 300))
        XCTAssertTrue(hold.reaskDue(now: ms(401), rttMs: 300))
    }

    /// The clock is read before the lock is taken, so `now` can be older than a
    /// stamp another thread has just written. That must read as no time at all
    /// rather than trap.
    func testAClockReadingOlderThanTheLastRequestDoesNotTrap() {
        var hold = KeyframeHold()
        _ = hold.picture(frameId: 1, isIdr: true, now: ms(0))
        XCTAssertEqual(hold.damaged(frameId: 2, now: ms(100)), .holdAndAsk)
        XCTAssertEqual(hold.damaged(frameId: 3, now: ms(99)), .hold)
        XCTAssertFalse(hold.reaskDue(now: ms(50), rttMs: 0))
    }
}

/// The reassembler and the hold together, as MediaClient wires them, fed
/// synthetic datagrams.
final class VideoRecoveryPipelineTests: XCTestCase {

    private final class Pipeline {
        let reassembler = VideoReassembler()
        var hold = KeyframeHold()
        var decoded: [UInt32] = []
        var asks = 0

        init() {
            reassembler.onPicture = { [unowned self] picture in
                let now = DispatchTime.now().uptimeNanoseconds
                if self.hold.picture(frameId: picture.frameId, isIdr: picture.isIdr,
                                     now: now) == .decode {
                    self.decoded.append(picture.frameId)
                }
            }
            reassembler.onDamaged = { [unowned self] frameId in
                let now = DispatchTime.now().uptimeNanoseconds
                if self.hold.damaged(frameId: frameId, now: now) == .holdAndAsk {
                    self.asks += 1
                }
            }
            reassembler.onIdrFragment = { [unowned self] frameId in
                self.hold.idrArriving(frameId: frameId,
                                      now: DispatchTime.now().uptimeNanoseconds)
            }
        }

        func send(_ frameId: UInt32, fragment: Int = 0, of count: Int = 1, idr: Bool = false) {
            let payload = Data(repeating: UInt8(frameId & 0xFF), count: 1000)
            var packet = Data()
            packet.append(SMT.typeVideo)
            var flags: UInt8 = 0
            if fragment == 0 { flags |= SMT.flagFrameStart }
            if fragment == count - 1 { flags |= SMT.flagFrameEnd }
            if idr { flags |= SMT.flagIdr }
            packet.append(flags)
            packet.append(0xF0)
            packet.append(0)
            packet.append(SMTPacket.be(UInt64(frameId), 4))
            packet.append(SMTPacket.be(UInt64(fragment * 1000), 3))
            packet.append(0)
            packet.append(SMTPacket.be(1234, 4))
            packet.append(payload)
            reassembler.ingest(packet)
        }
    }

    /// One datagram of a moving picture lost: the next picture is held, never
    /// decoded against the reference that did not arrive.
    func testAPictureAfterAPartlyLostOneIsHeldUntilTheIdr() {
        let pipe = Pipeline()
        pipe.send(1, idr: true)
        pipe.send(2)
        pipe.send(3, fragment: 0, of: 2)        // its second datagram is lost
        pipe.send(4)
        pipe.send(5)
        XCTAssertEqual(pipe.decoded, [1, 2])
        XCTAssertEqual(pipe.asks, 1)

        pipe.send(6, idr: true)
        pipe.send(7)
        XCTAssertEqual(pipe.decoded, [1, 2, 6, 7])
    }

    /// A burst takes 6-8 whole and part of 9, and the IDR asked for lands
    /// before 9 could have timed out. Nothing after the IDR is held.
    func testABurstEndingPartWayThroughAPictureDoesNotHoldPastTheIdr() {
        let pipe = Pipeline()
        for frame: UInt32 in 1...5 { pipe.send(frame, idr: frame == 1) }
        pipe.send(9, fragment: 1, of: 2)        // 6-8 lost whole, 9's head lost
        XCTAssertEqual(pipe.asks, 1)
        pipe.send(10, fragment: 0, of: 3, idr: true)
        pipe.send(10, fragment: 1, of: 3, idr: true)
        pipe.send(10, fragment: 2, of: 3, idr: true)
        pipe.send(11)
        pipe.send(12)
        XCTAssertEqual(pipe.decoded, [1, 2, 3, 4, 5, 10, 11, 12])

        // And the idle timer has nothing left to report about 9.
        usleep(40_000)
        pipe.reassembler.tick()
        pipe.send(13)
        XCTAssertEqual(pipe.decoded, [1, 2, 3, 4, 5, 10, 11, 12, 13])
        XCTAssertEqual(pipe.asks, 1)
    }

    /// The host's first IDR went nowhere, because it was encoded before the
    /// Mac had said where it was, so the session's first pictures are
    /// P-frames. None of them reaches the decoder.
    func testPFramesBeforeTheFirstIdrAreHeld() {
        let pipe = Pipeline()
        pipe.send(2)
        pipe.send(3)
        XCTAssertEqual(pipe.decoded, [])
        pipe.send(4, idr: true)
        pipe.send(5)
        XCTAssertEqual(pipe.decoded, [4, 5])
    }

    /// A datagram of a picture older than the IDR turns up after the IDR has
    /// been decoded, and times out. Its report comes after the repair, and is
    /// ignored rather than freezing the pictures that follow.
    func testALateReportAboutAPictureBeforeTheIdrIsIgnored() {
        let pipe = Pipeline()
        pipe.send(1, idr: true)
        pipe.send(2)
        pipe.send(5, idr: true)                 // the host dropped 3 and 4 itself
        pipe.send(4, fragment: 1, of: 2)        // a straggler of one it never finished
        usleep(40_000)
        pipe.reassembler.tick()
        pipe.send(6)
        XCTAssertEqual(pipe.decoded, [1, 2, 5, 6])
        XCTAssertEqual(pipe.asks, 0)
    }
}
