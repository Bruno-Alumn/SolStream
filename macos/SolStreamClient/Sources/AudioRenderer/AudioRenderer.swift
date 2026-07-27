import Foundation
import AudioUnit
import CoreAudio
import AVFoundation
import SolStreamLogging
import SolStreamLogging

/// Renders Opus/S16LE audio frames using AudioUnit for low-latency playback.
///
/// Uses the RemoteIO AudioUnit (output unit) for macOS audio output.
/// Audio frames arrive from the stream connection, are decoded, and
/// queued in a ring buffer for the AudioUnit playback callback.
public final class AudioRenderer {
    private var audioUnit: AudioUnit?
    private var audioQueue: AudioQueueRef?
    private var isRunning = false

    // Audio format: 16-bit signed PCM, 48kHz, stereo
    private let sampleRate: Double = 48000
    private let channelCount: UInt32 = 2
    private let bitsPerChannel: UInt32 = 16

    // Simple ring buffer for audio data (internal for callback access)
    var ringBuffer = RingBuffer<Int16>(capacity: 48000 * 2 * 2) // ~1 second

    public init() {
        setupAudio()
    }

    deinit {
        stop()
        if let audioUnit {
            AudioUnitUninitialize(audioUnit)
            // Uninitialize releases the unit's resources but not the instance
            // itself. Without this each session left a live HAL output unit
            // behind — and every one of them holds a render callback whose
            // refcon is this object.
            AudioComponentInstanceDispose(audioUnit)
        }
        audioUnit = nil
    }

    /// Play a decoded audio frame. Called from the stream connection callback.
    /// Formats supported: 16-bit PCM, 48kHz stereo.
    public func playAudio(_ data: Data) {
        guard !data.isEmpty, isRunning else { return }

        // Process each 16-bit sample.
        let samples = data.withUnsafeBytes { buffer -> [Int16] in
            guard let baseAddress = buffer.baseAddress else { return [] }
            let count = buffer.count / MemoryLayout<Int16>.stride
            return Array(UnsafeBufferPointer(
                start: baseAddress.assumingMemoryBound(to: Int16.self),
                count: count
            ))
        }

        for sample in samples {
            ringBuffer.write(sample)
        }
    }

    /// Stop audio playback.
    public func stop() {
        isRunning = false
        if let audioUnit {
            AudioOutputUnitStop(audioUnit)
        }
    }

    // MARK: - Private

    private func setupAudio() {
        // Describe the audio unit.
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            Log.error("Failed to find audio component")
            return
        }

        var unit: AudioUnit?
        AudioComponentInstanceNew(component, &unit)
        guard let audioUnit = unit else {
            Log.error("Failed to create audio unit instance")
            return
        }
        self.audioUnit = audioUnit

        // Set the stream format: 48kHz, 16-bit signed, stereo.
        var streamFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger |
                          kAudioFormatFlagsNativeEndian |
                          kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bitsPerChannel / 8) * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bitsPerChannel / 8) * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )

        AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        // Set the render callback.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        // Initialize and start.
        AudioUnitInitialize(audioUnit)
        AudioOutputUnitStart(audioUnit)
        isRunning = true
    }
}

// MARK: - AudioUnit Callback

private let renderCallback: AURenderCallback = {(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus in
    guard let ioData else { return noErr }

    let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
    let bufferList = UnsafeMutableAudioBufferListPointer(ioData)

    for buffer in bufferList {
        guard let data = buffer.mData else { continue }
        let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.stride
        let samples = data.assumingMemoryBound(to: Int16.self)

        for i in 0..<frameCount {
            if renderer.ringBuffer.available > 0 {
                samples[i] = renderer.ringBuffer.read()
            } else {
                samples[i] = 0  // Silence underflow
            }
        }
    }

    return noErr
}

// MARK: - Simple Ring Buffer
/// Simple ring buffer for audio data (internal access for callback).
final class RingBuffer<T: ExpressibleByIntegerLiteral> {
    private var buffer: [T]
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [T](repeating: 0, count: capacity)
    }

    var available: Int { count }

    func write(_ value: T) {
        if count < capacity {
            buffer[writeIndex] = value
            writeIndex = (writeIndex + 1) % capacity
            count += 1
        }
        // If full, drop the oldest sample.
    }

    func read() -> T {
        precondition(count > 0)
        let value = buffer[readIndex]
        readIndex = (readIndex + 1) % capacity
        count -= 1
        return value
    }
}
