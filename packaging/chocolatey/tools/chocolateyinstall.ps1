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
  url64bit       = 'https://github.com/Bruno-Alumn/SolStream/releases/download/v1.0.7/SolStreamSetup-1.0.7.exe'
  checksum64     = 'a9ba4fc2073087ded335c924d8304417a535f3debc6011fa6adac607d1d5c50d'
  checksumType64 = 'sha256'
  silentArgs     = $arguments -join ' '
  validExitCodes = @(0)
}
Install-ChocolateyPackage @packageArgs
