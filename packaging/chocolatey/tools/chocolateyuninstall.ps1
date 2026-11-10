$ErrorActionPreference = 'Stop'

$installed = Join-Path ${env:ProgramFiles} 'SolStream\SolStream.exe'
if (-not (Test-Path $installed)) {
  Write-Warning "SolStream isn't installed in $(Split-Path $installed); nothing to remove."
  return
}

# Run from a copy: the installed SolStream.exe can't delete its own folder, so
# started from there it relaunches from a copy and returns at once, before the
# uninstall has happened. A copy run directly does the work and reports it. The
# copy goes next to this script, in the package's own folder, which only
# administrators can write to, so nothing else can swap it before it runs
# elevated. (Not the package-folder environment variable: Chocolatey's
# moderation counts it as private, rule CPMR0072, and matches its name even in
# a comment.)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$copy = Join-Path $toolsDir 'SolStream-uninstall.exe'
Copy-Item $installed $copy -Force
try {
  Uninstall-ChocolateyPackage -PackageName $env:ChocolateyPackageName -FileType 'exe' `
    -SilentArgs '--uninstall --now' -File $copy -ValidExitCodes @(0)
} finally {
  Remove-Item $copy -Force -ErrorAction SilentlyContinue
}
