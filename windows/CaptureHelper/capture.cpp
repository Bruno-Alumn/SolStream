#include "capture.h"

#include <winrt/Windows.Foundation.Metadata.h>

#include <cmath>
#include <format>
#include <mutex>
#include <string>

namespace winrt {
    using namespace Windows::Foundation;
    using namespace Windows::Graphics::Capture;
    using namespace Windows::Graphics::DirectX;
    using namespace Windows::Graphics::DirectX::Direct3D11;
    using namespace Windows::System;
}

namespace SolStream::Capture {

// ══════════════════════════════════════════════════════════════════════════════
// Constants
// ══════════════════════════════════════════════════════════════════════════════

static constexpr std::uint32_t kFramePoolBufferCount = 2;

// ══════════════════════════════════════════════════════════════════════════════
// CaptureException
// ══════════════════════════════════════════════════════════════════════════════

CaptureException::CaptureException(std::string_view msg, HRESULT hr)
    : std::runtime_error(
          std::format("{} [HRESULT=0x{:08X}]", msg,
                      static_cast<std::uint32_t>(hr))),
      m_hresult(hr) {}

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

WindowCapture::WindowCapture() = default;

WindowCapture::~WindowCapture() {
    StopCapture();
}

// ══════════════════════════════════════════════════════════════════════════════
// Start / Stop / Reset
// ══════════════════════════════════════════════════════════════════════════════

void WindowCapture::StartCapture(HWND hwnd, ID3D11Device* device) {
    std::lock_guard lock(m_mutex);

    if (m_state.load(std::memory_order_acquire) != CaptureState::Idle)
        throw CaptureException("StartCapture: already active.", E_UNEXPECTED);

    try {
        if (!hwnd || !IsWindow(hwnd))
            throw CaptureException("StartCapture: invalid HWND.", E_INVALIDARG);
        if (!device)
            throw CaptureException("StartCapture: null device.", E_INVALIDARG);

        if (!winrt::GraphicsCaptureSession::IsSupported())
            throw CaptureException("StartCapture: Graphics Capture not supported.",
                                   DXGI_ERROR_UNSUPPORTED);

        m_hwnd   = hwnd;
        m_device = device;

        // Get the immediate context for texture copy.
        Microsoft::WRL::ComPtr<ID3D11DeviceContext> ctx;
        device->GetImmediateContext(&ctx);
        if (!ctx)
            throw CaptureException("StartCapture: GetImmediateContext failed.", E_FAIL);
        m_context = std::move(ctx);

        // Convert D3D11 device → WinRT IDirect3DDevice.
        auto dxgiDevice = Microsoft::WRL::ComPtr<IDXGIDevice>{};
        winrt::check_hresult(
            device->QueryInterface(IID_PPV_ARGS(&dxgiDevice)));
        auto inspectable = winrt::capture<winrt::Windows::Foundation::IInspectable>(
            &CreateDirect3D11DeviceFromDXGIDevice, dxgiDevice.Get());
        m_winrtDevice = inspectable.as<winrt::IDirect3DDevice>();

        // Capture item from HWND via interop.
        auto factory = winrt::get_activation_factory<winrt::GraphicsCaptureItem>();
        auto interopFactory = factory.as<::IGraphicsCaptureItemInterop>();
        winrt::GraphicsCaptureItem item = {nullptr};
        winrt::check_hresult(interopFactory->CreateForWindow(
            hwnd,
            winrt::guid_of<winrt::GraphicsCaptureItem>(),
            reinterpret_cast<void**>(winrt::put_abi(item))));
        m_captureItem = std::move(item);

        // Get initial window size.
        RECT clientRect{};
        if (!GetClientRect(hwnd, &clientRect))
            throw CaptureException("StartCapture: GetClientRect failed.", HRESULT_FROM_WIN32(GetLastError()));
        auto width  = static_cast<int32_t>(clientRect.right - clientRect.left);
        auto height = static_cast<int32_t>(clientRect.bottom - clientRect.top);
        if (width <= 0 || height <= 0)
            throw CaptureException("StartCapture: window has zero size.", E_INVALIDARG);

        // Create the frame pool.
        m_framePool = winrt::Direct3D11CaptureFramePool::CreateFreeThreaded(
            m_winrtDevice,
            winrt::DirectXPixelFormat::B8G8R8A8UIntNormalized,
            kFramePoolBufferCount,
            {width, height});
        m_poolSize = {width, height};

        // Register the frame-arrived event with an auto-revoker.
        m_frameArrivedRevoker = m_framePool.FrameArrived(
            winrt::auto_revoke,
            {this, &WindowCapture::OnFrameArrived});

        // Create and start the capture session.
        m_session = m_framePool.CreateCaptureSession(m_captureItem);
        m_session.IsBorderRequired(false);
        m_session.StartCapture();

        m_frameCount.store(0, std::memory_order_relaxed);
        TransitionTo(CaptureState::Capturing);

    } catch (winrt::hresult_error const& e) {
        StopCaptureLocked();
        throw CaptureException("StartCapture: WinRT error.", e.code().value);
    } catch (...) {
        StopCaptureLocked();
        throw;
    }
}

void WindowCapture::StopCapture() noexcept {
    std::lock_guard lock(m_mutex);
    StopCaptureLocked();
}

void WindowCapture::Reset() noexcept {
    std::lock_guard lock(m_mutex);
    StopCaptureLocked();
    // Reset leaves state Idle (done by StopCaptureLocked).
}

// ══════════════════════════════════════════════════════════════════════════════
// Frame retrieval
// ══════════════════════════════════════════════════════════════════════════════

CapturedFrame WindowCapture::TryGetNextFrame() {
    std::lock_guard lock(m_mutex);

    if (m_state.load(std::memory_order_acquire) != CaptureState::Capturing)
        return {};

    if (!m_frameAvailable)
        return {};

    try {
        // Take the pending frame.
        auto frame = std::move(m_pendingFrame);
        m_pendingFrame = nullptr;
        m_frameAvailable = false;

        // Extract the native D3D texture from the WinRT surface.
        auto surface = frame.Surface();
        auto dxgiSurface = surface.as<IDXGISurface>();
        Microsoft::WRL::ComPtr<ID3D11Texture2D> capturedTexture;
        winrt::check_hresult(
            dxgiSurface->QueryInterface(IID_PPV_ARGS(&capturedTexture)));

        // Describe the source and create a compatible destination.
        D3D11_TEXTURE2D_DESC srcDesc{};
        capturedTexture->GetDesc(&srcDesc);
        srcDesc.BindFlags      = 0;
        srcDesc.MiscFlags      = 0;
        srcDesc.CPUAccessFlags = 0;
        srcDesc.Usage          = D3D11_USAGE_DEFAULT;

        Microsoft::WRL::ComPtr<ID3D11Texture2D> copyTexture;
        winrt::check_hresult(
            m_device->CreateTexture2D(&srcDesc, nullptr, &copyTexture));

        m_context->CopyResource(copyTexture.Get(), capturedTexture.Get());
        m_context->Flush();

        auto index = m_frameCount.fetch_add(1, std::memory_order_relaxed);
        return CapturedFrame{std::move(copyTexture), index,
                             std::chrono::steady_clock::now()};
    } catch (winrt::hresult_error const&) {
        TransitionTo(CaptureState::Error);
        return {};
    } catch (std::exception const&) {
        TransitionTo(CaptureState::Error);
        return {};
    } catch (...) {
        TransitionTo(CaptureState::Error);
        return {};
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Frame arrival callback (runs on thread-pool thread)
// ══════════════════════════════════════════════════════════════════════════════

void WindowCapture::OnFrameArrived(
    FramePool const& sender,
    winrt::Windows::Foundation::IInspectable const&)
try {
    std::lock_guard lock(m_mutex);

    if (m_state.load(std::memory_order_acquire) != CaptureState::Capturing)
        return;

    // Drain all available frames (keep only the latest).
    bool gotFrame = false;
    while (auto frame = sender.TryGetNextFrame()) {
        // Check for window resize — validate content size.
        auto contentSize = frame.ContentSize();
        if (contentSize.Width <= 0 || contentSize.Height <= 0)
            continue;
        auto poolSize = m_poolSize;
        if (contentSize.Width != poolSize.Width ||
            contentSize.Height != poolSize.Height) {
            // Window resized — recreate the frame pool.
            m_pendingFrame = nullptr;
            m_frameAvailable = false;
            gotFrame = false;
            auto pixelFormat = winrt::DirectXPixelFormat::B8G8R8A8UIntNormalized;
            sender.Recreate(m_winrtDevice, pixelFormat, kFramePoolBufferCount, {contentSize.Width, contentSize.Height});
            m_poolSize = {contentSize.Width, contentSize.Height};
            // Drop this frame (was from the old-size pool).
            continue;
        }
        // Store the latest frame.
        m_pendingFrame = std::move(frame);
        gotFrame = true;
    }
    // Keep m_frameAvailable true even if no new frame arrived in this
    // callback, as long as a prior frame is still unconsumed.
    if (gotFrame || m_pendingFrame)
        m_frameAvailable = true;

} catch (winrt::hresult_error const& e) {
    std::lock_guard lock(m_mutex);
    if (e.code().value == DXGI_ERROR_DEVICE_REMOVED ||
        e.code().value == DXGI_ERROR_DEVICE_RESET) {
        TransitionTo(CaptureState::DeviceLost);
    } else {
        TransitionTo(CaptureState::Error);
    }
} catch (...) {
    std::lock_guard lock(m_mutex);
    TransitionTo(CaptureState::Error);
}

// ══════════════════════════════════════════════════════════════════════════════
// Internal helpers
// ══════════════════════════════════════════════════════════════════════════════

void WindowCapture::StopCaptureLocked() noexcept {
    // Unsubscribe from events (revoker auto-disconnects).
    m_frameArrivedRevoker.revoke();

    // Close session and pool.
    if (m_session) {
        try { m_session.Close(); } catch (...) {}
        m_session = nullptr;
    }
    if (m_framePool) {
        try { m_framePool.Close(); } catch (...) {}
        m_framePool = nullptr;
    }

    // Clear any pending frame.
    m_pendingFrame = nullptr;
    m_frameAvailable = false;

    // Release WinRT and D3D11 objects.
    m_captureItem  = nullptr;
    m_winrtDevice  = nullptr;
    m_poolSize     = {};
    m_context.Reset();
    m_device.Reset();
    m_hwnd = {};

    TransitionTo(CaptureState::Idle);
}

void WindowCapture::TransitionTo(CaptureState newState) noexcept {
    m_state.store(newState, std::memory_order_release);
}

} // namespace SolStream::Capture
