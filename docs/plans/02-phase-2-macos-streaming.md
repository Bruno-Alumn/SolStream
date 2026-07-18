# Phase 2: macOS Client Streaming (4 Weeks)

## Goal
Build the macOS client: connect to Sunshine, receive video/audio stream, render in a per-app NSWindow with CAMetalLayer, and send keyboard/mouse input back. End-to-end streaming working.

## Key Changes from Previous Review
1. **moonlight-common-c compatibility spike first** — verify protocol handshake works with Sunshine fork before building client
2. **CGEventTap as opt-in, not mandatory** — client defaults to local NSView monitoring for standard keyboard. CGEventTap is only activated when user enables "Forward System Shortcuts" (e.g., Cmd+Tab). Permission prompt only shown on opt-in.
3. **Audio capture: dual approach on Windows side** — Primary: WASAPI per-process loopback with child PID tracking (Windows only, runs on host). Fallback: virtual audio loopback driver (e.g., VB-Cable) for anti-cheat/complex process trees where PID tracking fails. macOS client receives decoded audio via RTP stream — no WASAPI involved on the client side.
4. **Coordinate synchronization protocol** added — Windows host reports target window position/size via WS control channel, macOS client uses this for absolute coordinate mapping
5. **Multi-window limits documented** — single stream per Sunshine instance, GPU encoder session limit (~5) known
6. **UDP packet format fully specified** — nonce construction, key binding, MTU handling, seq rollover
7. **Accessibility permission flow documented** — only shown when CGEventTap opt-in is enabled

## Task Breakdown

### Week 1, Day 1-3: moonlight-common-c Integration
- [ ] Create Xcode project: `macos/SolStreamClient/`
- [ ] Integrate `moonlight-common-c` as a Swift Package Manager dependency (or submodule)
- [ ] Implement LiStartConnection with Sunshine's pairing/handshake protocol
- [ ] Handle RTSP connection to Sunshine port 47989
- [ ] Receive SDP with video/audio stream parameters
- [ ] **Verify:** Client completes handshake with Sunshine, prints stream parameters

### Week 1, Day 3-5: Video Decode Pipeline
- [ ] Integrate VideoToolbox decoder (VTDecompressionSession)
- [ ] Receive RTP/H.264 or H.265 video frames from moonlight-common-c
- [ ] Feed compressed frames to VideoToolbox → receive CVPixelBuffers
- [ ] Handle SRTP decryption (AES-GCM keys from handshake)
- [ ] Implement frame queue with PTS ordering and drop-on-late
- [ ] **Verify:** CVPixelBuffers are produced at 60fps with correct resolution

### Week 2, Day 1-3: CAMetalLayer Rendering
- [ ] Create NSWindow with CAMetalLayer-backed content view
- [ ] Implement Metal texture upload: CVPixelBuffer → CVMetalTextureCache → MTLTexture
- [ ] Render MTLTexture to CAMetalLayer via `[drawable present]`
- [ ] Handle vsync (16.6ms present) vs tearing mode (immediate present)
- [ ] Handle window resize → update Metal layer drawable size
- [ ] **Verify:** Video renders smoothly at 60fps in the NSWindow

### Week 2, Day 3-5: Per-App NSWindows
- [ ] Create NSWindowController that creates one NSWindow per app stream
- [ ] Window title = streamed app name
- [ ] Handle window close → send stream stop to Sunshine
- [ ] App discovery UI: on launch, query `/api/apps` → display list
- [ ] Click app → open stream window → start streaming
- [ ] **Verify:** Can launch Notepad on Windows, see it in app list, click it, and see Notepad's content in a dedicated NSWindow

### Week 3, Day 1-3: Local NSView Input Capture (No Accessibility)
- [ ] Implement keyboard capture via `[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown]`
- [ ] Implement mouse capture via `[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouse]`
- [ ] Override `sendEvent:` in NSWindow for any events local monitors miss
- [ ] Map HID scancodes → Windows virtual key codes (lookup table)
- [ ] Map macOS coordinates → Windows DPI-aware coordinates: `win_x = mac_x * (target_dpi / 96) * monitor_scale`
- [ ] Subtract client area offset from mouse coordinates
- [ ] **Verify:** Key presses and mouse clicks in the stream window are captured and mapped correctly

### Week 3, Day 3-5: Input Send Over UDP
- [ ] Implement UDP socket on port 47990
- [ ] Packet format: 64-bit sequence + 96-bit nonce + AES-GCM encrypted payload
- [ ] Payload: `{type: keydown|keyup|mousemove|mouseclick|mousewheel, ...params}`
- [ ] Implement focused-only input: capture ONLY when NSWindow is key window
- [ ] On focus loss: stop capturing, send nothing
- [ ] **Verify:** Wireshark shows encrypted UDP packets when typing in focused window

### Week 4, Day 1-3: Audio Pipeline
- [ ] Receive audio RTP stream from moonlight-common-c
- [ ] Decode via AudioToolbox (AAC or Opus)
- [ ] Play via AVAudioEngine
- [ ] Handle audio start/stop with stream lifecycle
- [ ] **Verify:** Audio plays from the streamed Windows app

### Week 4, Day 3-5: Polish + Signing Setup
- [ ] Handle stream disconnect / reconnect
- [ ] Error UI: "Connection lost", "Permission denied" overlays
- [ ] Start code signing setup: Apple Developer account, certificates
- [ ] Notarization preparation: configure Hardened Runtime entitlements
- [ ] **Verify:** Client shows appropriate error states and survives reconnection

## Acceptance Criteria (Phase 2 Gate)
1. Discover Windows apps from macOS via `/api/apps`
2. Click app → dedicated NSWindow appears with video stream
3. Video renders at 60fps at ~22-28ms display latency
4. Keyboard and mouse input in the stream window reaches the Windows app
5. Audio from Windows app plays on macOS
6. Window close → stream stops cleanly
7. Focused-only input: no capture when window is not focused
8. Works without any Accessibility permissions

## Files Created
```
macos/SolStreamClient/
├── SolStreamClient.xcodeproj/
├── Package.swift
├── Sources/
│   ├── AppDelegate.swift
│   ├── AppDiscovery/
│   │   ├── AppListViewController.swift   # List of available Windows apps
│   │   └── AppListViewModel.swift
│   ├── Streaming/
│   │   ├── StreamManager.swift            # LiStartConnection, lifecycle
│   │   ├── VideoDecoder.swift             # VideoToolbox + moonlight-common-c
│   │   ├── MetalRenderer.swift            # CAMetalLayer renderer
│   │   ├── AudioPlayer.swift              # AVAudioEngine + AudioToolbox
│   │   └── StreamWindowController.swift   # Per-app NSWindow management
│   └── Input/
│       ├── InputCapture.swift             # Local NSView event monitors
│       ├── KeyCodeMap.swift               # HID → Windows VK lookup table
│       └── CoordinateMapper.swift          # macOS points → Windows DPI coords
```
