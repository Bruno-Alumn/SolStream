#pragma once

/// @file key_state_tracker.h
/// Tracks pressed keys per session. On disconnect or session
/// change, releases all held keys to prevent stuck-key scenarios.

#include <Windows.h>
#include <cstdint>
#include <mutex>
#include <unordered_set>
#include <vector>

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// KeyStateTracker
// ══════════════════════════════════════════════════════════════════════════════
//
// Tracks virtual key codes that are currently pressed. When a key-up
// arrives, removes from the set. On disconnect, sends key-up for all
// tracked keys. Also tracks modifier keys (Shift, Ctrl, Alt, Win) for
// synthetic cleanup.
//
class KeyStateTracker {
public:
    KeyStateTracker() = default;

    /// Record a key as pressed.
    void KeyDown(uint8_t vkCode);

    /// Record a key as released.
    void KeyUp(uint8_t vkCode);

    /// Release all currently-pressed keys via SendInput.
    /// Returns the number of keys released.
    int ReleaseAll();

private:
    mutable std::mutex m_mutex;
    std::unordered_set<uint8_t> m_pressedKeys;  ///< VK codes currently down
};

} // namespace solstream::input
