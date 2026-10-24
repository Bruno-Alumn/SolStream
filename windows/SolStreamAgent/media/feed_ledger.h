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
// The ids run on across encoders. A retarget ends one capture pass and opens a
// new encoder for the next, and the Mac -- which is not told about the retarget
// on the stream -- keeps the frame ids it has already finished. A second pass
// starting again at 1 had its pictures, its first keyframe among them, thrown
// away as stragglers for as long as the first pass had lasted, and once its ids
// climbed past the old ones a P-frame was decoded against the first pass's last
// picture. Each new encoder therefore starts where the last one stopped.
//
// Header-only, with no Windows in it, so the updater's test program can check
// it without a Media Foundation encoder.

#pragma once

#include <atomic>
#include <cstdint>

namespace solstream::media {

class FeedLedger {
public:
    /// Carry on from an earlier encoder of the same session: `next` is that
    /// encoder's `NextFrameId` once it has stopped taking frames. Before the
    /// first feed only.
    void StartAt(uint32_t next) { next_ = next; }

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
