# SolStream — Sign all helper executables
# Requires: Windows SDK (signtool.exe), code-signing certificate
# Usage:
#   .\sign-helpers.ps1 -CertificateFile cert.pfx -Password "secret"
#   .\sign-helpers.ps1 -CertificateFile cert.pfx -Password "secret" -TimestampServer http://timestamp.digicert.com

param(
    [Parameter(Mandatory=$true)]
    [string]$CertificateFile,

    [Parameter(Mandatory=$true)]
    [string]$Password,

    [string]$TimestampServer = "http://timestamp.digicert.com",

    [string]$OutputDir = "."
)

$helpers = @(
    "CaptureHelper.exe",
    "ClipboardMonitor.exe",
    "InputInjector.exe",
    "FileTransferService.exe"
)

# Locate signtool.exe
$signtool = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
if (-not $signtool) {
    $patterns = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x86\signtool.exe",
        "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\signtool.exe"
    )
    foreach ($pattern in $patterns) {
        $found = Get-ChildItem $pattern -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($found) { $signtool = $found.FullName; break }
    }
}
if (-not $signtool) { Write-Error "signtool.exe not found. Install Windows SDK."; exit 1 }

Write-Host "Using signtool: $signtool"
Write-Host "Timestamp server: $TimestampServer"

$exitCode = 0
foreach ($helper in $helpers) {
    $path = Join-Path $OutputDir $helper
    if (-not (Test-Path $path)) {
        Write-Warning "Not found: $path — skipping"
        continue
    }
    Write-Host "Signing: $path ..."
    & $signtool sign /fd SHA256 `
        /f $CertificateFile `
        /p $Password `
        /tr $TimestampServer `
        /td SHA256 `
        /v "$path" 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "FAILED: $path (exit code $LASTEXITCODE)"
        $exitCode = 1
    } else {
        Write-Host "  OK"
    }
}

if ($exitCode -eq 0) {
    Write-Host "All helpers signed successfully."
}
exit $exitCode
