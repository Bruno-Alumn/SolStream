# cursor-probe.ps1 — where is the host's pointer, from the session that has one?
#
# An SSH session on this machine lands in session 0, which has a phantom desktop:
# its cursor position is not the real one and never moves. So this has to run
# from an INTERACTIVE scheduled task (schtasks /it), and it writes to a file
# because there is nowhere else for it to be read from.
#
#   cursor-probe.ps1 [samples] [intervalMs] [outputPath]

param(
    [int]$Samples = 100,
    [int]$IntervalMs = 200,
    [string]$OutputPath = "$env:USERPROFILE\cursor-probe.txt"
)

Add-Type -AssemblyName System.Windows.Forms
$lines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $Samples; $i++) {
    $p = [System.Windows.Forms.Cursor]::Position
    $lines.Add(("{0},{1}" -f $p.X, $p.Y))
    Start-Sleep -Milliseconds $IntervalMs
}
$lines | Set-Content -Path $OutputPath -Encoding ASCII
