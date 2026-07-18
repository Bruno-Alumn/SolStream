#include "clipboard_listener.h"

#include <algorithm>
#include <chrono>
#include <span>
#include <vector>

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// Window class registration
// ══════════════════════════════════════════════════════════════════════════════

static const wchar_t kWindowClass[] = L"SolStreamClipboardWindow";

static ATOM RegisterWindowClass() {
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = &ClipboardListener::WndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.lpszClassName = kWindowClass;
    return RegisterClassExW(&wc);
}

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

ClipboardListener::ClipboardListener() = default;

ClipboardListener::~ClipboardListener() {
    Shutdown();
}

bool ClipboardListener::Initialize() {
    // Register the window class (once).
    static ATOM cls = RegisterWindowClass();
    if (!cls)
        return false;

    // Create a hidden window for clipboard notifications.
    m_hwnd = CreateWindowExW(
        0, kWindowClass, L"SolStream Clipboard Monitor",
        WS_OVERLAPPEDWINDOW, 0, 0, 0, 0,
        nullptr, nullptr, GetModuleHandleW(nullptr), this);

    if (!m_hwnd)
        return false;

    // Register for clipboard change notifications.
    if (!AddClipboardFormatListener(m_hwnd)) {
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
        return false;
    }

    return true;
}

void ClipboardListener::Shutdown() {
    if (m_hwnd) {
        RemoveClipboardFormatListener(m_hwnd);
        DestroyWindow(m_hwnd);
        m_hwnd = nullptr;
    }
    m_callback = nullptr;
    m_dedup.Reset();
}

// ══════════════════════════════════════════════════════════════════════════════
// Clipboard update handler
// ══════════════════════════════════════════════════════════════════════════════

void ClipboardListener::OnClipboardUpdate() {
    // Debounce: ignore changes within kDebounceMs.
    auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    if (now - m_lastChangeTime < static_cast<int64_t>(kDebounceMs) * 1'000'000)
        return;
    m_lastChangeTime = now;

    // Rate limit.
    if (m_dedup.IsRateLimited())
        return;

    // Open the clipboard.
    if (!OpenClipboard(m_hwnd))
        return;

    ClipboardSnapshot snapshot;
    snapshot.sequence = ++m_sequence;
    snapshot.originId = m_originId;

    // Enumerate and read allowed formats.
    auto formatIds = EnumerateFormats();
    for (auto fmtId : formatIds) {
        if (!IsAllowlistedFormat(fmtId))
            continue;
        if (snapshot.formats.size() >= kMaxFormatsPerSync)
            break;

        auto fmtData = ReadFormat(fmtId);
        if (!fmtData.data.empty()) {
            snapshot.formats.push_back(std::move(fmtData));
        }
    }

    CloseClipboard();

    // Dedup check.
    if (m_dedup.IsNewContent(snapshot)) {
        m_dedup.RecordSent(snapshot);

        // Notify the callback (WS server will send to macOS client).
        if (m_callback)
            m_callback(snapshot);
    }
}

std::vector<uint32_t> ClipboardListener::EnumerateFormats() {
    std::vector<uint32_t> formats;
    uint32_t fmt = 0;
    while ((fmt = EnumClipboardFormats(fmt)) != 0) {
        formats.push_back(fmt);
    }
    return formats;
}

ClipboardFormatData ClipboardListener::ReadFormat(uint32_t formatId) {
    ClipboardFormatData result;
    result.formatId = formatId;
    result.formatName = FormatIdToName(formatId);

    HANDLE hData = GetClipboardData(formatId);
    if (!hData)
        return result;

    // Lock the global handle.
    void* locked = GlobalLock(hData);
    if (!locked)
        return result;

    size_t size = GlobalSize(hData);
    if (size > 0 && size <= kMaxBytesPerFormat) {
        auto* bytes = static_cast<const uint8_t*>(locked);
        result.data.assign(bytes, bytes + size);
        result.hash = ComputeContentHash(result.data);
    }

    GlobalUnlock(hData);
    return result;
}

// ══════════════════════════════════════════════════════════════════════════════
// Window procedure
// ══════════════════════════════════════════════════════════════════════════════

LRESULT CALLBACK ClipboardListener::WndProc(HWND hwnd, UINT msg,
                                             WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_NCCREATE) {
        auto* cs = reinterpret_cast<CREATESTRUCT*>(lParam);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }

    auto* self = reinterpret_cast<ClipboardListener*>(
        GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    if (msg == WM_CLIPBOARDUPDATE && self) {
        self->OnClipboardUpdate();
        return 0;
    }

    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace solstream::clipboard
