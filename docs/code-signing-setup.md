# SolStream — Code Signing Setup

## Overview

All SolStream helper executables (CaptureHelper.exe, ClipboardMonitor.exe,
InputInjector.exe, FileTransferService.exe) must be digitally signed with a
code-signing certificate. Sunshine verifies each helper's signature via
`WinVerifyTrust` before spawning it, preventing tampered/replaced binaries.

This document covers Windows-side helper signing. macOS signing (notarization,
Developer ID) is documented separately.

## Phase 2 Setup (CI Integration)

### Certificate Acquisition

Acquire an **Extended Validation (EV) Code Signing certificate** from a
trusted CA (DigiCert, Sectigo, GlobalSign). EV certificates provide:
- Hardware-token or cloud-HSM key storage
- Immediate SmartScreen reputation (no "Windows protected your PC" warning
  during the reputation-building period)
- SHA-256 timestamping support

Store the certificate:
- **CI:** Azure Key Vault / GitHub Actions Secrets
- **Local dev:** Hardware token (YubiKey) or encrypted `.pfx` with strong password

### Signing Script

The build process generates unsigned `.exe` and `.dll` files. The signing
step runs as a post-build action:

```powershell
# sign-helpers.ps1 — Sign all SolStream helper executables
# Usage: .\sign-helpers.ps1 -CertificateFile cert.pfx -TimestampServer http://timestamp.digicert.com

param(
    [Parameter(Mandatory=$true)]
    [string]$CertificateFile,
    [Parameter(Mandatory=$true)]
    [string]$Password,
    [string]$TimestampServer = "http://timestamp.digicert.com",
    [string]$OutputDir = "."
)

# Find all helpers to sign
$helpers = @(
    "CaptureHelper.exe",
    "ClipboardMonitor.exe",
    "InputInjector.exe",
    "FileTransferService.exe"
)

$signtool = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
if (-not $signtool) {
    # Common locations for signtool
    $possiblePaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x86\signtool.exe",
        "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\signtool.exe"
    )
    foreach ($pattern in $possiblePaths) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($found) {
            $signtool = $found.FullName
            break
        }
    }
}

if (-not $signtool) {
    Write-Error "signtool.exe not found. Install Windows SDK."
    exit 1
}

Write-Host "Using signtool: $signtool"

foreach ($helper in $helpers) {
    $path = Join-Path $OutputDir $helper
    if (-not (Test-Path $path)) {
        Write-Warning "Not found: $path — skipping"
        continue
    }

    Write-Host "Signing: $path..."
    & $signtool sign /fd SHA256 `
        /f $CertificateFile `
        /p $Password `
        /tr $TimestampServer `
        /td SHA256 `
        /v `
        "$path"

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to sign: $path"
        exit 1
    }

    Write-Host "  ✓ Signed"
}

Write-Host "All helpers signed successfully."
```

### Timestamping

Always use **RFC 3161** timestamping (`/tr` flag) with SHA-256 digest
(`/td SHA256`). This ensures signatures remain valid after the certificate
expires. Recommended timestamp servers:

| Server | URL |
|--------|-----|
| DigiCert | `http://timestamp.digicert.com` |
| Sectigo | `http://timestamp.sectigo.com` |
| GlobalSign | `http://timestamp.globalsign.com/tsa/r6advanced` |

### CMake Integration

Add a post-build step to the helper targets in CMakeLists.txt:

```cmake
# In each helper's CMakeLists.txt:
add_custom_command(TARGET CaptureHelper POST_BUILD
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/sign-helpers.ps1
        -CertificateFile ${SOLSTREAM_CERT_FILE}
        -Password ${SOLSTREAM_CERT_PASSWORD}
        -OutputDir $<TARGET_FILE_DIR:CaptureHelper>
    COMMENT "Signing CaptureHelper..."
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)
```

The `SOLSTREAM_CERT_FILE` and `SOLSTREAM_CERT_PASSWORD` cache variables
are set via CMake presets or CI environment.

## Sunshine Helper Verification

Sunshine verifies helper signatures before spawning:

```cpp
bool VerifyHelperSignature(const std::wstring& binaryPath) {
    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = binaryPath.c_str();
    fileInfo.hFile = nullptr;
    fileInfo.pgKnownSubject = nullptr;

    WINTRUST_DATA trustData{};
    trustData.cbStruct = sizeof(trustData);
    trustData.dwUnionChoice = WTD_CHOICE_FILE;
    trustData.pFile = &fileInfo;
    trustData.dwUIChoice = WTD_UI_NONE;          // No UI
    trustData.fdwRevocationChecks = WTD_REVOKE_NONE;
    trustData.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
    trustData.dwStateAction = WTD_STATEACTION_IGNORE;

    GUID policyGUID = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status = WinVerifyTrust(nullptr, &policyGUID, &trustData);
    return status == ERROR_SUCCESS;
}
```

This is called from the `ProcessSupervisor` before `CreateProcess`:

```cpp
if (!VerifyHelperSignature(helperPath)) {
    Log("Refusing to spawn %ls: signature verification failed.",
        helperPath.c_str());
    return false;
}
```

## CI Pipeline Integration

```yaml
# GitHub Actions — signing step
- name: Sign helpers
  shell: powershell
  run: |
    .\scripts\sign-helpers.ps1 `
      -CertificateFile $env:SOLSTREAM_PFX `
      -Password $env:SOLSTREAM_PFX_PASSWORD
  env:
    SOLSTREAM_PFX: ${{ secrets.SOLSTREAM_CODE_SIGN_PFX }}
    SOLSTREAM_PFX_PASSWORD: ${{ secrets.SOLSTREAM_CODE_SIGN_PASSWORD }}
```

## Development / Testing

For local development without a real certificate:

1. Create a **self-signed certificate** for testing:
   ```powershell
   New-SelfSignedCertificate -Type CodeSigning `
       -Subject "CN=SolStream Dev" `
       -CertStoreLocation "Cert:\CurrentUser\My"
   ```

2. Sign with the test cert:
   ```powershell
   signtool sign /fd SHA256 /a /n "SolStream Dev" /
       /tr http://timestamp.digicert.com /td SHA256 CaptureHelper.exe
   ```

3. Add the test certificate to the **Trusted Publishers** store on
   the development machine so WinVerifyTrust passes.

**Note:** Self-signed certificates will fail `WinVerifyTrust` on other
machines. This is expected — production builds must use a real EV cert.
