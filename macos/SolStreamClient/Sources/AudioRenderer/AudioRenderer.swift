import Foundation
import AudioUnit
import CoreAudio
import AVFoundation
import os
import SolStreamLogging

/// Renders Opus/S16LE audio frames using AudioUnit for low-latency playback.
///
/// Uses the RemoteIO AudioUnit (output unit) for macOS audio output.
/// Audio frames arrive from the stream connection, are decoded, and
/// queued in a ring buffer for the AudioUnit playback callback.
public final class AudioRenderer {
    private var audioUnit: AudioUnit?
    private var isRunning = false

    // Audio format: 16-bit signed PCM, 48kHz, stereo
    private let sampleRate: Double = 48000
    private let channelCount: UInt32 = 2
    private let bitsPerChannel: UInt32 = 16

    /// Interleaved stereo samples waiting to be played (internal for the callback).
    let ringBuffer = AudioRingBuffer()

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

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let count = raw.count / MemoryLayout<Int16>.stride
            // Whole stereo frames only — see AudioRingBuffer on why a stray odd
            // sample is not a rounding error but a permanent channel swap.
            let usable = count - (count % 2)
            guard usable > 0 else { return }
            ringBuffer.write(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Int16.self), count: usable))
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

    /// Build the output unit, and only claim to be running once it really is.
    ///
    /// Every call in here returns an OSStatus and every one of them used to be
    /// thrown away, with `isRunning` set at the end no matter what happened. A
    /// unit that never initialised or never started then went on accepting
    /// packets into the ring buffer, and the ring buffer's only reader is a
    /// render callback CoreAudio was never going to call — so the failure
    /// presented as audio that is simply silent, with a buffer that fills and
    /// trims itself forever and not one line anywhere saying why. Each step now
    /// stops at the first failure and names it with its status code, because
    /// that number is the only thing that distinguishes "no output device" from
    /// "format refused" after the fact.
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
        let instanceStatus = AudioComponentInstanceNew(component, &unit)
        guard instanceStatus == noErr, let audioUnit = unit else {
            Log.error("[audio] AudioComponentInstanceNew failed: \(instanceStatus)")
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

        let formatStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &streamFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            Log.error("[audio] the output unit refused 48 kHz 16-bit stereo: \(formatStatus)")
            return
        }

        // Set the render callback.
        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let callbackStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            Log.error("[audio] could not install the render callback: \(callbackStatus)")
            return
        }

        // Initialize and start.
        let initStatus = AudioUnitInitialize(audioUnit)
        guard initStatus == noErr else {
            Log.error("[audio] AudioUnitInitialize failed: \(initStatus)")
            return
        }

        let startStatus = AudioOutputUnitStart(audioUnit)
        guard startStatus == noErr else {
            Log.error("[audio] AudioOutputUnitStart failed: \(startStatus)")
            return
        }

        // Only now: `playAudio` gates on this, and everything it lets through
        // goes to a buffer the render callback is the sole reader of.
        isRunning = true
        Log.info("[audio] output unit running at 48 kHz, 16-bit stereo")
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
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.stride
        // One block copy rather than a per-sample loop with a lock acquisition
        // and a bounds check each time round.
        renderer.ringBuffer.read(into: data.assumingMemoryBound(to: Int16.self),
                                 count: sampleCount)
    }

    return noErr
}

// MARK: - Ring buffer

/// Interleaved stereo audio waiting to be played, with a bounded backlog.
///
/// Three things this has to get right that the previous version did not.
///
/// **It is shared across threads.** `write` runs on the stream's audio queue and
/// `read` on the CoreAudio HAL's realtime thread. The indices used to be plain
/// `Int`s incremented from both — a data race, and undefined behaviour, whose
/// visible form is a read pointer that drifts permanently out of step with the
/// write pointer and never recovers.
///
/// **The backlog has to be trimmed.** On overrun the old version dropped the
/// *arriving* sample (its comment claimed the opposite). Since the render
/// callback consumes at exactly the device rate and nothing ever drained the
/// buffer, every jitter burst that filled it became permanent latency — a
/// one-way ratchet that saturated at the full capacity of two seconds behind
/// video and stayed there. The host's audio clock and this Mac's output clock
/// are not the same clock, so a backlog left uncorrected only grows.
///
/// **Everything moves in whole frames.** The stream is interleaved L,R,L,R.
/// Writing sample-by-sample meant the buffer could fill part-way through a
/// packet and reject an odd number of samples, which shifts the parity of the
/// interleave for everything after it: left channel out of the right speaker,
/// for the rest of the session.
///
/// A lock on the realtime thread is not ideal. `os_unfair_lock` donates priority
/// so the audio queue cannot leave the IO thread waiting on a descheduled
/// writer, and the critical section is a bounded `memcpy` of at most one buffer.
/// That is a real trade, but the alternative it replaces was undefined
/// behaviour, not a faster correct thing.
final class AudioRingBuffer {
    private let storage: UnsafeMutablePointer<Int16>
    private let capacity: Int
    /// Backlog to aim for after a trim, and the level that triggers one.
    private let target: Int
    private let ceiling: Int

    private var head = 0     // next write
    private var tail = 0     // next read
    private var filled = 0

    private let lock: UnsafeMutablePointer<os_unfair_lock>

    /// Whole frames discarded to keep latency bounded, for diagnostics.
    private(set) var framesDropped: UInt64 = 0

    /// Holding playback until `prefill` has arrived. True at the start and
    /// again after every underrun. The host sends nothing at all while the PC
    /// is silent, so every sound used to begin playing from an empty buffer,
    /// and the first late 5 ms packet on Wi-Fi was a click. A short cushion
    /// first costs that much latency once per sound and removes the clicks.
    private var priming = true
    private let prefill: Int
    /// At most this much is trimmed per packet when the buffer runs long, so
    /// drift is corrected a few milliseconds at a time instead of as one
    /// audible 70 ms jump from the ceiling back down to the target.
    private let trimStep: Int

    init(sampleRate: Int = 48000, channels: Int = 2,
         capacityMilliseconds: Int = 500,
         targetMilliseconds: Int = 50,
         ceilingMilliseconds: Int = 120,
         prefillMilliseconds: Int = 25) {
        func samples(_ milliseconds: Int) -> Int {
            let frames = sampleRate * milliseconds / 1000
            return frames * channels
        }
        capacity = samples(capacityMilliseconds)
        target = samples(targetMilliseconds)
        ceiling = samples(ceilingMilliseconds)
        // Never more cushion than the target the buffer is steered towards.
        prefill = min(samples(prefillMilliseconds), target)
        priming = prefill > 0
        trimStep = samples(2)

        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var available: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return filled
    }

    func write(_ samples: UnsafeBufferPointer<Int16>) {
        guard let source = samples.baseAddress, !samples.isEmpty else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        // A packet bigger than the whole ring can only be partly kept; keep its
        // newest end, which is what dropping the oldest means at that scale.
        var count = samples.count
        var offset = 0
        if count > capacity {
            offset = count - capacity
            count = capacity
        }

        if filled + count > capacity {
            discardOldest(filled + count - capacity)
        }

        let first = min(count, capacity - head)
        storage.advanced(by: head).update(from: source.advanced(by: offset), count: first)
        if count > first {
            storage.update(from: source.advanced(by: offset + first), count: count - first)
        }
        head = (head + count) % capacity
        filled += count

        // Correct drift continuously rather than only at saturation, and
        // gently: a couple of milliseconds per packet until back at target. A
        // backlog past twice the ceiling is not drift -- the Mac stalled, or a
        // burst arrived at once -- and goes straight back to the target.
        if filled > ceiling {
            discardOldest(filled > 2 * ceiling ? filled - target
                                               : min(filled - target, trimStep))
        }
    }

    /// Fill `destination`, padding with silence on underrun.
    func read(into destination: UnsafeMutablePointer<Int16>, count: Int) {
        guard count > 0 else { return }
        os_unfair_lock_lock(lock)
        if priming && filled >= prefill { priming = false }
        let take = priming ? 0 : min(count, filled)
        if !priming && take < count { priming = true }   // underrun: re-cushion
        if take > 0 {
            let first = min(take, capacity - tail)
            destination.update(from: storage.advanced(by: tail), count: first)
            if take > first {
                destination.advanced(by: first).update(from: storage, count: take - first)
            }
            tail = (tail + take) % capacity
            filled -= take
        }
        os_unfair_lock_unlock(lock)

        if take < count {
            destination.advanced(by: take).update(repeating: 0, count: count - take)
        }
    }

    /// Drop the oldest audio, always in whole frames so the L,R interleave keeps
    /// its parity. Call with the lock held.
    private func discardOldest(_ samples: Int) {
        var amount = samples
        if amount % 2 != 0 { amount += 1 }   // round up to a whole frame
        amount = min(amount, filled)
        amount -= amount % 2                  // and stay on the frame boundary
        guard amount > 0 else { return }
        tail = (tail + amount) % capacity
        filled -= amount
        framesDropped &+= UInt64(amount / 2)
    }
}
