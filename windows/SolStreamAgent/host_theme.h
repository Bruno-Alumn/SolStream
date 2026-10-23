// host_theme.h — Solar, the design's literal values, and nothing derived.
//
// Every colour here is copied from docs/design-system.md rather than computed
// from a base hue. That is deliberate: the ramps were chosen against contrast
// targets on two grounds, and a generated ramp lands somewhere plausible and
// fails AA in exactly the places nobody screenshots. If a value looks wrong,
// it is wrong in the design and should be fixed there — and in the Mac
// client's DesignSystem.swift in the same commit, because both programs carry
// these exact numbers.
//
// Lengths are DIPs — device-independent pixels, 1/96 inch. Direct2D draws in
// DIPs natively, so 150% and 200% are a scale factor on the render target and
// never a second layout. Nothing in this file is a pixel count.

#pragma once

#include <d2d1.h>

namespace solstream {

/// The design's spacing scale: 4, 8, 12, 16, 20, 24, 32, 48. The window's
/// content inset is kXl, on every edge.
namespace space {
constexpr float kXs = 4.0f;
constexpr float kSm = 8.0f;
constexpr float kMd = 12.0f;
constexpr float kLg = 16.0f;
constexpr float kLgr = 20.0f;
constexpr float kXl = 24.0f;
constexpr float k2Xl = 32.0f;
constexpr float k3Xl = 48.0f;
}  // namespace space

/// Type roles, in DIPs. Segoe UI Variable Display at 20 and above, Text below;
/// Cascadia Mono only for addresses, tokens and live numbers. Weights are real
/// axis stops on the variable font -- 400, 500, 600 -- never synthesised.
/// Sentence case everywhere: no all-caps, no letter-spacing tricks.
namespace type {
constexpr float kDisplay = 26.0f;   // semibold — the wordmark
constexpr float kTitle = 20.0f;     // semibold — the one sentence each screen leads with
constexpr float kHeadline = 15.0f;  // semibold — a banner's first line
constexpr float kBody = 13.0f;      // regular
constexpr float kCaption = 11.0f;   // medium
constexpr float kMono = 12.0f;      // regular, Cascadia Mono
}  // namespace type

/// Control metrics, from the design's space-and-shape table.
namespace metric {
/// The window is as tall as what it is showing; this is only the width, and a
/// first guess at the height before the first layout pass measures the real one.
constexpr float kWindowW = 460.0f;
constexpr float kWindowH = 480.0f;

constexpr float kRadiusButton = 8.0f;
constexpr float kRadiusField = 8.0f;
constexpr float kRadiusRow = 8.0f;
constexpr float kRadiusCard = 12.0f;
constexpr float kRadiusCheck = 4.0f;    // a tick box is a control, not a chip

constexpr float kButtonH = 32.0f;
constexpr float kButtonHit = 32.0f;     // hit rect, per the platform minimum
constexpr float kButtonMinW = 96.0f;
constexpr float kButtonPadX = 16.0f;    // caption to edge, each side
constexpr float kShieldExtra = 18.0f;   // widened for the elevation glyph: its 12 box, a 6 gap

constexpr float kRowH = 36.0f;          // one-line row
constexpr float kFieldH = 36.0f;
constexpr float kFieldPadX = 12.0f;     // the EDIT's text sits this far inside the field
constexpr float kCardInset = 16.0f;
constexpr float kDot = 8.0f;            // status dot diameter

/// The focus ring on a drawn control: 2 DIP stroke, 2 DIP of the parent's own
/// ground between the control edge and the ring, and a radius concentric with
/// what it surrounds. Drawn OUTSIDE the layout box so focus never reflows
/// anything -- which means every container owes it this much internal
/// clearance or the ring clips. A field is the exception: its own border
/// becomes the 2 DIP ring, so it needs no clearance at all.
constexpr float kFocusStroke = 2.0f;
constexpr float kFocusGap = 2.0f;
constexpr float kFocusRadiusBump = 3.0f;
constexpr float kFocusClearance = 5.0f;

constexpr float kCaretW = 2.0f;  // the system caret is 1px and vanishes at 200%
}  // namespace metric

/// One theme's colours. Named by role — the same names as the design document
/// — because the same role is a different hex in each theme and the drawing
/// code must never know which theme it is in.
struct Palette {
    // Surfaces
    D2D1_COLOR_F ground;        ///< the window, edge to edge, title bar included
    D2D1_COLOR_F surface;       ///< cards, fields, list background
    D2D1_COLOR_F raised;        ///< hovered row, secondary button, chips, tracks

    // Lines
    D2D1_COLOR_F hairline;      ///< separators, resting borders
    D2D1_COLOR_F edge;          ///< hovered borders, unticked boxes

    // Ink
    D2D1_COLOR_F text;
    D2D1_COLOR_F textSecondary; ///< supporting sentences
    D2D1_COLOR_F textMuted;     ///< labels, captions
    D2D1_COLOR_F textFaint;     ///< placeholders and disabled only — never for reading

    // The one warm accent, sun amber
    D2D1_COLOR_F accent;        ///< primary fill, focus ring, the mark
    D2D1_COLOR_F accentHover;
    D2D1_COLOR_F accentPressed;
    D2D1_COLOR_F onAccent;      ///< text on a filled accent
    D2D1_COLOR_F accentInk;     ///< accent as text or a 1px line on ground/surface
    D2D1_COLOR_F accentTint;    ///< selected row, selection, primary-tag ground
    D2D1_COLOR_F accentTintInk; ///< text on accentTint

    // State: two hues, only ever small
    D2D1_COLOR_F live;          ///< connected / running dot
    D2D1_COLOR_F danger;        ///< failed dot, destructive text

    bool dark;
};

constexpr D2D1_COLOR_F Hex(unsigned rgb, float a = 1.0f) {
    return D2D1_COLOR_F{((rgb >> 16) & 0xFF) / 255.0f,
                        ((rgb >> 8) & 0xFF) / 255.0f,
                        (rgb & 0xFF) / 255.0f, a};
}

/// A deep, neutral graphite — still the darkest thing on screen, so the
/// application being streamed stays the brightest.
inline Palette DarkPalette() {
    Palette p{};
    p.ground = Hex(0x0E0F12);
    p.surface = Hex(0x17191E);
    p.raised = Hex(0x20232A);

    p.hairline = Hex(0x2A2D35);
    p.edge = Hex(0x3A3E48);

    p.text = Hex(0xF2F2F4);
    p.textSecondary = Hex(0xA9ADB8);
    p.textMuted = Hex(0x7C818D);
    p.textFaint = Hex(0x5A5F6B);

    p.accent = Hex(0xFFB547);
    p.accentHover = Hex(0xFFC56E);
    p.accentPressed = Hex(0xE89A2A);
    p.onAccent = Hex(0x1A1205);
    p.accentInk = Hex(0xFFC66B);
    p.accentTint = Hex(0x2B2418);
    p.accentTintInk = Hex(0xFFD699);

    p.live = Hex(0x4ADE80);
    p.danger = Hex(0xFF6B6B);

    p.dark = true;
    return p;
}

/// The light ramps are not the dark ones inverted. The ground is a warm paper
/// rather than white, so a white card reads as a card; the accent deepens to
/// amber 500 so a filled button still holds onAccent at 8.5:1; and accentInk
/// drops to amber 700, because amber 500 as text on paper fails AA.
inline Palette LightPalette() {
    Palette p{};
    p.ground = Hex(0xF7F6F3);
    p.surface = Hex(0xFFFFFF);
    p.raised = Hex(0xEFEDE8);

    p.hairline = Hex(0xE4E1DA);
    p.edge = Hex(0xCFCBC2);

    p.text = Hex(0x17181B);
    p.textSecondary = Hex(0x4A4E57);
    p.textMuted = Hex(0x6A6F79);
    p.textFaint = Hex(0x9A9EA6);

    p.accent = Hex(0xF59E0B);
    p.accentHover = Hex(0xFBB13C);
    p.accentPressed = Hex(0xD97706);
    p.onAccent = Hex(0x1A1205);
    p.accentInk = Hex(0xB45309);
    p.accentTint = Hex(0xFDF0DA);
    p.accentTintInk = Hex(0x8A4B06);

    p.live = Hex(0x16A34A);
    p.danger = Hex(0xDC2626);

    p.dark = false;
    return p;
}

/// The status dots. Severity is still carried by the words; the colour only
/// makes it findable, so there are exactly two state hues and both are small.
///   Live      green — running, connected, present
///   NeedsYou  accent, with a soft halo — works, but there is something to do
///   Failed    coral — the thing the headline is apologising for
///   Idle      faint — absent or not started, nothing wrong
enum class Mark { Live, NeedsYou, Failed, Idle, None };

inline D2D1_COLOR_F MarkColor(const Palette& p, Mark mark) {
    switch (mark) {
        case Mark::Live: return p.live;
        case Mark::NeedsYou: return p.accent;
        case Mark::Failed: return p.danger;
        default: return p.textFaint;
    }
}

}  // namespace solstream
