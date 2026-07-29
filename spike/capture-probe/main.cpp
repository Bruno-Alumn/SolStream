// capture-probe — does WGC see a swap chain? Window capture and display capture,
// on the same window, one after the other.
//
// spike/swapchain presents through a flip-model swap chain at 9,000 fps, its
// window reports itself visible at 2560,0 1800x1169, and SolStream's DISPLAY
// capture of the monitor it sits on shows bare wallpaper there. That is the
// "Windows Terminal is a black rectangle" symptom, and it disqualifies display
// capture for browsers, terminals and games if it holds generally.
//
// So: capture the WINDOW, then capture the MONITOR, and count how many DISTINCT
// pixel values each one saw at the centre. A capture that is working sees many
// (the shader is moving); one that is missing the swap chain sees one.
//
// Frame counts alone would not tell them apart. WGC delivers frames for a window
// whose content it cannot see, and they are all identical -- which is exactly how
// this looks like "capture works" until somebody looks at the picture.
//
//   capture-probe.exe <window title substring> [seconds]

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <d3d11.h>
#include <dxgi.h>
#include <windows.h>

#include <atomic>
#include <cstdio>
#include <mutex>
#include <set>
#include <string>

#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace {

struct Found {
    std::wstring needle;
    HWND window = nullptr;
};

BOOL CALLBACK FindByTitle(HWND window, LPARAM param) {
    auto* found = reinterpret_cast<Found*>(param);
    if (!IsWindowVisible(window)) {
        return TRUE;
    }
    wchar_t title[512] = {};
    GetWindowTextW(window, title, 512);
    if (title[0] && wcsstr(title, found->needle.c_str())) {
        found->window = window;
        return FALSE;
    }
    return TRUE;
}

/// One capture run: attach, watch, and report how much of what it saw changed.
struct Probe {
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11DeviceContext> context;
    com_ptr<ID3D11Texture2D> staging;
    IDirect3DDevice winrtDevice{nullptr};

    std::mutex lock;
    std::set<uint32_t> distinct;
    std::atomic<int> frames{0};

    bool Prepare() {
        D3D_FEATURE_LEVEL level{};
        if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                     D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                     D3D11_SDK_VERSION, device.put(), &level,
                                     context.put()))) {
            return false;
        }
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = 1;
        desc.Height = 1;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        if (FAILED(device->CreateTexture2D(&desc, nullptr, staging.put()))) {
            return false;
        }
        auto dxgi = device.as<IDXGIDevice>();
        com_ptr<::IInspectable> inspectable;
        if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()))) {
            return false;
        }
        winrtDevice = inspectable.as<IDirect3DDevice>();
        return true;
    }

    void Sample(const com_ptr<ID3D11Texture2D>& surface) {
        D3D11_TEXTURE2D_DESC desc{};
        surface->GetDesc(&desc);
        // The centre. A pixel near the edge is in the window frame, or in
        // Windows 11's rounded corner, and never in the content.
        const UINT cx = desc.Width / 2;
        const UINT cy = desc.Height / 2;
        D3D11_BOX box{cx, cy, 0, cx + 1, cy + 1, 1};
        context->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, surface.get(), 0, &box);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
            return;
        }
        const unsigned char* bgra = (const unsigned char*) mapped.pData;
        const uint32_t value = ((uint32_t) bgra[0] << 16) | ((uint32_t) bgra[1] << 8)
                             | (uint32_t) bgra[2];
        {
            std::lock_guard<std::mutex> guard(lock);
            distinct.insert(value);
        }
        context->Unmap(staging.get(), 0);
    }

    void Run(GraphicsCaptureItem item, int seconds, const char* label) {
        distinct.clear();
        frames.store(0);
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            winrtDevice, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, item.Size());
        auto session = pool.CreateCaptureSession(item);
        try { session.IsBorderRequired(false); } catch (hresult_error const&) {}
        try { session.IsCursorCaptureEnabled(false); } catch (hresult_error const&) {}

        auto token = pool.FrameArrived([this](Direct3D11CaptureFramePool const& sender, auto&&) {
            auto frame = sender.TryGetNextFrame();
            if (!frame) { return; }
            auto access = frame.Surface().as<
                ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            com_ptr<ID3D11Texture2D> texture;
            if (SUCCEEDED(access->GetInterface(guid_of<ID3D11Texture2D>(),
                                               texture.put_void()))) {
                Sample(texture);
            }
            frames.fetch_add(1);
            frame.Close();
        });

        session.StartCapture();
        Sleep((DWORD) seconds * 1000);
        pool.FrameArrived(token);
        session.Close();
        pool.Close();

        std::lock_guard<std::mutex> guard(lock);
        std::printf("  %-18s %4d frames, %3zu distinct centre pixels  -> %s\n",
                    label, frames.load(), distinct.size(),
                    distinct.size() > 4 ? "SEES THE CONTENT"
                                        : "BLIND (one frozen value)");
    }
};

/// Per-monitor DPI aware, v2, or every coordinate here is a lie.
///
/// `SetProcessDPIAware` makes a process SYSTEM-DPI-aware, which means Windows
/// virtualises its coordinates on any monitor whose scale factor differs from
/// the primary's. This spike asked for a window at 2560,0 -- the left edge of
/// the virtual display -- and got one on the primary monitor instead, which is
/// why SolStream's capture of the virtual display showed bare wallpaper where
/// the window was supposed to be. Nothing failed; the window was simply
/// somewhere else, and both halves reported their own truth.
void MakeDpiAware() {
    // Declared by hand rather than by raising the SDK's WINVER: this is the
    // v2 context, which is what makes a coordinate a real pixel.
    using SetContext = BOOL(WINAPI*)(HANDLE);
    if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
        if (auto set = (SetContext) GetProcAddress(user32,
                                                   "SetProcessDpiAwarenessContext")) {
            if (set((HANDLE) -4)) {   // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
                return;
            }
        }
    }
    SetProcessDPIAware();
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 2) {
        std::printf("usage: capture-probe <window title substring> [seconds]\n");
        return 2;
    }
    const int seconds = argc > 2 ? _wtoi(argv[2]) : 5;
    MakeDpiAware();
    init_apartment(apartment_type::multi_threaded);

    Found found{argv[1], nullptr};
    EnumWindows(FindByTitle, reinterpret_cast<LPARAM>(&found));
    if (!found.window) {
        std::printf("no visible window matching \"%ls\"\n", argv[1]);
        return 1;
    }
    RECT rect{};
    GetWindowRect(found.window, &rect);
    HMONITOR monitor = MonitorFromWindow(found.window, MONITOR_DEFAULTTONEAREST);
    MONITORINFOEXW info{};
    info.cbSize = sizeof(info);
    GetMonitorInfoW(monitor, &info);
    std::printf("window \"%ls\" at %ld,%ld %ldx%ld on %ls\n\n", argv[1],
                rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
                info.szDevice);

    Probe probe;
    if (!probe.Prepare()) {
        std::printf("no D3D11 device\n");
        return 1;
    }
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();

    GraphicsCaptureItem windowItem{nullptr};
    if (SUCCEEDED(interop->CreateForWindow(found.window, guid_of<GraphicsCaptureItem>(),
                                           put_abi(windowItem)))
        && windowItem) {
        probe.Run(windowItem, seconds, "window capture");
    } else {
        std::printf("  window capture     could not create an item\n");
    }

    GraphicsCaptureItem monitorItem{nullptr};
    if (SUCCEEDED(interop->CreateForMonitor(monitor, guid_of<GraphicsCaptureItem>(),
                                            put_abi(monitorItem)))
        && monitorItem) {
        probe.Run(monitorItem, seconds, "display capture");
    } else {
        std::printf("  display capture    could not create an item\n");
    }
    return 0;
}
