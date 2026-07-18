# SolStream — Overall Product Plan (Revised)

## Vision
Stream individual Windows application windows to macOS clients — not the full desktop. Bidirectional clipboard, file transfer, and low-latency input over LAN.

## Guiding Principles
1. **Security from Phase 1** — named pipe ACLs, helper signing, and IPC hardening are designed in from day one, not bolted on at the end
2. **Companion processes, not monolith** — each piece independently testable and maintainable
3. **Honest latency** — 22-28ms display, 25-33ms round-trip
4. **Spike risky unknowns first** — protocol compatibility (moonlight-common-c), WinRT capture edge cases, and D3D11 cross-process sharing get dedicated spikes before committing to full builds

## Dependencies Between Phases

```
Phase 1 ──────────────────────────────────┐
  (CaptureHelper + encoder)               │
       │                                  ▼
       ▼                           Phase 5a ────► Phase 5b
Phase 2 ───────────────┐          (Security)       (Polish)
  (macOS streaming)    │
       │               ▼
       ▼         Phase 4
Phase 3 ────────►  (File Transfer)
  (Clipboard+Input)
```

## Phase Overview (Revised)

| Phase | Name | Duration | Key Changes from Previous Plan |
|---|---|---|---|
| 1 | Capture Foundation | 3 weeks (+1) | Added: yellow border mitigation, hybrid GPU LUID negotiation, NT handles for cross-session, DispatcherQueue threading spec, keyed-mutex ring with ownership protocol |
| 2 | macOS Client Streaming | 5 weeks (+1) | Added: moonlight-common-c compatibility spike first, CGEventTap needed for reliable keyboard (not just local NSView), coordinate sync protocol, multi-window streaming limits documented |
| 3 | Clipboard + Input | 4 weeks (+1) | Added: session change monitoring (WTSRegisterSessionNotification), modifier key cleanup on focus loss, SendInput focus-stealing mitigation (only inject when target is in known allowed list), PID recycling prevention, clipboard ownership model |
| 4 | File Transfer | 3 weeks | Added: async IStream for large files, TOCTOU-safe file writes via random temp + rename, per-session disk quotas |
| 5a | Security | 2 weeks | **Moved earlier** to run alongside Phase 1-2. Added: test-signing cert for dev builds, ProgramData config storage, PID handle pinning |
| 5b | Polish & Distribute | 3 weeks (+1) | Added: silent crash notification to UI, host audio muting, installer upgrade path, expanded regression matrix |
| Buffer | Edge Cases | 1 week | No change |
| **Total** | | **21 weeks (+3-5)** | |

## Revised Milestones

| Week | Milestone |
|---|---|
| 1 | moonlight-common-c compatibility spike — verify protocol works with Sunshine fork |
| 3 | CaptureHelper captures a window → Sunshine encodes from shared texture |
| 5 | First pixel in macOS NSWindow from remote Windows app |
| 8 | End-to-end streaming: video + audio + input |
| 12 | Clipboard sync working both directions with dedup |
| 15 | File transfer: drag Mac → paste Windows app |
| 18 | All channels secured: pairing, TLS, signed helpers, secure config storage |
| 21 | Notarized macOS app, Windows installer, beta-ready |

## Test Matrix (Expanded)

- **Windows:** 10 2004, 10 22H2, 11 23H2; NVIDIA + AMD + Intel GPUs; mixed-DPI multi-monitor; HDR on/off; sleep/resume; display hot-plug; RDP session; Fast User Switching; firewall on/off; antivirus products
- **macOS:** Ventura (13), Sonoma (14), Sequoia (15); built-in + external display; Accessibility permission denied/granted; sleep/wake; network change
- **Edge cases:** Protected content (DRM black frame); UWP windows; minimized windows; elevated (Admin) target windows; 32-bit vs 64-bit target apps; network disconnects; GPU driver crash; low disk space; offline mode
- **Performance gates:** Latency <35ms RTT 95th percentile; dropped frames <0.5%; CPU usage <10% on host; memory <500MB per helper process
