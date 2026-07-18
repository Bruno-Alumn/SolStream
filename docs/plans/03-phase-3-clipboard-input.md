# Phase 3: Clipboard + Input (3 Weeks)

## Goal
Bidirectional clipboard sync with dedup, and reliable keyboard/mouse injection into Windows apps. This phase delivers ClipboardMonitor.exe and InputInjector.exe.

## Key Changes from Previous Review
1. **SendInput focus-stealing mitigation**: InputInjector maintains a session-scoped **allowed HWND list** — only injects into HWNDs verified as belonging to the streamed session. If focus changes to an unknown window (system popup, UAC, etc.), input is DISCARDED (not queued). Only modifier key-up events are injected to prevent stuck keys. No burst on focus restore — user must click back into the streamed app to resume input.
2. **Session change monitoring**: InputInjector registers `WTSRegisterSessionNotification` to detect logoff, Fast User Switching, or lock screen. On session change → pause injection, release all keys, wait for correct session. On lock screen → injection stops entirely (all windows become secure desktop).
3. **Modifier key cleanup**: On macOS client window focus loss → send synthetic key-up for all tracked modifiers. On network disconnect → same. Concrete trigger mechanism specified.
4. **PID recycling prevention**: `GetNamedPipeClientProcessId` → immediately `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_DUP_HANDLE)` → check process creation time → **hold handle open for entire session lifetime** to prevent PID recycling. If process exits, handle becomes invalid → disconnect. Reconnection triggers fresh validation.
5. **Clipboard ownership model**: define canonical serialization (UTF-8 for text, PNG for images), max total payload 100MB, sequence counter handles ownership changes, format conversion documented (e.g., RTF → plain text loss).
6. **UIPI documented limits**: `SendInput` at High Integrity can inject into Medium + High Integrity windows, but NOT into SYSTEM-level windows, secure desktop, or lock screen. Documented as supported/unsupported integrity level matrix.

## Task Breakdown

### Week 1, Day 1-2: ClipboardMonitor — Clipboard Listener
- [ ] Create Win32 hidden window with message pump
- [ ] Register `AddClipboardFormatListener` for `WM_CLIPBOARDUPDATE`
- [ ] On notification: enumerate available formats (CF_TEXT, CF_UNICODETEXT, CF_HDROP, CF_DIB)
- [ ] Read clipboard data via `GetClipboardData` for each format
- [ ] Extract text content from CF_UNICODETEXT
- [ ] Compute SHA-256 hash of data
- [ ] Implement debounce: coalesce rapid changes within 100ms
- [ ] **Verify:** Changing clipboard in a Windows app fires WM_CLIPBOARDUPDATE and data is read

### Week 1, Day 3: ClipboardMonitor — WS Server
- [ ] Start WebSocket server on port 47991 (TLS 1.3)
- [ ] Accept macOS client connections (authenticated via session token)
- [ ] On clipboard change: serialize `{seq, origin, format, hash, data}` → send over WS
- [ ] On WS receive: deserialize clipboard data → `OpenClipboard`/`SetClipboardData`/`CloseClipboard`
- [ ] Implement dedup: if incoming `seq <= last_seen[origin]`, suppress
- [ ] Implement hash tiebreaker: if seq is new but hash matches last sent, suppress (loop prevention)
- [ ] Implement format allowlist: only CF_TEXT, CF_UNICODETEXT, CF_HDROP, CF_DIB, CFSTR_FILECONTENTS
- [ ] **Verify:** Copy on Windows → paste on macOS works. Copy on macOS → paste on Windows works. No loops.

### Week 1, Day 4-5: macOS Clipboard Bridge
- [ ] In SolStreamClient: implement NSPasteboard monitoring via polling (500ms)
- [ ] On pasteboard change: read generalPasteboard items
- [ ] Connect to ClipboardMonitor WS
- [ ] Serialize clipboard data → send over WS
- [ ] Receive clipboard data from WS → set NSPasteboard
- [ ] Implement same dedup logic (seq + hash + origin)
- [ ] **Verify:** Bidirectional clipboard sync works, copy-paste across machines no loops

### Week 2, Day 1-2: InputInjector — Named Pipe Receiver
- [ ] Schedule task at Install: `schtasks /create /tn SolStreamInputInjector /tr InputInjector.exe /ru INTERACTIVE /rp /rl HIGHEST`
- [ ] InputInjector: create named pipe server with `PIPE_REJECT_REMOTE_CLIENTS`
- [ ] Set DACL: grant access only to ClipboardMonitor's expected process SID
- [ ] Bounded message schema: max 256 bytes, typed enum:
  ```
  enum InputType: UInt8 {
    keyDown = 1, keyUp = 2,
    mouseMove = 3, mouseDown = 4, mouseUp = 5, mouseWheel = 6
  }
  struct InputPacket {
    type: InputType,
    params: [UInt8; 252]  // union: {vk,flags} | {x,y,flags} | {delta,flags}
  }
  ```
- [ ] On connect: call `GetNamedPipeClientProcessId`, verify process is signed ClipboardMonitor.exe via `WinVerifyTrust`
- [ ] **Verify:** Pipe connection works, client-token validation passes for real ClipboardMonitor, rejects impostor

### Week 2, Day 3-5: SendInput Implementation
- [ ] Implement keyboard: `INPUT{type: INPUT_KEYBOARD, ki: {wVk, dwFlags}}`
- [ ] Implement mouse move: `INPUT{type: INPUT_MOUSE, mi: {dx, dy, dwFlags: MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE}}`
- [ ] Implement mouse click: `MOUSEEVENTF_LEFTDOWN/LEFTUP`
- [ ] Implement mouse wheel: `MOUSEEVENTF_WHEEL`
- [ ] Implement focus-aware injection:
  - Check `GetForegroundWindow() == target_hwnd` before inject
  - If mismatch: enter 100ms lease with 10ms polling
  - On lease expiry without focus: discard input, send "window not focused" message back over WS to macOS client
- [ ] Implement target HWND allowlist: only inject into HWNDs from streamed session
- [ ] **Verify:** Keyboard/mouse input reaches the streamed Windows app with <5ms overhead

### Week 3, Day 1: ClipboardMonitor — UDP Input Receive
- [ ] UDP socket on port 47990: receive encrypted input packets from macOS
- [ ] Decrypt with AES-GCM session key (from pairing)
- [ ] Verify 64-bit sequence number against sliding replay window (size 1024)
- [ ] Validate 96-bit nonce freshness
- [ ] Forward decrypted input packet to InputInjector via named pipe
- [ ] **Verify:** UDP input packets received from macOS → forwarded to InputInjector → SendInput fires

### Week 3, Day 2-3: Rate Limits + Hostile Input Protection
- [ ] Clipboard: max 10 formats per sync, 100MB per format, 5 ops/sec rate limit
- [ ] Input: max 100 packets/sec, reject malformed packets, bounds-check coordinates
- [ ] Key-state reconciliation: track pressed keys per-session. On disconnect: send release for all
- [ ] **Verify:** Sending 500 packets/sec → 400 are dropped, keys are released on disconnect

### Week 3, Day 4-5: Integration + Edge Case Testing
- [ ] Full end-to-end test: copy text on macOS → verify paste on Windows → copy other text → verify no loop
- [ ] Test UIPI: stream an elevated app (Notepad as Admin) → verify input still works (High Integrity InputInjector)
- [ ] Test window focus: click macOS desktop → verify input stops → click back → verify input resumes
- [ ] Test rapid clipboard changes (copy every 50ms) → verify debounce + dedup handles it
- [ ] **Verify:** All edge cases pass

## Acceptance Criteria (Phase 3 Gate)
1. Copy text on Windows → paste works on macOS
2. Copy text on macOS → paste works on Windows
3. No clipboard loops (infinite copy-paste cycles)
4. Keyboard input reaches streamed Windows apps
5. Mouse clicks and movement reach streamed Windows apps
6. Input stops when streamed window loses focus (100ms timeout + overlay)
7. Elevated (Admin) app input works via High Integrity InputInjector
8. Rapid clipboard changes are debounced and deduplicated
9. UDP replay window rejects old/duplicate packets
10. Disconnect → all held keys are released

## Files Created
```
windows/ClipboardMonitor/
├── CMakeLists.txt
├── main.cpp                    # Win32 hidden window, message pump
├── clipboard_listener.cpp      # AddClipboardFormatListener, WM_CLIPBOARDUPDATE
├── clipboard_listener.h
├── ws_server.cpp               # WebSocket server with TLS, session token auth
├── ws_server.h
├── dedup.cpp                   # seq + hash + origin dedup logic
├── dedup.h
├── udp_input.cpp               # UDP receive, AES-GCM decrypt, replay window
└── udp_input.h

windows/InputInjector/
├── CMakeLists.txt
├── main.cpp                    # Named pipe receiver, scheduled task setup
├── pipe_client_validator.cpp   # GetNamedPipeClientProcessId + WinVerifyTrust
├── pipe_client_validator.h
├── input_injector.cpp          # SendInput with focus-aware injection
├── input_injector.h
├── key_state_tracker.cpp       # Key press/release tracking, cleanup on disconnect
└── key_state_tracker.h
```
