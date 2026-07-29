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
# There is one file to assemble now.
#
#     SolStreamSetup.exe    what a person downloads
#
# This script used to build a folder: the executable, 65 MB of unmodified
# Sunshine with its assets and web UI, a display driver package, and a licenses\
# directory carrying Sunshine's GPL-3.0 text and a NOTICE explaining where to
# get its corresponding source. All of it was then zipped and linked into the
# executable as a resource so that one file could unpack the rest into Program
# Files.
#
# None of that exists any more. SolStream captures, encodes and sends the
# picture itself, so there is no second program to ship, no GPL obligation to
# carry, and no payload to embed. The driver is still optional and still
# offered by the application, which downloads it itself when the user asks.
#
# Usage:
#   .\package-windows.ps1

param(
    [string] $OutDir = "$PSScriptRoot\..\dist",
    [string] $BuildDir = "$PSScriptRoot\..\build"
)

$ErrorActionPreference = "Stop"

Write-Host "=== SolStream Windows package ==="

cmake -S "$PSScriptRoot\.." -B $BuildDir | Out-Null
cmake --build $BuildDir --target SolStreamAgent --config Release
# $ErrorActionPreference does not apply to a native command's exit code, so a
# failed build carries straight on. It has already shipped one stale binary:
# a running agent held SolStreamAgent.exe open, the link failed with LNK1104,
# and the script packaged the PREVIOUS build.
if ($LASTEXITCODE -ne 0) { throw "the build failed ($LASTEXITCODE)" }

$exe = Join-Path $BuildDir "bin\release\SolStreamAgent.exe"
if (-not (Test-Path $exe)) { throw "no executable at $exe" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Named SolStreamSetup.exe rather than SolStream.exe, because that is what it is
# when it is downloaded: run from anywhere other than the install directory it
# shows the setup screen, and what it copies into Program Files is itself, named
# SolStream.exe. One binary, two names, no second project to keep in step.
$single = Join-Path $OutDir "SolStreamSetup.exe"
Copy-Item $exe $single -Force

# An earlier release of this script wrote SolStream.exe here. Leaving it beside
# the new name would mean two downloads that differ only in which one is stale.
$stale = Join-Path $OutDir "SolStream.exe"
if (Test-Path $stale) { Remove-Item $stale -Force }

Write-Host ("=== Setup program: {0} ({1:N1} MB) ===" -f $single, ((Get-Item $single).Length / 1MB))
