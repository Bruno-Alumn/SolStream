import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore
import SolStreamLogging

/// Decodes H.264 frames with VideoToolbox's hardware decoder.
///
/// Frames arrive from the depacketizer in Annex-B form (start-code delimited).
/// VideoToolbox does not accept Annex-B: a `CMSampleBuffer` must hold AVCC —
/// each NAL unit prefixed with its big-endian length, matching the
/// `nalUnitHeaderLength` the format description was created with. Feeding it
/// raw Annex-B makes the decoder read `00 00 00 01` as a 1-byte NAL and produce
/// nothing, so the conversion below is what actually gets pictures on screen.
///
/// SPS/PPS come in-band: Sunshine repeats them ahead of every IDR frame, so the
/// format description is built from the stream itself and no SDP parsing is
/// needed.
public final class VideoDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let frameCallback: (CVPixelBuffer) -> Void

    private var sps: Data?
    private var pps: Data?
    private var lastKeyframeRequest = Date.distantPast
    private var loggedFirstFrame = false

    /// How often to re-ask the host for an IDR while we have no parameter sets.
    private static let keyframeRequestInterval: TimeInterval = 0.5

    /// Guards the session against teardown while a decode is in flight.
    /// `decode()` runs on the media queue; `shutdown()` is called from the main
    /// thread, and the VideoToolbox callback holds an unretained pointer to
    /// self, so releasing the session underneath an in-flight frame would be a
    /// use-after-free.
    private let lock = NSLock()
    private var isShutDown = false

    /// Called when the decoder needs a keyframe (no parameter sets yet).
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

        var pictureNALs: [Data] = []
        var parameterSetsChanged = false

        for nal in nalUnits {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7:  // SPS
                if sps != nal { sps = nal; parameterSetsChanged = true }
            case 8:  // PPS
                if pps != nal { pps = nal; parameterSetsChanged = true }
            case 6, 9, 12:  // SEI, access unit delimiter, filler — not needed
                continue
            default:
                pictureNALs.append(nal)
            }
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
            // parameter sets show up. This has to keep retrying rather than
            // fire once: joining an in-progress session (/resume) drops us
            // mid-GOP, and the control channel we send the request on isn't
            // even connected until after PLAY, so the first attempts are lost.
            let now = Date()
            if now.timeIntervalSince(lastKeyframeRequest) >= Self.keyframeRequestInterval {
                lastKeyframeRequest = now
                Log.info("[decode] no parameter sets yet — requesting an IDR frame")
                onKeyframeNeeded?()
            }
            return
        }

        guard !pictureNALs.isEmpty else { return }

        var avcc = Data()
        for nal in pictureNALs {
            withUnsafeBytes(of: UInt32(nal.count).bigEndian) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        guard let sampleBuffer = Self.makeSampleBuffer(avcc, formatDescription: formatDescription) else {
            return
        }

        var flagsOut: VTDecodeInfoFlags = []
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if status != noErr {
            Log.error("[decode] VTDecompressionSessionDecodeFrame failed: \(status)")
            if status == kVTInvalidSessionErr {
                invalidateSession()
            }
        } else if !loggedFirstFrame {
            loggedFirstFrame = true
            Log.info("[decode] first frame submitted (\(avcc.count) bytes, IDR: \(isIDR))")
        }
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    // MARK: - Annex-B

    /// Split an Annex-B byte stream into NAL units, dropping the start codes.
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
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
                units.append(Data(bytes[nalStart..<nalEnd]))
            }
            index = nalEnd
        }
        return units
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
                if status != noErr { Log.error("[decode] frame dropped: \(status)") }
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

    private static func makeSampleBuffer(_ data: Data,
                                         formatDescription: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            Log.error("[decode] CMBlockBufferCreateWithMemoryBlock failed: \(status)")
            return nil
        }

        status = data.withUnsafeBytes { buffer in
            CMBlockBufferReplaceDataBytes(with: buffer.baseAddress!,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: data.count)
        }
        guard status == kCMBlockBufferNoErr else {
            Log.error("[decode] CMBlockBufferReplaceDataBytes failed: \(status)")
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 90000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
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
