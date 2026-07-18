#pragma once

/// @file paste_injector.h
/// Sends Ctrl+V keystrokes to the InputInjector pipe to trigger a
/// paste operation 500ms after a file transfer completes.
///
/// Thread safety: all methods are thread-safe (internal mutex).

#include <Windows.h>
#include <cstdint>
#include <mutex>
#include <string>

#include "../ClipboardMonitor/clipboard_input_protocol.h"

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// PasteInjector
// ══════════════════════════════════════════════════════════════════════════════
//
// Connects to the InputInjector named pipe and sends Ctrl+V key events.
// Uses the InputPacket protocol defined in ClipboardMonitor.
//
class PasteInjector {
public:
    PasteInjector();
    ~PasteInjector();

    PasteInjector(const PasteInjector&) = delete;
    PasteInjector& operator=(const PasteInjector&) = delete;

    /// Connect to the InputInjector pipe.
    /// Returns false if the pipe is unavailable.
    [[nodiscard]] bool Connect(uint32_t timeoutMs = 10000);

    /// Disconnect from the pipe.
    void Disconnect();

    /// Check if connected.
    [[nodiscard]] bool IsConnected() const noexcept;

    /// Send Ctrl+V to the target window.
    /// The paste is delayed by 500ms to allow the IDataObject to be
    /// fully set on the clipboard.
    void SendCtrlV(uint32_t delayMs = 500);

private:
    // Pipe handle.
    HANDLE m_hPipe{INVALID_HANDLE_VALUE};
    mutable std::mutex m_mutex;

    // Build an InputPacket for a key event.
    [[nodiscard]] static InputPacket MakeKeyPacket(uint8_t vkCode,
                                                    bool isDown);
};

} // namespace solstream::filetransfer
