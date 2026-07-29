# window-restore-probe.ps1 — did the streamed application survive, and did its
# window come back?
#
# Closing a stream window must end the stream and leave the application running
# on the PC. The agent parks a managed window on the virtual capture display,
# strips its resize border and pins it topmost, so "still running" is not enough:
# a window left at those coordinates is on a monitor nobody can see, and one left
# without WS_THICKFRAME cannot be resized ever again.

# AGAINST A BASELINE, NOT AGAINST AN ASSUMPTION. The first version of this
# asserted that a restored window must have WS_THICKFRAME and WS_MAXIMIZEBOX,
# and reported FAIL for Character Map — which is a fixed-size dialog and has
# never had either. Run with -Capture before streaming to record what the window
# looked like untouched, then again afterwards to compare. What matters is that
# nothing CHANGED, and only the window itself can say what it started as.

param(
    [string]$Process = "charmap",
    [string]$Title = "Character Map",
    [int]$VirtualDisplayLeft = 2560,
    [switch]$Capture,
    [string]$BaselinePath = "$env:USERPROFILE\window-baseline.txt",
    [string]$OutputPath = "$env:USERPROFILE\window-restore.txt"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Restore {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")]
    public static extern int GetWindowLongW(IntPtr h, int index);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$GWL_STYLE = -16
$GWL_EXSTYLE = -20
$WS_THICKFRAME = 0x00040000
$WS_MAXIMIZEBOX = 0x00010000
$WS_EX_TOPMOST = 0x00000008

$out = New-Object System.Collections.Generic.List[string]
$fail = $false

$proc = Get-Process $Process -ErrorAction SilentlyContinue
if ($proc) {
    $out.Add("application running: yes (pid $($proc.Id))")
} else {
    $out.Add("application running: NO - closing the stream killed the app")
    $fail = $true
}

$handle = [Restore]::FindWindowW([NullString]::Value, $Title)
if ($handle -eq [IntPtr]::Zero) {
    $out.Add("window '$Title': not found")
    $fail = $true
} else {
    $r = New-Object Restore+RECT
    [Restore]::GetWindowRect($handle, [ref]$r) | Out-Null
    $out.Add("window at $($r.Left),$($r.Top) size $($r.Right - $r.Left)x$($r.Bottom - $r.Top)")

    if ($r.Left -ge $VirtualDisplayLeft) {
        $out.Add("position: STRANDED on the virtual capture display")
        $fail = $true
    } else {
        $out.Add("position: back on a real monitor")
    }

    $style = [Restore]::GetWindowLongW($handle, $GWL_STYLE)
    $ex = [Restore]::GetWindowLongW($handle, $GWL_EXSTYLE)
    $out.Add("thickframe: $([bool]($style -band $WS_THICKFRAME))  maximisebox: $([bool]($style -band $WS_MAXIMIZEBOX))")

    # Topmost is the one thing that is absolute: the agent only ever ADDS it to
    # a window that was not already in that band, and a window left pinned above
    # everything with no visible cause is the worst thing to leave behind.
    if ($ex -band $WS_EX_TOPMOST) {
        $out.Add("topmost: STILL PINNED above everything")
        $fail = $true
    } else {
        $out.Add("topmost: cleared")
    }

    $fingerprint = "$($r.Left),$($r.Top),$($r.Right - $r.Left),$($r.Bottom - $r.Top),$style,$ex"
    if ($Capture) {
        $fingerprint | Set-Content $BaselinePath -Encoding ASCII
        $out.Add("baseline captured: $fingerprint")
        $out.Add("RESULT: BASELINE - run again without -Capture after streaming")
        $out -join "`r`n" | Set-Content $OutputPath -Encoding ASCII
        exit 0
    }
    if (Test-Path $BaselinePath) {
        $baseline = (Get-Content $BaselinePath -Raw).Trim()
        if ($baseline -eq $fingerprint) {
            $out.Add("baseline: identical ($fingerprint)")
        } else {
            $out.Add("baseline: CHANGED")
            $out.Add("  before: $baseline")
            $out.Add("  after:  $fingerprint")
            $fail = $true
        }
    } else {
        $out.Add("baseline: none recorded, so position and style are unchecked")
    }
}

$out.Add($(if ($fail) { "RESULT: FAIL" } else { "RESULT: PASS" }))
$out -join "`r`n" | Set-Content $OutputPath -Encoding ASCII
