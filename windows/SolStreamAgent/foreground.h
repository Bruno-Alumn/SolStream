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
// One worker, for the life of the host, and it only ever does the newest
// request (LatestJobWorker). A thread per request piled up a stuck thread for
// every click while an app hung, each able to put its own window in front
// whenever that app let it go. Now a request made while the worker is stuck
// replaces the one waiting, and only it runs once the worker is free; and a
// request it is stuck on puts the newest request's window in front, rather
// than its own, which the user has since moved on from (ForegroundTurns).
// Without a worker thread the foreground is not asked for at all: done on the
// command thread it would have no bound.
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

private:
    std::atomic<uint64_t> latest_{0};
    std::atomic<HWND> target_{nullptr};
};

/// One thread, started on first use and never stopped, that runs the newest job
/// handed to it. A job handed over while another runs waits; a newer one
/// replaces it, and the replaced one never runs. So however long a job is stuck,
/// there is one thread, and one job waiting behind it.
///
/// Never destroyed: its thread runs for the life of the process, and reads it
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
            HANDLE thread = CreateThread(nullptr, 0, Run, this, 0, nullptr);
            if (!thread) {
                ReleaseSRWLockExclusive(&lock_);
                return 0;
            }
            CloseHandle(thread);
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

private:
    static DWORD WINAPI Run(void* param) {
        auto* self = static_cast<LatestJobWorker*>(param);
        for (;;) {
            AcquireSRWLockExclusive(&self->lock_);
            while (!self->pending_) {
                SleepConditionVariableSRW(&self->wake_, &self->lock_, INFINITE, 0);
            }
            std::function<void()> job = std::move(self->pending_);
            self->pending_ = nullptr;
            const uint64_t ticket = self->submitted_;
            ReleaseSRWLockExclusive(&self->lock_);
            job();
            AcquireSRWLockExclusive(&self->lock_);
            self->finished_ = ticket;
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
    bool started_ = false;
};

}  // namespace solstream
