@echo off
REM install-solstream-firewall.bat — Create Windows Firewall rules for SolStream
REM Scopes rules to private network profile only.
REM Run as Administrator.

setlocal enabledelayedexpansion

echo Installing SolStream Windows Firewall rules...
echo Rules are scoped to PRIVATE networks only.
echo.

REM Check for admin privileges.
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: This script must be run as Administrator.
    exit /b 1
)

REM Define rules: name, port, protocol
set RULES[0].Name=SolStream - Control + Pairing
set RULES[0].Port=47989
set RULES[0].Proto=TCP

set RULES[1].Name=SolStream - Input (UDP)
set RULES[1].Port=47990
set RULES[1].Proto=UDP

set RULES[2].Name=SolStream - Clipboard Sync
set RULES[2].Port=47991
set RULES[2].Proto=TCP

set RULES[3].Name=SolStream - File Transfer
set RULES[3].Port=47992
set RULES[3].Proto=TCP

set RULES[4].Name=SolStream - RTP Video (UDP)
set RULES[4].Port=47998-48010
set RULES[4].Proto=UDP

set COUNT=5

for /L %%i in (0,1,4) do (
    for /f "tokens=1,2 delims==" %%a in ('set RULES[%%i]') do (
        set /a done%%i=0
    )
)

for /L %%i in (0,1,4) do (
    call :InstallRule %%i
)

echo.
echo Firewall rules installed successfully.
echo Rules are active on PRIVATE networks only.
echo.
echo To remove: run as Administrator and execute:
echo   netsh advfirewall firewall delete rule name="SolStream - Control + Pairing"
echo   netsh advfirewall firewall delete rule name="SolStream - Input (UDP)"
echo   ... (repeat for all 5 rules)
echo.
endlocal
exit /b 0

:InstallRule
setlocal
set IDX=%1

set RULE_NAME=SolStream - 
if %IDX%==0 set RULE_NAME=SolStream - Control + Pairing
if %IDX%==1 set RULE_NAME=SolStream - Input (UDP)
if %IDX%==2 set RULE_NAME=SolStream - Clipboard Sync
if %IDX%==3 set RULE_NAME=SolStream - File Transfer
if %IDX%==4 set RULE_NAME=SolStream - RTP Video (UDP)

set PORT=0
if %IDX%==0 set PORT=47989
if %IDX%==1 set PORT=47990
if %IDX%==2 set PORT=47991
if %IDX%==3 set PORT=47992
if %IDX%==4 set PORT=47998-48010

set PROTO=TCP
if %IDX%==1 set PROTO=UDP
if %IDX%==4 set PROTO=UDP

echo   Installing: !RULE_NAME! (Port !PORT!, !PROTO!)

netsh advfirewall firewall add rule ^
    name="!RULE_NAME!" ^
    dir=in ^
    action=allow ^
    protocol=!PROTO! ^
    localport=!PORT! ^
    profile=private ^
    description="SolStream remote application streaming - !RULE_NAME!" >nul 2>&1

if !errorlevel! equ 0 (
    echo     OK
) else (
    echo     WARNING: Rule may already exist or failed. Continuing...
)
endlocal
goto :EOF
