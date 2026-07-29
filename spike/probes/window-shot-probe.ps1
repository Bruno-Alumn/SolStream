# window-shot-probe.ps1 — photograph ONE window, brought to the front first.
#
# A full-desktop capture is at the mercy of whatever else is on screen: the first
# attempt at this photographed the Start menu sitting over the window it was
# meant to be looking at, and the visible sliver was ambiguous enough to argue
# about. Focusing the window first removes the argument.

param(
    [string]$Title = "SolStream",
    [string]$OutputPath = "$env:USERPROFILE\window-shot.png"
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
[Win]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null

# Escape first. A scheduled task cannot take the foreground, so if the Start menu
# is open the capture photographs THAT and whatever is beside it -- which is how
# three runs of this produced the same ambiguous sliver. keybd_event injects into
# whatever holds the foreground, which is exactly the thing that needs dismissing.
[Win]::keybd_event(0x1B, 0, 0, [IntPtr]::Zero)
[Win]::keybd_event(0x1B, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 600

# FindWindowW needs a real null for "any class"; PowerShell marshals $null as an
# empty string, which matches nothing at all.
$handle = [Win]::FindWindowW([NullString]::Value, $Title)
if ($handle -eq [IntPtr]::Zero) {
    "no window titled '$Title'" | Set-Content "$env:USERPROFILE\window-shot.txt" -Encoding ASCII
    exit 1
}
[Win]::ShowWindow($handle, 9) | Out-Null      # SW_RESTORE
[Win]::SetForegroundWindow($handle) | Out-Null
Start-Sleep -Milliseconds 900

$r = New-Object Win+RECT
[Win]::GetWindowRect($handle, [ref]$r) | Out-Null
$w = $r.Right - $r.Left
$h = $r.Bottom - $r.Top
$bitmap = New-Object System.Drawing.Bitmap $w, $h
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
$bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
"window at $($r.Left),$($r.Top) ${w}x${h}" | Set-Content "$env:USERPROFILE\window-shot.txt" -Encoding ASCII
