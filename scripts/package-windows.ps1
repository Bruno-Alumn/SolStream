# NOTE ON THE BOM AT THE TOP OF THIS FILE
#
# Windows PowerShell 5.1 — still the default on Windows 11 — reads a .ps1 as
# ANSI unless the file declares itself otherwise. Without the byte-order mark
# the em dashes in the strings below arrive as mojibake and the parser fails on
# them: "Unexpected token 'pass' in expression or statement". The BOM is the
# declaration. Do not strip it.
#
# package-windows.ps1 - assemble the SolStream host application for Windows.
#
# Produces one folder that can be zipped or handed to an installer:
#
#     SolStream\
#       SolStream.exe            the host application
#       sunshine\                Sunshine's own unmodified build
#         sunshine.exe
#         assets\                its shaders and web UI — it looks for these
#                                relative to its own directory, so the whole
#                                install goes in, not just the executable
#       driver\                  an indirect display driver package, if you ship
#         SolStreamDisplay.inf   one; the app offers to install it when the
#                                machine has no virtual display
#       licenses\
#         Sunshine-LICENSE.txt   GPL-3.0, and where to get its source
#
# The layout is what FindSunshine (sunshine_host.cpp) looks for: `sunshine\
# sunshine.exe` beside the executable wins over anything installed in Program
# Files, so a machine that already has Sunshine keeps its own and SolStream uses
# the copy it was tested against.
#
# ── Licensing ────────────────────────────────────────────────────────────────
#
# Sunshine is GPL-3.0 and is shipped here as its own unmodified binary, run as a
# child process over the network protocol any Moonlight client speaks. Nothing
# links against it. Distributing it still carries the GPL's obligations: its
# licence text goes in the package, and whoever ships this has to be able to
# provide its corresponding source.
#
# Usage:
#   .\package-windows.ps1 -SunshineDir "C:\Program Files\Sunshine" [-DriverDir <path>]

param(
    [string] $SunshineDir = "C:\Program Files\Sunshine",
    [string] $DriverDir = "",
    [string] $OutDir = "$PSScriptRoot\..\dist\SolStream",
    [string] $BuildDir = "$PSScriptRoot\..\build"
)

$ErrorActionPreference = "Stop"

Write-Host "=== SolStream Windows package ==="

# Step 1: build
cmake -S "$PSScriptRoot\.." -B $BuildDir | Out-Null
cmake --build $BuildDir --target SolStreamAgent --config Release

$exe = Join-Path $BuildDir "bin\release\SolStreamAgent.exe"
if (-not (Test-Path $exe)) {
    throw "Built executable not found at $exe"
}

# Step 2: lay the folder out fresh
if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path "$OutDir\licenses" | Out-Null

# Named for the product rather than for what it was called while it was only an
# agent. FindSunshine resolves everything relative to this file's directory, so
# the name is free.
Copy-Item $exe (Join-Path $OutDir "SolStream.exe") -Force

# Step 3: Sunshine, whole
if (-not (Test-Path (Join-Path $SunshineDir "sunshine.exe"))) {
    throw "No sunshine.exe in $SunshineDir — pass -SunshineDir"
}
Write-Host "--- copying Sunshine from $SunshineDir ---"
robocopy $SunshineDir "$OutDir\sunshine" /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$global:LASTEXITCODE = 0

# Its own config directory is never used — SolStream writes one per user under
# LOCALAPPDATA — so drop anything the source install had, rather than shipping
# somebody's paired clients and credentials to whoever installs this.
$staleConfig = "$OutDir\sunshine\config"
if (Test-Path $staleConfig) {
    Remove-Item $staleConfig -Recurse -Force
    Write-Host "removed the source install's config (it would have shipped its paired clients)"
}

# Step 4: the display driver, if one is being shipped
if ($DriverDir -ne "" -and (Test-Path $DriverDir)) {
    robocopy $DriverDir "$OutDir\driver" /E /NFL /NDL /NJH /NJS /NP | Out-Null
    $global:LASTEXITCODE = 0
    Write-Host "--- bundled the display driver from $DriverDir ---"
} else {
    Write-Host "--- no display driver bundled; the app will say so and explain what to install ---"
}

# Step 5: licences
$sunshineLicense = Join-Path $SunshineDir "LICENSE"
if (Test-Path $sunshineLicense) {
    Copy-Item $sunshineLicense "$OutDir\licenses\Sunshine-LICENSE.txt" -Force
}
@"
SolStream ships Sunshine (https://github.com/LizardByte/Sunshine), which is
licensed under the GNU General Public License v3.0.

Sunshine is included here as its own unmodified binary. SolStream does not link
against it and contains none of its code; it is started as a separate process
and talked to over the network protocol any Moonlight client uses.

The corresponding source for the included build is available from
https://github.com/LizardByte/Sunshine at the tag matching sunshine\sunshine.exe
(run it with --version), and from whoever supplied this package on request.
"@ | Set-Content -Encoding UTF8 "$OutDir\licenses\Sunshine-NOTICE.txt"

$size = (Get-ChildItem $OutDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Host ""
Write-Host ("=== Done: {0} ({1:N0} MB) ===" -f $OutDir, $size)
Get-ChildItem $OutDir | Select-Object -ExpandProperty Name
