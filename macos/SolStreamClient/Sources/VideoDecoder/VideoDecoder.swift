import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import QuartzCore
import SolStreamLogging

/// Decodes H.264/H.265 video frames using VideoToolbox hardware decoder.
///
/// VideoToolbox provides hardware-accelerated video decoding on all
/// modern Macs (Apple Silicon + Intel). The decoder outputs CVPixelBuffers
/// which are passed to the MetalView for rendering via CVMetalTextureCache.
///
/// Thread safety: the decode callback can fire on any thread. The frame
/// callback dispatches to the main thread for rendering.
public final class VideoDecoder {
    private var decompressionSession: MTDecompressionSession?
    private let frameCallback: (CVPixelBuffer) -> Void
    private var formatDescription: CMVideoFormatDescription?

    private let callbackQueue = DispatchQueue(label: "com.solstream.decoder",
                                              qos: .userInitiated)

    /// SPS/PPS from RTSP handshake (set by StreamConnection).
    public var streamSPS: Data?
    public var streamPPS: Data?

    public typealias FrameCallback = (CVPixelBuffer) -> Void

    public init(frameCallback: @escaping FrameCallback) {
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
    public func decode(_ data: Data) {
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
    public func flush() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
    }

    // MARK: - Private

    private func createFormatDescription(from data: Data) {
        // Auto-detect codec by scanning for start codes and NAL unit types.
        guard data.count > 5 else { return }

        // Check for H.264 (Annex B start code: 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01)
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            let nalHeader = data[4]
            let nalType = nalHeader & 0x1F

            // H.264 SPS (7) or PPS (8) — format from RTSP handshake is used below.
            if nalType == 7 || nalType == 8 {
                // Format will be created from RTSP SPS/PPS below.
                return
            }
        }

        // Check for H.265/HEVC (start code + NAL unit type 32-34 for VPS/SPS/PPS)
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            let nalHeader = data[6]  // HEVC NAL header is 2 bytes
            let nalType = (nalHeader >> 1) & 0x3F

            // HEVC VPS (32), SPS (33), PPS (34)
            if nalType >= 32 && nalType <= 34 {
                createHEVCFormatDescription(data: data)
                return
            }
        }

        // Fallback: try H.264 if we have SPS/PPS from RTSP handshake
        if let sps = streamSPS, let pps = streamPPS {
            createH264FormatDescription(sps: sps, pps: pps)
        }
    }

    private func createH264FormatDescription(sps: Data, pps: Data) {
        let spsPtr = [UInt8](sps)
        let ppsPtr = [UInt8](pps)
        var parameterSetSizes = [sps.count, pps.count]

        spsPtr.withUnsafeBufferPointer { spsBuf in
            ppsPtr.withUnsafeBufferPointer { ppsBuf in
                var parameterSets: [UnsafePointer<UInt8>] = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                psBuffer in
                    let _ = parameterSetSizes.withUnsafeMutableBufferPointer { sizesBuffer in
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
        }
    }

    private func createHEVCFormatDescription(data: Data) {
        // HEVC format description creation
        // For now, create a basic HEVC format description
        // In production, extract VPS/SPS/PPS from the data
        let codec = kCMVideoCodecType_HEVC

        // Create format description with codec type
        var videoFormatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codec,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &videoFormatDesc
        )

        if status == noErr {
            formatDescription = videoFormatDesc
        }
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
