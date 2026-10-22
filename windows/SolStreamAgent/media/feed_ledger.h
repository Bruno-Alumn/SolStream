// feed_ledger.h — the frame id and the keyframe request one encoder feed
// takes, and gives back when the encoder does not take the frame.
//
// The Mac reads frame ids as consecutive: a jump is a picture lost whole, which
// it answers by holding the last good picture and asking for a keyframe. So an
// id must be spent only on a picture that will exist. The feed used to take its
// id first, and then fail on any of half a dozen calls -- wrapping the texture,
// making the sample, or ProcessInput itself refusing, which a stale input
// credit makes an expected case -- and the Mac froze for a keyframe's round
// trip over a picture that was never sent. A keyframe request taken by such a
// feed was lost with it, and waited for the Mac's quarter-second repeat.
//
// Header-only, with no Windows in it, so the updater's test program can check
// it without a Media Foundation encoder.

#pragma once

#include <atomic>
#include <cstdint>

namespace solstream::media {

class FeedLedger {
public:
    /// The id the next picture fed will carry. The same until `Accepted`.
    uint32_t NextFrameId() const { return next_; }

    /// Whether this feed should be a keyframe: asked for by the caller, or
    /// requested since the last feed. Takes the request; a feed that then
    /// fails must hand it back with `Refused`.
    bool TakeIdr(bool forced) {
        const bool wanted = idrWanted_.exchange(false);
        return forced || wanted;
    }

    /// The encoder took the frame: its id is spent.
    void Accepted() { ++next_; }

    /// It did not. The id stays for the next picture, and a keyframe this feed
    /// was carrying is still owed.
    void Refused(bool carriedIdr) {
        if (carriedIdr) { idrWanted_.store(true); }
    }

    /// From any thread.
    void RequestIdr() { idrWanted_.store(true); }
    bool IdrPending() const { return idrWanted_.load(); }

private:
    uint32_t next_ = 1;
    std::atomic<bool> idrWanted_{false};
};

}  // namespace solstream::media
