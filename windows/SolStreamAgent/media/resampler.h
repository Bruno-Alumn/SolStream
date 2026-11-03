// resampler.h — the PC's sound brought to the stream's 48 kHz.
//
// A windowed-sinc resampler, kept apart from audio.cpp to be measured: see
// TestResampler in updater_tests.cpp, which checks what comes out of a tone.

#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

namespace solstream::media {

/// Interleaved stereo float at any rate in, at `1 / ratio` of it out, where
/// `ratio` is input rate over output rate.
///
/// It replaces area averaging -- a boxcar, which at 96 kHz is two taps and at
/// 44.1 kHz less than one: a held value with almost no filter, so a 10 kHz
/// tone came back with its image folded to 13.9 kHz only 10 dB down. This is
/// a low-pass at just under the lower Nyquist, 16 zero crossings either side,
/// Blackman-windowed, read from a table so the audio thread spends no time on
/// sines: images and anything above the output's Nyquist come out at -70 dB
/// or below. A ratio of exactly 1 -- a 48 kHz device, the usual one -- is
/// passed straight through untouched.
class SincResampler {
public:
    /// Ready for `ratio`, with nothing carried from before. A ratio that is
    /// not a positive number gives nothing out, rather than spinning.
    void Reset(double ratio) {
        ratio_ = ratio;
        history_.clear();
        table_.clear();
        if (!(ratio > 0.0) || ratio == 1.0) {
            return;
        }
        // The cutoff, in cycles per input sample at its Nyquist: the lower of
        // the two rates', a little inside it for the filter's transition.
        cutoff_ = (ratio > 1.0 ? 1.0 / ratio : 1.0) * 0.94;
        halfWidth_ = kZeroCrossings / cutoff_;
        const size_t entries = (size_t) std::ceil(halfWidth_ * kPhases) + 2;
        table_.resize(entries);
        for (size_t i = 0; i < entries; ++i) {
            const double d = (double) i / kPhases;
            table_[i] = (float) Kernel(d);
        }
        // Half a filter of silence first, so the first output has the whole
        // window to look back over.
        const size_t pad = (size_t) std::ceil(halfWidth_);
        history_.assign(pad * 2, 0.0f);
        position_ = (double) pad;
    }

    void Run(const std::vector<float>& in, std::vector<float>& out) {
        if (!(ratio_ > 0.0)) {
            return;
        }
        if (ratio_ == 1.0) {
            out.insert(out.end(), in.begin(), in.end());
            return;
        }
        history_.insert(history_.end(), in.begin(), in.end());
        const double frames = (double) (history_.size() / 2);
        while (position_ + halfWidth_ + 1.0 < frames) {
            const long first = (long) std::ceil(position_ - halfWidth_);
            const long last = (long) std::floor(position_ + halfWidth_);
            double left = 0.0, right = 0.0, weight = 0.0;
            for (long k = first < 0 ? 0 : first; k <= last; ++k) {
                const double w = Lookup(std::fabs(position_ - (double) k));
                left += history_[(size_t) k * 2] * w;
                right += history_[(size_t) k * 2 + 1] * w;
                weight += w;
            }
            // By the weights' own sum, so a constant comes out the constant
            // it went in as, wherever between samples the output falls.
            const double gain = weight != 0.0 ? 1.0 / weight : 0.0;
            out.push_back((float) (left * gain));
            out.push_back((float) (right * gain));
            position_ += ratio_;
        }
        // What no later output can reach goes.
        const long keepFrom = (long) std::floor(position_ - halfWidth_) - 1;
        if (keepFrom > 0) {
            history_.erase(history_.begin(), history_.begin() + keepFrom * 2);
            position_ -= (double) keepFrom;
        }
    }

private:
    static constexpr double kZeroCrossings = 16.0;
    static constexpr double kPhases = 512.0;

    /// The filter at `d` input samples from the centre.
    double Kernel(double d) const {
        constexpr double kPi = 3.14159265358979323846;
        if (d >= halfWidth_) {
            return 0.0;
        }
        const double x = cutoff_ * d;
        const double sinc = x == 0.0 ? 1.0 : std::sin(kPi * x) / (kPi * x);
        // Blackman, over the whole width.
        const double t = 0.5 + 0.5 * d / halfWidth_;
        const double window = 0.42 - 0.5 * std::cos(2.0 * kPi * t)
                              + 0.08 * std::cos(4.0 * kPi * t);
        return cutoff_ * sinc * window;
    }

    double Lookup(double d) const {
        const double at = d * kPhases;
        const size_t i = (size_t) at;
        if (i + 1 >= table_.size()) {
            return 0.0;
        }
        const double f = at - (double) i;
        return table_[i] * (1.0 - f) + table_[i + 1] * f;
    }

    double ratio_ = 1.0;
    double cutoff_ = 1.0;
    double halfWidth_ = 0.0;
    double position_ = 0.0;
    std::vector<float> table_;
    std::vector<float> history_;
};

}  // namespace solstream::media
