// overflow_gate.h — what the send queue does with each coded picture once the
// sender has fallen behind.
//
// The queue holds 24 pictures. When it is full the sender cannot keep up, and
// what is in it will be stale before it leaves, so it is thrown away and the
// encoder is asked for a keyframe: that recovers in one frame, and sending the
// backlog recovers in however long it takes. The P-frames the encoder makes
// before that keyframe are no use either -- each refers to a picture just
// thrown away -- and they used to be sent. The Mac read the jump in frame ids
// in front of the first of them as pictures lost, and asked for a keyframe of
// its own, which over a slow path reached the host after its 200 ms limit had
// run out and brought a second, into the sender that had just fallen behind.
// They are dropped now, until the keyframe comes out. A jump that lands on a
// keyframe is the host starting over after dropping pictures itself, and the
// Mac asks nothing about it.
//
// An encoder that ignores the request must not leave the stream with nothing
// but dropped pictures, so the wait is bounded: past it, pictures are sent
// again and the keyframe is asked for once more.
//
// Header-only, with no Windows in it, so the updater's test program can check
// it without a Media Foundation encoder. Not thread-safe: the session calls it
// under the queue lock.

#pragma once

namespace solstream::media {

class OverflowGate {
public:
    /// How long to drop pictures waiting for the keyframe before giving up on
    /// it. An encoder that honours the request makes one within a frame or two.
    static constexpr double kGiveUpMs = 500.0;

    struct Decision {
        /// Throw away the pictures already queued.
        bool clear = false;
        /// Queue this picture. False drops it.
        bool send = true;
        /// Ask the encoder for a keyframe.
        bool askIdr = false;
    };

    /// One picture out of the encoder. `queueFull` is whether the queue is
    /// already at its depth, and `nowMs` any clock in milliseconds that does
    /// not go backwards.
    Decision Picture(bool isIdr, bool queueFull, double nowMs) {
        Decision decision;
        if (isIdr) {
            // The keyframe waited for, or one that came anyway. Either way it
            // is the start of everything after it, so it goes, and the backlog
            // it overtakes does not. Nothing is asked for: this is the keyframe
            // an overflow would ask for, and asking again made a second one
            // straight after it.
            waiting_ = false;
            decision.clear = queueFull;
            return decision;
        }
        if (waiting_) {
            if (nowMs - since_ <= kGiveUpMs) {
                decision.send = false;
                return decision;
            }
            waiting_ = false;
            decision.askIdr = true;
        }
        if (queueFull) {
            waiting_ = true;
            since_ = nowMs;
            decision.clear = true;
            decision.send = false;
            decision.askIdr = true;
        }
        return decision;
    }

    /// Pictures are being dropped until a keyframe comes out.
    bool Waiting() const { return waiting_; }

private:
    bool waiting_ = false;
    double since_ = 0.0;
};

}  // namespace solstream::media
