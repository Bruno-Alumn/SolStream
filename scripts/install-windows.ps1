# NOTE ON THE BOM AT THE TOP OF THIS FILE
#
# Windows PowerShell 5.1 - still the default on Windows 11 - reads a .ps1 as
# ANSI unless the file declares itself otherwise. Without the byte-order mark
# any non-ASCII character in a string breaks the parser. The BOM is the
# declaration. Do not strip it.
#
# install-windows.ps1 - install the SolStream host application.
#
# Run it against the folder package-windows.ps1 produced:
#
#     .\install-windows.ps1 -Package ..\dist\SolStream
#     .\install-windows.ps1 -Uninstall
#
# ── Why this exists, rather than "unzip it somewhere" ────────────────────────
#
# Windows will not let a program accept connections it has never been asked
# about. Normally it asks: the first time a program listens, a dialog appears
# and the answer becomes a firewall rule. SolStream starts from a logon task,
# which has no desktop to show a dialog on, so nothing asks and Windows decides
# for itself - it writes a BLOCK rule and the host silently accepts nothing.
#
# Worse, that block cannot be undone by adding permission afterwards. An explicit
# Block beats an Allow in Windows Firewall, so a later "allow this program" rule
# changes nothing at all. Measured on a real machine: with SolStream's own
# binaries blocked this way, ports 47595-47630 were refused from the Mac while
# 22, 47984 and 47989 stayed open, and neither a program-scoped nor a
# port-scoped Allow rule reopened them.
#
# So the rules have to exist BEFORE anything listens for the first time, and any
# stale Block left by an earlier run has to be removed rather than out-voted.
# That is the whole reason installation is a step rather than a copy.

param(
    [string] $Package = "$PSScriptRoot\..\dist\SolStream",
    [string] $Destination = "$env:ProgramFiles\SolStream",
    [switch] $Uninstall
)

$ErrorActionPreference = "Stop"

$RuleGroup = "SolStream"
$TaskName = "SolStream Host"

# ── Elevation ────────────────────────────────────────────────────────────────
#
# Firewall rules, Program Files and scheduled tasks all need it. Re-launching
# ourselves elevated shows the UAC prompt, which is the right place for the user
# to see what is being asked for.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Administrator rights are needed; asking..."
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" " +
                 "-Package `"$Package`" -Destination `"$Destination`""
    if ($Uninstall) { $arguments += " -Uninstall" }
    Start-Process powershell -Verb RunAs -ArgumentList $arguments -Wait
    exit
}

function Remove-SolStreamFirewallRules {
    param([string] $Root)

    # By group first: everything this installer created, whatever it was for.
    Get-NetFirewallRule -Group $RuleGroup -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue

    # Then by program path, which is what catches the Block rules Windows wrote
    # by itself. Those carry no group of ours, so nothing else would find them,
    # and leaving one behind means the install looks complete and accepts
    # nothing.
    if ($Root) {
        $normalised = $Root.TrimEnd('\').ToLowerInvariant()
        Get-NetFirewallApplicationFilter -All -ErrorAction SilentlyContinue |
            Where-Object { $_.Program -and $_.Program.ToLowerInvariant().StartsWith($normalised) } |
            ForEach-Object {
                $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue |
                    Remove-NetFirewallRule -ErrorAction SilentlyContinue
            }
    }
}

# ── Uninstall ────────────────────────────────────────────────────────────────

if ($Uninstall) {
    Write-Host "=== Removing SolStream ==="

    Get-Process -Name SolStream -ErrorAction SilentlyContinue | Stop-Process -Force
    # Its Sunshine goes with it through the job object, but not instantly.
    Start-Sleep -Seconds 2
    Get-Process -Name sunshine -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Destination) } |
        Stop-Process -Force

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-SolStreamFirewallRules -Root $Destination

    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }

    # Deliberately left behind: %LOCALAPPDATA%\SolStream holds the pairing
    # token, the generated Sunshine credentials and which display to capture.
    # Reinstalling and having to pair every Mac again is a worse default than
    # leaving a few kilobytes on a machine somebody may well install to again.
    Write-Host "Removed. Your settings are kept in $env:LOCALAPPDATA\SolStream;"
    Write-Host "delete that folder too if you want SolStream to forget this PC."
    exit
}

# ── Install ──────────────────────────────────────────────────────────────────

Write-Host "=== Installing SolStream ==="

if (-not (Test-Path (Join-Path $Package "SolStream.exe"))) {
    throw "No SolStream.exe in $Package - run package-windows.ps1 first"
}

# Stop anything already running from the destination, or the copy fails on a
# locked file and leaves a half-installed folder.
Get-Process -Name SolStream -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-Process -Name sunshine -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Destination) } |
    Stop-Process -Force

Write-Host "--- copying to $Destination ---"
robocopy $Package $Destination /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$global:LASTEXITCODE = 0

# Sunshine creates this at startup whatever its configuration says, and under
# Program Files it cannot -- it exits 0 before its logging is up, leaving an
# empty log and a host that reports "Sunshine keeps stopping" with no reason.
# The package ships it empty, but an empty directory does not survive every way
# a folder gets moved around (most zip tools drop them), and the cost of being
# wrong here is a completely dead install. Made here too, where there are
# administrator rights to make it with.
$sunshineConfig = Join-Path $Destination "sunshine\config"
if (-not (Test-Path $sunshineConfig)) {
    New-Item -ItemType Directory -Path $sunshineConfig -Force | Out-Null
}

# ── Firewall, before anything has listened ───────────────────────────────────

Write-Host "--- firewall ---"
Remove-SolStreamFirewallRules -Root $Destination

$programs = @(
    (Join-Path $Destination "SolStream.exe"),
    (Join-Path $Destination "sunshine\sunshine.exe")
)
foreach ($program in $programs) {
    if (-not (Test-Path $program)) { continue }
    $name = Split-Path $program -Leaf
    foreach ($protocol in @("TCP", "UDP")) {
        New-NetFirewallRule `
            -DisplayName "SolStream ($name, $protocol)" `
            -Group $RuleGroup `
            -Direction Inbound `
            -Program $program `
            -Protocol $protocol `
            -Action Allow `
            -Profile Any | Out-Null
    }
    Write-Host "  allowed $name (TCP and UDP, all profiles)"
}

# ── Start at logon ───────────────────────────────────────────────────────────
#
# /it - interactive. A process in session 0 sees a phantom display and no
# windows at all, so it can neither show its own window nor find the
# application the Mac asked to stream.
Write-Host "--- start at logon ---"
# Register-ScheduledTask rather than schtasks.exe: schtasks takes the whole
# command as one string and splits it on spaces, so "C:\Program Files\SolStream\
# SolStream.exe" was stored as Command="C:\Program", Arguments="Files\...", and
# the task failed with ERROR_FILE_NOT_FOUND. Quoting does not survive the trip.
#
# --listen-all because an installed host that only answers on loopback is a host
# no Mac can reach. The socket requires the pairing token whenever it is not on
# loopback, and the window shows that token - that is the lock, not the address.
$action = New-ScheduledTaskAction -Execute (Join-Path $Destination "SolStream.exe") `
                                  -Argument "--listen-all" `
                                  -WorkingDirectory $Destination
$trigger = New-ScheduledTaskTrigger -AtLogOn
# Interactive: a process in session 0 sees a phantom display and no windows at
# all, so it could neither show its own window nor find the application the Mac
# asked for.
# Whoever is logged in at the console, not whoever ran the installer. Normally
# the same person, but an administrator installing for somebody else should not
# register a task that runs as themselves - and $env:USERDOMAIN is empty in a
# non-interactive session, which fails as ERROR_NONE_MAPPED (0x80070534).
$owner = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $owner) {
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
}
Write-Host "  running as $owner at logon"
$principal = New-ScheduledTaskPrincipal -UserId $owner `
                                        -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                         -DontStopIfGoingOnBatteries `
                                         -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                       -Principal $principal -Settings $settings -Force | Out-Null

Write-Host ""
Write-Host "=== Installed to $Destination ==="
Write-Host "Starting it now; it will also start when you log in."
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 8
$running = Get-Process -Name SolStream -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "SolStream is running (pid $($running.Id))."
} else {
    Write-Host "SolStream did not start - run $Destination\SolStream.exe by hand to see why."
}
