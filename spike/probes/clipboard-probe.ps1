# clipboard-probe.ps1 — what is on the host's clipboard, from the session that
# actually has one.
#
# An SSH session lands in session 0, which has its own clipboard that nothing
# the user can see ever touches. Reading it would report an empty string however
# well the sync worked, so this has to run from an interactive scheduled task.

param(
    [string]$OutputPath = "$env:USERPROFILE\clipboard-probe.txt"
)

Add-Type -AssemblyName System.Windows.Forms
$text = [System.Windows.Forms.Clipboard]::GetText()
$report = "length={0} head={1}" -f $text.Length,
          ($text.Substring(0, [Math]::Min(40, $text.Length)))
$report | Set-Content -Path $OutputPath -Encoding ASCII
