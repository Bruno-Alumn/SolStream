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
// is done on a thread of its own with a bound on the wait, which covers the
// first seconds of a hang, before Windows reports it. A thread that is still
// stuck when the bound runs out is left to finish on its own; it holds nothing
// the command thread needs.
//
// Header-only, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <functional>
#include <memory>
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

inline DWORD WINAPI RunBoundedJob(void* param) {
    const std::unique_ptr<std::function<void()>> job(static_cast<std::function<void()>*>(param));
    (*job)();
    return 0;
}

/// Run `work` on a thread of its own and wait at most `timeout_ms` for it.
/// True when it finished in time. When it did not it carries on regardless,
/// so `work` must own everything it uses: capture by value. Without a thread
/// to run it on, it runs here, unbounded, as it did before there was a bound.
inline bool RunWithin(DWORD timeout_ms, std::function<void()> work) {
    auto* job = new std::function<void()>(std::move(work));
    HANDLE thread = CreateThread(nullptr, 0, RunBoundedJob, job, 0, nullptr);
    if (!thread) {
        RunBoundedJob(job);
        return true;
    }
    const bool finished = WaitForSingleObject(thread, timeout_ms) == WAIT_OBJECT_0;
    CloseHandle(thread);
    return finished;
}

}  // namespace solstream
