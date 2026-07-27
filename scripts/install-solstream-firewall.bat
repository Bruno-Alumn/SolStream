@echo off
REM install-solstream-firewall.bat - Windows Firewall rules for SolStream
REM Run as Administrator.
REM
REM These are the ports the current architecture actually uses: Sunshine for the
REM stream, plus the SolStream agent. An earlier version of this script opened
REM 47991 and 47992 for a bespoke clipboard and file-transfer daemon that is no
REM longer part of the connection, and never opened 47997 at all -- which is the
REM agent, the one port without which the Mac cannot list windows, place them or
REM pair. It also opened Sunshine's web UI as UDP rather than TCP.

setlocal enabledelayedexpansion

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator.
    exit /b 1
)

echo Installing SolStream Windows Firewall rules...
echo.

REM Profile scope. Tailscale's adapter is not reliably categorised as Private on
REM Windows, and a private-only rule silently blocks everything arriving over it
REM -- which looks exactly like the agent not running. private+public covers both;
REM the agent still requires its token, and Sunshine still requires pairing.
set PROFILE=private,public

call :Rule "SolStream - Agent"            47997       TCP
call :Rule "SolStream - Sunshine HTTPS"   47984       TCP
call :Rule "SolStream - Sunshine HTTP"    47989       TCP
call :Rule "SolStream - Sunshine Web UI"  47990       TCP
call :Rule "SolStream - Sunshine RTSP"    48010       TCP
call :Rule "SolStream - Stream Media"     47998-48000 UDP

echo.
echo Done. Rules are active on: %PROFILE%
echo.
echo To remove them, run as Administrator:
echo   netsh advfirewall firewall delete rule name="SolStream - Agent"
echo   netsh advfirewall firewall delete rule name="SolStream - Sunshine HTTPS"
echo   netsh advfirewall firewall delete rule name="SolStream - Sunshine HTTP"
echo   netsh advfirewall firewall delete rule name="SolStream - Sunshine Web UI"
echo   netsh advfirewall firewall delete rule name="SolStream - Sunshine RTSP"
echo   netsh advfirewall firewall delete rule name="SolStream - Stream Media"
echo.
endlocal
exit /b 0

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
