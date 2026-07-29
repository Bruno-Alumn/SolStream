// input.h — SMT/1's input events, and the SendInput that applies them.
//
// The wire format is SolStream's own. The one property it is designed around is
// that UDP loses packets and input is not idempotent: a lost key-up leaves a key
// held down, and a lost mouse-button-up leaves a drag running. So every event
// carries a sequence number, the client repeats recent events on later
// datagrams, and the host DEDUPLICATES BY SEQUENCE rather than trusting arrival.
// Repetition is then free to be generous.
//
//   off  w  field
//    0   1  type = 0x30
//    1   1  event count
//    2   2  reserved
//    4   N  events
//
// Each event:
//
//    0   4  seq, big-endian
//    4   1  kind
//    5   1  body length
//    6   L  body

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <cstdint>

namespace solstream::media {

enum : unsigned char {
    kInputMouseAbs = 1,     ///< x u16, y u16 -- 0..65535 across the captured surface
    kInputMouseRel = 2,     ///< dx i16, dy i16
    kInputButton = 3,       ///< button u8, down u8
    kInputScrollV = 4,      ///< amount i16, in Windows wheel units (120 per click)
    kInputScrollH = 5,      ///< amount i16
    kInputKey = 6,          ///< vk u16, down u8, modifiers u8
    kInputText = 7,         ///< UTF-16 code units, for what a keycode cannot say
};

/// Where absolute coordinates land.
struct InputTarget {
    HWND window = nullptr;      ///< set for a window capture
    HMONITOR monitor = nullptr; ///< set for a display capture
};

class InputInjector {
public:
    void SetTarget(const InputTarget& target);

    /// Apply one datagram's worth of events. Returns the highest contiguous
    /// sequence number applied so far, which is what the host echoes back so the
    /// client can stop repeating.
    uint32_t Apply(const unsigned char* plaintext, size_t length);

    uint32_t Acknowledged() const { return acked_; }
    uint64_t Applied() const { return applied_; }
    uint64_t Duplicates() const { return duplicates_; }

    /// Release everything currently held. Called when the session ends, because
    /// a client that disappears mid-drag otherwise leaves the host's mouse
    /// button down forever.
    void ReleaseAll();

private:
    bool ApplyOne(unsigned char kind, const unsigned char* body, size_t length);
    bool ScreenPoint(uint16_t nx, uint16_t ny, LONG* x, LONG* y) const;

    InputTarget target_;
    uint32_t acked_ = 0;
    uint64_t applied_ = 0;
    uint64_t duplicates_ = 0;

    /// A 1024-slot window of sequence numbers already applied, the same shape as
    /// the replay window a layer below and for the same reason: repeats must be
    /// free, and an event must never be applied twice.
    uint64_t seen_[16] = {};
    uint32_t highest_ = 0;
    bool started_ = false;

    unsigned char buttonsDown_ = 0;   ///< bitmask over the five buttons
    unsigned short keysDown_[256] = {};
    int keysDownCount_ = 0;
};

}  // namespace solstream::media
