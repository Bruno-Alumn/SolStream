// audio_downmix.h — how the PC's speaker channels become the Mac's two.
//
// Kept apart from audio.cpp so the weights can be checked without a sound
// device: see TestDownmix in updater_tests.cpp.

#pragma once

#include <cmath>
#include <cstdint>
#include <vector>

namespace solstream::media {

/// How much of each source channel goes to the left and to the right.
struct StereoWeights {
    std::vector<float> left;
    std::vector<float> right;
};

/// The weights for `channels` channels laid out by `mask` (a
/// WAVEFORMATEXTENSIBLE dwChannelMask; 0 when the format has none).
///
/// Taking only the first two channels -- front left and right -- dropped the
/// centre, which carries a film's or a game's dialogue, and every surround,
/// whenever the PC played 5.1 or 7.1 to a multichannel output. The usual
/// mixdown instead: each side its own front, plus the centre and its own
/// surrounds at -3 dB; a back centre to both at -6 dB. The low-frequency
/// channel is left out, as a stereo mixdown usually leaves it -- the mains
/// already carry its content -- and nothing is scaled: plain stereo played on
/// a 5.1 output keeps its level, and the rare peak of every channel at once is
/// clipped like any other.
inline StereoWeights DownmixWeights(int channels, uint32_t mask) {
    StereoWeights weights;
    if (channels <= 0) {
        return weights;
    }
    weights.left.assign((size_t) channels, 0.0f);
    weights.right.assign((size_t) channels, 0.0f);
    if (channels == 1) {
        weights.left[0] = weights.right[0] = 1.0f;
        return weights;
    }
    constexpr float kMinus3dB = 0.7071f;
    constexpr float kMinus6dB = 0.5f;
    // Speaker positions in the order WAVEFORMATEXTENSIBLE lays them out.
    enum : uint32_t {
        kFrontLeft = 0x1, kFrontRight = 0x2, kFrontCenter = 0x4, kLowFrequency = 0x8,
        kBackLeft = 0x10, kBackRight = 0x20, kFrontLeftOfCenter = 0x40,
        kFrontRightOfCenter = 0x80, kBackCenter = 0x100, kSideLeft = 0x200,
        kSideRight = 0x400,
    };
    if (mask == 0) {
        // No layout given: the first two are left and right, and the rest is
        // not guessed at.
        weights.left[0] = 1.0f;
        weights.right[1] = 1.0f;
        return weights;
    }
    int index = 0;
    for (uint32_t bit = 1; bit != 0 && index < channels; bit <<= 1) {
        if ((mask & bit) == 0) {
            continue;
        }
        float& left = weights.left[(size_t) index];
        float& right = weights.right[(size_t) index];
        switch (bit) {
            case kFrontLeft: left = 1.0f; break;
            case kFrontRight: right = 1.0f; break;
            case kFrontCenter: left = right = kMinus3dB; break;
            case kLowFrequency: break;
            case kBackLeft: case kSideLeft: case kFrontLeftOfCenter: left = kMinus3dB; break;
            case kBackRight: case kSideRight: case kFrontRightOfCenter: right = kMinus3dB; break;
            case kBackCenter: left = right = kMinus6dB; break;
            default: break;
        }
        ++index;
    }
    // A mask that named no speaker this knows -- only SPEAKER_ALL, or
    // reserved bits, as some drivers report -- left every weight at zero and
    // the stream silent. The first two channels instead, as with no mask.
    bool any = false;
    for (int c = 0; c < channels; ++c) {
        any = any || weights.left[(size_t) c] != 0.0f || weights.right[(size_t) c] != 0.0f;
    }
    if (!any) {
        weights.left[0] = 1.0f;
        weights.right[1] = 1.0f;
    }
    return weights;
}

/// A sample brought within full scale, gently: unchanged up to 0.75, then
/// bent toward 1.0 and never past it. For a surround mix summed to two
/// channels only, which can reach three times full scale on a loud 7.1 scene,
/// and a hard clip is not kind to listen to; plain stereo is never put
/// through it, so a loud master keeps its peaks.
inline float SoftLimit(float sample) {
    constexpr float kKnee = 0.75f;
    constexpr float kRoom = 1.0f - kKnee;
    const float size = std::fabs(sample);
    if (size <= kKnee) {
        return sample;
    }
    const float bent = kKnee + kRoom * std::tanh((size - kKnee) / kRoom);
    return sample < 0.0f ? -bent : bent;
}

}  // namespace solstream::media
