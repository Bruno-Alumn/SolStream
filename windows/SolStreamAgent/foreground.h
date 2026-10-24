// foreground.h — taking the PC's foreground without waiting on a hung app.
//
// ForceForeground in main.cpp joins the input queue of whichever thread holds
// the foreground, so that Windows lets it hand the foreground on. With the
// queues joined, the old window's deactivation is SENT to that thread rather
// than posted, and a thread that has stopped reading its messages never
// answers. A game hung in front of everything on the PC then held the command
// thread with it: every later command queued behind the `focus`, the Mac gave
// up after ten seconds, and every reconnect was refused as busy because the
// stuck connection still counted as the live one.
//
// So a holder Windows already reports as hung is never joined, and the asking
// -- the window's restore and raise as well, which wait on the window's own
// app -- is done on a worker thread, with a bound on the command thread's wait
// for it, which covers the first seconds of a hang, before Windows reports it.
//
// One worker, and it only ever does the newest request (LatestJobWorker). A
// thread per request piled up a stuck thread for every click while an app
// hung, each able to put its own window in front whenever that app let it go.
// Now a request made while the worker is busy replaces the one waiting, and
// only it runs once the worker is free; and a request it was stuck on puts the
// newest request's window in front, rather than its own, which the user has
// since moved on from (ForegroundTurns). Without a worker thread the
// foreground is not asked for at all: done on the command thread it would have
// no bound.
//
// One worker stuck would stop every window being raised, which capture needs
// even when focus cannot be won. So the worker asks the window first, for a
// tenth of a second, and one that does not answer is only raised
// asynchronously, never joined to. And a worker stuck all the same for longer
// than kForegroundStuckMs is left to finish on its own and a fresh one takes
// over -- a few times over the host's life, no more (DecideStuckWorker). The
// one that is stuck may be joined to the holder's queue, so only one thread at
// a time joins one (ForegroundTurns::BeginJoin): a fresh worker joining the
// same hung holder would only be stuck beside it.
//
// Header-only, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <utility>

namespace solstream {

/// How long the command thread waits for the foreground to be asked for.
/// Asking takes a few milliseconds when the apps involved are answering.
constexpr DWORD kForegroundWaitMs = 500;

/// How long the worker asks a window whether it is answering before waiting on
/// it. IsHungAppWindow says so only after five seconds.
constexpr UINT kForegroundProbeMs = 100;

/// How long a request may run before its worker counts as stuck and a fresh
/// one takes over, and how many times over the host's life that happens.
constexpr ULONGLONG kForegroundStuckMs = 2000;
constexpr int kForegroundMaxReplacements = 3;

/// Whether `window`'s thread answers a message within `timeout_ms`.
inline bool AnswersWithin(HWND window, UINT timeout_ms) {
    DWORD_PTR result = 0;
    return SendMessageTimeoutW(window, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, timeout_ms, &result)
           != 0;
}

enum class StuckWorker { Keep, Replace, Exhausted };

/// What to do about the worker after the command thread has given up waiting:
/// `running_ms` is how long its current request has run (0 when it is idle),
/// `replaced` how many fresh workers have been started before. Keep it while it
/// is idle or has not been at it long; replace it while there are replacements
/// left; and once there are none, it is exhausted.
inline StuckWorker DecideStuckWorker(ULONGLONG running_ms, int replaced,
                                     ULONGLONG stuck_ms = kForegroundStuckMs,
                                     int max_replacements = kForegroundMaxReplacements) {
    if (running_ms == 0 || running_ms < stuck_ms) {
        return StuckWorker::Keep;
    }
    return replaced < max_replacements ? StuckWorker::Replace : StuckWorker::Exhausted;
}

/// Whether to join the input queue of the thread holding the foreground. Not
/// when there is none, when it is the asking thread itself, or when Windows
/// already says its window is hung.
inline bool JoinsHolderQueue(DWORD holder_thread, DWORD self_thread, bool holder_hung) {
    return holder_thread != 0 && holder_thread != self_thread && !holder_hung;
}

/// The requests for the foreground, in order. Begun on the command thread;
/// read by the worker doing the asking.
class ForegroundTurns {
public:
    struct Turn {
        uint64_t generation = 0;
    };

    /// A new request, for `window`.
    Turn Begin(HWND window) {
        target_.store(window);
        Turn turn;
        turn.generation = latest_.fetch_add(1) + 1;
        return turn;
    }

    /// Whether a newer request has come since `turn` began.
    bool Overtaken(const Turn& turn) const { return latest_.load() != turn.generation; }

    /// The window `turn` should put in front now: its own, `own`, until it is
    /// overtaken, and the newest request's after that.
    HWND Wanted(const Turn& turn, HWND own) const {
        return Overtaken(turn) ? target_.load() : own;
    }

    /// Whether this thread may join the holder's queue: only when no other one
    /// is joined to a queue now -- perhaps a replaced worker, stuck there.
    /// EndJoin when it has left it.
    bool BeginJoin() { return !joining_.exchange(true); }
    void EndJoin() { joining_.store(false); }

private:
    std::atomic<uint64_t> latest_{0};
    std::atomic<HWND> target_{nullptr};
    std::atomic<bool> joining_{false};
};

/// One thread, started on first use, that runs the newest job handed to it. A
/// job handed over while another runs waits; a newer one replaces it, and the
/// replaced one never runs. A thread stuck in a job can be given up on
/// (ReplaceIfStuck): it leaves once that job returns, if it ever does, and a
/// fresh thread runs what is waiting. So there is one thread working, a few
/// stuck at most, and one job waiting.
///
/// Never destroyed: its threads run for the life of the process, and read it
/// to the last. Make it with `new` and keep it.
class LatestJobWorker {
public:
    LatestJobWorker() = default;
    LatestJobWorker(const LatestJobWorker&) = delete;
    LatestJobWorker& operator=(const LatestJobWorker&) = delete;

    /// Hand `job` over, replacing any job not yet started. Returns its ticket
    /// for WaitFor, or 0 when there is no thread to run it -- it could not be
    /// started -- and the job is dropped. `job` may run after its caller has
    /// stopped waiting, so it must own everything it uses: capture by value.
    uint64_t Submit(std::function<void()> job) {
        AcquireSRWLockExclusive(&lock_);
        if (!started_) {
            if (!StartLocked()) {
                ReleaseSRWLockExclusive(&lock_);
                return 0;
            }
            started_ = true;
        }
        pending_ = std::move(job);
        const uint64_t ticket = ++submitted_;
        ReleaseSRWLockExclusive(&lock_);
        WakeConditionVariable(&wake_);
        return ticket;
    }

    /// Wait at most `timeout_ms` for the worker to have finished `ticket`, or a
    /// job handed over after it, which replaced it. True when it has.
    bool WaitFor(uint64_t ticket, DWORD timeout_ms) {
        const ULONGLONG deadline = GetTickCount64() + timeout_ms;
        AcquireSRWLockExclusive(&lock_);
        while (finished_ < ticket) {
            const ULONGLONG now = GetTickCount64();
            if (now >= deadline
                || (!SleepConditionVariableSRW(&done_, &lock_, (DWORD) (deadline - now), 0)
                    && GetLastError() != ERROR_TIMEOUT)) {
                break;
            }
        }
        const bool finished = finished_ >= ticket;
        ReleaseSRWLockExclusive(&lock_);
        return finished;
    }

    /// When the working thread has been in one job for `stuck_ms` or more,
    /// give up on it and start a fresh one, `max_replacements` times at most
    /// over this worker's life; see DecideStuckWorker. Replace when it did,
    /// Exhausted when it would have but may not -- or could not start one.
    StuckWorker ReplaceIfStuck(ULONGLONG stuck_ms = kForegroundStuckMs,
                               int max_replacements = kForegroundMaxReplacements) {
        AcquireSRWLockExclusive(&lock_);
        const ULONGLONG running =
            running_since_ == 0 ? 0 : GetTickCount64() - running_since_ + 1;
        StuckWorker verdict = DecideStuckWorker(running, replacements_, stuck_ms,
                                                max_replacements);
        if (verdict == StuckWorker::Replace) {
            const uint64_t stuck_epoch = epoch_;
            ++epoch_;
            if (StartLocked()) {
                ++replacements_;
                running_since_ = 0;
            } else {
                epoch_ = stuck_epoch;   // the stuck one is all there is
                verdict = StuckWorker::Exhausted;
            }
        }
        ReleaseSRWLockExclusive(&lock_);
        WakeAllConditionVariable(&wake_);
        return verdict;
    }

private:
    struct Start {
        LatestJobWorker* self;
        uint64_t epoch;
    };

    /// A thread for the current epoch. Call with lock_ held.
    bool StartLocked() {
        auto* start = new Start{this, epoch_};
        HANDLE thread = CreateThread(nullptr, 0, Run, start, 0, nullptr);
        if (!thread) {
            delete start;
            return false;
        }
        CloseHandle(thread);
        return true;
    }

    static DWORD WINAPI Run(void* param) {
        LatestJobWorker* const self = static_cast<Start*>(param)->self;
        const uint64_t epoch = static_cast<Start*>(param)->epoch;
        delete static_cast<Start*>(param);
        for (;;) {
            AcquireSRWLockExclusive(&self->lock_);
            while (self->epoch_ == epoch && !self->pending_) {
                SleepConditionVariableSRW(&self->wake_, &self->lock_, INFINITE, 0);
            }
            if (self->epoch_ != epoch) {   // given up on; a fresh one works now
                ReleaseSRWLockExclusive(&self->lock_);
                return 0;
            }
            std::function<void()> job = std::move(self->pending_);
            self->pending_ = nullptr;
            const uint64_t ticket = self->submitted_;
            self->running_since_ = GetTickCount64();
            ReleaseSRWLockExclusive(&self->lock_);
            job();
            AcquireSRWLockExclusive(&self->lock_);
            if (ticket > self->finished_) {
                self->finished_ = ticket;
            }
            if (self->epoch_ == epoch) {
                self->running_since_ = 0;
            }
            ReleaseSRWLockExclusive(&self->lock_);
            WakeAllConditionVariable(&self->done_);
        }
    }

    SRWLOCK lock_ = SRWLOCK_INIT;
    CONDITION_VARIABLE wake_ = CONDITION_VARIABLE_INIT;   // a job is waiting
    CONDITION_VARIABLE done_ = CONDITION_VARIABLE_INIT;   // a job has finished
    std::function<void()> pending_;   // all guarded by lock_
    uint64_t submitted_ = 0;
    uint64_t finished_ = 0;
    /// Which thread is the working one; the others leave after their job.
    uint64_t epoch_ = 0;
    /// When the working thread began its job (GetTickCount64), 0 when idle.
    ULONGLONG running_since_ = 0;
    int replacements_ = 0;
    bool started_ = false;
};

}  // namespace solstream
