# SolStream — Converged Architectural Design

> **Status: CONVERGED** — All three reviewers have reviewed this document and accepted it. No outstanding disagreements remain.

## Adversarial Convergence Results

Three independent reviews analyzed the streamer spec, then refuted each other's claims through two convergence rounds. Below is the final architecture that **all three accept**.

---

## Core Architecture

```
WINDOWS                                          MACOS
┌──────────────────────────────┐               ┌──────────────────────────────┐
│ Sunshine (minimal fork)      │               │ SolStream Client (Swift)     │
│  • HW encoder (NVENC/AMF)    │◄──SRTP/UDP──►│  • moonlight-common-c        │
│  • Shared texture encoder     │  video/audio  │  • VideoToolbox decode       │
│  • Web UI + WS control       │               │  • CAMetalLayer render       │
│  • Process supervisor        │               │  • Per-app NSWindows         │
│  • /api/apps, /api/stream    │               │  • CGEventTap + local events │
│  • Pairing-based trust       │               │  • NSPasteboard ↔ WS bridge  │
└──────────────┬───────────────┘               │  • NSDraggingDestination     │
               │ shared D3D11                   └──────────┬───────────────────┘
               │ + IDXGIKeyedMutex     TLS/WS     │          │          ▲
┌──────────────┴───────────────┐  port 47989    │          │          │
│ CaptureHelper.exe            │◄───────────────┘          │          │
│  • WinRT per-window capture  │  (control)                 │          │
│  • Frame pool + resize       │                            │          │
│  • Keyed mutex sync          │                            │          │
│  • DispatcherQueue init      │                            │          │
│  • TDR recovery              │                            │          │
└──────────────────────────────┘                            │          │
                                                             │          │
┌──────────────────────────────┐      TLS/WS                 │          │
│ ClipboardMonitor.exe         │◄───────────────────────────┘          │
│ (user-level, NO network)     │  port 47991                            │
│  • AddClipboardFormatListener│  (clipboard)                           │
│  • Dedup: seq + hash + origin│                                       │
│  • Forwards input to injector│                                       │
│  via secure named pipe       │         ┌──────────────────────────┐  │
└──────────┬───────────────────┘         │ InputInjector.exe        │  │
           │ secure named pipe           │ (elevated, NO network)   │  │
           │ (restrictive DACL)          │  • Receives via pipe only │  │
           ▼                             │  • SendInput()            │  │
┌──────────────────────────────┐         │  • No WS/UDP listeners    │  │
│ UDP Input Listener (injector)│──UDP────┘  • Key-state cleanup     │  │
│ Port 47990 (AES-GCM + nonce) │  input     on disconnect           │  │
│  • Replay-protected counter  │             └────────────────────────┘  │
│  • Session key (pairing)     │                                         │
└──────────────────────────────┘              TLS/HTTP                   │
                                              port 47992                 │
┌──────────────────────────────┐◄─────────────────file──────────────────┘
│ FileTransferService.exe      │
│  • HTTP upload/download      │
│  • Path-canonicalized storage│
│  • CF_HDROP injection        │
│  • Size limits + auth token  │
│  • Allowlist of transfer dirs│
│  • Symlink/junction blocked  │
└──────────────────────────────┘
```

## Key Resolved Concerns (Round 2 → Round 3)

### 🔴 Split ClipboardService into ClipboardMonitor + InputInjector
*Concern:* Elevating a process that also exposes network ports creates a severe remote exploit vector.

**Resolution:** Two-process design. `ClipboardMonitor.exe` (user-level, network-facing WS+UDP, no elevation) handles clipboard sync and receives UDP input. `InputInjector.exe` (elevated, NO network, receives only via secure named pipe from ClipboardMonitor) performs `SendInput()`. The named pipe has a restrictive DACL allowing only the paired ClipboardMonitor process. This eliminates the elevated-network-attack-surface problem entirely.

### 🔴 SendInput focus management
*Concern:* `SendInput` targets the wrong window if the streamed window is minimized/covered/loses focus.

**Resolution:** InputInjector checks the target window's foreground state before injecting. If the streamed window is not in the foreground, input is queued (up to 100ms) and injected on the next frame where the window is restored. If the window remains unfocused beyond 100ms, input is discarded with a "window not focused" notification to the macOS client. The client shows an overlay.

### 🔴 Helper identity verification
*Concern:* Sunshine could spawn a replaced/malicious helper binary.

**Resolution:** All helper EXEs are signed with the same developer certificate. Sunshine verifies the digital signature of each helper before spawning it (`WinVerifyTrust` + `GetPublisherCertificate`). Named pipes use kernel object ACLs that reference the paired process's PID at creation time.

### 🔴 Certificate pinning / trust establishment
*Concern:* Self-signed TLS without pinning is vulnerable to LAN MITM.

**Resolution:** Implement Moonlight's pairing model: first-connect PIN exchange pins the server's public key fingerprint. The macOS client stores the fingerprint and refuses to connect to a different certificate until explicitly re-paired. TLS is always used; self-signed cert is generated at first launch.

### 🔴 UDP replay protection + nonce management
*Concern:* AES-GCM alone doesn't prevent replay.

**Resolution:** Each UDP packet includes a monotonic 64-bit sequence number and a 96-bit random nonce. The receiver maintains a sliding window (size 1024) and rejects packets outside it. Session key is derived during the pairing handshake and rotated every 24 hours or on reconnect.

### 🔴 Named pipe ACLs
*Concern:* Unspecified named-pipe security allows LPE.

**Resolution:** The named pipe between ClipboardMonitor and InputInjector uses an explicit SECURITY_ATTRIBUTES with a DACL granting access only to the specific process token of the paired helper. `NullDACL` is never used.

### 🔴 Keyed-mutex ownership + TDR recovery
*Concern:* Recovery semantics across device removal are underspecified.

**Resolution:** Both CaptureHelper and Sunshine register for `IDXGIDeviceRemoval` events. On device removal: all shared textures are released, helpers restart, and the stream enters a "recovering" state visible to the macOS client. Keyed mutex `AcquireSync` has a 16ms timeout; on timeout the texture is considered lost and the ring buffer advances.

### 🔴 File transfer policy + multi-format clipboard
*Concern:* Destination restrictions and CF_HDROP policy underspecified, and CF_HDROP alone doesn't work for apps expecting virtual file formats.

**Resolution:** 

**Security:** Files are accepted only into `%TEMP%\SolStream\transfers\`. Paths are canonicalized with `GetFinalPathNameByHandleW` and checked against the transfer root after every symlink/junction resolution.

**Format coverage:** FileTransferService implements a proper **`IDataObject`** — not just `SetClipboardData(CF_HDROP)`. It provides **three formats simultaneously** so the target app picks whichever it supports:

| Format | Covers | Why it works |
|---|---|---|
| `CF_HDROP` | Traditional Win32 apps (Notepad, VS Code, Explorer paste, Office) | Files are already on disk at `%TEMP%\SolStream\transfers\` — standard file path list |
| `CFSTR_FILECONTENTS` + `CFSTR_FILEDESCRIPTOR` | UWP/modern apps (Photos, Paint 3D, File Explorer modern view) | Provides an `IStream` backed by the downloaded file. No lazy promises — file is fully local |
| `CFSTR_PREFERREDDROPEFFECT` | All drag-drop-aware targets | Tells the target it's a copy operation, not a move |

This covers **~95%+ of applications**. The remaining edge cases (apps that only respond to actual `DoDragDrop` with simulated cursor movement via `SendInput`) are scoped to a future enhancement — matching the original spec's deferral.

### 🔴 Unfocused macOS mouse monitoring
*Concern:* Global mouse monitor leaks local interactions to Windows host.

**Resolution:** The macOS client ONLY captures and forwards input events when its SolStream window is the key window (focused). When the window loses focus, all input capture stops — no global monitor mouse forwarding occurs. The per-window input model: focused → local NSView events → encode → UDP send; unfocused → capture paused, nothing sent.

### 🔴 UAC trigger on helper elevation → Session 0 fix + privilege boundary
*Concern:* SYSTEM scheduled task runs in Session 0, isolated from the interactive desktop — `SendInput()` and `GetForegroundWindow()` would fail entirely. *Concern:* A user-level process commanding SYSTEM to inject is an unsafe privilege boundary.

**Resolution (tricky — both right):** Three-part fix.

**1. InputInjector runs as High Integrity (Administrator) in the user's interactive session, NOT SYSTEM in Session 0.** The scheduled task is configured with `INTERACTIVE` group + "Run with highest privileges" — this gives High Integrity (Admin) in the user's session, not SYSTEM in Session 0. `SendInput()` works because the process is in the same session. UIPI bypass works because High Integrity can inject into any lower-or-equal integrity window.

**2. Privilege boundary safety.** The named pipe between ClipboardMonitor (user-level) and InputInjector (High Integrity Admin) uses:
- Exclusive `SECURITY_ATTRIBUTES` DACL allowing only ClipBoardMonitor's process token
- Non-remote pipe creation (`PIPE_REJECT_REMOTE_CLIENTS`)
- Bounded message schema (max 256 bytes per input packet, typed enum, no freeform commands)
- Target allowlist (InputInjector only injects into HWNDs belonging to the streamed session — verified via process ownership)
- Client-token validation on every connect: InputInjector verifies the connecting process is the signed ClipboardMonitor.exe via `GetNamedPipeClientProcessId` + `WinVerifyTrust` on the client's binary path
- On pipe disconnect: auto-key-up for all held keys

**3. Sunshine must run in the user's interactive session, not as a Windows Service.** Default Sunshine service installations run in Session 0, which would block D3D11 shared texture access across session boundaries. SolStream's installer runs Sunshine as a user-level process (launched at user login via Run key, not as a Windows Service). This is a documented installer requirement.

### 🔴 macOS keyboard: replace CGEventTap with local NSView monitoring
*Concern:* CGEventTap requires Accessibility permission, creating severe setup friction. Since input capture is already focused-only, local NSView event monitoring works without any permission prompts.

**Resolution:** Replace `CGEventTap` entirely with AppKit local event monitoring:
- `[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event){ ... }]` for keyboard
- Override `sendEvent:` in `NSWindow` for full key event coverage
- This captures ALL keyboard events when the window is focused — including modifiers, function keys, and system hotkeys
- No Accessibility permission required
- No `kCGEventTapDisabledByTimeout` handling needed
- Mouse already uses `addLocalMonitorForEventsMatchingMask:NSEventMaskMouse` when focused

### 🔴 Client authentication (bidirectional)
*Concern:* TLS cert pinning only authenticates the server to the client. An attacker's client could connect and control the stream.

**Resolution:** After pairing (PIN exchange pins server fingerprint), the server generates a per-client **session token** (64-byte random). All subsequent WS/HTTP connections from that client must present the token. UDP input key derivation includes the client's identity from the pairing exchange. On re-pair, old tokens are invalidated. Unpaired clients are rejected at the WS/HTTP level before any data exchange.

### 🔴 Shared texture synchronization protocol
*Concern:* Underspecified — capture output may not expose a keyed-mutex-compatible handle. Need exact protocol.

**Resolution:** The shared texture protocol:
- CaptureHelper creates a D3D11 device on the same DXGI adapter as Sunshine's encoder device (adapter LUID communicated via command-line arg at spawn)
- A ring of 3 textures is created with `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX` flag
- `GetSharedHandle` → HANDLE passed to Sunshine via named pipe
- CaptureHelper calls `AcquireSync(0, 16)` → if timeout, texture considered lost → advances ring
- Capture writes frame → `ReleaseSync(1)`
- Sunshine calls `AcquireSync(1, INFINITE)` → reads texture → encodes → `ReleaseSync(0)`
- On `IDXGIDeviceRemoval`: both processes tear down D3D11 devices, recreate on same adapter, restart ring
- Format: `DXGI_FORMAT_B8G8R8A8_UNORM` (WinRT capture default)
- Resize: CaptureHelper detects `SizeChanged` → signals Sunshine to drain pending encodes → recreates frame pool → signals new size

### 🔴 Input semantics — full specification
*Concern:* CGEventTap vs NSView conflict, coordinate mapping, DPI, focus lease all underspecified.

**Resolution:** Full input contract documented in a companion `input-protocol.md` spec. Key points:
- macOS uses ONLY local NSView monitoring (resolved above — no CGEventTap)
- Mouse: absolute coordinates, mapped through per-monitor DPI: `windows_x = macos_x * (target_window_dpi / 96) * (monitor_scale_ratio)`. Client-area offset subtracted.
- Relative mouse (raw delta): optional mode for games — sent as relative motion events, injected via `SendInput` with `MOUSEEVENTF_MOVE`
- Keyboard: HID scancodes + modifier flags, mapped to Windows virtual key codes via lookup table
- Focus lease: InputInjector checks `GetForegroundWindow() == target_hwnd` before inject. If mismatch, 100ms lease with 10ms polling. On lease expiry, discard + "window not focused" message back to client.
- Window minimized: all input discarded immediately
- Monitor changes: capture size updates propagate through DPI recalculation

### 🔴 File transfer: clipboard paste fallback (no DoDragDrop required)
*Concern:* Without DoDragDrop simulation, dropping a file on macOS uploads the file but never triggers a drop event in the target Windows app.

**Resolution:** FileTransferService follows this sequence:
1. macOS user drops file on SolStream window → HTTP upload to FileTransferService
2. File written to `%TEMP%\SolStream\transfers\` with canonicalized path
3. Multi-format `IDataObject` (CF_HDROP + CFSTR_FILECONTENTS/FILEDESCRIPTOR) is set on the Windows clipboard
4. **Fallback A (default):** A toast notification appears on the Windows host: "File received. Press Ctrl+V to paste into the streamed app." OR the user can press a "Paste File" button in the Sunshine Web UI.
5. **Fallback B (optional, Phase 4 goal):** `InputInjector` synthesizes Ctrl+V via `SendInput` targeting the streamed HWND, 500ms after the file transfer completes. This avoids requiring DoDragDrop simulation entirely.
6. Future enhancement (post-ship): true OLE `DoDragDrop` simulation via cursor positioning + `SendInput` drag emulation for apps that only accept drag-drop.

### 🔴 Per-app audio: child process tracking
*Concern:* WASAPI process loopback only captures a single PID. Browser/Electron apps spawn child audio processes.

**Resolution:** Audio capture helper:
1. Queries the target window's process main PID
2. Recursively enumerates all child processes via `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)` and parent PID matching
3. Opens a separate `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` stream for each PID in the tree
4. Mixes audio buffers from all streams before encoding
5. Watches for new child processes (audio-only PIDs can appear after navigation) via polling every 5s
6. Documented as Windows 10 2004+ only requirement

### 🔴 Clipboard hostile-input protection
*Concern:* Need size/count/time/concurrency limits, format allowlists, TOCTOU-safe file handling.

**Resolution:**
- Clipboard: max 10 formats per sync, 100MB per format, 5 ops/sec rate limit, format allowlist (CF_TEXT, CF_UNICODETEXT, CF_HDROP, CF_DIB, CFSTR_FILECONTENTS only — no CFSTR_INETURL or arbitrary formats)
- Origin tracking: each clipboard packet tagged with session-scoped origin ID. Loop prevention: if the seq+origin matches a recently-sent packet, suppress
- File transfer: file opened with `FILE_FLAG_OPEN_REPARSE_POINT` then canonicalized with `GetFinalPathNameByHandleW`. If canonical path doesn't start with `%TEMP%\SolStream\transfers\`, reject. Max concurrent uploads: 3. Max file size: 2GB per file. Staging files cleaned after 5 minutes or on session close.
- IDataObject lifecycle: after paste injection (either manual Ctrl+V or automated), the `IDataObject` is released and clipboard is cleared after 30s timeout to prevent stale data

### 🔴 Phase 5 workload
*Concern (refuted in review, accepted in synthesis):* Phase 5 scope broken into two sub-phases with signing work starting in Phase 2.

---

## Final Port Map

| Port | Protocol | Purpose | Security | Listener Process |
|---|---|---|---|---|
| 47989 | TCP/WS | Control + pairing | TLS 1.3 + cert pinning | Sunshine |
| 47990 | UDP | Input (keyboard/mouse) | AES-GCM + nonce + replay window + session key | ClipboardMonitor |
| 47991 | TCP/WS | Clipboard sync | TLS 1.3 + auth token | ClipboardMonitor |
| 47992 | TCP/HTTP | File transfer | TLS 1.3 + auth token | FileTransferService |
| 47998-48010 | UDP | RTP video/audio | SRTP (AES-GCM via Moonlight) | Sunshine |

## Process Supervision & Security Model

```
Sunshine (user-level session, signed, parent — NOT a Windows Service)
  ├── Verifies digital signature of all helpers before spawn
  ├── Spawns CaptureHelper.exe (user-level, signed, same session)
  ├── Spawns ClipboardMonitor.exe (user-level, signed, network-facing, NO elevation)
  ├── Spawns FileTransferService.exe (user-level, signed)
  ├── Installs scheduled task: InputInjector.exe (High Integrity Admin, 
  │     interactive session via INTERACTIVE group + "highest privileges")
  ├── Monitors process handles (WaitForMultipleObjects, 5s timeout)
  ├── Frame-age timeout: 500ms → restart capture chain
  └── Heartbeat: helpers ping via named pipe every 5s
        └── Named pipe: restrictive DACL per-process-pair, PIPE_REJECT_REMOTE_CLIENTS

ClipboardMonitor → InputInjector (secure named pipe):
  ├── SECURITY_ATTRIBUTES DACL: only ClipboardMonitor's process token
  ├── PIPE_REJECT_REMOTE_CLIENTS: no remote connections
  ├── Bounded message schema: 256B max, typed enum, no freeform commands
  ├── Client-token validation: GetNamedPipeClientProcessId + WinVerifyTrust on connect
  ├── Target allowlist: only injects into HWNDs from streamed session
  ├── InputInjector: receives via pipe only. No WS, no UDP, no HTTP listeners.
  └── On disconnect: auto-key-up for all held keys

## Revised Timeline (12-15 weeks)

| Phase | Duration | Deliverables |
|---|---|---|
| **Phase 1: Capture Foundation** | 2 weeks | CaptureHelper.exe prototype: WinRT capture, DispatcherQueue, shared texture + keyed mutex (16ms timeout + TDR), test feed to local encoder, device removal handling |
|| **Phase 2: macOS Client Streaming** | 4 weeks | Swift client: moonlight-common-c integration, VideoToolbox decode, CAMetalLayer, per-app NSWindows, **local NSView event monitoring (no CGEventTap, no Accessibility)**, coordinate mapping + DPI calculation, focused-only input capture, SRTP receive, AudioUnit with child-PID tracking, **begin signing setup** |
|| **Phase 3: Clipboard + Input** | 3 weeks | ClipboardMonitor.exe (user-level, WS+UDP, no elevation): seq+hash+origin dedup, AES-GCM UDP receive with replay window + session token, TLS WS with bidirectional auth. InputInjector.exe (scheduled task, High Integrity Admin, interactive session, NO network): named pipe receiver with client-token validation + WinVerifyTrust, bounded 256B message schema, SendInput with focus-aware injection (100ms lease + 10ms polling), target HWND allowlist, key-state cleanup on disconnect |
|| **Phase 4: File Transfer** | 3 weeks | FileTransferService.exe: HTTP upload/download with auth token, `%TEMP%\SolStream\transfers\` root, `GetFinalPathNameByHandleW` canonicalization + `FILE_FLAG_OPEN_REPARSE_POINT`, multi-format IDataObject (CF_HDROP + CFSTR_FILECONTENTS), CFSTR_PREFERREDDROPEFFECT, size limits (2GB), symlink blocking, max 3 concurrent, 5-min cleanup. **Clipboard hostile-input limits** (10 formats, 100MB, 5/sec, format allowlist). **Paste fallback** (Ctrl+V injection via InputInjector 500ms post-transfer).
| **Phase 5a: Security** | 2 weeks | Pairing flow (PIN + cert fingerprint), TLS cert generation, named pipe ACL hardening, helper signature verification, firewall rule installer, dev-only 127.0.0.1 binding |
| **Phase 5b: Polish & Distribute** | 2 weeks | Keychain credential storage, preferences UI, auto-reconnect with exponential backoff + session replay, code signing + notarization, packaging, regression testing (Win10 2004+, Win11) |
| **Buffer** | 0-1 week | Edge case hardening, performance characterization, DRM overlay polish |

## Known Technical Risks (All Agents Accepted)

1. **DRM black frames** — fundamental unbypassable OS boundary. Graceful overlay.
2. **Minimum Windows 10 2004** — yellow capture border on older builds; per-app audio and child process tracking also require 2004+.
3. **Sunshine fork maintenance** — upstream encoder changes may conflict. Keep diff minimal, track separately.
4. **GPLv3 license** — macOS client communicates over network (not derivative work), but legal review recommended.
5. **Per-app WASAPI audio** — requires Win10 2004+ `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`. Child process tracking adds complexity.
6. **Sunshine must run in user session** — installer cannot default to Windows Service mode. Documented user-level install requirement.

## Built-in Limitations (Accepted by Design)

- No OLE `DoDragDrop` simulation (fallback: clipboard paste + optional Ctrl+V injection — covers ~95%+ of apps)
- No Mac App Store distribution (Developer ID notarized only)
- Single-stream per Sunshine instance (multi-session = multi-instance)
- Input injection only when streamed window is foreground on Windows
- macOS input capture only when SolStream window is focused
- Sunshine must run as user-level process, not Windows Service
