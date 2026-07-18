# Phase 5b: Polish & Distribute (2 Weeks)

## Goal
Production-ready polish: auto-reconnect, preferences, code signing, notarization, packaging, regression testing.

## Key Changes from Previous Review
1. **Helper crash notification to UI**: When a helper crashes and restart fails (max 3), Sunshine sends a WS notification to the macOS client with specific error: "Capture failed", "Input disconnected", "File transfer unavailable". Client shows persistent error badge.
2. **Host audio muting**: Installer creates a virtual audio endpoint (or configures WASAPI to capture from loopback while muting the physical speakers). On stream start, host speakers are muted via `IAudioEndpointVolume->SetMute(TRUE)`. On stream end, unmuted. Documented behavior.
3. **Installer upgrade path**: Inno Setup script checks for running processes BEFORE attempting to overwrite binaries. Stops Sunshine + helpers, removes scheduled task, copies new files, restarts. **Configuration is preserved** — `ProgramData` and `AppData` config dirs are not touched during upgrade. On rollback failure (new binaries fail to start), original binaries are restored from backup, config remains untouched.
4. **Expanded regression matrix** — adds Intel GPUs, HDR color formats, sleep/wake, RDP sessions, antivirus products, low disk space, macOS permission-denied states, offline pairing attempt.
5. **Performance acceptance thresholds**: <35ms RTT 95th percentile measured on reference hardware (Intel i7 + NVIDIA RTX 3060, Gigabit Ethernet, macOS M1. Network baseline: <1ms LAN latency, zero packet loss on wired). Thresholds are per-reference-config and noted as "may vary on different hardware." No pass/fail on non-reference hardware — reported as measured values.

## Task Breakdown

### Week 1, Day 1: Keychain Credential Storage
- [ ] macOS client: store pairing credentials in Keychain (server fingerprint, session token)
- [ ] Implement `SecKeychainAddGenericPassword` / `SecKeychainFindGenericPassword`
- [ ] On launch: check Keychain for stored credentials → auto-connect
- [ ] On re-pair: update stored credentials
- [ ] Windows: Sunshine stores paired client fingerprints in config file
- [ ] **Verify:** Close and reopen macOS client → auto-connects without re-pairing

### Week 1, Day 2-3: Preferences UI
- [ ] macOS: add Preferences window
  - [ ] Display settings: windowed/fullscreen, tearing mode toggle
  - [ ] Audio: device selector, volume
  - [ ] Connection: server address, re-pair button
  - [ ] About: version, build info, license
- [ ] Windows: Sunshine Web UI already exists — enhance with SolStream-specific settings
  - [ ] App list customization
  - [ ] Default encoder settings (NVENC/AMF)
  - [ ] Session log viewer
- [ ] **Verify:** Preferences persist across restarts

### Week 1, Day 4-5: Auto-Reconnect
- [ ] macOS client: detect connection loss via WS close + heartbeat timeout (10s)
- [ ] On loss: show "Reconnecting..." overlay
- [ ] Exponential backoff: 1s → 2s → 4s → 8s → max 30s
- [ ] On reconnect: re-authenticate with session token
- [ ] Sunshine: detect crash of any helper → attempt restart (max 3 attempts)
- [ ] After 3 failures: stop streaming, show error in macOS client
- [ ] State replay: clipboard state, input state restored on reconnect
- [ ] **Verify:** Kill Sunshine → macOS shows "Reconnecting..." → restart Sunshine → auto-reconnects within 30s

### Week 2, Day 1-2: Code Signing + Notarization
- [ ] macOS: sign SolStreamClient.app with Developer ID Application certificate
  - `codesign --deep --force --verify --verbose --sign "Developer ID Application: Your Name" SolStreamClient.app`
- [ ] Configure Hardened Runtime entitlements (com.apple.security.cs.disable-executable-page-protection not needed — no CGEventTap)
- [ ] Notarize: `xcrun notarytool submit SolStreamClient.dmg --apple-id ... --team-id ...`
- [ ] Staple ticket: `xcrun stapler staple SolStreamClient.dmg`
- [ ] Windows: sign helper EXEs with Authenticode certificate
  - `signtool sign /fd SHA256 /a /tr http://timestamp.digicert.com /td SHA256 *.exe`
- [ ] **Verify:** macOS Gatekeeper allows download and launch. Windows SmartScreen passes.

### Week 2, Day 3: Packaging
- [ ] macOS: create .dmg with Applications folder shortcut
- [ ] Windows: create installer using Inno Setup or WiX:
  - [ ] Install Sunshine fork (user-level, not service)
  - [ ] Install all helpers
  - [ ] Create scheduled task for InputInjector
  - [ ] Add firewall rules
  - [ ] Create Run key for auto-start
- [ ] **Verify:** Clean install on fresh Windows 10 → everything works. Clean install on macOS → works.

### Week 2, Day 4-5: Regression Testing
- [ ] Test matrix:
  - Windows 10 2004, Windows 10 22H2, Windows 11 23H2
  - macOS Ventura (13), Sonoma (14), Sequoia (15)
  - NVIDIA GPU (NVENC), AMD GPU (AMF)
- [ ] Test scenarios:
  - [ ] Stream Notepad, VS Code, Chrome, Explorer
  - [ ] Bidirectional clipboard with text, images, files
  - [ ] File transfer: .txt, .png, .zip, .pdf
  - [ ] Input: typing, mouse clicks, drag-select, scroll wheel
  - [ ] Window resize, minimize, restore
  - [ ] Pairing, re-pairing, multiple clients
  - [ ] Network disconnect/reconnect
  - [ ] Fast User Switching, lock screen
  - [ ] GPU driver crash recovery
- [ ] **Verify:** All scenarios pass on all target platforms

## Acceptance Criteria (Phase 5b Gate)
1. macOS auto-reconnects on network interruption (exponential backoff)
2. Helper crashes are detected and restarted (max 3 attempts)
3. Preferences persist across sessions
4. macOS app is signed, notarized, Gatekeeper-approved
5. Windows binaries are Authenticode-signed
6. Installer works on clean Windows 10/11
7. .dmg installer works on macOS Ventura/Sonoma/Sequoia
8. All regression tests pass on target platforms
9. Beta-ready for external testers
