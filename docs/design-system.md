# Solar — SolStream's design system

One system for both programs. The Mac client (`macos/SolStreamClient/Sources/DesignSystem/DesignSystem.swift`) and the Windows host (`windows/SolStreamAgent/host_theme.h`) carry these exact values; if one changes, both change in the same commit.

It replaces Nocturne (navy ground, muted blurple accent). Nocturne was coherent but dim: every surface sat within a few steps of navy, the only accent was a desaturated purple, and monospace carried most labels, so nothing on screen had a clear first thing to look at.

## Idea

*Sol* is the sun. The chrome is a deep, neutral graphite — still the darkest thing on screen, so a streamed app stays the brightest — and there is **one warm accent, sun amber**, used for the single most important thing on each screen: the primary button, the selected row, the live dot, the focus ring, the mark. Everything else is neutral.

State gets real hues now, but only two and only small: a green dot for live and a coral one for failed. Severity is still carried by the words; the colour just makes it findable.

## Colour

Every token is a role, with a dark and a light value. Drawing code never knows which theme it is in.

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `ground` | `#0E0F12` | `#F7F6F3` | window background |
| `surface` | `#17191E` | `#FFFFFF` | cards, fields, list background |
| `raised` | `#20232A` | `#EFEDE8` | hovered row, secondary button, chips |
| `hairline` | `#2A2D35` | `#E4E1DA` | separators, resting borders |
| `edge` | `#3A3E48` | `#CFCBC2` | hovered borders, floating panels |
| `text` | `#F2F2F4` | `#17181B` | primary text |
| `textSecondary` | `#A9ADB8` | `#4A4E57` | supporting text |
| `textMuted` | `#7C818D` | `#6A6F79` | labels, captions |
| `textFaint` | `#5A5F6B` | `#9A9EA6` | placeholders, disabled |
| `accent` | `#FFB547` | `#F59E0B` | primary button fill, live mark, focus ring, caret |
| `accentHover` | `#FFC56E` | `#FBB13C` | primary button hover |
| `accentPressed` | `#E89A2A` | `#D97706` | primary button pressed |
| `onAccent` | `#1A1205` | `#1A1205` | text on a filled accent |
| `accentInk` | `#FFC66B` | `#B45309` | accent used as text or a 1px line on `ground`/`surface` |
| `accentTint` | `#2B2418` | `#FDF0DA` | selected row, text selection, primary-tag ground |
| `accentTintInk` | `#FFD699` | `#8A4B06` | text on `accentTint` |
| `live` | `#4ADE80` | `#16A34A` | live / connected dot |
| `danger` | `#FF6B6B` | `#DC2626` | failed dot, destructive text |

Contrast: `text` on `ground` and `surface` is ≥ 14:1 in both themes; `textSecondary` ≥ 7:1; `textMuted` ≥ 4.5:1; `onAccent` on `accent` ≥ 8.5:1; `accentInk` on `ground` ≥ 4.5:1. `textFaint` is for placeholders and disabled labels only, never for anything that must be read.

## Type

- **Mac:** SF Pro (system font) for all UI text. SF Mono only for addresses, tokens and live numbers.
- **Windows:** Segoe UI Variable (Display ≥ 20 DIP, Text below). Cascadia Mono only for addresses, tokens and live numbers.

| Role | Size | Weight |
| --- | --- | --- |
| `display` | 26 | semibold |
| `title` | 20 | semibold |
| `headline` | 15 | semibold |
| `body` | 13 | regular |
| `caption` | 11 | medium |
| `mono` | 12 | regular |

Labels are sentence case. No all-caps, no letter-spacing tricks.

## Space and shape

Spacing scale: 4, 8, 12, 16, 20, 24, 32, 48. Window content inset: 24.

| Thing | Radius | Height |
| --- | --- | --- |
| button | 8 | 32 |
| field | 8 | 36 |
| list row | 8 | 48 (two-line) / 36 (one-line) |
| card | 12 | — |
| chip | 6 | 20 |
| app icon tile | 8 | 32 |
| status dot | full | 8 |

## Components

- **Primary button** — `accent` fill, `onAccent` text, no border; `accentHover` / `accentPressed`. One per screen.
- **Secondary button** — `raised` fill, `hairline` border, `text` ink; hover lifts the border to `edge`.
- **Field** — `surface` fill, 1px `hairline` border; focused, the border becomes a 2px `accent` ring. Caret `accent`, selection `accentTint` / `text`.
- **Row** — transparent at rest; hover `raised`; selected `accentTint` with `accentTintInk` subtitle and a 3px `accent` bar on the leading edge.
- **Card** — `surface` fill, 1px `hairline` border, radius 12, inset 16.
- **Chip** — `raised` fill, `textMuted` caption text, radius 6.
- **Status dot** — 8px: `live` connected, `accent` (pulsing) working or waiting, `danger` failed, `textFaint` idle. Reduce Motion stops the pulse.
- **Hairline** — 1px `hairline`, never a box.

## The mark

Unchanged in shape (a hairline frame for the host display, a solid rectangle for the application crossing its right edge). Recoloured: tile `surface`, tile edge `hairline`, frame `edge` (brightened at small sizes), application rectangle `accent`.
