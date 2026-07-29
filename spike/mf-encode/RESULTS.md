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

## Not measured: submit → first encoded byte

The run hangs after configuration. The async event loop blocks in `GetEvent`,
which means the MFT is not emitting `METransformNeedInput` — most likely
something else is still missing from the async startup sequence, and the process
had to be killed.

So `docs/transport-smt1.md`'s **3–8 ms encode budget remains arithmetic, not
measurement**, exactly as it was before this spike. The capability answer is
real; the latency answer is not, and nothing here should be quoted as one.
