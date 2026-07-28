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

#include <algorithm>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "display_setup.h"
#include "host_theme.h"
#include "installer.h"
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
/// Setup gets its OWN class, and the reason is not tidiness.
///
/// The installed agent starts by asking whether SolStream is already running,
/// by looking for a window of the host class, and bows out if one is — that is
/// what makes a shortcut press show the window instead of starting a second
/// agent to fight the first for the port. Sharing one class made the setup
/// window answer that question: the agent the install had just started found
/// setup's window, decided SolStream was already running, and exited. So did
/// the one behind the "Open SolStream" button. The install completed perfectly
/// and left nothing running, which is the hardest kind of failure to see —
/// every step reported success.
constexpr wchar_t kSetupClassName[] = L"SolStreamSetupWindow";
constexpr UINT kTimerId = 1;
constexpr int kEditId = 200;

/// Posted by the worker thread when a long job finishes. wparam is non-zero on
/// success. Work does not happen on the UI thread: installing waits on a UAC
/// prompt and then on a second process, and a window that stops repainting while
/// it does that is a window Windows offers to close for you.
constexpr UINT WM_SOLSTREAM_JOB_DONE = WM_APP + 1;
/// Posted while a job is still going, carrying a sentence for the working
/// phase to show. lparam owns a std::wstring the UI thread deletes.
constexpr UINT WM_SOLSTREAM_JOB_STEP = WM_APP + 2;

// ── Shared state ─────────────────────────────────────────────────────────────

std::mutex g_mutex;
HostStatus g_status;
std::wstring g_pending_pin;
std::wstring g_pending_client;
bool g_closed = false;

/// Which face the window is showing, fixed at creation.
WindowMode g_mode = WindowMode::Host;

/// Where setup has got to. Setup, uninstall and the display-driver button all
/// have the same shape — choose, work, then say what happened — so they share
/// one state machine rather than each inventing their own.
enum class Phase { Choosing, Working, Done, Failed };
Phase g_phase = Phase::Choosing;
std::wstring g_step;      ///< what the working phase is doing right now
std::wstring g_outcome;   ///< the sentence shown when it finishes, either way
bool g_job_running = false;

/// A one-off message the Host window shows in place of its usual banner — the
/// result of pressing a button, which used to be a MessageBox. A modal system
/// dialog in the middle of a window this carefully drawn is the one thing that
/// gives away that the rest of it was drawn at all.
std::wstring g_notice;
std::wstring g_notice_detail;

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

/// How tall this text is when wrapped to `width`, in DIPs.
///
/// Every block on this window used to be given a height picked by eye — the
/// banner's reason got 40 DIP, two lines' worth. The real strings run to four,
/// and because every format here is vertically centred, a four-line block in a
/// two-line box does not simply overflow downwards: it centres, so its first
/// lines are drawn UP THROUGH the sentence above it and its last lines are
/// clipped away. It reads as two paragraphs printed on top of each other, and
/// only for the longest string, which is the one that matters most.
/// `designed` is the height the design gives this block. It is honoured when the
/// text fits inside it, so the window keeps the rhythm it was drawn with, and
/// exceeded only when the alternative is losing words.
float MeasureHeight(const std::wstring& text, IDWriteTextFormat* format, float width,
                    float designed = 0.0f) {
    if (!format || text.empty() || width <= 0.0f) {
        return designed;
    }
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(g_dwrite->CreateTextLayout(text.c_str(), (UINT32) text.size(), format,
                                          width, 4096.0f, &layout))
        || layout == nullptr) {
        return 0.0f;
    }
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    layout->Release();
    return metrics.height > designed ? metrics.height : designed;
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

/// The mark: a hairline frame with a solid accent rect straddling its right
/// edge — the host display, and the application half out of it.
///
/// Drawn rather than loaded from the .ico beside it, because this is the only
/// place it appears at a size Windows has no artboard for, and because at 34
/// DIP on a 200% display it wants 68 real pixels: a scaled 48px icon there is
/// visibly soft next to text DirectWrite has hinted. Two rounded rectangles
/// cost less than the code to pick the right icon size would.
///
/// With its tile, which is not decoration: the mark's artwork occupies the
/// middle 48% of the tile, so without one it reads as a small glyph floating
/// beside large type rather than as the application's icon. Every lockup in the
/// design shows the tile, on light grounds as well as dark.
void DrawLogo(const D2D1_RECT_F& box) {
    const float side = box.bottom - box.top;
    const float stroke = side < 24.0f ? 1.0f : side / 17.0f;

    // The design's own light-ground lockup, not the dark one inverted: on a
    // light ground the tile lightens, the frame darkens toward the text, and the
    // accent goes to its 700 step so a solid block of it still holds its
    // contrast against a near-white card.
    const D2D1_COLOR_F tile = g_palette.dark ? Hex(0x232532) : Hex(0xe4e7f5);
    const D2D1_COLOR_F tileEdge = g_palette.dark ? Hex(0x3f424d) : Hex(0xcfd3e5);
    const D2D1_COLOR_F frameInk = g_palette.dark ? Hex(0x595d6c) : Hex(0x9397ab);
    const D2D1_COLOR_F accentInk = g_palette.dark ? Hex(0x9184d9) : Hex(0x5d5294);

    // 22.4% — the macOS squircle radius, which is also what the tile is drawn at
    // everywhere it appears beside the wordmark.
    Fill(box, side * 0.224f, tile);
    Stroke(box, side * 0.224f, tileEdge);

    // The same fractions the icon artboards use, so the wordmark's companion and
    // the taskbar icon are the same drawing rather than two things that look
    // alike. See assets/logo/make-logo.swift.
    const D2D1_RECT_F frame{box.left + side * 0.15f + stroke / 2,
                            box.top + side * 0.26f + stroke / 2,
                            box.left + side * 0.60f - stroke / 2,
                            box.top + side * 0.74f - stroke / 2};
    g_brush->SetColor(frameInk);
    g_target->DrawRoundedRectangle(
        D2D1::RoundedRect(frame, side * 0.055f, side * 0.055f), g_brush, stroke);

    // Drawn second, so it covers the frame's right edge. The overlap IS the
    // mark — a window that crossed a boundary and stopped being remote.
    const D2D1_RECT_F accent{box.left + side * 0.44f, box.top + side * 0.38f,
                             box.left + side * 0.85f, box.top + side * 0.74f};
    g_brush->SetColor(accentInk);
    g_target->FillRoundedRectangle(
        D2D1::RoundedRect(accent, side * 0.047f, side * 0.047f), g_brush);
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
    // Setup and uninstall. Kept in the same list and the same tab order as the
    // rest, because they are the same kind of control on the same window.
    kIdInstall,
    kIdCancel,
    kIdOpenApp,
    kIdClose,
    kIdRetry,
    kIdRemove,
    // The tick boxes on the setup screen, in the order they are drawn.
    kIdCheckDesktop = 100,
    kIdCheckStartMenu,
    kIdCheckLogon,
};

/// A tick box. Drawn rather than a real BUTTON control for the same reason the
/// buttons are: the design specifies its resting, hover, checked and focused
/// colours in literal hex, and a stock checkbox honours none of them.
struct Check {
    int id = 0;
    const wchar_t* caption = L"";
    const wchar_t* detail = L"";
    bool checked = true;
    bool visible = false;
    D2D1_RECT_F rect{};  ///< the whole row, so the label is clickable too
};

std::vector<Check> g_checks;

Check* FindCheck(int id) {
    for (Check& check : g_checks) {
        if (check.id == id) {
            return &check;
        }
    }
    return nullptr;
}

bool CheckedById(int id) {
    const Check* check = FindCheck(id);
    return check != nullptr && check->checked;
}

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

bool HitCheck(const Check& check, float x, float y) {
    return check.visible && x >= check.rect.left && x <= check.rect.right
           && y >= check.rect.top && y <= check.rect.bottom;
}

void DrawCheck(const Check& check) {
    if (!check.visible) {
        return;
    }
    constexpr float kBox = 18.0f;
    const bool hot = g_hot == check.id;
    const bool focused = g_focus == check.id && g_keyboard_nav;

    const float top = check.rect.top + (metric::kRowH - kBox) / 2.0f;
    const D2D1_RECT_F box{check.rect.left, top, check.rect.left + kBox, top + kBox};

    if (check.checked) {
        Fill(box, metric::kRadiusControl,
             hot ? g_palette.accentHover : g_palette.accent);
        // The tick, two strokes. A glyph would need a font that has one at this
        // size and would sit a pixel off centre on half the machines that do.
        g_brush->SetColor(g_palette.onAccent);
        const float l = box.left;
        const float t = box.top;
        g_target->DrawLine(D2D1::Point2F(l + 4.0f, t + 9.0f),
                           D2D1::Point2F(l + 7.5f, t + 12.5f), g_brush, 2.0f);
        g_target->DrawLine(D2D1::Point2F(l + 7.5f, t + 12.5f),
                           D2D1::Point2F(l + 14.0f, t + 5.5f), g_brush, 2.0f);
    } else {
        Stroke(box, metric::kRadiusControl,
               hot ? g_palette.accent : g_palette.hairlineStrong, 1.5f);
    }

    const float text_left = check.rect.left + kBox + space::kMd;
    Text(check.caption, g_fmt_value,
         D2D1::RectF(text_left, check.rect.top, check.rect.right,
                     check.rect.top + metric::kRowH),
         hot ? g_palette.accentTintInk : g_palette.text);

    if (focused) {
        FocusRing(box, metric::kRadiusControl);
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

    // What a button just did, said in the window rather than in a system dialog
    // that knows nothing about this program's theme. It outranks the driver
    // advisory below, because it is the answer to the button that advisory
    // offered — showing the question again underneath its own answer would be
    // absurd — but not the two hard failures above, which are still true.
    if (!g_notice.empty()) {
        screen.what = g_notice;
        screen.why = g_notice_detail;
        // Nothing to dismiss until it has finished saying it.
        screen.fix = g_job_running ? L"" : L"OK";
        screen.shield = false;
        return screen;
    }

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

/// The horizontal lockup: mark, gap, wordmark.
///
/// The design fixes the relationship rather than the sizes — the mark's artwork
/// is as tall as the wordmark's cap height, and the gap between them is that
/// height divided by 2.5. Segoe UI Variable's cap height is 0.7 of its em, so
/// the 28 DIP wordmark wants 19.6 DIP of artwork; the artwork is the middle 48%
/// of the tile, so the tile is 19.6 / 0.48 = 41. That is also the design's own
/// lockup proportion — a 44 tile against 30 type — arrived at from the other
/// end, which is the check that the rule and the drawing agree.
constexpr float kLockupMark = 41.0f;
constexpr float kLockupH = 42.0f;

void DrawLockup(float left, float top, float right) {
    const float mark_top = top + (kLockupH - kLockupMark) / 2.0f;
    DrawLogo(D2D1::RectF(left, mark_top, left + kLockupMark, mark_top + kLockupMark));
    const float gap = kLockupMark * 0.48f / 2.5f;
    Text(L"SolStream", g_fmt_wordmark,
         D2D1::RectF(left + kLockupMark + gap, top, right, top + kLockupH),
         g_palette.text);
}

/// Make the window tall enough for what was just laid out.
///
/// The design fixes the window at 460x560 and every block inside it at a height
/// chosen for the string that was in it when it was drawn. Real strings are
/// longer on some machines than others — a longer computer name, a failure with
/// a reason attached, a translated sentence — and a window that cannot grow
/// answers that by clipping the sentence that explains what went wrong.
///
/// Only ever grows, and only by more than a DIP, so this cannot oscillate with
/// the WM_SIZE it causes.
void GrowToFit(HWND window, float content_bottom) {
    if (!g_target) {
        return;
    }
    const float wanted = content_bottom + space::kXl;
    if (wanted <= g_target->GetSize().height + 1.0f) {
        return;
    }
    const UINT dpi = (UINT) g_dpi;
    RECT frame{0, 0, MulDiv((int) metric::kWindowW, dpi, 96),
               MulDiv((int) wanted, dpi, 96)};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE, 0, dpi);
    SetWindowPos(window, nullptr, 0, 0, frame.right - frame.left,
                 frame.bottom - frame.top, SWP_NOMOVE | SWP_NOZORDER);
}

void HideAllControls() {
    for (Button& button : g_buttons) {
        button.visible = false;
    }
    for (Check& check : g_checks) {
        check.visible = false;
    }
}

/// The setup and uninstall faces. Same four phases either way — choose, work,
/// then say what happened — so they are one screen with different words rather
/// than two screens that would drift.
struct SetupCopy {
    std::wstring headline;
    std::wstring lead;
    std::vector<const wchar_t*> bullets;
    std::wstring go;       ///< the primary button; empty in the working phase
    bool shield = false;
};

SetupCopy CopyForPhase() {
    const bool removing = g_mode == WindowMode::Uninstall;
    SetupCopy copy;
    switch (g_phase) {
        case Phase::Choosing:
            if (removing) {
                copy.headline = L"Remove SolStream from this PC?";
                copy.lead = L"This takes back everything setup put here.";
                copy.bullets = {
                    L"Removes the program and its shortcuts",
                    L"Deletes the firewall rules it added",
                    L"Keeps your pairing token, so a reinstall won't make your "
                    L"Mac pair again",
                };
                copy.go = L"Remove";
            } else {
                copy.headline = L"Install SolStream on this PC.";
                copy.lead = L"Afterwards your Mac can open one application from here.";
                copy.bullets = {
                    L"Copies SolStream to Program Files",
                    L"Opens the five ports your Mac needs, and nothing else",
                    L"Includes everything it streams with — nothing else to download",
                };
                copy.go = L"Install";
            }
            copy.shield = true;
            break;
        case Phase::Working:
            copy.headline = removing ? L"Removing SolStream…" : L"Installing SolStream…";
            copy.lead = g_step;
            break;
        case Phase::Done:
            copy.headline = removing ? L"SolStream has been removed."
                                     : L"SolStream is installed.";
            copy.lead = g_outcome;
            break;
        case Phase::Failed:
            copy.headline = removing ? L"Removing SolStream didn't finish."
                                     : L"Setup didn't finish.";
            copy.lead = g_outcome;
            break;
    }
    return copy;
}

/// An indeterminate bar. Deliberately not a percentage: the work happens in a
/// second, elevated process that reports nothing until it exits, and a bar that
/// invents a number is a bar that sits at 90% for the last two seconds every
/// time. This one only claims that something is still happening.
void DrawWorkingBar(float left, float top, float right) {
    constexpr float kHeight = 4.0f;
    constexpr unsigned kPeriod = 1600;
    const D2D1_RECT_F track{left, top, right, top + kHeight};
    Fill(track, kHeight / 2.0f, g_palette.inset);

    const float width = right - left;
    const float segment = width * 0.32f;
    const float phase = (float) (GetTickCount64() % kPeriod) / (float) kPeriod;
    // Travels from fully off the left to fully off the right, then clips to the
    // track, so it enters and leaves rather than appearing mid-way.
    const float start = left - segment + phase * (width + segment);
    const D2D1_RECT_F bar{start < left ? left : start, top,
                          start + segment > right ? right : start + segment,
                          top + kHeight};
    if (bar.right > bar.left) {
        Fill(bar, kHeight / 2.0f, g_palette.accent);
    }
}

void LayoutAndPaintSetup(HWND window) {
    if (!EnsureTarget(window)) {
        return;
    }
    const SetupCopy copy = CopyForPhase();
    const D2D1_SIZE_F size = g_target->GetSize();
    const float pad = space::kXl;
    const float right = size.width - pad;

    g_target->BeginDraw();
    g_target->Clear(g_palette.ground);
    HideAllControls();

    float y = pad;
    DrawLockup(pad, y, right);
    y += kLockupH + space::kMd;

    const float headline_h = MeasureHeight(copy.headline, g_fmt_headline,
                                           right - pad, 52.0f);
    Text(copy.headline, g_fmt_headline,
         D2D1::RectF(pad, y, right, y + headline_h), g_palette.text);
    y += headline_h + space::kLg;

    // The card. In the choosing phase it says what is about to happen, which is
    // the whole of the consent the UAC prompt is about to ask for in the
    // abstract; in the others it says what is happening or what happened — and
    // a failure's reason is the longest string this window ever holds, so it is
    // measured rather than allotted a height that fits the happy path.
    const float kLeadH = MeasureHeight(copy.lead, g_fmt_value,
                                       right - pad - space::kMd * 2.0f, 44.0f);
    // Per bullet, not one height for all of them. "Keeps your pairing token, so
    // a reinstall won't make your Mac pair again" wraps to two lines and ran
    // straight out of the bottom of the card.
    const float bullet_w = right - pad - space::kMd - space::kLg;
    std::vector<float> bullet_h;
    float bullets_h = 0.0f;
    for (const wchar_t* bullet : copy.bullets) {
        bullet_h.push_back(MeasureHeight(bullet, g_fmt_label, bullet_w, 24.0f));
        bullets_h += bullet_h.back();
    }
    const bool working = g_phase == Phase::Working;
    const float card_h = space::kMd + kLeadH
                       + (copy.bullets.empty() ? 0.0f : space::kSm + bullets_h)
                       + (working ? space::kMd + 4.0f : 0.0f)
                       + space::kMd;
    const float card_top = y;
    Fill(D2D1::RectF(pad, card_top, right, card_top + card_h), metric::kRadiusCard,
         g_palette.card);
    Stroke(D2D1::RectF(pad, card_top, right, card_top + card_h), metric::kRadiusCard,
           g_palette.hairlineStrong);

    float inner = card_top + space::kMd;
    Text(copy.lead, g_fmt_value,
         D2D1::RectF(pad + space::kMd, inner, right - space::kMd, inner + kLeadH),
         g_palette.text);
    inner += kLeadH;

    if (!copy.bullets.empty()) {
        inner += space::kSm;
        for (size_t i = 0; i < copy.bullets.size(); ++i) {
            const float height = bullet_h[i];
            // The mark sits on the first line rather than in the middle of the
            // block, so a two-line bullet does not put its dot beside the gap.
            DrawMark(pad + space::kMd + 4.0f, inner + 12.0f, Mark::Good);
            Text(copy.bullets[i], g_fmt_label,
                 D2D1::RectF(pad + space::kMd + space::kLg, inner, right - space::kMd,
                             inner + height),
                 g_palette.muted);
            inner += height;
        }
    }
    if (working) {
        inner += space::kMd;
        DrawWorkingBar(pad + space::kMd, inner, right - space::kMd);
    }
    y = card_top + card_h + space::kXl;

    // The tick boxes, only while there is still a choice to make and only when
    // installing — there is nothing optional about removing something.
    if (g_phase == Phase::Choosing && g_mode == WindowMode::Setup) {
        Text(L"Also", g_fmt_label, D2D1::RectF(pad, y, right, y + 18.0f),
             g_palette.muted);
        y += 18.0f + space::kXs;
        for (Check& check : g_checks) {
            check.visible = true;
            check.rect = D2D1::RectF(pad + metric::kFocusClearance, y,
                                     right, y + metric::kRowH);
            DrawCheck(check);
            y += metric::kRowH;
        }
        y += space::kLg;

        Text(L"Installs to " + InstallDirectory(), g_fmt_mono,
             D2D1::RectF(pad, y, right, y + 18.0f), g_palette.faint);
        y += 18.0f;
    }
    // The buttons are anchored to the bottom edge, so growing for the content
    // has to leave room for them as well or a long failure message runs
    // underneath them.
    const float content_bottom = y + space::kLg + metric::kButtonH;

    // The buttons sit on the bottom edge, where a setup program's buttons are.
    const float button_top = size.height - pad - metric::kButtonH;
    float button_left = pad;
    auto place = [&](int id, const std::wstring& caption, ButtonKind kind,
                     bool shield) {
        Button* button = FindButton(id);
        if (!button) {
            return;
        }
        const float width = metric::kButtonMinW + (shield ? metric::kShieldExtra : 0.0f);
        button->rect = D2D1::RectF(button_left, button_top, button_left + width,
                                   button_top + metric::kButtonH);
        button->caption = caption;
        button->kind = kind;
        button->shield = shield;
        button->visible = true;
        DrawButton(*button);
        button_left += width + space::kMd;
    };

    switch (g_phase) {
        case Phase::Choosing:
            place(g_mode == WindowMode::Uninstall ? kIdRemove : kIdInstall, copy.go,
                  ButtonKind::Primary, copy.shield);
            place(kIdCancel, L"Cancel", ButtonKind::Secondary, false);
            break;
        case Phase::Working:
            break;  // nothing to press, and a greyed button is still a target
        case Phase::Done:
            if (g_mode == WindowMode::Setup) {
                place(kIdOpenApp, L"Open SolStream", ButtonKind::Primary, false);
            }
            place(kIdClose, L"Close", ButtonKind::Secondary, false);
            break;
        case Phase::Failed:
            place(kIdRetry, L"Try again", ButtonKind::Primary, copy.shield);
            place(kIdClose, L"Close", ButtonKind::Secondary, false);
            // The log is the one thing worth asking for when this goes wrong on
            // a machine nobody was watching, so its path is on screen and not in
            // a support article.
            Text(InstallLogPath(), g_fmt_mono,
                 D2D1::RectF(pad, button_top - 22.0f, right, button_top - 4.0f),
                 g_palette.faint);
            break;
    }

    const HRESULT hr = g_target->EndDraw();
    if (hr == D2DERR_RECREATE_TARGET) {
        DiscardTarget();
        return;
    }
    GrowToFit(window, content_bottom);
}

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
    HideAllControls();

    float y = pad;

    // The lockup: the mark, then the wordmark in Segoe UI Variable Display at a
    // real 500 axis stop.
    DrawLockup(pad, y, right);
    y += kLockupH + space::kMd;

    // The headline answers "is this PC ready" before anything else is read.
    const float headline_h = MeasureHeight(screen.headline, g_fmt_headline,
                                           right - pad, 52.0f);
    Text(screen.headline, g_fmt_headline,
         D2D1::RectF(pad, y, right, y + headline_h), g_palette.text);
    y += headline_h + space::kLg;

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
        const float text_w = right - pad - space::kMd * 2.0f;
        const float kWhatH = MeasureHeight(screen.what, g_fmt_value, text_w, 22.0f);
        const float kWhyH = MeasureHeight(screen.why, g_fmt_label, text_w, 40.0f);
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
    const float content_bottom = y;

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
        return;
    }
    // After EndDraw, never during it: resizing invalidates the render target
    // this function is holding.
    if (pin.empty()) {
        GrowToFit(window, content_bottom);
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

// ── Long jobs ────────────────────────────────────────────────────────────────
//
// Installing waits on a UAC prompt and then on a second process; setting a
// display up cycles a device and sleeps through it. Neither can run on the UI
// thread — a window that stops answering messages for six seconds is one Windows
// offers to close for you, greyed out and titled "not responding", at exactly
// the moment the user is deciding whether this program is trustworthy.
//
// The worker never touches the state the painter reads. It says what it is doing
// by posting a string, which the UI thread takes ownership of and deletes; that
// is the whole synchronisation, and there is nothing to lock.

std::wstring Widen(const std::string& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0);
    std::wstring out((size_t) needed, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(), out.data(), needed);
    return out;
}

void PostStep(HWND window, const std::wstring& text) {
    PostMessageW(window, WM_SOLSTREAM_JOB_STEP, 0, (LPARAM) new std::wstring(text));
}

void PostDone(HWND window, bool ok, const std::wstring& text) {
    PostMessageW(window, WM_SOLSTREAM_JOB_DONE, ok ? 1 : 0,
                 (LPARAM) new std::wstring(text));
}

void StartInstallJob(HWND window) {
    if (g_job_running) {
        return;
    }
    // Read the ticks here, on the UI thread that owns them, and hand the worker
    // a copy. Reaching back into the controls from the other thread would be a
    // race for no reason.
    InstallOptions options;
    options.desktop_shortcut = CheckedById(kIdCheckDesktop);
    options.start_menu_shortcut = CheckedById(kIdCheckStartMenu);
    options.start_at_logon = CheckedById(kIdCheckLogon);

    g_job_running = true;
    g_phase = Phase::Working;
    g_step = L"Waiting for you to allow this in the Windows prompt…";
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window, options] {
        std::string error;
        bool ok = false;
        if (IsElevated()) {
            ok = InstallSelf(options, error);
        } else {
            // The elevated half is this same executable running its install
            // path. It cannot report back through a return value, so it leaves
            // its reason in a file.
            if (RelaunchElevated(L"--install" + OptionArguments(options), error)) {
                ok = ReadInstallResult(error);
            }
        }
        PostDone(window, ok,
                 ok ? L"Open SolStream on your Mac and pick this PC. It asks for a "
                      L"pairing token once, and SolStream's window on this PC shows it."
                    : Widen(error));
    }).detach();
}

void StartUninstallJob(HWND window) {
    if (g_job_running) {
        return;
    }
    g_job_running = true;
    g_phase = Phase::Working;
    g_step = L"Waiting for you to allow this in the Windows prompt…";
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window] {
        std::string error;
        bool ok = false;
        if (IsElevated()) {
            ok = UninstallSelf(error);
        } else if (RelaunchElevated(L"--uninstall --now", error)) {
            ok = ReadInstallResult(error);
        }
        PostDone(window, ok,
                 ok ? L"Your pairing token and settings are still here, so "
                      L"installing SolStream again won't make your Mac pair twice."
                    : Widen(error));
    }).detach();
}

/// Install the display driver and then actually set it up.
///
/// The second half is the part that was missing. Installing the driver on its
/// own leaves a display with the wrong mode list, the wrong scaling and HDR
/// turned on — and that last one is why streamed content used to arrive as a
/// black rectangle with its window chrome drawn correctly around it.
void StartDisplayJob(HWND window) {
    if (g_job_running) {
        return;
    }
    g_job_running = true;
    g_notice = L"Setting the virtual display up…";
    g_notice_detail = L"Installing the driver.";
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window] {
        std::string error;
        if (!InstallBundledDriver(error)) {
            PostDone(window, false, Widen(error));
            return;
        }
        PostStep(window, L"Setting its size and colour up. The screen may blink.");
        std::string note;
        std::string configure_error;
        const bool ok = ConfigureVirtualDisplay(kDefaultCanvasWidth,
                                                kDefaultCanvasHeight,
                                                kDefaultScalePercent, note,
                                                configure_error);
        PostDone(window, ok, Widen(ok ? note : configure_error));
    }).detach();
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
            // Doubles as the notice's "OK": if there is something being said,
            // this button dismisses it rather than starting the job again.
            if (!g_notice.empty()) {
                g_notice.clear();
                g_notice_detail.clear();
                InvalidateRect(window, nullptr, FALSE);
                break;
            }
            bool needs_driver = false;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                needs_driver = !g_status.virtual_display;
            }
            if (needs_driver) {
                StartDisplayJob(window);
            }
            break;
        }

        case kIdInstall:
        case kIdRetry:
            StartInstallJob(window);
            break;

        case kIdRemove:
            StartUninstallJob(window);
            break;

        case kIdOpenApp: {
            // The install already started the agent through its logon task, so
            // this normally finds a running window and brings it forward; the
            // installed executable's single-instance check does that for us.
            const std::wstring exe = InstallDirectory() + L"\\SolStream.exe";
            ShellExecuteW(nullptr, L"open", exe.c_str(), nullptr, nullptr,
                          SW_SHOWNORMAL);
            PostMessageW(window, WM_CLOSE, 0, 0);
            break;
        }

        case kIdCancel:
        case kIdClose:
            PostMessageW(window, WM_CLOSE, 0, 0);
            break;

        default:
            if (Check* check = FindCheck(id)) {
                check->checked = !check->checked;
                InvalidateRect(window, nullptr, FALSE);
            }
            break;
    }
}

/// Tab order over the drawn buttons. Hand-rolled because the buttons are, but
/// deliberately the same contract Windows would give: Tab moves, Space and
/// Enter activate, and the ring only appears for keyboard travel.
void MoveFocus(HWND window, int direction) {
    // Reading order, taken from where the controls actually ARE.
    //
    // This used to walk the vectors in the order controls were pushed into
    // them, which is a fact about the code and not about the window. On the
    // uninstall screen that put Cancel before Remove — so the first Tab landed
    // on Cancel, and anyone driving this from the keyboard pressed Space
    // expecting to remove SolStream and closed the window instead. It only
    // worked anywhere else by coincidence.
    struct Stop { int id; float top; float left; };
    std::vector<Stop> stops;
    for (const Check& check : g_checks) {
        if (check.visible) {
            stops.push_back({check.id, check.rect.top, check.rect.left});
        }
    }
    for (const Button& button : g_buttons) {
        if (button.visible) {
            stops.push_back({button.id, button.rect.top, button.rect.left});
        }
    }
    std::sort(stops.begin(), stops.end(), [](const Stop& a, const Stop& b) {
        // A row's worth of tolerance, so two buttons side by side are ordered
        // left to right even when their tops differ by a rounding error.
        if (a.top + 4.0f < b.top) { return true; }
        if (b.top + 4.0f < a.top) { return false; }
        return a.left < b.left;
    });
    std::vector<int> order;
    order.reserve(stops.size());
    for (const Stop& stop : stops) {
        order.push_back(stop.id);
    }
    if (order.empty()) {
        return;
    }
    // Where the focus is NOW, and whether it is anywhere at all. The second
    // half matters: a control can vanish under the focus when the screen
    // changes phase -- press Remove, the job fails, and the Remove button is
    // replaced by Try again and Close. Treating a stale id as "index 0" and
    // advancing from it silently skipped the first button, so the next Tab
    // landed on Close and closing was one keystroke from where retrying should
    // have been.
    size_t index = 0;
    bool focused = false;
    for (size_t i = 0; i < order.size(); ++i) {
        if (order[i] == g_focus) {
            index = i;
            focused = true;
            break;
        }
    }
    if (!focused) {
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
            for (int id : {kIdInstall, kIdCancel, kIdOpenApp, kIdClose, kIdRetry,
                           kIdRemove}) {
                g_buttons.push_back({id, L"", ButtonKind::Secondary, false, {}, false});
            }

            g_checks.clear();
            if (g_mode == WindowMode::Setup) {
                // All on. Every one of them is what somebody installing a program
                // expects to get and every one is a tick away from being undone —
                // but they are shown, because a program that puts things on your
                // desktop without mentioning it is a program you resent.
                g_checks.push_back({kIdCheckDesktop, L"Put a shortcut on the desktop",
                                    L"", true, false, {}});
                g_checks.push_back({kIdCheckStartMenu, L"Add it to the Start menu",
                                    L"", true, false, {}});
                g_checks.push_back({kIdCheckLogon, L"Start SolStream when I log in",
                                    L"", true, false, {}});
            }

            if (g_mode == WindowMode::Host) {
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
            }

            // Mica, so the window sits in the system's own material rather than
            // pretending to be a flat rectangle on top of it.
            const int backdrop = DWMSBT_MAINWINDOW;
            DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                                  sizeof(backdrop));
            ApplyTheme(window);
            // Setup redraws for its own animation; the host window only redraws
            // to age its status, and thirty times a second to do that would be a
            // program that shows up in Task Manager for no reason.
            SetTimer(window, kTimerId, g_mode == WindowMode::Host ? 1000 : 33, nullptr);
            return 0;
        }

        case WM_SOLSTREAM_JOB_STEP: {
            std::wstring* text = (std::wstring*) lparam;
            // Setup shows it as the working phase's sentence; the host window
            // has no phases, so it goes under the notice the button raised.
            g_step = *text;
            if (g_mode == WindowMode::Host) {
                g_notice_detail = *text;
            }
            delete text;
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_SOLSTREAM_JOB_DONE: {
            std::wstring* text = (std::wstring*) lparam;
            const bool ok = wparam != 0;
            g_job_running = false;
            if (g_mode == WindowMode::Host) {
                // The host window has no phases: the answer replaces the
                // question in the same banner the button was in.
                g_notice = ok ? L"The display is set up."
                              : L"SolStream couldn't set the display up.";
                g_notice_detail = *text;
            } else {
                g_phase = ok ? Phase::Done : Phase::Failed;
                g_outcome = *text;
            }
            delete text;
            InvalidateRect(window, nullptr, FALSE);
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
            if (hot == 0) {
                for (const Check& check : g_checks) {
                    if (HitCheck(check, x, y)) {
                        hot = check.id;
                        break;
                    }
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
            if (g_pressed == 0) {
                for (const Check& check : g_checks) {
                    if (HitCheck(check, x, y)) {
                        g_pressed = check.id;
                        g_focus = check.id;
                        g_keyboard_nav = false;
                        break;
                    }
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
                } else if (const Check* check = FindCheck(pressed)) {
                    if (HitCheck(*check, x, y)) {
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
            if (g_mode == WindowMode::Host) {
                LayoutAndPaint(window);
            } else {
                LayoutAndPaintSetup(window);
            }
            EndPaint(window, &paint);
            return 0;
        }

        case WM_CLOSE:
            // Not in the middle of writing to Program Files. The work happens in
            // another process and would carry on regardless, so closing here
            // would not stop it — it would only take away the one thing that
            // could tell the user how it went.
            if (g_job_running) {
                return 0;
            }
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

bool ShowHostWindow(WindowMode mode) {
    g_mode = mode;
    if (!CreateDeviceIndependentResources()) {
        return false;
    }

    const wchar_t* class_name =
        mode == WindowMode::Host ? kClassName : kSetupClassName;
    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WindowProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = class_name;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    // The title bar and Alt-Tab take the CLASS's icon, not the executable's.
    // Leaving these null does not fall back to the .ico in the binary — it falls
    // back to Windows' generic application icon, so the taskbar showed
    // SolStream's mark while the title bar two inches above it showed a green
    // square. Resource 1 is the icon group; see resources.rc.in.
    wc.hIcon = (HICON) LoadImageW(wc.hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                  GetSystemMetrics(SM_CXICON),
                                  GetSystemMetrics(SM_CYICON), 0);
    wc.hIconSm = (HICON) LoadImageW(wc.hInstance, MAKEINTRESOURCEW(1), IMAGE_ICON,
                                    GetSystemMetrics(SM_CXSMICON),
                                    GetSystemMetrics(SM_CYSMICON), 0);
    if (!RegisterClassExW(&wc)) {
        return false;
    }

    const UINT dpi = GetDpiForSystem();
    const int width = MulDiv((int) metric::kWindowW, dpi, 96);
    // Uninstall has no tick boxes and no install path to show, so the same
    // height would be a third of a window of empty space above the buttons.
    const float wanted_height =
        mode == WindowMode::Uninstall ? 400.0f : metric::kWindowH;
    const int height = MulDiv((int) wanted_height, dpi, 96);
    RECT wanted{0, 0, width, height};
    AdjustWindowRectExForDpi(&wanted, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE,
                             0, dpi);
    const wchar_t* title = mode == WindowMode::Host      ? L"SolStream"
                         : mode == WindowMode::Uninstall ? L"Remove SolStream"
                                                         : L"SolStream Setup";
    g_window = CreateWindowExW(
        0, class_name, title,
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
    if (mode != WindowMode::Host) {
        // Centred and in front. Setup is the only thing this process is doing,
        // and a setup window that opens behind the browser the download came
        // from is one the user concludes did nothing.
        RECT frame{};
        GetWindowRect(g_window, &frame);
        const int screen_w = GetSystemMetrics(SM_CXSCREEN);
        const int screen_h = GetSystemMetrics(SM_CYSCREEN);
        SetWindowPos(g_window, nullptr,
                     (screen_w - (frame.right - frame.left)) / 2,
                     (screen_h - (frame.bottom - frame.top)) / 2, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER);
    }
    ShowWindow(g_window, SW_SHOW);
    UpdateWindow(g_window);
    if (mode != WindowMode::Host) {
        SetForegroundWindow(g_window);
    }
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

bool FocusExistingHostWindow() {
    HWND existing = FindWindowW(kClassName, nullptr);
    if (!existing || existing == g_window) {
        return false;
    }
    if (IsIconic(existing)) {
        ShowWindow(existing, SW_RESTORE);
    }
    // SetForegroundWindow is refused to a process that does not own the
    // foreground, and a shortcut press does own it — the shell hands it over for
    // exactly this. If it is refused anyway the window is at least restored and
    // flashing in the taskbar, which is the same fallback Windows itself uses.
    if (!SetForegroundWindow(existing)) {
        FlashWindow(existing, TRUE);
    }
    return true;
}

}  // namespace solstream
