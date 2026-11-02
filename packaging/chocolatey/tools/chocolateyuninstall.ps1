$ErrorActionPreference = 'Stop'

$installed = Join-Path ${env:ProgramFiles} 'SolStream\SolStream.exe'
if (-not (Test-Path $installed)) {
  Write-Warning "SolStream isn't installed in $(Split-Path $installed); nothing to remove."
  return
}

# Run from a copy: the installed SolStream.exe can't delete its own folder, so
# started from there it relaunches from a copy and returns at once, before the
# uninstall has happened. A copy run directly does the work and reports it.
$copy = Join-Path $env:TEMP "SolStream-uninstall-$([guid]::NewGuid()).exe"
Copy-Item $installed $copy
try {
  $process = Start-Process -FilePath $copy -ArgumentList '--uninstall', '--now' -Wait -PassThru -NoNewWindow
  if ($process.ExitCode -ne 0) {
    throw "SolStream's uninstall failed (exit code $($process.ExitCode)). Its log is in $env:ProgramData\SolStream."
  }
} finally {
  Remove-Item $copy -Force -ErrorAction SilentlyContinue
}
