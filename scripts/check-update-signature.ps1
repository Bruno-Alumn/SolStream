# check-update-signature.ps1 - check a built setup tells good update signatures
# from bad ones.
#
# The host is its own updater: if it cannot tell a good signature from a bad
# one, no release after the one it came in reaches anybody. This runs the
# contract's CLI (docs/updates.md) against the test vector, on the setup under
# its release name and from outside an install folder, as a release runs it
# before publishing. CI runs the same on every commit that changes the host.
#
# Usage:
#   .\check-update-signature.ps1 -Setup dist\SolStreamSetup-X.Y.Z.exe

#Requires -Version 7

param(
    [Parameter(Mandatory = $true)] [string] $Setup
)

$ErrorActionPreference = "Stop"

$exe = (Resolve-Path $Setup).Path
$vector = (Resolve-Path (Join-Path $PSScriptRoot "..\tests\update-vector")).Path
$testKey = (Get-Content "$vector\test-key.pub.b64" -TotalCount 1).Trim()

# The same signature over a SHA256SUMS with one byte changed.
$temp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tampered = (New-Item -ItemType Directory -Force (Join-Path $temp "tampered-vector")).FullName
$bytes = [IO.File]::ReadAllBytes("$vector\SHA256SUMS")
$bytes[0] = $bytes[0] -bxor 1
[IO.File]::WriteAllBytes("$tampered\SHA256SUMS", $bytes)
Copy-Item "$vector\SHA256SUMS.sig" $tampered

function Test-Signature([string[]] $arguments, [int] $expected, [string] $what) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    foreach ($argument in @("--verify-update-signature") + $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    # A build that does not know the flag opens its setup window
    # instead, and nobody on a runner is going to close it.
    if (-not $process.WaitForExit(60000)) {
        $process.Kill($true)
        throw "${what}: still running after a minute"
    }
    if ($process.ExitCode -ne $expected) {
        throw "${what}: exit code $($process.ExitCode), expected $expected"
    }
    Write-Host "${what}: $expected, as expected"
}

Test-Signature @("$vector\SHA256SUMS", "$vector\SHA256SUMS.sig", $testKey) 0 "test vector, test key"
Test-Signature @("$tampered\SHA256SUMS", "$tampered\SHA256SUMS.sig", $testKey) 1 "one byte changed"
Test-Signature @("$vector\SHA256SUMS", "$vector\SHA256SUMS.sig") 1 "test vector, compiled-in key"
