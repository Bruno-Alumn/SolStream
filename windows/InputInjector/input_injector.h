#pragma once

/// @file input_injector.h
/// SendInput wrapper with focus-aware injection and
/// 100ms lease with 10ms polling.
///
/// Thread safety: all methods must be called from a single thread
/// (the pipe receive thread) or serialised externally.

#include <Windows.h>
#include <cstdint>
#include <chrono>
#include <mutex>
#include <unordered_set>

#include "../ClipboardMonitor/clipboard_input_protocol.h"
#include "key_state_tracker.h"

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// InputInjector
// ══════════════════════════════════════════════════════════════════════════════
//
// Receives InputPacket structs (from ClipboardMonitor via named pipe)
// and calls SendInput with focus-gating.
//
// Focus gating rules:
//   1. Check GetForegroundWindow() == m_targetHwnd before injection.
//   2. If mismatch: enter 100ms lease with 10ms polling.
//   3. If lease expires without focus: discard input.
//   4. Only inject into HWNDs from the streamed session (allowlist).
//   5. On disconnect: release all keys via KeyStateTracker::ReleaseAll().
//
class InputInjector {
public:
    InputInjector();
    ~InputInjector();

    InputInjector(const InputInjector&) = delete;
    InputInjector& operator=(const InputInjector&) = delete;

    /// Set the target HWND for injection.
    void SetTargetWindow(HWND hwnd) { m_targetHwnd = hwnd; }

    /// Process an input packet.
    /// Returns true if the packet was injected (or queued within lease).
    bool ProcessPacket(const InputPacket& packet);

    /// Release all held keys (call on disconnect).
    void ReleaseAllKeys();

    /// Check if the target window is currently in the foreground.
    [[nodiscard]] bool IsTargetFocused() const;

private:
    // Inject a single key event.
    bool InjectKey(uint8_t vkCode, uint8_t scancode, uint16_t flags, bool isDown);

    // Inject a mouse event.
    bool InjectMouseMove(uint32_t absX, uint32_t absY);
    bool InjectMouseButton(uint8_t button, bool isDown);
    bool InjectMouseWheel(int16_t delta);

    // Inject modifier flags.
    bool InjectModifiers(uint8_t modifiers);

    // Check focus with polling lease.
    bool WaitForFocus();

    KeyStateTracker m_keyTracker;

    HWND m_targetHwnd{};
    mutable std::mutex m_allowlistMutex;
    std::unordered_set<HWND> m_allowedWindows;

    // Focus polling
    static constexpr int kFocusLeaseMs  = 100;
    static constexpr int kFocusPollMs   = 10;
};

} // namespace solstream::input
