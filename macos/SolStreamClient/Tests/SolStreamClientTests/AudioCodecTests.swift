import XCTest
import CryptoKit
import MediaSession
@testable import AgentChannel
@testable import AudioRenderer
@testable import SolStreamClient

/// Compressed sound, on this side: the packets libopus makes on the PC, framed
/// as SMT/1 carries them, decoded by AudioToolbox -- and a host that predates
/// all of it, which has to go on being asked and heard exactly as before.
final class AudioCodecTests: XCTestCase {

    // MARK: - Framing

    func testAnAudioPacketRoundTripsThroughItsFraming() throws {
        let packet = SMTAudioPacket(format: .opus, channels: 2, sequence: 0x0102_0304,
                                    timestampMicros: 0xA0B0_C0D0, sampleRate: 48_000,
                                    payload: Data([0xF4, 1, 2, 3]))
        let wire = packet.plaintext
        // audio.h's table, byte for byte.
        XCTAssertEqual([UInt8](wire), [0x20, 0, 2, 2,
                                       0x01, 0x02, 0x03, 0x04,
                                       0xA0, 0xB0, 0xC0, 0xD0,
                                       0x00, 0x00, 0xBB, 0x80,
                                       0xF4, 1, 2, 3])
        XCTAssertEqual(SMTAudioPacket(plaintext: wire), packet)

        // And through the AEAD, as the receive thread gets it.
        let key = SymmetricKey(size: .bits256)
        let sealer = SMTDirection(key: key, fixed: Data(repeating: 7, count: 6))
        let opener = SMTDirection(key: key, fixed: Data(repeating: 7, count: 6))
        var window = SMTReplayWindow()
        let datagram = try XCTUnwrap(SMTPacket.seal(wire, direction: sealer, sessionTag: 9))
        let (plain, _) = try XCTUnwrap(SMTPacket.open(datagram, direction: opener, window: &window))
        XCTAssertEqual(SMTAudioPacket(plaintext: plain), packet)
    }

    /// The layout session.cpp has always built, from a host that has never
    /// heard of Opus: format 1, little-endian samples.
    func testAnOldHostsPCMStillParsesAsPCM() throws {
        var wire = Data([0x20, 0, 2, 1, 0, 0, 0, 7, 0, 0, 0x13, 0x88, 0, 0, 0xBB, 0x80])
        for sample: Int16 in [100, -100, .max, .min] {
            withUnsafeBytes(of: sample.littleEndian) { wire.append(contentsOf: $0) }
        }
        let packet = try XCTUnwrap(SMTAudioPacket(plaintext: wire))
        XCTAssertEqual(packet.format, .pcm16)
        XCTAssertEqual(packet.channels, 2)
        XCTAssertEqual(packet.sequence, 7)
        XCTAssertEqual(packet.timestampMicros, 5_000)
        XCTAssertEqual(packet.sampleRate, 48_000)
        XCTAssertEqual(packet.payload, wire.dropFirst(16))
    }

    func testWhatIsNotAnAudioPacketIsNotPlayed() {
        let opus = SMTAudioPacket(format: .opus, sequence: 1, payload: Data([0xF4])).plaintext
        XCTAssertNil(SMTAudioPacket(plaintext: opus.prefix(16)), "a header with no sound")
        var unknown = opus
        unknown[3] = 9
        XCTAssertNil(SMTAudioPacket(plaintext: unknown), "a format this build does not know")
        var video = opus
        video[0] = SMT.typeVideo
        XCTAssertNil(SMTAudioPacket(plaintext: video))
        var silent = opus
        silent[2] = 0
        XCTAssertNil(SMTAudioPacket(plaintext: silent), "no channels")
    }

    // MARK: - Opus

    /// RFC 6716 §3.1: the TOC byte says how long each frame is and how many
    /// there are, and AudioConverter has to be told before it will decode.
    func testThePacketsFirstByteSaysHowLongItIs() {
        func frames(_ bytes: [UInt8]) -> Int? { OpusDecoder.frames(in: Data(bytes)) }
        // CELT fullband stereo, one frame: what the host sends.
        XCTAssertEqual(frames([0xE4]), 120, "2.5 ms")
        XCTAssertEqual(frames([0xEC]), 240, "5 ms")
        XCTAssertEqual(frames([0xF4]), 480, "10 ms")
        XCTAssertEqual(frames([0xFC]), 960, "20 ms")
        XCTAssertEqual(frames([0xFD]), 1920, "two 20 ms frames, equal")
        XCTAssertEqual(frames([0xFE]), 1920, "two 20 ms frames, not equal")
        XCTAssertEqual(frames([0xFF, 0x06]), 5760, "six 20 ms frames: 120 ms, the most allowed")
        XCTAssertEqual(frames([0x18]), 2880, "SILK, 60 ms")
        XCTAssertEqual(frames([0x60]), 480, "hybrid, 10 ms")
        XCTAssertEqual(frames([0x68]), 960, "hybrid, 20 ms")
        XCTAssertNil(frames([0xFF, 0x07]), "140 ms is past the limit")
        XCTAssertNil(frames([0xFF, 0x00]), "no frames at all")
        XCTAssertNil(frames([0xFF]), "a count byte promised and missing")
        XCTAssertNil(frames([]))
    }

    /// Packets libopus 1.6.1 made exactly as the host makes them -- restricted
    /// low delay, constrained VBR, music -- from 100 ms of a tone, 440 Hz on
    /// the left and 1 kHz on the right at half scale.
    func testWhatLibopusMakesDecodesToWhatWentIn() throws {
        try assertDecodesTheTone(Self.libopus128k10ms, framesPerPacket: 480)
        try assertDecodesTheTone(Self.libopus64k20ms, framesPerPacket: 960)
    }

    /// The host keeps one packet length for a session, but a decoder built for
    /// one length refuses another outright, so a change has to rebuild it.
    func testAChangeOfPacketLengthIsFollowed() throws {
        let decoder = OpusDecoder()
        var frames: [Int] = []
        for packet in try Self.packets(Self.libopus128k10ms).prefix(3)
            + Self.packets(Self.libopus64k20ms).prefix(3) {
            XCTAssertTrue(decoder.decode(packet) { frames.append($0.count / 2) })
        }
        XCTAssertEqual(frames.suffix(2), [960, 960])
        XCTAssertEqual(frames[1...2], [480, 480])
    }

    func testWhatCannotBeDecodedIsRefused() {
        let decoder = OpusDecoder()
        var called = false
        XCTAssertFalse(decoder.decode(Data()) { _ in called = true })
        XCTAssertFalse(decoder.decode(Data([0xFF])) { _ in called = true })
        XCTAssertFalse(decoder.decode(Data([0xF4]) + Data(count: 2_000)) { _ in called = true },
                       "larger than any datagram")
        XCTAssertFalse(called)
    }

    private func assertDecodesTheTone(_ base64: String, framesPerPacket: Int,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let packets = try Self.packets(base64)
        let decoder = OpusDecoder()
        var out: [Int16] = []
        for (index, payload) in packets.enumerated() {
            XCTAssertEqual(OpusDecoder.frames(in: payload), framesPerPacket, file: file, line: line)
            // Framed as the host frames it, and taken apart as the Mac does.
            let framed = SMTAudioPacket(format: .opus, sequence: UInt32(index + 1),
                                        payload: payload).plaintext
            let parsed = try XCTUnwrap(SMTAudioPacket(plaintext: framed), file: file, line: line)
            XCTAssertEqual(parsed.format, .opus, file: file, line: line)
            XCTAssertTrue(decoder.decode(parsed.payload) { out.append(contentsOf: $0) },
                          file: file, line: line)
        }
        // AudioToolbox drops the encoder's 2.5 ms of lookahead from the front,
        // so what comes out lines up sample for sample with what went in.
        XCTAssertEqual(out.count / 2, packets.count * framesPerPacket - 120, file: file, line: line)

        // Past the first 10 ms, where the codec is still settling: close to
        // the tone, in the right channels and at the right pitch. A swapped
        // pair, a wrong rate or a byte-order slip are all far below this.
        var signal = 0.0, error = 0.0
        for n in 480..<(out.count / 2) {
            let left = 0.5 * sin(2 * .pi * 440 * Double(n) / 48_000) * 32_767
            let right = 0.5 * sin(2 * .pi * 1_000 * Double(n) / 48_000) * 32_767
            let l = Double(out[n * 2]), r = Double(out[n * 2 + 1])
            signal += left * left + right * right
            error += (left - l) * (left - l) + (right - r) * (right - r)
        }
        let snr = 10 * log10(signal / max(error, 1))
        XCTAssertGreaterThan(snr, 25, "\(framesPerPacket)-frame packets decode to noise", file: file, line: line)
    }

    // MARK: - Negotiation

    /// Lossless asks for nothing new, so a host of any age is sent the same
    /// command it always was.
    func testLosslessAsksAnOldHostExactlyWhatItAlwaysAsked() {
        let request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY1", fps: 60,
                                                   bitrate: 20_000_000, audio: true,
                                                   width: 3024, height: 1964,
                                                   audioEncoding: .pcm)
        let fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(Set(fields.keys), ["display", "fps", "bitrate", "audio", "width", "height"])
        XCTAssertEqual(fields["audio"] as? Int, 1)
    }

    /// Opus is asked for in fields an old host has no lookup for and so never
    /// reads -- and that cannot be mistaken for the ones it does read.
    func testOpusIsAskedForInFieldsAnOldHostCannotMisread() throws {
        let request = AgentConnection.MediaRequest(
            display: "\\\\.\\DISPLAY1", fps: 60, bitrate: 20_000_000, audio: true,
            audioEncoding: .opus(bitrate: 128_000, frameMilliseconds: 10))
        let fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(fields["audioCodec"] as? String, "opus")
        XCTAssertEqual(fields["audioBitrate"] as? Int, 128_000)
        XCTAssertEqual(fields["audioFrameMs"] as? Int, 10)

        // main.cpp finds a field by searching for its name in quotes, so a new
        // name containing an old one in quotes would be read as that one.
        let read = ["cmd", "op", "ver", "cpub", "cnonce", "window", "display", "fps",
                    "bitrate", "audio", "width", "height"]
        for new in ["audioCodec", "audioBitrate", "audioFrameMs"] {
            for old in read {
                XCTAssertFalse("\"\(new)\"".contains("\"\(old)\""), "\(new) reads as \(old)")
            }
        }
        // And on the line itself, read the way an old host reads it.
        let line = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields),
                                        encoding: .utf8))
        XCTAssertEqual(Self.hostFieldNumber(line, "audio"), 1)
        XCTAssertEqual(Self.hostFieldNumber(line, "bitrate"), 20_000_000,
                       "the sound's bitrate was read as the picture's")
        XCTAssertEqual(Self.hostFieldNumber(line, "fps"), 60)
    }

    func testWithoutSoundNoEncodingIsAskedFor() {
        let request = AgentConnection.MediaRequest(
            audio: false, audioEncoding: .opus(bitrate: 64_000, frameMilliseconds: 20))
        let fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(fields["audio"] as? Int, 0)
        XCTAssertNil(fields["audioCodec"])
        XCTAssertNil(fields["audioBitrate"])
    }

    /// A reply with no word on the sound is from a host that sends PCM; so is
    /// one naming a codec this build cannot play.
    func testAnOldHostsReplyMeansPCM() {
        // What main.cpp answered before there was a choice, field for field.
        let old: [String: Any] = ["type": "media", "ok": true, "ver": 1, "hpub": "04",
                                  "hnonce": "00", "hcount": "41", "hauth": "00",
                                  "streaming": true, "hport": 47631]
        XCTAssertEqual(AgentConnection.audioCodec(inReply: old), .pcm)
        var new = old
        new["audioCodec"] = "opus"
        XCTAssertEqual(AgentConnection.audioCodec(inReply: new), .opus)
        new["audioCodec"] = "flac"
        XCTAssertEqual(AgentConnection.audioCodec(inReply: new), .pcm)
        new["audioCodec"] = 2
        XCTAssertEqual(AgentConnection.audioCodec(inReply: new), .pcm)
    }

    /// The streamed apps' sound alone is one more field, sent only when it is
    /// wanted and there is sound to want it of, and like the codec's it cannot
    /// be read as a field an old host knows.
    func testTheAppsSoundIsAskedForInOneFieldAnOldHostCannotMisread() throws {
        var request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY1", fps: 60,
                                                   bitrate: 20_000_000, audio: true,
                                                   audioEncoding: .pcm, audioSource: .apps)
        var fields = AgentConnection.mediaOpenFields(request)
        XCTAssertEqual(Set(fields.keys), ["display", "fps", "bitrate", "audio", "audioSource"])
        XCTAssertEqual(fields["audioSource"] as? String, "apps")
        for old in ["audio", "display", "fps", "bitrate"] {
            XCTAssertFalse("\"audioSource\"".contains("\"\(old)\""))
        }
        let line = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: fields),
                                        encoding: .utf8))
        XCTAssertEqual(Self.hostFieldNumber(line, "audio"), 1)

        request.audio = false
        fields = AgentConnection.mediaOpenFields(request)
        XCTAssertNil(fields["audioSource"], "asked whose sound while asking for none")
    }

    func testAHostThatSaysNothingSendsTheWholePCsSound() {
        XCTAssertEqual(AgentConnection.audioSource(inReply: ["type": "media", "ok": true]), .system)
        XCTAssertEqual(AgentConnection.audioSource(inReply: ["audioSource": "apps"]), .apps)
        XCTAssertEqual(AgentConnection.audioSource(inReply: ["audioSource": "system"]), .system)
        XCTAssertEqual(AgentConnection.audioSource(inReply: ["audioSource": "everything"]), .system)
    }

    /// The popover's "predates this" is said only when Opus was asked for and
    /// PCM promised -- not with the sound off, and not for Lossless.
    func testTheMacNoticesAHostThatIgnoredTheQuality() {
        let opus = StreamConfig(audio: true, audioEncoding: .opus(bitrate: 256_000, frameMilliseconds: 10))
        XCTAssertTrue(StreamSession.hostIgnoresSoundQuality(asked: opus, answered: .pcm))
        XCTAssertFalse(StreamSession.hostIgnoresSoundQuality(asked: opus, answered: .opus))
        var silent = opus
        silent.audio = false
        XCTAssertFalse(StreamSession.hostIgnoresSoundQuality(asked: silent, answered: .pcm))
        let lossless = StreamConfig(audio: true, audioEncoding: .pcm)
        XCTAssertFalse(StreamSession.hostIgnoresSoundQuality(asked: lossless, answered: .pcm))
    }

    /// The popover's "all the PC's sound" is said only when the streamed apps'
    /// alone was asked for and the whole PC's promised -- as a host on
    /// Windows 10 answers -- and not with the sound off.
    func testTheMacNoticesAHostThatSendsTheWholePCsSound() {
        let apps = StreamConfig(audio: true, audioSource: .apps)
        XCTAssertTrue(StreamSession.hostSendsWholePC(asked: apps, answered: .system))
        XCTAssertFalse(StreamSession.hostSendsWholePC(asked: apps, answered: .apps))
        var silent = apps
        silent.audio = false
        XCTAssertFalse(StreamSession.hostSendsWholePC(asked: silent, answered: .system))
        let everything = StreamConfig(audio: true, audioSource: .system)
        XCTAssertFalse(StreamSession.hostSendsWholePC(asked: everything, answered: .system))
    }

    // MARK: - Helpers

    /// main.cpp's FieldNumber, transcribed: the first `"key"`, then the first
    /// colon after it, then the digits.
    private static func hostFieldNumber(_ json: String, _ key: String) -> Int? {
        guard let name = json.range(of: "\"\(key)\""),
              let colon = json[name.upperBound...].firstIndex(of: ":") else { return nil }
        let digits = json[json.index(after: colon)...]
            .drop { $0 == " " || $0 == "\t" }
            .prefix { $0.isASCII && $0.isNumber }
        return Int(digits)
    }

    /// Length-prefixed packets: a big-endian UInt16, then that many bytes.
    private static func packets(_ base64: String) throws -> [Data] {
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        var packets: [Data] = []
        var at = data.startIndex
        while at + 2 <= data.endIndex {
            let length = Int(data[at]) << 8 | Int(data[at + 1])
            at += 2
            packets.append(data.subdata(in: at..<at + length))
            at += length
        }
        return packets
    }

    // Made with libopus 1.6.1: opus_encoder_create(48000, 2,
    // OPUS_APPLICATION_RESTRICTED_LOWDELAY), OPUS_SET_BITRATE, OPUS_SET_VBR_CONSTRAINT(1),
    // OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC), opus_encode_float -- what audio.cpp does.
    static let libopus128k10ms = [
        "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",
        "JGjDORjhdt7rCp0fG+7ryP2Z3+vb/QA=",
    ].joined()

    static let libopus64k20ms = [
        "AQ/8tUTtq8Z/vXH0+VHc+xAlgqwcv8r7WjCnoIdJhK1BMXI9I1mAzVn2sm6kl6zxAKAeN+ZyvKvE",
        "4IB07GpDAJjCf9E+OKHwdGqUcVs6XCVIeoeV7sex+6BRQChgFehaTzY/rS+4Vkg0vIxqofPtfI2G",
        "jlFDOmmT5WJgJjfug43LHtio/Pl7f9EZDBYW8TV+gAAAAAAAAAAAAAAAAAAAAAAAAAAIu34brrX5",
        "GNgp6ZFpVURb2XigQJvyC4dV88R+GzhkUrwldCwlF0/O54U/INMkZxlD/+njF74cwfdvNBgL9rT+",
        "4dHzY5pW5VBW+5tl90q5eUxStY7jqIs/EtB1nHcsIcxDnl0z4NPRuZzjlEUiANP82xlVqsSQAB/u",
        "TvFEWH8HVkk+pLf6fI8Phxlxlxlxlxl+5DgeP81w3tvEo5v5t/s1icdjTYR3omQZXdz0ctOCiZvJ",
        "zhSMwq/20rmXzP+cQSZcM9bxdDrS443Bk7FFTEFBvVbXk5GwFX0RpniEKFbX85g6liPnk9r1Sj6s",
        "gjmXKs4DFBbEODeUewtvv7zRARyuJkzS9Jvl9du4esL1TEZeymgRjtHBYhhNlUVE0+uEoeH8DKsz",
        "MDH6c2El78R9g6hzPSJ9D3WywuY2kXZWChS/3daxAKH868Jd5EXwRtt3P/kGesUktYHZRL8VPbuS",
        "SiSiSiSiSiojgk6nWghXCWoO7reQbo29zxH+AfsMt+ZZsRSftL/2gWVC02f6RS98+nPsv1vZJyex",
        "C45I5ih87cqoK15xScdiZWkCxpxig4kVKTs1DGTcfFnT4i320pwVW/LbGlNUuHv7koRHxfCaJ4Rk",
        "Z3HOL62HgloAHjPIIqn/Oy3NO9JdAQCh/Nr+GjCqn3/jzutcUtwvley68kg1oiYPYPYPYPYPZrBi",
        "9Lh19FmAl2k1zwwBtBafkR6/PXIbGKmffIE0i/bwY+d8c4OiBH/bg8p75VtRxDbXNtEEQ3zVLXtS",
        "7EIZliWpE9KuleOeU347ft/CJ7DjPhusJ09IH+2lz7Oze+kKnV1rgqtIB2O8rLeQ4qpz/m9kV0pl",
        "vFqdN0/BNs+/O2nsRrEAofz3oaU3BMfFiJE6PNGMky9lqRLWacEkEkEkEkEkbKGQ63KYLwHG7yLN",
        "ZXfmFQEIGaVudpltvTJO4sgaqYoYmI4nyvxYXBI4/YXxCLcrbluPed4JS3YGsaomALHEu0JGChnu",
        "jopZj7tTQ5HtQEEk9olulGEcnUEzY3vTZiYu4+WFk3fepNqJ26HEjluKC4y/dOsZKufW+jre87xv",
        "HcbnJC0B",
    ].joined()
}
