# SolStream — Tooling Gap Solutions

## Gap 1: MSVC + Windows SDK for C++ Compilation

**Best approach: Host compilation + VM testing**
Compile on host (Win11 Pro) with MSVC, copy binaries to VM via PowerShell Direct for testing.

### Install on HOST:
```powershell
winget install --id Kitware.CMake --exact
winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --override `
  "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools `
  --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --includeRecommended"
```

### Build + deploy to VM:
```powershell
cmake --preset windows-msvc-debug
cmake --build --preset windows-msvc-debug
Copy-Item .\out\build\windows-msvc-debug\*.exe -ToSession $vmSession -Destination C:\Tests\
Invoke-Command -VMName SolStreamTest -ScriptBlock { C:\Tests\CaptureHelper.exe --test }
```

**CMakePresets.json** — includes `windows-msvc-debug` and `windows-msvc-release` presets.

---

## Gap 2: Google Test for C++ Unit Tests

**Best approach: CMake FetchContent** (both agents agree)

```cmake
include(FetchContent)
FetchContent_Declare(googletest URL https://github.com/google/googletest/archive/refs/tags/v1.15.2.zip)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)
```

Test files with full examples:
- `tests/luid_negotiation_test.cpp` — LUID match/mismatch
- `tests/keyed_mutex_ring_test.cpp` — acquire/release/timeout/LOST
- `tests/named_pipe_parser_test.cpp` — framing, partial frames, oversized
- `tests/clipboard_dedup_test.cpp` — identical content suppression
- `tests/coordinate_mapping_test.cpp` — DPI scaling math

---

## Gap 3: Interactive Hyper-V Desktop for WinRT/SendInput

**Key insight:** Enhanced Session Mode locks the screen on disconnect, suspending graphics. 
**Solution:** Use Basic Session console + auto-logon.

### Auto-logon:
```powershell
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
New-ItemProperty $winlogon -Name AutoAdminLogon -PropertyType String -Value "1" -Force
New-ItemProperty $winlogon -Name DefaultUserName -PropertyType String -Value "SolStreamTest" -Force
New-ItemProperty $winlogon -Name DefaultPassword -PropertyType String -Value "PASSWORD" -Force
New-ItemProperty $winlogon -Name DefaultDomainName -PropertyType String -Value $env:COMPUTERNAME -Force
```

Or use Sysinternals Autologon: `Autologon64.exe SolStreamTest $env:COMPUTERNAME "PASSWORD"`

### Disconnect without locking:
```powershell
tscon.exe 1 /dest:console
```
This drops the RDP/VMConnect session but keeps the desktop active.

---

## Gap 4: macOS CI Runner Alternatives

| Option | Cost | GPU/HW Accel | Notes |
|---|---|---|---|
| **GitHub Actions macos-14** | Included in GH plan | Yes (Apple Silicon) | Easiest, no setup |
| **WarpBuild** | ~$0.02/min | Yes | Drop-in GH runner replacement, faster |
| **Blacksmith** | ~$0.02/min | Yes | Same as above |
| **MacStadium** | ~$99/mo dedicated | Yes | Full hardware access |
| **Macly/MacRent** | ~$50-80/mo | Yes | Dedicated Mac mini M4 |

**Recommendation:** Start with GitHub Actions `macos-14` (free with plan). Only move to dedicated hardware if CGEventTap or Metal tests need it.

Workflow YAML — includes moonlight-common-c build, Swift build, Xcode build+test, all in one pipeline.

---

## Gap 5: Inno Setup Compilation

```powershell
winget install --id JRSoftware.InnoSetup --exact
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /Q /O".\artifacts" installer\SolStream.iss
```
