$ErrorActionPreference = 'Stop'

# The setup is SolStream itself: --install does the install without a window,
# and Chocolatey runs it elevated, so there is no UAC prompt either.
$pp = Get-PackageParameters
$arguments = @('--install')
# The virtual display only when asked for: installing the driver makes Windows
# ask whether to trust its publisher, which an unattended install can't answer.
if ($pp['DisplayDriver']) { $arguments += '--with-display-driver' }
if ($pp['NoDesktopShortcut']) { $arguments += '--no-desktop-shortcut' }
if ($pp['NoStartMenu']) { $arguments += '--no-start-menu' }
if ($pp['NoLogon']) { $arguments += '--no-logon' }

$packageArgs = @{
  packageName    = $env:ChocolateyPackageName
  fileType       = 'exe'
  url64bit       = 'https://github.com/Bruno-Alumn/SolStream/releases/download/v2.0.1/SolStreamSetup-2.0.1.exe'
  checksum64     = 'f9a64a47cbf29df21c91e05d050badd85a452a6cd391d49de481221eebbfa2e4'
  checksumType64 = 'sha256'
  silentArgs     = $arguments -join ' '
  validExitCodes = @(0)
}
Install-ChocolateyPackage @packageArgs
