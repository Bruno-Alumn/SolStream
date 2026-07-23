#pragma once

#include <Windows.h>
#include <d3d11.h>
#include <wrl/client.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <winrt/Windows.System.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <string_view>

namespace SolStream::Capture {

// ── Exception ───────────────────────────────────────────────────────────────

class CaptureException final : public std::runtime_error {
public:
    CaptureException(std::string_view msg, HRESULT hr);
    [[nodiscard]] HRESULT HResult() const noexcept { return m_hresult; }
private:
    HRESULT m_hresult;
};

// ── State machine ───────────────────────────────────────────────────────────

enum class CaptureState : std::uint8_t {
    Idle,
    Capturing,
    Error,
    DeviceLost,
};

// ── Frame result ────────────────────────────────────────────────────────────

/// A captured frame with its native D3D11 texture.
struct CapturedFrame {
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    std::uint64_t frameIndex{};
    std::chrono::steady_clock::time_point timestamp;
};

// ── Window Capture ──────────────────────────────────────────────────────────
//
// Captures a single HWND via WinRT Graphics Capture (CreateFreeThreaded).
//
// THREAD SAFETY:
//   All public methods are internally mutex-protected against the
//   frame-arrival callback which runs on an arbitrary thread-pool thread.
//   The following are safe from any thread:
//     StartCapture(), StopCapture(), Reset(), TryGetNextFrame(),
//     GetState(), GetFrameCount()
//
//   Internal state is protected by m_mutex (recursive, so the exception
//   handler in OnFrameArrived can safely re-acquire it).
//
//   NOTE: GetTargetWindow() reads m_hwnd without the mutex. Do not call
//   it concurrently with StartCapture or StopCapture.
//
// STATE MACHINE (legal transitions enforced in implementation):
//   Idle → StartCapture() → Capturing → StopCapture() → Idle
//   Capturing → (window minimized) → Paused → (restored) → Capturing
//   Capturing/Paused → (device lost) → DeviceLost → Reset() → Idle
//   Any → (fatal error) → Error
//
// TryGetNextFrame() behavior per state:
//   Capturing: returns CapturedFrame or empty if none available
//   Paused:    returns empty
//   Idle/Error/DeviceLost: returns empty
//
class WindowCapture {
public:
    WindowCapture();
    ~WindowCapture();

    WindowCapture(const WindowCapture&) = delete;
    WindowCapture& operator=(const WindowCapture&) = delete;
    WindowCapture(WindowCapture&&) = delete;
    WindowCapture& operator=(WindowCapture&&) = delete;

    /// Start capturing the given window.
    /// Throws CaptureException if capture is unsupported or setup fails.
    /// The D3D11 device must have D3D11_CREATE_DEVICE_BGRA_SUPPORT.
    void StartCapture(HWND hwnd, ID3D11Device* device);

    /// Stop the capture session and release WinRT resources.
    /// Safe to call from any state (including Idle).
    void StopCapture() noexcept;

    /// Reset to Idle after Error or DeviceLost.
    void Reset() noexcept;

    /// Try to retrieve the latest captured frame.
    /// Returns a CapturedFrame with texture==nullptr if no new frame available.
    /// The texture is a copy from the capture frame; caller owns it.
    [[nodiscard]] CapturedFrame TryGetNextFrame();
    /// Get the current window being captured.
    /// (Reads m_hwnd without locking — callers should synchronize with
    ///  StartCapture/StopCapture if they need a precise value across threads.)
    [[nodiscard]] HWND GetTargetWindow() const noexcept { return m_hwnd; }
    [[nodiscard]] CaptureState GetState() const noexcept { return m_state.load(std::memory_order_acquire); }
    [[nodiscard]] std::uint64_t GetFrameCount() const noexcept { return m_frameCount.load(std::memory_order_acquire); }

private:
    using Direct3DCaptureFrame = winrt::Windows::Graphics::Capture::Direct3D11CaptureFrame;
    using FramePool = winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool;
    using CaptureSession = winrt::Windows::Graphics::Capture::GraphicsCaptureSession;
    using CaptureItem = winrt::Windows::Graphics::Capture::GraphicsCaptureItem;
    using SizeInt32 = winrt::Windows::Graphics::SizeInt32;

    void OnFrameArrived(FramePool const& sender, winrt::Windows::Foundation::IInspectable const&);
    void StopCaptureLocked() noexcept;
    void TransitionTo(CaptureState newState) noexcept;

    // WinRT objects
    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice m_winrtDevice{nullptr};
    FramePool m_framePool{nullptr};
    CaptureSession m_session{nullptr};
    CaptureItem m_captureItem{nullptr};

    // Event auto-revoker (unsubscribes automatically on destruction/revoke)
    winrt::event_revoker<winrt::Windows::Graphics::Capture::IDirect3D11CaptureFramePool> m_frameArrivedRevoker;

    // Native device and context for resource management
    Microsoft::WRL::ComPtr<ID3D11Device> m_device;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> m_context;

    // Window handle
    HWND m_hwnd{};

    // Mutex protecting all shared state (used by callback and consumer)
    std::recursive_mutex m_mutex;
    Direct3DCaptureFrame m_pendingFrame{nullptr};
    bool m_frameAvailable{false};

    // Track current pool size (CurrentSize not exposed in SDK 10.0.26100)
    SizeInt32 m_poolSize{};

    // State
    std::atomic<CaptureState> m_state{CaptureState::Idle};
    std::atomic<std::uint64_t> m_frameCount{0};
};

} // namespace SolStream::Capture
