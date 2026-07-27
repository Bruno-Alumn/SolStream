import AudioToolbox
import Foundation
import SolStreamLogging

/// Decodes the Opus frames Sunshine sends into the 16-bit PCM the renderer wants.
///
/// macOS ships an Opus decoder — `kAudioFormatOpus` is a real entry in
/// `kAudioFormatProperty_DecodeFormatIDs`, and AudioConverter will build an
/// Opus→LPCM converter — so nothing has to be vendored for this.
public final class OpusDecoder {
    /// 48 kHz stereo: what Sunshine encodes, and what the SDP we send asks for.
    private let sampleRate: Double = 48000
    private let channels: UInt32 = 2

    /// Opus frames run at most 120 ms; at 48 kHz that is 5760 samples. Sizing the
    /// output for the largest legal frame means a longer packet duration than the
    /// one we negotiated can never overrun it.
    private let maxFrames: UInt32 = 5760

    private var converter: AudioConverterRef?
    private let lock = NSLock()

    /// The packet currently being fed to the converter, held for the input
    /// callback to hand over. AudioConverter pulls rather than being pushed.
    private var pending: Data?
    private var packetDescription = AudioStreamPacketDescription()
    private var output: UnsafeMutableRawPointer

    public init?() {
        output = UnsafeMutableRawPointer.allocate(
            byteCount: Int(maxFrames * channels) * MemoryLayout<Int16>.size,
            alignment: MemoryLayout<Int16>.alignment)

        var source = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,          // variable: Opus packets differ in size
            mFramesPerPacket: 0,         // variable: let the decoder read the TOC
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0)

        var destination = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0)

        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let created else {
            Log.error("[audio] no Opus decoder available: \(status)")
            output.deallocate()
            return nil
        }
        converter = created
        Log.info("[audio] Opus decoder ready (48kHz stereo)")
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        output.deallocate()
    }

    /// Decode one Opus packet. Returns interleaved 16-bit PCM, or nil.
    public func decode(_ packet: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let converter, !packet.isEmpty else { return nil }

        pending = packet
        packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.count))

        var frames = maxFrames
        var buffers = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: frames * channels * UInt32(MemoryLayout<Int16>.size),
                mData: output))

        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioConverterFillComplexBuffer(
            converter, decoderInputCallback, context, &frames, &buffers, nil)

        pending = nil
        // A converter that has run dry returns noErr with zero frames, which is
        // not an error — it just has nothing more for us this time.
        guard status == noErr || status == kNoMoreDataError, frames > 0 else {
            if status != noErr && status != kNoMoreDataError {
                Log.error("[audio] decode failed: \(status)")
            }
            return nil
        }
        return Data(bytes: output,
                    count: Int(frames * channels) * MemoryLayout<Int16>.size)
    }

    /// Reset after a gap, so the decoder does not try to interpolate across one.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        if let converter { AudioConverterReset(converter) }
    }

    fileprivate func provide(packets: inout UInt32,
                             buffers: UnsafeMutablePointer<AudioBufferList>,
                             description: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?)
        -> OSStatus {
        guard let packet = pending else {
            packets = 0
            return kNoMoreDataError
        }
        // Handed over exactly once: leaving it set would feed the same packet
        // round and round for as long as the converter kept asking.
        pending = nil

        packet.withUnsafeBytes { raw in
            buffers.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress)
            buffers.pointee.mBuffers.mDataByteSize = UInt32(packet.count)
            buffers.pointee.mBuffers.mNumberChannels = channels
        }
        buffers.pointee.mNumberBuffers = 1
        packets = 1
        description?.pointee = withUnsafeMutablePointer(to: &packetDescription) { $0 }
        return noErr
    }
}

/// AudioConverter pulls its input through this. `kNoMoreDataError` is the
/// documented way to say "that is all for now" without it being a failure.
private let kNoMoreDataError: OSStatus = -1

private func decoderInputCallback(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ buffers: UnsafeMutablePointer<AudioBufferList>,
    _ description: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else {
        packetCount.pointee = 0
        return kNoMoreDataError
    }
    let decoder = Unmanaged<OpusDecoder>.fromOpaque(context).takeUnretainedValue()
    return decoder.provide(packets: &packetCount.pointee,
                           buffers: buffers, description: description)
}
