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
        let ring = AudioRingBuffer(prefillMilliseconds: 0)
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
                                   ceilingMilliseconds: 15, prefillMilliseconds: 0)
        for round in 0..<50 {
            let input = stereo(frames: 96, startingAt: round * 96)
            write(input, to: ring)
            XCTAssertEqual(read(input.count, from: ring), input,
                           "round \(round) came back different")
        }
    }

    func testUnderrunPadsWithSilence() {
        let ring = AudioRingBuffer(prefillMilliseconds: 0)
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
                                   ceilingMilliseconds: 8, prefillMilliseconds: 0)
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
                                   ceilingMilliseconds: 200, prefillMilliseconds: 0)
        let capacitySamples = (48000 * 10 / 1000) * 2
        let input = stereo(frames: 2000)   // 4000 samples, well over capacity
        write(input, to: ring)

        XCTAssertEqual(ring.available, capacitySamples)
        XCTAssertEqual(read(capacitySamples, from: ring), Array(input.suffix(capacitySamples)))
    }

    /// Playback waits for a cushion before it starts, and again after it runs
    /// dry, so a sound does not begin from an empty buffer that the next late
    /// packet turns into a click.
    func testPlaybackWaitsForTheCushionAndReprimesAfterAnUnderrun() {
        let ring = AudioRingBuffer(prefillMilliseconds: 25)
        let fiveMs = 48000 * 5 / 1000
        write(stereo(frames: fiveMs), to: ring)
        XCTAssertEqual(read(fiveMs * 2, from: ring), [Int16](repeating: 0, count: fiveMs * 2),
                       "played before the cushion was there")
        XCTAssertEqual(ring.available, fiveMs * 2, "the held audio was consumed")

        write(stereo(frames: fiveMs * 5, startingAt: fiveMs), to: ring)   // now 30 ms
        let out = read(fiveMs * 2, from: ring)
        XCTAssertEqual(out, stereo(frames: fiveMs), "the cushion did not start playing in order")

        // Drain it, run dry, and the next packet has to wait for a cushion again.
        _ = read(ring.available + 2, from: ring)
        write(stereo(frames: fiveMs), to: ring)
        XCTAssertEqual(read(2, from: ring), [0, 0], "did not re-prime after the underrun")
    }

    /// Ordinary drift comes down a little per packet, not as one jump.
    func testDriftIsTrimmedGently() {
        let ring = AudioRingBuffer(capacityMilliseconds: 500, targetMilliseconds: 50,
                                   ceilingMilliseconds: 120, prefillMilliseconds: 0)
        write(stereo(frames: 48000 * 118 / 1000), to: ring)   // just under the ceiling
        write(stereo(frames: 48000 * 5 / 1000), to: ring)     // crosses it
        let afterMs = Double(ring.available / 2) / 48.0
        XCTAssertGreaterThan(afterMs, 115, "drift was corrected as one jump")
        XCTAssertLessThan(afterMs, 123)
    }

    func testEmptyWriteIsIgnored() {
        let ring = AudioRingBuffer()
        write([], to: ring)
        XCTAssertEqual(ring.available, 0)
    }

    // MARK: - Buffering

    private func samples(ms: Int) -> Int { 48000 * ms / 1000 * 2 }

    func testBufferingChoicesMapToTheirLevels() {
        XCTAssertEqual(AudioRenderer.Buffering.lowLatency.latency,
                       .init(prefillMilliseconds: 25, targetMilliseconds: 50, ceilingMilliseconds: 120))
        XCTAssertEqual(AudioRenderer.Buffering.steady.latency,
                       .init(prefillMilliseconds: 60, targetMilliseconds: 100, ceilingMilliseconds: 220))
    }

    func testSwitchingBufferingSwapsAllThreeLevels() {
        let ring = AudioRingBuffer(latency: AudioRenderer.Buffering.lowLatency.latency)
        XCTAssertTrue(ring.levels == (samples(ms: 25), samples(ms: 50), samples(ms: 120)))
        ring.setLatency(AudioRenderer.Buffering.steady.latency)
        XCTAssertTrue(ring.levels == (samples(ms: 60), samples(ms: 100), samples(ms: 220)))
        ring.setLatency(AudioRenderer.Buffering.lowLatency.latency)
        XCTAssertTrue(ring.levels == (samples(ms: 25), samples(ms: 50), samples(ms: 120)))
    }

    /// Steady lets a clump of packets stand as cushion that low latency trims.
    func testSteadyKeepsABacklogLowLatencyWouldTrim() {
        let low = AudioRingBuffer(latency: AudioRenderer.Buffering.lowLatency.latency)
        write(stereo(frames: 48 * 200), to: low)
        XCTAssertLessThan(low.available, samples(ms: 200))

        let steady = AudioRingBuffer(latency: AudioRenderer.Buffering.lowLatency.latency)
        steady.setLatency(AudioRenderer.Buffering.steady.latency)
        write(stereo(frames: 48 * 200), to: steady)
        XCTAssertEqual(steady.available, samples(ms: 200))

        // And a burst past twice the new ceiling goes to the new target.
        write(stereo(frames: 48 * 250), to: steady)
        XCTAssertEqual(steady.available, samples(ms: 100))
    }

    /// Back to low latency on a live stream: the backlog comes down a couple of
    /// milliseconds per packet, not as one audible jump.
    func testSwitchingToLowLatencyTrimsGently() {
        let ring = AudioRingBuffer(latency: AudioRenderer.Buffering.steady.latency)
        write(stereo(frames: 48 * 200), to: ring)
        ring.setLatency(AudioRenderer.Buffering.lowLatency.latency)
        write(stereo(frames: 48 * 5), to: ring)
        XCTAssertEqual(ring.available, samples(ms: 203))
    }

    /// Steady's larger cushion is what playback waits for after it primes.
    func testSteadyWaitsForItsLargerCushion() {
        let ring = AudioRingBuffer(latency: AudioRenderer.Buffering.lowLatency.latency)
        ring.setLatency(AudioRenderer.Buffering.steady.latency)
        write(stereo(frames: 48 * 30), to: ring)
        XCTAssertEqual(read(4, from: ring), [0, 0, 0, 0], "played before the steady cushion was there")
        write(stereo(frames: 48 * 35, startingAt: 48 * 30), to: ring)
        XCTAssertEqual(read(4, from: ring), Array(stereo(frames: 2)))
    }
}
