import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore
import SolStreamLogging

/// Decodes H.264 frames with VideoToolbox's hardware decoder.
///
/// Frames arrive from the reassembler in Annex-B form (start-code delimited).
/// VideoToolbox does not accept Annex-B: a `CMSampleBuffer` must hold AVCC —
/// each NAL unit prefixed with its big-endian length, matching the
/// `nalUnitHeaderLength` the format description was created with. Feeding it
/// raw Annex-B makes the decoder read `00 00 00 01` as a 1-byte NAL and produce
/// nothing, so the conversion below is what actually gets pictures on screen.
///
/// SPS/PPS come in-band: the host prefixes them to every IDR that the encoder
/// did not inline them into — see `Encoder::Emit` — so the format description is
/// built from the stream itself and there is nothing to parse out of band.
public final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let frameCallback: (CVPixelBuffer) -> Void

    private var sps: Data?
    private var pps: Data?
    private var lastKeyframeRequest = Date.distantPast
    private var loggedFirstFrame = false
    /// Last decode error and when it was logged, so a decoder failing on every
    /// frame at 60fps cannot spend the whole log file on one repeated line.
    private var lastDecodeError: OSStatus = noErr
    private var lastDecodeErrorLog = Date.distantPast

    /// How often to re-ask the host for an IDR while we have no parameter sets.
    private static let keyframeRequestInterval: TimeInterval = 0.5

    /// Guards the session against teardown while a decode is in flight.
    /// `decode()` runs on the media queue; `shutdown()` is called from the main
    /// thread, and the VideoToolbox callback holds an unretained pointer to
    /// self, so releasing the session underneath an in-flight frame would be a
    /// use-after-free.
    private let lock = NSLock()
    private var isShutDown = false

    /// A failure the decompression output callback saw, waiting to be dealt
    /// with by the next `decode()`. Guarded by `failureLock` — which exists
    /// precisely so that the callback never touches `lock`; see
    /// `noteAsyncDecodeFailure`.
    private let failureLock = NSLock()
    private var pendingAsyncFailure: OSStatus = noErr

    /// Whether a failure has cost the session its reference pictures, so that
    /// nothing but an IDR can be decoded. Guarded by `lock`.
    private var recovery = SessionRecovery()

    /// Called when the decoder needs a keyframe: no parameter sets yet, or a
    /// failure that cost it the pictures the next ones refer to. Pictures that
    /// are not IDRs are of no use to it until one arrives.
    public var onKeyframeNeeded: (() -> Void)?

    public typealias FrameCallback = (CVPixelBuffer) -> Void

    public init(frameCallback: @escaping FrameCallback) {
        self.frameCallback = frameCallback
    }

    deinit {
        shutdown()
    }

    /// Drain in-flight frames and tear the session down. Safe to call twice.
    /// Must complete before the decoder is released.
    public func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return }
        isShutDown = true
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
    }

    /// Decode one complete Annex-B frame.
    public func decode(_ annexB: Data, isIDR: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isShutDown else { return }

        let nalUnits = Self.splitAnnexB(annexB)
        guard !nalUnits.isEmpty else { return }

        var pictureNALs: [Range<Int>] = []
        var parameterSetsChanged = false
        // The host's flag, or an IDR slice in the picture itself.
        var startsOver = isIDR

        for nal in nalUnits {
            switch annexB[nal.lowerBound] & 0x1F {
            case 7:  // SPS
                let unit = annexB[nal]
                if sps != unit { sps = Data(unit); parameterSetsChanged = true }
            case 8:  // PPS
                let unit = annexB[nal]
                if pps != unit { pps = Data(unit); parameterSetsChanged = true }
            case 6, 9, 12:  // SEI, access unit delimiter, filler — not needed
                continue
            case 5:  // a slice of an IDR picture
                startsOver = true
                pictureNALs.append(nal)
            default:
                pictureNALs.append(nal)
            }
        }

        // Anything the output callback failed on since the last frame. It is
        // handled here, on the thread that owns the session, rather than there:
        // see `noteAsyncDecodeFailure`. The session may be dropped by this, in
        // which case the `session == nil` test further down rebuilds it from
        // this frame's parameter sets -- if this frame is an IDR, which is then
        // the repair rather than a reason to ask for another one.
        failureLock.lock()
        let asyncFailure = pendingAsyncFailure
        pendingAsyncFailure = noErr
        failureLock.unlock()
        if asyncFailure != noErr {
            noteDecodeFailure(asyncFailure, beforeIdr: startsOver)
        }

        // A session dropped by a failure is rebuilt by an IDR and nothing
        // else. See `SessionRecovery`.
        guard recovery.admit(isIdr: startsOver) else {
            requestKeyframeNow(throttled: true)
            return
        }

        // Rebuild when the parameter sets change, and also when the session
        // was lost: VideoToolbox can invalidate a session (GPU reset, display
        // change) and the host will keep sending the *same* SPS/PPS, so waiting
        // for a parameter-set change would blackscreen the stream for good.
        if let sps, let pps, parameterSetsChanged || session == nil {
            rebuildSession(sps: sps, pps: pps)
        }

        guard let formatDescription, let session else {
            // Nothing to decode against yet — ask the host for an IDR so the
            // parameter sets show up, and keep asking: the request is one
            // datagram, and it can be lost.
            if requestKeyframeNow(throttled: true) {
                Log.info("[decode] no parameter sets yet — requesting an IDR frame")
            }
            return
        }

        guard !pictureNALs.isEmpty else { return }

        let avccBytes = pictureNALs.reduce(0) { $0 + 4 + $1.count }
        guard let sampleBuffer = Self.makeSampleBuffer(annexB, nals: pictureNALs,
                                                       length: avccBytes,
                                                       formatDescription: formatDescription) else {
            return
        }

        var flagsOut: VTDecodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // No _EnableTemporalProcessing: it lets VideoToolbox hold pictures
            // back to reorder them, which a stream with no B-frames never needs
            // and which only adds latency.
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if status != noErr {
            noteDecodeFailure(status)
        } else if !loggedFirstFrame {
            loggedFirstFrame = true
            Log.info("[decode] first frame submitted (\(avccBytes) bytes, IDR: \(isIDR))")
        }
    }

    // MARK: - Annex-B

    /// Split an Annex-B byte stream into NAL units, dropping the start codes.
    /// The ranges are indices into `data` itself, so nothing is copied.
    static func splitAnnexB(_ data: Data) -> [Range<Int>] {
        let base = data.startIndex
        return data.withUnsafeBytes { bytes -> [Range<Int>] in
            var units: [Range<Int>] = []
            let count = bytes.count
            guard count > 4 else { return units }

            /// Returns the length of the start code at `index`, or 0.
            func startCodeLength(at index: Int) -> Int {
                guard index + 3 <= count else { return 0 }
                if bytes[index] == 0 && bytes[index + 1] == 0 {
                    if bytes[index + 2] == 1 { return 3 }
                    if index + 4 <= count && bytes[index + 2] == 0 && bytes[index + 3] == 1 { return 4 }
                }
                return 0
            }

            var index = 0
            // Skip to the first start code.
            while index < count, startCodeLength(at: index) == 0 { index += 1 }

            while index < count {
                let prefix = startCodeLength(at: index)
                guard prefix > 0 else { break }
                let nalStart = index + prefix
                var nalEnd = nalStart
                while nalEnd < count, startCodeLength(at: nalEnd) == 0 { nalEnd += 1 }
                if nalEnd > nalStart {
                    units.append((base + nalStart)..<(base + nalEnd))
                }
                index = nalEnd
            }
            return units
        }
    }

    /// Put a failure the output callback saw where the next `decode()` will
    /// find it, and do nothing else there.
    ///
    /// The callback used to take `lock` and call `noteDecodeFailure` directly,
    /// and that could hang the thread that submitted the frame against itself.
    /// `_EnableAsynchronousDecompression` is permission, not a promise:
    /// VideoToolbox is free to run the output callback on the caller's own
    /// thread from inside `VTDecompressionSessionDecodeFrame`, and
    /// `VTDecompressionSessionWaitForAsynchronousFrames` drains outstanding
    /// callbacks on the calling thread by design. Both of those are called with
    /// `lock` held, and `lock` is an `NSLock` — not recursive — so the callback
    /// would wait for a lock its own thread already owned. On the decode path
    /// that is the media queue stopping dead; on the shutdown path it is the
    /// main thread, and the app never quits.
    ///
    /// Recording the status and leaving is enough. `decode()` picks it up on
    /// the next frame — 16 ms later at 60fps — and does the logging and the
    /// session rebuild on the thread that owns the session, which is where
    /// invalidating a session VideoToolbox is currently standing inside of
    /// belongs anyway.
    private func noteAsyncDecodeFailure(_ status: OSStatus) {
        failureLock.lock()
        pendingAsyncFailure = status
        failureLock.unlock()
    }

    /// Deal with a decode failure, rebuilding the session for the errors Apple
    /// documents as recoverable only that way.
    ///
    /// Only `kVTInvalidSessionErr` used to drop the session. Everything else was
    /// logged and the frame discarded — including `kVTVideoDecoderMalfunctionErr`
    /// and `kVTVideoDecoderBadDataErr`, where recreating the session *is* the
    /// documented recovery. That mattered more than it sounds: the host repeats
    /// the same SPS/PPS ahead of every IDR, so `parameterSetsChanged` stays
    /// false, and the one other thing that rebuilds a session never fired. A
    /// decoder that malfunctioned once stayed wedged for the rest of the
    /// connection, showing a frozen picture that no keyframe could repair.
    ///
    /// `beforeIdr` says the failure was an earlier frame's, found waiting just
    /// as an IDR is about to be decoded.
    ///
    /// Call with `lock` held.
    func noteDecodeFailure(_ status: OSStatus, beforeIdr: Bool = false) {
        // A wedged decoder fails on every frame, 60 times a second. Unthrottled
        // that is the log file's whole budget spent on one repeated line.
        let now = Date()
        if status != lastDecodeError || now.timeIntervalSince(lastDecodeErrorLog) > 5 {
            Log.error("[decode] VTDecompressionSessionDecodeFrame failed: \(status)")
            lastDecodeError = status
            lastDecodeErrorLog = now
        }

        guard SessionRecovery.dropsSession(status) else { return }
        invalidateSession()
        // The next IDR rebuilds it; ask for one now rather than waiting for
        // the host's own keyframe interval. Unless that IDR is the frame in
        // hand, in which case it is already here.
        if recovery.sessionDropped(beforeIdr: beforeIdr) {
            requestKeyframeNow(throttled: false)
        }
    }

    /// Ask the host for an IDR, at most every `keyframeRequestInterval` when
    /// `throttled`. Returns whether it asked. Call with `lock` held.
    @discardableResult
    private func requestKeyframeNow(throttled: Bool) -> Bool {
        let now = Date()
        if throttled,
           now.timeIntervalSince(lastKeyframeRequest) < Self.keyframeRequestInterval {
            return false
        }
        lastKeyframeRequest = now
        onKeyframeNeeded?()
        return true
    }

    // MARK: - Session

    private func rebuildSession(sps: Data, pps: Data) {
        invalidateSession()

        var newFormat: CMVideoFormatDescription?
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var sizes = [spsBytes.count, ppsBytes.count]

        let status: OSStatus = spsBytes.withUnsafeBufferPointer { spsBuffer in
            ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                var pointers: [UnsafePointer<UInt8>] = [spsBuffer.baseAddress!, ppsBuffer.baseAddress!]
                return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                    sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormat
                        )
                    }
                }
            }
        }

        guard status == noErr, let newFormat else {
            Log.error("[decode] could not build a format description: \(status)")
            return
        }
        formatDescription = newFormat

        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        Log.info("[decode] stream is \(dimensions.width)x\(dimensions.height)")

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        let outputCallback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
            guard let refcon else { return }
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
            guard status == noErr, let pixelBuffer = imageBuffer else {
                // Asynchronous failures were logged and nothing more, so a
                // session that malfunctioned only on this path stayed wedged.
                if status != noErr {
                    decoder.noteAsyncDecodeFailure(status)
                }
                return
            }
            decoder.frameCallback(pixelBuffer)
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormat,
            decoderSpecification: [
                kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true
            ] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )

        guard sessionStatus == noErr, let newSession else {
            Log.error("[decode] VTDecompressionSessionCreate failed: \(sessionStatus)")
            return
        }
        session = newSession
        Log.info("[decode] hardware decoder ready")
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    /// A sample buffer holding `nals` of `annexB` in AVCC form: each NAL unit
    /// after its four-byte big-endian length, written straight into a block
    /// of `length` bytes allocated once.
    private static func makeSampleBuffer(_ annexB: Data, nals: [Range<Int>], length: Int,
                                         formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            Log.error("[decode] CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return nil
        }

        var destination: UnsafeMutablePointer<CChar>?
        status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                             totalLengthOut: nil, dataPointerOut: &destination)
        guard status == kCMBlockBufferNoErr, let destination else {
            Log.error("[decode] CMBlockBufferGetDataPointer failed: \(status)")
            return nil
        }
        annexB.withUnsafeBytes { source in
            var out = UnsafeMutableRawPointer(destination)
            for nal in nals {
                withUnsafeBytes(of: UInt32(nal.count).bigEndian) { prefix in
                    out.copyMemory(from: prefix.baseAddress!, byteCount: 4)
                }
                out = out.advanced(by: 4)

                out.copyMemory(from: source.baseAddress!.advanced(by: nal.lowerBound - annexB.startIndex),
                               byteCount: nal.count)
                out = out.advanced(by: nal.count)
            }
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length

        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else {
            Log.error("[decode] CMSampleBufferCreateReady failed: \(status)")
            return nil
        }
        return sampleBuffer
    }
}

/// What `decode()` does after a failure that cost it its session, kept apart
/// from VideoToolbox so it can be tested with statuses and keyframe flags.
///
/// A session rebuilt after a failure has no reference pictures, so every
/// P-frame decoded into it fails -- asynchronously, with
/// kVTVideoDecoderBadDataErr. Each of those failures used to drop the session
/// and the next P-frame to build another: a VTDecompressionSessionCreate and an
/// invalidate, 8-11 ms together, on the media thread for every frame until the
/// IDR arrived. And when it did, the last P-frame's failure was found waiting,
/// dropped the session once more and asked for a second IDR that the host then
/// sent for nothing.
struct SessionRecovery {
    /// A failure dropped the session, and only an IDR can start the next one.
    private(set) var awaitingIdr = false

    /// The statuses Apple documents as recoverable only by a new session.
    static func dropsSession(_ status: OSStatus) -> Bool {
        status == kVTInvalidSessionErr
            || status == kVTVideoDecoderMalfunctionErr
            || status == kVTVideoDecoderBadDataErr
    }

    /// The session has been dropped. Returns whether to ask the host for an
    /// IDR: not when the failure was an earlier frame's found just as an IDR
    /// is about to be decoded, because that IDR starts the new session itself.
    mutating func sessionDropped(beforeIdr: Bool) -> Bool {
        if beforeIdr { return false }
        awaitingIdr = true
        return true
    }

    /// Whether a picture may go to the session. An IDR always may, and ends
    /// the wait; anything else waits with it.
    mutating func admit(isIdr: Bool) -> Bool {
        if isIdr {
            awaitingIdr = false
            return true
        }
        return !awaitingIdr
    }
}
