@echo off
REM install-solstream-firewall.bat - Windows Firewall rules for SolStream
REM Run as Administrator.
REM
REM SECONDARY. install-windows.ps1 already does all of this, correctly, before
REM anything has listened, and that is the path a real install takes. This script
REM exists for a machine running SolStream without having been installed -- a
REM development box, or one where the rules were removed -- and for nothing else.
REM
REM It had drifted badly by the time anyone ran it: it still opened the old
REM 47984-48010 block and named the agent as 47997, none of which anything has
REM listened on since the ports moved to base 47600. Two scripts configuring the
REM same firewall is how that happened. If these ever disagree with
REM install-windows.ps1 again, install-windows.ps1 is right.
REM
REM Two kinds of rule, and both are needed.
REM
REM PROGRAM rules are what stop Windows asking. When a program starts listening
REM and no rule names that executable, Windows raises "Do you want to allow
REM public and private networks to access this app?" and blocks it until someone
REM answers. On this project that prompt landed on the virtual display -- which
REM has no monitor -- so nobody could see it, and its system-modal dimmer ate
REM every click aimed at the streamed application for days. Naming the two
REM executables up front means the question is never asked.
REM
REM PORT rules cover the traffic itself, including the UDP media ports, which are
REM bound by Sunshine's child processes rather than by sunshine.exe directly.
REM
REM The ports come from windows\SolStreamAgent\ports.h. SolStream runs its own
REM Sunshine on base 47600, deliberately clear of Sunshine's default 47989, so a
REM machine that already had Sunshine keeps it. Everything else is that base plus
REM a fixed GameStream offset:
REM
REM     https  base - 5    47595      video    base + 9   47609
REM     http   base + 0    47600      control  base + 10  47610
REM     web UI base + 1    47601      audio    base + 11  47611
REM     rtsp   base + 21   47621
REM
REM The agent sits outside that block entirely, on 47630.

setlocal enabledelayedexpansion

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator.
    exit /b 1
)

if "%~1"=="" (
    set INSTALLDIR=%ProgramFiles%\SolStream
) else (
    set INSTALLDIR=%~1
)

echo Installing SolStream Windows Firewall rules...
echo   install directory: !INSTALLDIR!
echo.

REM Profile scope. Tailscale's adapter is not reliably categorised as Private on
REM Windows, and a private-only rule silently blocks everything arriving over it
REM -- which looks exactly like the agent not running. private+public covers both;
REM the agent still requires its token, and Sunshine still requires pairing.
set PROFILE=private,public

echo Programs:
call :Program "SolStream - Agent (program)"    "!INSTALLDIR!\SolStreamAgent.exe"
call :Program "SolStream - Sunshine (program)" "!INSTALLDIR!\sunshine\sunshine.exe"

echo.
echo Ports:
call :Rule "SolStream - Agent"            47630       TCP
call :Rule "SolStream - Sunshine HTTPS"   47595       TCP
call :Rule "SolStream - Sunshine HTTP"    47600       TCP
call :Rule "SolStream - Sunshine Web UI"  47601       TCP
call :Rule "SolStream - Sunshine RTSP"    47621       TCP
call :Rule "SolStream - Stream Media"     47609-47611 UDP

echo.
echo Done. Rules are active on: %PROFILE%
echo.
echo To remove them, run as Administrator:
echo   for %%%%N in ("SolStream - Agent (program)" "SolStream - Sunshine (program)"
echo                 "SolStream - Agent" "SolStream - Sunshine HTTPS"
echo                 "SolStream - Sunshine HTTP" "SolStream - Sunshine Web UI"
echo                 "SolStream - Sunshine RTSP" "SolStream - Stream Media") do ^
echo       netsh advfirewall firewall delete rule name=%%%%~N
echo.
endlocal
exit /b 0

:Program
set NAME=%~1
set EXE=%~2

echo   %NAME%

if not exist "%EXE%" (
    echo     SKIPPED - not found at %EXE%
    goto :EOF
)

REM Replace rather than skip: an install that moved leaves a rule naming a path
REM that no longer exists, which allows nothing and hides the fact.
netsh advfirewall firewall delete rule name="%NAME%" >nul 2>&1

netsh advfirewall firewall add rule ^
    name="%NAME%" ^
    dir=in ^
    action=allow ^
    program="%EXE%" ^
    profile=%PROFILE% ^
    description="SolStream remote application streaming" >nul 2>&1

if !errorlevel! equ 0 (
    echo     OK
) else (
    echo     FAILED - check that this shell is elevated
)
goto :EOF

:Rule
set NAME=%~1
set PORT=%~2
set PROTO=%~3

echo   %NAME% (%PROTO% %PORT%)

REM Replace rather than skip: a rule left over from an earlier install may name
REM the right port with the wrong protocol, and "add" would leave both in place.
netsh advfirewall firewall delete rule name="%NAME%" >nul 2>&1

netsh advfirewall firewall add rule ^
    name="%NAME%" ^
    dir=in ^
    action=allow ^
    protocol=%PROTO% ^
    localport=%PORT% ^
    profile=%PROFILE% ^
    description="SolStream remote application streaming" >nul 2>&1

if !errorlevel! equ 0 (
    echo     OK
) else (
    echo     FAILED - check that this shell is elevated
)
goto :EOF
