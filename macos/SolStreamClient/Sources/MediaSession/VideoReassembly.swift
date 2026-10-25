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
    }

    public var onPicture: ((Picture) -> Void)?
    /// A picture that will never be complete. The caller decides whether that is
    /// worth a keyframe request.
    public var onDamaged: ((UInt32) -> Void)?
    /// A fragment of an IDR has arrived, for a picture not yet finished: the
    /// keyframe the caller may be waiting for is on its way.
    public var onIdrFragment: ((UInt32) -> Void)?

    public private(set) var complete: UInt64 = 0
    public private(set) var damaged: UInt64 = 0

    /// Close a picture this long after its LAST fragment, not its first.
    ///
    /// Timing from the first fragment is defect #5 of the six in
    /// docs/transport-smt1.md: an IDR on a 20 Mbit/s path takes 80-160 ms to
    /// arrive, so a 25 ms timer started at its first fragment declares it
    /// damaged before it has landed and asks for another one -- which is bigger.
    /// An idle timeout is the standard reassembly rule and does not have that
    /// failure.
    private let idleTimeoutMs: Double = 25

    /// The largest picture this will assemble. Above it a picture is refused
    /// and reported damaged, rather than assembled from whatever fitted.
    ///
    /// The buffer used to be a fixed 512 KB and any picture past it was thrown
    /// away for good, which was reachable rather than theoretical: `--bitrate`
    /// on this side has no upper bound and the host enforces only a lower one,
    /// so a large enough setting turns every IDR into a picture this side
    /// refuses -- and the stream never recovers, because the keyframe it then
    /// asks for is bigger still. The buffer now grows to whatever a picture
    /// actually claims.
    ///
    /// 16 MiB is not a taste judgement. `fragOff` is 24 bits wide, so it can
    /// only address the first 16 MiB of a picture; the host writes that offset
    /// with a three-byte `PutBE`, so a picture past this has already had its
    /// later offsets wrapped round to the front and could not be reassembled by
    /// anybody. Refusing it is the honest answer, and it is reported damaged so
    /// the caller asks for a keyframe rather than waiting on a picture that
    /// will never arrive.
    private static let maxPictureBytes = 1 << 24

    private struct Assembly {
        var bytes: [UInt8]
        /// The byte ranges actually written, merged and in ascending order.
        ///
        /// This used to be a running total of received payload lengths, which
        /// made completion mean "as many bytes have arrived as the picture is
        /// long" instead of "every byte of the picture is here". The two are
        /// not the same as soon as a fragment arrives twice or two fragments
        /// overlap: the count reaches the picture's length while a hole is
        /// still open, and the picture goes to the decoder with a run of zeroes
        /// in the middle of it. That is worse than a picture reported damaged,
        /// because nothing reports it -- the decoder is handed a broken slice
        /// and the image tears or stalls with no keyframe request behind it.
        var covered: [(start: Int, end: Int)] = []
        var total = -1
        var isIdr = false
        var lastSeen: UInt64

        /// Record `[start, end)` as present, absorbing any range it touches or
        /// overlaps so that `covered` stays merged and ordered.
        mutating func cover(_ start: Int, _ end: Int) {
            var low = start
            var high = end
            var merged: [(start: Int, end: Int)] = []
            merged.reserveCapacity(covered.count + 1)
            var placed = false
            for range in covered {
                if range.end < low {
                    merged.append(range)
                } else if range.start > high {
                    if !placed {
                        merged.append((start: low, end: high))
                        placed = true
                    }
                    merged.append(range)
                } else {
                    low = min(low, range.start)
                    high = max(high, range.end)
                }
            }
            if !placed { merged.append((start: low, end: high)) }
            covered = merged
        }

        /// Every byte from zero to `total` present, rather than merely that
        /// many bytes having been received.
        var isComplete: Bool {
            guard total >= 0, covered.count == 1, let only = covered.first else {
                return false
            }
            return only.start == 0 && only.end >= total
        }
    }

    private var building: [UInt32: Assembly] = [:]
    /// Pictures already emitted or given up on, so a straggler fragment does not
    /// start a fresh assembly that then times out and asks for a keyframe.
    private var finished: Set<UInt32> = []
    private var highestSeen: UInt32 = 0
    /// The buffer of the last picture that completed or was retired, kept so
    /// the next picture does not allocate half a megabyte. It is not cleared:
    /// a picture is emitted only once `covered` spans all of [0, total), and
    /// `covered` records only what this picture's own fragments wrote.
    private var spare: [UInt8]?

    public init() {}

    private func takeBuffer() -> [UInt8] {
        if let buffer = spare {
            spare = nil
            return buffer
        }
        return [UInt8](repeating: 0, count: 512 * 1024)
    }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public func ingest(_ plaintext: Data) {
        guard plaintext.count > 16 else { return }
        plaintext.withUnsafeBytes { ingest($0) }
    }

    private func ingest(_ b: UnsafeRawBufferPointer) {
        guard b[0] == SMT.typeVideo else { return }

        let flags = b[1]
        let frameId = (UInt32(b[4]) << 24) | (UInt32(b[5]) << 16)
                    | (UInt32(b[6]) << 8) | UInt32(b[7])
        let fragOff = (Int(b[8]) << 16) | (Int(b[9]) << 8) | Int(b[10])
        let payloadCount = b.count - 16
        guard payloadCount > 0, finished.contains(frameId) == false else { return }

        // A gap in the frame ids is a picture lost WHOLE. An assembly only
        // exists once a fragment of it arrives, so a one- or two-datagram
        // P-frame -- typing, a cursor blink -- that lost every datagram was
        // never retired, never reported, and the pictures after it were decoded
        // against a reference that was not there. Ids are consecutive per
        // encoder pass, and a single paced path barely reorders, so a jump is
        // damage. Not when the jump lands on an IDR: that is the host starting
        // over after dropping pictures itself, and the IDR is the repair. They
        // are also monotonic within a session, so a lower id is a wrap or a
        // restart and must not be reported as a gap.
        if highestSeen > 0, frameId > highestSeen,
           frameId &- highestSeen > 1, flags & SMT.flagIdr == 0 {
            let missing = min(frameId &- highestSeen &- 1, 64)
            for gap in 1...missing {
                let lost = highestSeen &+ gap
                if building[lost] == nil, finished.insert(lost).inserted {
                    damaged &+= 1
                    onDamaged?(lost)
                }
            }
        }
        if frameId > highestSeen { highestSeen = frameId }
        if flags & SMT.flagIdr != 0 { onIdrFragment?(frameId) }

        let stamp = Self.now()
        // Taken OUT of the dictionary, not read from it. A read leaves the
        // dictionary sharing the buffer, so the write below copies all of it —
        // half a megabyte per fragment, about a gigabyte a second at 20 Mbit/s,
        // on the receive thread. Every path below puts it back or retires it.
        var assembly = building.removeValue(forKey: frameId)
            ?? Assembly(bytes: takeBuffer(), lastSeen: stamp)
        let end = fragOff + payloadCount
        if end > Self.maxPictureBytes {
            // Past what the wire format can address, so refuse the whole
            // picture and say so. Assembling the part that fits would hand the
            // decoder a picture with a hole where the rest belongs.
            spare = assembly.bytes
            finished.insert(frameId)
            damaged &+= 1
            onDamaged?(frameId)
            return
        }
        if end > assembly.bytes.count {
            // Grow rather than give up. The starting 512 KB is twelve times a
            // 40 KB frame and twice a large IDR, so this reallocation is off
            // the ordinary path; doubling keeps it off it for a stream whose
            // pictures are consistently larger, rather than reallocating once
            // per fragment as the offsets climb.
            let grown = min(Self.maxPictureBytes, max(end, assembly.bytes.count * 2))
            assembly.bytes.append(contentsOf:
                repeatElement(UInt8(0), count: grown - assembly.bytes.count))
        }
        assembly.bytes.withUnsafeMutableBytes { destination in
            destination.baseAddress!.advanced(by: fragOff)
                .copyMemory(from: b.baseAddress!.advanced(by: 16), byteCount: payloadCount)
        }
        assembly.cover(fragOff, end)
        assembly.lastSeen = stamp
        if flags & SMT.flagIdr != 0 { assembly.isIdr = true }
        if flags & SMT.flagFrameEnd != 0 { assembly.total = end }

        if assembly.isComplete {
            // Every older picture still being built is given up on FIRST, and
            // reported before this one is handed on. The host sends pictures one
            // after another, so an older one that is still open when a newer one
            // has finished has lost a fragment that is not coming. Leaving it to
            // the idle timer was the most common loss of all -- one datagram of
            // a moving picture -- decoded wrongly: the timer cannot fire until
            // 25 ms after that picture's last fragment, the next picture has
            // finished well before then, and it went to the decoder against a
            // reference that never arrived. VideoToolbox does not call that an
            // error; it shows a smeared picture, and the hold that the late
            // report then set kept exactly that picture on screen until the
            // keyframe came. Reported first, the hold is already on when this
            // picture arrives at it.
            //
            // Silently when this picture is an IDR: nothing after an IDR refers
            // to anything before it, so there is nothing to repair and a report
            // would only ask for another keyframe and hold the one that just
            // arrived.
            retire(olderThan: frameId, reporting: !assembly.isIdr)
            let picture = Picture(
                frameId: frameId,
                bytes: Data(assembly.bytes[0..<assembly.total]),
                isIdr: assembly.isIdr)
            spare = assembly.bytes
            finished.insert(frameId)
            complete &+= 1
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
        let timedOut = building.compactMap { (frameId, assembly) -> UInt32? in
            let idleMs = Double(stamp - assembly.lastSeen) / 1e6
            return idleMs > idleTimeoutMs ? frameId : nil
        }
        for frameId in timedOut {
            guard let assembly = building.removeValue(forKey: frameId) else { continue }
            spare = assembly.bytes
            finished.insert(frameId)
            damaged &+= 1
            onDamaged?(frameId)
        }
        pruneFinished()
    }

    /// Give up on every picture older than `frameId` that is still being built.
    /// Each one counts as damaged; `reporting` says whether it is also passed to
    /// `onDamaged`, oldest first.
    private func retire(olderThan frameId: UInt32, reporting: Bool) {
        let older = building.keys.filter { $0 < frameId }.sorted()
        for lost in older {
            if let assembly = building.removeValue(forKey: lost) { spare = assembly.bytes }
            finished.insert(lost)
            damaged &+= 1
            if reporting { onDamaged?(lost) }
        }
    }

    private func pruneFinished() {
        guard finished.count > 512 else { return }
        let floor = highestSeen > 256 ? highestSeen - 256 : 0
        finished = finished.filter { $0 >= floor }
    }

}
