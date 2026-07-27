# Not built

This directory holds the beginnings of a Sunshine fork: an API surface and a
named-pipe server intended to be linked *into* Sunshine so it could be told which
window to encode.

It is no longer part of the build. `add_subdirectory(windows/sunshine)` has been
removed from the root `CMakeLists.txt`.

## Why

Nothing links it. It builds a `sunshine_fork` static library that no other target
consumes, no target produces a `Sunshine.exe`, and no file outside this directory
includes any of these headers. It has been dead weight rather than work in
progress.

More importantly, the premise turned out to be wrong. **Sunshine does not need
modifying for SolStream** — everything the product relies on is reachable through
configuration:

- which display to capture — `output_name` in `sunshine.conf`, taking the device
  id that Sunshine logs at startup
- the capture backend — `capture = ddx`
- pairing without a browser — its own local `/api/pin`, which the agent already
  drives (see `windows/SolStreamAgent/README.md`)

Everything single-application about SolStream happens on the two ends instead: the
agent places the window, and the Mac crops it out of the frame.

That matters beyond saving effort. Sunshine is GPL-3.0. Shipping an unmodified
upstream binary and shipping a modified one are materially different positions,
and the second is the one that pulls in source-publication obligations.

## If a fork ever becomes necessary

The one thing configuration cannot buy is encoding a **sub-rectangle** of a
display. Sunshine encodes the whole capture display, so a window smaller than the
canvas spends bitrate and encoder time on pixels nobody sees. Today the seeded
mode ladder keeps the canvas close to the window, which makes the waste small.

If that stops being good enough, this is where that work would start — and it
should start by re-reading the licence position first, not the code.
