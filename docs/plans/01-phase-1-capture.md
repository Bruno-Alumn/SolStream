# Phase 1: Capture Foundation (3 Weeks — revised from 2)

## Goal
Build and verify CaptureHelper.exe: capture a specific window via WinRT, share its D3D11 texture via keyed mutex across processes, and feed it into Sunshine's encoder. Prove the hardest technical risk works.

## Dependencies
- None — first phase
- **Pre-phase spike (Week 0):** Verify D3D11 shared keyed-mutex handles work across same-session processes on target hardware. Reserve 2 days for this before Phase 1 starts.

## Key Changes from Previous Review
1. **NT handles** (`D3D11_RESOURCE_MISC_SHARED_NTHANDLE`) mandated for cross-process — not legacy `GetSharedHandle`
2. **Hybrid GPU mitigation**: LUID negotiation between CaptureHelper and Sunshine to ensure same-adapter binding
3. **Yellow border**: Documented as unavoidable on Win10 2004. Minimum Windows version raised to 10.0.20348 (Win10 2022H2) where `IsBorderRequired=false` API exists. Win10 2004 users get yellow border — documented limitation.
4. **Keyed-mutex ownership protocol** fully specified with producer/consumer state machine
5. **DispatcherQueue threading model** specified: must be initialized on dedicated thread, not main thread
6. **Window state handling** added: minimized occlusion, window destruction, DPI change

## Task Breakdown

### Week 0 (Pre-phase Spike): Protocol Validation
- [ ] Create minimal test: two processes sharing D3D11 texture via `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX` + `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`
- [ ] Verify on target GPU (NVIDIA + Intel hybrid, AMD)
- [ ] Test across process integrity levels (user → user, user → admin)
- [ ] **Go/No-Go decision:** If shared textures fail on any target config, fall back to CPU copy path

### Week 1, Day 1-2: Environment Setup
- [ ] Fork Sunshine repo into `windows/sunshine/`
- [ ] Set up CMake build for CaptureHelper project
- [ ] Verify D3D11 device creation on target GPU (NVENC or AMF)
- [ ] Query adapter LUID — log and expose via command line
- [ ] Write stub CaptureHelper that creates D3D11 device and logs adapter LUID
- [ ] **Verify:** `CaptureHelper.exe --list-adapters` prints correct GPU info

### Week 1, Day 3-5: WinRT Capture
- [ ] Initialize `DispatcherQueueController` on a **dedicated thread** (not main thread) — CaptureFramePool requires DispatcherQueue for FrameArrived callbacks
- [ ] Implement `Direct3D11CaptureFramePool::CreateForWindow(hwnd)` with `DXGI_FORMAT_B8G8R8A8_UNORM`
- [ ] Handle `FrameArrived` callback → extract `Direct3DSurface` → Get `ID3D11Texture2D`
- [ ] Handle `SizeChanged` event → synchronize with in-flight frames → call `Recreate()`
- [ ] Handle minimized window → capture produces black/stale frames → detect via `IsIconic(hwnd)` → pause capture, send "window minimized" state
- [ ] Handle window destruction → clean up capture resources
- [ ] Handle DPI change → `Recreate()` frame pool with new dimensions
- [ ] Handle protected content → `FrameArrived` fires with black surface → detect via pixel check → emit "protected content" event
- [ ] Test with Notepad, Chrome, Explorer, UWP Calculator
- [ ] **Verify:** FrameArrived fires for all test apps, minimized apps return paused state

### Week 1, Day 5 — Week 2, Day 2: Shared Texture with Keyed Mutex
- [ ] Create 3-texture ring buffer with `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX | D3D11_RESOURCE_MISC_SHARED_NTHANDLE`
- [ ] Ownership protocol:
  ```
  INIT: all textures owned by producer (key=0)
  PRODUCER: AcquireSync(0, 16) → if timeout, texture is LOST → advance ring
            CopySubresourceRegion(framepool → ring texture)
            ReleaseSync(1) → texture now owned by consumer
  CONSUMER: AcquireSync(1, INFINITE) → read → encode → ReleaseSync(0)
  SHUTDOWN: signal flag → producer stops acquiring → consumer processes final frame → ReleaseSync(0) → done
  LOST: on AcquireSync timeout → mark texture as invalid → consumer drops frame → producer advances to next texture in ring
  ```
- [ ] Get shared handle via `IDXGIResource1::GetSharedHandle` (NT handle)
- [ ] **Verify:** Ring operates at 60fps, timeout correctly advances on stall, shutdown drains cleanly

### Week 2, Day 2-4: Shared Texture → Named Pipe Transport
- [ ] Create named pipe server in CaptureHelper (local, restrictive DACL, `PIPE_REJECT_REMOTE_CLIENTS`)
- [ ] On first frame: pack `{handle_value, adapter_LUID, width, height, format, mutex_key}` → send over pipe
- [ ] Create test consumer process that opens NT shared handle via `ID3D11Device1::OpenSharedHandle1`
- [ ] Test consumer verifies adapter LUID matches — if mismatch, log error and fall back to CPU copy
- [ ] Test consumer calls `AcquireSync(1, INFINITE)` → reads texture → encodes → `ReleaseSync(0)`
- [ ] **Verify:** Consumer renders frames at ~60fps, adapter mismatch is detected and handled

### Week 2, Day 4 — Week 3, Day 2: Sunshine Encoder Abstraction
- [ ] In Sunshine fork: add `external_texture` encoder input mode
- [ ] When mode=external_texture: Sunshine opens NT shared handle, binds to same adapter via LUID
- [ ] Sunshine spawns CaptureHelper.exe with HWND arg on stream start
- [ ] Sunshine waits for named pipe data containing shared handle info
- [ ] Implementation: `stream::video_create_external(nt_handle, adapter_luid, width, height, key)`
- [ ] Sunshine calls `AcquireSync(1, INFINITE)` → encodes frame → `ReleaseSync(0)`
- [ ] 3 new API endpoints: `/api/apps` (list windows), `/api/stream/start` (accepts hwnd), `/api/apps/launch`
- [ ] **Verify:** Sunshine web UI shows app list, clicking "Stream" on Notepad captures and encodes

### Week 3, Day 2-3: Device Removal Handling
- [ ] CaptureHelper: register `IDXGIDeviceRemoval` event
- [ ] On removal: release all D3D11 resources, destroy frame pool, recreate device
- [ ] Sunshine: register same event. On removal: set stream state to "recovering"
- [ ] Both processes re-negotiate adapter LUID on restart (GPU may be different after reset)
- [ ] Stale handle invalidation: old NT handles are closed, new ring created
- [ ] **Verify:** GPU driver crash → clean recovery within 3 seconds. Multiple recovery cycles work.

### Week 3, Day 4-5: Integration + Edge Case Testing
- [ ] Test with NVENC and AMF encoders
- [ ] Test resize: rapid window size changes (100ms interval)
- [ ] Test minimize/restore cycle
- [ ] Test rapid window creation/destruction (app switching)
- [ ] Test on hybrid GPU laptop (integrated + discrete)
- [ ] Verify edge case: both processes crash → no leaked handles or zombie pipes

## Acceptance Criteria (Phase 1 Gate)
1. CaptureHelper captures Notepad, Chrome, Calculator → shared NT handles valid
2. Sunshine encoder reads from shared texture and produces valid NVENC/AMF frames
3. `/api/apps` returns window list
4. `/api/stream/start` streams the requested window
5. Window resize triggers pool recreation without crash or frame loss
6. Window minimize → capture pauses cleanly → restore → resumes
7. GPU device removal → clean recovery within 3 seconds
8. Hybrid GPU systems → LUID negotiation correctly binds to same adapter
9. Yellow border present on Win10 < 2022H2 (documented limitation)
10. Protected content → black frames detected and signaled

## Files Created
```
windows/CaptureHelper/
├── CMakeLists.txt
├── main.cpp                  # Entry point, arg parsing, pipe transport
├── capture.cpp               # WinRT capture: FrameArrived, SizeChanged, DispatcherQueue
├── capture.h
├── texture_ring.cpp          # 3-texture ring, keyed mutex, shared handle
├── texture_ring.h
├── device_management.cpp     # D3D11 device creation, adapter detection, device removal
├── device_management.h
├── pipe_transport.cpp        # Named pipe server, handle exchange protocol
└── pipe_transport.h

windows/sunshine/ (fork modifications)
├── lib/
│   └── video.cpp             # Added external_texture encoder input mode
├── sunshine/
│   └── api.cpp               # /api/apps, /api/stream/start (hwnd mode), /api/apps/launch
```
