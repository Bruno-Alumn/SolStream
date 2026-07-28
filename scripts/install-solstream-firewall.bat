@echo off
REM install-solstream-firewall.bat - Windows Firewall rules for SolStream
REM Run as Administrator.
REM
REM SECONDARY. `SolStream.exe --install` already does all of this, correctly,
REM before anything has listened, and that is the path a real install takes.
REM This script exists for a machine running SolStream without having been
REM installed -- a development box, or one where the rules were removed.
REM
REM It had drifted badly by the time anyone ran it: it still opened the old
REM 47984-48010 block and named the agent as 47997, none of which anything has
REM listened on since the ports moved to base 47600. Two scripts configuring the
REM same firewall is how that happened. If these ever disagree with
REM `SolStream.exe --install` again, the executable is right.
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
echo.

REM Find the two executables. The installed layout puts both under one root, but
REM the case this script exists for does not: on a development machine the agent
REM runs out of a build tree and Sunshine is wherever it was installed, so no
REM single directory names them both. Ask the running processes rather than
REM guessing, and fall back to the install layout when nothing is running.
set AGENTEXE=
set SUNEXE=

call :Running SolStreamAgent AGENTEXE
call :Running sunshine       SUNEXE

if "!AGENTEXE!"=="" if exist "!INSTALLDIR!\SolStream.exe"          set AGENTEXE=!INSTALLDIR!\SolStream.exe
if "!AGENTEXE!"=="" if exist "!INSTALLDIR!\SolStreamAgent.exe"     set AGENTEXE=!INSTALLDIR!\SolStreamAgent.exe
if "!SUNEXE!"==""   if exist "!INSTALLDIR!\sunshine\sunshine.exe"  set SUNEXE=!INSTALLDIR!\sunshine\sunshine.exe

echo   agent:    !AGENTEXE!
echo   sunshine: !SUNEXE!
echo.

REM Profile scope. Tailscale's adapter is not reliably categorised as Private on
REM Windows, and a private-only rule silently blocks everything arriving over it
REM -- which looks exactly like the agent not running. private+public covers both;
REM the agent still requires its token, and Sunshine still requires pairing.
set PROFILE=private,public

echo Programs:
call :Program "SolStream - Agent (program)"    "!AGENTEXE!"
call :Program "SolStream - Sunshine (program)" "!SUNEXE!"

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

REM Ask Windows where a running process's image actually is, so the rule names
REM the file that will be listening rather than the file somebody expected.
REM
REM No pipe in the PowerShell. Inside for /f's backticks a `|` has to be written
REM `^|`, and the caret is then handed to PowerShell literally -- "a positional
REM parameter cannot be found that accepts argument '^'" -- so the lookup fails
REM and the rule is silently skipped. A foreach avoids the question.
REM
REM And not simply the first match either. There can be several processes of one
REM name -- a machine with its own Sunshine service has that one and SolStream's
REM child both running -- and Path comes back empty for any whose image this
REM session cannot read. Taking [0] therefore skipped the Sunshine rule while
REM cheerfully creating the agent's. Walk them and keep the first that answers.
:Running
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$found = ''; foreach ($q in @(Get-Process -Name '%~1' -ErrorAction SilentlyContinue)) { if (-not $found) { try { if ($q.Path) { $found = $q.Path } } catch { } } }; $found"`) do set %~2=%%P
goto :EOF

:Program
set NAME=%~1
set EXE=%~2

echo   %NAME%

if "%EXE%"=="" (
    echo     SKIPPED - could not find the executable. Start it, or pass the
    echo               install directory as the first argument to this script.
    goto :EOF
)
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
