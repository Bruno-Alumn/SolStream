#include "capture.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <dxgi.h>

#include <atomic>
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
    /// The item going away: the captured window closed, or the monitor was
    /// disconnected. WGC says so through this event and in no other way -- the
    /// frames simply stop -- so without it a closed window looked exactly like
    /// a still one, and the retained frame was re-encoded for the rest of the
    /// session.
    GraphicsCaptureItem::Closed_revoker itemClosedEvent;
    /// Set by that handler, and owned jointly with it. revoke() unhooks the
    /// handler but does not wait for an invocation already under way, so the
    /// handler touches nothing of Impl's -- only this flag, which its own copy
    /// of the pointer keeps alive however late it runs.
    std::shared_ptr<std::atomic<bool>> itemClosed =
        std::make_shared<std::atomic<bool>>(false);

    /// The retained frame. One texture, copied into on every arrival, so the
    /// WGC frame can be closed immediately -- the frame pool has two buffers and
    /// holding one across an encode would stall capture at 30 fps.
    com_ptr<ID3D11Texture2D> retained;
    UINT width = 0, height = 0;

    /// The size the frame pool's textures were created at, and the size the
    /// arrivals say the source has actually become. WGC does not resize the
    /// pool's surfaces by itself, so these two disagreeing is what says the pool
    /// has to be built again.
    UINT poolWidth = 0, poolHeight = 0;
    UINT pendingWidth = 0, pendingHeight = 0;
    bool poolStale = false;

    std::mutex lock;
    /// Held by OnFrame for the whole of its body, and taken by Stop and by
    /// RecreatePoolIfNeeded. See Stop for what goes wrong without it. It is
    /// always taken BEFORE `lock`.
    std::mutex callback;
    std::condition_variable arrived;
    uint64_t serial = 0;
    long long capturedAt = 0;
    uint64_t delivered = 0;
    /// Atomic because the readers do not agree on a mutex: OnFrame and Stop go
    /// through `callback`, Acquire's wait predicate goes through `lock`, and
    /// Running() holds neither. As a plain bool that was a data race whatever
    /// the mutexes did. The atomic makes the reads defined; it is still cleared
    /// with `callback` held, and that -- not the atomic -- is what makes Stop
    /// wait for an arrival that is already running.
    std::atomic<bool> running{false};

    bool Begin(GraphicsCaptureItem newItem);
    void OnFrame(Direct3D11CaptureFramePool const& sender);
    void RecreatePoolIfNeeded();
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
    itemClosed->store(false);
    itemClosedEvent = item.Closed(auto_revoke,
        [closed = itemClosed](GraphicsCaptureItem const&, auto&&) {
            closed->store(true);
        });

    width = (UINT) size.Width;
    height = (UINT) size.Height;
    poolWidth = (UINT) size.Width;
    poolHeight = (UINT) size.Height;
    running.store(true);
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
    if (!running.load()) {
        return;
    }
    auto frame = sender.TryGetNextFrame();
    if (!frame) {
        return;
    }
    const long long at = Now();
    // The frame pool's textures stay the size the pool was created at; WGC does
    // not grow or shrink them because the source changed. ContentSize is where
    // the real picture ends, and the pool has to be recreated to make the two
    // agree again -- which is NOT done here. See RecreatePoolIfNeeded: doing it
    // on this thread is what crashed the agent, with an access violation inside
    // ntdll and four "the encoder would not produce output (0x8000FFFF)" lines
    // in front of it, because Recreate frees the very surfaces this callback is
    // being dispatched over. So this arrival is served from the part of the
    // surface both sizes have in common -- on a shrink that is the content, and
    // the stale band the source used to occupy is left out rather than streamed
    // as a border -- and the consumer thread rebuilds the pool between frames.
    const auto content = frame.ContentSize();
    auto access = frame.Surface().as<
        ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    com_ptr<ID3D11Texture2D> texture;
    if (content.Width > 0 && content.Height > 0
        && SUCCEEDED(access->GetInterface(guid_of<ID3D11Texture2D>(),
                                          texture.put_void()))) {
        D3D11_TEXTURE2D_DESC desc{};
        texture->GetDesc(&desc);
        const UINT usableWidth =
            (UINT) content.Width < desc.Width ? (UINT) content.Width : desc.Width;
        const UINT usableHeight =
            (UINT) content.Height < desc.Height ? (UINT) content.Height : desc.Height;
        std::lock_guard<std::mutex> guard(lock);
        if (!retained || usableWidth != width || usableHeight != height) {
            retained = nullptr;
            D3D11_TEXTURE2D_DESC mine{};
            mine.Width = usableWidth;
            mine.Height = usableHeight;
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
            width = usableWidth;
            height = usableHeight;
        }
        // A region rather than the whole resource, because the surface is only
        // the same size as the retained texture while nothing is resizing.
        const D3D11_BOX box{0, 0, 0, usableWidth, usableHeight, 1};
        context->CopySubresourceRegion(retained.get(), 0, 0, 0, 0, texture.get(), 0,
                                       &box);
        // Flush, or the copy sits in the deferred queue and the encoder is
        // handed a texture whose contents have not been written yet -- which
        // shows up as one frame of lag that no timestamp explains.
        context->Flush();
        ++serial;
        ++delivered;
        capturedAt = at;
        if ((UINT) content.Width != poolWidth || (UINT) content.Height != poolHeight) {
            pendingWidth = (UINT) content.Width;
            pendingHeight = (UINT) content.Height;
            poolStale = true;
        }
    }
    frame.Close();
    arrived.notify_all();
}

/// Rebuild the frame pool at the size the source has actually become.
///
/// ON THE CONSUMER'S THREAD, NEVER ON THE CALLBACK'S. Recreate tears down and
/// reallocates the surfaces the pool owns, and the frame-arrived handler is
/// dispatched over exactly those -- so calling it from inside OnFrame is a
/// use-after-free inside WGC's own thread pool. It presents as an access
/// violation in ntdll with the last log lines being ordinary encoder failures,
/// which is as far from the cause as a report can get. A C++ `catch` does not
/// help: an access violation is not a C++ exception.
///
/// `callback` is taken first and held across the Recreate, which is what makes
/// "no arrival is inside the pool" true rather than likely: OnFrame holds it for
/// its whole body. The lock order is the same as everywhere else -- `callback`
/// before `lock` -- and `lock` is released before `callback` is taken.
void Capture::Impl::RecreatePoolIfNeeded() {
    UINT wantWidth = 0, wantHeight = 0;
    {
        std::lock_guard<std::mutex> guard(lock);
        if (!poolStale) {
            return;
        }
        wantWidth = pendingWidth;
        wantHeight = pendingHeight;
    }
    std::lock_guard<std::mutex> alive(callback);
    if (!running.load() || !pool) {
        return;
    }
    try {
        pool.Recreate(winrtDevice, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2,
                      {(int32_t) wantWidth, (int32_t) wantHeight});
    } catch (hresult_error const&) {
        // Left stale on purpose, so the next pass tries again rather than
        // capturing at the old size for the rest of the session.
        return;
    }
    std::lock_guard<std::mutex> guard(lock);
    poolWidth = wantWidth;
    poolHeight = wantHeight;
    // Only if nothing has moved again while the pool was being rebuilt.
    if (pendingWidth == wantWidth && pendingHeight == wantHeight) {
        poolStale = false;
    }
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
    if (!impl_ || !impl_->running.load()) {
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
        impl_->running.store(false);
    }
    impl_->frameArrived.revoke();
    impl_->itemClosedEvent.revoke();
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

bool Capture::Running() const {
    return impl_ && impl_->running.load() && !impl_->itemClosed->load();
}

ID3D11Device* Capture::Device() const { return impl_ ? impl_->device.get() : nullptr; }

uint64_t Capture::Delivered() const {
    if (!impl_) { return 0; }
    std::lock_guard<std::mutex> guard(impl_->lock);
    return impl_->delivered;
}

bool Capture::Acquire(Frame& out, uint64_t sinceSerial, int timeoutMs) {
    if (!impl_) { return false; }
    // Between frames, which is the only safe place for it. The pool was created
    // once from the item's size, so a source resized after StartCapture went on
    // being captured at its original size for the rest of the session.
    impl_->RecreatePoolIfNeeded();
    std::unique_lock<std::mutex> guard(impl_->lock);
    if (impl_->serial <= sinceSerial) {
        impl_->arrived.wait_for(guard, std::chrono::milliseconds(timeoutMs),
                                [&] {
                                    return impl_->serial > sinceSerial
                                           || !impl_->running.load();
                                });
    }
    if (!impl_->retained) {
        return false;
    }
    // Taken while `lock` is still held, so the arrival that swaps the retained
    // texture out cannot get between reading the pointer and referencing it.
    // The reference travels with the frame: see Frame::hold for what happened
    // when the caller was handed the bare pointer instead.
    ID3D11Texture2D* const texture = impl_->retained.get();
    texture->AddRef();
    out.hold = std::shared_ptr<ID3D11Texture2D>(
        texture, [](ID3D11Texture2D* released) { released->Release(); });
    out.texture = texture;
    out.width = impl_->width;
    out.height = impl_->height;
    out.serial = impl_->serial;
    out.capturedAt = impl_->capturedAt;
    out.isNew = impl_->serial > sinceSerial;
    return true;
}

}  // namespace solstream::media
