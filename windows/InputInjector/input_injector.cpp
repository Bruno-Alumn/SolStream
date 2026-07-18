#include "input_injector.h"

#include <cmath>
#include <cstring>
#include <thread>

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

InputInjector::InputInjector() = default;
InputInjector::~InputInjector() { ReleaseAllKeys(); }

// ══════════════════════════════════════════════════════════════════════════════
// Allowlist management
// ══════════════════════════════════════════════════════════════════════════════

void InputInjector::AddAllowedWindow(HWND hwnd) {
    if (hwnd && IsWindow(hwnd)) {
        std::lock_guard lk(m_allowlistMutex);
        m_allowedWindows.insert(hwnd);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Focus checking
// ══════════════════════════════════════════════════════════════════════════════

bool InputInjector::IsTargetFocused() const {
    HWND fg = GetForegroundWindow();
    if (!fg)
        return false;

    // Check exact match, then allowlist.
    if (fg == m_targetHwnd)
        return true;

    std::lock_guard lk(m_allowlistMutex);
    return m_allowedWindows.count(fg) > 0;
}

bool InputInjector::WaitForFocus() {
    auto deadline = std::chrono::steady_clock::now()
                    + std::chrono::milliseconds(kFocusLeaseMs);

    while (std::chrono::steady_clock::now() < deadline) {
        if (IsTargetFocused())
            return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(kFocusPollMs));
    }

    return IsTargetFocused();
}

// ══════════════════════════════════════════════════════════════════════════════
// Packet processing
// ══════════════════════════════════════════════════════════════════════════════

bool InputInjector::ProcessPacket(const InputPacket& packet) {
    // Check focus — if not focused, try the lease.
    if (!IsTargetFocused()) {
        if (!WaitForFocus()) {
            // Input discarded — window not focused.
            return false;
        }
    }

    switch (packet.type) {
    case InputType::KeyDown:
        m_keyTracker.KeyDown(packet.key.vkCode);
        return InjectKey(packet.key.vkCode, packet.key.scancode,
                         packet.key.flags, true);

    case InputType::KeyUp:
        m_keyTracker.KeyUp(packet.key.vkCode);
        return InjectKey(packet.key.vkCode, packet.key.scancode,
                         packet.key.flags, false);

    case InputType::MouseMove:
        return InjectMouseMove(packet.mouseMove.absoluteX,
                               packet.mouseMove.absoluteY);

    case InputType::MouseDown:
        return InjectMouseButton(packet.mouseButton.button, true);

    case InputType::MouseUp:
        return InjectMouseButton(packet.mouseButton.button, false);

    case InputType::MouseWheel:
        return InjectMouseWheel(packet.mouseWheel.delta);

    case InputType::Modifiers:
        return InjectModifiers(packet.modifiers.modifiers);

    default:
        return false;
    }
}

void InputInjector::ReleaseAllKeys() {
    m_keyTracker.ReleaseAll();
}

// ══════════════════════════════════════════════════════════════════════════════
// Key injection
// ══════════════════════════════════════════════════════════════════════════════

bool InputInjector::InjectKey(uint8_t vkCode, uint8_t scancode,
                              uint16_t flags, bool isDown)
{
    INPUT input{};
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = vkCode;
    input.ki.wScan = scancode;

    // Set extended key flag for navigation/insert keys.
    if (flags & KEYEVENTF_EXTENDEDKEY)
        input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;

    if (!isDown)
        input.ki.dwFlags |= KEYEVENTF_KEYUP;

    UINT sent = SendInput(1, &input, sizeof(INPUT));
    return sent == 1;
}

// ══════════════════════════════════════════════════════════════════════════════
// Mouse injection
// ══════════════════════════════════════════════════════════════════════════════

bool InputInjector::InjectMouseMove(uint32_t absX, uint32_t absY) {
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.dx = absX;
    input.mi.dy = absY;
    input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
    UINT sent = SendInput(1, &input, sizeof(INPUT));
    return sent == 1;
}

bool InputInjector::InjectMouseButton(uint8_t button, bool isDown) {
    INPUT input{};
    input.type = INPUT_MOUSE;

    DWORD downFlag = 0, upFlag = 0;
    switch (button) {
    case 0: downFlag = MOUSEEVENTF_LEFTDOWN;   upFlag = MOUSEEVENTF_LEFTUP;   break;
    case 1: downFlag = MOUSEEVENTF_RIGHTDOWN;  upFlag = MOUSEEVENTF_RIGHTUP;  break;
    case 2: downFlag = MOUSEEVENTF_MIDDLEDOWN; upFlag = MOUSEEVENTF_MIDDLEUP; break;
    default: return false;
    }

    input.mi.dwFlags = isDown ? downFlag : upFlag;
    UINT sent = SendInput(1, &input, sizeof(INPUT));
    return sent == 1;
}

bool InputInjector::InjectMouseWheel(int16_t delta) {
    INPUT input{};
    input.type = INPUT_MOUSE;
    input.mi.mouseData = static_cast<DWORD>(delta);
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    UINT sent = SendInput(1, &input, sizeof(INPUT));
    return sent == 1;
}

// ══════════════════════════════════════════════════════════════════════════════
// Modifier injection
// ══════════════════════════════════════════════════════════════════════════════

bool InputInjector::InjectModifiers(uint8_t modifiers) {
    // Compare against current tracked state and send changes.
    // Bit 0=Shift, 1=Ctrl, 2=Alt, 3=Win
    struct ModEntry { uint8_t bit; uint8_t vk; } const modMap[] = {
        {0x01, VK_SHIFT},   {0x02, VK_CONTROL},
        {0x04, VK_MENU},    {0x08, VK_LWIN},
    };

    bool allOk = true;
    for (auto& m : modMap) {
        bool shouldBeDown = (modifiers & m.bit) != 0;
        // In a full implementation, compare against actual key state.
        // For simplicity, inject the modifier state directly.
        // The key_state_tracker handles individual key tracking.
        INPUT input{};
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = m.vk;
        if (!shouldBeDown)
            input.ki.dwFlags |= KEYEVENTF_KEYUP;
        UINT sent = SendInput(1, &input, sizeof(INPUT));
        if (sent != 1) allOk = false;
    }

    return allOk;
}

} // namespace solstream::input
