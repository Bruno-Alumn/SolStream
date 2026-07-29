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
# carry, and no payload to embed.
#
# THE DISPLAY DRIVER IS NOT SHIPPED AND IS NOT DOWNLOADED. This is worth saying
# plainly because the line that used to sit here said the application "downloads
# it itself when the user asks", and there is no code anywhere in SolStream that
# fetches a driver, or anything else, from the internet. What
# InstallBundledDriver in vdd.cpp actually does
# is run pnputil on driver\SolStreamDisplay.inf sitting beside the executable —
# a file this script does not produce — and when it is absent, which is always
# for a packaged build, the "Install driver" button explains that no driver is
# bundled and points the user at the Virtual Display Driver to install by hand.
# So a packaged SolStream streams a real monitor until somebody installs an
# indirect display driver themselves.
#
# NOTHING HERE SIGNS THE EXECUTABLE, and there is no CI: this script is run by
# hand on a Windows machine. An unsigned download means SmartScreen's "Windows
# protected your PC" and an Unknown publisher prompt at the UAC dialog. See
# installer/README.md, which records the gap rather than pretending it is
# closed.
#
# Usage:
#   .\package-windows.ps1

param(
    [string] $OutDir = "$PSScriptRoot\..\dist",
    [string] $BuildDir = "$PSScriptRoot\..\build"
)

$ErrorActionPreference = "Stop"

Write-Host "=== SolStream Windows package ==="

# BUILD_TESTING=OFF because this is a packaging run and there is no C++ suite to
# build: left to its default, include(CTest) turns it ON and the configure walks
# into tests/, which is where a fetched test framework used to be downloaded and
# compiled before anything a user downloads was built.
cmake -S "$PSScriptRoot\.." -B $BuildDir -DBUILD_TESTING=OFF | Out-Null
# Checked for the same reason the build below is, and it is the easier of the two
# to miss: `| Out-Null` swallows the configure's output, so a configure that
# failed leaves this script looking like it printed nothing rather than like it
# went wrong. Carrying on means building whatever the previous configure left in
# $BuildDir and packaging the result as though it were this one.
if ($LASTEXITCODE -ne 0) { throw "cmake could not configure the build ($LASTEXITCODE)" }

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
