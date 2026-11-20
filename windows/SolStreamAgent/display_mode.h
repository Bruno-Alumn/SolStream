// display_mode.h — the virtual display's refresh rate, and which sizes setup
// leaves alone.
//
// Both used to ask for as much as they could get. The rate was the highest the
// display offered at a size, which on this driver can be 120 Hz or more:
// Windows then composes the virtual display that often, for a stream that the
// Mac asks for at 30 or 60 frames a second. And setup put the display back on a ladder size
// whenever it found it at any other, which undid a size the Mac's `canvas` had
// chosen, only for the next connection to choose it again: a display
// reconfiguration each way, and another at every restart of the host.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#include <vector>

namespace solstream {

/// The rate the virtual display is set to when nothing says otherwise. The Mac
/// asks for 30 or 60 frames a second, and its `canvas` request carries no rate
/// and comes before the stream is opened, so the display cannot be matched to
/// the stream it is about to carry. 60 covers both choices, and staying at one
/// rate means switching between them never reconfigures the display.
constexpr unsigned kDisplayRefreshTarget = 60;

/// The largest canvas on either axis: NVENC's H.264 limit. A larger one starts
/// a session that never delivers a frame.
constexpr unsigned kLargestCanvas = 4096;

/// Whether `candidate` is a better rate than `current` for a stream that wants
/// `target` frames a second: the closest at or above the target, since a
/// display slower than the stream holds every frame back to its own pace, and
/// failing any of those the fastest there is.
inline bool BetterRefresh(unsigned candidate, unsigned current, unsigned target) {
    const bool candidate_enough = candidate >= target;
    const bool current_enough = current >= target;
    if (candidate_enough != current_enough) {
        return candidate_enough;
    }
    return candidate_enough ? candidate < current : candidate > current;
}

/// The rate to use out of those a display offers at one size, by BetterRefresh;
/// 0 when it offers none. 0 and 1 are Windows' "the hardware's default" and
/// say nothing about the rate, so they are passed over.
inline unsigned ChooseRefresh(const std::vector<unsigned>& offered, unsigned target) {
    unsigned chosen = 0;
    for (unsigned rate : offered) {
        if (rate <= 1) {
            continue;
        }
        if (chosen == 0 || BetterRefresh(rate, chosen, target)) {
            chosen = rate;
        }
    }
    return chosen;
}

/// Whether setup can leave an attached display at this size. Any size the
/// encoder takes will do: the ladder is what setup attaches at, but the Mac's
/// `canvas` may have chosen another of the modes the driver offers, and
/// putting it back meant the two took turns reconfiguring the display.
inline bool KeepsAttachedSize(unsigned width, unsigned height) {
    return width > 0 && height > 0 && width <= kLargestCanvas && height <= kLargestCanvas;
}

}  // namespace solstream
