import XCTest
import CryptoKit
@testable import MediaSession

/// SMT/1, checked where it is cheapest to check: before a socket is involved.
///
/// The first test is the important one. It reproduces the frozen vector from
/// `spike/smt-vectors` — the same fixed scalars, nonces, host count and token —
/// and asserts the exact datagram both languages must produce. If the Mac's key
/// schedule and the Windows agent's ever drift apart, every packet fails its
/// authentication tag and there is nothing in any log to say why; this fails
/// first, in `swift test`, with a hex string to compare.
final class SMTVectorTests: XCTestCase {

    /// The scalars are 0x11… and 0x22… repeated rather than random, because a
    /// vector nobody can retype by hand is a vector nobody checks.
    private func fixedKeys() throws -> MediaKeys {
        let clientPriv = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32))
        let hostPriv = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32))
        let secret = try clientPriv.sharedSecretFromKeyAgreement(with: hostPriv.publicKey)

        let keys = MediaKeySchedule.derive(
            clientPublic: clientPriv.publicKey.x963Representation,
            hostPublic: hostPriv.publicKey.x963Representation,
            clientNonce: Data(repeating: 0xAA, count: 32),
            hostNonce: Data(repeating: 0xBB, count: 32),
            hostCount: 42,
            secret: secret.withUnsafeBytes { Data($0) },
            token: "00112233445566778899aabbccddeeff")
        return try XCTUnwrap(keys)
    }

    func testTheFrozenDatagramIsStillProduced() throws {
        let keys = try fixedKeys()
        let direction = SMTDirection(key: keys.hostToClient, fixed: keys.fixedHostToClient)
        let plaintext = Data([0x01]) + Data("SMT/1 ping".utf8)

        // Counter 0 first: the vector is the SECOND datagram, sealed under
        // counter 1, which is also what proves the counter advances.
        _ = SMTPacket.seal(plaintext, direction: direction, sessionTag: keys.sessionTag)
        let datagram = try XCTUnwrap(
            SMTPacket.seal(plaintext, direction: direction, sessionTag: keys.sessionTag))

        XCTAssertEqual(datagram.smtHex,
                       "106200000000000197a994e89c72a402aad58804a5822a0168d97fe393aefa275679b3")
    }

    func testTheSessionTagIsTheLowByteOfTheSessionId() throws {
        let keys = try fixedKeys()
        XCTAssertEqual(keys.sessionTag, UInt8(keys.sessionId & 0xFF))
        XCTAssertEqual(keys.sessionTag, 0x62)
    }

    func testHostAndClientAuthDiffer() throws {
        let keys = try fixedKeys()
        XCTAssertEqual(keys.hostAuth.count, 12)
        XCTAssertEqual(keys.clientAuth.count, 12)
        XCTAssertNotEqual(keys.hostAuth, keys.clientAuth,
                          "one value proving both directions would prove nothing")
    }

    func testAWrongTokenDerivesDifferentKeys() throws {
        let clientPriv = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x11, count: 32))
        let hostPriv = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(repeating: 0x22, count: 32))
        let secret = try clientPriv.sharedSecretFromKeyAgreement(with: hostPriv.publicKey)
            .withUnsafeBytes { Data($0) }

        func derive(token: String) -> MediaKeys? {
            MediaKeySchedule.derive(clientPublic: clientPriv.publicKey.x963Representation,
                                    hostPublic: hostPriv.publicKey.x963Representation,
                                    clientNonce: Data(repeating: 0xAA, count: 32),
                                    hostNonce: Data(repeating: 0xBB, count: 32),
                                    hostCount: 42, secret: secret, token: token)
        }
        let right = try XCTUnwrap(derive(token: "00112233445566778899aabbccddeeff"))
        let wrong = try XCTUnwrap(derive(token: "00112233445566778899aabbccddeef0"))
        // The token is INPUT KEY MATERIAL, not merely transcript, which is what
        // makes a stolen token useless against a session that has ended.
        XCTAssertNotEqual(right.hostAuth, wrong.hostAuth)
    }
}

final class SMTPacketTests: XCTestCase {

    private func direction(_ byte: UInt8) -> SMTDirection {
        SMTDirection(key: SymmetricKey(data: Data(repeating: byte, count: 32)),
                     fixed: Data(repeating: byte &+ 1, count: 6))
    }

    func testSealAndOpenRoundTrip() throws {
        let send = direction(0x01)
        let receive = direction(0x01)
        var window = SMTReplayWindow()
        let plaintext = Data([SMT.typeVideo]) + Data("hello".utf8)

        let datagram = try XCTUnwrap(SMTPacket.seal(plaintext, direction: send,
                                                    sessionTag: 0x5A))
        let opened = try XCTUnwrap(SMTPacket.open(datagram, direction: receive,
                                                  window: &window))
        XCTAssertEqual(opened.0, plaintext)
        XCTAssertEqual(opened.1, 0)
        XCTAssertEqual(datagram.count, plaintext.count + SMT.overhead)
    }

    func testTheHeaderIsAuthenticated() throws {
        let send = direction(0x02)
        let receive = direction(0x02)
        var window = SMTReplayWindow()
        var datagram = try XCTUnwrap(SMTPacket.seal(Data([SMT.typePing]),
                                                    direction: send, sessionTag: 0x11))
        // Flip the session tag. It is a demux hint and never an authority, and
        // the reason it can never become one is that it is the AAD.
        datagram[datagram.startIndex + 1] ^= 0xFF
        XCTAssertNil(SMTPacket.open(datagram, direction: receive, window: &window))
    }

    func testAnotherKeyCannotOpenIt() throws {
        let send = direction(0x03)
        let other = direction(0x04)
        var window = SMTReplayWindow()
        let datagram = try XCTUnwrap(SMTPacket.seal(Data([SMT.typePing]),
                                                    direction: send, sessionTag: 0))
        XCTAssertNil(SMTPacket.open(datagram, direction: other, window: &window))
    }

    func testTheCounterAdvancesAndIsOnTheWire() throws {
        let send = direction(0x05)
        var seen: [UInt64] = []
        for _ in 0..<3 {
            let datagram = try XCTUnwrap(SMTPacket.seal(Data([SMT.typePing]),
                                                        direction: send, sessionTag: 0))
            seen.append(SMTPacket.readBE([UInt8](datagram)[2..<8]))
        }
        XCTAssertEqual(seen, [0, 1, 2])
    }
}

final class SMTReplayWindowTests: XCTestCase {

    func testARepeatIsRejected() {
        var window = SMTReplayWindow()
        XCTAssertFalse(window.seenOrTooOld(7))
        window.record(7)
        XCTAssertTrue(window.seenOrTooOld(7))
    }

    func testReorderingWithinTheWindowIsAccepted() {
        var window = SMTReplayWindow()
        window.record(100)
        // 98 arrived late, which is reordering rather than replay.
        XCTAssertFalse(window.seenOrTooOld(98))
        window.record(98)
        XCTAssertTrue(window.seenOrTooOld(98))
        XCTAssertFalse(window.seenOrTooOld(99))
    }

    func testAnythingOlderThanTheWindowIsRejected() {
        var window = SMTReplayWindow()
        window.record(5000)
        XCTAssertTrue(window.seenOrTooOld(5000 - 1024))
        XCTAssertFalse(window.seenOrTooOld(5000 - 1023))
    }

    func testASlideDoesNotForgetTheRecentPast() {
        var window = SMTReplayWindow()
        window.record(10)
        window.record(11)
        window.record(500)
        XCTAssertTrue(window.seenOrTooOld(10))
        XCTAssertTrue(window.seenOrTooOld(11))
        XCTAssertFalse(window.seenOrTooOld(12))
    }
}

final class VideoReassemblyTests: XCTestCase {

    private func fragment(frameId: UInt32, offset: Int, payload: Data,
                          start: Bool, end: Bool, idr: Bool = false,
                          captureUs: UInt32 = 1234) -> Data {
        var packet = Data(capacity: 16 + payload.count)
        packet.append(SMT.typeVideo)
        var flags: UInt8 = 0
        if start { flags |= SMT.flagFrameStart }
        if end { flags |= SMT.flagFrameEnd }
        if idr { flags |= SMT.flagIdr }
        packet.append(flags)
        packet.append(0xF0)
        packet.append(0)
        packet.append(SMTPacket.be(UInt64(frameId), 4))
        packet.append(SMTPacket.be(UInt64(offset), 3))
        packet.append(0)
        packet.append(SMTPacket.be(UInt64(captureUs), 4))
        packet.append(payload)
        return packet
    }

    func testOneFragmentIsOnePicture() {
        let reassembler = VideoReassembler()
        var pictures: [VideoReassembler.Picture] = []
        reassembler.onPicture = { pictures.append($0) }

        let payload = Data((0..<200).map { UInt8($0 % 251) })
        reassembler.ingest(fragment(frameId: 1, offset: 0, payload: payload,
                                    start: true, end: true, idr: true))
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.bytes, payload)
        XCTAssertEqual(pictures.first?.isIdr, true)
        XCTAssertEqual(reassembler.lastCompleteFrame, 1)
    }

    func testFragmentsReassembleByByteOffset() {
        let reassembler = VideoReassembler()
        var pictures: [VideoReassembler.Picture] = []
        reassembler.onPicture = { pictures.append($0) }

        let whole = Data((0..<3000).map { UInt8($0 % 251) })
        let first = whole.prefix(1432)
        let second = whole.dropFirst(1432).prefix(1432)
        let third = whole.dropFirst(2864)

        reassembler.ingest(fragment(frameId: 9, offset: 0, payload: first,
                                    start: true, end: false))
        reassembler.ingest(fragment(frameId: 9, offset: 1432, payload: second,
                                    start: false, end: false))
        XCTAssertTrue(pictures.isEmpty, "a picture must not close before its end flag")
        reassembler.ingest(fragment(frameId: 9, offset: 2864, payload: third,
                                    start: false, end: true))
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.bytes, whole)
    }

    /// The offset is a BYTE offset, not a fragment index, so fragments that
    /// arrive backwards need no reordering machinery at all.
    func testFragmentsMayArriveOutOfOrder() {
        let reassembler = VideoReassembler()
        var pictures: [VideoReassembler.Picture] = []
        reassembler.onPicture = { pictures.append($0) }

        let whole = Data((0..<2000).map { UInt8(($0 * 7) % 251) })
        reassembler.ingest(fragment(frameId: 3, offset: 1000,
                                    payload: whole.dropFirst(1000),
                                    start: false, end: true))
        XCTAssertTrue(pictures.isEmpty)
        reassembler.ingest(fragment(frameId: 3, offset: 0, payload: whole.prefix(1000),
                                    start: true, end: false))
        XCTAssertEqual(pictures.count, 1)
        XCTAssertEqual(pictures.first?.bytes, whole)
    }

    func testAStragglerAfterCompletionIsIgnored() {
        let reassembler = VideoReassembler()
        var pictures = 0
        reassembler.onPicture = { _ in pictures += 1 }
        let payload = Data(repeating: 7, count: 64)
        reassembler.ingest(fragment(frameId: 4, offset: 0, payload: payload,
                                    start: true, end: true))
        reassembler.ingest(fragment(frameId: 4, offset: 0, payload: payload,
                                    start: true, end: true))
        XCTAssertEqual(pictures, 1, "a repeated fragment must not emit a second picture")
    }

    /// The closure timer runs from the LAST fragment, not the first: an IDR on a
    /// 20 Mbit/s path takes 80–160 ms to arrive, so a timer started at its first
    /// fragment declares it damaged before it has landed and asks for a bigger
    /// one. Nothing may be retired while fragments are still arriving.
    func testAnIncompletePictureIsNotRetiredWhileFragmentsArrive() {
        let reassembler = VideoReassembler()
        var damaged: [UInt32] = []
        reassembler.onDamaged = { damaged.append($0) }
        reassembler.ingest(fragment(frameId: 5, offset: 0,
                                    payload: Data(repeating: 1, count: 1432),
                                    start: true, end: false))
        reassembler.tick()
        XCTAssertTrue(damaged.isEmpty)
    }

    func testAPictureLargerThanTheBufferIsReportedRatherThanCrashing() {
        let reassembler = VideoReassembler()
        var damaged: [UInt32] = []
        reassembler.onDamaged = { damaged.append($0) }
        reassembler.ingest(fragment(frameId: 6, offset: 524_000,
                                    payload: Data(repeating: 2, count: 1432),
                                    start: false, end: true))
        XCTAssertEqual(damaged, [6])
    }
}

final class SMTInputTests: XCTestCase {

    func testAnEventIsKindLengthBody() {
        let event = SMTInput.mouseButton(.right, pressed: true)
        XCTAssertEqual([UInt8](event), [SMTInput.Kind.button.rawValue, 2, 3, 1])
    }

    /// Absolute positions go on the wire as a fraction of the picture, so a
    /// window the host resizes needs no renegotiation for the pointer to keep
    /// landing in the right place.
    func testAbsolutePositionsAreNormalised() {
        let middle = SMTInput.mouseMoveAbsolute(x: 50, y: 25,
                                                referenceWidth: 100, referenceHeight: 50)
        let bytes = [UInt8](middle)
        XCTAssertEqual(bytes[0], SMTInput.Kind.mouseAbs.rawValue)
        XCTAssertEqual(bytes[1], 4)
        let nx = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let ny = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        XCTAssertEqual(nx, 32767)
        XCTAssertEqual(ny, 32767)
    }

    func testPositionsOutsideThePictureAreClamped() {
        let past = SMTInput.mouseMoveAbsolute(x: 500, y: -20,
                                              referenceWidth: 100, referenceHeight: 50)
        let bytes = [UInt8](past)
        XCTAssertEqual(UInt16(bytes[2]) << 8 | UInt16(bytes[3]), 65535)
        XCTAssertEqual(UInt16(bytes[4]) << 8 | UInt16(bytes[5]), 0)
    }

    func testDegenerateReferenceRectanglesDoNotDivideByZero() {
        let event = SMTInput.mouseMoveAbsolute(x: 10, y: 10,
                                               referenceWidth: 0, referenceHeight: 0)
        XCTAssertEqual(event.count, 6)
    }

    func testKeyEventsCarryTheVirtualKeyBigEndian() {
        let event = SMTInput.key(code: 0x1234, pressed: false, modifiers: [.control])
        XCTAssertEqual([UInt8](event),
                       [SMTInput.Kind.key.rawValue, 4, 0x12, 0x34, 0, 0x02])
    }

    func testScrollIsSignedAndBigEndian() {
        let up = SMTInput.scroll(amount: 120)
        XCTAssertEqual([UInt8](up), [SMTInput.Kind.scrollV.rawValue, 2, 0x00, 0x78])
        let down = SMTInput.scroll(amount: -120)
        XCTAssertEqual([UInt8](down), [SMTInput.Kind.scrollV.rawValue, 2, 0xFF, 0x88])
    }
}
