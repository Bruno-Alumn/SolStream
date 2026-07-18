@echo off
REM install-inputinjector-task.bat — Install InputInjector as a scheduled task
REM Runs at user logon with highest privileges (High Integrity Admin)
REM in the interactive session (not Session 0).
REM
REM Usage: install-inputinjector-task.bat [path-to-InputInjector.exe]

setlocal enabledelayedexpansion

set INJECTOR_PATH=%~1
if "%INJECTOR_PATH%"=="" set INJECTOR_PATH=%~dp0..\build\bin\release\InputInjector.exe

echo Installing SolStream InputInjector scheduled task...
echo Binary path: %INJECTOR_PATH%

if not exist "%INJECTOR_PATH%" (
    echo ERROR: InputInjector.exe not found at %INJECTOR_PATH%
    exit /b 1
)

REM Remove existing task if present.
schtasks /query /tn "SolStream\InputInjector" >nul 2>&1
if !errorlevel! equ 0 (
    echo Removing existing task...
    schtasks /delete /tn "SolStream\InputInjector" /f
)

REM Create the task.
REM Key settings:
REM   /ru INTERACTIVE — runs in the user's interactive session (not Session 0)
REM   /rp "" — no password for INTERACTIVE group
REM   /rl HIGHEST — highest available privileges (High Integrity)
REM   /it — run only when user is logged on
REM   /delay 0005:00 — wait 5 minutes after logon to avoid startup contention

schtasks /create ^
    /tn "SolStream\InputInjector" ^
    /tr "!INJECTOR_PATH!" ^
    /ru INTERACTIVE ^
    /rp "" ^
    /rl HIGHEST ^
    /it ^
    /sc ONLOGON ^
    /delay 0005:00 ^
    /f

if !errorlevel! equ 0 (
    echo.
    echo SUCCESS: InputInjector task installed.
    echo The task will run 5 minutes after user logon.
    echo To start immediately: schtasks /run /tn "SolStream\InputInjector"
) else (
    echo.
    echo ERROR: Failed to create scheduled task (error !errorlevel!).
    echo Try running this script as Administrator.
    exit /b 1
)

endlocal
