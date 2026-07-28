// host_window.cpp — the one thing the user opens on the Windows PC.
//
// Direct2D and DirectWrite rather than GDI. Not for taste: the two hard
// constraints are per-monitor DPI from 100% to 200%, and live Windows 11 light
// and dark. D2D draws in DIPs, so scaling is a property of the render target
// and never a second layout, and DirectWrite is the only thing here that can
// lay out Segoe UI Variable at a real axis weight. Both ship in Windows, so the
// program is still one self-contained executable with nothing to install —
// which is the whole point of an application somebody sets up on a PC that is
// not theirs.
//
// Buttons are drawn rather than being child controls, because the design
// specifies five states per part in literal hex and a stock button can honour
// none of them. The token is the exception: it is a real EDIT, because
// selection, the caret and Ctrl+C are the entire reason that field exists and
// hand-rolling text selection to get them back would be absurd.

#include "host_window.h"

#include <windows.h>
#include <windowsx.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dwmapi.h>
#include <shellapi.h>

#include <mutex>
#include <string>
#include <vector>

#include "host_theme.h"
#include "vdd.h"

// Not in every SDK this is built against, and they are only integers.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMSBT_MAINWINDOW
#define DWMSBT_MAINWINDOW 2
#endif

namespace solstream {
namespace {

constexpr wchar_t kClassName[] = L"SolStreamHostWindow";
constexpr UINT kTimerId = 1;
constexpr int kEditId = 200;

// ── Shared state ─────────────────────────────────────────────────────────────

std::mutex g_mutex;
HostStatus g_status;
std::wstring g_pending_pin;
std::wstring g_pending_client;
bool g_closed = false;

HWND g_window = nullptr;
HWND g_token_edit = nullptr;
HFONT g_edit_font = nullptr;
Palette g_palette = DarkPalette();
float g_dpi = 96.0f;

// ── Direct2D ─────────────────────────────────────────────────────────────────

ID2D1Factory* g_d2d = nullptr;
ID2D1HwndRenderTarget* g_target = nullptr;
ID2D1SolidColorBrush* g_brush = nullptr;
IDWriteFactory* g_dwrite = nullptr;

IDWriteTextFormat* g_fmt_wordmark = nullptr;
IDWriteTextFormat* g_fmt_headline = nullptr;
IDWriteTextFormat* g_fmt_value = nullptr;
IDWriteTextFormat* g_fmt_label = nullptr;
IDWriteTextFormat* g_fmt_mono = nullptr;
IDWriteTextFormat* g_fmt_token = nullptr;
IDWriteTextFormat* g_fmt_pin = nullptr;

/// Segoe UI Variable and Cascadia Mono ship with Windows 11. On anything older
/// DirectWrite falls back on its own; naming the fallback explicitly keeps the
/// metrics predictable instead of letting it pick.
IDWriteTextFormat* MakeFormat(const wchar_t* family, float size,
                              DWRITE_FONT_WEIGHT weight) {
    IDWriteTextFormat* format = nullptr;
    if (FAILED(g_dwrite->CreateTextFormat(family, nullptr, weight,
                                          DWRITE_FONT_STYLE_NORMAL,
                                          DWRITE_FONT_STRETCH_NORMAL, size,
                                          L"en-us", &format))) {
        return nullptr;
    }
    format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    return format;
}

bool CreateDeviceIndependentResources() {
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &g_d2d))) {
        return false;
    }
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                                   __uuidof(IDWriteFactory),
                                   reinterpret_cast<IUnknown**>(&g_dwrite)))) {
        return false;
    }
    g_fmt_wordmark = MakeFormat(L"Segoe UI Variable Display", type::kWordmark,
                                DWRITE_FONT_WEIGHT_MEDIUM);
    g_fmt_headline = MakeFormat(L"Segoe UI Variable Text", type::kHeadline,
                                DWRITE_FONT_WEIGHT_MEDIUM);
    g_fmt_value = MakeFormat(L"Segoe UI Variable Text", type::kValue,
                             DWRITE_FONT_WEIGHT_NORMAL);
    g_fmt_label = MakeFormat(L"Segoe UI Variable Text", type::kLabel,
                             DWRITE_FONT_WEIGHT_NORMAL);
    g_fmt_mono = MakeFormat(L"Cascadia Mono", type::kMono,
                            DWRITE_FONT_WEIGHT_NORMAL);
    g_fmt_token = MakeFormat(L"Cascadia Mono", type::kValue,
                             DWRITE_FONT_WEIGHT_NORMAL);
    g_fmt_pin = MakeFormat(L"Cascadia Mono", type::kPin,
                           DWRITE_FONT_WEIGHT_SEMI_BOLD);
    return g_fmt_value != nullptr;
}

void DiscardTarget() {
    if (g_brush) { g_brush->Release(); g_brush = nullptr; }
    if (g_target) { g_target->Release(); g_target = nullptr; }
}

bool EnsureTarget(HWND window) {
    if (g_target) {
        return true;
    }
    RECT client{};
    GetClientRect(window, &client);
    const D2D1_SIZE_U size = D2D1::SizeU(client.right - client.left,
                                         client.bottom - client.top);
    if (size.width == 0 || size.height == 0) {
        return false;
    }
    if (FAILED(g_d2d->CreateHwndRenderTarget(
            D2D1::RenderTargetProperties(),
            D2D1::HwndRenderTargetProperties(window, size), &g_target))) {
        return false;
    }
    // Authoring is in DIPs; this is the only place the scale factor exists.
    g_target->SetDpi(g_dpi, g_dpi);
    g_target->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &g_brush);
    return g_brush != nullptr;
}

// ── Drawing primitives ───────────────────────────────────────────────────────

void Fill(const D2D1_RECT_F& rect, float radius, const D2D1_COLOR_F& colour) {
    g_brush->SetColor(colour);
    if (radius <= 0.0f) {
        g_target->FillRectangle(rect, g_brush);
        return;
    }
    g_target->FillRoundedRectangle(D2D1::RoundedRect(rect, radius, radius), g_brush);
}

void Stroke(const D2D1_RECT_F& rect, float radius, const D2D1_COLOR_F& colour,
            float width = 1.0f) {
    g_brush->SetColor(colour);
    // Inset by half the stroke so the line lands inside the box rather than
    // straddling its edge — otherwise adjacent hairlines read as 2px.
    const float half = width / 2.0f;
    const D2D1_RECT_F inner{rect.left + half, rect.top + half,
                            rect.right - half, rect.bottom - half};
    if (radius <= 0.0f) {
        g_target->DrawRectangle(inner, g_brush, width);
        return;
    }
    g_target->DrawRoundedRectangle(D2D1::RoundedRect(inner, radius, radius),
                                   g_brush, width);
}

void Text(const std::wstring& text, IDWriteTextFormat* format,
          const D2D1_RECT_F& rect, const D2D1_COLOR_F& colour,
          DWRITE_TEXT_ALIGNMENT align = DWRITE_TEXT_ALIGNMENT_LEADING) {
    if (!format || text.empty()) {
        return;
    }
    format->SetTextAlignment(align);
    g_brush->SetColor(colour);
    g_target->DrawTextW(text.c_str(), (UINT32) text.size(), format, rect, g_brush,
                        D2D1_DRAW_TEXT_OPTIONS_CLIP);
}

/// The focus ring: one geometry everywhere. Two DIPs of the parent's own ground
/// between the control and a two-DIP accent stroke, at a radius concentric with
/// whatever it surrounds. Drawn outside the layout box, so focus never reflows
/// anything — which is why every container owes it kFocusClearance of room.
void FocusRing(const D2D1_RECT_F& control, float control_radius) {
    const float gap = metric::kFocusGap;
    const float stroke = metric::kFocusStroke;
    const D2D1_RECT_F ring{control.left - gap - stroke / 2,
                           control.top - gap - stroke / 2,
                           control.right + gap + stroke / 2,
                           control.bottom + gap + stroke / 2};
    g_brush->SetColor(g_palette.accent);
    const float radius = control_radius + metric::kFocusRadiusBump;
    g_target->DrawRoundedRectangle(D2D1::RoundedRect(ring, radius, radius),
                                   g_brush, stroke);
}

/// A status mark. Solid accent = good, accent in a ring = needs you, grey =
/// not present. No new hues and never red: severity lives in the words.
void DrawMark(float cx, float cy, Mark mark) {
    if (mark == Mark::NeedsYou) {
        g_brush->SetColor(D2D1::ColorF(g_palette.accent.r, g_palette.accent.g,
                                       g_palette.accent.b, 0.20f));
        g_target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 7.0f, 7.0f),
                              g_brush);
    }
    g_brush->SetColor(MarkColor(g_palette, mark));
    g_target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 4.0f, 4.0f), g_brush);
}

// ── Interaction ──────────────────────────────────────────────────────────────

enum class ButtonKind { Primary, Secondary };

struct Button {
    int id = 0;
    std::wstring caption;
    ButtonKind kind = ButtonKind::Secondary;
    bool shield = false;     ///< announces that pressing it raises a UAC prompt
    D2D1_RECT_F rect{};      ///< visual box, in DIPs
    bool visible = false;
};

enum ButtonId {
    kIdCopyToken = 1,
    kIdOpenPairingPage,
    kIdBannerFix,
};

std::vector<Button> g_buttons;
int g_hot = 0;       ///< under the pointer
int g_pressed = 0;   ///< mouse is down on it
int g_focus = 0;     ///< keyboard focus
/// Suppress the ring on mouse-driven focus, or every click leaves one behind.
bool g_keyboard_nav = false;

Button* FindButton(int id) {
    for (Button& button : g_buttons) {
        if (button.id == id) {
            return &button;
        }
    }
    return nullptr;
}

/// Hit rects are taller than paint rects on the small controls — 32 DIP is the
/// platform minimum and the Copy button is only 22 DIP of visible ink.
bool HitButton(const Button& button, float x, float y) {
    if (!button.visible) {
        return false;
    }
    const float height = button.rect.bottom - button.rect.top;
    const float grow = height < metric::kButtonHit
                           ? (metric::kButtonHit - height) / 2.0f : 0.0f;
    return x >= button.rect.left && x <= button.rect.right
           && y >= button.rect.top - grow && y <= button.rect.bottom + grow;
}

void DrawButton(const Button& button) {
    if (!button.visible) {
        return;
    }
    const bool hot = g_hot == button.id;
    const bool down = g_pressed == button.id && hot;
    const bool focused = g_focus == button.id && g_keyboard_nav;

    D2D1_COLOR_F fill{};
    D2D1_COLOR_F ink{};
    if (button.kind == ButtonKind::Primary) {
        fill = down ? g_palette.accentPressed
                    : (hot ? g_palette.accentHover : g_palette.accent);
        ink = g_palette.onAccent;
        Fill(button.rect, metric::kRadiusControl, fill);
    } else {
        ink = hot ? g_palette.accentTintInk : g_palette.text;
        if (down) {
            Fill(button.rect, metric::kRadiusControl, g_palette.accentTint);
        }
        Stroke(button.rect, metric::kRadiusControl,
               hot ? g_palette.accent : g_palette.hairlineStrong);
    }

    D2D1_RECT_F label = button.rect;
    if (button.shield) {
        // The shield says "this elevates" before the UAC prompt steals focus.
        const D2D1_RECT_F glyph{button.rect.left + 10.0f, button.rect.top,
                                button.rect.left + 24.0f, button.rect.bottom};
        Text(L"⛊", g_fmt_mono, glyph,
             button.kind == ButtonKind::Primary ? ink : g_palette.accentHover);
        label.left += metric::kShieldExtra;
    }
    Text(button.caption, g_fmt_label, label, ink, DWRITE_TEXT_ALIGNMENT_CENTER);

    if (focused) {
        FocusRing(button.rect, metric::kRadiusControl);
    }
}

// ── What the window is currently saying ──────────────────────────────────────

struct Screen {
    std::wstring headline;
    // The banner is a sentence, a reason, and one button. Empty `what` means no
    // banner at all — most of this window's life.
    std::wstring what;
    std::wstring why;
    std::wstring fix;
    std::wstring code;
    bool shield = false;
    bool connected = false;
};

/// Derive what to show from what the agent last reported. One banner at a time:
/// failures cascade, and four banners describing one broken link is noise.
Screen Describe(const HostStatus& status) {
    Screen screen;
    screen.connected = status.connected_clients > 0;

    if (status.address.empty()) {
        screen.headline = L"Ready, but your Mac can't reach this PC.";
        screen.what = L"This PC isn't on a network your Mac can see.";
        screen.why = L"SolStream needs both machines on the same local network.";
        screen.code = L"SS-104";
        return screen;
    }
    if (!status.sunshine_running) {
        screen.headline = L"SolStream couldn't start streaming.";
        screen.what = status.sunshine_detail.empty()
                          ? L"The streaming host stopped."
                          : status.sunshine_detail;
        screen.why = L"SolStream restarts it on a crash, so a failure that reaches "
                     L"you is a real conflict rather than a hiccup.";
        screen.code = L"SS-311";
        return screen;
    }
    screen.headline = screen.connected
        ? L"Streaming to your Mac."
        : L"Ready. Open SolStream on your Mac and pick this PC.";

    // Missing driver is an advisory, not a failure. SolStream captures the main
    // display instead and everything works — which is why this does not take
    // over the headline, and why the row beside it is "needs you" rather than
    // the grey mark that means broken.
    //
    // It is still worth saying, because the two things it costs are exactly the
    // two a person would otherwise discover the hard way: whatever they drag
    // over the streamed application goes down the wire with it, and the canvas
    // is the monitor's size rather than the Mac's, so the picture is scaled.
    if (!status.virtual_display) {
        screen.what = L"Streaming your main display.";
        screen.why = L"That works, but everything on that display goes to your Mac — "
                     L"including anything you drag over the application — and the "
                     L"picture is your monitor's size rather than your Mac's. A "
                     L"virtual display fixes both.";
        screen.fix = L"Install driver";
        screen.shield = true;
    }
    return screen;
}

// ── Layout and paint ─────────────────────────────────────────────────────────

struct Row {
    const wchar_t* label;
    std::wstring value;
    Mark mark;
};

void LayoutAndPaint(HWND window) {
    if (!EnsureTarget(window)) {
        return;
    }

    HostStatus status;
    std::wstring pin, pin_client;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        status = g_status;
        pin = g_pending_pin;
        pin_client = g_pending_client;
    }
    const Screen screen = Describe(status);

    const D2D1_SIZE_F size = g_target->GetSize();
    const float pad = space::kXl;
    const float right = size.width - pad;

    g_target->BeginDraw();
    g_target->Clear(g_palette.ground);

    float y = pad;

    // Wordmark. Segoe UI Variable Display at a real 500 axis stop.
    Text(L"SolStream", g_fmt_wordmark,
         D2D1::RectF(pad, y, right, y + 36.0f), g_palette.text);
    y += 36.0f + space::kMd;

    // The headline answers "is this PC ready" before anything else is read.
    Text(screen.headline, g_fmt_headline,
         D2D1::RectF(pad, y, right, y + 52.0f), g_palette.text);
    y += 52.0f + space::kLg;

    // The banner sits under the headline and above the rows, because the rows
    // are its evidence. One sentence, one reason, one button that does the
    // thing — never "Learn more".
    Button* fix = FindButton(kIdBannerFix);
    if (fix) {
        fix->visible = false;
    }
    if (!screen.what.empty()) {
        // Height first, then the card, then its contents. D2D has no z-order —
        // the order of the calls is the z-order — so anything drawn before the
        // fill is simply painted over.
        constexpr float kWhatH = 22.0f;
        constexpr float kWhyH = 40.0f;
        const bool has_fix = fix && !screen.fix.empty();
        const float top = y;
        const float height = space::kMd + kWhatH + space::kXs + kWhyH
                             + (has_fix ? space::kSm + metric::kButtonH : 0.0f)
                             + space::kMd;

        Fill(D2D1::RectF(pad, top, right, top + height), metric::kRadiusCard,
             g_palette.card);
        Stroke(D2D1::RectF(pad, top, right, top + height), metric::kRadiusCard,
               g_palette.hairlineStrong);

        float inner = top + space::kMd;
        Text(screen.what, g_fmt_value,
             D2D1::RectF(pad + space::kMd, inner, right - space::kMd,
                         inner + kWhatH), g_palette.text);
        inner += kWhatH + space::kXs;
        Text(screen.why, g_fmt_label,
             D2D1::RectF(pad + space::kMd, inner, right - space::kMd,
                         inner + kWhyH), g_palette.muted);
        inner += kWhyH + space::kSm;

        if (has_fix) {
            const float width = metric::kButtonMinW
                                + (screen.shield ? metric::kShieldExtra : 0.0f);
            fix->rect = D2D1::RectF(pad + space::kMd, inner,
                                    pad + space::kMd + width,
                                    inner + metric::kButtonH);
            fix->caption = screen.fix;
            fix->shield = screen.shield;
            fix->kind = ButtonKind::Primary;
            fix->visible = true;
            DrawButton(*fix);
            if (!screen.code.empty()) {
                // For support, not for the user: small, quiet, always there.
                Text(screen.code, g_fmt_mono,
                     D2D1::RectF(right - 90.0f - space::kMd, inner,
                                 right - space::kMd, inner + metric::kButtonH),
                     g_palette.faint, DWRITE_TEXT_ALIGNMENT_TRAILING);
            }
        }
        y = top + height + space::kLg;
    }

    // Four rows, in the order they fail. A status list is a table, so its rules
    // do not fade — a fading rule inside a table reads as damage.
    std::vector<Row> rows;
    rows.push_back({L"This PC",
                    status.computer_name.empty() ? L"—" : status.computer_name,
                    Mark::Good});
    rows.push_back({L"Address",
                    status.address.empty() ? L"not reachable" : status.address,
                    status.address.empty() ? Mark::Absent : Mark::Good});
    if (screen.connected) {
        rows.push_back({L"Serving",
                        std::to_wstring(status.connected_clients) + L" of 1 · Mac only",
                        Mark::Good});
    } else {
        rows.push_back({L"Streaming",
                        status.sunshine_running ? L"running" : L"not running",
                        status.sunshine_running ? Mark::Good : Mark::Absent});
    }
    // Named for what it is doing rather than for what is missing. "Virtual
    // display: not installed" reads as a broken component; "Display: your main
    // display" reads as a choice, which is what it is.
    rows.push_back(status.virtual_display
        ? Row{L"Virtual display",
              status.display_detail.empty() ? L"—" : status.display_detail,
              Mark::Good}
        : Row{L"Display", L"your main display", Mark::NeedsYou});

    for (const Row& row : rows) {
        DrawMark(pad + 4.0f, y + metric::kRowH / 2.0f, row.mark);
        Text(row.label, g_fmt_label,
             D2D1::RectF(pad + space::kLg, y, pad + 150.0f, y + metric::kRowH),
             g_palette.muted);
        Text(row.value, g_fmt_value,
             D2D1::RectF(pad + 150.0f, y, right, y + metric::kRowH),
             row.mark == Mark::Absent ? g_palette.muted : g_palette.text);
        Fill(D2D1::RectF(pad, y + metric::kRowH - 1.0f, right, y + metric::kRowH),
             0.0f, g_palette.rule);
        y += metric::kRowH;
    }
    y += space::kXl;

    // The token answers "what do I type on my Mac", and sits above the buttons
    // because it is read far more often than any button is pressed. It hides
    // itself while a Mac is connected: a visible pairing token beside a live
    // session is an invitation.
    Button* copy = FindButton(kIdCopyToken);
    if (screen.connected || status.pairing_token.empty()) {
        if (g_token_edit) { ShowWindow(g_token_edit, SW_HIDE); }
        if (copy) { copy->visible = false; }
    } else {
        Text(L"Pairing token — the Mac asks for this once", g_fmt_label,
             D2D1::RectF(pad, y, right, y + 18.0f), g_palette.muted);
        y += 18.0f + space::kSm;

        // Copy is a small button beside the field, not a full-width action:
        // 22 DIP of visible ink with a 32 DIP hit rect around it. Reserve its
        // width plus a gutter, or the field runs underneath it — and a child
        // EDIT always paints above Direct2D content, so the overlap is total.
        constexpr float kCopyW = 58.0f;
        const float field_right = right - kCopyW - space::kMd;
        const D2D1_RECT_F field{pad, y, field_right, y + metric::kFieldH};
        const bool field_focus = GetFocus() == g_token_edit;
        Fill(field, metric::kRadiusControl, g_palette.inset);
        Stroke(field, metric::kRadiusControl,
               field_focus ? g_palette.accent : g_palette.hairline);

        // The EDIT sits one DIP inside the drawn rect, so the hairline is ours
        // and never the system's.
        if (g_token_edit) {
            const float scale = g_dpi / 96.0f;
            const float inset = metric::kFieldInset + 6.0f;
            SetWindowPos(g_token_edit, nullptr,
                         (int) ((field.left + inset) * scale),
                         (int) ((field.top + 8.0f) * scale),
                         (int) ((field.right - field.left - inset * 2) * scale),
                         (int) (18.0f * scale),
                         SWP_NOZORDER | SWP_SHOWWINDOW);
        }

        if (copy) {
            const float mid = y + metric::kFieldH / 2.0f;
            copy->rect = D2D1::RectF(right - kCopyW, mid - metric::kCopyVisual / 2.0f,
                                     right, mid + metric::kCopyVisual / 2.0f);
            copy->caption = L"Copy";
            copy->kind = ButtonKind::Secondary;
            copy->visible = true;
            DrawButton(*copy);
        }
        y += metric::kFieldH + space::kLg;
    }

    // The pairing page button only exists while a PIN is waiting on it.
    Button* page = FindButton(kIdOpenPairingPage);
    if (page) {
        page->visible = !pin.empty();
        if (page->visible) {
            page->rect = D2D1::RectF(pad, size.height - pad - metric::kButtonH,
                                     pad + 170.0f, size.height - pad);
            page->caption = L"Open pairing page";
            page->kind = ButtonKind::Secondary;
            DrawButton(*page);
        }
    }

    // The fallback pairing card. Rare, and it has to survive being seen once,
    // so the digits are cells rather than a string: someone is reading this off
    // one screen and typing it on another.
    if (!pin.empty()) {
        const float top = y;
        Text(L"Pairing request", g_fmt_headline,
             D2D1::RectF(pad + space::kMd, top + space::kMd, right - space::kMd,
                         top + space::kMd + 26.0f), g_palette.text);
        const std::wstring who = pin_client.empty() ? L"A Mac" : pin_client;
        Text(who + L" is asking to pair. SolStream couldn't approve it for you, "
                   L"because this PC has its own Sunshine with a password SolStream "
                   L"doesn't know.",
             g_fmt_label,
             D2D1::RectF(pad + space::kMd, top + 44.0f, right - space::kMd,
                         top + 92.0f), g_palette.muted);

        float cell_x = pad + space::kMd;
        const float cell_y = top + 100.0f;
        for (wchar_t digit : pin) {
            const D2D1_RECT_F cell{cell_x, cell_y, cell_x + 56.0f, cell_y + 68.0f};
            Fill(cell, metric::kRadiusControl, g_palette.inset);
            Stroke(cell, metric::kRadiusControl, g_palette.hairline);
            Text(std::wstring(1, digit), g_fmt_pin, cell, g_palette.text,
                 DWRITE_TEXT_ALIGNMENT_CENTER);
            cell_x += 56.0f + space::kSm;
        }
    }

    const HRESULT hr = g_target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        DiscardTarget();
    }
}

// ── Theme ────────────────────────────────────────────────────────────────────

bool SystemPrefersDark() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                      0, KEY_READ, &key) != ERROR_SUCCESS) {
        return true;
    }
    DWORD value = 1;
    DWORD size = sizeof(value);
    DWORD type = 0;
    const bool ok = RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, &type,
                                     (LPBYTE) &value, &size) == ERROR_SUCCESS;
    RegCloseKey(key);
    return ok ? value == 0 : true;
}

/// Follow the system immediately on WM_SETTINGCHANGE — never a restart, and
/// never an in-app theme switch, which would be a second source of truth for
/// something Windows already decides.
void ApplyTheme(HWND window) {
    const bool dark = SystemPrefersDark();
    g_palette = dark ? DarkPalette() : LightPalette();
    const BOOL immersive = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &immersive,
                          sizeof(immersive));
    InvalidateRect(window, nullptr, FALSE);
}

// ── Window ───────────────────────────────────────────────────────────────────

void CopyToClipboard(const std::wstring& text) {
    if (text.empty() || !OpenClipboard(g_window)) {
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

void Activate(HWND window, int id) {
    switch (id) {
        case kIdCopyToken: {
            std::lock_guard<std::mutex> lock(g_mutex);
            CopyToClipboard(g_status.pairing_token);
            break;
        }
        case kIdOpenPairingPage: {
            unsigned short port = 0;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                port = g_status.web_ui_port;
            }
            if (port != 0) {
                const std::wstring url =
                    L"https://localhost:" + std::to_wstring(port) + L"/pin";
                ShellExecuteW(window, L"open", url.c_str(), nullptr, nullptr,
                              SW_SHOWNORMAL);
            }
            break;
        }
        case kIdBannerFix: {
            bool needs_driver = false;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                needs_driver = !g_status.virtual_display;
            }
            if (needs_driver) {
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
            }
            break;
        }
        default:
            break;
    }
}

/// Tab order over the drawn buttons. Hand-rolled because the buttons are, but
/// deliberately the same contract Windows would give: Tab moves, Space and
/// Enter activate, and the ring only appears for keyboard travel.
void MoveFocus(HWND window, int direction) {
    std::vector<int> order;
    for (const Button& button : g_buttons) {
        if (button.visible) {
            order.push_back(button.id);
        }
    }
    if (order.empty()) {
        return;
    }
    size_t index = 0;
    for (size_t i = 0; i < order.size(); ++i) {
        if (order[i] == g_focus) {
            index = i;
            break;
        }
    }
    if (g_focus == 0) {
        index = direction > 0 ? 0 : order.size() - 1;
    } else {
        index = (index + order.size() + (direction > 0 ? 1 : -1)) % order.size();
    }
    g_focus = order[index];
    g_keyboard_nav = true;
    SetFocus(window);
    InvalidateRect(window, nullptr, FALSE);
}

float ToDip(int pixels) { return pixels * 96.0f / g_dpi; }

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
        case WM_CREATE: {
            g_dpi = (float) GetDpiForWindow(window);
            g_buttons.clear();
            g_buttons.push_back({kIdBannerFix, L"", ButtonKind::Primary, false, {}, false});
            g_buttons.push_back({kIdCopyToken, L"Copy", ButtonKind::Secondary, false, {}, false});
            g_buttons.push_back({kIdOpenPairingPage, L"Open pairing page",
                                 ButtonKind::Secondary, false, {}, false});

            // Read-only, not disabled: disabled text cannot be selected, and
            // selecting the token is the entire point of the field.
            g_token_edit = CreateWindowExW(
                0, L"EDIT", L"",
                WS_CHILD | ES_AUTOHSCROLL | ES_READONLY,
                0, 0, 10, 10, window, (HMENU) (INT_PTR) kEditId, nullptr, nullptr);
            // Cascadia Mono, sized in the same DIPs as everything else. A token
            // in the proportional UI font is a token whose characters cannot be
            // told apart when somebody reads it aloud.
            g_edit_font = CreateFontW(
                -(int) (type::kValue * g_dpi / 96.0f), 0, 0, 0, FW_NORMAL, FALSE,
                FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN,
                L"Cascadia Mono");
            SendMessageW(g_token_edit, WM_SETFONT, (WPARAM) g_edit_font, TRUE);

            // Mica, so the window sits in the system's own material rather than
            // pretending to be a flat rectangle on top of it.
            const int backdrop = DWMSBT_MAINWINDOW;
            DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                                  sizeof(backdrop));
            ApplyTheme(window);
            SetTimer(window, kTimerId, 1000, nullptr);
            return 0;
        }

        case WM_MOUSEMOVE: {
            const float x = ToDip(GET_X_LPARAM(lparam));
            const float y = ToDip(GET_Y_LPARAM(lparam));
            int hot = 0;
            for (const Button& button : g_buttons) {
                if (HitButton(button, x, y)) {
                    hot = button.id;
                    break;
                }
            }
            if (hot != g_hot) {
                g_hot = hot;
                InvalidateRect(window, nullptr, FALSE);
                TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, window, 0};
                TrackMouseEvent(&track);
            }
            return 0;
        }

        case WM_MOUSELEAVE:
            g_hot = 0;
            InvalidateRect(window, nullptr, FALSE);
            return 0;

        case WM_LBUTTONDOWN: {
            const float x = ToDip(GET_X_LPARAM(lparam));
            const float y = ToDip(GET_Y_LPARAM(lparam));
            g_pressed = 0;
            for (const Button& button : g_buttons) {
                if (HitButton(button, x, y)) {
                    g_pressed = button.id;
                    g_focus = button.id;
                    g_keyboard_nav = false;  // a click must not leave a ring
                    break;
                }
            }
            SetFocus(window);
            SetCapture(window);
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_LBUTTONUP: {
            const int pressed = g_pressed;
            g_pressed = 0;
            ReleaseCapture();
            const float x = ToDip(GET_X_LPARAM(lparam));
            const float y = ToDip(GET_Y_LPARAM(lparam));
            if (pressed != 0) {
                if (const Button* button = FindButton(pressed)) {
                    if (HitButton(*button, x, y)) {
                        Activate(window, pressed);
                    }
                }
            }
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_KEYDOWN: {
            if (wparam == VK_TAB) {
                MoveFocus(window, (GetKeyState(VK_SHIFT) & 0x8000) ? -1 : 1);
                return 0;
            }
            if ((wparam == VK_SPACE || wparam == VK_RETURN) && g_focus != 0) {
                Activate(window, g_focus);
                return 0;
            }
            break;
        }

        case WM_GETDLGCODE:
            // Tab and Enter belong to this window, not to a dialog manager.
            return DLGC_WANTALLKEYS;

        // WM_CTLCOLORSTATIC as well, and it is the one that matters: a READ-ONLY
        // edit is coloured through the STATIC message, not the EDIT one. Handling
        // only WM_CTLCOLOREDIT leaves the field stock white on a near-black
        // window — which is exactly what it did.
        case WM_CTLCOLORSTATIC:
        case WM_CTLCOLOREDIT: {
            // The field's ground and ink come from the drawn surface around it,
            // so the EDIT never looks like a system control that wandered in.
            auto dc = (HDC) wparam;
            const D2D1_COLOR_F& bg = g_palette.inset;
            const D2D1_COLOR_F& fg = g_palette.text;
            static HBRUSH brush = nullptr;
            if (brush) { DeleteObject(brush); }
            brush = CreateSolidBrush(RGB((int) (bg.r * 255), (int) (bg.g * 255),
                                         (int) (bg.b * 255)));
            SetBkColor(dc, RGB((int) (bg.r * 255), (int) (bg.g * 255),
                               (int) (bg.b * 255)));
            SetTextColor(dc, RGB((int) (fg.r * 255), (int) (fg.g * 255),
                                 (int) (fg.b * 255)));
            return (LRESULT) brush;
        }

        case WM_SETTINGCHANGE:
            if (lparam && wcscmp((const wchar_t*) lparam, L"ImmersiveColorSet") == 0) {
                ApplyTheme(window);
            }
            return 0;

        case WM_DPICHANGED: {
            g_dpi = (float) HIWORD(wparam);
            if (g_target) {
                g_target->SetDpi(g_dpi, g_dpi);
            }
            const RECT* suggested = (const RECT*) lparam;
            SetWindowPos(window, nullptr, suggested->left, suggested->top,
                         suggested->right - suggested->left,
                         suggested->bottom - suggested->top,
                         SWP_NOZORDER | SWP_NOACTIVATE);
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_SIZE:
            if (g_target) {
                g_target->Resize(D2D1::SizeU(LOWORD(lparam), HIWORD(lparam)));
            }
            return 0;

        case WM_TIMER:
            InvalidateRect(window, nullptr, FALSE);
            return 0;

        case WM_ERASEBKGND:
            return 1;  // the render target covers the whole client area

        case WM_PAINT: {
            PAINTSTRUCT paint{};
            BeginPaint(window, &paint);
            LayoutAndPaint(window);
            EndPaint(window, &paint);
            return 0;
        }

        case WM_CLOSE:
            // Closing ends the session deliberately. A host that goes on
            // streaming after its window is gone is one nobody can find again
            // to turn off.
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                g_closed = true;
            }
            DestroyWindow(window);
            return 0;

        case WM_DESTROY:
            DiscardTarget();
            PostQuitMessage(0);
            return 0;

        default:
            break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

bool ShowHostWindow() {
    if (!CreateDeviceIndependentResources()) {
        return false;
    }

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = kClassName;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    if (!RegisterClassExW(&wc)) {
        return false;
    }

    const UINT dpi = GetDpiForSystem();
    const int width = MulDiv((int) metric::kWindowW, dpi, 96);
    const int height = MulDiv((int) metric::kWindowH, dpi, 96);
    RECT wanted{0, 0, width, height};
    AdjustWindowRectExForDpi(&wanted, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE,
                             0, dpi);
    g_window = CreateWindowExW(
        0, kClassName, L"SolStream",
        // Not resizable: every part of this is a fixed-height card, and a
        // window draggable to a shape none of its content fits is worse than
        // one that cannot be dragged at all.
        WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX,
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
        if (g_token_edit) {
            SetWindowTextW(g_token_edit, status.pairing_token.c_str());
        }
        InvalidateRect(g_window, nullptr, FALSE);
    }
}

void ShowPairingPin(const std::wstring& pin, const std::wstring& client_name) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_pending_pin = pin;
        g_pending_client = client_name;
    }
    if (!g_window) {
        return;
    }
    // Grow the existing window rather than opening a second one, and flash the
    // taskbar — but never steal the foreground, because somebody is typing
    // somewhere and this is not worth taking their keystrokes for.
    const float wanted = pin.empty() ? metric::kWindowH : metric::kWindowH + 200.0f;
    const UINT dpi = (UINT) g_dpi;
    RECT frame{0, 0, MulDiv((int) metric::kWindowW, dpi, 96),
               MulDiv((int) wanted, dpi, 96)};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE,
                             0, dpi);
    SetWindowPos(g_window, nullptr, 0, 0, frame.right - frame.left,
                 frame.bottom - frame.top, SWP_NOMOVE | SWP_NOZORDER);
    if (!pin.empty()) {
        ShowWindow(g_window, SW_SHOW);
        FlashWindow(g_window, TRUE);
    }
    InvalidateRect(g_window, nullptr, TRUE);
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
