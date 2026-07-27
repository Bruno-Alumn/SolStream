<#
.SYNOPSIS
    Prepare a virtual display for SolStream to stream a single application onto.

.DESCRIPTION
    SolStream crops one application's rectangle out of a captured display. If that
    display is the real monitor, anything the user drags over the application is
    streamed as though it were part of it. Parking the application on a display
    with no physical panel removes the problem at the source, and — unlike an HDMI
    dummy plug, whose EDID offers a fixed list of modes — a virtual display can be
    sized to match the client Mac exactly, so no scaling happens anywhere.

    This configures MikeTheTech's Virtual Display Driver:
      1. adds the requested mode to vdd_settings.xml (its mode list is that file)
      2. restarts the device so the driver re-reads it
      3. attaches the display to the desktop at that mode
      4. sets its DPI scaling, so Windows draws UI at the Mac's backing scale

.PARAMETER Width, Height
    The canvas, in physical pixels. Match the client Mac's screen: its size in
    points multiplied by its backing scale factor. SolStream logs this on startup
    as "[canvas] this Mac is ... = WxH physical".

.PARAMETER Scale
    Windows DPI scaling percent. 200 matches a 2x Retina Mac exactly: Windows
    draws UI at 2x, macOS displays it at 2x, so controls end up the same physical
    size as native ones. Must be one of Windows' fixed steps.

.PARAMETER ConfigureSunshine
    Also point Sunshine's output_name at this display, by reading the device id
    out of Sunshine's own log. Sunshine encodes exactly one display; if it is not
    this one, every crop comes from the wrong pixels.

.NOTES
    Must run ELEVATED and in the INTERACTIVE session. Display configuration is
    session-bound: run over SSH or as a service it lands in session 0, which has a
    phantom 1024x768 desktop, and the attach silently does nothing.
#>
[CmdletBinding()]
param(
    [int]    $Width  = 3600,
    [int]    $Height = 2338,
    [int]    $Scale  = 200,
    [string] $VddPath = 'C:\VirtualDisplayDriver',
    [switch] $ConfigureSunshine,
    [string] $SunshineConfig = 'C:\Program Files\Sunshine\config\sunshine.conf',
    [string] $SunshineLog    = 'C:\Program Files\Sunshine\config\sunshine.log'
)

$ErrorActionPreference = 'Stop'

# ── Preconditions ────────────────────────────────────────────────────────────

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this elevated: it restarts a display device."
}
if ((Get-Process -Id $PID).SessionId -eq 0) {
    throw "Run this in the interactive session. Session 0 has no real desktop, so attaching a display there does nothing."
}
$settings = Join-Path $VddPath 'vdd_settings.xml'
if (-not (Test-Path $settings)) {
    throw "No Virtual Display Driver at $VddPath. Install it first (see README.md)."
}

# ── Native display APIs ──────────────────────────────────────────────────────
#
# The structs are deliberately FLAT — the device-info header is inlined rather
# than nested. PowerShell hands back a *copy* when you read a nested value-type
# field, so "$x.header.type = 1" writes to a temporary that is then discarded,
# and the call goes out with a zeroed header (ERROR_GEN_FAILURE, 31).

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SolDisp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public uint dmPanningWidth, dmPanningHeight;
  }
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential, Size = 48)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC sourceInfo; public TGT targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential, Size = 64)] public struct MODE { public uint infoType; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct SRCNAME {
    public int type; public uint size; public uint adapLow; public int adapHigh; public uint id;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
  }
  [StructLayout(LayoutKind.Sequential)] public struct DPIGET {
    public int type; public uint size; public uint adapLow; public int adapHigh; public uint id;
    public int minScaleRel, curScaleRel, maxScaleRel;
  }
  [StructLayout(LayoutKind.Sequential)] public struct DPISET {
    public int type; public uint size; public uint adapLow; public int adapHigh; public uint id;
    public int scaleRel;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplayDevicesW")]
  public static extern bool EnumAdapters(IntPtr dev, uint n, ref DISPLAY_DEVICE d, uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsW")]
  public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
  public static extern int Change(string dev, ref DEVMODE dm, IntPtr wnd, uint flags, IntPtr p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
  public static extern int ApplyAll(IntPtr dev, IntPtr dm, IntPtr wnd, uint flags, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PATH[] p, ref uint nm, [Out] MODE[] m, IntPtr t);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref SRCNAME r);
  [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref DPIGET r);
  [DllImport("user32.dll")] public static extern int DisplayConfigSetDeviceInfo(ref DPISET r);
}
"@

$szDev  = [Runtime.InteropServices.Marshal]::SizeOf([type][SolDisp+DISPLAY_DEVICE])
$szMode = [Runtime.InteropServices.Marshal]::SizeOf([type][SolDisp+DEVMODE])
$szName = [Runtime.InteropServices.Marshal]::SizeOf([type][SolDisp+SRCNAME])
$szGet  = [Runtime.InteropServices.Marshal]::SizeOf([type][SolDisp+DPIGET])
$szSet  = [Runtime.InteropServices.Marshal]::SizeOf([type][SolDisp+DPISET])

function Find-VddAdapter {
    for ($n = 0; $n -lt 32; $n++) {
        $d = New-Object SolDisp+DISPLAY_DEVICE; $d.cb = $szDev
        if (-not [SolDisp]::EnumAdapters([IntPtr]::Zero, $n, [ref]$d, 0)) { return $null }
        if ($d.DeviceString -like '*Virtual Display Driver*') {
            return [pscustomobject]@{ Name = $d.DeviceName; Attached = [bool]($d.StateFlags -band 0x1) }
        }
    }
    return $null
}

# ── 1. Teach the driver the mode ─────────────────────────────────────────────

# Every Retina Mac size we know about, in host pixels (points x 2), plus the
# requested one. Seeding the whole ladder up front is what keeps this out of the
# streaming path: a device restart is needed to ADD a mode, never to switch
# between modes already in the list. So pay it once here, then any Mac that
# connects later just calls ChangeDisplaySettingsEx.
#
# All are within 4096 in both axes, which is NVENC's H.264 limit — a larger canvas
# starts a session that never delivers a frame.
$LADDER = @(
    @{w=2560; h=1440},   # 1280x720  @2x, and a 1440p panel at 100%
    @{w=2560; h=1600},   # 1280x800  @2x
    @{w=2880; h=1800},   # 1440x900  @2x — 13" Air default
    @{w=2940; h=1912},   # 1470x956  @2x — 14" MBP default
    @{w=3024; h=1964},   # 1512x982  @2x — 14" MBP native
    @{w=3420; h=2214},   # 1710x1107 @2x — 16" MBP default
    @{w=3456; h=2234},   # 1728x1117 @2x — 16" MBP native
    @{w=3600; h=2338},   # 1800x1169 @2x
    @{w=3840; h=2160}    # 4K panel at 100%
)

$wanted = @($LADDER)
if (-not ($wanted | Where-Object { $_.w -eq $Width -and $_.h -eq $Height })) {
    $wanted += @{w=$Width; h=$Height}
}
foreach ($m in $wanted) {
    if ($m.w -gt 4096 -or $m.h -gt 4096) {
        throw "${($m.w)}x${($m.h)} exceeds NVENC's 4096 limit; a session at that size never delivers video."
    }
}

$raw = [System.IO.File]::ReadAllText($settings)
$have = @{}
foreach ($m in [regex]::Matches($raw, '<width>\s*(\d+)\s*</width>\s*<height>\s*(\d+)\s*</height>')) {
    $have["$($m.Groups[1].Value)x$($m.Groups[2].Value)"] = $true
}
$missing = @($wanted | Where-Object { -not $have.ContainsKey("$($_.w)x$($_.h)") })

$modeAdded = $false
if ($missing.Count -gt 0) {
    Copy-Item $settings "$settings.solstream-backup" -Force -ErrorAction SilentlyContinue
    $idx = $raw.LastIndexOf('</resolutions>')
    if ($idx -lt 0) { throw "vdd_settings.xml has no <resolutions> block." }
    # One refresh rate per added resolution, not the file's global list: the driver
    # replicates every <g_refresh_rate> across every resolution, so the mode count
    # is (resolutions x global rates) and a long ladder against six global rates is
    # how the target-mode buffer overflows. That overflow is the nastiest failure
    # here — the driver logs "Input buffer is too small for target modes" and then
    # reports success, so it presents as a healthy device with no display at all.
    $block = ''
    foreach ($m in $missing) {
        $block += "        <resolution>`r`n            <width>$($m.w)</width>`r`n            <height>$($m.h)</height>`r`n            <refresh_rate>60</refresh_rate>`r`n        </resolution>`r`n"
    }
    [System.IO.File]::WriteAllText($settings, $raw.Substring(0, $idx) + $block + "    " + $raw.Substring($idx),
                                   (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Added to vdd_settings.xml: " + (($missing | ForEach-Object { "$($_.w)x$($_.h)" }) -join ', '))
    $modeAdded = $true
} else {
    Write-Host "All ladder modes already offered by the driver"
}

# The driver reads that file when the device starts, so a new mode needs a cycle.
if ($modeAdded) {
    Write-Host "Restarting the virtual display device..."
    Import-Module PnpDevice -ErrorAction SilentlyContinue
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
           Where-Object { $_.FriendlyName -like '*Virtual Display Driver*' } | Select-Object -First 1
    if (-not $dev) { throw "Virtual Display Driver device not found." }
    Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false
    Start-Sleep -Seconds 3
    Enable-PnpDevice  -InstanceId $dev.InstanceId -Confirm:$false
    Start-Sleep -Seconds 6
}

# ── 2. Attach it ─────────────────────────────────────────────────────────────

$vdd = Find-VddAdapter
if (-not $vdd) { throw "No 'Virtual Display Driver' adapter present." }
Write-Host "Virtual display adapter: $($vdd.Name)"

$offered = $false
for ($i = 0; $i -lt 500; $i++) {
    $dm = New-Object SolDisp+DEVMODE; $dm.dmSize = $szMode
    if (-not [SolDisp]::EnumDisplaySettings($vdd.Name, $i, [ref]$dm)) { break }
    if ($dm.dmPelsWidth -eq $Width -and $dm.dmPelsHeight -eq $Height) { $offered = $true; break }
}
if (-not $offered) { throw "Driver still does not offer ${Width}x${Height}. Reboot and re-run." }

# Park it to the right of everything else so it never overlaps a real monitor's
# coordinates — SolStream addresses windows in virtual-desktop space.
$originX = 0
Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    if ($s.DeviceName -ne $vdd.Name -and $s.Bounds.Right -gt $originX) { $originX = $s.Bounds.Right }
}

$dm = New-Object SolDisp+DEVMODE
$dm.dmSize = $szMode
$dm.dmDeviceName = $vdd.Name
$dm.dmPelsWidth = $Width; $dm.dmPelsHeight = $Height
$dm.dmBitsPerPel = 32; $dm.dmDisplayFrequency = 60
$dm.dmPositionX = $originX; $dm.dmPositionY = 0
# DM_POSITION | DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
$dm.dmFields = 0x20 -bor 0x40000 -bor 0x80000 -bor 0x100000 -bor 0x400000
# CDS_UPDATEREGISTRY | CDS_NORESET. NORESET is 0x10000000 — 0x10000 is not a
# valid flag and fails with DISP_CHANGE_BADFLAGS (-4).
$rc = [SolDisp]::Change($vdd.Name, [ref]$dm, [IntPtr]::Zero, (0x1 -bor 0x10000000), [IntPtr]::Zero)
if ($rc -ne 0) { throw "Staging the display mode failed: DISP_CHANGE $rc" }
$rc = [SolDisp]::ApplyAll([IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
if ($rc -ne 0) { throw "Applying the display config failed: DISP_CHANGE $rc" }
Start-Sleep -Seconds 3
Write-Host "Attached $($vdd.Name) at ${Width}x${Height} @ ${originX},0"

# ── 3. DPI scaling ───────────────────────────────────────────────────────────

$TABLE = @(100,125,150,175,200,225,250,300,350,400,450,500)
if ($TABLE -notcontains $Scale) { throw "Scale must be one of: $($TABLE -join ', ')" }

[uint32]$np = 0; [uint32]$nm = 0
$null = [SolDisp]::GetDisplayConfigBufferSizes(2, [ref]$np, [ref]$nm)   # QDC_ONLY_ACTIVE_PATHS
$paths = New-Object 'SolDisp+PATH[]' $np
$modes = New-Object 'SolDisp+MODE[]' $nm
if ([SolDisp]::QueryDisplayConfig(2, [ref]$np, $paths, [ref]$nm, $modes, [IntPtr]::Zero) -ne 0) {
    throw "QueryDisplayConfig failed."
}
$scaled = $false
for ($i = 0; $i -lt $np; $i++) {
    $a = $paths[$i].sourceInfo.adapterId
    $sid = $paths[$i].sourceInfo.id
    $sn = New-Object SolDisp+SRCNAME
    $sn.type = 1; $sn.size = $szName; $sn.adapLow = $a.LowPart; $sn.adapHigh = $a.HighPart; $sn.id = $sid
    $sn.viewGdiDeviceName = ''
    if ([SolDisp]::DisplayConfigGetDeviceInfo([ref]$sn) -ne 0) { continue }
    if ($sn.viewGdiDeviceName -ne $vdd.Name) { continue }

    $g = New-Object SolDisp+DPIGET
    $g.type = -3; $g.size = $szGet; $g.adapLow = $a.LowPart; $g.adapHigh = $a.HighPart; $g.id = $sid
    if ([SolDisp]::DisplayConfigGetDeviceInfo([ref]$g) -ne 0) { break }
    # Scale values are indices relative to whatever Windows calls "recommended".
    # The minimum absolute step is always 100%, so recommended = -minScaleRel.
    $rec = -$g.minScaleRel
    $target = [array]::IndexOf($TABLE, $Scale)
    if ($target -gt ($rec + $g.maxScaleRel)) { throw "This display cannot scale to ${Scale}%." }
    $s = New-Object SolDisp+DPISET
    $s.type = -4; $s.size = $szSet; $s.adapLow = $a.LowPart; $s.adapHigh = $a.HighPart; $s.id = $sid
    $s.scaleRel = $target - $rec
    if ([SolDisp]::DisplayConfigSetDeviceInfo([ref]$s) -ne 0) { throw "Setting DPI scale failed." }
    Write-Host "Set DPI scaling to ${Scale}% (Windows recommends $($TABLE[$rec])%)"
    $scaled = $true
    break
}
if (-not $scaled) { Write-Warning "Could not set DPI scaling; the display is attached regardless." }

# ── 4. Point Sunshine at it ──────────────────────────────────────────────────

Write-Host ""
Write-Host "Virtual display ready: $($vdd.Name)  ${Width}x${Height} @ ${Scale}%"

if ($ConfigureSunshine) {
    if (-not (Test-Path $SunshineLog)) { throw "No Sunshine log at $SunshineLog." }
    # Sunshine logs a device_id -> display_name map at startup; output_name takes
    # the device id, which is stable across the display-name renumbering that a
    # device restart causes.
    $text = Get-Content $SunshineLog -Raw
    $escaped = $vdd.Name -replace '\\', '\\\\'
    $rx = [regex]::Matches($text, '"device_id":\s*"(\{[^"]+\})",\s*"display_name":\s*"([^"]+)"')
    $id = $null
    foreach ($m in $rx) { if ($m.Groups[2].Value -replace '\\\\', '\' -eq $vdd.Name) { $id = $m.Groups[1].Value } }
    if (-not $id) {
        Write-Warning "Could not find a device id for $($vdd.Name) in Sunshine's log. Restart Sunshine and re-run, or pick 'VDD by MTT' in its web UI."
    } else {
        Copy-Item $SunshineConfig "$SunshineConfig.solstream-backup" -Force -ErrorAction SilentlyContinue
        $conf = [System.IO.File]::ReadAllText($SunshineConfig)
        if ($conf -match '(?m)^output_name\s*=.*$') {
            $conf = [regex]::Replace($conf, '(?m)^output_name\s*=.*$', "output_name = $id")
        } else {
            $conf = $conf.TrimEnd() + "`r`noutput_name = $id`r`n"
        }
        [System.IO.File]::WriteAllText($SunshineConfig, $conf, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "Sunshine output_name = $id  ($($vdd.Name))"
        Restart-Service -Name 'SunshineService' -Force -ErrorAction SilentlyContinue
        Write-Host "Sunshine restarted."
    }
} else {
    Write-Host "Set Sunshine to capture this display (its web UI lists it as 'VDD by MTT'),"
    Write-Host "or re-run with -ConfigureSunshine to do it automatically."
}
