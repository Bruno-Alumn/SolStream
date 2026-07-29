# SMT/1 — SolStream Media Transport

The transport that replaces GameStream. Designed clean-room from requirements;
no Sunshine or moonlight-common-c source was consulted, and both were moved off
the project tree before this began.

## Why

SolStream owns both ends. GameStream is NVIDIA's 2013 protocol for talking to a
Shield, and every awkward thing about the current media path is a consequence of
speaking it to a third-party server: a PIN dance and an mTLS certificate factory
to pair two programs that have already authenticated each other, seven RTSP
round trips to start a session both ends already agree on, Reed–Solomon FEC
because the far end cannot be asked to re-encode, and an IDR-per-loss recovery so
expensive it had to be rate-limited to twice a second.

None of that is needed between two programs that ship together.

## What stays

The agent channel — TCP 47630, newline-JSON, token-authenticated, sixteen
commands. It already does app enumeration, window placement, the clipboard,
launching, display selection and the cursor. **It is not GameStream and it is not
being replaced.** SMT/1 is the media path only, and it is started by one new
command on that channel.

## Wire format

Eight cleartext bytes on every datagram. Everything else, including the packet
type, is inside the AEAD.

```
off  w  field
 0   1  verEpoch   high nibble = version (1); low nibble = key epoch mod 16
 1   1  sessTag    low byte of the derived 32-bit session id
 2   6  counter    48-bit big-endian, per-direction AEAD invocation number
 8   N  ciphertext
8+N 16  tag        AES-256-GCM
```

AAD is those eight bytes verbatim. The tag goes **after** the ciphertext so the
sender builds one buffer and encrypts in place at offset 8, and the receiver
`recvfrom`s into a pooled buffer and decrypts in place — no assembly step on
either side.

`sessTag` is eight bits of a truncated secret. It is never trusted: its only jobs
are demuxing an old and a new session during the moment they coexist, and
rejecting 255/256 of a forged flood with a byte compare instead of a GCM verify.

Fixed overhead 24 bytes; video adds a 16-byte inner header. At a 1500 MTU that is
1432 bytes of coded video in a 1472-byte payload — 97.3%, with no FEC parity.

Big-endian throughout, no exceptions. (`InputProtocol.swift:15` documents a
little-endian keycode inside an otherwise big-endian packet and calls the
asymmetry deliberate. It is not carried over.)

## The nonce, which is the part that must not be wrong

```
N(d, e, i) = F(d, e) || BE48(i)
```

`F(d,e)` is a secret six-byte fixed field per direction and epoch, **never
transmitted**. `i` is the 48-bit counter, carried verbatim in header bytes 2..7.
This is the NIST SP 800-38D §8.2.1 deterministic construction: fixed field plus
invocation field.

The counter is carried at **full width** rather than truncated and reconstructed.
Five bytes per packet — about 0.5% of a 20 Mbps stream — buys the removal of an
entire class of reconstruction bug from the one place in the system where a bug
is silent and catastrophic. AES-GCM's nonce is 96 bits, which is far too short to
choose at random; nothing here is chosen at random.

ChaCha20-Poly1305 was considered and rejected: BCrypt does not have it, so it
means shipping a constant-time stream cipher on Windows to run software crypto on
a machine with AES-NI. The only thing it buys is a nonce wide enough to randomise,
which is the property this construction is designed not to need.

## Six critical defects, found by attacking the design, and their fixes

Three independent adversarial passes — a cryptographer, a performance engineer
and someone walking the ugly paths — found 7 critical and 15 major defects. The
cryptography survived intact; every critical failure was in the layers above it.
All six fixes below are folded into the design above and cost no protocol change.

**1. Recovery assumes a frame that will never come.** Every recovery tier ends in
"encode the next frame". WGC is change-driven: `spike/wgc-capture/RESULTS.md`
measured 241 frames for 240 paints and concluded a still window costs nothing.
So when a static window's last frame is damaged, there is no next frame, the
repair never happens, and the corruption persists until the user moves something
— seconds to minutes.
→ **Keep the last captured texture alive and re-submit it to the encoder on
demand.** One retained texture, one force-encode entry point.

**2. A lost final key-up is a permanently stuck, auto-repeating key.** The
redundancy window repeats recent events on *subsequent* datagrams, and when the
user stops typing there are none. The gap detector needs a later packet to notice
the hole. `InputCapture.swift:328` already names this failure in a comment.
→ **Retransmit the highest event on a 10 ms timer until `inputAck` covers it**,
giving up after ~300 ms. Two lenses found this independently.

**3. Repair frames are never repaired.** The host ignores a recovery request
naming a frame it has already answered — but if the repair itself is lost, the
client keeps naming the same frame and is ignored forever.
→ **Suppress on confirmation, not on request.**

**4. The counter resets on rekey, and everything above it assumes monotonic.**
The loss detector, the NACK space and the retransmit ring all index on the
counter; a ten-minute rekey sends it to zero and all three break at once, twice
per session, in both directions.
→ **Never reset it.** 2^48 at 2500 pps is 3,570 years. This also deletes the CAS
and the guard band — the fix makes it simpler, not safer-but-uglier.

**5. Keyframe storm on Wi-Fi.** The frame-closure timer fires 25 ms after a
frame's *first* fragment; an IDR on a 20 Mbps path takes 80–160 ms to arrive, so
it is declared damaged before it lands, requesting another.
→ **Close 25 ms after the LAST fragment** (an idle timeout, the standard
reassembly rule), and drop the `min(framePeriod, …)` cap in the pacer.

**6. The v1 auth fallback is a token-disclosure oracle.** Keeping the legacy
`{"cmd":"auth","token":…}` path means anyone who answers on 47630 first gets the
token in cleartext — and the token is the root of all media key material.
→ **The Mac must never send the token.** If `hello` carries no challenge, report
an old agent and drop, exactly as it already does for a `needsAuth:false`
mismatch.

## v1 is smaller than the above

The design agent tasked with arguing against complexity died mid-response, so
nobody in the panel was defending simplicity. Supplying that judgement: the full
design has four recovery tiers, a chain ratchet, path validation, NACK plus
retransmit, and a pacer. **v1 ships none of the recovery layers.**

v1 is: the eight-byte header, AES-256-GCM, the counter nonce, ECDH+HKDF over the
agent channel, video fragmentation and reassembly, and a feedback packet carrying
`lastGoodFrame`. That is enough to put a picture on the Mac and **measure it**.
Every recovery tier is an optimisation against a loss rate nobody has measured on
this path yet, and the whole point of tiering is to be able to add them one at a
time against numbers.

## Build order

Each step is measurable before the next exists.

1. **Cross-language crypto vectors, no sockets.** A Windows test and a Swift test
   that print identical hex for HKDF, the transcript, the nonce and one sealed
   packet of each type.
2. **Agent auth v2, alone and shippable.** Challenge–response so the token stops
   crossing the wire. Independently valuable; ship it whatever happens next.
3. **Transport core, ping/pong only.** Socket, header, AEAD, counter, replay
   window, MTU ladder. No media. *The first real RTT numbers this project has.*
4. **The `media` command and session handshake.** Still no media.
5. **Video from a pre-encoded file**, not a live encoder, so the transport is
   measured without the encoder as a variable. Feeds the existing `VideoDecoder`.
6. **WGC encoder into the transport, slice-early.** Measures capture-to-wire,
   which `RESULTS.md` says is still unmeasured.
7. **Audio and input.**
8. **Feedback, then recovery tiers, in order, each against measured loss.**
9. **Delete the GameStream code — only after 1–8 measure well.**

## Open questions

- **Does the encoder expose LTR at all?** This gates the whole recovery scheme
  and nothing in the tree configures an encoder, so there is no evidence either
  way. Answer it before building tier 2.
- **`BCRYPT_KDF_RAW_SECRET` returns the ECDH x-coordinate little-endian** and
  CryptoKit does not. Getting this wrong means the two ends derive different keys
  and everything fails silently. Step 1 exists to catch exactly this.
- **The agent channel stays plaintext.** After this lands, the media is encrypted
  and the channel carrying window titles, application names, the display layout
  and the entire clipboard is not. The auth-v2 handshake gives it the key
  material to fix that; it should.
- **The token is a bearer secret in a plaintext file** at
  `%LOCALAPPDATA%\SolStream\agent.token`. Keychain and DPAPI are the answer.
- **IPv4 only**, inherited deliberately from the existing sockets.
- **Every quantitative claim in the full design is arithmetic, not measurement.**
  The ring sizes, thresholds and periods are reasoned from configured defaults.
  Treat them as starting values.
