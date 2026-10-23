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

#include <atomic>
#include <cstdint>
#include <mutex>

#include "keys.h"
#include "smt.h"

namespace solstream::media {

enum : unsigned char {
    kInputMouseAbs = 1,     ///< x u16, y u16 -- 0..65535 across the captured surface
    kInputMouseRel = 2,     ///< dx i16, dy i16
    kInputButton = 3,       ///< button u8, down u8
    kInputScrollV = 4,      ///< amount i16, in Windows wheel units (120 per click)
    kInputScrollH = 5,      ///< amount i16
    kInputKey = 6,          ///< vk u16, down u8, modifiers u8
    kInputText = 7,         ///< UTF-16 code units, for what a keycode cannot say
    /// scan u16, down u8, modifiers u8: the key by position, a set-1 make code
    /// with 0xE0 in the high byte for an extended key. See keys.h. The
    /// modifiers byte adds 0x10 for the Mac's Caps Lock being on, which this
    /// host brings its own into line with before a key goes down.
    ///
    /// Sent only by a Mac that read "scancodes" in this host's `media open`
    /// reply; anything older sends `kInputKey`, which is still taken exactly
    /// as it always was.
    kInputKeyScan = 8,
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
    ///
    /// Contiguous means from sequence 1, which is where every session starts, so
    /// this stays at zero until sequence 1 has actually been applied and only
    /// ever advances one applied sequence at a time. Anything else would tell
    /// the client that events this host never saw are safe to forget, and the
    /// client obliges: it keeps a tail of 32 and stops repeating 300 ms after
    /// the last new event, so a button-up acknowledged in error is a button
    /// held down here with nothing left anywhere to raise it.
    uint32_t Apply(const unsigned char* plaintext, size_t length);

    /// All three are read by the sender thread -- ten times a second for the
    /// acknowledgement it puts in the host-stat packet, once every five seconds
    /// for the log line -- while the receive thread is writing them. Plain
    /// integers here would be a data race in the language's terms, not merely a
    /// number that may be a datagram out of date.
    uint32_t Acknowledged() const { return acked_.load(); }
    uint64_t Applied() const { return applied_.load(); }
    uint64_t Duplicates() const { return duplicates_.load(); }
    /// Events that were recorded as seen without having been applied: a body
    /// too short for its kind, a kind this host does not know, or a SendInput
    /// that Windows refused -- typically because an elevated window has focus.
    uint64_t Failed() const { return failed_.load(); }

    /// Release everything currently held. Called when the session ends, because
    /// a client that disappears mid-drag otherwise leaves the host's mouse
    /// button down forever.
    void ReleaseAll();

    /// Forget the sequence numbers. MUST be called when a session starts.
    ///
    /// THE CLIENT'S SEQUENCE RESTARTS AT 1 FOR EVERY SESSION and this window
    /// did not, so from the second session onwards the host saw sequence 1 while
    /// it was holding a highest of a thousand-something, called every event a
    /// duplicate of something it had already applied, and threw the lot away.
    /// The first session after the agent started worked perfectly; every session
    /// after it had no mouse and no scroll wheel at all, while the video, the
    /// keyboard and resizing the window all went on working — so it read as
    /// anything but input, and nothing in any log said a word about it.
    void Reset();

private:
    bool ApplyOne(unsigned char kind, const unsigned char* body, size_t length);
    bool ScreenPoint(uint16_t nx, uint16_t ny, LONG* x, LONG* y) const;

    /// Retarget rewrites the target from the agent's command thread while the
    /// receive thread is turning coordinates into screen pixels with it. Two
    /// pointers written and read without a lock is a race whatever the hardware
    /// does with them, so every reader takes a copy under this and then lets go
    /// before it calls into Windows.
    mutable std::mutex targetLock_;
    InputTarget target_;

    std::atomic<uint32_t> acked_{0};
    std::atomic<uint64_t> applied_{0};
    std::atomic<uint64_t> duplicates_{0};
    std::atomic<uint64_t> failed_{0};

    /// A 1024-slot window of sequence numbers already applied: the replay
    /// window a layer below, for the same reason -- repeats must be free, and
    /// an event must never be applied twice. Only the receive thread touches
    /// it; Reset runs with that thread joined.
    smt::ReplayWindow seen_;
    /// Each key's and button's newest event applied, so an older one that
    /// arrives after it is passed over. See keys.h; cleared with the above.
    HoldOrder holdOrder_;

    /// Note a key going down or up, so ReleaseAll can let go of it.
    void TrackKey(uint32_t key, bool down);

    /// Press Caps Lock if the PC's is not what the Mac says its own is. See
    /// keys.h. Only the receive thread touches the belief; Reset clears it.
    void MatchCapsLock(bool wanted);
    CapsLockBelief capsLock_;

    unsigned char buttonsDown_ = 0;   ///< bitmask over the five buttons
    /// The keys held down: a virtual key from `kInputKey`, or a scan code from
    /// `kInputKeyScan` marked with `kHeldByScan`, so each is released the way
    /// it was pressed.
    static constexpr uint32_t kHeldByScan = 0x10000;
    uint32_t keysDown_[256] = {};
    int keysDownCount_ = 0;
};

}  // namespace solstream::media
