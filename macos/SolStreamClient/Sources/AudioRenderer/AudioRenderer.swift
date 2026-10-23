import Foundation
import AudioUnit
import CoreAudio
import AVFoundation
import os
import SolStreamLogging

/// Plays the host's sound -- 16-bit PCM, or Opus decoded on the way in --
/// through the default output AudioUnit.
///
/// Packets arrive from the stream connection, are decoded if they need to be,
/// and are queued in a ring buffer for the AudioUnit's render callback.
public final class AudioRenderer {
    private var audioUnit: AudioUnit?
    private var isRunning = false

    // Audio format: 16-bit signed PCM, 48kHz, stereo
    private let sampleRate: Double = 48000
    private let channelCount: UInt32 = 2

    /// Interleaved stereo samples waiting to be played (internal for the callback).
    let ringBuffer = AudioRingBuffer(latency: Buffering.lowLatency.latency)
    /// Volume and mute, read by the render callback (internal for the callback).
    let gain = AudioGain()

    /// How much audio is held before playing, traded against latency.
    public enum Buffering: String, CaseIterable, Sendable {
        /// The least delay; right on a wired or good home network.
        case lowLatency
        /// More cushion, for Wi-Fi and the internet, where packets arrive in
        /// clumps and a thin buffer runs dry between them.
        case steady

        /// Steady roughly doubles each figure: a Wi-Fi or internet path
        /// delivers in clumps tens of milliseconds apart, and a 50 ms target
        /// with a 120 ms ceiling both runs dry between clumps and trims away
        /// the backlog a clump leaves, which is the cushion for the next gap.
        var latency: AudioRingBuffer.Latency {
            switch self {
            case .lowLatency:
                return .init(prefillMilliseconds: 25, targetMilliseconds: 50, ceilingMilliseconds: 120)
            case .steady:
                return .init(prefillMilliseconds: 60, targetMilliseconds: 100, ceilingMilliseconds: 220)
            }
        }
    }

    /// 0...1, applied to every sample played, as amplitude. A change is ramped
    /// over 10 ms, so a slider drag never clicks. Safe to set from any thread
    /// while the stream plays. A slider's position goes through
    /// `amplitude(forPosition:)` first.
    public var volume: Float {
        get { gain.volume }
        set { gain.volume = newValue }
    }

    /// The amplitude for a volume slider at `position` (0...1).
    ///
    /// Heard loudness goes roughly as amplitude to the power 0.6, so a slider
    /// that maps straight to amplitude is -6 dB at its middle -- still most of
    /// the way to full -- and squeezes everything from quiet to silent into its
    /// bottom tenth. Squared, the middle is -12 dB, which sounds about half as
    /// loud, and a tenth of the way along is -40 dB rather than -20.
    public static func amplitude(forPosition position: Float) -> Float {
        let clamped = position.isNaN ? 1 : min(max(position, 0), 1)
        return clamped * clamped
    }

    /// Silence without stopping the stream or forgetting the volume. The unit
    /// keeps running and keeps draining the buffer, so unmuting resumes in
    /// step with the picture rather than from a backlog built up while muted.
    public var isMuted: Bool {
        get { gain.isMuted }
        set { gain.isMuted = newValue }
    }

    /// See `Buffering`. Safe to change while the stream plays, and nothing is
    /// interrupted to apply it: a lower ceiling trims the backlog down a few
    /// milliseconds per packet, and a larger cushion is built the next time
    /// playback primes -- which on the paths that need it is the next underrun.
    /// Set it from one thread at a time; StreamSession uses the main thread.
    public var buffering: Buffering = .lowLatency {
        didSet {
            guard buffering != oldValue else { return }
            ringBuffer.setLatency(buffering.latency)
        }
    }

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

    /// Play one packet of 16-bit PCM, 48 kHz stereo, interleaved. Called from
    /// the stream connection's receive thread.
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

    /// Play one Opus packet. Called from the stream connection's receive
    /// thread, and only ever from that one thread: the decoder keeps state
    /// from one packet to the next.
    ///
    /// - Returns: false when the packet could not be decoded.
    @discardableResult
    public func playOpus(_ packet: Data) -> Bool {
        guard !packet.isEmpty, isRunning else { return false }
        return opus.decode(packet) { samples in
            let usable = samples.count - (samples.count % 2)
            guard usable > 0 else { return }
            ringBuffer.write(UnsafeBufferPointer(rebasing: samples[0..<usable]))
        }
    }

    /// Built on the first Opus packet, so a stream of PCM -- from a host that
    /// predates Opus, or chosen as Lossless -- never builds a decoder.
    private lazy var opus = OpusDecoder(sampleRate: sampleRate, channels: Int(channelCount))

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
        var streamFormat = AudioStreamBasicDescription.pcm16(sampleRate: sampleRate,
                                                             channels: Int(channelCount))

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
        let samples = data.assumingMemoryBound(to: Int16.self)
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.stride
        // One block copy rather than a per-sample loop with a lock acquisition
        // and a bounds check each time round.
        renderer.ringBuffer.read(into: samples, count: sampleCount)
        renderer.gain.apply(to: samples, count: sampleCount,
                            channels: Int(buffer.mNumberChannels))
    }

    return noErr
}

// MARK: - Gain

/// Volume and mute, set from the main thread and applied on the render thread.
///
/// The render thread must never wait on the main thread, so it reads the level
/// with `os_unfair_lock_trylock` and, in the rare buffer where the main thread
/// is mid-store, keeps the level it already had; the next buffer, ten
/// milliseconds later, picks up the new one. An aligned 32-bit load would also
/// never tear on arm64, but a Swift load racing a store is undefined behaviour
/// whatever the instruction does, and a try-lock costs one atomic compare.
///
/// Every change is a linear ramp from the gain playing now to the new one. A
/// step in gain is a step in the waveform, and at full scale that is a click --
/// worst of all for mute, which is a step all the way to zero.
///
/// The ramp is a fixed 10 ms and carries on across buffers, rather than lasting
/// one render buffer: the buffer is as short as the smallest any app on the
/// same output device asks for, and with a browser or a music app holding it
/// at 64 frames a one-buffer ramp is 1.3 ms, short enough to click again.
final class AudioGain {
    /// Frames a change is spread over: 10 ms at the stream's 48 kHz.
    static let rampFrames = 480

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    // Guarded by `lock`.
    private var volumeStorage: Float = 1
    private var mutedStorage = false

    // Render thread only: the level the last frame played at, where the ramp
    // is heading, and how far it still has to go.
    private var current: Float = 1
    private var target: Float = 1
    private var step: Float = 0
    private var rampLeft = 0

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    var volume: Float {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return volumeStorage
        }
        set {
            // A NaN would reach Int16(_:) as NaN and trap on the render thread.
            let clamped = newValue.isNaN ? 1 : min(max(newValue, 0), 1)
            os_unfair_lock_lock(lock)
            volumeStorage = clamped
            os_unfair_lock_unlock(lock)
        }
    }

    var isMuted: Bool {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return mutedStorage
        }
        set {
            os_unfair_lock_lock(lock)
            mutedStorage = newValue
            os_unfair_lock_unlock(lock)
        }
    }

    /// Scale `count` interleaved samples in place. Render thread only: no
    /// allocation, no blocking, no Objective-C.
    func apply(to samples: UnsafeMutablePointer<Int16>, count: Int, channels: Int) {
        guard count > 0, channels > 0 else { return }
        if os_unfair_lock_trylock(lock) {
            let wanted = mutedStorage ? 0 : volumeStorage
            os_unfair_lock_unlock(lock)
            // A new level mid-ramp starts a fresh ramp from wherever the old
            // one had got to, so a slider drag is followed without a corner.
            if wanted != target {
                target = wanted
                rampLeft = Self.rampFrames
                step = (target - current) / Float(rampLeft)
            }
        }

        if rampLeft == 0 {
            if current == 1 { return }   // full volume: leave the samples bit-exact
            if current == 0 {
                samples.update(repeating: 0, count: count)
                return
            }
        }

        // Per frame, not per sample, so left and right of one frame always
        // get the same gain and the stereo image does not wobble mid-ramp.
        let frames = count / channels
        var index = 0
        for _ in 0..<frames {
            if rampLeft > 0 {
                rampLeft -= 1
                // Land on the target exactly: a rounding error short of 1 or 0
                // would keep the fast paths above from ever applying again.
                current = rampLeft == 0 ? target : current + step
            }
            let gain = min(max(current, 0), 1)
            for _ in 0..<channels {
                samples[index] = Self.scale(samples[index], by: gain)
                index += 1
            }
        }
        // A partial frame cannot happen with whole-frame buffers, but if one
        // did it should play at the level its frame would have.
        while index < count {
            samples[index] = Self.scale(samples[index], by: min(max(current, 0), 1))
            index += 1
        }
    }

    /// With `gain` in 0...1 the product is inside Int16's range, so the
    /// conversion cannot trap; the clamp is there so that stays true.
    @inline(__always)
    private static func scale(_ sample: Int16, by gain: Float) -> Int16 {
        let scaled = (Float(sample) * gain).rounded()
        return Int16(min(max(scaled, -32768), 32767))
    }
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
    /// The three levels the backlog is steered by, in milliseconds.
    struct Latency: Equatable {
        /// Held before playback starts, and again after every underrun.
        var prefillMilliseconds: Int
        /// Where a trim brings the backlog back down to.
        var targetMilliseconds: Int
        /// The backlog past which trimming starts.
        var ceilingMilliseconds: Int
    }

    private let storage: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private let sampleRate: Int
    private let channels: Int
    /// Backlog to aim for after a trim, and the level that triggers one.
    /// Guarded by `lock`, like everything below that changes: `setLatency`
    /// swaps them on the main thread while `write` and `read` use them.
    private var target: Int
    private var ceiling: Int

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
    private var prefill: Int
    /// At most this much is trimmed per packet when the buffer runs long, so
    /// drift is corrected a few milliseconds at a time instead of as one
    /// audible 70 ms jump from the ceiling back down to the target.
    private let trimStep: Int

    init(sampleRate: Int = 48000, channels: Int = 2,
         capacityMilliseconds: Int = 500,
         targetMilliseconds: Int = 50,
         ceilingMilliseconds: Int = 120,
         prefillMilliseconds: Int = 25) {
        self.sampleRate = sampleRate
        self.channels = channels
        capacity = Self.samples(capacityMilliseconds, sampleRate: sampleRate, channels: channels)
        target = Self.samples(targetMilliseconds, sampleRate: sampleRate, channels: channels)
        ceiling = Self.samples(ceilingMilliseconds, sampleRate: sampleRate, channels: channels)
        // Never more cushion than the target the buffer is steered towards.
        prefill = min(Self.samples(prefillMilliseconds, sampleRate: sampleRate, channels: channels),
                      target)
        priming = prefill > 0
        trimStep = Self.samples(2, sampleRate: sampleRate, channels: channels)

        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)

        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    convenience init(latency: Latency, capacityMilliseconds: Int = 500) {
        self.init(capacityMilliseconds: capacityMilliseconds,
                  targetMilliseconds: latency.targetMilliseconds,
                  ceilingMilliseconds: latency.ceilingMilliseconds,
                  prefillMilliseconds: latency.prefillMilliseconds)
    }

    private static func samples(_ milliseconds: Int, sampleRate: Int, channels: Int) -> Int {
        let frames = sampleRate * milliseconds / 1000
        return frames * channels
    }

    /// Swap the three levels on a live stream.
    ///
    /// Nothing is dropped or held here. The next `write` trims towards a lower
    /// ceiling at the usual few milliseconds per packet, and a larger prefill
    /// applies the next time playback primes; forcing a re-prime now would cut
    /// the sound that is playing to build a cushion nobody had yet missed.
    func setLatency(_ latency: Latency) {
        let newTarget = Self.samples(latency.targetMilliseconds, sampleRate: sampleRate, channels: channels)
        let newCeiling = Self.samples(latency.ceilingMilliseconds, sampleRate: sampleRate, channels: channels)
        let newPrefill = min(Self.samples(latency.prefillMilliseconds, sampleRate: sampleRate, channels: channels),
                             newTarget)
        os_unfair_lock_lock(lock)
        target = newTarget
        ceiling = newCeiling
        prefill = newPrefill
        os_unfair_lock_unlock(lock)
    }

    /// The levels in force, in samples, for tests.
    var levels: (prefill: Int, target: Int, ceiling: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (prefill, target, ceiling)
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
