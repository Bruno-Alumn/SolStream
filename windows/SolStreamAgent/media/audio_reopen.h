// audio_reopen.h — when the sound capture gives up on what it has open, and
// opens it again.
//
// The whole PC's sound is a loopback of the default output device, and that
// device changes under a running session as a matter of course: a headset is
// plugged in, a Bluetooth one connects and becomes the default, the monitor
// carrying the sound over HDMI is switched off. The old capture then fails
// with AUDCLNT_E_DEVICE_INVALIDATED, or goes on capturing a device nothing
// plays to any more. Either way the Mac hears nothing, and cannot tell that
// from silence: the host sends nothing during silence too. So the host has to
// notice by itself and open the new device -- and an app's tap needs the same
// when the audio service restarts under it.
//
// The decisions are here, apart from audio.cpp, which builds only with MSVC,
// so that updater_tests.cpp can check them. Nothing here touches a device.
// Times are milliseconds, from GetTickCount64.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <audioclient.h>

#include <cstdint>
#include <string>

namespace solstream::media {

/// The least time between two opens of one capture, whether the first worked
/// or not: a device that is not there yet is asked twice a second, and one
/// that opens and fails at once is not opened in a tight loop.
constexpr uint64_t kReopenRetryMs = 500;

/// The wait after an open that timed out instead of failing. OpenTap gives an
/// app's activation two seconds; one that has not answered by then belongs to
/// a wedged audio service, is still outstanding, and holds the audio thread
/// for the whole of those two seconds. Starting another every half second
/// would keep the thread in back-to-back waits, piling up activations and
/// holding up the end of the session by two seconds a tap.
constexpr uint64_t kTimedOutRetryMs = 10000;

/// How often the whole PC's capture asks which device is the default. A
/// device that stops being the default still works, and its capture goes on
/// delivering -- silence -- so asking is the only way to notice.
constexpr uint64_t kDefaultDeviceCheckMs = 1000;

/// How long a read may go on failing, with an error that does not say the
/// device has gone, before the capture is closed and opened again anyway.
constexpr uint64_t kPersistentFailureMs = 250;

/// How long a capture has to have worked before trouble with it counts as new,
/// and is said in the log whatever was said before.
constexpr uint64_t kSteadyMs = 5000;

/// How long a repeat of the trouble last said is kept out of the log.
constexpr uint64_t kRepeatQuietMs = 60000;

/// Whether a capture's reads have failed for long enough to give up on it.
class ReadTrouble {
public:
    /// A read that worked, which ends any run of failures.
    void Worked() { failing_ = false; }

    /// A read that failed with `hr` at `now`. True when the capture is to be
    /// closed and opened again: at once when the device has gone or the audio
    /// service has stopped, which no amount of waiting brings back, and for
    /// any other failure once it has lasted kPersistentFailureMs. A true
    /// answer ends the run, so the capture opened next starts afresh.
    bool GiveUp(HRESULT hr, uint64_t now) {
        if (hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING) {
            failing_ = false;
            return true;
        }
        if (!failing_) {
            failing_ = true;
            since_ = now;
        }
        if (now - since_ >= kPersistentFailureMs) {
            failing_ = false;
            return true;
        }
        return false;
    }

private:
    bool failing_ = false;
    uint64_t since_ = 0;
};

/// When a capture may be opened again, and which lines about it go in the log.
///
/// The log is what the host is checked with, and a capture in trouble must not
/// fill it: a PC whose only sound device is a monitor that has been switched
/// off fails to open twice a second for as long as it stays off. So the first
/// trouble is said, and so is any different trouble after it, but a repeat of
/// the last is said once a minute. A capture that has worked for kSteadyMs
/// since it opened ends the trouble, so the next is said in full however soon
/// it comes and whatever it is. That it opened again is said only when the
/// trouble before it was.
class Reopener {
public:
    /// Whether an open may be tried at `now`.
    bool Due(uint64_t now) const { return !tried_ || now - triedAt_ >= wait_; }

    /// An open that worked, at `now` -- when it returned, not when it began,
    /// since an open can take seconds. True when that belongs in the log: the
    /// first, and the first after trouble that was said.
    bool Opened(uint64_t now) {
        Tried(now);
        open_ = true;
        openedAt_ = now;
        const bool say = sayOpened_;
        sayOpened_ = false;
        return say;
    }

    /// An open that failed with `hr`, at `now`, when it returned. True when
    /// that belongs in the log. One that timed out is not tried again for
    /// kTimedOutRetryMs.
    bool OpenFailed(HRESULT hr, uint64_t now) {
        Tried(now);
        if (hr == HRESULT_FROM_WIN32(ERROR_TIMEOUT)) { wait_ = kTimedOutRetryMs; }
        return Say(hr, now);
    }

    /// The open capture was given up on at `now`: it failed with `why`, or
    /// `why` is S_OK because another device became the default. True when that
    /// belongs in the log.
    bool Lost(HRESULT why, uint64_t now) {
        if (open_ && now - openedAt_ >= kSteadyMs) { said_ = false; }
        open_ = false;
        return Say(why, now);
    }

private:
    void Tried(uint64_t now) {
        tried_ = true;
        triedAt_ = now;
        wait_ = kReopenRetryMs;
    }

    bool Say(HRESULT why, uint64_t now) {
        if (said_ && why == lastSaid_ && now - saidAt_ < kRepeatQuietMs) { return false; }
        said_ = true;
        lastSaid_ = why;
        saidAt_ = now;
        sayOpened_ = true;
        return true;
    }

    bool tried_ = false;
    uint64_t triedAt_ = 0;
    uint64_t wait_ = kReopenRetryMs;
    bool open_ = false;
    uint64_t openedAt_ = 0;
    bool said_ = false;
    HRESULT lastSaid_ = S_OK;
    uint64_t saidAt_ = 0;
    bool sayOpened_ = true;
};

/// Whether another output device has become the default since the one being
/// captured, whose id is `opened`, was opened. No answer -- an empty `current`,
/// because there is no default device at all or the question failed -- is not
/// a change: if the open device has gone, its reads say so.
inline bool DefaultDeviceMoved(const std::wstring& opened, const std::wstring& current) {
    return !opened.empty() && !current.empty() && opened != current;
}

}  // namespace solstream::media
