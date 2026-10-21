import XCTest
@testable import AudioRenderer

/// Volume and mute as the render callback applies them.
///
/// What matters is what the person hears: the level is the level they chose,
/// mute is silence, and getting from one to the other never clicks -- a click
/// being a jump in the waveform between one sample and the next.
final class AudioGainTests: XCTestCase {

    /// One render buffer's worth at a typical HAL size.
    private let frames = 512

    /// Constant stereo, left positive and right negative, so a ramp shows up as
    /// a slope and a channel mix-up as a sign.
    private func steady(_ value: Int16, frames: Int) -> [Int16] {
        var samples: [Int16] = []
        for _ in 0..<frames {
            samples.append(value)
            samples.append(-value)
        }
        return samples
    }

    private func render(_ input: [Int16], through gain: AudioGain) -> [Int16] {
        var out = input
        out.withUnsafeMutableBufferPointer {
            gain.apply(to: $0.baseAddress!, count: $0.count, channels: 2)
        }
        return out
    }

    func testFullVolumeLeavesSamplesBitExact() {
        let gain = AudioGain()
        let input: [Int16] = [32767, -32768, 1, -1, 12345, -12345]
        XCTAssertEqual(render(input, through: gain), input)
    }

    func testHalfVolumeHalvesSamples() {
        let gain = AudioGain()
        gain.volume = 0.5
        let input = steady(10_000, frames: frames)
        _ = render(input, through: gain)   // the ramp down
        XCTAssertEqual(render(input, through: gain), steady(5_000, frames: frames))
    }

    func testMuteIsSilenceAfterTheRampAndUnmuteRestoresTheVolume() {
        let gain = AudioGain()
        gain.volume = 0.5
        let input = steady(10_000, frames: frames)
        _ = render(input, through: gain)

        gain.isMuted = true
        let ramp = render(input, through: gain)
        XCTAssertLessThanOrEqual(abs(Int(ramp[ramp.count - 2])), 10,
                                 "the ramp did not reach silence by the end of the buffer")
        XCTAssertEqual(render(input, through: gain), [Int16](repeating: 0, count: input.count))
        XCTAssertEqual(gain.volume, 0.5, "muting forgot the volume")

        gain.isMuted = false
        _ = render(input, through: gain)
        XCTAssertEqual(render(input, through: gain), steady(5_000, frames: frames))
    }

    /// Mute is the worst case: a step from full scale to zero. Across the ramp
    /// no two neighbouring frames, and no two buffers, may differ by more than
    /// one ramp step, and left and right must move together.
    func testRampNeverJumps() {
        let gain = AudioGain()
        let value: Int16 = 30_000
        let input = steady(value, frames: frames)
        let before = render(input, through: gain)
        gain.isMuted = true
        let ramp = render(input, through: gain)
        let after = render(input, through: gain)

        let lefts = (before + ramp + after).enumerated()
            .filter { $0.offset % 2 == 0 }.map { Int($0.element) }
        let maxStep = Int(value) / AudioGain.rampFrames + 2
        for index in 1..<lefts.count {
            XCTAssertLessThanOrEqual(abs(lefts[index] - lefts[index - 1]), maxStep,
                                     "jump of \(lefts[index] - lefts[index - 1]) at frame \(index)")
        }
        for frame in 0..<frames {
            XCTAssertEqual(ramp[frame * 2], -ramp[frame * 2 + 1],
                           "left and right got different gains at frame \(frame)")
        }
    }

    /// A slider drag lands a new level on every buffer; each one must carry on
    /// from where the last ended.
    func testSliderDragIsContinuousAcrossBuffers() {
        let gain = AudioGain()
        let input = steady(20_000, frames: frames)
        var previousLast: Int?
        for level: Float in [0.9, 0.3, 0.7, 0.1, 1.0] {
            gain.volume = level
            let out = render(input, through: gain)
            if let previousLast {
                XCTAssertLessThanOrEqual(abs(Int(out[0]) - previousLast),
                                         20_000 / AudioGain.rampFrames + 2,
                                         "the buffer at \(level) did not start where the last ended")
            }
            XCTAssertEqual(Float(out[out.count - 2]), 20_000 * level, accuracy: 2)
            previousLast = Int(out[out.count - 2])
        }
    }

    /// With another app holding the device at 64-frame buffers, a one-buffer
    /// ramp would be 1.3 ms. The ramp has to carry on across buffers and still
    /// take its full 10 ms, and a change of mind mid-ramp must not jump.
    func testRampSpansSmallBuffers() {
        let gain = AudioGain()
        let small = 64
        let value: Int16 = 30_000
        let input = steady(value, frames: small)
        var lefts: [Int] = []
        func play(_ buffers: Int) {
            for _ in 0..<buffers {
                lefts += render(input, through: gain).enumerated()
                    .filter { $0.offset % 2 == 0 }.map { Int($0.element) }
            }
        }

        play(1)
        gain.isMuted = true
        let rampStart = lefts.count
        play(1)
        XCTAssertGreaterThan(lefts[lefts.count - 1], Int(value) / 2,
                             "the whole ramp happened inside one 64-frame buffer")
        play(8)
        XCTAssertGreaterThan(lefts[rampStart + AudioGain.rampFrames - 2], 0,
                             "the ramp finished early")
        XCTAssertEqual(lefts[rampStart + AudioGain.rampFrames - 1], 0,
                       "the ramp did not reach silence in \(AudioGain.rampFrames) frames")
        XCTAssertTrue(lefts[(rampStart + AudioGain.rampFrames)...].allSatisfy { $0 == 0 })

        // Halfway back up, change the level again.
        gain.isMuted = false
        play(4)
        gain.volume = 0.2
        play(10)
        XCTAssertEqual(Float(lefts[lefts.count - 1]), Float(value) * 0.2, accuracy: 2)

        let maxStep = Int(value) / AudioGain.rampFrames + 2
        for index in 1..<lefts.count {
            XCTAssertLessThanOrEqual(abs(lefts[index] - lefts[index - 1]), maxStep,
                                     "jump of \(lefts[index] - lefts[index - 1]) at frame \(index)")
        }
    }

    /// A NaN would trap converting back to Int16 on the render thread.
    func testVolumeIsClampedAndNaNIsRefused() {
        let gain = AudioGain()
        gain.volume = 2
        XCTAssertEqual(gain.volume, 1)
        gain.volume = -1
        XCTAssertEqual(gain.volume, 0)
        gain.volume = .nan
        XCTAssertEqual(gain.volume, 1)
        let input: [Int16] = [32767, -32768]
        XCTAssertEqual(render(input, through: gain), input)
    }
}

/// The slider's position as a gain: the bar should feel even along its length,
/// which a straight line to amplitude does not.
final class VolumeTaperTests: XCTestCase {

    func testEndsAreSilenceAndFull() {
        XCTAssertEqual(AudioRenderer.amplitude(forPosition: 0), 0)
        XCTAssertEqual(AudioRenderer.amplitude(forPosition: 1), 1)
    }

    func testRisesAllTheWayAlong() {
        var previous = AudioRenderer.amplitude(forPosition: 0)
        for step in 1...100 {
            let next = AudioRenderer.amplitude(forPosition: Float(step) / 100)
            XCTAssertGreaterThan(next, previous, "flat or falling at \(step)%")
            previous = next
        }
    }

    /// Halfway along should sound about half as loud, which is near -12 dB --
    /// not the -6 dB a linear slider gives, which still sounds mostly full.
    func testMiddleIsWellBelowHalfAmplitude() {
        let decibels = 20 * log10(AudioRenderer.amplitude(forPosition: 0.5))
        XCTAssertLessThan(decibels, -10)
        XCTAssertGreaterThan(decibels, -20)
    }

    func testOutOfRangeIsClampedAndNaNIsFull() {
        XCTAssertEqual(AudioRenderer.amplitude(forPosition: -1), 0)
        XCTAssertEqual(AudioRenderer.amplitude(forPosition: 2), 1)
        XCTAssertEqual(AudioRenderer.amplitude(forPosition: .nan), 1)
    }
}
