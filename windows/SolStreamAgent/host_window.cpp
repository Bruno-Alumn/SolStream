#include "host_window.h"

#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <shellapi.h>

#include <mutex>
#include <string>

#include "vdd.h"

// Not in every SDK this is built against, and it is only an integer.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

namespace solstream {
namespace {

constexpr wchar_t kClassName[] = L"SolStreamHostWindow";
/// Wide enough for the longest status line. The first render truncated
/// "Sunshine running on base port 47600 (installed copy)" mid-word, which is the
/// one row where the detail is the whole point.
constexpr int kWidth = 620;
/// Two heights, because the pairing card is only there when a Mac is waiting.
/// One height sized for the card leaves a third of the window empty the rest of
/// the time; one sized without it clips the card when it matters most.
constexpr int kHeightCompact = 344;
constexpr int kHeightWithPin = 510;
constexpr UINT kTimerId = 1;

int g_height = kHeightCompact;

enum ControlId {
    kIdCopyToken = 100,
    kIdInstallDriver = 101,
    kIdOpenPairingPage = 102,
};

std::mutex g_mutex;
HostStatus g_status;
std::wstring g_pending_pin;
std::wstring g_pending_client;
bool g_closed = false;

HWND g_window = nullptr;
HFONT g_title_font = nullptr;
HFONT g_body_font = nullptr;
HFONT g_mono_font = nullptr;
HFONT g_pin_font = nullptr;

/// The design's palette, as far as a plain Win32 window can carry it: the same
/// near-black ground and the same accent, so the two applications read as one
/// product rather than as a Mac app and a utility somebody wrote in a hurry.
constexpr COLORREF kGround = RGB(0x14, 0x15, 0x1C);
constexpr COLORREF kCard = RGB(0x1C, 0x1E, 0x28);
constexpr COLORREF kText = RGB(0xEC, 0xEE, 0xF6);
constexpr COLORREF kTextFaint = RGB(0x8A, 0x8E, 0xA3);
constexpr COLORREF kAccent = RGB(0x7C, 0x6C, 0xF5);
constexpr COLORREF kAccentPressed = RGB(0x2A, 0x27, 0x4A);
constexpr COLORREF kGood = RGB(0x4C, 0xC8, 0x8A);
constexpr COLORREF kBad = RGB(0xE0, 0x6C, 0x6C);

HBRUSH g_ground_brush = nullptr;
HBRUSH g_card_brush = nullptr;

HFONT MakeFont(int height, int weight, const wchar_t* face) {
    return CreateFontW(height, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                       CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, face);
}

void CopyToClipboard(const std::wstring& text) {
    if (!OpenClipboard(g_window)) {
        return;
    }
    EmptyClipboard();
    const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    if (HGLOBAL handle = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
        if (void* target = GlobalLock(handle)) {
            memcpy(target, text.c_str(), bytes);
            GlobalUnlock(handle);
            SetClipboardData(CF_UNICODETEXT, handle);
        } else {
            GlobalFree(handle);
        }
    }
    CloseClipboard();
}

/// One "label: value" row with a coloured state dot, mirroring the way the Mac
/// draws a host in its list — the dot is the only colour in the row.
void DrawStatusRow(HDC dc, int x, int& y, const wchar_t* label,
                   const std::wstring& value, bool ok, bool has_dot = true) {
    if (has_dot) {
        const COLORREF colour = ok ? kGood : kBad;
        HBRUSH dot = CreateSolidBrush(colour);
        RECT circle{x, y + 6, x + 8, y + 14};
        HRGN region = CreateEllipticRgnIndirect(&circle);
        FillRgn(dc, region, dot);
        DeleteObject(region);
        DeleteObject(dot);
    }

    SelectObject(dc, g_body_font);
    SetTextColor(dc, kTextFaint);
    RECT label_rect{x + 18, y, x + 150, y + 20};
    DrawTextW(dc, label, -1, &label_rect, DT_LEFT | DT_SINGLELINE);

    SetTextColor(dc, kText);
    RECT value_rect{x + 150, y, kWidth - 30, y + 20};
    DrawTextW(dc, value.c_str(), -1, &value_rect,
              DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);
    y += 26;
}

void Paint(HWND window) {
    PAINTSTRUCT paint{};
    HDC dc = BeginPaint(window, &paint);

    RECT client{};
    GetClientRect(window, &client);
    FillRect(dc, &client, g_ground_brush);
    SetBkMode(dc, TRANSPARENT);

    HostStatus status;
    std::wstring pin, pin_client;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        status = g_status;
        pin = g_pending_pin;
        pin_client = g_pending_client;
    }

    int y = 24;
    SelectObject(dc, g_title_font);
    SetTextColor(dc, kText);
    RECT title{28, y, kWidth - 28, y + 34};
    DrawTextW(dc, L"SolStream", -1, &title, DT_LEFT | DT_SINGLELINE);
    y += 32;

    SelectObject(dc, g_body_font);
    SetTextColor(dc, kTextFaint);
    RECT subtitle{28, y, kWidth - 28, y + 22};
    const std::wstring ready = status.agent_listening && status.sunshine_running
        ? L"Ready. Open SolStream on your Mac and pick this PC."
        : L"Getting ready…";
    DrawTextW(dc, ready.c_str(), -1, &subtitle, DT_LEFT | DT_WORDBREAK);
    y += 34;

    // The pairing card takes over the window when a Mac is waiting, because at
    // that moment it is the only thing that matters.
    if (!pin.empty()) {
        RECT card{20, y, kWidth - 20, y + 150};
        FillRect(dc, &card, g_card_brush);

        SelectObject(dc, g_body_font);
        SetTextColor(dc, kTextFaint);
        RECT ask{36, y + 14, kWidth - 36, y + 56};
        // Which end the code goes into is the whole instruction, and it goes
        // into this PC: the Mac is the end that *shows* it. Saying "enter this
        // code there" pointed at the machine already displaying it.
        const std::wstring who = pin_client.empty() ? std::wstring(L"A Mac")
                                                    : pin_client;
        const std::wstring line =
            who + L" is asking to pair, and SolStream could not approve it for you. "
                  L"Enter this code on the pairing page of this PC:";
        DrawTextW(dc, line.c_str(), -1, &ask, DT_LEFT | DT_WORDBREAK);

        SelectObject(dc, g_pin_font);
        SetTextColor(dc, kAccent);
        RECT code{36, y + 58, kWidth - 36, y + 120};
        DrawTextW(dc, pin.c_str(), -1, &code, DT_CENTER | DT_SINGLELINE);
        y += 166;
    }

    RECT card{20, y, kWidth - 20, y + 122};
    FillRect(dc, &card, g_card_brush);
    int row = y + 14;
    DrawStatusRow(dc, 36, row, L"This PC",
                  status.computer_name.empty() ? L"—" : status.computer_name, true, false);
    DrawStatusRow(dc, 36, row, L"Address",
                  status.address.empty() ? L"not reachable" : status.address,
                  !status.address.empty());
    DrawStatusRow(dc, 36, row, L"Streaming",
                  status.sunshine_detail, status.sunshine_running);
    DrawStatusRow(dc, 36, row, L"Virtual display",
                  status.display_detail, status.virtual_display);
    y += 138;

    SelectObject(dc, g_body_font);
    SetTextColor(dc, kTextFaint);
    RECT token_label{28, y, kWidth - 28, y + 20};
    DrawTextW(dc, L"Pairing token — the Mac asks for this once", -1, &token_label,
              DT_LEFT | DT_SINGLELINE);
    y += 22;

    SelectObject(dc, g_mono_font);
    SetTextColor(dc, kText);
    RECT token{28, y, kWidth - 140, y + 24};
    DrawTextW(dc, status.pairing_token.c_str(), -1, &token,
              DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS);

    EndPaint(window, &paint);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_CREATE: {
            // Owner-drawn: a stock button is light grey with a light border,
            // and on a near-black card that is the one element that looks like
            // it belongs to a different program.
            CreateWindowExW(0, L"BUTTON", L"Copy token",
                            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW,
                            kWidth - 130, g_height - 96, 100, 26,
                            window, (HMENU) (INT_PTR) kIdCopyToken,
                            nullptr, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Open pairing page",
                            WS_CHILD | BS_OWNERDRAW,
                            kWidth - 200, 176, 164, 28,
                            window, (HMENU) (INT_PTR) kIdOpenPairingPage,
                            nullptr, nullptr);
            CreateWindowExW(0, L"BUTTON", L"Install display driver",
                            WS_CHILD | BS_OWNERDRAW,
                            28, g_height - 56, 180, 28,
                            window, (HMENU) (INT_PTR) kIdInstallDriver,
                            nullptr, nullptr);
            // A dark title bar to match the window under it. Without this the
            // chrome is light and the content is near-black, which reads as an
            // application that has been half-restyled.
            const BOOL dark = TRUE;
            DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                                  &dark, sizeof(dark));
            SetTimer(window, kTimerId, 1000, nullptr);
            return 0;
        }

        case WM_COMMAND: {
            switch (LOWORD(wparam)) {
                case kIdCopyToken: {
                    std::lock_guard<std::mutex> lock(g_mutex);
                    CopyToClipboard(g_status.pairing_token);
                    return 0;
                }
                case kIdOpenPairingPage: {
                    unsigned short port = 0;
                    {
                        std::lock_guard<std::mutex> lock(g_mutex);
                        port = g_status.web_ui_port;
                    }
                    if (port != 0) {
                        // Sunshine's own page, on this machine. Opened here so
                        // the instruction is two clicks rather than a URL the
                        // user has to be told how to assemble.
                        const std::wstring url =
                            L"https://localhost:" + std::to_wstring(port) + L"/pin";
                        ShellExecuteW(window, L"open", url.c_str(), nullptr, nullptr,
                                      SW_SHOWNORMAL);
                    }
                    return 0;
                }
                case kIdInstallDriver: {
                    std::string error;
                    if (InstallBundledDriver(error)) {
                        MessageBoxW(window,
                                    L"The display driver is installed. SolStream will "
                                    L"use it the next time a Mac connects.",
                                    L"SolStream", MB_OK | MB_ICONINFORMATION);
                    } else {
                        const std::wstring reason(error.begin(), error.end());
                        MessageBoxW(window, reason.c_str(), L"SolStream",
                                    MB_OK | MB_ICONWARNING);
                    }
                    return 0;
                }
                default:
                    break;
            }
            break;
        }

        case WM_DRAWITEM: {
            auto* item = (DRAWITEMSTRUCT*) lparam;
            if (item->CtlType != ODT_BUTTON) {
                break;
            }
            const bool pressed = (item->itemState & ODS_SELECTED) != 0;
            // The accent for the action, a flat fill for the surface, and a
            // one-pixel edge — the same shape the Mac's outlined buttons have.
            HBRUSH fill = CreateSolidBrush(pressed ? kAccentPressed : kCard);
            FillRect(item->hDC, &item->rcItem, fill);
            DeleteObject(fill);

            HPEN pen = CreatePen(PS_SOLID, 1, kAccent);
            HGDIOBJ old_pen = SelectObject(item->hDC, pen);
            HGDIOBJ old_brush = SelectObject(item->hDC, GetStockObject(NULL_BRUSH));
            Rectangle(item->hDC, item->rcItem.left, item->rcItem.top,
                      item->rcItem.right, item->rcItem.bottom);
            SelectObject(item->hDC, old_pen);
            SelectObject(item->hDC, old_brush);
            DeleteObject(pen);

            wchar_t caption[128] = {};
            GetWindowTextW(item->hwndItem, caption, 128);
            SetBkMode(item->hDC, TRANSPARENT);
            SetTextColor(item->hDC, kText);
            SelectObject(item->hDC, g_body_font);
            DrawTextW(item->hDC, caption, -1, &item->rcItem,
                      DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            if (item->itemState & ODS_FOCUS) {
                RECT focus = item->rcItem;
                InflateRect(&focus, -3, -3);
                DrawFocusRect(item->hDC, &focus);
            }
            return TRUE;
        }

        case WM_SIZE: {
            // Keep the buttons on the bottom edge wherever it now is.
            const int height = HIWORD(lparam);
            SetWindowPos(GetDlgItem(window, kIdCopyToken), nullptr,
                         kWidth - 130, height - 96, 0, 0,
                         SWP_NOSIZE | SWP_NOZORDER);
            SetWindowPos(GetDlgItem(window, kIdInstallDriver), nullptr,
                         28, height - 56, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
            return 0;
        }

        case WM_TIMER: {
            // The install button only exists while it would do something.
            bool needs_driver = false;
            bool pairing = false;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                needs_driver = !g_status.virtual_display;
                pairing = !g_pending_pin.empty();
            }
            ShowWindow(GetDlgItem(window, kIdInstallDriver),
                       needs_driver ? SW_SHOW : SW_HIDE);
            ShowWindow(GetDlgItem(window, kIdOpenPairingPage),
                       pairing ? SW_SHOW : SW_HIDE);
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_CTLCOLORBTN:
        case WM_CTLCOLORSTATIC: {
            SetBkColor((HDC) wparam, kGround);
            SetTextColor((HDC) wparam, kText);
            return (LRESULT) g_ground_brush;
        }

        case WM_ERASEBKGND:
            return 1;  // Paint() fills the whole client area; this stops the flicker.

        case WM_PAINT:
            Paint(window);
            return 0;

        case WM_CLOSE:
            // Closing the window ends the session deliberately. A host that goes
            // on streaming after its window is gone is a host nobody can find
            // again to turn off.
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_closed = true;
            }
            DestroyWindow(window);
            return 0;

        case WM_DESTROY:
            PostQuitMessage(0);
            return 0;

        default:
            break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

bool ShowHostWindow() {
    g_ground_brush = CreateSolidBrush(kGround);
    g_card_brush = CreateSolidBrush(kCard);
    g_title_font = MakeFont(-28, FW_SEMIBOLD, L"Segoe UI");
    g_body_font = MakeFont(-15, FW_NORMAL, L"Segoe UI");
    g_mono_font = MakeFont(-15, FW_NORMAL, L"Consolas");
    g_pin_font = MakeFont(-46, FW_SEMIBOLD, L"Consolas");

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClassName;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = g_ground_brush;
    if (!RegisterClassExW(&wc)) {
        return false;
    }

    RECT wanted{0, 0, kWidth, g_height};
    AdjustWindowRect(&wanted, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE);
    g_window = CreateWindowExW(
        0, kClassName, L"SolStream",
        // Not resizable: everything in it is a fixed-height card, and a window
        // that can be dragged to a shape none of its content fits is worse than
        // one that cannot be dragged at all.
        (WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX),
        CW_USEDEFAULT, CW_USEDEFAULT,
        wanted.right - wanted.left, wanted.bottom - wanted.top,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!g_window) {
        return false;
    }
    ShowWindow(g_window, SW_SHOW);
    UpdateWindow(g_window);
    return true;
}

void UpdateHostStatus(const HostStatus& status) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_status = status;
    }
    if (g_window) {
        InvalidateRect(g_window, nullptr, FALSE);
    }
}

void ShowPairingPin(const std::wstring& pin, const std::wstring& client_name) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_pending_pin = pin;
        g_pending_client = client_name;
    }
    if (g_window) {
        // Grow to fit the card, and shrink again when it goes.
        const int wanted_height = pin.empty() ? kHeightCompact : kHeightWithPin;
        if (wanted_height != g_height) {
            g_height = wanted_height;
            RECT frame{0, 0, kWidth, g_height};
            AdjustWindowRect(&frame, (WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME), FALSE);
            SetWindowPos(g_window, nullptr, 0, 0,
                         frame.right - frame.left, frame.bottom - frame.top,
                         SWP_NOMOVE | SWP_NOZORDER);
        }
        // Bring it forward: this is the one moment the user has to look.
        if (!pin.empty()) {
            ShowWindow(g_window, SW_SHOW);
            SetForegroundWindow(g_window);
            FlashWindow(g_window, TRUE);
        }
        InvalidateRect(g_window, nullptr, TRUE);
    }
}

int RunHostWindowLoop() {
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return (int) message.wParam;
}

bool HostWindowClosed() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_closed;
}

}  // namespace solstream
