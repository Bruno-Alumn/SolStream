# SolStream — Tooling Capability Audit

## Audit

| # | Component | Status | What's Needed |
|---|---|---|---|
| **1** | D3D11 shared texture + keyed mutex | **GAP** | Hyper-V VM with GPU-PV + compiled native test harness |
| **2** | WinRT capture | **GAP** | Same Windows GPU-PV VM + Windows SDK test binaries |
| **3** | Named pipe IPC | **GAP** | Native Windows test harness (byte protocol ✅, ACLs ❌) |
| **4** | SendInput / focus injection | **GAP** | Windows VM with interactive desktop + native test exe |
| **5** | WS server/client clipboard | **✅ COVERED** | pytest + websockets + trustme — full TLS/token testing |
| **6** | UDP AES-GCM packets | **✅ COVERED** | cryptography + hypothesis — replay window, nonce, seq |
| **7** | macOS Swift client | **GAP** | macOS runner with Xcode (macos-14 GitHub runner) |
| **8** | CMake/MSVC build | **GAP** | Visual Studio Build Tools + Windows SDK |
| **9** | Inno Setup installer | **GAP** | ISCC.exe on Windows (via VM) |
| **10** | Security tests | **✅ COVERED** | ssl + trustme + cryptography — cert pinning, tokens, fuzz |

## What I Can Test Right Now (no additional setup)

These 3 areas are fully testable from the current environment with installed Python packages:

- **WS clipboard protocol** — full bidirectional sync, dedup, rate limiting, token auth, TLS 1.3
- **UDP input crypto** — AES-GCM encrypt/decrypt, replay window, nonce management, sequence rollover
- **Security layer** — cert pinning logic, token validation, constant-time compare, malformed packet rejection

## What Needs One-Time Setup (then I handle everything)

### 1. Hyper-V VM with GPU-PV (closes GAPS 1-4, helps 8 & 9)

**You do once:**
```powershell
# Enable Hyper-V
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All

# Create VM
New-VM -Name SolStreamTest -MemoryGB 8 -BootDevice VHD
Add-VMGpuPartitionAdapter -VMName SolStreamTest
Set-VMGpuPartitionAdapter -VMName SolStreamTest -MinPartitionVRAM 80000000
```

**Then I do:**
- Install Windows SDK + VS Build Tools inside VM (via PowerShell Direct)
- Build CaptureHelper, ClipboardMonitor, InputInjector, FileTransferService
- Copy binaries and test harnesses into VM
- Execute D3D11 texture tests, WinRT capture tests, SendInput tests
- Capture results, debug failures, fix code, rebuild, redeploy, retest

### 2. Visual Studio Build Tools (closes GAP 8)

Install on the Hyper-V VM (or host if preferred):
```
winget install Microsoft.VisualStudio.2022.BuildTools
```

### 3. Inno Setup (closes GAP 9)

Install in VM:
```
winget install JRSoftware.InnoSetup
```

### 4. macOS GitHub Runner (closes GAP 7)

Add a GitHub Actions workflow targeting `macos-14` (M1) or `macos-13` (Intel) for:
- Swift compilation of SolStreamClient
- moonlight-common-c integration tests
- No local macOS needed

## Summary

**Without Hyper-V VM:** I can test 3/10 areas (protocol/security only)
**With Hyper-V VM + Build Tools:** I can test 9/10 areas (everything except macOS)
**Adding a macOS GitHub runner:** I can test 10/10

Want me to outline the exact steps to enable Hyper-V and get started?
