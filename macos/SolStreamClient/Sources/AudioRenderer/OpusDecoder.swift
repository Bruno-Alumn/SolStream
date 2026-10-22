import Foundation
import AudioToolbox
import SolStreamLogging

/// Opus packets to interleaved 16-bit stereo, with AudioToolbox's own decoder.
///
/// macOS has decoded Opus in AudioConverter for years, so the Mac needs no
/// library for it: the host compiles libopus in to encode, and this is the
/// whole of the other end.
///
/// One packet in, its samples out, on whichever thread delivers packets --
/// MediaClient's receive thread. It is not thread-safe and does not need to
/// be: there is one receive thread per session and one decoder per renderer.
/// Nothing is allocated per packet; both buffers are sized once, for the
/// largest packet Opus can make.
final class OpusDecoder {
    /// 120 ms, the longest packet RFC 6716 allows, in frames at 48 kHz.
    static let maxFrames = 5760
    /// No Opus packet is larger than one SMT/1 datagram can carry.
    static let maxPacketBytes = 1500

    let sampleRate: Double
    let channels: Int

    private var converter: AudioConverterRef?
    /// What `converter` was built for. AudioConverter's Opus decoder is told the
    /// frames in a packet up front, so a packet of another length rebuilds it.
    private var convertedFrames = 0

    // The packet being handed to the converter. Read by `supplyPacket`, which
    // AudioConverter calls back into synchronously from `decode`.
    fileprivate let input: UnsafeMutableRawPointer
    fileprivate var inputBytes: UInt32 = 0
    fileprivate var inputTaken = true
    /// Allocated rather than a stored struct, because AudioConverter is handed
    /// a pointer to it that has to stay valid after the callback returns.
    fileprivate let inputDescription: UnsafeMutablePointer<AudioStreamPacketDescription>

    private let output: UnsafeMutablePointer<Int16>
    private var failures = 0

    init(sampleRate: Double = 48_000, channels: Int = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
        input = .allocate(byteCount: Self.maxPacketBytes, alignment: 16)
        inputDescription = .allocate(capacity: 1)
        inputDescription.initialize(to: AudioStreamPacketDescription())
        output = .allocate(capacity: Self.maxFrames * channels)
        output.initialize(repeating: 0, count: Self.maxFrames * channels)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        input.deallocate()
        inputDescription.deinitialize(count: 1)
        inputDescription.deallocate()
        output.deinitialize(count: Self.maxFrames * channels)
        output.deallocate()
    }

    /// Decode one packet and hand its samples to `body`, which must not keep
    /// them: the buffer is reused for the next packet.
    ///
    /// - Returns: false when the packet could not be decoded, which loses its
    ///   few milliseconds of sound and nothing else.
    @discardableResult
    func decode(_ packet: Data, _ body: (UnsafeBufferPointer<Int16>) -> Void) -> Bool {
        guard let frames = Self.frames(in: packet), packet.count <= Self.maxPacketBytes else {
            fail("not an Opus packet (\(packet.count) bytes)")
            return false
        }
        if converter == nil || frames != convertedFrames {
            guard rebuild(frames: frames) else { return false }
        }
        guard let converter else { return false }

        packet.copyBytes(to: input.assumingMemoryBound(to: UInt8.self), count: packet.count)
        inputBytes = UInt32(packet.count)
        inputTaken = false

        var produced = UInt32(Self.maxFrames)
        var buffers = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(Self.maxFrames * channels * 2),
                                  mData: output))
        let status = AudioConverterFillComplexBuffer(
            converter, supplyPacket, Unmanaged.passUnretained(self).toOpaque(),
            &produced, &buffers, nil)
        // `drained` is this file's own way of saying "that was the only packet",
        // which is how a one-packet-at-a-time decode is meant to end.
        guard status == noErr || status == drained else {
            fail("AudioConverter refused a \(frames)-frame packet: \(status)")
            return false
        }
        if produced > 0 {
            body(UnsafeBufferPointer(start: output, count: Int(produced) * channels))
        }
        return true
    }

    /// The frames, per channel at 48 kHz, in one Opus packet: RFC 6716 §3.1.
    ///
    /// The first byte, the TOC, says how long each frame is and how many frames
    /// follow it. Nil for anything that cannot be an Opus packet -- empty, or a
    /// count past the 120 ms the format allows.
    static func frames(in packet: Data) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        // In 2.5 ms units (120 frames at 48 kHz), so CELT's 2.5 ms is exact.
        let units: Int
        switch config {
        case 0...11: units = [4, 8, 16, 24][config % 4]     // SILK: 10, 20, 40, 60 ms
        case 12...15: units = [4, 8][config % 2]            // hybrid: 10, 20 ms
        default: units = [1, 2, 4, 8][config % 4]           // CELT: 2.5, 5, 10, 20 ms
        }
        let count: Int
        switch toc & 0x3 {
        case 0: count = 1
        case 1, 2: count = 2
        default:
            guard packet.count >= 2 else { return nil }
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        let frames = units * 120 * count
        guard count > 0, frames <= maxFrames else { return nil }
        return frames
    }

    private func rebuild(frames: Int) -> Bool {
        if let converter { AudioConverterDispose(converter) }
        converter = nil
        var opus = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(frames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var pcm = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian
                | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels), mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16, mReserved: 0)
        var made: AudioConverterRef?
        let status = AudioConverterNew(&opus, &pcm, &made)
        guard status == noErr, let made else {
            fail("no Opus decoder for \(frames)-frame packets: \(status)")
            return false
        }
        converter = made
        if convertedFrames != 0 {
            Log.info("[audio] Opus packets changed from \(convertedFrames) to \(frames) frames")
        } else {
            Log.info("[audio] decoding Opus, \(frames) frames a packet")
        }
        convertedFrames = frames
        return true
    }

    /// The first failure is logged; the rest are counted into the next log
    /// line, because a stream of bad packets at 100 a second would roll the log.
    private func fail(_ what: String) {
        failures += 1
        if failures == 1 || failures % 1000 == 0 {
            Log.error("[audio] \(what) (\(failures) so far)")
        }
    }
}

/// Returned by `supplyPacket` once its one packet has gone: not an error, the
/// end of this call's input.
private let drained: OSStatus = 0x6472_6E64   // 'drnd'

private let supplyPacket: AudioConverterComplexInputDataProc = {
    _, packets, data, description, context in
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(context!).takeUnretainedValue()
    guard !decoder.inputTaken else {
        packets.pointee = 0
        return drained
    }
    decoder.inputTaken = true
    data.pointee.mNumberBuffers = 1
    data.pointee.mBuffers.mData = decoder.input
    data.pointee.mBuffers.mDataByteSize = decoder.inputBytes
    data.pointee.mBuffers.mNumberChannels = UInt32(decoder.channels)
    decoder.inputDescription.pointee = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: decoder.inputBytes)
    description?.pointee = decoder.inputDescription
    packets.pointee = 1
    return noErr
}
