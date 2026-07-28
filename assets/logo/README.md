# The mark

Two rectangles, because that is what the product is.

SolStream's whole idea is a rectangle cut out of a bigger rectangle and
delivered untouched. That is already a mark, so this one draws no sun, no
monitor, no cloud and no play triangle: **a hairline frame is the host display,
one solid accent rect is the application, and the accent straddles the frame's
right edge** — half on the PC, half on the Mac. The overlap is the product's
actual claim: not a picture of a remote screen, a window that crossed a boundary
and stopped being remote.

It is directional (the accent leads right, out of the host and toward the
viewer), the accent is the dominant shape (so the application is the subject and
the PC is the frame it left), it survives 16px, and it needs no gradient.

## Regenerating

    assets/logo/build.sh

Draws every artboard with CoreGraphics, packs the `.icns` with `iconutil`, and
assembles the `.ico` by hand. Needs a Mac and nothing installed. It writes:

| Output | Used by |
| --- | --- |
| `windows/SolStreamAgent/SolStream.ico` | linked into the executable by `resources.rc.in` — the taskbar, Explorer, the shortcuts and the title bar |
| `macos/SolStreamClient/Resources/AppIcon.icns` | copied into the bundle by `scripts/package-macos.sh` |
| `out/preview-512.png` | for looking at |
| `out/preview-small.png` | the hand-drawn artboards at 10x on their own pixel grid |
| `out/template-*.png` | monochrome, no tile, for a menu-bar or tray item |

**The outputs are committed.** Regenerating is a deliberate act with a visible
diff, rather than something a build does silently: an icon that changed because
a toolchain updated is an icon nobody reviewed.

## The one thing to know before changing it

**Below 32px the mark is a redraw, not a scale.** Scaled proportionally, the
overlap between the frame and the accent reaches two pixels and the two shapes
fuse into one blob — at exactly the sizes that appear in the taskbar, the Start
menu and the menu bar. So 16, 20 and 24 are separate artboards with whole-pixel
coordinates, square corners, and the accent **clearing** the frame by one pixel
instead of crossing it. At those sizes the crossing is implied by the two bands
overlapping vertically, not by contact.

32 and 48 keep the real crossing, but their rectangles are snapped to whole
pixels: the design's fractions land on quarter-pixels there, and Core Graphics
duly anti-aliases a one-pixel hairline across two columns at half strength each,
which arrives in the taskbar looking like a low-resolution icon rather than a
small one.

Look at `out/preview-small.png` after any change. At real size a wrong pixel is
invisible.

## Platform differences

- **macOS** masks icons into a squircle, so the tile is drawn at 22.4% radius and
  16 and 32 are their own artboards rather than downsamples of 1024 — which is
  what the `.icns` format is for.
- **Windows** masks nothing, so the tile has square corners: it is the shape it
  will actually be seen as. Same art otherwise.
- The `.ico` entries are PNGs, which Windows has accepted at any size since
  Vista. The alternative is a bottom-up BGRA DIB plus a separate 1-bit AND mask
  per size, for a format nothing this ships to still needs.

## Don't

- No gradient in the mark or the tile — the accent is one flat value.
- Don't centre the inner rect. Centred, it becomes a record button.
- Don't add a third rectangle to mean "more windows". Two is the idea.
- Don't outline the accent rect or fill the frame — the contrast between line
  and solid is the whole mark.
- Don't rotate, skew, or set it in perspective to imply motion.

## Colours

Nocturne tokens, copied literally rather than derived:

| Role | Dark | Light |
| --- | --- | --- |
| Tile | `#232532` | `#e4e7f5` |
| Tile hairline | `#3f424d` | `#cfd3e5` |
| Frame | `#595d6c` (`#75798c` at 32/24, `#9397ab` at 20/16) | `#9397ab` |
| Accent | `#9184d9` | `#5d5294` |

The frame brightens as the artboard shrinks because a hairline at one pixel
against a dark tile loses its contrast long before it loses its shape.

## The wordmark

Inter 500 on the design surfaces, Segoe UI Variable 500 in the Windows
application — no bolder. Tracking −0.025em at 30px and above, −0.02em below; one
capital S each, set solid with no space. Never a second weight inside the word,
never letterspaced out, never all-caps.

In the horizontal lockup the mark's **artwork** is as tall as the wordmark's cap
height, and the gap between them is that height ÷ 2.5. The artwork is the middle
48% of the tile, so a 28px wordmark (cap height 19.6) wants a 41px tile — which
is also the design's own 44-tile-against-30-type proportion, arrived at from the
other end. `DrawLockup` in `windows/SolStreamAgent/host_window.cpp` is that rule
written down.

Clear space, when placing the mark: measure from the mark's **bounding box**, not
the frame — the accent overhangs it on the right, so the frame is not the edge.
Clear space on all four sides is the accent rect's height.
