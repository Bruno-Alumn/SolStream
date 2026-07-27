import XCTest
@testable import StreamConnection
@testable import VideoDecoder
@testable import InputCapture

/// Checks the client against the exact byte layouts Sunshine puts on the wire.
///
/// The packets below are assembled the same way `videoBroadcastThread` in
/// Sunshine's `stream.cpp` assembles them, so a change that breaks
/// interoperability fails here instead of silently producing a black window.
final class ProtocolTests: XCTestCase {

    // MARK: - Helpers mirroring Sunshine's packetizer

    private static let headerSize = 32   // video_packet_raw_t
    private static let frameHeaderSize = 8  // video_short_frame_header_t

    /// Build the datagrams Sunshine would send for one encoded frame.
    ///
    /// - Parameters:
    ///   - annexB: the encoded frame, as the encoder produced it.
    ///   - packetSize: the client's advertised `x-nv-video[0].packetSize`.
    ///   - parityShards: how many (dummy) parity shards to append per block.
    private func packetize(annexB: Data,
                           frameIndex: UInt32,
                           isIDR: Bool,
                           packetSize: Int = 1024,
                           parityShards: Int = 2,
                           blockCount: Int = 1) -> [Data] {
        let blocksize = packetSize + 16                      // + MAX_RTP_HEADER_SIZE
        let payloadBlocksize = blocksize - Self.headerSize

        // video_short_frame_header_t
        var stream = Data([0x01, 0x00, 0x00, isIDR ? 2 : 1, 0x00, 0x00, 0x00, 0x00])
        stream.append(annexB)

        // `concat_and_insert` lays the frame out as whole blocksize chunks with
        // room reserved for each packet header, zero-padding only the very end.
        // Every FEC block is therefore already a whole number of shards.
        let totalShards = (stream.count + payloadBlocksize - 1) / payloadBlocksize
        stream.append(Data(repeating: 0, count: totalShards * payloadBlocksize - stream.count))

        // aligned_size, expressed in shards rather than bytes.
        let unalignedBytes = (totalShards * blocksize) / blockCount
        let shardsPerBlock = max(1, (unalignedBytes + blocksize - 1) / blocksize)

        var packets: [Data] = []

        for blockIndex in 0..<blockCount {
            let firstShard = blockIndex * shardsPerBlock
            guard firstShard < totalShards else { break }
            let dataShards = blockIndex == blockCount - 1
                ? totalShards - firstShard
                : min(shardsPerBlock, totalShards - firstShard)
            let blockStart: Int = stream.startIndex + firstShard * payloadBlocksize
            let blockEnd: Int = blockStart + dataShards * payloadBlocksize
            let block = Data(stream[blockStart..<blockEnd])

            for shard in 0..<(dataShards + parityShards) {
                var packet = Data(repeating: 0, count: Self.headerSize)

                // RTP header: 0x80 | FLAG_EXTENSION, big-endian sequence number.
                packet[0] = 0x90
                packet[2] = UInt8((shard >> 8) & 0xFF)
                packet[3] = UInt8(shard & 0xFF)

                // NV_VIDEO_PACKET, little-endian.
                let streamPacketIndex = UInt32(shard) << 8
                packet.replaceSubrange(16..<20, with: le32(streamPacketIndex))
                packet.replaceSubrange(20..<24, with: le32(frameIndex))
                var flags: UInt8 = 0x1                        // FLAG_CONTAINS_PIC_DATA
                if shard == 0 { flags |= 0x4 }                // FLAG_SOF
                if shard == dataShards - 1 { flags |= 0x2 }   // FLAG_EOF
                packet[24] = flags
                packet[26] = 0x10                             // multiFecFlags
                packet[27] = UInt8((blockIndex << 4) | ((blockCount - 1) << 6))
                let fecInfo = UInt32(shard) << 12 | UInt32(dataShards) << 22 | UInt32(20) << 4
                packet.replaceSubrange(28..<32, with: le32(fecInfo))

                if shard < dataShards {
                    let offset = shard * payloadBlocksize
                    packet.append(block[(block.startIndex + offset)..<(block.startIndex + offset + payloadBlocksize)])
                } else {
                    // Parity: contents are irrelevant, the client must ignore it.
                    packet.append(Data(repeating: 0xAB, count: payloadBlocksize))
                }
                packets.append(packet)
            }
        }
        return packets
    }

    private func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF),
              UInt8((value >> 8) & 0xFF),
              UInt8((value >> 16) & 0xFF),
              UInt8((value >> 24) & 0xFF)])
    }

    /// A stand-in encoded frame: SPS, PPS and a slice in Annex-B form.
    private func sampleAnnexBFrame(sliceBytes: Int) -> Data {
        var frame = Data()
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65])
        // Slice payload; avoid trailing zeros, which FEC padding is trimmed by.
        frame.append(Data((0..<sliceBytes).map { UInt8(($0 % 250) + 1) }))
        return frame
    }

    // MARK: - Depacketizer

    func testSingleBlockFrameIsReassembled() {
        let original = sampleAnnexBFrame(sliceBytes: 3000)
        let depacketizer = VideoDepacketizer()

        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        for packet in packetize(annexB: original, frameIndex: 7, isIDR: true) {
            depacketizer.ingest(packet)
        }

        XCTAssertEqual(received.count, 1, "one frame should come out")
        XCTAssertEqual(received.first?.frameIndex, 7)
        XCTAssertTrue(received.first?.isIDR == true)
        XCTAssertEqual(received.first?.annexB, original,
                       "reassembled frame must match the encoder's bytes exactly")
    }

    func testMultipleFecBlocksAreReassembledInOrder() {
        let original = sampleAnnexBFrame(sliceBytes: 9000)
        let depacketizer = VideoDepacketizer()

        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        for packet in packetize(annexB: original, frameIndex: 1, isIDR: true, blockCount: 3) {
            depacketizer.ingest(packet)
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.annexB, original)
    }

    /// Sunshine recomputes `fec_blocks_needed` per frame from the encoded size
    /// (stream.cpp), so a large IDR can use several FEC blocks and the small
    /// P-frame right after it only one. The per-frame block count must not leak
    /// from one frame into the next.
    func testSingleBlockFrameAfterMultiBlockFrame() {
        let depacketizer = VideoDepacketizer()
        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        let big = sampleAnnexBFrame(sliceBytes: 9000)
        for packet in packetize(annexB: big, frameIndex: 1, isIDR: true, blockCount: 3) {
            depacketizer.ingest(packet)
        }
        XCTAssertEqual(received.count, 1, "the multi-block frame should decode")

        // The very next frame, one block only — the common case.
        let small = sampleAnnexBFrame(sliceBytes: 1500)
        for packet in packetize(annexB: small, frameIndex: 2, isIDR: false, blockCount: 1) {
            depacketizer.ingest(packet)
        }

        XCTAssertEqual(received.count, 2,
                       "a single-block frame following a multi-block frame must not be withheld")
        XCTAssertEqual(received.last?.annexB, small)
        XCTAssertEqual(depacketizer.framesDropped, 0, "nothing was actually lost")
    }

    func testParityShardsAloneProduceNoFrame() {
        let depacketizer = VideoDepacketizer()
        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        let packets = packetize(annexB: sampleAnnexBFrame(sliceBytes: 3000),
                                frameIndex: 3, isIDR: true)
        // Feed only the last two (the parity shards).
        for packet in packets.suffix(2) {
            depacketizer.ingest(packet)
        }
        XCTAssertTrue(received.isEmpty, "parity shards must not be mistaken for data")
    }

    func testMissingDataShardDropsFrameAndAsksForKeyframe() {
        let depacketizer = VideoDepacketizer()
        var received: [VideoFrame] = []
        var lossReports = 0
        depacketizer.onFrame = { received.append($0) }
        depacketizer.onFrameLoss = { lossReports += 1 }

        var first = packetize(annexB: sampleAnnexBFrame(sliceBytes: 4000), frameIndex: 10, isIDR: true)
        first.removeFirst()  // lose one data shard
        for packet in first { depacketizer.ingest(packet) }

        XCTAssertTrue(received.isEmpty, "an incomplete frame must not be emitted")

        // The next frame arriving is what tells us the previous one is lost.
        for packet in packetize(annexB: sampleAnnexBFrame(sliceBytes: 2000), frameIndex: 11, isIDR: false) {
            depacketizer.ingest(packet)
        }
        XCTAssertEqual(received.count, 1, "the following frame still decodes")
        XCTAssertEqual(lossReports, 1, "loss should be reported so an IDR is requested")
    }

    /// After a /resume the host's previous session keeps sending until its ping
    /// timeout, so two encoders with independent frame numbering land on the
    /// same socket. Latching onto the higher number must not black out the
    /// stream permanently once the other one stops.
    func testFrameNumberingGoingBackwardsResynchronises() {
        let depacketizer = VideoDepacketizer()
        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        // A frame from the old, far-ahead session.
        for packet in packetize(annexB: sampleAnnexBFrame(sliceBytes: 2000),
                                frameIndex: 9000, isIDR: true) {
            depacketizer.ingest(packet)
        }
        XCTAssertEqual(received.count, 1)

        // The surviving session restarts numbering from 1. Every one of these
        // looks "stale" until the depacketizer gives up and resynchronises.
        for frame in 1...40 {
            for packet in packetize(annexB: sampleAnnexBFrame(sliceBytes: 2000),
                                    frameIndex: UInt32(frame), isIDR: frame == 1) {
                depacketizer.ingest(packet)
            }
        }

        XCTAssertGreaterThan(received.count, 1,
                             "must recover instead of rejecting the surviving stream forever")
    }

    func testStragglersFromAnEmittedFrameAreIgnored() {
        let depacketizer = VideoDepacketizer()
        var received: [VideoFrame] = []
        depacketizer.onFrame = { received.append($0) }

        let packets = packetize(annexB: sampleAnnexBFrame(sliceBytes: 2500), frameIndex: 42, isIDR: true)
        for packet in packets { depacketizer.ingest(packet) }
        for packet in packets { depacketizer.ingest(packet) }  // duplicates

        XCTAssertEqual(received.count, 1, "a replayed frame must not be emitted twice")
    }

    // MARK: - Annex-B handling

    func testAnnexBSplitFindsEveryNalUnit() {
        let frame = sampleAnnexBFrame(sliceBytes: 32)
        let units = VideoDecoder.splitAnnexB(frame)
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].first! & 0x1F, 7, "first NAL is SPS")
        XCTAssertEqual(units[1].first! & 0x1F, 8, "second NAL is PPS")
        XCTAssertEqual(units[2].first! & 0x1F, 5, "third NAL is an IDR slice")
    }

    func testAnnexBSplitHandlesThreeByteStartCodes() {
        var frame = Data([0x00, 0x00, 0x01, 0x67, 0x01, 0x02])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0x03])
        let units = VideoDecoder.splitAnnexB(frame)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0], Data([0x67, 0x01, 0x02]))
        XCTAssertEqual(units[1], Data([0x68, 0x03]))
    }

    // MARK: - Pairing identity

    func testCertificateSignatureIsExtractedFromDER() throws {
        let identity = ClientIdentity.shared
        let signature = try XCTUnwrap(ClientIdentity.extractCertificateSignature(identity.certDER))
        // A 2048-bit RSA signature.
        XCTAssertEqual(signature.count, 256)
        // This used to assert the first four bytes of the one certificate every
        // build shipped. Identities are minted per installation now, so there is
        // no fixed answer — but the signature is still the last element of the
        // certificate, so it has to be the DER's own tail. That catches the walk
        // stopping early and returning some other element, which is the failure
        // the hardcoded prefix was really guarding against.
        XCTAssertEqual(signature, identity.certDER.suffix(256))
    }

    func testClientIdentityLoadsAKeyThatCanSign() throws {
        let signature = try ClientIdentity.shared.sign(Data(repeating: 0x5A, count: 16))
        XCTAssertEqual(signature.count, 256)
    }

    // MARK: - RTSP parsing

    func testServerPortIsParsedFromTransportHeader() {
        let response = """
        RTSP/1.0 200 OK\r
        CSeq: 4\r
        Session: DEADBEEFCAFE;timeout = 90\r
        Transport: server_port=47998\r
        X-SS-Ping-Payload: 0123456789abcdef\r
        \r

        """
        XCTAssertEqual(StreamConnection.serverPort(in: response), 47998)
        XCTAssertEqual(StreamConnection.header(response, "X-SS-Ping-Payload"), "0123456789abcdef")
        XCTAssertEqual(StreamConnection.header(response, "Session"), "DEADBEEFCAFE;timeout = 90")
    }

    func testAppListIsParsed() {
        let xml = """
        <?xml version="1.0"?><root status_code="200">
        <App><IsHdrSupported>1</IsHdrSupported><AppTitle>Desktop</AppTitle><ID>881448767</ID></App>
        <App><IsHdrSupported>0</IsHdrSupported><AppTitle>Steam Big Picture</AppTitle><ID>1</ID></App>
        </root>
        """
        let apps = StreamConnection.parseApps(xml)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].name, "Desktop")
        XCTAssertEqual(apps[0].id, "881448767")
        XCTAssertEqual(apps[1].name, "Steam Big Picture")
    }
}

/// Byte-exact checks of the input packets against Sunshine's `Input.h` structs.
/// The header size field excludes itself, the magic is little-endian, and the
/// payload fields are big-endian except the keyboard key code — get any of
/// those backwards and the host silently ignores or misreads the event.
final class InputProtocolTests: XCTestCase {

    func testAbsoluteMouseMoveLayout() {
        let packet = InputProtocol.mouseMoveAbsolute(x: 100, y: 200,
                                                     referenceWidth: 1920,
                                                     referenceHeight: 1080)
        // 8-byte header + 10-byte body == sizeof(NV_ABS_MOUSE_MOVE_PACKET)
        XCTAssertEqual(packet.count, 18)
        XCTAssertEqual(packet.hexString,
                       "0000000e"    // size = 14 (BE), excludes itself
                       + "05000000"  // MOUSE_MOVE_ABS_MAGIC (LE)
                       + "0064"      // x = 100 (BE)
                       + "00c8"      // y = 200 (BE)
                       + "0000"      // unused
                       + "077f"      // width - 1 = 1919 (BE)
                       + "0437")     // height - 1 = 1079 (BE)
    }

    func testKeyboardLayout() {
        let packet = InputProtocol.key(code: 0x41, pressed: true, modifiers: .shift)
        XCTAssertEqual(packet.count, 14)  // sizeof(NV_KEYBOARD_PACKET)
        XCTAssertEqual(packet.hexString,
                       "0000000a"    // size = 10
                       + "03000000"  // KEY_DOWN_EVENT_MAGIC
                       + "00"        // flags
                       + "4100"      // keyCode = 0x41, LITTLE-endian here
                       + "01"        // MODIFIER_SHIFT
                       + "0000")     // zero2
    }

    func testKeyUpUsesItsOwnMagic() {
        let packet = InputProtocol.key(code: 0x41, pressed: false, modifiers: [])
        XCTAssertEqual(packet.hexString.dropFirst(8).prefix(8), "04000000")
    }

    func testMouseButtonLayout() {
        XCTAssertEqual(InputProtocol.mouseButton(.left, pressed: true).hexString,
                       "00000005" + "08000000" + "01")
        XCTAssertEqual(InputProtocol.mouseButton(.right, pressed: false).hexString,
                       "00000005" + "09000000" + "03")
    }

    func testScrollMirrorsBothAmounts() {
        let packet = InputProtocol.scroll(amount: 120)
        XCTAssertEqual(packet.hexString,
                       "0000000a" + "0a000000" + "0078" + "0078" + "0000")
    }

    func testReferenceRectNeverUnderflows() {
        // A zero-sized view must not produce -1 on the wire.
        let packet = InputProtocol.mouseMoveAbsolute(x: 0, y: 0,
                                                     referenceWidth: 0, referenceHeight: 0)
        XCTAssertEqual(packet.hexString.suffix(8), "00000000")
    }
}

/// The client picks which host display to park applications on. Getting this
/// wrong is not a visible error: it streams the real monitor instead, and every
/// crop then shows whatever the user happens to have open there.
final class DisplaySelectionTests: XCTestCase {

    private func display(_ name: String, adapter: String,
                         primary: Bool = false,
                         width: Int = 1920, height: Int = 1080) -> RemoteDisplay {
        RemoteDisplay(name: name, adapter: adapter, x: 0, y: 0,
                      width: width, height: height, isPrimary: primary)
    }

    func testVirtualDisplayIsRecognisedByAdapter() {
        XCTAssertTrue(display("\\\\.\\DISPLAY6", adapter: "Virtual Display Driver").isVirtual)
        XCTAssertTrue(display("\\\\.\\DISPLAY2", adapter: "IddSampleDriver Device").isVirtual)
    }

    func testPhysicalAdapterIsNotVirtual() {
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "NVIDIA GeForce RTX 4070 SUPER").isVirtual)
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "Radeon RX 580 Series").isVirtual)
    }

    /// An agent that predates the `adapter` field must not have every display
    /// silently classed as virtual.
    func testMissingAdapterIsNotVirtual() {
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "").isVirtual)
    }
}

/// The pointer is mapped onto the picture, not onto the view.
///
/// The video layer scales with .resizeAspect, so a crop whose shape differs from
/// the view's is letterboxed. Measuring from the view's edges then puts the host
/// pointer off by an amount that grows with distance from the centre — a drift
/// that gets worse the further the mouse travels.
final class PointerMappingTests: XCTestCase {

    private func unit(_ point: CGPoint, view: CGSize, source: CGRect) -> CGPoint? {
        InputCapture.unitPoint(viewPoint: point, viewSize: view, source: source, isFlipped: true)
    }

    /// Shapes match, so the picture fills the view and the mapping is linear.
    func testMatchingAspectMapsLinearly() {
        let view = CGSize(width: 800, height: 500)
        let source = CGRect(x: 100, y: 50, width: 1600, height: 1000)

        XCTAssertEqual(unit(CGPoint(x: 0, y: 0), view: view, source: source)?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 400, y: 250), view: view, source: source)?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 400, y: 250), view: view, source: source)?.y ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 800, y: 500), view: view, source: source)?.x ?? -1, 1, accuracy: 0.001)
    }

    /// A picture wider than the view is letterboxed top and bottom. The centre
    /// still maps to the centre; the rows above and below it are not picture.
    func testLetterboxedVerticallyIgnoresTheBars() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 1600, height: 800)   // 2:1 into a square
        // Picture is 800x400, centred, so bars are 200pt tall.
        XCTAssertNil(unit(CGPoint(x: 400, y: 100), view: view, source: source))
        XCTAssertNil(unit(CGPoint(x: 400, y: 700), view: view, source: source))

        let middle = unit(CGPoint(x: 400, y: 400), view: view, source: source)
        XCTAssertEqual(middle?.y ?? -1, 0.5, accuracy: 0.001)
        // Top edge of the picture, 200pt down the view.
        XCTAssertEqual(unit(CGPoint(x: 400, y: 200), view: view, source: source)?.y ?? -1,
                       0, accuracy: 0.001)
    }

    /// A picture taller than the view is pillarboxed — the case the user saw as
    /// bars down each side.
    func testPillarboxedHorizontallyIgnoresTheBars() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 400, height: 800)    // 1:2 into a square
        // Picture is 400x800, centred, so bars are 200pt wide.
        XCTAssertNil(unit(CGPoint(x: 100, y: 400), view: view, source: source))
        XCTAssertEqual(unit(CGPoint(x: 200, y: 400), view: view, source: source)?.x ?? -1,
                       0, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 600, y: 400), view: view, source: source)?.x ?? -1,
                       1, accuracy: 0.001)
    }

    /// The regression itself: measuring across the whole view instead of the
    /// picture. Half way down a letterboxed view is NOT half way down the image,
    /// and the error is largest at the extremes.
    func testDriftGrowsWithDistanceWhenLetterboxed() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 1600, height: 800)

        // Naive mapping: y / viewHeight. Correct mapping accounts for the bars.
        for viewY in stride(from: 200.0, through: 600.0, by: 100.0) {
            let naive = viewY / view.height
            let correct = unit(CGPoint(x: 400, y: viewY), view: view, source: source)!.y
            let error = abs(naive - correct)
            if viewY == 400 {
                XCTAssertEqual(error, 0, accuracy: 0.001, "no error at the centre")
            } else {
                XCTAssertGreaterThan(error, 0.1, "the naive mapping is off away from the centre")
            }
        }
    }

    func testDegenerateSizesAreRejected() {
        XCTAssertNil(unit(CGPoint(x: 1, y: 1), view: .zero,
                          source: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(unit(CGPoint(x: 1, y: 1), view: CGSize(width: 10, height: 10),
                          source: .zero))
    }
}
