#include "paste_injector.h"

#include <cstring>
#include <thread>

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

PasteInjector::PasteInjector() = default;

PasteInjector::~PasteInjector() {
    Disconnect();
}

// ══════════════════════════════════════════════════════════════════════════════
// Connection management
// ══════════════════════════════════════════════════════════════════════════════

bool PasteInjector::Connect(uint32_t timeoutMs) {
    std::lock_guard lk(m_mutex);

    if (m_hPipe != INVALID_HANDLE_VALUE)
        return true;  // Already connected

    // Wait for the pipe to become available.
    if (!WaitNamedPipeW(kInputInjectorPipe, timeoutMs))
        return false;

    m_hPipe = CreateFileW(
        kInputInjectorPipe,
        GENERIC_WRITE,
        0, nullptr,
        OPEN_EXISTING,
        0, nullptr);

    if (m_hPipe == INVALID_HANDLE_VALUE)
        return false;

    // Set message write mode.
    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(m_hPipe, &mode, nullptr, nullptr);

    return true;
}

void PasteInjector::Disconnect() {
    std::lock_guard lk(m_mutex);
    if (m_hPipe != INVALID_HANDLE_VALUE) {
        CloseHandle(m_hPipe);
        m_hPipe = INVALID_HANDLE_VALUE;
    }
}

bool PasteInjector::IsConnected() const noexcept {
    std::lock_guard lk(m_mutex);
    return m_hPipe != INVALID_HANDLE_VALUE;
}

// ══════════════════════════════════════════════════════════════════════════════
// Ctrl+V injection
// ══════════════════════════════════════════════════════════════════════════════

void PasteInjector::SendCtrlV(uint32_t delayMs) {
    // Delay to allow IDataObject to propagate on the clipboard.
    if (delayMs > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(delayMs));

    std::lock_guard lk(m_mutex);
    if (m_hPipe == INVALID_HANDLE_VALUE)
        return;

    // Build the Ctrl+V sequence: Ctrl-down, V-down, V-up, Ctrl-up.
    auto ctrlDown = MakeKeyPacket(VK_CONTROL, true);
    auto vDown    = MakeKeyPacket(0x56, true);      // 'V'
    auto vUp      = MakeKeyPacket(0x56, false);
    auto ctrlUp   = MakeKeyPacket(VK_CONTROL, false);

    InputPacket packets[] = { ctrlDown, vDown, vUp, ctrlUp };

    for (auto& pkt : packets) {
        DWORD written = 0;
        WriteFile(m_hPipe, &pkt, sizeof(pkt), &written, nullptr);
        // Small inter-key delay for reliable input processing.
        if (written > 0)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

InputPacket PasteInjector::MakeKeyPacket(uint8_t vkCode, bool isDown) {
    InputPacket pkt{};
    pkt.type = isDown ? InputType::KeyDown : InputType::KeyUp;
    pkt.key.vkCode = vkCode;
    pkt.key.scancode = static_cast<uint8_t>(MapVirtualKeyW(vkCode, MAPVK_VK_TO_VSC));
    return pkt;
}

} // namespace solstream::filetransfer
