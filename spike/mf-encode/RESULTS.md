# Hardware encoder — capabilities answered, latency not yet

Run on the dev box (RTX 4070 SUPER), Windows 11.

## The design's largest open question is answered: LTR is supported

```
[1] encoder: NVIDIA H.264 Encoder MFT   (1 hardware encoder present)

  LTR buffer control                 yes, currently 0
  use LTR frame                      yes  (write-only: GetValue returns E_NOTIMPL)
  mark LTR frame                     yes  (write-only)
  slice control mode                 yes, currently 2   (slices per frame)
  slice control size                 yes
  low latency mode                   yes, currently false
  rate control mode                  yes, currently 0
  force key frame                    yes
  CABAC                              yes, currently true
```

`docs/transport-smt1.md` lists *"does the encoder expose LTR at all?"* as **the
largest unknown in the design**, because the whole tier-2 recovery scheme — the
reason SolStream can drop FEC and its 20–30% bandwidth tax — depends on being
able to mark a frame as a long-term reference and later predict from a named one.

**It can.** `AVEncVideoLTRBufferControl`, `AVEncVideoUseLTRFrame` and
`AVEncVideoMarkLTRFrame` are all supported. The `E_NOTIMPL` on reading the latter
two is expected: they are commands rather than readable state.

`AVEncSliceControlMode` is available and already 2, so **slice-early sending is
possible** — an encoder that only emitted whole frames could not put anything on
the wire before a frame finished, and the design's slice pipelining would be
unimplementable whatever the transport did.

Only one hardware H.264 encoder is present on this machine, so nothing here says
what an AMD or Intel part reports. That has to be checked separately before the
recovery design is assumed portable.

## MF_E_TRANSFORM_ASYNC_LOCKED, and why it misleads

`SetInputType` returned `0xC00D6D77`. A hardware MFT is asynchronous and starts
**locked**: it refuses input types until `MF_TRANSFORM_ASYNC_UNLOCK` is set.

The trap is that `SetOutputType` succeeds anyway. So the natural reading of the
failure is that the *input* type is wrong — the wrong pixel format, the wrong
frame size, a missing attribute — and none of that is the problem. The unlock has
to happen before any type negotiation, not where it reads naturally in the setup
sequence.

## Submit → first encoded byte, and why it is an upper bound

```
  events: NeedInput 301, HaveOutput 300, other 0
  output samples (slices)  300  = 1.50 per frame
  encoded size             12.47 MB, 20.2 Mbit/s at 60 fps  (target was 20)
  submit -> first output   min 5.34   p50 15.69   p95 30.90   max 31.20 ms
```

**The p50 is not the encoder's latency.** Frames are fed from *system memory*,
so every measurement includes a 3 MB CPU-to-GPU upload the real path will never
do — WGC hands back a GPU texture and the encoder can take it directly. The
minimum of **5.34 ms** is the closer indication; the median is that plus a copy
this design intends to delete.

Even so it is worth stating plainly: `docs/transport-smt1.md` budgets **3–8 ms**
for encode, and nothing measured here reaches the bottom of that range even at
its floor. **The zero-copy GPU path is therefore not an optimisation, it is a
requirement** — if the encoder is fed from system memory the budget is missed
before the transport is involved at all.

Rate control is working: 20.2 Mbit/s against a 20 Mbit/s target.

## Slice control is accepted but does not do what was asked

`AVEncSliceControlMode = 2` and `AVEncSliceControlSize = 4` were both accepted,
and the encoder produced **1.5 samples per frame, not 4**. Accepting a control
and honouring it are different things, which is why the probe prints both what
is supported and what a set returns.

Slice-early sending still works with 1.5 — anything above 1 means bytes can leave
before a frame is finished — but the design should not assume it gets the slice
count it asks for.

## Getting this far took two non-obvious steps

- **`MF_TRANSFORM_ASYNC_UNLOCK` before any type negotiation** (see above).
- **A D3D11 device manager, also before type negotiation.** The MFT advertises
  `MF_SA_D3D11_AWARE`, and without `MFT_MESSAGE_SET_D3D_MANAGER` it accepted
  every call in the setup sequence and then emitted no events at all — which
  presents as a hang in `GetEvent` with nothing having failed.

The event loop now polls with `MF_EVENT_FLAG_NO_WAIT` against a deadline, and
counts events, so "emitted nothing" and "emitted the wrong thing" are different
answers rather than the same silence.

## Accounting still imperfect

300 samples map to 200 distinct input timestamps, so 100 submitted frames are
unaccounted for in the per-frame figures. With slices enabled several samples
share a timestamp, and the mapping from output time back to input frame is not
reliable enough to separate "two slices of one frame" from "a frame that
produced nothing". The latency samples that ARE reported each pair a real submit
with a real output; the missing hundred mean the distribution may not be
representative of every frame.
