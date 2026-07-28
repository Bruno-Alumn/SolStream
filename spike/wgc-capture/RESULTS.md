# WGC capture spike — results

Run 2026-07-29 on the dev box (RTX 4070 SUPER, primary display 2560 @ **144 Hz**),
Windows 11, from an **unpackaged** console binary. 240 paints at ~60 Hz into a
window the spike creates and captures itself.

```
[1] WGC is supported.
[2] Per-window capture item created: 786x593
[3] RequestAccessAsync(Borderless) -> 4 (ALLOWED)
[3] IsBorderRequired(false) accepted; reads back as false (honoured)

  frames delivered            241 for 240 paints
  frames while fully covered  121
  paint -> pixels, unoccluded  n=121  min 5.42  p50 17.43  p95 27.79  max 32.71
  paint -> pixels, OCCLUDED    n=120  min 2.37  p50 17.18  p95 32.90  max 54.05
```

## What is proven

**Per-window capture works, and the yellow border can be turned off from an
unpackaged binary.** This was the risk that could have forced a sparse package
or MSIX onto the project. `RequestAccessAsync(Borderless)` returned `Allowed`
and `IsBorderRequired(false)` reads back as `false`. No package identity, no
manifest, no capability declaration.

**Capture survives full occlusion.** 121 frames were delivered while a topmost
window completely covered the target, with the latency distribution essentially
unchanged (p50 17.18 vs 17.43 ms). This is the property that makes the virtual
display driver unnecessary: what is on top of the window stops mattering.

**Delivery is change-driven, not clock-driven.** 241 frames for 240 paints, on a
144 Hz display. WGC does not re-deliver unchanged content, so a still window
costs nothing — which is the right behaviour for a streaming host and something
the display-capture path had to implement for itself.

## What the latency number is NOT

**Do not quote the 17 ms median as the capture latency.** The measurement pairs a
paint with an arrival by reading a pixel back out of the captured texture, and
that read maps a staging texture — a full CPU–GPU round trip that stalls until
the copy retires. That stall is inside the measurement.

A real host never does this: it hands the captured texture straight to the
encoder on the GPU and the pixels are never read back to the CPU at all. So:

- **5.4 ms** (the floor) is the honest indication of what the path can do.
- **17.4 ms** (the median) is the floor plus a readback the product will not pay,
  plus the phase between an unsynchronised GDI paint and DWM composition.

The real figure has to be re-measured end to end against an actual encoder, with
the timestamp taken where the encoder emits its first slice. Until then, treat
this spike as answering the *feasibility* questions and not the latency one.

## What this deletes if it holds

- `windows/SolStreamAgent/vdd.cpp` and `vdd.h`
- `windows/SolStreamAgent/display_setup.cpp` and `display_setup.h`
- `windows/VirtualDisplay/setup-virtual-display.ps1`
- The "Install driver" banner and its whole advisory in `host_window.cpp`
- The HDR/PQ colour trap, the mode ladder, the DPI setting, the capture-display
  choice, `RescueStrandedWindows`, and every bug in the class of "something was
  dragged over the streamed window"

## Still unanswered, and worth a second spike before committing

1. **Swap-chain and DirectComposition applications.** The old display-capture
   path rendered Windows Terminal's content as a solid black rectangle with its
   chrome drawn correctly around it. Whether WGC window capture has the same
   problem is unknown and matters: terminals and browsers are the applications
   worth streaming.
2. **Minimised windows.** WGC is expected to stop delivering frames; SolStream
   would have to keep the window restored, or say so.
3. **A window that resizes mid-capture.** The frame pool is created at a fixed
   size and has to be recreated.
4. **Windows 10.** Everything above was measured on Windows 11 only.
