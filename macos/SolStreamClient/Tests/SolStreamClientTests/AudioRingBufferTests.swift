import XCTest
@testable import AudioRenderer

/// Checks the audio ring buffer's two invariants: latency stays bounded, and the
/// stereo interleave never shifts.
///
/// Both failures are the kind a user reports as something else entirely — "the
/// sound lags further behind the further into a session I get", or "the audio is
/// coming out of the wrong speaker" — with nothing in a log to connect them back
/// to a buffer.
final class AudioRingBufferTests: XCTestCase {

    /// Left channel positive, right channel negative, so a swapped interleave is
    /// visible in the sign of every sample.
    private func stereo(frames: Int, startingAt first: Int = 0) -> [Int16] {
        var samples: [Int16] = []
        for frame in 0..<frames {
            let value = Int16((first + frame) % 1000 + 1)
            samples.append(value)    // left
            samples.append(-value)   // right
        }
        return samples
    }

    private func write(_ samples: [Int16], to ring: AudioRingBuffer) {
        samples.withUnsafeBufferPointer { ring.write($0) }
    }

    private func read(_ count: Int, from ring: AudioRingBuffer) -> [Int16] {
        var out = [Int16](repeating: 0, count: count)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return out
    }

    func testRoundTripsExactly() {
        let ring = AudioRingBuffer()
        let input = stereo(frames: 240)
        write(input, to: ring)
        XCTAssertEqual(ring.available, input.count)
        XCTAssertEqual(read(input.count, from: ring), input)
        XCTAssertEqual(ring.available, 0)
    }

    /// Repeated writes and reads have to keep working once the indices wrap past
    /// the end of the storage.
    func testSurvivesWraparound() {
        let ring = AudioRingBuffer(capacityMilliseconds: 20, targetMilliseconds: 5,
                                   ceilingMilliseconds: 15)
        for round in 0..<50 {
            let input = stereo(frames: 96, startingAt: round * 96)
            write(input, to: ring)
            XCTAssertEqual(read(input.count, from: ring), input,
                           "round \(round) came back different")
        }
    }

    func testUnderrunPadsWithSilence() {
        let ring = AudioRingBuffer()
        write(stereo(frames: 2), to: ring)
        let out = read(10, from: ring)
        XCTAssertEqual(Array(out.prefix(4)), stereo(frames: 2))
        XCTAssertEqual(Array(out.dropFirst(4)), [Int16](repeating: 0, count: 6))
    }

    /// The ratchet this replaced: on overrun the old buffer refused the incoming
    /// sample, so the newest audio was thrown away and the backlog stayed at its
    /// maximum forever. Overflow must cost the *oldest* audio.
    func testOverrunDropsOldestNotNewest() {
        let ring = AudioRingBuffer(capacityMilliseconds: 10, targetMilliseconds: 2,
                                   ceilingMilliseconds: 8)
        // 10 ms of capacity is 480 frames at 48 kHz.
        write(stereo(frames: 400, startingAt: 0), to: ring)
        let newest = stereo(frames: 400, startingAt: 400)
        write(newest, to: ring)

        let out = read(ring.available, from: ring)
        XCTAssertGreaterThan(ring.framesDropped, 0)
        // Whatever survived must be a suffix of what went in, i.e. the newest.
        XCTAssertEqual(out, Array(newest.suffix(out.count)))
    }

    /// Latency must be bounded rather than only capped: crossing the ceiling
    /// trims back to the target instead of sitting at capacity forever.
    func testBacklogIsTrimmedTowardsTheTarget() {
        let ring = AudioRingBuffer(capacityMilliseconds: 500, targetMilliseconds: 50,
                                   ceilingMilliseconds: 120)
        // 300 ms of audio in one burst, well past the 120 ms ceiling.
        write(stereo(frames: 48000 * 300 / 1000), to: ring)

        let targetSamples = (48000 * 50 / 1000) * 2
        XCTAssertEqual(ring.available, targetSamples,
                       "backlog should be trimmed to the target, not left at the ceiling")
    }

    /// The channel swap. Every trim must move whole frames, or the L,R parity
    /// shifts for everything afterwards and the speakers stay swapped for the
    /// rest of the session.
    func testInterleaveParitySurvivesTrimming() {
        let ring = AudioRingBuffer(capacityMilliseconds: 10, targetMilliseconds: 2,
                                   ceilingMilliseconds: 8)
        // Odd frame counts, so a trim that rounded carelessly would land between
        // a left and a right sample.
        for round in 0..<40 {
            write(stereo(frames: 77, startingAt: round * 77), to: ring)
            XCTAssertEqual(ring.available % 2, 0, "backlog split a stereo frame")

            let out = read(ring.available, from: ring)
            for index in stride(from: 0, to: out.count, by: 2) {
                XCTAssertGreaterThan(out[index], 0, "left sample at \(index) is not a left sample")
                XCTAssertLessThan(out[index + 1], 0, "right sample at \(index + 1) is not a right sample")
            }
        }
    }

    /// A packet larger than the whole ring keeps its newest end rather than
    /// being refused outright.
    func testPacketLargerThanCapacityKeepsItsNewestEnd() {
        let ring = AudioRingBuffer(capacityMilliseconds: 10, targetMilliseconds: 2,
                                   ceilingMilliseconds: 200)
        let capacitySamples = (48000 * 10 / 1000) * 2
        let input = stereo(frames: 2000)   // 4000 samples, well over capacity
        write(input, to: ring)

        XCTAssertEqual(ring.available, capacitySamples)
        XCTAssertEqual(read(capacitySamples, from: ring), Array(input.suffix(capacitySamples)))
    }

    func testEmptyWriteIsIgnored() {
        let ring = AudioRingBuffer()
        write([], to: ring)
        XCTAssertEqual(ring.available, 0)
    }
}
