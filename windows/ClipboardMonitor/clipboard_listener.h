#pragma once

/// @file clipboard_listener.h
/// Win32 hidden window with AddClipboardFormatListener for
/// WM_CLIPBOARDUPDATE notifications.
///
/// Thread safety: all methods must be called on the thread that owns
/// the message pump (typically the main thread).

#include <Windows.h>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

#include "clipboard_input_protocol.h"
#include "dedup.h"

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// ClipboardListener
// ══════════════════════════════════════════════════════════════════════════════
//
// Listens for clipboard changes via AddClipboardFormatListener,
// reads data for allowlisted formats, computes hashes, and invokes
// a callback with the resulting ClipboardSnapshot.
//
class ClipboardListener {
public:
    using OnChangeCallback = std::function<void(const ClipboardSnapshot&)>;

    ClipboardListener();
    ~ClipboardListener();

    ClipboardListener(const ClipboardListener&) = delete;
    ClipboardListener& operator=(const ClipboardListener&) = delete;

    /// Create the hidden clipboard listener window.
    /// Must be called on the thread that will run the message pump.
    /// Returns false if window creation fails.
    bool Initialize();

    /// Destroy the hidden window and unregister the clipboard listener.
    void Shutdown();

    /// Set the callback for clipboard change notifications.
    void SetCallback(OnChangeCallback cb) { m_callback = std::move(cb); }

    /// HWND of the hidden window (for dispatching WM_CLIPBOARDUPDATE).
    [[nodiscard]] HWND GetWindowHandle() const noexcept { return m_hwnd; }

    /// The origin ID for this session.
    void SetOriginId(uint32_t id) { m_originId = id; }

    // Window procedure (static, public — used by RegisterClassEx).
    static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg,
                                    WPARAM wParam, LPARAM lParam);

private:
    /// Handle a WM_CLIPBOARDUPDATE notification.
    void OnClipboardUpdate();

    /// Read clipboard data for a specific format.
    [[nodiscard]] ClipboardFormatData ReadFormat(uint32_t formatId);

    /// Enumerate all available formats on the clipboard.
    [[nodiscard]] std::vector<uint32_t> EnumerateFormats();

    HWND m_hwnd{};
    OnChangeCallback m_callback;
    DedupEngine m_dedup;
    uint32_t m_originId{};
    uint64_t m_sequence{};

    // Debounce: ignore rapid changes within kDebounceMs.
    uint64_t m_lastChangeTime{};
};

} // namespace solstream::clipboard
