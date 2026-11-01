# The logo

SolStream's logo is a looped ribbon, white turning to cyan, on an electric-blue
tile. `source.png` is the artwork as it was delivered: the tile on a white page,
1254 pixels square. Every icon both applications ship is cut from it.

## Regenerating

    assets/logo/build.sh

Needs a Mac and nothing installed. `make-icons.swift` cuts the tile out of the
white page, draws every size with CoreGraphics, packs the `.icns` with
`iconutil` and assembles the `.ico` itself. It writes:

| Output | Used by |
| --- | --- |
| `macos/SolStreamClient/Resources/AppIcon.icns` | the Mac app: Dock, Finder, the connect window |
| `windows/SolStreamAgent/SolStream.ico` | the Windows host: taskbar, tray, Explorer, shortcuts, and the logo in its window |
| `docs/media/logo.png` | the README |
| `out/preview-512.png`, `out/preview-sizes.png` | for looking at, not committed |

The outputs are committed. Regenerating is a deliberate act with a visible
diff, rather than something a build does silently.

## How the tile is cut out

The white page is found by flood-filling from the four corners, so the white
of the ribbon inside the tile is never touched. Pixels along the tile's edge
are the blue blended into white; they get back the transparency they were
blended from, so the icon has no white fringe on a dark Dock or taskbar.

Small sizes are made by halving the image step by step rather than in one
draw, which keeps the dark lines inside the ribbon from going ragged. Look at
`out/preview-sizes.png` after any change: at 16 pixels the ribbon should still
read as a loop.

## Platform differences

- **macOS:** the tile is 824 of 1,024 pixels, centred, with a soft shadow:
  Apple's icon grid, so it sits at the same size as other apps in the Dock.
- **Windows:** the tile fills the icon, less a hair at 32 pixels and above.
  The `.ico` carries 38, 57 and 76 pixels as well as the usual sizes, because
  the host window draws the logo at 38 DIP and copies it from the icon at
  100%, 150% and 200% scaling rather than scaling it.

## Colours

The interface's accent comes from the logo (`docs/design-system.md`):

| Role | Dark theme | Light theme |
| --- | --- | --- |
| Accent: buttons, focus ring, selection | `#2A64F5` | `#1652F0` |
| Accent as text | `#6CC4FF` (the logo's cyan) | `#0B45D6` |

The fill is a shade deeper than the logo's brightest blue so that white
button text on it still reads at 5:1.

## Don't

- Don't recolour the logo or put it on a tile of another colour.
- Don't stretch it, crop the tile, or draw the ribbon without its tile.
- Don't set it smaller than 16 pixels.
