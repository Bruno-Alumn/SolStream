# SolStream architecture

What is actually built, as of the SMT/1 rewrite. This file previously described
a Sunshine fork sharing D3D11 textures with a `CaptureHelper` process over named
pipes, with signature verification on every spawned helper and a keyed-mutex ring
buffer between them. **None of that was ever built**, and the code that had been
written towards it has been deleted. Treat any surviving copy of the old text as
a design that lost.

## Two programs

```
   macOS                                        Windows
   ┌────────────────────────┐                   ┌──────────────────────────────┐
   │ SolStream.app          │  TCP 47630        │ SolStream.exe                │
   │                        │◄─── newline ─────►│                              │
   │  ConnectWindow         │      JSON         │  window + app enumeration    │
   │  AppPicker             │                   │  placement, focus, clipboard │
   │  AppWindow × N         │                   │  cursor shape, launch        │
   │  StreamSession         │                   │  auth v2 (HMAC challenge)    │
   │   └ VideoDecoder       │                   │  media key agreement         │
   │   └ AudioRenderer      │                   │                              │
   │   └ InputCapture       │  UDP 47631        │  media/                      │
   │   └ MediaClient ───────┼◄─── SMT/1 ───────►│   capture.cpp   (WGC)        │
   │                        │  AES-256-GCM      │   encoder.cpp   (MF, H.264)  │
   │                        │                   │   audio.cpp     (WASAPI)     │
   │                        │  UDP 47629        │   input.cpp     (SendInput)  │
   │                        │◄─── discovery ────│   session.cpp   (the socket) │
   └────────────────────────┘                   └──────────────────────────────┘
```

Three ports. Nothing else listens.

## The agent channel — TCP 47630

Newline-delimited JSON, sixteen commands: window and application enumeration,
launch, focus, placement, geometry locking, the clipboard, the cursor shape, the
display list, and the media session.

Authentication is **v2 only**. The host sends a challenge in its `hello`; the Mac
answers `HMAC-SHA256(token, "SolStream agent auth v2" || challenge || cnonce)`.
The token never crosses the wire, and there is no v1 fallback — keeping one would
mean anyone who answered on 47630 first was handed the token in cleartext, and
the token is the root of every media key.

**The channel is encrypted from the auth reply onwards**, with keys derived from
the same challenge, nonce and token that just proved possession — so it costs no
extra round trip. Framing switches at that exact message: newline-delimited JSON
before it, four-byte-length-prefixed AES-256-GCM records after. Both ends
negotiate it in the greeting, because a mismatch is not a degraded channel but a
socket where each end reads the other's bytes as the wrong thing.

It **is forward secret**. The proof message carries an ephemeral P-256 public
point and the reply carries the host's; the shared secret is mixed with the token
into the same HKDF and then discarded, so someone who later learns the token
cannot decrypt a session they recorded. The token being in the input key material
is what stops a man in the middle substituting a point: without it they derive
keys neither end will use, so every record fails its tag and the connection drops
— a detected failure rather than a silent compromise.

The reply also carries `hostAuth`, twelve bytes of the same expansion. That is
the only thing in the handshake that authenticates the **host** to the Mac; the
challenge-response runs the other way. The Mac refuses to switch if it disagrees.

**One Mac at a time.** A knock while a Mac holds the session is answered with
`busy` before any `hello`. A Mac whose network changed under it leaves a socket
the PC cannot see is dead, so its reconnect meets its own old session. Two
things deal with that, each working without the other:

- The Mac sends `client`, a random id kept per install, with its auth proof.
  The host's `busy` offers `"takeover":1` and a fresh `challenge`; a Mac that
  understands answers `{"cmd":"takeover","client","cnonce","proof"}`, where
  `proof = HMAC-SHA256(token, "SolStream agent takeover v1" || challenge ||
  cnonce || client)`. The host ends the old session only if the ids match and
  it has been silent for 15 s (a missed heartbeat), then greets the Mac on the
  same socket with an ordinary `hello`. Otherwise it answers `busy` again with
  `"holder":"self"` (wait) or `"holder":"other"` (final). A Mac that never sent
  an id is never taken over, and a Mac that predates the offer ignores it.
- A Mac reconnecting after losing a session treats a `busy` that names nobody
  (an older host) as "wait", and knocks again for 45 s, past the host's 30 s
  idle timeout, before showing it. A first connection still treats it as final.

## The media path — UDP 47631

`docs/transport-smt1.md` is the protocol. In summary: eight cleartext bytes
(version, session tag, 48-bit counter), AES-256-GCM over everything else with
that header as the AAD, and a deterministic nonce built from a per-direction
secret fixed field and the counter. The packet type is inside the AEAD.

Keys come from an ephemeral P-256 ECDH exchanged over the agent channel with the
token mixed into the input key material, expanded to 108 bytes with HKDF-SHA256.
Both ends print a 12-byte proof of what they derived and compare it before a
single datagram is sent.

On the host:

- **Capture** is Windows.Graphics.Capture, which survives occlusion and delivers
  only when something changes. The last frame is retained and re-encoded on a
  250 ms heartbeat, because a still window otherwise has no next frame in which
  to repair damage.
- **Encode** is a hardware H.264 MFT fed an `ID3D11Texture2D`. BGRA→NV12 happens
  on the GPU through `ID3D11VideoProcessor`, which does the scaling too. The
  frame never touches the CPU.
- **Pacing** meters to a rate with no frame-period cap. Spreading a keyframe
  across its own frame period loses about 3.4% of every keyframe and none of the
  P-frames; `spike/smt-video/RESULTS.md` has the measurement.
- **Audio** is WASAPI loopback, downmixed and resampled to 48 kHz stereo. It is
  sent as S16 in 5 ms packets, or, when the Mac asks for it in `media open`, as
  Opus (libopus, restricted low delay) at 64, 128 or 256 kbit/s in 10 or 20 ms
  packets. Every packet's format byte says which, so a host that predates Opus
  simply goes on sending PCM, and the Mac plays it as before. The Mac decodes
  Opus with AudioToolbox.

On the Mac: reassembly by byte offset, a picture closed 25 ms after its LAST
fragment, VideoToolbox for decode, AudioToolbox for Opus and AudioUnit for
playback, and a 10 ms timer that
repeats unacknowledged input until the host's ack covers it.

## Discovery — UDP 47629

The Mac broadcasts `SOLSTREAM-DISCOVER/1`; a host answers `SOLSTREAM-HOST/1
<name>`. It discloses a computer name to anyone on the same segment and grants
nothing. Broadcast does not cross subnets or traverse a VPN, so typing an address
remains the way to reach anything discovery cannot see.

## The virtual display

Still here, and still the reason a streamed application looks like an
application rather than a rectangle cut out of somebody's desktop: windows are
parked on a display with no physical panel, sized to the Mac.

Windows.Graphics.Capture can capture a **window** directly — `spike/wgc-capture`
proved it works from an unpackaged binary, with the yellow border off, and
through full occlusion. Doing that would delete the driver, the mode ladder, the
DPI setting, the HDR trap and the whole "something was dragged over the streamed
window" class of bug. It is not done yet: the current path captures the display
and crops, which is what lets several windows share one encoder.

## What is measured, and what is not

| | |
| --- | --- |
| Capture → last byte on the wire | 6.7 ms best, 9.7 ms mean, at 3600×2338 |
| Loss, over Tailscale, video | 0 damaged pictures across every run so far |
| Audio | 198 packets/second, matching the 5 ms packet rate exactly |
| Input | lands within a pixel of where it was aimed |
| Sustained frame rate | **49 fps at 3600×2338**, capture-bound; the encoder and transport kept up with all of it |
| Swap-chain applications | WGC sees them, per-window and per-display alike — not black rectangles |
| Behaviour under real loss | **unmeasured**; no recovery tier has been exercised |
| Windows 10, AMD, Intel | **untested**; every figure here is one RTX 4070 SUPER on Windows 11 |
