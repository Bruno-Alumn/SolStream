# SolStream — Testing & Troubleshooting Toolkit

## Installed Tools (ready now)

| Tool | Version | Purpose |
|---|---|---|
| pytest | 8.4.2 | Test framework |
| pytest-asyncio | 1.4.0 | Async test support |
| pytest-timeout | 2.4.0 | Test timeout enforcement |
| hypothesis | 6.156.7 | Property-based testing (fuzzing) |
| anyio | 4.9+ | Async runtime for IPC simulation |
| websockets | 15.0+ | WS server/client for clipboard protocol tests |
| trustme | 1.2.1 | In-process TLS CA/cert generation |
| cryptography | 45.0.7 | AES-GCM, certs, signatures |
| cmake-format | 0.6.13 | CMakeLists.txt syntax validation |
| cmakelang | 0.6.13 | CMake language tooling |

## What Each Component Can Test (and How)

### 1. D3D11 Shared Texture + Keyed Mutex
**Testable here:** ✅ State machine (ownership protocol, timeout, LOST state, shutdown)
**Not testable here:** ❌ Actual GPU texture sharing, D3D11 device creation
**Approach:** Python fake implementing `AcquireSync(key, timeout)` / `ReleaseSync(key)` as a deterministic state machine. Test all transitions: INIT→PRODUCER→CONSUMER→LOST→SHUTDOWN. Use `hypothesis` to fuzz timeout values and key mismatches. Golden vectors for handle exchange protocol.
```
pytest tests/test_texture_ring.py --hypothesis-show-statistics
```

### 2. WinRT Capture
**Testable here:** ✅ FrameArrived callback logic, SizeChanged→Recreate, DispatcherQueue thread model
**Not testable here:** ❌ Actual WinRT runtime, window enumeration, DPI scaling
**Approach:** Python fake `FramePool` that emits events on virtual timelines. Test racing FrameArrived with Recreate, zero frames, burst frames, callback-after-close. Use `anyio` for async dispatch simulation.
```
pytest tests/test_capture_fakes.py -v
```

### 3. Named Pipe IPC
**Testable here:** ✅ Byte-level protocol (packet framing, fragmentation, backpressure), client-token validation logic
**Not testable here:** ❌ Actual `GetNamedPipeClientProcessId`, `WinVerifyTrust`, DACL enforcement (require Windows)
**Approach:** Python `asyncio.start_server()` / `asyncio.open_connection()` as behavioral substitute. Test malformed lengths, half-close, reconnect, 256-byte bounded message schema. Write the protocol validation logic in a platform-independent layer.
```
pytest tests/test_pipe_protocol.py -v
```

### 4. SendInput / Focus-Aware Injection
**Testable here:** ✅ Input packet decoding (struct), coordinate mapping (DPI math), modifier key state machine, focus lease policy (allowed HWND list, timeout, discard logic)
**Not testable here:** ❌ Actual `SendInput()` call, `GetForegroundWindow()` (require interactive desktop)
**Approach:** Python `struct` / `construct` to validate binary input packet layouts. Pure-function tests for DPI coordinate scaling, modifier tracking, and focus policy state machine.
```
pytest tests/test_input_packets.py tests/test_coordinate_mapping.py -v
```

### 5. WS Server/Client (Clipboard)
**Testable here:** ✅ Everything — WS handshake, TLS 1.3, token auth, clipboard data serialization, dedup logic (seq + hash + origin), rate limiting
**Approach:** Python `websockets` + `trustme` for in-process TLS. Start server + client in same process, test full clipboard sync cycle. Test: token rejection, malformed messages, 100MB payloads, 5 ops/sec rate limiting, format allowlist validation, loop prevention.
```
pytest tests/test_clipboard_ws.py -v
```

### 6. UDP Input Packets (AES-GCM)
**Testable here:** ✅ Everything — AES-GCM encrypt/decrypt, nonce construction, replay window (sliding 1024), sequence rollover, MTU handling
**Approach:** Python `cryptography.hazmat.primitives.ciphers.aead.AESGCM`. `hypothesis` for property-based: sequence numbers must be authenticated as associated data, nonce reuse must be rejected, out-of-order must be correctly accepted/rejected by window. Known-answer vectors for cross-platform verification.
```
pytest tests/test_udp_crypto.py --hypothesis-show-statistics
```

### 7. macOS Swift Client
**Testable here:** ✅ Protocol golden vectors (shared with Python tests), moonlight-common-c ABI contracts via ctypes, Swift syntax via tree-sitter
**Not testable here:** ❌ CAMetalLayer rendering, CGEventTap, NSPasteboard, AVFoundation (require macOS)
**Approach:** Generate golden vectors (binary packets, clipboard payloads) in Python that Swift tests consume. Use `ctypes` for ABI-level moonlight-common-c contract checks. Node.js `tree-sitter-swift` for basic syntax validation.
```
python tests/generate_golden_vectors.py
node tests/check_swift_syntax.mjs Sources/
```

### 8. CMake/MSVC Build System
**Testable here:** ✅ Syntax checking, target graph validation, dependency detection, install rule verification
**Approach:** `cmake-format --check CMakeLists.txt` for formatting. `cmake -S . -B build -G Ninja --trace-expand --trace-format=json-v1` for target graph inspection. Python scripts to validate source file lists match directory contents.
```
cmake-format --check windows/CaptureHelper/CMakeLists.txt
cmake -N -S . -B build  # dry run
```

### 9. Windows Installer (Inno Setup)
**Testable here:** ✅ .iss script structure, file manifests, registry entries, upgrade logic
**Not testable here:** ❌ Actual installation, MSI validation, UAC behavior (require Windows)
**Approach:** Python `configparser` to parse .iss sections. Validate file paths exist. Test upgrade logic (stop → backup → copy → rollback) as a state machine.
```
python tests/validate_installer_manifest.py installer/solstream.iss
```

### 10. Security Tests
**Testable here:** ✅ TLS cert pinning logic, token auth, AES-GCM integrity, replay attacks, malformed packet fuzzing, constant-time comparisons
**Not testable here:** ❌ Windows Authenticode trust chain, named pipe DACL runtime behavior
**Approach:** Python `ssl` + `trustme` for TLS tests. `cryptography` for token signing. `boofuzz` (if installable) or `hypothesis` for protocol fuzzing. Test: expired cert, hostname mismatch, wrong PIN, token replay, old token after re-pair.
```
pytest tests/test_security.py -v
```

## Quick Reference — Run All Tests

```bash
# Protocol & state machine tests (all runnable here)
pytest tests/ -v --ignore=tests/native

# CMake validation
cmake-format --check windows/*/CMakeLists.txt
cmake-format --check macos/SolStreamClient/CMakeLists.txt

# Syntax checks
node tests/check_swift_syntax.mjs macos/SolStreamClient/Sources/

# Generate golden vectors for cross-platform test alignment
python tests/generate_golden_vectors.py --output tests/golden/
```

## What Requires Native CI (Windows/macOS runners)

| Test | Runner | Why |
|---|---|---|
| D3D11 texture + keyed mutex on real GPU | Windows + NVIDIA/AMD/Intel GPU | Needs GPU driver, D3D11 runtime |
| WinRT capture | Windows with desktop session | Needs interactive window station |
| SendInput injection | Windows with desktop session | Needs foreground window |
| Named pipe ACL enforcement | Windows | Needs Windows security descriptor runtime |
| Swift compilation + Metal rendering | macOS 14+ (GitHub Actions macos-14) | Needs Xcode, Metal GPU |
| CGEventTap | macOS with Accessibility | Needs Accessibility permission promptable |
| Inno Setup compilation | Windows | Needs ISCC.exe |
| Full regression matrix | Windows + macOS matrix | Multi-OS, multi-GPU, multi-monitor |
