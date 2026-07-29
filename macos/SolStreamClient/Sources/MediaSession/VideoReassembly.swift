// VideoReassembly.swift — turn fragments back into coded pictures.
//
// The video header is sixteen bytes, and `fragOff` is a BYTE OFFSET rather than
// a fragment index. That makes a fragment a memcpy at base+off, and it means
// variable-length fragments -- which is what slice-early sending produces --
// need no index arithmetic at all.
//
//   off  w  field
//    0   1  type = 0x10
//    1   1  flags: 0x01 frame start, 0x04 frame end, 0x08 IDR
//    2   1  ltr
//    3   1  sliceId
//    4   4  frameId
//    8   3  fragOff
//   11   1  parameter-set generation
//   12   4  captureUs, the host's clock when the picture was captured

import Foundation

public final class VideoReassembler {

    public struct Picture {
        public let frameId: UInt32
        public let bytes: Data
        public let isIdr: Bool
        public let captureUs: UInt32
        /// Milliseconds from this picture's first fragment to its last.
        public let spreadMs: Double
    }

    public var onPicture: ((Picture) -> Void)?
    /// A picture that will never be complete. The caller decides whether that is
    /// worth a keyframe request.
    public var onDamaged: ((UInt32) -> Void)?

    public private(set) var complete: UInt64 = 0
    public private(set) var damaged: UInt64 = 0
    public private(set) var fragments: UInt64 = 0
    public private(set) var lastCompleteFrame: UInt32 = 0

    /// Close a picture this long after its LAST fragment, not its first.
    ///
    /// Timing from the first fragment is defect #5 of the six in
    /// docs/transport-smt1.md: an IDR on a 20 Mbit/s path takes 80-160 ms to
    /// arrive, so a 25 ms timer started at its first fragment declares it
    /// damaged before it has landed and asks for another one -- which is bigger.
    /// An idle timeout is the standard reassembly rule and does not have that
    /// failure.
    private let idleTimeoutMs: Double = 25

    private struct Assembly {
        var bytes: [UInt8]
        var have = 0
        var total = -1
        var isIdr = false
        var captureUs: UInt32 = 0
        var firstSeen: UInt64
        var lastSeen: UInt64
    }

    private var building: [UInt32: Assembly] = [:]
    /// Pictures already emitted or given up on, so a straggler fragment does not
    /// start a fresh assembly that then times out and asks for a keyframe.
    private var finished: Set<UInt32> = []
    private var highestSeen: UInt32 = 0

    public init() {}

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public func ingest(_ plaintext: Data) {
        guard plaintext.count > 16 else { return }
        let b = [UInt8](plaintext)
        guard b[0] == SMT.typeVideo else { return }
        fragments &+= 1

        let flags = b[1]
        let frameId = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16)
                    | (UInt32(b[6]) << 8) | UInt32(b[7])
        let fragOff = (Int(b[8]) << 16) | (Int(b[9]) << 8) | Int(b[10])
        let captureUs = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16)
                      | (UInt32(b[14]) << 8) | UInt32(b[15])
        let payloadCount = b.count - 16
        guard payloadCount > 0, finished.contains(frameId) == false else { return }

        if frameId > highestSeen { highestSeen = frameId }

        let stamp = Self.now()
        var assembly = building[frameId]
            ?? Assembly(bytes: [UInt8](repeating: 0, count: 512 * 1024),
                        firstSeen: stamp, lastSeen: stamp)
        let end = fragOff + payloadCount
        if end > assembly.bytes.count {
            // A picture larger than the buffer is a picture this build cannot
            // reassemble, and growing here would be a reallocation in the
            // receive path. 512 KB is twelve times a 40 KB frame and twice a
            // large IDR.
            building.removeValue(forKey: frameId)
            finished.insert(frameId)
            damaged &+= 1
            onDamaged?(frameId)
            return
        }
        b.withUnsafeBufferPointer { source in
            assembly.bytes.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: fragOff)
                    .update(from: source.baseAddress!.advanced(by: 16), count: payloadCount)
            }
        }
        assembly.have += payloadCount
        assembly.lastSeen = stamp
        if flags & SMT.flagIdr != 0 { assembly.isIdr = true }
        if flags & SMT.flagFrameStart != 0 { assembly.captureUs = captureUs }
        if flags & SMT.flagFrameEnd != 0 { assembly.total = end }

        if assembly.total >= 0 && assembly.have >= assembly.total {
            let picture = Picture(
                frameId: frameId,
                bytes: Data(assembly.bytes[0..<assembly.total]),
                isIdr: assembly.isIdr,
                captureUs: assembly.captureUs == 0 ? captureUs : assembly.captureUs,
                spreadMs: Double(stamp - assembly.firstSeen) / 1e6)
            building.removeValue(forKey: frameId)
            finished.insert(frameId)
            complete &+= 1
            if frameId > lastCompleteFrame { lastCompleteFrame = frameId }
            onPicture?(picture)
        } else {
            building[frameId] = assembly
        }
        pruneFinished()
    }

    /// Retire assemblies that have gone quiet. Called from the receive loop's
    /// idle path, so it costs nothing while packets are arriving.
    public func tick() {
        guard !building.isEmpty else { return }
        let stamp = Self.now()
        for (frameId, assembly) in building {
            let idleMs = Double(stamp - assembly.lastSeen) / 1e6
            if idleMs > idleTimeoutMs {
                building.removeValue(forKey: frameId)
                finished.insert(frameId)
                damaged &+= 1
                onDamaged?(frameId)
            }
        }
        pruneFinished()
    }

    private func pruneFinished() {
        guard finished.count > 512 else { return }
        let floor = highestSeen > 256 ? highestSeen - 256 : 0
        finished = finished.filter { $0 >= floor }
    }

    public func reset() {
        building.removeAll()
        finished.removeAll()
    }
}
