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
// (Solar, docs/design-system.md) specifies every state of every part as a
// colour role, and a stock button can honour none of them. The token is the exception: it is a real EDIT, because
// selection, the caret and Ctrl+C are the entire reason that field exists and
// hand-rolling text selection to get them back would be absurd.

#include "host_window.h"

#include "media/log.h"

#include <windows.h>
#include <windowsx.h>
#include <d2d1.h>
#include <dwrite.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "display_setup.h"
#include "driver_install.h"
#include "host_theme.h"
#include "installer.h"
#include "ports.h"
#include "tailscale.h"
#include "updater.h"
#include "util.h"
#include "vdd.h"

// Not in every SDK this is built against, and they are only integers.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMSBT_NONE
#define DWMSBT_NONE 1
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
/// The notification-area icon's callback.
constexpr UINT WM_SOLSTREAM_TRAY = WM_APP + 3;
/// Posted by the update scheduler's thread when a check finishes. wparam is
/// non-zero when somebody asked for it; lparam owns an update::CheckResult the
/// UI thread deletes.
constexpr UINT WM_SOLSTREAM_UPDATE = WM_APP + 4;
/// Posted by the thread that waits on a started installer, when it finished
/// and this copy is still running -- so it was not replaced. wparam is its exit
/// code.
constexpr UINT WM_SOLSTREAM_UPDATE_EXITED = WM_APP + 5;
/// The virtual display's answer from a job, ahead of its WM_SOLSTREAM_JOB_DONE;
/// lParam is a std::string* the UI thread takes ownership of.
constexpr UINT WM_SOLSTREAM_JOB_DISPLAY = WM_APP + 6;
constexpr UINT kTrayIconId = 1;
constexpr UINT kTrayOpen = 1;
constexpr UINT kTrayCopyToken = 2;
constexpr UINT kTrayQuit = 3;
constexpr UINT kTrayInstallUpdate = 4;
constexpr UINT kTrayCheckUpdates = 5;
constexpr UINT kTraySetUpDisplay = 6;

// ── Shared state ─────────────────────────────────────────────────────────────

std::mutex g_mutex;
HostStatus g_status;
bool g_closed = false;

// ── The notification area ────────────────────────────────────────────────────
//
// SolStream is something that runs, not something you look at. It starts at
// logon with no window at all, lives as an icon beside the clock, and closing
// its window puts it back there rather than ending it -- the way a remote
// desktop host is expected to behave, and the only way to promise that nothing
// on this PC is interrupted by it. Quitting is a deliberate menu choice.

/// Broadcast by Explorer when the taskbar is recreated -- after Explorer
/// restarts, or a DPI change -- at which point every notification icon is gone
/// and has to be added again by its owner.
UINT g_taskbar_created = 0;
/// Sent by a second launch (a shortcut, the Start menu, setup's "Open") to the
/// running copy: "show your window". Registered, so both processes agree on it.
UINT g_show_request = 0;
bool g_tray_added = false;
/// Set by the tray's Quit, so the WM_CLOSE that follows ends the program
/// instead of hiding the window again.
bool g_quitting = false;

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

/// The virtual display, as setup found it and as the install left it.
///
/// `g_driver_state` is read once as the setup window opens: the tick box is
/// offered only when there is no device of the driver's at all, and only on a
/// PC it can be installed on (`g_can_install_driver`). One that is there but
/// switched off is somebody's own, and setup says so rather than install over
/// it; one that waits for a restart only needs the restart, and setup says
/// that. `g_driver_ours` is the same question for the uninstall window, which
/// only promises to remove a driver SolStream put there. `g_display_result` is
/// the elevated half's answer, "ready <note>", "ready-restart <note>" or
/// "failed <why>", empty when it was not asked to do anything -- setup's tick
/// box's, or the host window's Set up's.
DriverState g_driver_state = DriverState::Missing;
bool g_can_install_driver = true;
bool g_driver_ours = false;
std::string g_display_result;
/// What was ticked when Install was pressed, for the summary afterwards.
InstallOptions g_chosen;
/// Registered: the elevated half's progress, a DriverStep in wParam.
UINT g_progress_message = 0;
/// When the driver install reached the step where Windows may ask about the
/// publisher, or 0. A wait there of more than a few seconds is almost always
/// that question, possibly behind this window, and the screen says so.
ULONGLONG g_installing_since = 0;

/// What to add while the install has sat on that step for a while.
std::wstring PromptHint() {
    if (g_installing_since == 0 || GetTickCount64() - g_installing_since < 12000) {
        return {};
    }
    return L" Still here? Windows may be waiting for an answer in a window behind this "
           L"one: look on the taskbar for Windows Security.";
}
/// main.cpp's, run once a virtual display has been installed into a running
/// host, so it starts capturing it. On the worker thread.
std::function<void()> g_display_ready;

/// Which job g_job_running is about, so its answer is worded for that job.
enum class HostJob { None, Display, Update };
HostJob g_host_job = HostJob::None;

/// The update the last check found, its checksums' signature verified. UI
/// thread only: checks finish on another thread and report through
/// WM_SOLSTREAM_UPDATE rather than writing here.
bool g_update_found = false;
update::Release g_update;
/// "Check for updates" was chosen and has not been answered yet. Its answer
/// goes in the notice, which says "Checking…" until then.
bool g_update_checking = false;
/// The installer has started and has neither stopped this copy nor finished.
/// Install is not offered meanwhile, so a second press cannot raise a second
/// permission prompt.
bool g_update_installing = false;
/// The installer's end, when it arrived before the job's own answer did.
bool g_update_exit_early = false;
DWORD g_update_exit_code = 0;
/// The version the tray's tooltip announces, empty for none. Behind g_mutex,
/// unlike the rest of the update state: the status thread builds the tooltip.
std::wstring g_update_tip_version;

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
/// Round caps and joins for the tick, so its two strokes meet as one mark
/// instead of as two rectangles overlapping at a corner.
ID2D1StrokeStyle* g_round_stroke = nullptr;

// One format per type role in the design, and one more for button captions,
// which are body-sized but carry the 500 stop so a button reads as a button.
IDWriteTextFormat* g_fmt_display = nullptr;
IDWriteTextFormat* g_fmt_title = nullptr;
IDWriteTextFormat* g_fmt_headline = nullptr;
IDWriteTextFormat* g_fmt_body = nullptr;
IDWriteTextFormat* g_fmt_button = nullptr;
IDWriteTextFormat* g_fmt_caption = nullptr;
IDWriteTextFormat* g_fmt_mono = nullptr;

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
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &g_d2d);
    if (FAILED(hr)) {
        media::Log("[window] Direct2D would not start (0x%08lX)", hr);
        return false;
    }
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                             reinterpret_cast<IUnknown**>(&g_dwrite));
    if (FAILED(hr)) {
        media::Log("[window] DirectWrite would not start (0x%08lX)", hr);
        return false;
    }
    g_fmt_display = MakeFormat(L"Segoe UI Variable Display", type::kDisplay,
                               DWRITE_FONT_WEIGHT_SEMI_BOLD);
    g_fmt_title = MakeFormat(L"Segoe UI Variable Display", type::kTitle,
                             DWRITE_FONT_WEIGHT_SEMI_BOLD);
    g_fmt_headline = MakeFormat(L"Segoe UI Variable Text", type::kHeadline,
                                DWRITE_FONT_WEIGHT_SEMI_BOLD);
    g_fmt_body = MakeFormat(L"Segoe UI Variable Text", type::kBody,
                            DWRITE_FONT_WEIGHT_NORMAL);
    g_fmt_button = MakeFormat(L"Segoe UI Variable Text", type::kBody,
                              DWRITE_FONT_WEIGHT_MEDIUM);
    g_fmt_caption = MakeFormat(L"Segoe UI Variable Text", type::kCaption,
                               DWRITE_FONT_WEIGHT_MEDIUM);
    g_fmt_mono = MakeFormat(L"Cascadia Mono", type::kMono,
                            DWRITE_FONT_WEIGHT_NORMAL);
    const D2D1_STROKE_STYLE_PROPERTIES round = D2D1::StrokeStyleProperties(
        D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND,
        D2D1_LINE_JOIN_ROUND);
    g_d2d->CreateStrokeStyle(round, nullptr, 0, &g_round_stroke);
    return g_fmt_body != nullptr;
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
    HRESULT hr = g_d2d->CreateHwndRenderTarget(
        D2D1::RenderTargetProperties(),
        D2D1::HwndRenderTargetProperties(window, size), &g_target);
    if (FAILED(hr)) {
        // SOFTWARE, EXPLICITLY. The default type is documented to fall back on
        // its own, and on a machine with a basic render driver -- a virtual
        // machine, a thin client -- it does not: the call fails and the window
        // is left painting nothing at all, which is white with a real child
        // control sitting in it. That was the whole first impression on exactly
        // the machines that most need one.
        media::Log("[window] hardware Direct2D failed (0x%08lX); trying software", hr);
        hr = g_d2d->CreateHwndRenderTarget(
            D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_SOFTWARE),
            D2D1::HwndRenderTargetProperties(window, size), &g_target);
    }
    if (FAILED(hr)) {
        media::Log("[window] no Direct2D render target at all (0x%08lX); "
                   "the window will not paint", hr);
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
///
/// Rounded up to a whole DIP, so everything stacked under it stays on the DIP
/// grid and a hairline at 100% lands on one row of pixels instead of two.
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
    const float height = std::ceil(metrics.height);
    return height > designed ? height : designed;
}

/// How wide this text is on one line, in DIPs. Buttons are sized to their
/// caption rather than all being one width, so "OK" is not a slab and "Open
/// SolStream" is not squeezed against its own edges.
float MeasureWidth(const std::wstring& text, IDWriteTextFormat* format) {
    if (!format || text.empty()) {
        return 0.0f;
    }
    IDWriteTextLayout* layout = nullptr;
    if (FAILED(g_dwrite->CreateTextLayout(text.c_str(), (UINT32) text.size(), format,
                                          4096.0f, 4096.0f, &layout))
        || layout == nullptr) {
        return 0.0f;
    }
    DWRITE_TEXT_METRICS metrics{};
    layout->GetMetrics(&metrics);
    layout->Release();
    return std::ceil(metrics.widthIncludingTrailingWhitespace);
}

/// The height of one line of `format`, for putting a dot beside the FIRST line
/// of a block that may wrap rather than beside the middle of the block.
float LineHeight(IDWriteTextFormat* format) {
    return MeasureHeight(L"Ag", format, 4096.0f);
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
/// place it appears at a size Windows has no artboard for, and because at 38
/// DIP on a 200% display it wants 76 real pixels: a scaled 48px icon there is
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

    // Solar's recolouring of the unchanged shape: tile `surface`, tile edge
    // `hairline`, the application rectangle `accent`. The frame is `edge` in
    // the design, brightened at small sizes — and this is a small size, where
    // `edge` itself is close enough to the tile to disappear, so it takes the
    // next ink up: textMuted on graphite, textFaint on paper, which is the
    // same distance from the tile in either theme. These are the .ico's
    // colours too, so the title bar and the header show one drawing.
    const D2D1_COLOR_F tile = g_palette.surface;
    const D2D1_COLOR_F tileEdge = g_palette.hairline;
    const D2D1_COLOR_F frameInk = g_palette.dark ? g_palette.textMuted
                                                 : g_palette.textFaint;
    const D2D1_COLOR_F appInk = g_palette.accent;

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
    const D2D1_RECT_F app{box.left + side * 0.44f, box.top + side * 0.38f,
                          box.left + side * 0.85f, box.top + side * 0.74f};
    g_brush->SetColor(appInk);
    g_target->FillRoundedRectangle(
        D2D1::RoundedRect(app, side * 0.047f, side * 0.047f), g_brush);
}

/// A status dot, 8 DIP. Green = live, accent with a halo = needs you, coral =
/// failed, faint = idle. The words beside it still carry the severity; the
/// colour only makes the row findable from across the room.
void DrawMark(float cx, float cy, Mark mark) {
    if (mark == Mark::None) {
        return;
    }
    if (mark == Mark::NeedsYou) {
        g_brush->SetColor(D2D1::ColorF(g_palette.accent.r, g_palette.accent.g,
                                       g_palette.accent.b, 0.22f));
        g_target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), 7.0f, 7.0f),
                              g_brush);
    }
    const float r = metric::kDot / 2.0f;
    g_brush->SetColor(MarkColor(g_palette, mark));
    g_target->FillEllipse(D2D1::Ellipse(D2D1::Point2F(cx, cy), r, r), g_brush);
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
    kIdBannerFix,
    // Setup and uninstall. Kept in the same list and the same tab order as the
    // rest, because they are the same kind of control on the same window.
    kIdInstall,
    kIdCancel,
    kIdOpenApp,
    kIdClose,
    kIdRetry,
    kIdRemove,
    // In the summary setup ends on: where to get the Mac app, and Tailscale.
    kIdGetMacApp,
    kIdGetTailscale,
    // The tick boxes on the setup screen, in the order they are drawn.
    kIdCheckDesktop = 100,
    kIdCheckStartMenu,
    kIdCheckLogon,
    kIdCheckDisplay,
};

/// Where the Mac app comes from: the same releases the updaters read.
constexpr wchar_t kMacAppUrl[] = L"https://github.com/Bruno-Alumn/SolStream/releases/latest";
/// Shown short enough to stay on one line beside its button; the button opens
/// the releases page itself.
constexpr wchar_t kMacAppShown[] = L"github.com/Bruno-Alumn/SolStream";

/// A tick box. Drawn rather than a real BUTTON control for the same reason the
/// buttons are: the design gives its resting, hover, checked and focused looks
/// as colour roles, and a stock checkbox honours none of them.
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

/// Hit rects are never shorter than the platform's 32 DIP minimum. Every button
/// is drawn at that height now, so this only matters if one is ever drawn
/// smaller — and then it still is not a target the pointer has to aim for.
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

/// The elevation glyph's box, and the gap between it and the caption.
constexpr float kShieldW = 12.0f;
constexpr float kShieldGap = 6.0f;

/// A button's width: its caption plus the design's padding, never narrower
/// than `min_width`, and wider by the glyph when it carries the UAC shield.
float ButtonWidth(const std::wstring& caption, bool shield, float min_width) {
    const float width = MeasureWidth(caption, g_fmt_button)
                      + metric::kButtonPadX * 2.0f
                      + (shield ? kShieldW + kShieldGap : 0.0f);
    return width > min_width ? width : min_width;
}

void DrawButton(const Button& button) {
    if (!button.visible) {
        return;
    }
    const bool hot = g_hot == button.id;
    const bool down = g_pressed == button.id && hot;
    const bool focused = g_focus == button.id && g_keyboard_nav;
    const float radius = metric::kRadiusButton;

    D2D1_COLOR_F ink{};
    if (button.kind == ButtonKind::Primary) {
        // Filled sun amber, no border. One of these per screen at most: it is
        // the thing the screen is asking you to do.
        Fill(button.rect, radius,
             down ? g_palette.accentPressed
                  : (hot ? g_palette.accentHover : g_palette.accent));
        ink = g_palette.onAccent;
    } else {
        // Raised, with a hairline that lifts to `edge` under the pointer. Down
        // is the hairline's own colour as a fill: one step further from the
        // ground in either theme, which is what a press should look like.
        Fill(button.rect, radius, down ? g_palette.hairline : g_palette.raised);
        Stroke(button.rect, radius,
               hot || down ? g_palette.edge : g_palette.hairline);
        ink = g_palette.text;
    }

    // The caption — and the shield, when there is one — centred as a group,
    // so the glyph does not push the word off the button's middle.
    const float caption_w = MeasureWidth(button.caption, g_fmt_button);
    const float group = caption_w + (button.shield ? kShieldW + kShieldGap : 0.0f);
    const float mid = (button.rect.left + button.rect.right) / 2.0f;
    float left = mid - group / 2.0f;
    if (button.shield) {
        // The shield says "this elevates" before the UAC prompt steals focus.
        Text(L"⛊", g_fmt_button,
             D2D1::RectF(left - 2.0f, button.rect.top, left + kShieldW + 2.0f,
                         button.rect.bottom),
             ink, DWRITE_TEXT_ALIGNMENT_CENTER);
        left += kShieldW + kShieldGap;
    }
    Text(button.caption, g_fmt_button,
         D2D1::RectF(left, button.rect.top, left + caption_w + 1.0f,
                     button.rect.bottom),
         ink);

    if (focused) {
        FocusRing(button.rect, radius);
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

    const float row_h = check.rect.bottom - check.rect.top;
    const float top = check.rect.top + (row_h - kBox) / 2.0f;
    const D2D1_RECT_F box{check.rect.left, top, check.rect.left + kBox, top + kBox};

    if (check.checked) {
        Fill(box, metric::kRadiusCheck,
             hot ? g_palette.accentHover : g_palette.accent);
        // The tick, two strokes. A glyph would need a font that has one at this
        // size and would sit a pixel off centre on half the machines that do.
        g_brush->SetColor(g_palette.onAccent);
        const float l = box.left;
        const float t = box.top;
        g_target->DrawLine(D2D1::Point2F(l + 4.5f, t + 9.5f),
                           D2D1::Point2F(l + 7.75f, t + 12.75f), g_brush, 2.0f,
                           g_round_stroke);
        g_target->DrawLine(D2D1::Point2F(l + 7.75f, t + 12.75f),
                           D2D1::Point2F(l + 13.5f, t + 5.75f), g_brush, 2.0f,
                           g_round_stroke);
    } else {
        // An empty box is a control at rest: surface inside, `edge` around it
        // — a hairline would be too faint to read as something to click.
        Fill(box, metric::kRadiusCheck, g_palette.surface);
        Stroke(box, metric::kRadiusCheck,
               hot ? g_palette.textMuted : g_palette.edge);
    }

    const float text_left = check.rect.left + kBox + space::kMd;
    Text(check.caption, g_fmt_body,
         D2D1::RectF(text_left, check.rect.top, check.rect.right, check.rect.bottom),
         g_palette.text);

    if (focused) {
        FocusRing(box, metric::kRadiusCheck);
    }
}

// ── What the window is currently saying ──────────────────────────────────────

/// What the banner's button does. Decided by Describe, the same function that
/// decides what the button SAYS, so the two cannot disagree.
enum class BannerAction { None, Dismiss, InstallDriver, InstallUpdate };

struct Screen {
    // A short title and the sentence under it, the same shape as setup's. One
    // long headline wrapped and left "this PC." alone on a line of its own; a
    // title short enough never to wrap cannot do that.
    std::wstring headline;
    std::wstring subtitle;
    // The banner is a sentence, a reason, and one button. Empty `what` means no
    // banner at all — most of this window's life.
    std::wstring what;
    std::wstring why;
    std::wstring fix;
    std::wstring code;
    Mark mark = Mark::None;  ///< the dot beside the banner's first line
    bool fix_primary = true; ///< "OK" is not the thing the screen is asking for
    bool shield = false;
    bool connected = false;
    BannerAction action = BannerAction::None;
};

/// The dot beside a notice: working while its job runs, then how it went.
Mark g_notice_mark = Mark::None;
/// The notice is about an update: its progress, or the answer to something
/// asked. Those are said even over the two hard failures below, which every
/// other notice waits behind -- an update may be what fixes the failure, and
/// "Check for updates" chosen from the tray must get an answer in the window it
/// opened.
bool g_notice_about_update = false;

void SetNotice(std::wstring what, std::wstring why, Mark mark, bool about_update) {
    g_notice = std::move(what);
    g_notice_detail = std::move(why);
    g_notice_mark = mark;
    g_notice_about_update = about_update;
}

/// Derive what to show from what the agent last reported. One banner at a time:
/// failures cascade, and four banners describing one broken link is noise.
Screen Describe(const HostStatus& status) {
    Screen screen;
    screen.connected = status.connected_clients > 0;

    // The two hard failures keep the headline and subtitle whatever else is
    // said. Their rows give way only to an update (g_notice_about_update), and
    // to the virtual display's set-up while it runs.
    bool failing = true;
    if (status.address.empty()) {
        screen.headline = L"Not reachable yet.";
        screen.subtitle = L"SolStream is ready, but your Mac can't reach this PC.";
        screen.what = L"This PC isn't on a network your Mac can see.";
        screen.why = L"SolStream needs both machines on the same local network.";
        screen.code = L"SS-104";
        screen.mark = Mark::Failed;
    } else if (!status.streaming_ready) {
        screen.headline = L"Streaming didn't start.";
        screen.subtitle = L"SolStream couldn't start streaming on this PC.";
        screen.what = status.streaming_detail.empty()
                          ? L"The streaming host stopped."
                          : status.streaming_detail;
        screen.why = L"SolStream restarts it on a crash, so a failure that reaches "
                     L"you is a real conflict rather than a hiccup.";
        screen.code = L"SS-311";
        screen.mark = Mark::Failed;
    } else {
        failing = false;
        screen.headline = screen.connected ? L"Streaming to your Mac."
                                           : L"Ready for your Mac.";
        // Connected, the token is hidden, so the subtitle says where it went
        // rather than leaving somebody to look for it.
        screen.subtitle = screen.connected
            ? L"The pairing token is hidden while your Mac is connected."
            : L"Open SolStream on your Mac and pick this PC.";
    }

    // What a button just did, said in the window rather than in a system dialog
    // that knows nothing about this program's theme. It outranks the driver
    // advisory below, because it is the answer to the button that advisory
    // offered — showing the question again underneath its own answer would be
    // absurd — but not the two hard failures above, which are still true.
    //
    // Except while the virtual display is being set up: that may be waiting on
    // a Windows prompt, and what to answer and where to look for it are said
    // only here. Once it has finished, its answer waits behind them like any
    // other.
    const bool setting_up_display = g_job_running && g_host_job == HostJob::Display;
    if (!g_notice.empty() && (!failing || g_notice_about_update || setting_up_display)) {
        screen.what = g_notice;
        screen.why = g_notice_detail + (g_job_running ? PromptHint() : std::wstring());
        screen.mark = g_notice_mark;
        screen.code.clear();
        // Nothing to dismiss until it has finished saying it. Dismissing is not
        // the screen's main action, so it is the quiet button.
        const bool busy = g_job_running || g_update_checking || g_update_installing;
        screen.fix = busy ? L"" : L"OK";
        screen.fix_primary = false;
        screen.shield = false;
        screen.action = busy ? BannerAction::None : BannerAction::Dismiss;
        return screen;
    }

    // An update outranks the driver advisory below, which can stand for as
    // long as somebody is happy streaming their main display -- an update
    // behind it would never be seen; the tray's "Set up virtual display" keeps
    // that one reachable. It outranks the hard failures' rows too, since it
    // may be what fixes them. Nothing installs on its own: the button does,
    // and not while a Mac is streaming, because the installer restarts this
    // host and that would end the stream under whoever is using it.
    //
    // Except while a Mac is connected without the virtual display: Install
    // can't be pressed then anyway, and that is exactly when the advisory is
    // true -- everything on the main display is going to the Mac.
    if (g_update_found && !(screen.connected && !status.virtual_display)) {
        screen.what = L"Update available: " + ToWide(g_update.version);
        screen.mark = Mark::NeedsYou;
        screen.code.clear();
        if (screen.connected) {
            screen.why = L"You can install it once your Mac has disconnected — "
                         L"installing restarts SolStream on this PC.";
        } else {
            // The logon choice is kept (InstalledOptions reads it back), so
            // the only thing worth warning about is the permission prompt.
            screen.why = L"Windows asks for permission first. Installing restarts "
                         L"SolStream.";
            screen.fix = L"Install";
            screen.shield = true;
            screen.action = BannerAction::InstallUpdate;
        }
        return screen;
    }
    if (failing) {
        return screen;
    }

    if (!status.virtual_display && status.driver_restart_pending) {
        // Installed, and Windows starts it at the restart. No button: the
        // restart is the one thing left, and Device Manager has nothing to
        // turn on.
        screen.what = L"Restart this PC to finish setting up the virtual display.";
        screen.why = L"Windows finishes installing it when this PC restarts, and SolStream "
                     L"sets it up for your Mac after that. Until then it streams your main "
                     L"display.";
        screen.mark = Mark::NeedsYou;
        return screen;
    }

    // Missing driver is an advisory, not a failure. SolStream captures the main
    // display instead and everything works — which is why this does not take
    // over the headline, and why the row beside it is "needs you" rather than
    // the coral dot that means broken.
    //
    // It is still worth saying, because the two things it costs are exactly the
    // two a person would otherwise discover the hard way: whatever they drag
    // over the streamed application goes down the wire with it, and the canvas
    // is the monitor's size rather than the Mac's, so the picture is scaled.
    if (!status.virtual_display) {
        screen.what = L"Streaming your main display.";
        screen.why = L"That works, but everything on that display goes to your Mac — "
                     L"including anything you drag over the application — and the "
                     L"picture is your monitor's size rather than your Mac's. ";
        screen.mark = Mark::NeedsYou;
        // No button where pressing it can only fail: the driver that is here
        // is somebody's own and switched off, or this is an ARM PC.
        if (status.driver_off) {
            screen.why += L"This PC's Virtual Display Driver is turned off; turn it on in "
                          L"Device Manager (Display adapters) to stream to it.";
        } else if (!CanInstallDisplayDriver()) {
            screen.why += L"SolStream can't install a virtual display on an ARM PC. "
                        + ToWide(ManualInstallAdvice());
        } else {
            screen.why += L"A virtual display fixes both: SolStream downloads the free "
                          L"Virtual Display Driver, checks it, and sets it up.";
            screen.fix = L"Set up";
            screen.shield = true;
            screen.action = BannerAction::InstallDriver;
        }
    }
    return screen;
}

// ── Layout and paint ─────────────────────────────────────────────────────────

struct Row {
    const wchar_t* label;
    std::wstring value;
    Mark mark;          ///< None for a fact; a dot only where there is a state
    bool mono = false;  ///< an address: Cascadia Mono, so 1 and l stay apart
    bool dim = false;   ///< the value is a placeholder, not a reading
};

/// The horizontal lockup: mark, gap, wordmark.
///
/// The design fixes the relationship rather than the sizes — the mark's artwork
/// is as tall as the wordmark's cap height, and the gap between them is that
/// height divided by 2.5. Segoe UI Variable's cap height is 0.7 of its em, so
/// the 26 DIP display wordmark wants 18.2 DIP of artwork; the artwork is the
/// middle 48% of the tile, so the tile is 18.2 / 0.48 = 38.
constexpr float kLockupMark = 38.0f;
constexpr float kLockupH = 38.0f;

void DrawLockup(float left, float top, float right) {
    const float mark_top = top + (kLockupH - kLockupMark) / 2.0f;
    DrawLogo(D2D1::RectF(left, mark_top, left + kLockupMark, mark_top + kLockupMark));
    const float gap = std::round(kLockupMark * 0.48f / 2.5f);
    Text(L"SolStream", g_fmt_display,
         D2D1::RectF(left + kLockupMark + gap, top, right, top + kLockupH),
         g_palette.text);
}

/// Make the window exactly as tall as what was just laid out.
///
/// There is no designed height any more. The design used to fix the window at
/// 460x560 and every block inside it at a height chosen for the string that was
/// in it when it was drawn — which left a third of the host window empty below
/// the token on a healthy PC, and still clipped the sentence that explains what
/// went wrong on an unhealthy one. So the window is sized to its content: the
/// first layout runs before the window is shown, and every later one corrects
/// it if the content changed.
///
/// `shrink` is false where the window should only ever grow — setup, once it
/// is past the choosing phase, where halving the window under the pointer the
/// moment Install is pressed would look like something broke. Only acts on a
/// difference of more than a DIP, so it cannot oscillate with the WM_SIZE it
/// causes: the layout is a function of the content, not of the window.
void FitToContent(HWND window, float content_bottom, bool shrink) {
    if (!g_target) {
        return;
    }
    const float wanted = std::ceil(content_bottom + space::kXl);
    const float have = g_target->GetSize().height;
    if (wanted <= have + 1.0f && (!shrink || wanted >= have - 1.0f)) {
        return;
    }
    const UINT dpi = (UINT) g_dpi;
    RECT frame{0, 0, MulDiv((int) metric::kWindowW, dpi, 96),
               MulDiv((int) wanted, dpi, 96)};
    AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME, FALSE, 0, dpi);
    SetWindowPos(window, nullptr, 0, 0, frame.right - frame.left,
                 frame.bottom - frame.top, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
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
    std::vector<std::wstring> bullets;
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
                };
                // Only a driver SolStream installed: one somebody put here for
                // themselves is theirs, and stays.
                if (g_driver_ours) {
                    copy.bullets.push_back(L"Removes the virtual display it installed");
                }
                copy.bullets.push_back(L"Keeps your pairing token, so a reinstall won't "
                                       L"make your Mac pair again");
                copy.go = L"Remove";
            } else {
                copy.headline = L"Install SolStream on this PC.";
                copy.lead = L"Afterwards your Mac can open one application from here.";
                // What InstallSelf actually writes: two firewall rules, both
                // naming SolStream.exe, one for the agent's TCP port and one for
                // the media and discovery UDP ports. Taken from ports.h rather
                // than typed out, so this sentence cannot drift from the rules
                // the way "the five ports" did. No-break spaces after the
                // protocols, so a wrap never strands "UDP" from its numbers.
                copy.bullets = {
                    L"Copies SolStream to Program Files",
                    L"Adds two firewall rules for SolStream alone: TCP\u00A0"
                        + std::to_wstring(kDefaultPort) + L", UDP\u00A0"
                        + std::to_wstring(kDefaultMediaPort) + L" and "
                        + std::to_wstring(kDiscoveryPort),
                    // Said because it is the promise the tray behaviour keeps,
                    // and the thing a person installing a host most worries about.
                    L"Waits beside the clock, so nothing on this PC is interrupted",
                };
                if (g_driver_state == DriverState::Ready) {
                    copy.bullets.push_back(L"Streams from the virtual display already on "
                                           L"this PC");
                } else if (g_driver_state == DriverState::RestartPending) {
                    copy.bullets.push_back(L"Streams your main display for now: restart this "
                                           L"PC to finish setting up the virtual display");
                } else if (g_driver_state == DriverState::Off) {
                    copy.bullets.push_back(L"Leaves this PC's Virtual Display Driver as it "
                                           L"is: it's turned off, so SolStream streams your "
                                           L"main display until you turn it on");
                } else if (!g_can_install_driver) {
                    copy.bullets.push_back(L"Streams your main display: SolStream can't "
                                           L"install a virtual display on an ARM PC");
                }
                copy.go = L"Install";
            }
            copy.shield = true;
            break;
        case Phase::Working:
            copy.headline = removing ? L"Removing SolStream…" : L"Installing SolStream…";
            copy.lead = g_step + PromptHint();
            break;
        case Phase::Done:
            copy.headline = removing ? L"SolStream has been removed."
                                     : L"SolStream is installed.";
            // Setup says what it did in a summary of its own, below, rather
            // than in a sentence here.
            copy.lead = removing ? g_outcome : L"";
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
    Fill(track, kHeight / 2.0f, g_palette.raised);

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

/// A card: `surface`, one hairline, radius 12. Content sits kCardInset inside.
void DrawCard(const D2D1_RECT_F& rect) {
    Fill(rect, metric::kRadiusCard, g_palette.surface);
    Stroke(rect, metric::kRadiusCard, g_palette.hairline);
}

/// Tailscale's state, asked at most every few seconds: the setup screen
/// repaints thirty times a second for its animation, and the adapter list is
/// not something to walk that often.
struct TailscaleState {
    std::wstring address;
    bool installed = false;
};

TailscaleState CurrentTailscale() {
    static TailscaleState state;
    static ULONGLONG checked = 0;
    const ULONGLONG now = GetTickCount64();
    if (checked == 0 || now - checked > 5000) {
        state.address = TailscaleAddress();
        state.installed = !state.address.empty() || TailscaleInstalled();
        checked = now;
    }
    return state;
}

/// One line of the summary setup ends on: a dot or a step number, what is
/// true now, a sentence under it, and perhaps a button that does the next
/// thing about it.
struct SummaryLine {
    Mark mark = Mark::None;
    std::wstring number;   ///< "1", "2"... in place of a dot, for steps to take
    std::wstring title;
    std::wstring detail;
    bool mono_detail = false;  ///< an address or a link: Cascadia Mono
    int button = 0;
    std::wstring button_caption;
};

/// A card of summary lines, hairlines between them, from `top`. Returns where
/// the card ends.
float DrawSummaryCard(const std::vector<SummaryLine>& lines, float pad, float top,
                      float right) {
    const float inset = metric::kCardInset;
    const float lead_w = 20.0f;
    const float text_left = pad + inset + lead_w + space::kSm;
    const float title_h = LineHeight(g_fmt_body);

    // Measured first, so the card can be drawn behind them at its real height.
    std::vector<float> text_w, detail_h, button_w;
    float height = inset;
    for (size_t i = 0; i < lines.size(); ++i) {
        const SummaryLine& line = lines[i];
        button_w.push_back(line.button ? ButtonWidth(line.button_caption, false, 72.0f)
                                       : 0.0f);
        text_w.push_back(right - inset - text_left
                         - (line.button ? button_w.back() + space::kMd : 0.0f));
        detail_h.push_back(MeasureHeight(line.detail,
                                         line.mono_detail ? g_fmt_mono : g_fmt_caption,
                                         text_w.back()));
        height += (std::max)(title_h + (line.detail.empty() ? 0.0f : 2.0f + detail_h.back()),
                           line.button ? metric::kButtonH : 0.0f);
        if (i + 1 < lines.size()) {
            height += space::kMd * 2.0f + 1.0f;
        }
    }
    height += inset;
    DrawCard(D2D1::RectF(pad, top, right, top + height));

    float y = top + inset;
    for (size_t i = 0; i < lines.size(); ++i) {
        const SummaryLine& line = lines[i];
        const float block = (std::max)(
            title_h + (line.detail.empty() ? 0.0f : 2.0f + detail_h[i]),
            line.button ? metric::kButtonH : 0.0f);
        const float lead_cx = pad + inset + lead_w / 2.0f;
        if (!line.number.empty()) {
            Text(line.number, g_fmt_headline,
                 D2D1::RectF(pad + inset, y, pad + inset + lead_w, y + title_h),
                 g_palette.accent, DWRITE_TEXT_ALIGNMENT_CENTER);
        } else {
            DrawMark(lead_cx, y + title_h / 2.0f, line.mark);
        }
        Text(line.title, g_fmt_body,
             D2D1::RectF(text_left, y, text_left + text_w[i], y + title_h), g_palette.text);
        if (!line.detail.empty()) {
            Text(line.detail, line.mono_detail ? g_fmt_mono : g_fmt_caption,
                 D2D1::RectF(text_left, y + title_h + 2.0f, text_left + text_w[i],
                             y + title_h + 2.0f + detail_h[i]),
                 g_palette.textSecondary);
        }
        if (line.button) {
            if (Button* button = FindButton(line.button)) {
                const float button_top = y + (block - metric::kButtonH) / 2.0f;
                button->rect = D2D1::RectF(right - inset - button_w[i], button_top,
                                           right - inset, button_top + metric::kButtonH);
                button->caption = line.button_caption;
                button->kind = ButtonKind::Secondary;
                button->shield = false;
                button->visible = true;
                DrawButton(*button);
            }
        }
        y += block;
        if (i + 1 < lines.size()) {
            y += space::kMd;
            Fill(D2D1::RectF(text_left, y, right - inset, y + 1.0f), 0.0f, g_palette.hairline);
            y += 1.0f + space::kMd;
        }
    }
    return top + height;
}

/// What setup did, and what is left to do on the Mac -- the end of setup, in
/// place of the one sentence it used to end on, which said nothing about the
/// display and left the Mac half to be guessed.
float DrawSetupSummary(float pad, float top, float right) {
    std::vector<SummaryLine> done;

    SummaryLine host;
    if (g_outcome.empty()) {
        host.mark = Mark::Live;
        host.title = L"SolStream is running";
        host.detail = g_chosen.start_at_logon
            ? L"It starts when you log in and waits beside the clock."
            : L"Open it from the Start menu whenever you want to stream.";
    } else {
        // InstallSelf's warning: installed, but something is missing.
        host.mark = Mark::NeedsYou;
        host.title = L"SolStream is installed";
        host.detail = g_outcome;
    }
    done.push_back(host);

    SummaryLine display;
    const std::string& result = g_display_result;
    if (result.rfind("ready", 0) == 0) {
        // Said by the elevated half in so many words, not guessed from what
        // its notes happen to contain. Restart-needed is not called ready:
        // until the restart the display may not have started at all.
        const bool restart = result.rfind("ready-restart", 0) == 0;
        display.mark = restart ? Mark::NeedsYou : Mark::Live;
        display.title = restart ? L"Restart this PC to finish" : L"Virtual display ready";
        display.detail = restart
            ? L"Windows finishes installing the virtual display when this PC restarts, "
              L"and SolStream sets it up for your Mac after that."
            : L"Your Mac gets a screen of its own on this PC, so nothing on your monitor "
              L"is streamed.";
    } else if (result.rfind("failed", 0) == 0) {
        display.mark = Mark::NeedsYou;
        display.title = L"Virtual display not set up";
        display.detail = ToWide(result.size() > 7 ? result.substr(7) : std::string())
                       + L" Until then SolStream streams your main display, and its "
                         L"window offers Set up again.";
    } else if (g_driver_state == DriverState::Ready) {
        display.mark = Mark::Live;
        display.title = L"Virtual display ready";
        display.detail = L"Using the one already on this PC.";
    } else if (g_driver_state == DriverState::RestartPending) {
        display.mark = Mark::NeedsYou;
        display.title = L"Restart this PC to finish";
        display.detail = L"Restart this PC to finish setting up the virtual display. Until "
                         L"then SolStream streams your main display.";
    } else if (g_driver_state == DriverState::Off) {
        display.mark = Mark::NeedsYou;
        display.title = L"Virtual display turned off";
        display.detail = L"It's this PC's own Virtual Display Driver, so SolStream left it "
                         L"alone. Turn it on in Device Manager (Display adapters) to stream "
                         L"to it.";
    } else if (!g_can_install_driver) {
        display.mark = Mark::NeedsYou;
        display.title = L"Streaming your main display";
        display.detail = L"SolStream can't install a virtual display on an ARM PC. "
                       + ToWide(ManualInstallAdvice());
    } else {
        display.mark = Mark::NeedsYou;
        display.title = L"Streaming your main display";
        display.detail = L"You can set up a virtual display any time from SolStream's "
                         L"window.";
    }
    done.push_back(display);

    // Away from home. Read now rather than when setup opened: somebody may
    // have installed Tailscale while this was running.
    SummaryLine away;
    const TailscaleState tailscale_state = CurrentTailscale();
    const std::wstring& tailscale = tailscale_state.address;
    if (!tailscale.empty()) {
        away.mark = Mark::Live;
        away.title = L"Tailscale is on";
        away.detail = L"Your Mac can reach this PC away from home at " + tailscale + L".";
    } else {
        away.mark = Mark::Idle;
        away.title = L"Away from home?";
        away.detail = tailscale_state.installed
            ? L"Turn Tailscale on here and on your Mac, signed in to the same account."
            : L"Install Tailscale here and on your Mac, signed in to the same account. "
              L"It's free, and SolStream finds this PC over it.";
        if (!tailscale_state.installed) {
            away.button = kIdGetTailscale;
            away.button_caption = L"Get Tailscale";
        }
    }
    done.push_back(away);

    float y = DrawSummaryCard(done, pad, top, right);

    y += space::kXl;
    const float label_h = LineHeight(g_fmt_body);
    Text(L"Next, on your Mac", g_fmt_body, D2D1::RectF(pad, y, right, y + label_h),
         g_palette.textMuted);
    y += label_h + space::kSm;

    wchar_t name[MAX_COMPUTERNAME_LENGTH + 1] = {0};
    DWORD name_size = MAX_COMPUTERNAME_LENGTH + 1;
    GetComputerNameW(name, &name_size);
    std::vector<SummaryLine> steps(3);
    steps[0].number = L"1";
    steps[0].title = L"Get SolStream for Mac";
    steps[0].detail = kMacAppShown;
    steps[0].mono_detail = true;
    steps[0].button = kIdGetMacApp;
    steps[0].button_caption = L"Get it";
    steps[1].number = L"2";
    steps[1].title = std::wstring(L"Open it and pick ") + (name[0] ? name : L"this PC");
    steps[1].detail = L"It finds this PC on your network by itself.";
    steps[2].number = L"3";
    steps[2].title = L"Type the pairing token, once";
    steps[2].detail = L"Open SolStream here to see it.";
    return DrawSummaryCard(steps, pad, y, right);
}

void LayoutAndPaintSetup(HWND window) {
    if (!EnsureTarget(window)) {
        return;
    }
    const SetupCopy copy = CopyForPhase();
    const D2D1_SIZE_F size = g_target->GetSize();
    const float pad = space::kXl;
    const float right = size.width - pad;
    const float width = right - pad;
    const float inset = metric::kCardInset;

    g_target->BeginDraw();
    g_target->Clear(g_palette.ground);
    HideAllControls();

    float y = pad;
    DrawLockup(pad, y, right);
    y += kLockupH + space::kXl;

    // The title, then the sentence under it. A failure's reason is the longest
    // string this window ever holds, so both are measured rather than allotted
    // a height that fits the happy path.
    const float title_h = MeasureHeight(copy.headline, g_fmt_title, width);
    Text(copy.headline, g_fmt_title, D2D1::RectF(pad, y, right, y + title_h),
         g_palette.text);
    y += title_h;
    if (!copy.lead.empty()) {
        y += space::kSm;
        const float lead_h = MeasureHeight(copy.lead, g_fmt_body, width);
        Text(copy.lead, g_fmt_body, D2D1::RectF(pad, y, right, y + lead_h),
             g_palette.textSecondary);
        y += lead_h;
    }
    if (g_phase == Phase::Working) {
        y += space::kLgr;
        DrawWorkingBar(pad, y, right);
        y += 4.0f;
    }
    if (g_phase == Phase::Failed) {
        // The log is the one thing worth asking for when this goes wrong on a
        // machine nobody was watching, so its path is on screen and not in a
        // support article.
        y += space::kMd;
        const std::wstring log = L"Log: " + InstallLogPath();
        const float log_h = MeasureHeight(log, g_fmt_caption, width);
        Text(log, g_fmt_caption, D2D1::RectF(pad, y, right, y + log_h),
             g_palette.textMuted);
        y += log_h;
    }

    if (g_phase == Phase::Done && g_mode == WindowMode::Setup) {
        y += space::kLgr;
        y = DrawSetupSummary(pad, y, right);
    }

    // The card, in the choosing phase only. It says what is about to happen,
    // which is the whole of the consent the UAC prompt is about to ask for in
    // the abstract.
    if (!copy.bullets.empty()) {
        y += space::kLgr;
        // Per bullet, not one height for all of them. "Keeps your pairing
        // token, so a reinstall won't make your Mac pair again" wraps to two
        // lines and ran straight out of the bottom of the card.
        const float dot_w = 6.0f;
        const float bullet_left = pad + inset + dot_w + space::kMd;
        const float bullet_w = right - inset - bullet_left;
        std::vector<float> bullet_h;
        float bullets_h = 0.0f;
        for (const std::wstring& bullet : copy.bullets) {
            bullet_h.push_back(MeasureHeight(bullet, g_fmt_body, bullet_w));
            bullets_h += bullet_h.back();
        }
        bullets_h += space::kSm * (float) (copy.bullets.size() - 1);
        const float card_h = inset + bullets_h + inset;
        DrawCard(D2D1::RectF(pad, y, right, y + card_h));

        const float line = LineHeight(g_fmt_body);
        float inner = y + inset;
        for (size_t i = 0; i < copy.bullets.size(); ++i) {
            // The dot sits on the first line rather than in the middle of the
            // block, so a two-line bullet does not put its dot beside the gap.
            // Neutral, not a status: nothing here has happened yet.
            g_brush->SetColor(g_palette.textMuted);
            g_target->FillEllipse(
                D2D1::Ellipse(D2D1::Point2F(pad + inset + dot_w / 2.0f,
                                            inner + line / 2.0f),
                              dot_w / 2.0f, dot_w / 2.0f),
                g_brush);
            Text(copy.bullets[i], g_fmt_body,
                 D2D1::RectF(bullet_left, inner, right - inset, inner + bullet_h[i]),
                 g_palette.text);
            inner += bullet_h[i] + space::kSm;
        }
        y += card_h;
    }

    // The tick boxes, only while there is still a choice to make and only when
    // installing — there is nothing optional about removing something.
    if (g_phase == Phase::Choosing && g_mode == WindowMode::Setup) {
        y += space::kXl;
        const float label_h = LineHeight(g_fmt_body);
        Text(L"Also", g_fmt_body, D2D1::RectF(pad, y, right, y + label_h),
             g_palette.textMuted);
        y += label_h;
        // The box sits on the content edge, in line with everything above it.
        // Its focus ring reaches kFocusClearance outside that, into the 24 DIP
        // window inset, which is room enough.
        for (Check& check : g_checks) {
            check.visible = true;
            check.rect = D2D1::RectF(pad, y, right, y + metric::kRowH);
            DrawCheck(check);
            y += metric::kRowH;
        }
        y += space::kSm;
        const std::wstring where = L"Installs to " + InstallDirectory();
        const float where_h = MeasureHeight(where, g_fmt_caption, width);
        Text(where, g_fmt_caption, D2D1::RectF(pad, y, right, y + where_h),
             g_palette.textMuted);
        y += where_h;
        // What ticking the display box agrees to, said before the prompts
        // that follow it: a download, from whom, checked how, and the second
        // Windows prompt that will appear -- so neither comes as a surprise.
        if (FindCheck(kIdCheckDisplay) != nullptr) {
            y += space::kSm;
            const std::wstring about =
                std::wstring(L"The virtual display is the free Virtual Display Driver ")
                + ToWide(kDriverVersion) + L" from " + kDriverProject
                + L". SolStream checks the download before installing it, and Windows "
                  L"asks you to trust its publisher, SignPath Foundation. It gives "
                  L"your Mac a screen of its own, so nothing on your monitor is "
                  L"streamed.";
            const float about_h = MeasureHeight(about, g_fmt_caption, width);
            Text(about, g_fmt_caption, D2D1::RectF(pad, y, right, y + about_h),
                 g_palette.textMuted);
            y += about_h;
        }
    }

    // The buttons sit on the bottom edge, right-aligned, where a Windows setup
    // program's buttons are — primary first, so Tab reaches it first.
    struct Spec { int id; std::wstring caption; ButtonKind kind; bool shield; };
    std::vector<Spec> specs;
    switch (g_phase) {
        case Phase::Choosing:
            specs.push_back({g_mode == WindowMode::Uninstall ? kIdRemove : kIdInstall,
                             copy.go, ButtonKind::Primary, copy.shield});
            specs.push_back({kIdCancel, L"Cancel", ButtonKind::Secondary, false});
            break;
        case Phase::Working:
            break;  // nothing to press, and a greyed button is still a target
        case Phase::Done:
            if (g_mode == WindowMode::Setup) {
                specs.push_back({kIdOpenApp, L"Open SolStream", ButtonKind::Primary,
                                 false});
            }
            specs.push_back({kIdClose, L"Close", ButtonKind::Secondary, false});
            break;
        case Phase::Failed:
            specs.push_back({kIdRetry, L"Try again", ButtonKind::Primary, copy.shield});
            specs.push_back({kIdClose, L"Close", ButtonKind::Secondary, false});
            break;
    }
    // Room for the buttons as well, or a long failure message runs underneath
    // them. With no buttons (the working phase) the content simply ends.
    const float content_bottom =
        specs.empty() ? y : y + space::kXl + metric::kButtonH;

    const float button_top = size.height - pad - metric::kButtonH;
    std::vector<float> widths;
    float total = 0.0f;
    for (const Spec& spec : specs) {
        widths.push_back(ButtonWidth(spec.caption, spec.shield, metric::kButtonMinW));
        total += widths.back();
    }
    if (!specs.empty()) {
        total += space::kSm * (float) (specs.size() - 1);
    }
    float button_left = right - total;
    for (size_t i = 0; i < specs.size(); ++i) {
        Button* button = FindButton(specs[i].id);
        if (!button) {
            continue;
        }
        button->rect = D2D1::RectF(button_left, button_top, button_left + widths[i],
                                   button_top + metric::kButtonH);
        button->caption = specs[i].caption;
        button->kind = specs[i].kind;
        button->shield = specs[i].shield;
        button->visible = true;
        DrawButton(*button);
        button_left += widths[i] + space::kSm;
    }

    const HRESULT hr = g_target->EndDraw();
    if (FAILED(hr)) {
        static bool said = false;
        if (!said) {
            said = true;
            media::Log("[window] EndDraw failed (0x%08lX) on the setup screen", hr);
        }
    }
    if (hr == D2DERR_RECREATE_TARGET) {
        DiscardTarget();
        return;
    }
    // Exact while there is still a choice on screen; after that only ever
    // taller, so pressing Install does not collapse the window under the
    // pointer. The working phase's slack sits above the (absent) buttons.
    FitToContent(window, content_bottom, g_phase == Phase::Choosing);
}

void LayoutAndPaint(HWND window) {
    if (!EnsureTarget(window)) {
        // Once. A paint that fails fails sixty times a second, and a log that
        // says so sixty times a second is a log nobody reads.
        static bool said = false;
        if (!said) {
            said = true;
            media::Log("[window] no render target, so nothing is painted");
        }
        return;
    }
    {
        static bool said = false;
        if (!said) {
            said = true;
            const D2D1_SIZE_F reported = g_target->GetSize();
            RECT client{};
            GetClientRect(window, &client);
            media::Log("[window] painting: target %.0fx%.0f DIPs, client %ldx%ld px, "
                       "dpi %.0f", reported.width, reported.height,
                       client.right - client.left, client.bottom - client.top, g_dpi);
        }
    }

    HostStatus status;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        status = g_status;
    }
    const Screen screen = Describe(status);

    const D2D1_SIZE_F size = g_target->GetSize();
    const float pad = space::kXl;
    const float right = size.width - pad;
    const float width = right - pad;
    const float inset = metric::kCardInset;

    g_target->BeginDraw();
    g_target->Clear(g_palette.ground);
    HideAllControls();

    float y = pad;

    // The lockup: the mark, then the wordmark in Segoe UI Variable Display at
    // the design's semibold.
    DrawLockup(pad, y, right);
    y += kLockupH + space::kXl;

    // The title answers "is this PC ready" before anything else is read; the
    // subtitle says what to do about it.
    const float title_h = MeasureHeight(screen.headline, g_fmt_title, width);
    Text(screen.headline, g_fmt_title, D2D1::RectF(pad, y, right, y + title_h),
         g_palette.text);
    y += title_h;
    if (!screen.subtitle.empty()) {
        y += space::kSm;
        const float sub_h = MeasureHeight(screen.subtitle, g_fmt_body, width);
        Text(screen.subtitle, g_fmt_body, D2D1::RectF(pad, y, right, y + sub_h),
             g_palette.textSecondary);
        y += sub_h;
    }
    y += space::kLgr;

    // The banner sits under the title and above the rows, because the rows
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
        const bool dot = screen.mark != Mark::None;
        const float text_left = pad + inset + (dot ? metric::kDot + space::kMd : 0.0f);
        const float text_w = right - inset - text_left;
        const float what_h = MeasureHeight(screen.what, g_fmt_headline, text_w);
        const float why_h = MeasureHeight(screen.why, g_fmt_body, text_w);
        const bool has_fix = fix && !screen.fix.empty();
        const float top = y;
        const float height = inset + what_h
                             + (why_h > 0.0f ? space::kXs + why_h : 0.0f)
                             + (has_fix ? space::kLg + metric::kButtonH : 0.0f)
                             + inset;
        DrawCard(D2D1::RectF(pad, top, right, top + height));

        float inner = top + inset;
        DrawMark(pad + inset + metric::kDot / 2.0f,
                 inner + LineHeight(g_fmt_headline) / 2.0f, screen.mark);
        Text(screen.what, g_fmt_headline,
             D2D1::RectF(text_left, inner, right - inset, inner + what_h),
             g_palette.text);
        inner += what_h;
        if (why_h > 0.0f) {
            inner += space::kXs;
            Text(screen.why, g_fmt_body,
                 D2D1::RectF(text_left, inner, right - inset, inner + why_h),
                 g_palette.textSecondary);
            inner += why_h;
        }

        if (has_fix) {
            inner += space::kLg;
            const float button_w = ButtonWidth(screen.fix, screen.shield, 0.0f);
            fix->rect = D2D1::RectF(text_left, inner, text_left + button_w,
                                    inner + metric::kButtonH);
            fix->caption = screen.fix;
            fix->shield = screen.shield;
            fix->kind = screen.fix_primary ? ButtonKind::Primary
                                           : ButtonKind::Secondary;
            fix->visible = true;
            DrawButton(*fix);
        }
        if (!screen.code.empty()) {
            // For support, not for the user: small, quiet, always there —
            // trailing on the first line, out of the sentence's way.
            Text(screen.code, g_fmt_caption,
                 D2D1::RectF(right - inset - 80.0f, top + inset, right - inset,
                             top + inset + LineHeight(g_fmt_headline)),
                 g_palette.textMuted, DWRITE_TEXT_ALIGNMENT_TRAILING);
        }
        y = top + height + space::kLg;
    }

    // Four rows, in the order they fail, in one card. Separated by hairlines
    // rather than boxed: a status list is a table, and its rules do not fade —
    // a fading rule inside a table reads as damage.
    //
    // The first two are facts — a name and an address — and have no dot: a
    // green dot beside a computer's name claims a state the name does not
    // have, and four green dots in a column is a pattern nobody reads. The
    // dot sits beside the VALUE, on the trailing side, so the labels stay one
    // clean column whether a row has a state or not.
    std::vector<Row> rows;
    rows.push_back({L"This PC",
                    status.computer_name.empty() ? L"—" : status.computer_name,
                    Mark::None, false, status.computer_name.empty()});
    rows.push_back({L"Address",
                    status.address.empty() ? L"not reachable" : status.address,
                    Mark::None, !status.address.empty(), status.address.empty()});
    // The address that works away from home, when there is one and it is not
    // already the one above. Only then: a row saying "not set up" would be
    // a fifth line nagging about something optional.
    if (!status.tailscale_address.empty() && status.tailscale_address != status.address) {
        rows.push_back({L"Tailscale", status.tailscale_address, Mark::None, true, false});
    }
    if (screen.connected) {
        rows.push_back({L"Serving",
                        std::to_wstring(status.connected_clients) + L" of 1 · Mac only",
                        Mark::Live});
    } else {
        rows.push_back({L"Streaming",
                        status.streaming_ready ? L"running" : L"not running",
                        status.streaming_ready ? Mark::Live : Mark::Failed});
    }
    // Named for what it is doing rather than for what is missing. "Virtual
    // display: not installed" reads as a broken component; "Display: your main
    // display" reads as a choice, which is what it is — and its dot is the
    // accent that means "works, but there is something to do", not coral.
    rows.push_back(status.virtual_display
        ? Row{L"Virtual display",
              status.display_detail.empty() ? L"—" : status.display_detail,
              Mark::Live}
        : Row{L"Display", L"your main display", Mark::NeedsYou});

    const float list_top = y;
    const float list_h = space::kXs * 2.0f + metric::kRowH * (float) rows.size();
    DrawCard(D2D1::RectF(pad, list_top, right, list_top + list_h));
    float ry = list_top + space::kXs;
    const float label_left = pad + inset;
    const float value_left = label_left + 120.0f;
    const float value_right = right - inset;
    for (size_t i = 0; i < rows.size(); ++i) {
        const Row& row = rows[i];
        if (i > 0) {
            Fill(D2D1::RectF(pad + inset, ry, right - inset, ry + 1.0f), 0.0f,
                 g_palette.hairline);
        }
        Text(row.label, g_fmt_body,
             D2D1::RectF(label_left, ry, value_left, ry + metric::kRowH),
             g_palette.textMuted);
        IDWriteTextFormat* format = row.mono ? g_fmt_mono : g_fmt_body;
        Text(row.value, format,
             D2D1::RectF(value_left, ry, value_right, ry + metric::kRowH),
             row.dim || row.mark == Mark::Failed ? g_palette.textSecondary
                                                 : g_palette.text,
             DWRITE_TEXT_ALIGNMENT_TRAILING);
        if (row.mark != Mark::None) {
            const float value_w = MeasureWidth(row.value, format);
            DrawMark(value_right - value_w - space::kSm - metric::kDot / 2.0f,
                     ry + metric::kRowH / 2.0f, row.mark);
        }
        ry += metric::kRowH;
    }
    y = list_top + list_h;

    // The token answers "what do I type on my Mac", and sits under the rows
    // because it is read far more often than any button is pressed. It hides
    // itself while a Mac is connected: a visible pairing token beside a live
    // session is an invitation.
    Button* copy = FindButton(kIdCopyToken);
    if (screen.connected || status.pairing_token.empty()) {
        if (g_token_edit) { ShowWindow(g_token_edit, SW_HIDE); }
        if (copy) { copy->visible = false; }
    } else {
        y += space::kXl;
        const float label_h = LineHeight(g_fmt_body);
        Text(L"Pairing token", g_fmt_body, D2D1::RectF(pad, y, right, y + label_h),
             g_palette.textSecondary);
        Text(L"Your Mac asks for it once", g_fmt_body,
             D2D1::RectF(pad, y, right, y + label_h), g_palette.textMuted,
             DWRITE_TEXT_ALIGNMENT_TRAILING);
        y += label_h + space::kSm;

        // Copy is a secondary button beside the field, not a full-width
        // action. Reserve its width plus a gutter, or the field runs underneath
        // it — and a child EDIT always paints above Direct2D content, so the
        // overlap is total.
        const float copy_w = ButtonWidth(L"Copy", false, 64.0f);
        const float field_right = right - copy_w - space::kSm;
        const D2D1_RECT_F field{pad, y, field_right, y + metric::kFieldH};
        const bool field_focus = GetFocus() == g_token_edit;
        Fill(field, metric::kRadiusField, g_palette.surface);
        // Focused, the hairline itself becomes the 2 DIP accent ring — the
        // field's own border, not a second ring outside it.
        if (field_focus) {
            Stroke(field, metric::kRadiusField, g_palette.accent, metric::kFocusStroke);
        } else {
            Stroke(field, metric::kRadiusField, g_palette.hairline);
        }

        // The EDIT sits inside the drawn rect, so the border is ours and never
        // the system's, and its one line of text is centred in the field.
        if (g_token_edit) {
            const float scale = g_dpi / 96.0f;
            constexpr float kTextH = 16.0f;
            const int x = (int) std::lround((field.left + metric::kFieldPadX) * scale);
            const int y_px = (int) std::lround(
                (field.top + (metric::kFieldH - kTextH) / 2.0f) * scale);
            const int w = (int) std::lround(
                (field.right - field.left - metric::kFieldPadX * 2) * scale);
            const int h = (int) std::lround(kTextH * scale);
            // Only when it has actually moved. This runs on every paint, and a
            // SetWindowPos that changes nothing still repaints the control and
            // still carries SWP_SHOWWINDOW -- so the field was being redrawn
            // once a second for the whole life of the window, at a position it
            // was already in.
            RECT now{};
            GetWindowRect(g_token_edit, &now);
            MapWindowPoints(HWND_DESKTOP, GetParent(g_token_edit), (POINT*) &now, 2);
            const bool moved = now.left != x || now.top != y_px
                            || now.right - now.left != w || now.bottom - now.top != h;
            if (moved) {
                SetWindowPos(g_token_edit, nullptr, x, y_px, w, h, SWP_NOZORDER);
            }
            if (!IsWindowVisible(g_token_edit)) {
                ShowWindow(g_token_edit, SW_SHOW);
            }
        }

        if (copy) {
            const float mid = y + metric::kFieldH / 2.0f;
            copy->rect = D2D1::RectF(right - copy_w, mid - metric::kButtonH / 2.0f,
                                     right, mid + metric::kButtonH / 2.0f);
            copy->caption = L"Copy";
            copy->kind = ButtonKind::Secondary;
            copy->visible = true;
            DrawButton(*copy);
        }
        y += metric::kFieldH;
    }
    const float content_bottom = y;

    // PRESENT IT. Without this the whole frame is drawn into a batch that is
    // never submitted, so the window shows nothing at all -- white, with only
    // its real child controls visible, and not one Direct2D call failing to say
    // so. It was lost when the pairing-PIN card was removed: the cut ran from
    // the card through to the comment below, and this sat between them.
    const HRESULT hr = g_target->EndDraw();
    if (FAILED(hr)) {
        static bool said = false;
        if (!said) {
            said = true;
            media::Log("[window] EndDraw failed (0x%08lX)", hr);
        }
    }
    if (hr == D2DERR_RECREATE_TARGET) {
        DiscardTarget();
        return;
    }

    // After EndDraw, never during it: resizing invalidates the render target
    // this function is holding. Both ways on this window: the banner coming
    // and going is the only thing that changes its height, and a window that
    // kept the banner's height after it went is the dead space this replaced.
    FitToContent(window, content_bottom, true);
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

COLORREF ToColorRef(const D2D1_COLOR_F& colour) {
    return RGB((int) std::lround(colour.r * 255.0f), (int) std::lround(colour.g * 255.0f),
               (int) std::lround(colour.b * 255.0f));
}

/// Follow the system immediately on WM_SETTINGCHANGE — never a restart, and
/// never an in-app theme switch, which would be a second source of truth for
/// something Windows already decides.
///
/// The frame is painted to match: the title bar and the one-pixel border are
/// `ground`, the same colour as every pixel of the client area, so the window
/// is one surface from edge to edge. Without this the title bar and border
/// took the system's own dark grey and the content looked like a panel set
/// into somebody else's frame. Windows 10 ignores the caption and border
/// colours and keeps the immersive dark frame, which is the nearest it has.
void ApplyTheme(HWND window) {
    const bool dark = SystemPrefersDark();
    g_palette = dark ? DarkPalette() : LightPalette();
    const BOOL immersive = dark ? TRUE : FALSE;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE, &immersive,
                          sizeof(immersive));
    const COLORREF caption = ToColorRef(g_palette.ground);
    const COLORREF border = ToColorRef(g_palette.ground);
    const COLORREF title = ToColorRef(g_palette.text);
    DwmSetWindowAttribute(window, DWMWA_CAPTION_COLOR, &caption, sizeof(caption));
    DwmSetWindowAttribute(window, DWMWA_BORDER_COLOR, &border, sizeof(border));
    DwmSetWindowAttribute(window, DWMWA_TEXT_COLOR, &title, sizeof(title));
    InvalidateRect(window, nullptr, FALSE);
    if (g_token_edit) {
        InvalidateRect(g_token_edit, nullptr, TRUE);
    }
}

/// The token field's caret, in the accent and kCaretW wide.
///
/// The EDIT makes its own 1px black-on-XOR caret in WM_SETFOCUS and then only
/// moves, shows and hides it; EN_SETFOCUS arrives after that, so replacing the
/// caret here leaves every other part of the control's behaviour alone — no
/// subclassing, nothing between the EDIT and its own messages. A caret is
/// XORed onto what is under it, so the bitmap is the accent XOR the field's
/// ground, which comes out as the accent on that ground. The bitmap must
/// outlive the caret, so the previous one is freed only when the next is made
/// (the EDIT has destroyed the old caret on the way out by then).
///
/// The selection highlight stays the system's: an EDIT has no message for its
/// colours, and painting it ourselves would mean owning the selection drawing
/// this control exists to provide.
HBITMAP g_caret_bitmap = nullptr;

void AmberCaret() {
    if (!g_token_edit) {
        return;
    }
    HDC dc = GetDC(g_token_edit);
    HFONT old = (HFONT) SelectObject(dc, g_edit_font);
    TEXTMETRICW metrics{};
    GetTextMetricsW(dc, &metrics);
    SelectObject(dc, old);
    const int width = (int) std::lround(metric::kCaretW * g_dpi / 96.0f);
    const int height = metrics.tmHeight > 0 ? metrics.tmHeight : 16;
    HBITMAP bitmap = CreateCompatibleBitmap(dc, width, height);
    if (bitmap) {
        HDC mem = CreateCompatibleDC(dc);
        HGDIOBJ previous = SelectObject(mem, bitmap);
        const COLORREF accent = ToColorRef(g_palette.accent);
        const COLORREF ground = ToColorRef(g_palette.surface);
        HBRUSH brush = CreateSolidBrush(accent ^ ground);
        RECT all{0, 0, width, height};
        FillRect(mem, &all, brush);
        DeleteObject(brush);
        SelectObject(mem, previous);
        DeleteDC(mem);
    }
    ReleaseDC(g_token_edit, dc);
    if (!bitmap) {
        return;
    }
    POINT where{};
    GetCaretPos(&where);
    if (CreateCaret(g_token_edit, bitmap, width, height)) {
        SetCaretPos(where.x, where.y);
        ShowCaret(g_token_edit);
        if (g_caret_bitmap) {
            DeleteObject(g_caret_bitmap);
        }
        g_caret_bitmap = bitmap;
    } else {
        DeleteObject(bitmap);
    }
}

/// Cascadia Mono at the design's mono size, in this window's DPI. Recreated
/// when the window moves to a monitor with a different scale, or the token
/// would stay at the old monitor's pixel size inside a field that scaled.
void SetEditFont() {
    if (!g_token_edit) {
        return;
    }
    HFONT font = CreateFontW(
        -(int) std::lround(type::kMono * g_dpi / 96.0f), 0, 0, 0, FW_NORMAL, FALSE,
        FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, FIXED_PITCH | FF_MODERN, L"Cascadia Mono");
    SendMessageW(g_token_edit, WM_SETFONT, (WPARAM) font, TRUE);
    if (g_edit_font) {
        DeleteObject(g_edit_font);
    }
    g_edit_font = font;
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
    // Only offered when the PC has no virtual display; CheckedById answers
    // false for a box that was never put on the screen.
    options.display_driver = FindCheck(kIdCheckDisplay) != nullptr
                          && CheckedById(kIdCheckDisplay);
    g_chosen = options;
    g_display_result.clear();

    g_job_running = true;
    g_phase = Phase::Working;
    g_step = L"Waiting for you to allow this in the Windows prompt…";
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window, options] {
        std::string error;
        std::string display;
        bool ok = false;
        if (IsElevated()) {
            // Already elevated -- setup run as administrator -- so the work
            // happens here, in the order the elevated half does it.
            if (options.display_driver) {
                bool already = false, restart = false;
                std::string note, driver_error;
                const bool ready = InstallDisplayDriver(
                    [window](DriverStep step) {
                        PostMessageW(window, g_progress_message, (WPARAM) step, 0);
                    },
                    window, already, restart, note, driver_error);
                display = ready ? (restart ? "ready-restart " : "ready ") + note
                                : "failed " + driver_error;
                PostMessageW(window, g_progress_message, (WPARAM) DriverStep::Done, 0);
            }
            ok = InstallSelf(options, error);
        } else {
            // The elevated half is this same executable running its install
            // path. It cannot report back through a return value, so it leaves
            // its reason in a file, and posts its progress to this window.
            const std::wstring progress = L" --progress-window "
                + std::to_wstring((unsigned long long) (uintptr_t) window);
            if (RelaunchElevated(L"--install" + OptionArguments(options) + progress, error,
                                 options.display_driver)) {
                ok = ReadInstallResult(error, &display);
            }
        }
        if (!display.empty()) {
            PostMessageW(window, WM_SOLSTREAM_JOB_DISPLAY, 0,
                         (LPARAM) new std::string(display));
        }
        // On success `error` is InstallSelf's warning, or empty; the summary
        // says the rest.
        PostDone(window, ok, ToWide(error));
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
                    : ToWide(error));
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
    g_host_job = HostJob::Display;
    g_display_result.clear();
    SetNotice(L"Setting the virtual display up…",
              L"Waiting for you to allow this in the Windows prompt.", Mark::NeedsYou,
              false);
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window] {
        // The same elevated steps as setup's tick box: download, check,
        // install, create the device, set it up.
        std::string error;
        std::string display;
        if (IsElevated()) {
            bool already = false, restart = false;
            std::string note;
            const bool ready = InstallDisplayDriver(
                [window](DriverStep step) {
                    PostMessageW(window, g_progress_message, (WPARAM) step, 0);
                },
                window, already, restart, note, error);
            display = ready ? (restart ? "ready-restart " : "ready ") + note : "failed " + error;
        } else {
            const std::wstring progress = L"--install-display-driver --progress-window "
                + std::to_wstring((unsigned long long) (uintptr_t) window);
            if (RelaunchElevated(progress, error, true)) {
                ReadInstallResult(error, &display);
            } else {
                display = "failed " + error;
            }
        }
        const bool ok = display.rfind("ready", 0) == 0;
        if (ok && g_display_ready) {
            // This host chose what to capture as it started, when there was
            // no virtual display to choose.
            g_display_ready();
        }
        if (display.empty()) {
            display = "failed " + (error.empty() ? std::string("The setup did not run.") : error);
        }
        const bool restart = display.rfind("ready-restart", 0) == 0;
        // Ahead of the answer, from the same thread, so it has arrived by the
        // time the answer's headline is chosen from it.
        PostMessageW(window, WM_SOLSTREAM_JOB_DISPLAY, 0, (LPARAM) new std::string(display));
        PostDone(window, ok,
                 ok ? (restart ? L"Windows finishes installing it when this PC restarts, "
                                 L"and SolStream sets it up for your Mac after that."
                               : L"Your Mac gets a screen of its own from the next time it "
                                 L"connects.")
                    : ToWide(display.substr(7)));
    }).detach();
}

// The notification area's, below.
std::wstring TrayTip(const HostStatus& status, const std::wstring& update_version);
NOTIFYICONDATAW TrayData(HWND window);

// ── Updates ──────────────────────────────────────────────────────────────────
//
// Found by update::StartScheduler's checks (main.cpp starts it), announced
// here, installed only from here: the banner's Install button or the tray's
// "Install update". See docs/updates.md.

/// What this install was set up with, so an update keeps it rather than
/// quietly putting back a shortcut somebody removed: the installer applies
/// exactly what it is told, and told nothing it writes every shortcut.
///
/// The paths are installer.cpp's -- SolStream.lnk on the all-users desktop and
/// in the all-users Start menu. Where Windows will not name a folder the answer
/// is "keep it": guessing wrong that way costs a shortcut, and the other way it
/// costs the installer deleting one.
///
/// Start at logon is read back from the installed task (StartsAtLogon), so an
/// update keeps the person's choice: with it off, the installer registers a task
/// with no trigger and still uses it to start the new copy.
InstallOptions InstalledOptions() {
    auto present = [](int csidl) {
        wchar_t folder[MAX_PATH] = {0};
        if (FAILED(SHGetFolderPathW(nullptr, csidl, nullptr, SHGFP_TYPE_CURRENT, folder))) {
            return true;
        }
        const std::wstring link = std::wstring(folder) + L"\\SolStream.lnk";
        return GetFileAttributesW(link.c_str()) != INVALID_FILE_ATTRIBUTES;
    };
    InstallOptions options;
    options.desktop_shortcut = present(CSIDL_COMMON_DESKTOPDIRECTORY);
    options.start_menu_shortcut = present(CSIDL_COMMON_PROGRAMS);
    // As the person left it: an update used to turn "start when I log in"
    // back on every time.
    options.start_at_logon = StartsAtLogon();
    return options;
}

bool StreamingNow() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_status.connected_clients > 0;
}

/// Download, verify, and start the installer. It asks for elevation, stops
/// this host and starts the new one, so success is the last thing this copy
/// reports.
void StartUpdateJob(HWND window) {
    if (g_job_running || g_update_checking || g_update_installing || !g_update_found
        || StreamingNow()) {
        return;
    }
    const update::Release release = g_update;
    const InstallOptions options = InstalledOptions();
    g_job_running = true;
    g_host_job = HostJob::Update;
    SetNotice(L"Installing SolStream " + ToWide(release.version) + L"…",
              L"Getting the update ready.", Mark::NeedsYou, true);
    InvalidateRect(window, nullptr, FALSE);

    std::thread([window, release, options] {
        std::string error;
        const bool ok = update::InstallUpdate(
            release, window, options,
            [window](const std::wstring& text) { PostStep(window, text); },
            // Asked again at the last moment: a Mac can connect while a large
            // download runs, and starting the installer then ends its stream.
            [] { return !StreamingNow(); },
            [window](DWORD exit_code) {
                PostMessageW(window, WM_SOLSTREAM_UPDATE_EXITED, exit_code, 0);
            },
            error);
        // The new copy opens its window to say it is back (main.cpp reads the
        // note InstallUpdate left), so this one closing is not the last word.
        PostDone(window, ok,
                 ok ? L"This window closes while SolStream restarts, and opens again "
                      L"once it's back. Your Mac can connect again then."
                    : ToWide(error));
    }).detach();
}

/// "Check for updates": ask now, and say the answer in the window whatever it
/// is. Automatic checks only ever speak up when they find something.
void StartUpdateCheck(HWND window) {
    if (g_job_running || g_update_checking || g_update_installing) {
        return;
    }
    if (update::CheckNow()) {
        g_update_checking = true;
        SetNotice(L"Checking for updates…",
                  L"Asking GitHub for the newest version of SolStream.", Mark::NeedsYou, true);
    } else {
        // main.cpp starts the checks only for the installed copy, which is the
        // one an update replaces. Not a failure: there is nothing to fix.
        SetNotice(L"This copy of SolStream doesn't update itself.",
                  L"Only the copy installed in Program Files checks for updates.", Mark::None,
                  true);
    }
    InvalidateRect(window, nullptr, FALSE);
}

/// A check's answer, on the UI thread. Takes ownership of `result`.
/// The tooltip, rebuilt from the status and update state as they are now. The
/// status thread rewrites it too, but only when the status changes.
void RefreshTrayTip(HWND window) {
    if (!g_tray_added) {
        return;
    }
    NOTIFYICONDATAW data = TrayData(window);
    data.uFlags = NIF_TIP | NIF_SHOWTIP;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        wcsncpy_s(data.szTip, TrayTip(g_status, g_update_tip_version).c_str(), _TRUNCATE);
    }
    Shell_NotifyIconW(NIM_MODIFY, &data);
}

/// The update on offer, for the tooltip, which the status thread reads too.
/// None while it is being installed: it is not on offer then.
void PublishUpdateForTip(HWND window) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_update_tip_version = g_update_found && !g_update_installing
                                   ? ToWide(g_update.version)
                                   : std::wstring();
    }
    RefreshTrayTip(window);
}

void ApplyUpdateCheck(HWND window, std::unique_ptr<update::CheckResult> result, bool asked) {
    // While an update is being installed, a check's answer must not swap the
    // release out from under it.
    const bool installing =
        (g_job_running && g_host_job == HostJob::Update) || g_update_installing;
    if (!installing) {
        if (result->outcome == update::Outcome::Found) {
            g_update_found = true;
            g_update = result->release;
        } else if (result->outcome != update::Outcome::Failed) {
            // Withdrawn, or this copy has caught up. A failed check says
            // nothing either way, so it changes nothing.
            g_update_found = false;
        }
        PublishUpdateForTip(window);
    }
    if (asked && g_update_checking) {
        g_update_checking = false;
        switch (result->outcome) {
            case update::Outcome::Found:
                // The update banner is the answer, so the notice gets out of
                // its way.
                SetNotice(L"", L"", Mark::None, false);
                break;
            case update::Outcome::UpToDate:
            case update::Outcome::NothingVisible:
                SetNotice(L"SolStream is up to date.",
                          L"This is version " + ToWide(result->current)
                              + L", and there's no newer one to install.",
                          Mark::Live, true);
                break;
            case update::Outcome::Failed:
                SetNotice(L"SolStream couldn't check for updates.", ToWide(result->error),
                          Mark::Failed, true);
                break;
        }
    }
    InvalidateRect(window, nullptr, FALSE);
}

/// The installer finished and this copy is still running, so it was not
/// replaced. Its own log says why; the update stays on offer.
void ApplyInstallerExited(HWND window, DWORD exit_code) {
    g_update_installing = false;
    PublishUpdateForTip(window);
    if (exit_code == 0) {
        // It says it installed, yet did not stop this copy: only possible if
        // this copy is not the one in Program Files, which main.cpp does not
        // offer updates to. Said as it is rather than guessed at.
        SetNotice(L"SolStream " + ToWide(g_update.version) + L" is installed.",
                  L"This copy is still running. Quit SolStream from the notification area "
                  L"and open it again to use the new one.",
                  Mark::NeedsYou, true);
    } else {
        SetNotice(L"SolStream couldn't install the update.",
                  L"The installer stopped before replacing this copy. What happened is in "
                      + InstallLogPath() + L".",
                  Mark::Failed, true);
    }
    InvalidateRect(window, nullptr, FALSE);
}

void Activate(HWND window, int id) {
    switch (id) {
        case kIdCopyToken: {
            std::lock_guard<std::mutex> lock(g_mutex);
            CopyToClipboard(g_status.pairing_token);
            break;
        }
        case kIdBannerFix: {
            // Whatever the banner is offering, asked of the same function that
            // drew it. It doubles as the notice's "OK": while something is
            // being said, the button dismisses it rather than starting a job.
            HostStatus status;
            {
                std::lock_guard<std::mutex> lock(g_mutex);
                status = g_status;
            }
            switch (Describe(status).action) {
                case BannerAction::Dismiss:
                    SetNotice(L"", L"", Mark::None, false);
                    InvalidateRect(window, nullptr, FALSE);
                    break;
                case BannerAction::InstallDriver:
                    StartDisplayJob(window);
                    break;
                case BannerAction::InstallUpdate:
                    StartUpdateJob(window);
                    break;
                case BannerAction::None:
                    break;
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

        case kIdGetMacApp:
            ShellExecuteW(nullptr, L"open", kMacAppUrl, nullptr, nullptr, SW_SHOWNORMAL);
            break;

        case kIdGetTailscale:
            ShellExecuteW(nullptr, L"open", kTailscaleDownloadUrl, nullptr, nullptr,
                          SW_SHOWNORMAL);
            break;

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

/// `update_version` is g_update_tip_version, read under g_mutex by the caller.
/// The host lives in the tray, so an update an automatic check found is said
/// here as well -- quietly, where somebody pointing at the icon will see it,
/// rather than with a balloon. Not while streaming: then the stream is what the
/// icon is about, and Install has to wait for the Mac anyway.
std::wstring TrayTip(const HostStatus& status, const std::wstring& update_version) {
    if (!status.agent_listening) {
        return L"SolStream \u2014 not reachable yet";
    }
    if (status.connected_clients > 0) {
        return L"SolStream \u2014 streaming to your Mac";
    }
    if (!update_version.empty()) {
        return L"SolStream \u2014 update " + update_version + L" available";
    }
    return L"SolStream \u2014 ready for your Mac";
}

NOTIFYICONDATAW TrayData(HWND window) {
    NOTIFYICONDATAW data{};
    data.cbSize = sizeof(data);
    data.hWnd = window;
    data.uID = kTrayIconId;
    return data;
}

void AddTrayIcon(HWND window) {
    NOTIFYICONDATAW data = TrayData(window);
    data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
    data.uCallbackMessage = WM_SOLSTREAM_TRAY;
    // The small artboard, loaded at the notification area's own size: the
    // 16px mark is a hand-drawn redraw, not a scale, and asking for exactly
    // that size picks it rather than shrinking the 256. Not LoadIconMetric,
    // which lives only in Common Controls 6 -- a version this executable does
    // not opt into, so importing it stopped the program loading at all.
    data.hIcon = (HICON) LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(1),
                                    IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                                    GetSystemMetrics(SM_CYSMICON), 0);
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        wcsncpy_s(data.szTip, TrayTip(g_status, g_update_tip_version).c_str(), _TRUNCATE);
    }
    g_tray_added = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
    if (g_tray_added) {
        data.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, &data);
    }
}

void RemoveTrayIcon(HWND window) {
    if (g_tray_added) {
        NOTIFYICONDATAW data = TrayData(window);
        Shell_NotifyIconW(NIM_DELETE, &data);
        g_tray_added = false;
    }
}

/// Bring the window back from the tray, in front. Called on the UI thread, in
/// response to a click on the icon or a second launch -- both of which hand
/// this process the right to take the foreground.
void ShowFromTray(HWND window) {
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
}

void ShowTrayMenu(HWND window) {
    HMENU menu = CreatePopupMenu();
    if (!menu) {
        return;
    }
    AppendMenuW(menu, MF_STRING, kTrayOpen, L"Open SolStream");
    AppendMenuW(menu, MF_STRING, kTrayCopyToken, L"Copy pairing token");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    // Greyed rather than left out while something else is under way, or while
    // a Mac is streaming, so the menu keeps its shape from one opening to the
    // next and says the update is there even when it cannot be had right now.
    const bool busy = g_job_running || g_update_checking || g_update_installing;
    const UINT when_free = MF_STRING | (busy ? MF_GRAYED : 0);
    if (g_update_found) {
        const std::wstring install = L"Install update " + ToWide(g_update.version) + L"…";
        AppendMenuW(menu, when_free | (StreamingNow() ? MF_GRAYED : 0), kTrayInstallUpdate,
                    install.c_str());
    }
    AppendMenuW(menu, when_free, kTrayCheckUpdates, L"Check for updates");
    // The driver advisory's own button is behind the update banner while an
    // update is on offer, so it has a way in here too: neither banner can hide
    // the other's action. Offered exactly where that button is, and nowhere it
    // can only fail -- somebody's own driver that is switched off, an ARM PC --
    // or where only a restart is left to do.
    bool offer_display = false;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        offer_display = !g_status.virtual_display && !g_status.driver_off
                     && !g_status.driver_restart_pending;
    }
    if (offer_display && CanInstallDisplayDriver()) {
        AppendMenuW(menu, when_free, kTraySetUpDisplay, L"Set up virtual display…");
    }
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    // Greyed while a job runs: closing then is refused (WM_CLOSE), and a Quit
    // that silently did nothing would leave an update's permission prompt to
    // come up after somebody asked SolStream to go away.
    AppendMenuW(menu, MF_STRING | (g_job_running ? MF_GRAYED : 0), kTrayQuit,
                L"Quit SolStream");
    SetMenuDefaultItem(menu, kTrayOpen, FALSE);
    POINT at{};
    GetCursorPos(&at);
    // Without taking the foreground first the menu never dismisses when the
    // user clicks elsewhere: the documented quirk of TrackPopupMenu from a
    // notification icon.
    SetForegroundWindow(window);
    const UINT chosen = (UINT) TrackPopupMenuEx(
        menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON
                  | (GetSystemMetrics(SM_MENUDROPALIGNMENT) ? TPM_RIGHTALIGN : TPM_LEFTALIGN),
        at.x, at.y, window, nullptr);
    DestroyMenu(menu);
    switch (chosen) {
        case kTrayOpen:
            ShowFromTray(window);
            break;
        case kTrayCopyToken: {
            std::lock_guard<std::mutex> lock(g_mutex);
            CopyToClipboard(g_status.pairing_token);
            break;
        }
        // Both open the window: it is where the progress and the answer are
        // said. Somebody just chose this from the menu, so the window coming
        // forward is the answer to their click, not an interruption.
        case kTrayInstallUpdate:
            ShowFromTray(window);
            StartUpdateJob(window);
            break;
        case kTrayCheckUpdates:
            ShowFromTray(window);
            StartUpdateCheck(window);
            break;
        case kTraySetUpDisplay:
            ShowFromTray(window);
            StartDisplayJob(window);
            break;
        case kTrayQuit:
            g_quitting = true;
            PostMessageW(window, WM_CLOSE, 0, 0);
            break;
        default:
            break;
    }
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    if (g_taskbar_created != 0 && message == g_taskbar_created) {
        if (g_mode == WindowMode::Host) {
            g_tray_added = false;
            AddTrayIcon(window);
        }
        return 0;
    }
    if (g_show_request != 0 && message == g_show_request) {
        ShowFromTray(window);
        return 0;
    }
    if (g_progress_message != 0 && message == g_progress_message) {
        // The virtual display's progress, from the elevated half. Each step is
        // a wait the person would otherwise sit through wondering, and the
        // second one is a Windows prompt they need to know is coming.
        std::wstring text;
        switch ((DriverStep) wparam) {
            case DriverStep::Downloading:
                text = L"Downloading the Virtual Display Driver…";
                break;
            case DriverStep::Installing:
                text = L"Installing the virtual display. If Windows asks whether to "
                       L"install software from SignPath Foundation, choose Install.";
                break;
            case DriverStep::Starting:
                // Windows has had its say by now, so no prompt is mentioned,
                // and the hint below is not added to a wait that has none.
                text = L"Starting the virtual display…";
                break;
            case DriverStep::Configuring:
                text = L"Setting the virtual display up for your Mac. The screen may "
                       L"blink.";
                break;
            case DriverStep::Done:
                text = L"Copying SolStream into Program Files…";
                break;
            default:
                return 0;
        }
        g_installing_since = (DriverStep) wparam == DriverStep::Installing ? GetTickCount64()
                                                                            : 0;
        g_step = text;
        if (g_mode == WindowMode::Host) {
            g_notice_detail = text;
        }
        InvalidateRect(window, nullptr, FALSE);
        return 0;
    }
    switch (message) {
        case WM_CREATE: {
            g_dpi = (float) GetDpiForWindow(window);
            g_buttons.clear();
            g_buttons.push_back({kIdBannerFix, L"", ButtonKind::Primary, false, {}, false});
            g_buttons.push_back({kIdCopyToken, L"Copy", ButtonKind::Secondary, false, {}, false});
            for (int id : {kIdInstall, kIdCancel, kIdOpenApp, kIdClose, kIdRetry,
                           kIdRemove, kIdGetTailscale, kIdGetMacApp}) {
                g_buttons.push_back({id, L"", ButtonKind::Secondary, false, {}, false});
            }

            g_checks.clear();
            if (g_mode == WindowMode::Setup) {
                // First, and ticked, when the PC has no virtual display: it is
                // what makes the picture fit the Mac, and the one thing setup
                // can do that a person would otherwise have to go and find.
                // Not offered at all when one is here already.
                g_driver_state = CurrentDriverState();
                g_can_install_driver = CanInstallDisplayDriver();
                if (g_driver_state == DriverState::Missing && g_can_install_driver) {
                    g_checks.push_back({kIdCheckDisplay,
                                        L"Set up a virtual display (recommended)",
                                        L"", true, false, {}});
                }
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
            if (g_mode == WindowMode::Uninstall) {
                g_driver_ours = InstalledDriverHere();
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
                SetEditFont();
                AddTrayIcon(window);
            }

            // No Mica. Solar's ground is a flat colour by design — the darkest
            // thing on screen, so the streamed application stays the brightest
            // — and Mica tints the title bar with the wallpaper, which is
            // exactly the frame-around-a-panel look the caption colour in
            // ApplyTheme exists to remove. Said explicitly rather than left to
            // the default, which a future Windows may change.
            const int backdrop = DWMSBT_NONE;
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
            g_installing_since = 0;
            if (g_mode == WindowMode::Host) {
                // The host window has no phases: the answer replaces the
                // question in the same banner the button was in.
                if (g_host_job == HostJob::Update) {
                    // Started: the installer stops this copy next, unless it
                    // fails first -- WM_SOLSTREAM_UPDATE_EXITED. The update
                    // stays found until then, so a failure can offer it again.
                    SetNotice(ok ? L"Installing SolStream " + ToWide(g_update.version) + L"…"
                                 : L"SolStream couldn't install the update.",
                              *text, ok ? Mark::NeedsYou : Mark::Failed, true);
                    g_update_installing = ok;
                    PublishUpdateForTip(window);
                    if (ok && g_update_exit_early) {
                        // The installer's end overtook this message.
                        g_update_exit_early = false;
                        ApplyInstallerExited(window, g_update_exit_code);
                    }
                } else if (ok && g_display_result.rfind("ready-restart", 0) == 0) {
                    // Not called ready: until the restart the display may
                    // not have started at all.
                    SetNotice(L"Restart this PC to finish setting up the virtual display.",
                              *text, Mark::NeedsYou, false);
                } else {
                    SetNotice(ok ? L"The virtual display is ready."
                                 : L"SolStream couldn't set the virtual display up.",
                              *text, ok ? Mark::Live : Mark::Failed, false);
                }
                g_host_job = HostJob::None;
            } else {
                g_phase = ok ? Phase::Done : Phase::Failed;
                g_outcome = *text;
            }
            delete text;
            InvalidateRect(window, nullptr, FALSE);
            return 0;
        }

        case WM_SOLSTREAM_JOB_DISPLAY: {
            std::string* text = (std::string*) lparam;
            g_display_result = *text;
            delete text;
            return 0;
        }

        case WM_SOLSTREAM_UPDATE:
            ApplyUpdateCheck(window,
                             std::unique_ptr<update::CheckResult>(
                                 reinterpret_cast<update::CheckResult*>(lparam)),
                             wparam != 0);
            return 0;

        case WM_SOLSTREAM_UPDATE_EXITED:
            // Posted from a different thread than the job's own answer, so it
            // can arrive first: kept until that answer has said "Installing".
            if (g_job_running && g_host_job == HostJob::Update) {
                g_update_exit_early = true;
                g_update_exit_code = (DWORD) wparam;
                return 0;
            }
            ApplyInstallerExited(window, (DWORD) wparam);
            return 0;

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
            const COLORREF bg = ToColorRef(g_palette.surface);
            const COLORREF fg = ToColorRef(g_palette.text);
            static HBRUSH brush = nullptr;
            if (brush) { DeleteObject(brush); }
            brush = CreateSolidBrush(bg);
            SetBkColor(dc, bg);
            SetTextColor(dc, fg);
            return (LRESULT) brush;
        }

        case WM_COMMAND:
            // The field's border is drawn by this window and becomes the accent
            // ring while the EDIT has focus, so it has to be told the moment
            // focus arrives or leaves — not on the next once-a-second tick.
            if (LOWORD(wparam) == kEditId
                && (HIWORD(wparam) == EN_SETFOCUS || HIWORD(wparam) == EN_KILLFOCUS)) {
                if (HIWORD(wparam) == EN_SETFOCUS) {
                    AmberCaret();
                }
                InvalidateRect(window, nullptr, FALSE);
                return 0;
            }
            break;

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
            SetEditFont();
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

        case WM_SOLSTREAM_TRAY:
            // NOTIFYICON_VERSION_4: the event is in the low word of lparam.
            switch (LOWORD(lparam)) {
                case NIN_SELECT:
                case NIN_KEYSELECT:
                    ShowFromTray(window);
                    break;
                case WM_CONTEXTMENU:
                    ShowTrayMenu(window);
                    break;
                default:
                    break;
            }
            return 0;

        case WM_CLOSE:
            // The host goes back to the tray: closing the window is putting it
            // away, not turning SolStream off, and a Mac that was about to
            // connect should still find it. Quit in the tray menu is the way
            // to end it.
            if (g_mode == WindowMode::Host && !g_quitting && g_tray_added) {
                ShowWindow(window, SW_HIDE);
                return 0;
            }
            // Not in the middle of writing to Program Files. The work happens in
            // another process and would carry on regardless, so closing here
            // would not stop it — it would only take away the one thing that
            // could tell the user how it went. Nor is the refusal remembered:
            // left set, it would turn the next close with the window's × --
            // which only ever hides it -- into quitting.
            if (g_job_running) {
                g_quitting = false;
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
            RemoveTrayIcon(window);
            DiscardTarget();
            PostQuitMessage(0);
            return 0;

        default:
            break;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

bool ShowHostWindow(WindowMode mode, bool start_hidden) {
    g_mode = mode;
    g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
    g_show_request = RegisterWindowMessageW(L"SolStream.ShowHostWindow");
    g_progress_message = RegisterWindowMessageW(kSetupProgressMessage);
    // A message from a more privileged process than this one is let through
    // UIPI's filter as long as it goes downwards, which this one does -- but
    // say so, so that a setup run from an elevated prompt still hears it.
    ChangeWindowMessageFilter(g_progress_message, MSGFLT_ADD);
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
    // A first guess only: the layout pass below measures the real height
    // before anything is on screen.
    const int height = MulDiv((int) metric::kWindowH, dpi, 96);
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
        //
        // WS_CLIPCHILDREN, or the token field flickers once a second forever.
        // Everything here is drawn with Direct2D except that one real EDIT, and
        // without this the D2D paint covers the whole client area — including
        // the rectangle the EDIT occupies — and the EDIT then repaints itself on
        // top. Two paints of the same pixels on every timer tick is exactly what
        // flicker is. Clipping the child out of the parent's paint means the
        // token is drawn once, by the control that owns it.
        (WS_OVERLAPPEDWINDOW & ~WS_THICKFRAME & ~WS_MAXIMIZEBOX) | WS_CLIPCHILDREN,
        CW_USEDEFAULT, CW_USEDEFAULT,
        wanted.right - wanted.left, wanted.bottom - wanted.top,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!g_window) {
        return false;
    }
    // Lay out once while the window is still hidden, so it is shown already at
    // the height of what it says rather than at a guess that then snaps. The
    // creating thread's DPI may not be the monitor's; WM_CREATE read the real
    // one, and this pass measures with it.
    if (mode == WindowMode::Host) {
        LayoutAndPaint(g_window);
    } else {
        LayoutAndPaintSetup(g_window);
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
    // At logon the host starts in the tray and shows nothing: a program that
    // opens a window on every login is a program that interrupts every login.
    // Only if the tray icon could not be added -- no Explorer, a stripped-down
    // shell -- is the window shown anyway, or there would be no way to reach it.
    if (mode == WindowMode::Host && start_hidden && g_tray_added) {
        return true;
    }
    ShowWindow(g_window, SW_SHOW);
    UpdateWindow(g_window);
    if (mode != WindowMode::Host) {
        SetForegroundWindow(g_window);
    }
    return true;
}

static bool SameStatus(const HostStatus& a, const HostStatus& b) {
    return a.computer_name == b.computer_name && a.address == b.address
        && a.pairing_token == b.pairing_token && a.agent_listening == b.agent_listening
        && a.streaming_ready == b.streaming_ready && a.virtual_display == b.virtual_display
        && a.streaming_detail == b.streaming_detail && a.display_detail == b.display_detail
        && a.connected_clients == b.connected_clients
        && a.tailscale_address == b.tailscale_address && a.driver_off == b.driver_off
        && a.driver_restart_pending == b.driver_restart_pending;
}

void UpdateHostStatus(const HostStatus& status) {
    std::wstring tip;
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        // The agent reports once a second and almost nothing changes between
        // reports, so an unchanged one costs nothing: no tray update through
        // Explorer and no repaint.
        static bool first = true;
        if (!first && SameStatus(g_status, status)) {
            return;
        }
        first = false;
        g_status = status;
        tip = TrayTip(status, g_update_tip_version);
    }
    if (g_window) {
        // Only when it has actually changed, which is almost never. SetWindowText
        // on an EDIT clears the selection and puts the caret back at nought, so
        // writing the same token over the top of itself on every status update
        // means the field cannot be selected at all: the highlight vanishes the
        // instant anything on the host changes. Selecting the token is the whole
        // reason it is a real control rather than drawn text.
        if (g_token_edit) {
            wchar_t current[128] = {0};
            GetWindowTextW(g_token_edit, current, 128);
            if (status.pairing_token != current) {
                SetWindowTextW(g_token_edit, status.pairing_token.c_str());
            }
        }
        if (g_tray_added) {
            NOTIFYICONDATAW data = TrayData(g_window);
            data.uFlags = NIF_TIP | NIF_SHOWTIP;
            wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
            Shell_NotifyIconW(NIM_MODIFY, &data);
        }
        InvalidateRect(g_window, nullptr, FALSE);
    }
}

void UpdateCheckFinished(const update::CheckResult& result, bool asked) {
    // To the UI thread, which owns everything an announcement touches. The
    // copy belongs to the message; if it cannot be posted, it is freed here.
    if (!g_window) {
        return;
    }
    auto* copy = new update::CheckResult(result);
    if (!PostMessageW(g_window, WM_SOLSTREAM_UPDATE, asked ? 1 : 0, (LPARAM) copy)) {
        delete copy;
    }
}

void SetDisplayReadyHandler(std::function<void()> handler) {
    g_display_ready = std::move(handler);
}

void SayInstallOutcome(bool installed, const std::string& version) {
    if (installed) {
        SetNotice(L"Updated to SolStream " + ToWide(version) + L".",
                  L"Your Mac can connect again.", Mark::Live, true);
    } else {
        SetNotice(L"The update to SolStream " + ToWide(version) + L" didn't finish.",
                  L"This PC is still running SolStream " + std::wstring(kVersion)
                      + L". What happened is in " + InstallLogPath() + L".",
                  Mark::Failed, true);
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

bool FocusExistingHostWindow() {
    HWND existing = FindWindowW(kClassName, nullptr);
    if (!existing || existing == g_window) {
        return false;
    }
    // The window may be hidden in the tray, which ShowWindow from another
    // process can un-hide but not bring forward. So ask the owner to show
    // itself, and hand it the foreground right this process holds -- a
    // shortcut press does hold it, the shell gives it over for exactly this.
    DWORD owner = 0;
    GetWindowThreadProcessId(existing, &owner);
    if (owner) {
        AllowSetForegroundWindow(owner);
    }
    PostMessageW(existing, RegisterWindowMessageW(L"SolStream.ShowHostWindow"), 0, 0);
    return true;
}

}  // namespace solstream
