// animate — moving content on the virtual display, so throughput can be measured.
//
// Every fps figure this project has produced so far was taken against a STILL
// Windows desktop, where WGC delivers about 17 frames a second because that is
// how much changed. That number says nothing about whether the pipeline can
// sustain 60: the encoder was never asked for 60, so an encoder that cannot do
// it would look identical.
//
// This paints a full-screen window on the virtual display as fast as the
// compositor will take it, with content that changes in every pixel — a moving
// diagonal gradient — so the encoder gets no free frames and the capture has
// something to deliver at whatever rate it can.
//
// It lives on the VIRTUAL display, which is SolStream's own, so nothing the user
// has open is covered or disturbed.
//
//   animate.exe <seconds> [x] [y] [width] [height]

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

int g_phase = 0;
std::vector<unsigned char> g_pixels;
int g_width = 0, g_height = 0;
long long g_painted = 0;

/// A moving diagonal gradient, written straight into a DIB.
///
/// GDI rectangle fills would be cheaper, but they are also exactly the content
/// an encoder finds trivial. A gradient that moves every frame is closer to what
/// a real application costs, without needing a real application.
void Paint(HDC dc) {
    for (int y = 0; y < g_height; ++y) {
        unsigned char* row = g_pixels.data() + (size_t) y * g_width * 4;
        for (int x = 0; x < g_width; ++x) {
            const int value = (x + y + g_phase) & 0xFF;
            row[x * 4 + 0] = (unsigned char) value;
            row[x * 4 + 1] = (unsigned char) (255 - value);
            row[x * 4 + 2] = (unsigned char) ((value * 3) & 0xFF);
            row[x * 4 + 3] = 255;
        }
    }
    BITMAPINFO info{};
    info.bmiHeader.biSize = sizeof(info.bmiHeader);
    info.bmiHeader.biWidth = g_width;
    info.bmiHeader.biHeight = -g_height;   // top-down
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    SetDIBitsToDevice(dc, 0, 0, g_width, g_height, 0, 0, 0, g_height,
                      g_pixels.data(), &info, DIB_RGB_COLORS);
    ++g_painted;
}

LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_PAINT) {
        PAINTSTRUCT paint{};
        HDC dc = BeginPaint(window, &paint);
        Paint(dc);
        EndPaint(window, &paint);
        return 0;
    }
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    const int seconds = argc > 1 ? _wtoi(argv[1]) : 30;
    const int x = argc > 2 ? _wtoi(argv[2]) : 2560;
    const int y = argc > 3 ? _wtoi(argv[3]) : 0;
    g_width = argc > 4 ? _wtoi(argv[4]) : 1800;
    g_height = argc > 5 ? _wtoi(argv[5]) : 1169;
    g_pixels.resize((size_t) g_width * g_height * 4);

    SetProcessDPIAware();

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = Proc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"SolStreamAnimateSpike";
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassExW(&wc);

    HWND window = CreateWindowExW(0, L"SolStreamAnimateSpike",
                                  L"SolStream animation spike",
                                  WS_POPUP | WS_VISIBLE, x, y, g_width, g_height,
                                  nullptr, nullptr, wc.hInstance, nullptr);
    if (!window) {
        std::printf("could not create the window\n");
        return 1;
    }
    ShowWindow(window, SW_SHOW);
    SetForegroundWindow(window);

    LARGE_INTEGER frequency{}, started{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&started);

    for (;;) {
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        if ((now.QuadPart - started.QuadPart) > frequency.QuadPart * seconds) {
            break;
        }
        ++g_phase;
        InvalidateRect(window, nullptr, FALSE);
        UpdateWindow(window);

        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }

    LARGE_INTEGER ended{};
    QueryPerformanceCounter(&ended);
    const double elapsed =
        (double) (ended.QuadPart - started.QuadPart) / (double) frequency.QuadPart;
    std::printf("painted %lld frames in %.2fs = %.1f fps at %dx%d\n",
                g_painted, elapsed, (double) g_painted / elapsed, g_width, g_height);
    DestroyWindow(window);
    return 0;
}
