# screenshot-probe.ps1 — photograph the guest's own desktop, from inside it.
#
# Hyper-V's GetVirtualSystemThumbnailImage returns solid black with no VMConnect
# session attached, so it is not a fallback. This has to run in the interactive
# session, and it has to be DPI-aware or it captures a quarter of the screen and
# stretches it.

param(
    [string]$OutputPath = "$env:USERPROFILE\guest-screenshot.png"
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Dpi {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}
"@
[Dpi]::SetProcessDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null

$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
