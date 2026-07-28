// host_theme.h — the design's literal values, and nothing derived.
//
// Every colour here is copied from the design document rather than computed
// from a base hue. That is deliberate: the ramps were chosen against contrast
// targets on two grounds, and a generated ramp lands somewhere plausible and
// fails AA in exactly the places nobody screenshots. If a value looks wrong,
// it is wrong in the design and should be fixed there.
//
// Lengths are DIPs — device-independent pixels, 1/96 inch. Direct2D draws in
// DIPs natively, so 150% and 200% are a scale factor on the render target and
// never a second layout. Nothing in this file is a pixel count.

#pragma once

#include <d2d1.h>

namespace solstream {

/// The design's spacing scale. Authored at 0.7x on the design canvas
/// (2.8 / 5.6 / 8.4 ...), which is these numbers.
namespace space {
constexpr float kXs = 4.0f;
constexpr float kSm = 8.0f;
constexpr float kMd = 12.0f;
constexpr float kLg = 16.0f;
constexpr float kXl = 24.0f;
constexpr float k2Xl = 32.0f;
constexpr float k3Xl = 48.0f;
}  // namespace space

/// Type sizes, in DIPs. Segoe UI Variable Display for the wordmark, Text below
/// 20; Cascadia Mono for anything technical. Weights are real axis stops on the
/// variable font -- 400, 500, 600 -- never synthesised.
namespace type {
constexpr float kWordmark = 28.0f;  // weight 500
constexpr float kHeadline = 20.0f;  // weight 500
constexpr float kValue = 15.0f;     // weight 400
constexpr float kLabel = 13.0f;     // weight 400
constexpr float kMono = 11.0f;      // weight 400
constexpr float kPin = 46.0f;       // weight 600, mono
}  // namespace type

/// Control metrics, from the design's own state tables.
namespace metric {
constexpr float kWindowW = 460.0f;
constexpr float kWindowH = 560.0f;

constexpr float kRadiusControl = 4.0f;  // Windows 11 controls
constexpr float kRadiusCard = 8.0f;     // cards the controls sit in

constexpr float kButtonH = 30.0f;       // visual
constexpr float kButtonHit = 32.0f;     // hit rect, per the platform minimum
constexpr float kButtonMinW = 104.0f;
constexpr float kShieldExtra = 14.0f;   // widened for the elevation glyph

constexpr float kRowH = 32.0f;
constexpr float kFieldH = 34.0f;
constexpr float kFieldInset = 1.0f;     // the EDIT sits inside our hairline
constexpr float kCopyVisual = 22.0f;
constexpr float kCopyHit = 32.0f;

/// The focus ring: 2 DIP stroke, 2 DIP of the parent's own ground between the
/// control edge and the ring, and a radius concentric with what it surrounds.
/// Drawn OUTSIDE the layout box so focus never reflows anything -- which means
/// every container owes it this much internal clearance or the ring clips. The
/// design calls that the most likely bug in the whole spec, so it is named here
/// rather than left as a number in one function.
constexpr float kFocusStroke = 2.0f;
constexpr float kFocusGap = 2.0f;
constexpr float kFocusRadiusBump = 3.0f;
constexpr float kFocusClearance = 5.0f;

constexpr float kCaretW = 2.0f;  // the system caret is 1px and vanishes at 200%
}  // namespace metric

/// One theme's colours. Named by role, because the same role is a different
/// hex in each theme and the drawing code must never know which theme it is in.
struct Palette {
    // Surfaces
    D2D1_COLOR_F ground;        ///< behind the window's content
    D2D1_COLOR_F card;          ///< raised panels and banners
    D2D1_COLOR_F inset;         ///< fields and pressed rows
    D2D1_COLOR_F rowHover;

    // Lines
    D2D1_COLOR_F hairline;      ///< resting borders
    D2D1_COLOR_F hairlineStrong;///< hovered or elevated borders
    D2D1_COLOR_F rule;          ///< the line under a status row

    // Ink
    D2D1_COLOR_F text;
    D2D1_COLOR_F label;
    D2D1_COLOR_F muted;
    D2D1_COLOR_F faint;

    // Accent
    D2D1_COLOR_F accent;
    D2D1_COLOR_F accentHover;
    D2D1_COLOR_F accentPressed;
    D2D1_COLOR_F accentTint;    ///< the filled-tag / secondary-pressed ground
    D2D1_COLOR_F accentTintInk; ///< text on accentTint
    D2D1_COLOR_F onAccent;      ///< text on a filled accent button

    // Selection, matching ::selection in the Mac client so a copied token
    // looks the same on both machines.
    D2D1_COLOR_F selection;
    D2D1_COLOR_F selectionInk;
    D2D1_COLOR_F selectionIdle;   ///< kept after focus moves, so select-all + Ctrl-C works
    D2D1_COLOR_F selectionIdleInk;

    bool dark;
};

constexpr D2D1_COLOR_F Hex(unsigned rgb, float a = 1.0f) {
    return D2D1_COLOR_F{((rgb >> 16) & 0xFF) / 255.0f,
                        ((rgb >> 8) & 0xFF) / 255.0f,
                        (rgb & 0xFF) / 255.0f, a};
}

inline Palette DarkPalette() {
    Palette p{};
    p.ground = Hex(0x161826);
    p.card = Hex(0x232532);
    p.inset = Hex(0x161826);
    p.rowHover = Hex(0x1b1d2b);

    p.hairline = Hex(0x3f424d);
    p.hairlineStrong = Hex(0x595d6c);
    p.rule = Hex(0x292b31);

    p.text = Hex(0xe9e9ed);
    p.label = Hex(0xb2b6ca);
    p.muted = Hex(0x9397ab);
    p.faint = Hex(0x595d6c);

    p.accent = Hex(0x9184d9);
    p.accentHover = Hex(0xb5abfc);
    p.accentPressed = Hex(0x796cbf);
    p.accentTint = Hex(0x2b2741);
    p.accentTintInk = Hex(0xd2cefd);
    p.onAccent = Hex(0x161826);

    p.selection = Hex(0x423a6a);
    p.selectionInk = Hex(0xe9e9ed);
    p.selectionIdle = Hex(0x292b31);
    p.selectionIdleInk = Hex(0x9397ab);

    p.dark = true;
    return p;
}

/// The light ramps are not the dark ones inverted. The accent darkens rather
/// than the ground lightening, so a filled button keeps 4.5:1 against the
/// window. Note the absence of #75798c anywhere: it misses AA on both light
/// grounds, which is why labels are #595d6c and never a step lighter.
inline Palette LightPalette() {
    Palette p{};
    p.ground = Hex(0xf9fafe);
    p.card = Hex(0xeef0fb);
    p.inset = Hex(0xeef0fb);
    p.rowHover = Hex(0xeef0fb);

    p.hairline = Hex(0xcfd3e5);
    p.hairlineStrong = Hex(0xb2b6ca);
    p.rule = Hex(0xe4e7f5);

    p.text = Hex(0x292b31);
    p.label = Hex(0x595d6c);
    p.muted = Hex(0x595d6c);
    p.faint = Hex(0x9397ab);

    p.accent = Hex(0x5d5294);
    p.accentHover = Hex(0x423a6a);
    p.accentPressed = Hex(0x2b2741);
    p.accentTint = Hex(0xe8e5ff);
    p.accentTintInk = Hex(0x423a6a);
    p.onAccent = Hex(0xf9fafe);

    p.selection = Hex(0xd2cefd);
    p.selectionInk = Hex(0x292b31);
    p.selectionIdle = Hex(0xe4e7f5);
    p.selectionIdleInk = Hex(0x9397ab);

    p.dark = false;
    return p;
}

/// The three status marks. No new hues, and never red: severity is carried by
/// the banner and the words. A ring means "needs you", which is a different
/// thing from "broken" and reads as such at a glance.
enum class Mark { Good, NeedsYou, Absent };

inline D2D1_COLOR_F MarkColor(const Palette& p, Mark mark) {
    switch (mark) {
        case Mark::Good: return p.accent;
        case Mark::NeedsYou: return p.accent;   // drawn with a ring around it
        default: return p.faint;
    }
}

}  // namespace solstream
