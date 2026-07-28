// wgc-capture — does Windows.Graphics.Capture make the virtual display driver
// unnecessary, and what does it cost in latency?
//
// SolStream captures a display and crops one window out of it. That is why
// there is a virtual display driver at all: on a real monitor the crop is a crop
// out of somebody's actual screen, so anything dragged over the application is
// streamed with it, the window cannot be larger than the monitor, and the mode
// has to be changed to match the Mac. The driver costs an install, a UAC prompt,
// a mode ladder, a DPI setting and the HDR trap that made content arrive black.
//
// WGC captures a WINDOW. If it works, all of that goes away — not by being
// handled better, but by not existing. So this program answers the four
// questions that decide it, and answers them with measurements rather than with
// documentation:
//
//   1. Can an unpackaged binary capture a single window at all?
//   2. Can it turn the yellow capture border off? The docs say IsBorderRequired
//      needs the graphicsCaptureWithoutBorder capability, which needs a package
//      manifest, which an unpackaged Win32 app does not have. If that is fatal
//      SolStream needs a sparse package, and it is better to know now.
//   3. What is the latency from the application finishing its drawing to us
//      holding its pixels?
//   4. Does capture survive occlusion — another window dragged over the top?
//      This is the property that makes the driver unnecessary; without it,
//      nothing else matters.
//
// It captures a window it creates itself, so it reads none of the user's screen,
// and that window paints a sequence number into its own top-left pixel. Reading
// that number back out of the captured frame is what makes the latency figure a
// measurement of a specific frame rather than an average of a pipeline.

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <d3d11.h>
#include <dxgi.h>
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <mutex>
#include <vector>

#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

namespace {

constexpr int kPaintCount = 240;      // frames to measure
constexpr int kPaintIntervalMs = 16;  // roughly 60Hz, the rate a real app draws at

LARGE_INTEGER g_frequency{};

double MillisSince(long long start) {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return (double) (now.QuadPart - start) * 1000.0 / (double) g_frequency.QuadPart;
}

long long Now() {
    LARGE_INTEGER now{};
    QueryPerformanceCounter(&now);
    return now.QuadPart;
}

// ── The window under test ────────────────────────────────────────────────────
//
// Paints a solid colour whose RED channel is the low byte of a sequence number
// and whose GREEN channel is the next byte. Sixteen bits is enough to run for
// eighteen minutes at 60Hz without wrapping, and a solid fill means the value
// survives whatever scaling or colour conversion the capture path applies.

std::atomic<int> g_sequence{0};
std::mutex g_paint_lock;
std::vector<long long> g_painted_at(65536, 0);

LRESULT CALLBACK TestWindowProc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_PAINT) {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(window, &paint);
        const int seq = g_sequence.load();
        RECT client{};
        GetClientRect(window, &client);
        HBRUSH brush = CreateSolidBrush(RGB(seq & 0xFF, (seq >> 8) & 0xFF, 0x40));
        FillRect(dc, &client, brush);
        DeleteObject(brush);
        EndPaint(window, &paint);
        return 0;
    }
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

HWND CreateTestWindow() {
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = TestWindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"SolStreamCaptureSpike";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassExW(&wc);
    HWND window = CreateWindowExW(0, L"SolStreamCaptureSpike",
                                  L"SolStream capture spike",
                                  WS_OVERLAPPEDWINDOW, 100, 100, 800, 600,
                                  nullptr, nullptr, wc.hInstance, nullptr);
    ShowWindow(window, SW_SHOW);
    UpdateWindow(window);
    return window;
}

// ── Reading one pixel back out of a captured frame ───────────────────────────
//
// A 1x1 staging copy rather than mapping the whole surface: the question is only
// "which paint is this", and copying a megabyte to answer it would put the
// measurement inside the thing being measured.

struct PixelReader {
    com_ptr<ID3D11Device> device;
    com_ptr<ID3D11DeviceContext> context;
    com_ptr<ID3D11Texture2D> staging;

    void Prepare() {
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width = 1;
        desc.Height = 1;
        desc.MipLevels = 1;
        desc.ArraySize = 1;
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1;
        desc.Usage = D3D11_USAGE_STAGING;
        desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        device->CreateTexture2D(&desc, nullptr, staging.put());
    }

    /// The sequence number painted into the frame, or -1.
    int Read(const com_ptr<ID3D11Texture2D>& surface) {
        // The CENTRE of the frame, not near a corner. WGC hands back the whole
        // window including its frame and, on Windows 11, its rounded corners --
        // so a pixel two in from the edge is in the shadow or the transparent
        // corner, never in the client area. Reading there is what produced "no
        // samples" on the first run, and it looked exactly like a capture
        // failure rather than like sampling the wrong pixel.
        D3D11_TEXTURE2D_DESC desc{};
        surface->GetDesc(&desc);
        const UINT cx = desc.Width / 2;
        const UINT cy = desc.Height / 2;
        D3D11_BOX box{cx, cy, 0, cx + 1, cy + 1, 1};
        context->CopySubresourceRegion(staging.get(), 0, 0, 0, 0, surface.get(), 0, &box);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (FAILED(context->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
            return -1;
        }
        const unsigned char* bgra = (const unsigned char*) mapped.pData;
        const int seq = bgra[2] | (bgra[1] << 8);   // R is [2], G is [1]
        // The first few, raw. A pairing that silently matches nothing is
        // indistinguishable from a capture that delivered nothing, and this
        // spike exists to tell those two apart.
        static std::atomic<int> shown{0};
        if (shown.fetch_add(1) < 5) {
            std::printf("    sample: B=%02X G=%02X R=%02X A=%02X -> seq %d\n",
                        bgra[0], bgra[1], bgra[2], bgra[3], seq);
        }
        context->Unmap(staging.get(), 0);
        return seq;
    }
};

struct Arrival {
    int sequence;
    double latencyMs;
};

std::mutex g_arrival_lock;
std::vector<Arrival> g_arrivals;
std::atomic<int> g_frames{0};
/// Set the moment the covering window goes up. Frames counted after it are the
/// answer to "does capture survive occlusion", and they are counted rather than
/// inferred from the latency samples -- deriving the verdict from those samples
/// is what made the first run report the opposite of what it had measured.
std::atomic<bool> g_covered{false};
std::atomic<int> g_frames_covered{0};

void Report(const char* label, std::vector<double> values) {
    if (values.empty()) {
        std::printf("  %-28s no samples\n", label);
        return;
    }
    std::sort(values.begin(), values.end());
    auto at = [&](double q) { return values[(size_t) (q * (values.size() - 1))]; };
    double sum = 0;
    for (double v : values) { sum += v; }
    std::printf("  %-28s n=%zu  min %.2f  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f  mean %.2f\n",
                label, values.size(), values.front(), at(0.50), at(0.95), at(0.99),
                values.back(), sum / (double) values.size());
}

}  // namespace

int wmain() {
    QueryPerformanceFrequency(&g_frequency);
    init_apartment(apartment_type::multi_threaded);

    std::printf("=== SolStream WGC capture spike ===\n\n");

    // 1. Is it even here?
    if (!GraphicsCaptureSession::IsSupported()) {
        std::printf("GraphicsCaptureSession::IsSupported() == false. WGC is not\n"
                    "available on this machine, so per-window capture is not an\n"
                    "option and the virtual display driver has to stay.\n");
        return 1;
    }
    std::printf("[1] WGC is supported.\n");

    HWND window = CreateTestWindow();
    if (!window) {
        std::printf("could not create the window under test\n");
        return 1;
    }

    // D3D11 device, and the WinRT wrapper the frame pool wants.
    com_ptr<ID3D11Device> d3d;
    com_ptr<ID3D11DeviceContext> context;
    D3D_FEATURE_LEVEL level{};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                   D3D11_SDK_VERSION, d3d.put(), &level, context.put());
    if (FAILED(hr)) {
        std::printf("no hardware D3D11 device (0x%08lX); retrying with WARP\n", hr);
        hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                               D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                               D3D11_SDK_VERSION, d3d.put(), &level, context.put());
    }
    if (FAILED(hr)) {
        std::printf("no D3D11 device at all (0x%08lX)\n", hr);
        return 1;
    }
    auto dxgi = d3d.as<IDXGIDevice>();
    com_ptr<::IInspectable> inspectable;
    check_hresult(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), inspectable.put()));
    auto winrtDevice = inspectable.as<IDirect3DDevice>();

    // 2. A capture item for OUR window. This is the whole question: an item made
    //    from an HWND rather than from a monitor.
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    hr = interop->CreateForWindow(window, guid_of<GraphicsCaptureItem>(), put_abi(item));
    if (FAILED(hr) || !item) {
        std::printf("[2] CreateForWindow FAILED (0x%08lX) -- per-window capture is out\n", hr);
        return 1;
    }
    std::printf("[2] Per-window capture item created: %dx%d\n",
                item.Size().Width, item.Size().Height);

    // 3. The border. RequestAccessAsync(Borderless) is documented to need the
    //    graphicsCaptureWithoutBorder capability from a package manifest, which
    //    an unpackaged binary has none of. Ask anyway and report what actually
    //    happens, because "documented to need" and "refuses without" are not the
    //    same claim and only one of them is testable.
    bool borderlessGranted = false;
    try {
        auto status = GraphicsCaptureAccess::RequestAccessAsync(
            GraphicsCaptureAccessKind::Borderless).get();
        borderlessGranted = status == winrt::Windows::Security::Authorization::AppCapabilityAccess::
                                          AppCapabilityAccessStatus::Allowed;
        std::printf("[3] RequestAccessAsync(Borderless) -> %d (%s)\n", (int) status,
                    borderlessGranted ? "ALLOWED" : "not allowed");
    } catch (hresult_error const& e) {
        std::printf("[3] RequestAccessAsync(Borderless) threw 0x%08X: %ls\n",
                    (unsigned) e.code(), e.message().c_str());
    }

    auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        winrtDevice, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, item.Size());
    auto session = pool.CreateCaptureSession(item);

    bool borderTurnedOff = false;
    try {
        session.IsBorderRequired(false);
        borderTurnedOff = !session.IsBorderRequired();
        std::printf("[3] IsBorderRequired(false) accepted; reads back as %s\n",
                    session.IsBorderRequired() ? "TRUE (ignored)" : "false (honoured)");
    } catch (hresult_error const& e) {
        std::printf("[3] IsBorderRequired(false) threw 0x%08X: %ls\n",
                    (unsigned) e.code(), e.message().c_str());
    }

    PixelReader reader{d3d, context, {}};
    reader.Prepare();

    pool.FrameArrived([&reader](Direct3D11CaptureFramePool const& sender, auto&&) {
        auto frame = sender.TryGetNextFrame();
        if (!frame) {
            return;
        }
        const long long arrived = Now();
        auto access = frame.Surface().as<
            ::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        com_ptr<ID3D11Texture2D> texture;
        if (SUCCEEDED(access->GetInterface(guid_of<ID3D11Texture2D>(), texture.put_void()))) {
            const int seq = reader.Read(texture);
            if (seq >= 0) {
                std::lock_guard<std::mutex> lock(g_arrival_lock);
                const long long painted = g_painted_at[(size_t) (seq & 0xFFFF)];
                if (painted != 0) {
                    g_arrivals.push_back({seq, MillisSince(painted)});
                }
            }
        }
        g_frames.fetch_add(1);
        if (g_covered.load()) {
            g_frames_covered.fetch_add(1);
        }
        frame.Close();
    });

    session.StartCapture();
    std::printf("[4] Capture started. Painting %d frames at ~%dms...\n\n",
                kPaintCount, kPaintIntervalMs);

    // 4. Paint, and record exactly when each paint finished. UpdateWindow is
    //    synchronous, so when it returns the application has done its drawing --
    //    which is the moment a streaming host would like the pixels.
    for (int i = 1; i <= kPaintCount; ++i) {
        g_sequence.store(i);
        {
            std::lock_guard<std::mutex> lock(g_arrival_lock);
            g_painted_at[(size_t) (i & 0xFFFF)] = Now();
        }
        InvalidateRect(window, nullptr, FALSE);
        UpdateWindow(window);

        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        // Halfway through, cover the window completely with a topmost window and
        // leave it there. If frames stop, WGC cannot replace the display driver,
        // because the whole point is that what is on top does not matter.
        if (i == kPaintCount / 2) {
            HWND cover = CreateWindowExW(WS_EX_TOPMOST, L"STATIC", L"cover",
                                          WS_POPUP | WS_VISIBLE, 80, 80, 900, 700,
                                          nullptr, nullptr, GetModuleHandleW(nullptr),
                                          nullptr);
            std::printf("    ...window fully covered at frame %d (occlusion test)\n", i);
            g_covered.store(true);
            (void) cover;
        }
        Sleep(kPaintIntervalMs);
    }

    Sleep(200);
    session.Close();
    pool.Close();

    std::vector<double> early, late;
    {
        std::lock_guard<std::mutex> lock(g_arrival_lock);
        for (const Arrival& a : g_arrivals) {
            (a.sequence <= kPaintCount / 2 ? early : late).push_back(a.latencyMs);
        }
    }

    std::printf("\n=== results ===\n");
    std::printf("  frames delivered            %d for %d paints\n",
                g_frames.load(), kPaintCount);
    std::printf("  frames while fully covered  %d\n", g_frames_covered.load());
    Report("paint -> pixels, unoccluded", early);
    Report("paint -> pixels, OCCLUDED", late);

    std::printf("\n=== verdict ===\n");
    std::printf("  per-window capture          %s\n", "YES (item created, see above)");
    std::printf("  survives occlusion          %s\n",
                g_frames_covered.load() > 10
                    ? "YES -- the display driver is unnecessary"
                    : "NO -- frames stopped when covered");
    std::printf("  borderless from unpackaged  %s\n",
                borderTurnedOff ? "YES" : "NO -- needs package identity, or accept the border");
    std::printf("  borderless access granted   %s\n", borderlessGranted ? "yes" : "no");
    return 0;
}
