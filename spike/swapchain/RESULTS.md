# The ceiling, and the swap-chain question

Run 2026-07-29 on the dev box (RTX 4070 SUPER, Windows 11), streaming the virtual
display at **3600×2338** — 8.4 megapixels, slightly more than 4K — to a Mac over
Tailscale.

## The pipeline sustains 49 fps at 4K-class resolution, with no loss

```
  48.3 fps, 19.5 Mbit/s | capture 245, encoder 242/242 (dropped 0, extra samples 0)
  48.9 fps, 18.0 Mbit/s | capture 490, encoder 487/487
  49.4 fps, 16.8 Mbit/s | capture 738, encoder 735/735
  glass->wire   last 15.1   min 6.4   mean 20.6 ms
  client: 1,458 pictures, 0 damaged
```

Every earlier throughput figure was bounded by what the **test content** could be
drawn at, not by the path: a still desktop gives ~17 fps because that is how much
changed, and `spike/animate` gave 33.6 because a scalar 8 MB fill per frame is
what GDI could manage. This window presents 6,698 fps — 137 times what the
pipeline took — so for the first time the limit measured is the pipeline's own.

**The limiter is capture delivery, not the encoder or the transport.** Capture
delivered 245 frames in five seconds; the encoder emitted 242 of them and the
sender kept up with all of them. Nothing queued, nothing was dropped, and the
encoder sat at its 20 Mbit/s cap the whole time, which is what a rate control
doing its job looks like.

Latency rose from the 9.7 ms measured against a near-idle desktop to 20.6 ms
mean, which is what a pacer under real load should do: at 20 Mbit/s each frame is
~50 KB, and the pacer meters at twice the bitrate, so a frame takes ~10 ms to
leave. The **minimum is unchanged at 6.4 ms** — the path did not get slower, it
got busy.

## WGC sees swap-chain content, in both modes

The open question was disqualifying if it went the other way: the old display
capture rendered Windows Terminal as a solid black rectangle with its chrome
drawn correctly around it, the classic symptom of a capture that composites a
window's GDI surface and misses what DirectX presented into it. Terminals,
browsers and games are the applications worth streaming.

`spike/capture-probe` attaches to this window twice — once per-window, once
per-display — and counts how many **distinct** centre pixels each sees. A capture
that is blind still delivers frames; they are simply all the same, which is
exactly how this failure looks like success until somebody looks at the picture.

```
  window capture      244 frames, 243 distinct centre pixels  -> SEES THE CONTENT
  display capture     244 frames, 244 distinct centre pixels  -> SEES THE CONTENT
```

Flip-model swap chain, `DXGI_SWAP_EFFECT_FLIP_DISCARD`, presenting with no vsync.
Both modes see it.

## The trap this walked into first

The first run of this spike showed **bare wallpaper** where the window was
supposed to be, while the window itself reported `visible=1` at exactly the
coordinates it had asked for. Nothing had failed. The window was on a different
monitor.

`SetProcessDPIAware` makes a process **system**-DPI-aware, and Windows then
virtualises its coordinates on any monitor whose scale factor differs from the
primary's. A window asked for at 2560,0 — the left edge of the virtual display at
200% — was created on the primary monitor instead. Both halves reported their own
truth and neither was wrong.

`SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` is
what makes a coordinate a real pixel. It is worth printing the monitor a window
landed on rather than the coordinates it was given: the second is what you asked
for, and only the first is what happened.

## Still unanswered

- **Why 49 and not 60.** Capture delivery is the limit, and whether that is
  WGC's per-frame cost at 8.4 megapixels, the virtual display driver's own
  refresh, or DWM composition is not established. At 1080p it may not bind at all.
- **Behaviour under real loss.** 0 damaged pictures in every run so far means no
  recovery tier has ever been exercised. A network that actually drops packets is
  a different measurement and this is not it.
- **One machine.** RTX 4070 SUPER, Windows 11. AMD, Intel and Windows 10 remain
  untested.
