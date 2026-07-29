# SolStream — Final Convergence Record

**This is a dated record of a review round, not a description of the system.**
It was written on 18 July 2026, before the SMT/1 rewrite, when SolStream was a
front end for Sunshine and the media path was somebody else's. Most of what was
settled below was settled about a design that has since been deleted, so every
decision that no longer describes anything now carries a note saying what
actually happened instead. The record is kept because knowing which arguments
were had, and how they were resolved, is worth more than a tidy file — but
anybody wanting to know how SolStream works should read `docs/architecture.md`
and `docs/transport-smt1.md`, and treat nothing here as current.

## Third-agent fixes applied (July 18, 2026)

### Architecture Fixes

1. **Secret storage**: Changed from ProgramData to **%APPDATA%\SolStream\secrets\** encrypted with **DPAPI** (`CryptProtectData`). Per-user isolation. ProgramData \config\ retains non-secret settings only. 

   *Not what was built.* There is one secret, the pairing token, and it sits in
   plain text at `%LOCALAPPDATA%\SolStream\agent.token` (`TokenPath` in
   `main.cpp`). Nothing anywhere calls `CryptProtectData`. Encrypting it would
   defeat its purpose: the person at the Windows machine has to be able to read
   the token off their own screen and type it into their Mac, and a secret only
   the machine can read cannot be paired with by hand. What protects the channel
   is that the token never crosses the wire — the Mac proves possession with an
   HMAC over a host challenge — not where the file is kept. `%ProgramData%\SolStream`
   holds the install log, not secrets.

2. **Clipboard transport clarified**: ClipboardMonitor uses **WS (WebSocket over TCP)** for clipboard sync — confirmed reliable. UDP (port 47990) is **input-only** (keyboard/mouse packets, small payloads). Documentation clarified: no UDP for clipboard.

   *Every noun here has gone.* There is no WebSocket in either program and no
   ClipboardMonitor: the clipboard is one of the sixteen commands on the agent
   channel, newline-JSON over TCP 47630, AES-256-GCM framed from the auth reply
   onwards. Input is not on a separate socket either — it travels inside SMT/1 on
   UDP 47631, in the same AEAD as the video and audio. Port 47990 was Sunshine's
   web UI and nothing listens on it now; there are three ports in the whole
   system, and `windows/SolStreamAgent/ports.h` is the list.

### Plans Fixes

1. **Security track extended**: Security validation now runs alongside **ALL phases** (P1-P6), not just P1-2. Each phase's gate includes a security sign-off from the threat model.
2. **Pairing expiry removed**: Pairing is now **indefinite** (persists until user explicitly re-pairs). Session tokens rotate every 24h. 30-day expiry scrapped — matches Moonlight's model.

   The first half held: a token persists until somebody re-pairs, and the Mac
   keeps it per host. The rotation did not happen — nothing rotates a token on
   any clock. What does change per session is the media key material, which is
   derived fresh from an ephemeral P-256 exchange every time a media session
   opens, so a recorded session cannot be decrypted by someone who later learns
   the token. That is forward secrecy rather than rotation, and it is the
   property the 24-hour figure was reaching for.

### Tooling Fixes

1. **Google Test added**: `gtest` added to tooling list. C++ unit tests for LUID negotiation, keyed-mutex ring, named pipe logic.

   *None of it exists.* LUID negotiation, the keyed-mutex ring and the named-pipe
   helper belonged to the Sunshine-fork design that was never built, so there was
   never anything to test. GoogleTest was added to `tests/CMakeLists.txt` and
   then fetched for a suite of zero tests until that scaffolding was removed; the
   file now says so. The tests that exist are the Swift ones under
   `macos/SolStreamClient/Tests`, run with `swift test`.

2. **Interactive VM session**: Hyper-V VM configured with **auto-logon** + **Enhanced Session Mode** for WinRT/SendInput testing. PowerShell Direct for headless tasks, interactive session for GUI tests.

   Still the shape of it, and still for the same reason: WGC and SendInput need a
   real interactive session, and session 0 has neither a desktop nor windows.

3. **macOS GitHub runner**: Added to architecture doc as prerequisite. `macos-14` runner for Swift/Metal/CGEventTap tests.

   *Never done.* There is no CI of any kind — no workflow directory, no runner,
   no YAML — and both packaging scripts are run by hand. `installer/README.md`
   records that, along with the Windows build being unsigned, as a known gap
   rather than as a plan.

4. **MSVC + Inno Setup**: Added to Hyper-V VM provisioning steps. Installed via `winget` during first VM setup.

   MSVC yes; Inno Setup no. There is no `.iss` script and no installer project:
   the agent installs itself, and what ships is one executable that copies itself
   into Program Files. `installer/README.md` describes what a run does.

## Final verdicts from all three agents

| Pillar | Review A | Review B | Review C |
|---|---|---|---|
| **Architecture** | ✅ CONVERGE | ✅ CONVERGE | ✅ CONVERGE* |
| **Plans** | ✅ CONVERGE | ✅ CONVERGE | ✅ CONVERGE* |
| **Tooling** | ✅ CONVERGE | ⚠️ Pending MSVC/macOS install | ⚠️ Pending interactive VM config |

*\*After applying fixes above*

## What's needed to close the last two gaps

| Gap | What's needed | Who |
|---|---|---|
| MSVC + Windows SDK | Install VS Build Tools in Hyper-V VM | You enable Hyper-V, I handle the rest |
| macOS GitHub runner | Add `macos-14` to CI workflow | I write the YAML, you add secrets |
| Interactive VM session | Auto-logon + Enhanced Session Mode | I configure via PowerShell, you approve the VM install once |

Of those three, the toolchain and the VM happened; the CI workflow did not, and
the repository has none to this day. Nothing above is outstanding work — it is
what was outstanding on 18 July 2026.
