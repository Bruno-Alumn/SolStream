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

    /// Release all modifier keys only.
    int ReleaseModifiers();

    /// Check if any keys are currently pressed.
    [[nodiscard]] bool HasPressedKeys() const;

    /// Get the set of pressed keys (for debugging).
    [[nodiscard]] std::vector<uint8_t> GetPressedKeys() const;

    /// Reset all state without sending input.
    void Reset();

private:
    mutable std::mutex m_mutex;
    std::unordered_set<uint8_t> m_pressedKeys;  ///< VK codes currently down

    /// Known modifier virtual key codes.
    static constexpr uint8_t kModifiers[] = {
        VK_SHIFT,   VK_LSHIFT,  VK_RSHIFT,
        VK_CONTROL, VK_LCONTROL, VK_RCONTROL,
        VK_MENU,    VK_LMENU,   VK_RMENU,    // Alt
        VK_LWIN,    VK_RWIN,
    };

    [[nodiscard]] static bool IsModifier(uint8_t vkCode);
};

} // namespace solstream::input
