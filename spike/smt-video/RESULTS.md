# Video packetizer and reassembly — step 5

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
