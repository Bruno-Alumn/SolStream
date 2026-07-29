# token-selection-probe.ps1 — does a selection in the token field survive?
#
# The user's complaint was "I can't select the text as it deselects every time
# it flickers". That is a temporal symptom, so a screenshot cannot show it and
# cannot show it fixed either. This selects the whole token, waits several
# seconds — long past the once-a-second repaint timer and any status update —
# and asks the control what is still selected.
#
# Before the fix: SetWindowText ran on every status update with the same text,
# and SetWindowText on an EDIT resets the selection, so this comes back 0,0.
# After: the selection is still 0..len.

param(
    [string]$Title = "SolStream",
    [int]$WaitSeconds = 5,
    [string]$OutputPath = "$env:USERPROFILE\token-selection.txt"
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Sel {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wParam, IntPtr lParam);
    // WM_GETTEXT, not GetWindowText: GetWindowText refuses to read a control
    // owned by ANOTHER process and returns an empty string rather than an error,
    // which made this probe report a length of nought and call a passing run a
    // failure. WM_GETTEXT is marshalled across the boundary for standard
    // controls and is the only thing that works from outside.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr wParam, StringBuilder lParam);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$EM_SETSEL = 0x00B1
$EM_GETSEL = 0x00B0
$WM_GETTEXT = 0x000D

$report = New-Object System.Collections.Generic.List[string]

$window = [Sel]::FindWindowW([NullString]::Value, $Title)
if ($window -eq [IntPtr]::Zero) {
    "no window titled '$Title'" | Set-Content $OutputPath -Encoding ASCII
    exit 1
}
$edit = [Sel]::FindWindowExW($window, [IntPtr]::Zero, "EDIT", [NullString]::Value)
if ($edit -eq [IntPtr]::Zero) {
    "window found but it has no EDIT child (is a Mac connected? the field hides then)" |
        Set-Content $OutputPath -Encoding ASCII
    exit 1
}

$text = New-Object System.Text.StringBuilder 256
[Sel]::SendMessageW($edit, $WM_GETTEXT, [IntPtr]256, $text) | Out-Null
$len = $text.Length
$report.Add("token length: $len")

# Where the field is, so a move during the wait is visible too: the old code
# called SetWindowPos on every paint whether or not anything had moved.
$before = New-Object Sel+RECT
[Sel]::GetWindowRect($edit, [ref]$before) | Out-Null

[Sel]::SendMessageW($edit, $EM_SETSEL, [IntPtr]0, [IntPtr](-1)) | Out-Null
$packed = [Sel]::SendMessageW($edit, $EM_GETSEL, [IntPtr]::Zero, [IntPtr]::Zero)
$startNow = [int]($packed.ToInt64() -band 0xFFFF)
$endNow = [int](($packed.ToInt64() -shr 16) -band 0xFFFF)
$report.Add("selection immediately after selecting: $startNow..$endNow")

Start-Sleep -Seconds $WaitSeconds

$packed = [Sel]::SendMessageW($edit, $EM_GETSEL, [IntPtr]::Zero, [IntPtr]::Zero)
$start = [int]($packed.ToInt64() -band 0xFFFF)
$end = [int](($packed.ToInt64() -shr 16) -band 0xFFFF)
$report.Add("selection after ${WaitSeconds}s: $start..$end")

$after = New-Object Sel+RECT
[Sel]::GetWindowRect($edit, [ref]$after) | Out-Null
$moved = ($before.Left -ne $after.Left) -or ($before.Top -ne $after.Top) -or
         ($before.Right -ne $after.Right) -or ($before.Bottom -ne $after.Bottom)
$report.Add("field moved during the wait: $moved")

if ($end -gt $start -and $end -eq $len) {
    $report.Add("RESULT: PASS - the whole token is still selected")
} else {
    $report.Add("RESULT: FAIL - the selection was lost")
}

$report -join "`r`n" | Set-Content $OutputPath -Encoding ASCII
