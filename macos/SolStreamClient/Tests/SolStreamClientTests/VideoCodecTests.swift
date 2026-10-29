import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import MediaSession
@testable import AgentChannel
@testable import VideoDecoder
@testable import SolStreamClient

/// HEVC beside H.264: asked for and answered on the agent channel, with either
/// end older than the choice; read NAL by NAL; and recognised as a keyframe by
/// the reassembly and the hold, whichever of HEVC's keyframe types it is.
final class VideoCodecTests: XCTestCase {

    // MARK: - Negotiation

    /// H.264 alone is what every host sends unasked, so a Mac that wants
    /// nothing else sends exactly the command an old host always had.
    func testH264AloneAsksAnOldHostNothingNew() {
        let request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY1", fps: 60,
                                                   bitrate: 20_000_000, audio: false,
                                                   videoCodecs: [.h264])
        let fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(Set(fields.keys), ["display", "fps", "bitrate", "audio"])
        XCTAssertNil(AgentConnection.mediaOpenFields(.init(audio: false))["videoCodecs"],
                     "the default is H.264 alone")
    }

    /// HEVC is offered in one field, most wanted first, that an old host has
    /// no lookup for -- and that cannot be mistaken for one it does have.
    func testHEVCIsOfferedInOneFieldAnOldHostCannotMisread() throws {
        let request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY1", fps: 60,
                                                   bitrate: 20_000_000, audio: true,
                                                   videoCodecs: [.hevc, .h264])
        let fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(fields["videoCodecs"] as? String, "hevc,h264")
        let read = ["cmd", "op", "ver", "cpub", "cnonce", "window", "display", "fps",
                    "bitrate", "audio", "width", "height", "audioCodec", "audioBitrate",
                    "audioFrameMs", "audioSource"]
        for old in read {
            XCTAssertFalse("\"videoCodecs\"".contains("\"\(old)\""), "videoCodecs reads as \(old)")
        }
        let line = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields),
                                        encoding: .utf8))
        XCTAssertTrue(line.contains("\"videoCodecs\":\"hevc,h264\""), line)
    }

    /// A reply with no word on the picture is from a host that sends H.264:
    /// every host before the choice. A new host names what it chose.
    func testAnOldHostsReplyMeansH264() {
        // What main.cpp answered before there was a choice, field for field.
        let old: [String: Any] = ["type": "media", "ok": true, "ver": 1, "hpub": "04",
                                  "hnonce": "00", "hcount": "41", "hauth": "00",
                                  "streaming": true, "hport": 47631]
        XCTAssertEqual(AgentConnection.videoCodec(inReply: old), .h264)
        var new = old
        new["videoCodec"] = "hevc"
        XCTAssertEqual(AgentConnection.videoCodec(inReply: new), .hevc)
        new["videoCodec"] = "h264"
        XCTAssertEqual(AgentConnection.videoCodec(inReply: new), .h264)
        new["videoCodec"] = "av1"
        XCTAssertEqual(AgentConnection.videoCodec(inReply: new), .h264)
        new["videoCodec"] = 2
        XCTAssertEqual(AgentConnection.videoCodec(inReply: new), .h264)
    }

    /// Automatic offers HEVC only where this Mac decodes it in hardware, and
    /// every choice keeps H.264 as the fallback a PC without HEVC needs.
    func testTheSettingOffersWhatThisMacDecodes() {
        typealias Choice = StreamSettings.VideoCodecChoice
        XCTAssertEqual(Choice.automatic.codecs(hardwareHEVC: true), [.hevc, .h264])
        XCTAssertEqual(Choice.automatic.codecs(hardwareHEVC: false), [.h264])
        XCTAssertEqual(Choice.h264.codecs(hardwareHEVC: true), [.h264])
        XCTAssertEqual(Choice.hevc.codecs(hardwareHEVC: false), [.hevc, .h264])
        for choice in Choice.allCases {
            XCTAssertEqual(choice.codecs(hardwareHEVC: true).last, .h264)
        }
    }

    func testTheSettingIsAppliedUnlessAFlagSaidOtherwise() {
        let key = "SolStream.videoCodec"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let settings = StreamSettings.shared
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(settings.videoCodec, .h264, "H.264 until something is chosen")
        let unchosen = settings.apply(to: StreamConfig(), host: "192.168.1.20", hardwareHEVC: true)
        XCTAssertEqual(unchosen.videoCodecs, [.h264], "an update must not move anyone to HEVC")

        settings.videoCodec = .hevc
        var config = settings.apply(to: StreamConfig(), host: "192.168.1.20", hardwareHEVC: false)
        XCTAssertEqual(config.videoCodecs, [.hevc, .h264])
        settings.videoCodec = .automatic
        config = settings.apply(to: StreamConfig(), host: "192.168.1.20", hardwareHEVC: true)
        XCTAssertEqual(config.videoCodecs, [.hevc, .h264])

        var typed = StreamConfig()
        typed.videoCodecs = [.h264]
        config = settings.apply(to: typed, host: "192.168.1.20", overrides: [.videoCodec],
                                hardwareHEVC: true)
        XCTAssertEqual(config.videoCodecs, [.h264], "--video-codec wins over the setting")
    }

    /// A different codec is a different encoder on the PC, so changing it
    /// restarts a running stream -- and the restart asks for the new one.
    func testChangingTheCodecRestartsTheStreamWithIt() throws {
        let key = "SolStream.videoCodec"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let settings = StreamSettings.shared
        let host = "192.168.1.20"
        settings.videoCodec = .h264
        let config = settings.apply(to: StreamConfig(), host: host)
        let request = AgentConnection.MediaRequest(fps: config.frameRate,
                                                   bitrate: config.bitrateKbps * 1000,
                                                   audio: config.audio,
                                                   audioEncoding: config.audioEncoding,
                                                   audioSource: config.audioSource,
                                                   videoCodecs: config.videoCodecs)
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config, host: host,
                                          overrides: []))
        settings.videoCodec = .hevc
        let restarted = try XCTUnwrap(AppDelegate.applying(settings, to: request, config: config,
                                                           host: host, overrides: []))
        XCTAssertEqual(restarted.request.videoCodecs, [.hevc, .h264])
        XCTAssertEqual(restarted.config.videoCodecs, [.hevc, .h264])
        // What --video-codec set stays set.
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config, host: host,
                                          overrides: [.videoCodec]))
    }

    // MARK: - NAL units

    func testHEVCNalTypesAreReadFromTheirTwoByteHeader() {
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x40), 32)   // VPS
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x42), 33)   // SPS
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x44), 34)   // PPS
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x26), 19)   // IDR_W_RADL
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x28), 20)   // IDR_N_LP
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x2A), 21)   // CRA_NUT
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x02), 1)    // TRAIL_R
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x4E), 39)   // prefix SEI
        // The same byte means something else in the other codec.
        XCTAssertEqual(VideoNAL.type(.h264, first: 0x67), 7)
        XCTAssertEqual(VideoNAL.type(.hevc, first: 0x67), 51)
        XCTAssertEqual(VideoNAL.headerLength(.hevc), 2)
        XCTAssertEqual(VideoNAL.headerLength(.h264), 1)
    }

    func testHEVCRoles() {
        for type in [32, 33, 34] { XCTAssertEqual(VideoNAL.role(.hevc, type: type), .parameterSet) }
        for type in 16...21 { XCTAssertEqual(VideoNAL.role(.hevc, type: type), .keyframeSlice) }
        for type in [0, 1, 2, 9, 22, 31] { XCTAssertEqual(VideoNAL.role(.hevc, type: type), .slice) }
        for type in [35, 36, 37, 38, 39, 40, 48] {
            XCTAssertEqual(VideoNAL.role(.hevc, type: type), .other)
        }
        XCTAssertEqual(VideoNAL.role(.h264, type: 5), .keyframeSlice)
        XCTAssertEqual(VideoNAL.role(.h264, type: 1), .slice)
        XCTAssertEqual(VideoNAL.role(.h264, type: 7), .parameterSet)
        XCTAssertEqual(VideoNAL.role(.h264, type: 6), .other)
    }

    /// Each of the three keyframe types the brief names, as the encoder would
    /// send it: parameter sets, then the picture.
    func testEveryHEVCKeyframeTypeIsAKeyframe() {
        for (name, header) in [("IDR_W_RADL", UInt8(0x26)), ("IDR_N_LP", 0x28), ("CRA", 0x2A)] {
            let picture = Self.hevcPicture(slice: header, parameterSets: true)
            XCTAssertTrue(VideoNAL.isKeyframe(.hevc, annexB: picture), name)
            let bare = Self.hevcPicture(slice: header, parameterSets: false)
            XCTAssertTrue(VideoNAL.isKeyframe(.hevc, annexB: bare), "\(name) without parameter sets")
        }
        XCTAssertFalse(VideoNAL.isKeyframe(.hevc, annexB: Self.hevcPicture(slice: 0x02,
                                                                           parameterSets: false)))
        // Parameter sets alone are not a picture.
        XCTAssertFalse(VideoNAL.isKeyframe(.hevc, annexB: Data([0, 0, 0, 1, 0x40, 0x01, 0x0C])))
    }

    /// Read as the wrong codec, an HEVC keyframe is not one, which is why a
    /// stream is read only as what the host said it was.
    func testAnHEVCKeyframeReadAsH264IsNot() {
        let picture = Self.hevcPicture(slice: 0x26, parameterSets: true)
        XCTAssertFalse(VideoNAL.isKeyframe(.h264, annexB: picture))
        let h264Idr = Data([0, 0, 0, 1, 0x67, 0x64, 0, 0, 0, 1, 0x68, 0xEE, 0, 0, 1, 0x65, 0x88])
        XCTAssertTrue(VideoNAL.isKeyframe(.h264, annexB: h264Idr))
        XCTAssertFalse(VideoNAL.isKeyframe(.h264, annexB: Data([0, 0, 0, 1, 0x41, 0x9A])))
    }

    // MARK: - Reassembly and the hold

    /// A keyframe the host did not flag -- its encoder's clean-point mark is a
    /// courtesy -- is still one by its own first slice.
    func testAnUnflaggedHEVCIRAPPictureIsAKeyframe() {
        let reassembler = VideoReassembler(codec: .hevc)
        var pictures: [VideoReassembler.Picture] = []
        reassembler.onPicture = { pictures.append($0) }
        reassembler.ingest(Self.fragment(frameId: 1, payload: Self.hevcPicture(slice: 0x2A,
                                                                               parameterSets: true)))
        reassembler.ingest(Self.fragment(frameId: 2, payload: Self.hevcPicture(slice: 0x02,
                                                                               parameterSets: false)))
        XCTAssertEqual(pictures.map(\.isIdr), [true, false])

        // An H.264 stream is not read for HEVC's types.
        let h264 = VideoReassembler(codec: .h264)
        var h264Pictures: [VideoReassembler.Picture] = []
        h264.onPicture = { h264Pictures.append($0) }
        h264.ingest(Self.fragment(frameId: 1, payload: Self.hevcPicture(slice: 0x2A,
                                                                        parameterSets: true)))
        XCTAssertEqual(h264Pictures.map(\.isIdr), [false])
    }

    /// After a loss the hold keeps P-frames from the decoder until a keyframe;
    /// an HEVC CRA is one, flagged or not.
    func testAnHEVCCRAEndsTheHold() {
        let reassembler = VideoReassembler(codec: .hevc)
        var hold = KeyframeHold()
        var decoded: [UInt32] = []
        reassembler.onPicture = { picture in
            if hold.picture(frameId: picture.frameId, isIdr: picture.isIdr,
                            now: DispatchTime.now().uptimeNanoseconds) == .decode {
                decoded.append(picture.frameId)
            }
        }
        reassembler.onDamaged = { frameId in
            _ = hold.damaged(frameId: frameId, now: DispatchTime.now().uptimeNanoseconds)
        }
        let p = Self.hevcPicture(slice: 0x02, parameterSets: false)
        reassembler.ingest(Self.fragment(frameId: 1, payload: Self.hevcPicture(slice: 0x26,
                                                                               parameterSets: true),
                                         idr: true))
        reassembler.ingest(Self.fragment(frameId: 2, payload: p))
        // 3 is lost whole; 4 and 5 are P-frames that refer to it.
        reassembler.ingest(Self.fragment(frameId: 4, payload: p))
        reassembler.ingest(Self.fragment(frameId: 5, payload: p))
        XCTAssertEqual(decoded, [1, 2], "P-frames after a loss reached the decoder")
        // The repair: a CRA, which this host's encoder may not flag.
        reassembler.ingest(Self.fragment(frameId: 6, payload: Self.hevcPicture(slice: 0x2A,
                                                                               parameterSets: true)))
        reassembler.ingest(Self.fragment(frameId: 7, payload: p))
        XCTAssertEqual(decoded, [1, 2, 6, 7])
    }

    // MARK: - Decoding

    /// A real HEVC stream, made by this Mac's own encoder, through the decoder
    /// in the Annex-B form the host sends: the format description is built
    /// from its VPS, SPS and PPS, the slices go in length-prefixed, and a
    /// picture comes out.
    func testAnHEVCStreamDecodes() throws {
        let frames = try Self.encodeHEVC(count: 2)
        XCTAssertEqual(frames.count, 2)
        let units = VideoNAL.splitAnnexB(frames[0])
        XCTAssertEqual(units.prefix(3).map { VideoNAL.type(.hevc, first: frames[0][$0.lowerBound]) },
                       [32, 33, 34], "the keyframe does not start VPS, SPS, PPS")
        XCTAssertTrue(VideoNAL.isKeyframe(.hevc, annexB: frames[0]))
        XCTAssertFalse(VideoNAL.isKeyframe(.hevc, annexB: frames[1]))

        let decodedTwo = expectation(description: "two pictures decoded")
        decodedTwo.expectedFulfillmentCount = 2
        var sizes: [CGSize] = []
        let lock = NSLock()
        let decoder = VideoDecoder(codec: .hevc) { pixelBuffer in
            lock.lock()
            sizes.append(CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                height: CVPixelBufferGetHeight(pixelBuffer)))
            lock.unlock()
            decodedTwo.fulfill()
        }
        var keyframeAsks = 0
        decoder.onKeyframeNeeded = { keyframeAsks += 1 }
        // Not flagged: the decoder finds the keyframe in the picture itself.
        decoder.decode(frames[0], isIDR: false)
        decoder.decode(frames[1], isIDR: false)
        wait(for: [decodedTwo], timeout: 5)
        decoder.shutdown()
        XCTAssertEqual(keyframeAsks, 0)
        lock.lock()
        XCTAssertEqual(sizes, [CGSize(width: 320, height: 240), CGSize(width: 320, height: 240)])
        lock.unlock()
    }

    /// Before its parameter sets an HEVC decoder can do nothing, and asks.
    func testAnHEVCDecoderWithoutParameterSetsAsksForAKeyframe() {
        let decoder = VideoDecoder(codec: .hevc) { _ in XCTFail("decoded with no parameter sets") }
        var asks = 0
        decoder.onKeyframeNeeded = { asks += 1 }
        decoder.decode(Self.hevcPicture(slice: 0x02, parameterSets: false), isIDR: false)
        decoder.shutdown()
        XCTAssertEqual(asks, 1)
    }

    // MARK: - Helpers

    /// An Annex-B picture of one slice whose first header byte is `slice`,
    /// optionally behind a VPS, SPS and PPS. Not decodable; for reading only.
    private static func hevcPicture(slice: UInt8, parameterSets: Bool) -> Data {
        var bytes: [UInt8] = []
        if parameterSets {
            bytes += [0, 0, 0, 1, 0x40, 0x01, 0x0C, 0x01]    // VPS
            bytes += [0, 0, 0, 1, 0x42, 0x01, 0x01, 0x01]    // SPS
            bytes += [0, 0, 0, 1, 0x44, 0x01, 0xC1, 0x72]    // PPS
            bytes += [0, 0, 1, 0x4E, 0x01, 0x05, 0x10]       // prefix SEI
        }
        bytes += [0, 0, 1, slice, 0x01, 0xAF, 0x1C, 0x55]
        return Data(bytes)
    }

    /// One whole picture in one datagram.
    private static func fragment(frameId: UInt32, payload: Data, idr: Bool = false) -> Data {
        var packet = Data()
        packet.append(SMT.typeVideo)
        var flags: UInt8 = SMT.flagFrameStart | SMT.flagFrameEnd
        if idr { flags |= SMT.flagIdr }
        packet.append(flags)
        packet.append(0xF0)
        packet.append(0)
        packet.append(SMTPacket.be(UInt64(frameId), 4))
        packet.append(SMTPacket.be(0, 3))
        packet.append(0)
        packet.append(SMTPacket.be(1234, 4))
        packet.append(payload)
        return packet
    }

    /// `count` pictures from VideoToolbox's HEVC encoder, in the Annex-B form
    /// the host sends: the first a keyframe with its VPS, SPS and PPS in front,
    /// the rest P-frames, no B-frames.
    private static func encodeHEVC(count: Int) throws -> [Data] {
        var made: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 320, height: 240,
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard status == noErr, let session = made else {
            throw XCTSkip("no HEVC encoder on this Mac (\(status))")
        }
        defer { VTCompressionSessionInvalidate(session) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)

        var pictures: [Data] = []
        let lock = NSLock()
        for index in 0..<count {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!
            memset(base, Int32(40 + index * 60), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])

            let properties: CFDictionary? = index == 0
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
            let encoded = VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 60),
                duration: CMTime(value: 1, timescale: 60), frameProperties: properties,
                infoFlagsOut: nil) { status, _, sample in
                    guard status == noErr, let sample else { return }
                    let annexB = annexBFromSample(sample)
                    lock.lock()
                    pictures.append(annexB)
                    lock.unlock()
                }
            XCTAssertEqual(encoded, noErr)
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        lock.lock()
        defer { lock.unlock() }
        return pictures
    }

    /// A length-prefixed HEVC sample as Annex B, parameter sets first when it
    /// is a keyframe -- what `Encoder::Emit` puts on the wire.
    private static func annexBFromSample(_ sample: CMSampleBuffer) -> Data {
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        if !notSync, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil)
                if let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return out }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                    totalLengthOut: &length, dataPointerOut: &pointer)
        guard let pointer else { return out }
        let bytes = Data(bytes: pointer, count: length)
        var at = 0
        while at + 4 <= bytes.count {
            let unit = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16
                | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
            at += 4
            guard unit > 0, at + unit <= bytes.count else { break }
            out.append(contentsOf: startCode)
            out.append(bytes[at..<at + unit])
            at += unit
        }
        return out
    }
}
