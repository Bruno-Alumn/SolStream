; SolStream Windows Installer — Inno Setup
; Requires Inno Setup 6+ (https://jrsoftware.org/isdl.php)
;
; Build: iscc solstream.iss

#define MyAppName "SolStream"
#define MyAppVersion "0.2.0"
#define MyAppPublisher "SolStream Contributors"
#define MyAppURL "https://solstream.nousresearch.com"
#define MyAppExeName "Sunshine.exe"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={localappdata}\SolStream
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\build\installer
OutputBaseFilename=SolStream-{#MyAppVersion}-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
; Sunshine runs as a user-level process (NOT a Windows Service)
; CaptureHelper, ClipboardMonitor, FileTransferService are user-level
; InputInjector is installed as a scheduled task (High Integrity Admin)

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

; ── Files ────────────────────────────────────────────────────────────────────

[Files]
; Sunshine fork (main application)
Source: "..\build\bin\release\Sunshine.exe"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "..\build\bin\release\sunshine.conf"; DestDir: "{app}\bin"; Flags: ignoreversion

; CaptureHelper
Source: "..\build\bin\release\CaptureHelper.exe"; DestDir: "{app}\bin\helpers"; Flags: ignoreversion

; ClipboardMonitor
Source: "..\build\bin\release\ClipboardMonitor.exe"; DestDir: "{app}\bin\helpers"; Flags: ignoreversion

; FileTransferService
Source: "..\build\bin\release\FileTransferService.exe"; DestDir: "{app}\bin\helpers"; Flags: ignoreversion

; InputInjector (installed as scheduled task)
Source: "..\build\bin\release\InputInjector.exe"; DestDir: "{app}\bin\helpers"; Flags: ignoreversion

; Web UI assets
Source: "..\sunshine\web\*"; DestDir: "{app}\web"; Flags: ignoreversion recursesubdirs

; Configuration (default)
Source: "..\config\solstream.default.conf"; DestDir: "{app}\config"; Flags: ignoreversion onlyifdoesntexist

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\bin\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\bin\{#MyAppExeName}"; Tasks: desktopicon

; ── Registry (auto-start) ───────────────────────────────────────────────────

[Registry]
; Add Sunshine to HKCU Run on install
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; \
    ValueType: string; ValueName: "SolStream"; \
    ValueData: "{app}\bin\{#MyAppExeName} --start-minimized"; \
    Flags: uninsdeletevalue

; ── Run (post-install) ──────────────────────────────────────────────────────

[Run]
; Install InputInjector scheduled task
Filename: "{sys}\schtasks.exe"; \
    Parameters: "/create /tn ""SolStream\InputInjector"" /tr ""{app}\bin\helpers\InputInjector.exe"" /ru INTERACTIVE /rp """" /rl HIGHEST /it /sc ONLOGON /delay 0005:00 /f"; \
    Flags: runhidden; \
    StatusMsg: "Installing InputInjector scheduled task..."

; Add firewall rules
Filename: "{sys}\netsh.exe"; \
    Parameters: "advfirewall firewall add rule name=""SolStream - Control"" dir=in action=allow protocol=TCP localport=47989 profile=private"; \
    Flags: runhidden; \
    StatusMsg: "Adding firewall rules..."

Filename: "{sys}\netsh.exe"; \
    Parameters: "advfirewall firewall add rule name=""SolStream - Input UDP"" dir=in action=allow protocol=UDP localport=47990 profile=private"; \
    Flags: runhidden

Filename: "{sys}\netsh.exe"; \
    Parameters: "advfirewall firewall add rule name=""SolStream - Clipboard"" dir=in action=allow protocol=TCP localport=47991 profile=private"; \
    Flags: runhidden

Filename: "{sys}\netsh.exe"; \
    Parameters: "advfirewall firewall add rule name=""SolStream - File Transfer"" dir=in action=allow protocol=TCP localport=47992 profile=private"; \
    Flags: runhidden

Filename: "{sys}\netsh.exe"; \
    Parameters: "advfirewall firewall add rule name=""SolStream - RTP Video"" dir=in action=allow protocol=UDP localport=47998-48010 profile=private"; \
    Flags: runhidden

; Start Sunshine
Filename: "{app}\bin\{#MyAppExeName}"; Flags: nowait; Description: "Start SolStream now"

; ── Uninstall ────────────────────────────────────────────────────────────────

[UninstallRun]
; Stop Sunshine if running
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im Sunshine.exe"; Flags: runhidden; RunOnceId: "KillSunshine"
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im CaptureHelper.exe"; Flags: runhidden
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im ClipboardMonitor.exe"; Flags: runhidden
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im FileTransferService.exe"; Flags: runhidden
Filename: "{sys}\taskkill.exe"; Parameters: "/f /im InputInjector.exe"; Flags: runhidden

; Remove scheduled task
Filename: "{sys}\schtasks.exe"; Parameters: "/delete /tn ""SolStream\InputInjector"" /f"; Flags: runhidden

; Remove firewall rules
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SolStream - Control"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SolStream - Input UDP"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SolStream - Clipboard"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SolStream - File Transfer"""; Flags: runhidden
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""SolStream - RTP Video"""; Flags: runhidden

; ── Code (upgrade handling) ─────────────────────────────────────────────────

[Code]

function InitializeSetup: Boolean;
begin
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  // Stop running SolStream processes before overwriting binaries.
  Exec('taskkill.exe', '/f /im Sunshine.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/f /im CaptureHelper.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/f /im ClipboardMonitor.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/f /im FileTransferService.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('taskkill.exe', '/f /im InputInjector.exe', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  NeedsRestart := False;
  Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ResultCode: Integer;
begin
  if CurStep = ssPostInstall then
  begin
    // Re-install the InputInjector scheduled task (in case it was removed).
    Exec('schtasks.exe', '/create /tn "SolStream\InputInjector" /tr "' +
         ExpandConstant('{app}') + '\bin\helpers\InputInjector.exe" ' +
         '/ru INTERACTIVE /rp "" /rl HIGHEST /it /sc ONLOGON /delay 0005:00 /f',
         '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
