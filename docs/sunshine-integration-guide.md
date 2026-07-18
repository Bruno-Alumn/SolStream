# SolStream — Sunshine Fork Integration Guide

## Overview

Sunshine must be modified to consume frames from the SolStream capture pipeline
instead of (or alongside) its native DXGI duplicator capture. The integration
consists of three changes:

1. **`solstream_encoder_input.h/.cpp`** — Consumer-side ring buffer reader.
2. **`sunshine/api/` (new routes)** — HTTP endpoints for stream management.
3. **`sunshine/video.cpp`** — Encoder input source selection.

---

## 1. Encoder Input (already created)

Files added to `windows/sunshine/`:

- `solstream_encoder_input.h`
- `solstream_encoder_input.cpp`

These provide the `solstream::EncoderInput` class that opens shared D3D11
textures on Sunshine's device and acquires/releases frames via `IDXGIKeyedMutex`.

---

## 2. API Endpoints

Add the following routes to Sunshine's HTTP API:

```
GET  /api/solstream/apps        → List available windows
POST /api/solstream/stream/start → Begin streaming a window
POST /api/solstream/stream/stop  → Stop the active stream
GET  /api/solstream/status       → Poll stream health (frames, device state)
```

The endpoints are implemented in `windows/sunshine/api/solstream_api.h/.cpp`
and wired through `SunshinePipeServer::SendStreamStart()` /
`SendStreamStop()` to send commands over the named pipe.

### `/api/solstream/apps`

Returns a JSON array of capturable windows (enumeration via
`IGraphicsCaptureItemInterop` or `EnumWindows`):

```json
{
  "apps": [
    {"name": "Notepad", "hwnd": 0x1234, "pid": 5678},
    {"name": "Chrome",  "hwnd": 0x5678, "pid": 9012}
  ]
}
```

### Example: `/api/solstream/stream/start`

Starts the SolStream pipe client (if not connected) and sends `StartStream`
to CaptureHelper with the target window HWND.

### Example: `/api/solstream/stream/stop`

Sends `StopStream` to CaptureHelper.

---

## 3. Encoder Input Integration (`video.cpp`)

Sunshine's `video.cpp` has an encoder input abstraction. The SolStream
integration point is:

```cpp
// In Sunshine's encoder loop:

#include "solstream_encoder_input.h"

static solstream::EncoderInput g_encoderInput;

// During encoder setup:
g_encoderInput.SetDevice(device);

// During stream start (after receiving shared handles via pipe):
for (auto handle : receivedHandles)
    g_encoderInput.ImportHandle(handle);

// Each encoder frame:
auto [texture, slotIndex, result] = g_encoderInput.AcquireFrame();
if (result == solstream::EncoderInput::AcquireResult::Success) {
    // Encode 'texture' as usual.
    encoder->Encode(texture, ...);
    g_encoderInput.ReleaseFrame(slotIndex);
} else if (result == solstream::EncoderInput::AcquireResult::NoFrame) {
    // No frame — either sleep briefly or return to the event loop.
    std::this_thread::sleep_for(1ms);
}
```

---

## 4. Pipe Client to CaptureHelper

Sunshine also needs a `PipeClient` (reusing `pipe_transport.h`) to send
commands and receive shared handles:

```cpp
#include "../CaptureHelper/pipe_transport.h"

SolStream::IPC::PipeClient g_pipe;

// Connect on startup:
g_pipe.Connect(SolStream::IPC::kPipeName);

// Start stream:
g_pipe.Send(SolStream::IPC::MessageType::StartStream);

// Frame-ready handler (pipe callback receives FrameReady messages):
// The CaptureHelper sends FrameReady after each ring submission.
```

---

## 5. CMake Integration

Add to `windows/sunshine/CMakeLists.txt`:

```cmake
target_sources(sunshine_fork PRIVATE
    solstream_encoder_input.cpp
    solstream_encoder_input.h
)
target_link_libraries(sunshine_fork PRIVATE
    d3d11
    dxgi
)
target_include_directories(sunshine_fork PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../CaptureHelper
)
```

---

## Current Status

| Feature | Phase 1 | Phase 2 | Phase 3 |
|---------|---------|---------|---------|
| CaptureHelper.exe (WinRT capture, ring) | ✅ | ✅ | — |
| Shared-handle IPC (pipe + DuplicateHandle) | ❌ | ✅ | — |
| Sunshine pipe server (handle import) | ❌ | ✅ | — |
| Dynamic ring resize on size change | ❌ | ✅ | — |
| Sunshine API endpoints (apps, start, stop) | ❌ | ✅ | — |
| macOS Swift client (SPM project) | ❌ | ✅ | — |
| CAMetalLayer video rendering | ❌ | ✅ | — |
| NSView input capture (no CGEventTap) | ❌ | ✅ | — |
| AudioUnit playback | ❌ | ✅ | — |
| RTSP handshake (full OPTIONS→DESCRIBE→SETUP→PLAY) | ❌ | ✅ | — |
| Full SRTP decryption + RTP depacketization | ❌ | ❌ | ⏳ |
| macOS pairing UI + certificate management | ❌ | ❌ | ⏳ |
| macOS build + test on real Mac | ❌ | ❌ | ⏳ |
| Code signing infrastructure | ❌ | ✅ (doc+script) | ⏳ |

## Known Limitations (Phase 2)

- No dynamic resize: the ring texture is fixed at 1920×1080.
- No shared-handle transfer protocol: handles must be sent via the pipe
  in a future phase.
- Device loss on the Sunshine side requires pipe reconnection and handle
  re-import.
- No HDR or 10-bit format negotiation.
