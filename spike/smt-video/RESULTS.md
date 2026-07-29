# Video packetizer and reassembly — step 5

## Result after the fix

```
  frames complete      300 of 300      frames CORRUPT   0      partial   0
  sender sent          9100 datagrams in 5.00s = 21.4 Mbit/s, 1821 pkt/s
  receiver got         9100                     -> ZERO loss
  first fragment -> complete:  p50 10.51 ms   p95 14.29   max 85.23
```

Metering to a rate with **no frame-period cap** eliminates the keyframe loss
entirely. Two bugs were fixed together:

1. **The frame-period cap.** Giving a 240 KB IDR the same 16.7 ms as a 40 KB
   P-frame still bursts at six times the average rate. A frame may not start
   before its capture time, but it *may* finish after its period — 240 KB cannot
   cross a 25 Mbit/s path in 16.7 ms whatever the schedule says.
2. **Drift.** Each frame's deadline was taken relative to a fresh reading at the
   top of that frame, so every frame's overhead was added to the next one's
   start. 300 frames turned a 5 s run into 9.3 s — a "60 fps" sender actually
   running at 32, with every throughput figure it printed wrong by the same
   factor. Anchoring every slot to one absolute origin makes drift impossible
   rather than small.

**The cost, stated honestly.** Reassembly latency rose from p50 3.2 ms to
10.51 ms, and the worst case from 19 ms to 85 ms. That is not a regression — it
is the pacer doing its job. A 40 KB frame metered at 25 Mbit/s occupies 12.8 ms
of wire by definition, and a 240 KB IDR occupies 76.8 ms. The measured p50 and
max match those two numbers almost exactly, which is the check that the pacer is
metering to the rate it was told and not to something else.

**And it settles the frame-closure argument for the third time.** An IDR now
legitimately spans 85 ms. The design's closure timer is 25 ms. Anchored to a
frame's *first* fragment it would declare every keyframe damaged; anchored to the
*last received* fragment, as the adversarial review insisted, it does not. That
is now supported by the RTT tail (step 3), by the unpaced loss below, and by the
paced span here.

**Still not known: the path's actual ceiling.** 25 Mbit/s was given, not
measured, and produced zero loss. The rate a real host meters to has to be
estimated from feedback, and nothing here does that yet.

---

## What it looked like before the fix


Synthetic frames, no encoder: byte *i* of frame *n* is `(n*31 + i*17) & 0xFF`, and
the receiver regenerates the same bytes and compares. Verification is against an
independent computation, not a hash the sender chose — a hash both ends compute
the same wrong way agrees with itself.

300 frames, 40 KB P-frames with a 240 KB IDR every 60th, Mac ← dev box.

```
  frames complete      295 of 300
  frames CORRUPT       0
  frames left partial  5   -> 1 61 121 181 241   (every IDR, and only IDRs)
  sender sent          9100 datagrams, 13,364,000 bytes, 11.5 Mbit/s
  receiver got         8792                       -> 308 lost, 3.4%
```

## Proven

**Byte-offset reassembly is correct.** Zero corrupt frames across ~8800
datagrams and four runs. `fragOff` as a byte offset rather than a fragment index
makes a fragment a `memcpy` at `base + off`, which is what lets variable-length
fragments — the shape slice-early sending produces — reassemble with no index
arithmetic at all.

**Reassembly is cheap.** First fragment to complete frame: p50 3.2–3.9 ms, p95
6.4–8.7 ms.

**The loss is real, not the instrument.** The sender counts 9100 and the receiver
counts 8792. That was worth establishing before anything else, and it was not
established first: three separate changes were made — pacing the sender, raising
timer resolution, preallocating the receiver's buffers — before anyone asked the
sender what it had sent. All three left the result identical, which should have
prompted the question sooner.

## The keyframe loss is real and reproducible

Every IDR loses fragments; no P-frame ever does. Four runs, four times the same
five frame numbers.

**And the pacer here implements the wrong half of the fix.** The adversarial
review's critical finding #5 says to pace at `bytes / measuredRate` **with no
frame-period cap**. This spike paces each frame across its own period, which is
the capped version — so a 240 KB IDR gets one frame period, the same as a 40 KB
P-frame, and therefore still bursts at six times the average rate. At 11.5 Mbit/s
average that is a ~62 Mbit/s burst, and 3.4% of it does not survive.

That is a validation of the review by accident: implementing the capped version
reproduces exactly the failure the review predicted for it.

## Not measured properly

- **The frame rate.** The sender took 9.30 s for what should be 5 s at 60 fps, so
  it actually ran at ~32. `timeBeginPeriod(1)` is set, but the spin-wait sleeps
  1 ms whenever more than 2 ms remains, and overshoots. The throughput and
  Mbit/s figures are therefore lower than a real 60 fps stream would produce.
- **Loss under a correct pacer**, which is the next thing to try.
- Wi-Fi, and any path that is not this one.
