#include "key_state_tracker.h"

#include <cstring>

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

bool KeyStateTracker::IsModifier(uint8_t vkCode) {
    for (auto m : kModifiers)
        if (m == vkCode) return true;
    return false;
}

// ══════════════════════════════════════════════════════════════════════════════
// Key tracking
// ══════════════════════════════════════════════════════════════════════════════

void KeyStateTracker::KeyDown(uint8_t vkCode) {
    std::lock_guard lk(m_mutex);
    m_pressedKeys.insert(vkCode);
}

void KeyStateTracker::KeyUp(uint8_t vkCode) {
    std::lock_guard lk(m_mutex);
    m_pressedKeys.erase(vkCode);
}

bool KeyStateTracker::HasPressedKeys() const {
    std::lock_guard lk(m_mutex);
    return !m_pressedKeys.empty();
}

std::vector<uint8_t> KeyStateTracker::GetPressedKeys() const {
    std::lock_guard lk(m_mutex);
    return {m_pressedKeys.begin(), m_pressedKeys.end()};
}

void KeyStateTracker::Reset() {
    std::lock_guard lk(m_mutex);
    m_pressedKeys.clear();
}

// ══════════════════════════════════════════════════════════════════════════════
// Key release
// ══════════════════════════════════════════════════════════════════════════════

/// Build a KEYBDINPUT structure for a key event.
static INPUT MakeKeyInput(uint8_t vkCode, bool extended, bool keyUp) {
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vkCode;
    if (extended)
        input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    if (keyUp)
        input.ki.dwFlags |= KEYEVENTF_KEYUP;
    return input;
}

int KeyStateTracker::ReleaseAll() {
    std::lock_guard lk(m_mutex);
    int count = 0;

    // Build INPUT array for all pressed keys (key-up).
    std::vector<INPUT> inputs;
    inputs.reserve(m_pressedKeys.size());

    for (auto vk : m_pressedKeys) {
        bool extended = (vk == VK_LEFT || vk == VK_RIGHT ||
                         vk == VK_UP || vk == VK_DOWN ||
                         vk == VK_PRIOR || vk == VK_NEXT ||
                         vk == VK_HOME || vk == VK_END ||
                         vk == VK_INSERT || vk == VK_DELETE ||
                         vk == VK_LWIN || vk == VK_RWIN);
        inputs.push_back(MakeKeyInput(vk, extended, true));
    }

    if (!inputs.empty()) {
        UINT sent = SendInput(static_cast<UINT>(inputs.size()),
                              inputs.data(), sizeof(INPUT));
        count = static_cast<int>(sent);
    }

    m_pressedKeys.clear();
    return count;
}

int KeyStateTracker::ReleaseModifiers() {
    std::lock_guard lk(m_mutex);
    std::vector<INPUT> inputs;

    for (auto vk : kModifiers) {
        if (m_pressedKeys.erase(vk) > 0) {
            inputs.push_back(MakeKeyInput(vk, false, true));
        }
    }

    if (!inputs.empty()) {
        SendInput(static_cast<UINT>(inputs.size()),
                  inputs.data(), sizeof(INPUT));
    }

    return static_cast<int>(inputs.size());
}

} // namespace solstream::input
