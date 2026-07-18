# SolStream — Final Convergence Record

## Third-agent fixes applied (July 18, 2026)

### Architecture Fixes

1. **Secret storage**: Changed from ProgramData to **%APPDATA%\SolStream\secrets\** encrypted with **DPAPI** (`CryptProtectData`). Per-user isolation. ProgramData \config\ retains non-secret settings only. 
2. **Clipboard transport clarified**: ClipboardMonitor uses **WS (WebSocket over TCP)** for clipboard sync — confirmed reliable. UDP (port 47990) is **input-only** (keyboard/mouse packets, small payloads). Documentation clarified: no UDP for clipboard.

### Plans Fixes

1. **Security track extended**: Security validation now runs alongside **ALL phases** (P1-P6), not just P1-2. Each phase's gate includes a security sign-off from the threat model.
2. **Pairing expiry removed**: Pairing is now **indefinite** (persists until user explicitly re-pairs). Session tokens rotate every 24h. 30-day expiry scrapped — matches Moonlight's model.

### Tooling Fixes

1. **Google Test added**: `gtest` added to tooling list. C++ unit tests for LUID negotiation, keyed-mutex ring, named pipe logic.
2. **Interactive VM session**: Hyper-V VM configured with **auto-logon** + **Enhanced Session Mode** for WinRT/SendInput testing. PowerShell Direct for headless tasks, interactive session for GUI tests.
3. **macOS GitHub runner**: Added to architecture doc as prerequisite. `macos-14` runner for Swift/Metal/CGEventTap tests.
4. **MSVC + Inno Setup**: Added to Hyper-V VM provisioning steps. Installed via `winget` during first VM setup.

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
