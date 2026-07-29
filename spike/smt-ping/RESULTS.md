# SMT/1 transport core — first real numbers

Step 3 of the build order. No media, no encoder, no handshake: a UDP socket, the
8-byte header, AES-256-GCM, the counter and the replay window, with the keys
taken from the frozen cross-language vector so the wire is measured with nothing
else in the frame.

Mac → dev box (`100.101.102.103`), 300 packets at 5 ms intervals, 2026-07-29.

```
  replies      300 of 300   lost 0   unauthenticated 0
  min          2.137 ms
  p50          4.892
  p95         10.012
  p99         17.603
  max         37.430
  mean         5.666
  jitter       2.025      (mean |RTT(n) - RTT(n-1)|, in arrival order)
```

## The path is not a bare LAN

`tailscale status` reports **`direct 192.168.1.21:41641`** — a direct LAN path,
but wrapped in WireGuard at both ends. So these figures include userspace VPN
encryption and decryption on the round trip. A plain LAN would be lower; this is
the number for the setup that actually exists.

**One way is roughly 2.4 ms at the median.** The design brief assumed "LAN RTT is
0.5–2 ms", so it was optimistic by roughly 2.5×.

## What the tail says about a design decision

p99 is **17.6 ms** and the worst sample **37.4 ms** — both larger than a 60 fps
frame period. The design's frame-closure timer is 25 ms, which sits inside that
tail, and the adversarial review already argued it must start at a frame's *last*
received fragment rather than its first. This measurement is independent support
for that: a timeout in the same range as normal tail latency will fire on
healthy traffic if it is anchored to the wrong event.

## The replay window is proven, by accident

Running the client twice without restarting the responder gave **0 of 300** on
the second run. That is correct behaviour, not a fault: the client restarts its
counter at 0, and under a *fixed* key those counters had already been seen.
Restarting the responder — so the window is empty — accepted the same 300
counters again.

In the real protocol every session does a fresh handshake, so a counter restart
happens under a different key and is not a replay. Here the key is pinned by the
frozen vector, which is what turned a design property into an observable one.

## Two instrument bugs, both caught

**Jitter was computed on sorted samples**, which measures the mean gap in the
distribution rather than what a receiver has to absorb between consecutive
packets. It read **0.132 ms** where the real figure is **2.025 ms** — plausible,
stable, and wrong by 15×. Jitter can only be computed in arrival order.

**A kill that never ran.** The attempt to restart the responder chained commands
with `&`, and the host's SSH shell is PowerShell, where `&` is not a statement
separator. The command silently did nothing, the original process survived, and
the result looked like the replay-window hypothesis failing when it had never
been tested. Confirmed by finding the same PID still running.

## Not yet measured

- Loss and jitter over Wi-Fi rather than Ethernet.
- Behaviour at video rates: this ran at 200 packets/s, and video is ~2500.
- Cost of the AEAD itself, which is hidden inside the round trip here. The
  responder opens one algorithm handle per packet, which a real implementation
  would hoist.
