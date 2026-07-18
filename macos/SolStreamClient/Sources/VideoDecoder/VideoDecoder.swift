import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia

/// Decodes H.264/H.265 video frames using VideoToolbox hardware decoder.
///
/// VideoToolbox provides hardware-accelerated video decoding on all
/// modern Macs (Apple Silicon + Intel). The decoder outputs CVPixelBuffers
/// which are passed to the MetalView for rendering via CVMetalTextureCache.
///
/// Thread safety: the decode callback can fire on any thread. The frame
/// callback dispatches to the main thread for rendering.
final class VideoDecoder {
    private var decompressionSession: MTDecompressionSession?
    private let frameCallback: (CVPixelBuffer) -> Void
    private var formatDescription: CMVideoFormatDescription?

    private let callbackQueue = DispatchQueue(label: "com.solstream.decoder",
                                              qos: .userInitiated)

    typealias FrameCallback = (CVPixelBuffer) -> Void

    init(frameCallback: @escaping FrameCallback) {
        self.frameCallback = frameCallback
    }

    deinit {
        flush()
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
    }

    /// Decode a compressed video frame (H.264/H.265 Annex B format).
    func decode(_ data: Data) {
        guard !data.isEmpty else { return }

        // Try to detect the format from the data (SPS/PPS for H.264).
        if formatDescription == nil {
            createFormatDescription(from: data)
        }

        guard let formatDesc = formatDescription else { return }

        // Create the decompression session on first use.
        if decompressionSession == nil {
            createSession(formatDesc: formatDesc)
        }

        guard let session = decompressionSession else { return }

        // Create a CMBlockBuffer from the data.
        var blockBuffer: CMBlockBuffer?
        let dataCopy = NSData(data: data)
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            Log.error("Failed to create CMBlockBuffer")
            return
        }

        // Fill the block buffer with the compressed data.
        CMBlockBufferReplaceDataBytes(
            with: dataCopy.bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: data.count
        )

        // Create the sample buffer.
        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(),
                                          preferredTimescale: 60000),
            decodeTimeStamp: .invalid
        )

        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else {
            Log.error("Failed to create CMSampleBuffer")
            return
        }

        // Submit for decoding.
        let flags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._EnableTemporalProcessing
        ]

        var flagsOut: VTDecodeInfoFlags = []
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )
    }

    /// Flush pending frames.
    func flush() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    // MARK: - Private

    private func createFormatDescription(from data: Data) {
        // H.264: look for AVCC/Annex B header (0x00 0x00 0x00 0x01 or 0x00 0x00 0x01).
        // For H.265: HEVC start code.
        // We auto-detect by scanning the first few bytes.

        let startCodeH264: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        let startCodeH264_3: [UInt8] = [0x00, 0x00, 0x01]
        let startCodeHEVC: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Check first few bytes for NAL unit type.
        guard data.count > 4 else { return }

        let nalType = data[4] & 0x1F
        let isH264 = (nalType == 7 || nalType == 8)  // SPS or PPS

        if isH264 {
            // Try to extract SPS/PPS from the stream.
            // In Phase 2, the format is negotiated during RTSP handshake.
            // For now, create a basic H.264 format description.
            let sps: [UInt8] = [0x67, 0x42, 0x00, 0x1e, 0xab]  // Baseline profile placeholder
            let pps: [UInt8] = [0x68, 0xce, 0x38, 0x80]

            var parameterSetSizes = [
                sps.count, pps.count
            ]

            var parameterSets: [UnsafePointer<UInt8>] = [
                UnsafePointer(sps),
                UnsafePointer(pps)
            ]

            // Use 'withUnsafeMutablePointer' to create pointers to the arrays.
            // For a real implementation, these would come from the RTSP SDP.
            parameterSets.withUnsafeMutableBufferPointer { psBuffer in
                parameterSetSizes.withUnsafeMutableBufferPointer { sizesBuffer in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 2,
                        parameterSetPointers: psBuffer.baseAddress!,
                        parameterSetSizes: sizesBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDescription
                    )
                }
            }
        }
        // H.265 detection and format description creation would go here
        // for Phase 2 full implementation.
    }

    private func createSession(formatDesc: CMFormatDescription) {
        let destinationPixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferWidthKey: 1920,
            kCVPixelBufferHeightKey: 1080,
        ]

        var session: MTDecompressionSession?
        let outputCallback: VTDecompressionOutputCallback = {(
            refcon: UnsafeMutableRawPointer?,
            _: UnsafeMutableRawPointer?,
            status: OSStatus,
            infoFlags: VTDecodeInfoFlags,
            imageBuffer: CVImageBuffer?,
            presentationTimeStamp: CMTime,
            presentationDuration: CMTime
        ) in
            guard status == noErr, let pixelBuffer = imageBuffer else { return }

            // Retrieve the decoder instance from refcon.
            let decoder = Unmanaged<VideoDecoder>.fromOpaque(refcon!).takeUnretainedValue()
            decoder.frameCallback(pixelBuffer)
        }

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            Log.error("VTDecompressionSessionCreate failed: \(status)")
            return
        }

        self.decompressionSession = session
    }
}

/// Type alias for compatibility with older VideoToolbox naming.
typealias MTDecompressionSession = VTDecompressionSession
