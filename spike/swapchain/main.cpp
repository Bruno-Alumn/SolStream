// swapchain — content drawn on the GPU, fast enough to find the ceiling.
//
// Answers two questions at once, both of which have been open since the capture
// path was chosen.
//
//   1. WHAT IS THE PIPELINE'S REAL FRAME RATE? Every figure so far has been
//      bounded by what the test content could be DRAWN at, not by what the path
//      could carry: a still desktop gives ~17 fps because that is how much
//      changed, and spike/animate gave 33.6 because a scalar 8 MB fill per frame
//      is what GDI could manage. Neither has ever asked the chain for 60. A hard
//      ceiling below 60 would be invisible in both.
//
//   2. DOES WINDOWS.GRAPHICS.CAPTURE SEE SWAP-CHAIN CONTENT? The old display
//      capture rendered Windows Terminal as a solid black rectangle with its
//      chrome drawn correctly around it — the classic symptom of a capture that
//      composites the window's GDI surface and misses what DirectX presented
//      into it. Terminals and browsers are the applications worth streaming, so
//      "black rectangle" would be disqualifying. This window presents through a
//      flip-model swap chain, exactly as they do.
//
// The content is a pixel shader rather than a flat colour on purpose: a
// full-screen clear compresses to almost nothing, so an encoder fed one is not
// being asked for anything and its frame rate says nothing.
//
//   swapchain.exe <seconds> [x] [y] [width] [height]

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3dcompiler.h>

#include <cstdio>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

namespace {

// A full-screen triangle from the vertex id alone: no vertex buffer, no input
// layout, nothing to get wrong between the two.
const char* kShaders = R"(
cbuffer Frame : register(b0) { float time; float3 pad; };

struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };

VSOut vs(uint id : SV_VertexID) {
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}

// Detailed and moving, so the encoder has real work. A flat colour would make
// this a measurement of how fast nothing can be encoded.
float4 ps(VSOut i) : SV_TARGET {
    float2 p = i.uv * 40.0;
    float a = sin(p.x + time * 3.0) * cos(p.y - time * 2.0);
    float b = sin((p.x + p.y) * 0.7 + time * 5.0);
    float c = frac(sin(dot(floor(p), float2(12.9898, 78.233))) * 43758.5453);
    return float4(0.5 + 0.5 * a, 0.5 + 0.5 * b, c, 1.0);
}
)";

LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

template <typename T>
void Release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

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
    const int seconds = argc > 1 ? _wtoi(argv[1]) : 30;
    const int x = argc > 2 ? _wtoi(argv[2]) : 2560;
    const int y = argc > 3 ? _wtoi(argv[3]) : 0;
    const int width = argc > 4 ? _wtoi(argv[4]) : 1800;
    const int height = argc > 5 ? _wtoi(argv[5]) : 1169;

    MakeDpiAware();

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = Proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"SolStreamSwapChainSpike";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassExW(&wc);

    HWND window = CreateWindowExW(0, L"SolStreamSwapChainSpike",
                                  L"SolStream swap-chain spike",
                                  WS_POPUP | WS_VISIBLE, x, y, width, height,
                                  nullptr, nullptr, wc.hInstance, nullptr);
    if (!window) {
        std::printf("could not create the window\n");
        return 1;
    }
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);

    // Where the window ACTUALLY is, which is not always where it was asked to
    // be: this process is only system-DPI-aware, and a monitor at a different
    // scale factor moves and stretches what it is given.
    RECT placed{};
    GetWindowRect(window, &placed);
    MONITORINFOEXW where{};
    where.cbSize = sizeof(where);
    GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &where);
    std::printf("window at %ld,%ld %ldx%ld  visible=%d  on %ls\n",
                placed.left, placed.top, placed.right - placed.left,
                placed.bottom - placed.top, IsWindowVisible(window) ? 1 : 0,
                where.szDevice);
    std::fflush(stdout);

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL level{};
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                   D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                   D3D11_SDK_VERSION, &device, &level, &context);
    if (FAILED(hr)) {
        std::printf("no D3D11 device (0x%08lX)\n", hr);
        return 1;
    }

    IDXGIDevice* dxgiDevice = nullptr;
    IDXGIAdapter* adapter = nullptr;
    IDXGIFactory2* factory = nullptr;
    device->QueryInterface(__uuidof(IDXGIDevice), (void**) &dxgiDevice);
    dxgiDevice->GetAdapter(&adapter);
    adapter->GetParent(__uuidof(IDXGIFactory2), (void**) &factory);

    // FLIP_DISCARD, which is what a modern application presents with and what
    // the old capture path could not see through.
    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = (UINT) width;
    desc.Height = (UINT) height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1* swapChain = nullptr;
    hr = factory->CreateSwapChainForHwnd(device, window, &desc, nullptr, nullptr,
                                         &swapChain);
    if (FAILED(hr)) {
        std::printf("no swap chain (0x%08lX)\n", hr);
        return 1;
    }

    ID3D11Texture2D* backBuffer = nullptr;
    ID3D11RenderTargetView* target = nullptr;
    swapChain->GetBuffer(0, __uuidof(ID3D11Texture2D), (void**) &backBuffer);
    device->CreateRenderTargetView(backBuffer, nullptr, &target);

    ID3DBlob* vsBlob = nullptr;
    ID3DBlob* psBlob = nullptr;
    ID3DBlob* errors = nullptr;
    if (FAILED(D3DCompile(kShaders, strlen(kShaders), nullptr, nullptr, nullptr,
                          "vs", "vs_5_0", 0, 0, &vsBlob, &errors))
        || FAILED(D3DCompile(kShaders, strlen(kShaders), nullptr, nullptr, nullptr,
                             "ps", "ps_5_0", 0, 0, &psBlob, &errors))) {
        std::printf("shader compile failed: %s\n",
                    errors ? (const char*) errors->GetBufferPointer() : "?");
        return 1;
    }
    ID3D11VertexShader* vs = nullptr;
    ID3D11PixelShader* ps = nullptr;
    device->CreateVertexShader(vsBlob->GetBufferPointer(), vsBlob->GetBufferSize(),
                               nullptr, &vs);
    device->CreatePixelShader(psBlob->GetBufferPointer(), psBlob->GetBufferSize(),
                              nullptr, &ps);

    D3D11_BUFFER_DESC cbDesc{};
    cbDesc.ByteWidth = 16;
    cbDesc.Usage = D3D11_USAGE_DYNAMIC;
    cbDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    cbDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ID3D11Buffer* constants = nullptr;
    device->CreateBuffer(&cbDesc, nullptr, &constants);

    D3D11_VIEWPORT viewport{0.0f, 0.0f, (float) width, (float) height, 0.0f, 1.0f};

    LARGE_INTEGER frequency{}, started{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&started);
    long long presented = 0;

    for (;;) {
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        const double elapsed =
            (double) (now.QuadPart - started.QuadPart) / (double) frequency.QuadPart;
        if (elapsed > (double) seconds) {
            break;
        }

        D3D11_MAPPED_SUBRESOURCE mapped{};
        if (SUCCEEDED(context->Map(constants, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) {
            ((float*) mapped.pData)[0] = (float) elapsed;
            context->Unmap(constants, 0);
        }

        context->OMSetRenderTargets(1, &target, nullptr);
        context->RSSetViewports(1, &viewport);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vs, nullptr, 0);
        context->PSSetShader(ps, nullptr, 0);
        context->PSSetConstantBuffers(0, 1, &constants);
        context->Draw(3, 0);

        // NO VSYNC. The question is what the pipeline can carry, and a present
        // capped at the display's refresh answers a different one.
        swapChain->Present(0, 0);
        ++presented;

        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }

    LARGE_INTEGER ended{};
    QueryPerformanceCounter(&ended);
    const double total =
        (double) (ended.QuadPart - started.QuadPart) / (double) frequency.QuadPart;
    std::printf("presented %lld frames in %.2fs = %.1f fps at %dx%d\n",
                presented, total, (double) presented / total, width, height);

    Release(constants);
    Release(ps);
    Release(vs);
    Release(psBlob);
    Release(vsBlob);
    Release(target);
    Release(backBuffer);
    Release(swapChain);
    Release(factory);
    Release(adapter);
    Release(dxgiDevice);
    Release(context);
    Release(device);
    DestroyWindow(window);
    return 0;
}
