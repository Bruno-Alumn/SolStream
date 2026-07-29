#include "capture.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <dxgi.h>

#include <chrono>
#include <condition_variable>
#include <mutex>

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace solstream::media {
namespace {

long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

}  // namespace

struct Capture::Impl {
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11DeviceContext> context;
    IDirect3DDevice winrtDevice{nullptr};

    GraphicsCaptureItem item{nullptr};
    Direct3D11CaptureFramePool pool{nullptr};
    GraphicsCaptureSession session{nullptr};
    Direct3D11CaptureFramePool::FrameArrived_revoker frameArrived;

    /// The retained frame. One texture, copied into on every arrival, so the
    /// WGC frame can be closed immediately -- the frame pool has two buffers and
    /// holding one across an encode would stall capture at 30 fps.
    com_ptr<ID3D11Texture2D> retained;
    UINT width = 0, height = 0;

    std::mutex lock;
    /// Held by OnFrame for the whole of its body, and taken by Stop. See Stop
    /// for what goes wrong without it. It is always taken BEFORE `lock`.
    std::mutex callback;
    std::condition_variable arrived;
    uint64_t serial = 0;
    long long capturedAt = 0;
    uint64_t delivered = 0;
    bool running = false;

    bool Begin(GraphicsCaptureItem newItem);
    void OnFrame(Direct3D11CaptureFramePool const& sender);
};

bool Capture::Impl::Begin(GraphicsCaptureItem newItem) {
    item = newItem;
    const auto size = item.Size();
    if (size.Width <= 0 || size.Height <= 0) {
        return false;
    }

    D3D_FEATURE_LEVEL level{};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT
                                       | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION,
                                   device.put(), &level, context.put());
    if (FAILED(hr)) {
        return false;
    }
    // The encoder runs on another thread against this same device. Without
    // multithread protection that is not merely racy in theory: it corrupts in
    // ways that present as encoder bugs, which is the worst place to look.
    {
        com_ptr<ID3D10Multithread> threading;
        if (SUCCEEDED(device->QueryInterface(__uuidof(ID3D10Multithread),
                                             threading.put_void()))) {
            threading->SetMultithreadProtected(TRUE);
        }
    }

    auto dxgi = device.as<IDXGIDevice>();
    com_ptr<::IInspectable> inspectable;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()))) {
        return false;
    }
    winrtDevice = inspectable.as<IDirect3DDevice>();

    pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrtDevice, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
    session = pool.CreateCaptureSession(item);

    // The yellow capture border. spike/wgc-capture measured this being honoured
    // from an unpackaged binary, contrary to what the capability documentation
    // implies; older builds throw instead, and a border is survivable.
    try {
        session.IsBorderRequired(false);
    } catch (hresult_error const&) {
    }
    try {
        session.IsCursorCaptureEnabled(false);
    } catch (hresult_error const&) {
    }

    frameArrived = pool.FrameArrived(auto_revoke,
        [this](Direct3D11CaptureFramePool const& sender, auto&&) { OnFrame(sender); });

    width = (UINT) size.Width;
    height = (UINT) size.Height;
    running = true;
    session.StartCapture();
    return true;
}

void Capture::Impl::OnFrame(Direct3D11CaptureFramePool const& sender) {
    // Taken for the whole body, including the device work below, so that Stop
    // can wait for an invocation that is already running instead of freeing the
    // device underneath it. `running` is read under the same mutex Stop clears
    // it under, so an arrival that gets in after Stop touches neither the device
    // nor the retained texture.
    std::lock_guard<std::mutex> alive(callback);
    if (!running) {
        return;
    }
    auto frame = sender.TryGetNextFrame();
    if (!frame) {
        return;
    }
    const long long at = Now();
    auto access = frame.Surface().as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    com_ptr<ID3D11Texture2D> texture;
    if (SUCCEEDED(access->GetInterface(guid_of<ID3D11Texture2D>(), texture.put_void()))) {
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        std::lock_guard<std::mutex> guard(lock);
        if (!retained || desc.Width != width || desc.Height != height) {
            retained = nullptr;
            D3D11_TEXTURE2D_DESC mine{};
            mine.Width = desc.Width;
            mine.Height = desc.Height;
            mine.MipLevels = 1;
            mine.ArraySize = 1;
            mine.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            mine.SampleDesc.Count = 1;
            mine.Usage = D3D11_USAGE_DEFAULT;
            mine.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
            if (FAILED(device->CreateTexture2D(&mine, nullptr, retained.put()))) {
                frame.Close();
                return;
            }
            width = desc.Width;
            height = desc.Height;
        }
        context->CopyResource(retained.get(), texture.get());
        // Flush, or the copy sits in the deferred queue and the encoder is
        // handed a texture whose contents have not been written yet -- which
        // shows up as one frame of lag that no timestamp explains.
        context->Flush();
        ++serial;
        ++delivered;
        capturedAt = at;
    }
    frame.Close();
    arrived.notify_all();
}

Capture::Capture() : impl_(std::make_unique<Impl>()) {}

Capture::~Capture() {
    Stop();
}

bool Capture::Supported() {
    try {
        return GraphicsCaptureSession::IsSupported();
    } catch (hresult_error const&) {
        return false;
    }
}

bool Capture::StartWindow(HWND window) {
    if (!window || !IsWindow(window)) {
        return false;
    }
    try {
        auto interop =
            get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{nullptr};
        if (FAILED(interop->CreateForWindow(window, guid_of<GraphicsCaptureItem>(),
                                            put_abi(item))) || !item) {
            return false;
        }
        return impl_->Begin(item);
    } catch (hresult_error const&) {
        return false;
    }
}

bool Capture::StartMonitor(HMONITOR monitor) {
    if (!monitor) {
        return false;
    }
    try {
        auto interop =
            get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{nullptr};
        if (FAILED(interop->CreateForMonitor(monitor, guid_of<GraphicsCaptureItem>(),
                                             put_abi(item))) || !item) {
            return false;
        }
        return impl_->Begin(item);
    } catch (hresult_error const&) {
        return false;
    }
}

void Capture::Stop() {
    if (!impl_ || !impl_->running) {
        return;
    }
    // The frame pool is created free-threaded, so OnFrame runs on a thread-pool
    // thread that this one knows nothing about, and revoke() only unhooks the
    // handler -- it does not wait for an invocation that has already started.
    // Clearing `running` under the mutex OnFrame holds for its whole body is
    // what waits: without it Stop went straight on to close the pool, and the
    // destructor that calls Stop then freed the device, the context and the
    // retained texture out from under a CopyResource still in progress.
    {
        std::lock_guard<std::mutex> alive(impl_->callback);
        impl_->running = false;
    }
    impl_->frameArrived.revoke();
    try {
        if (impl_->session) { impl_->session.Close(); }
        if (impl_->pool) { impl_->pool.Close(); }
    } catch (hresult_error const&) {
    }
    impl_->session = nullptr;
    impl_->pool = nullptr;
    impl_->item = nullptr;
    impl_->arrived.notify_all();
}

bool Capture::Running() const { return impl_ && impl_->running; }

ID3D11Device* Capture::Device() const { return impl_ ? impl_->device.get() : nullptr; }

uint64_t Capture::Delivered() const {
    if (!impl_) { return 0; }
    std::lock_guard<std::mutex> guard(impl_->lock);
    return impl_->delivered;
}

bool Capture::Acquire(Frame& out, uint64_t sinceSerial, int timeoutMs) {
    if (!impl_) { return false; }
    std::unique_lock<std::mutex> guard(impl_->lock);
    if (impl_->serial <= sinceSerial) {
        impl_->arrived.wait_for(guard, std::chrono::milliseconds(timeoutMs),
                                [&] { return impl_->serial > sinceSerial || !impl_->running; });
    }
    if (!impl_->retained) {
        return false;
    }
    out.texture = impl_->retained.get();
    out.width = impl_->width;
    out.height = impl_->height;
    out.serial = impl_->serial;
    out.capturedAt = impl_->capturedAt;
    out.isNew = impl_->serial > sinceSerial;
    return true;
}

}  // namespace solstream::media
