// VideoNAL.swift — the two video codecs, and reading their NAL unit headers.
//
// H.264 is what every host has always sent. HEVC is offered in `media open` as
// `"videoCodecs":"hevc,h264"` and the host answers with the one it chose in
// `"videoCodec"`; a host that answers nothing predates the choice and sends
// H.264. See docs/transport-smt1.md. The host reads its own pictures with the
// same rules, in windows/SolStreamAgent/media/video_codec.h.

import Foundation

public enum VideoCodec: String, Sendable, CaseIterable {
    case h264, hevc

    /// For the log and the settings: "H.264", "HEVC".
    public var title: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

/// NAL unit types, for whichever codec a stream is in.
///
/// An H.264 NAL header is one byte, the type in its low five bits. An HEVC one
/// is two, the type in bits 1-6 of the first. The same byte means different
/// things in each -- H.264's SPS, 0x67, read as HEVC is type 51 -- so a stream
/// is only ever read as the codec the host said it was sending.
public enum VideoNAL {
    /// What one NAL unit is for, as far as decoding needs to know.
    public enum Role: Equatable, Sendable {
        /// H.264's SPS and PPS; HEVC's VPS, SPS and PPS.
        case parameterSet
        /// A slice of a picture decoding can start from: H.264's IDR, HEVC's
        /// IRAP pictures.
        case keyframeSlice
        /// Any other slice.
        case slice
        /// SEI, delimiters, filler: nothing the decoder needs.
        case other
    }

    /// The bytes a header takes, and so the least a NAL unit can be.
    public static func headerLength(_ codec: VideoCodec) -> Int {
        codec == .hevc ? 2 : 1
    }

    /// The type in the header that starts with `first`.
    public static func type(_ codec: VideoCodec, first: UInt8) -> Int {
        codec == .hevc ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }

    public static func role(_ codec: VideoCodec, type: Int) -> Role {
        switch codec {
        case .h264:
            switch type {
            case 7, 8: return .parameterSet
            case 5: return .keyframeSlice
            case 1...4: return .slice
            default: return .other
            }
        case .hevc:
            switch type {
            case 32, 33, 34: return .parameterSet
            // BLA_W_LP, BLA_W_RADL, BLA_N_LP, IDR_W_RADL, IDR_N_LP, CRA_NUT.
            // Nothing after any of them refers to a picture before it -- the
            // host sends no B-frames, so a CRA has no leading pictures to
            // skip -- which makes each one an IDR as far as the hold and the
            // reassembly are concerned.
            case 16...21: return .keyframeSlice
            case 0...31: return .slice
            default: return .other
            }
        }
    }

    /// Whether this Annex B picture is one decoding can start from, decided
    /// by its first slice: every slice of a picture is the same kind, so a
    /// P-frame is read only as far as its own first slice header.
    public static func isKeyframe(_ codec: VideoCodec, annexB: Data) -> Bool {
        for unit in splitAnnexB(annexB) where unit.count >= headerLength(codec) {
            switch role(codec, type: type(codec, first: annexB[unit.lowerBound])) {
            case .keyframeSlice: return true
            case .slice: return false
            case .parameterSet, .other: continue
            }
        }
        return false
    }

    /// Split an Annex-B byte stream into NAL units, dropping the start codes.
    /// The ranges are indices into `data` itself, so nothing is copied.
    public static func splitAnnexB(_ data: Data) -> [Range<Int>] {
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
}
