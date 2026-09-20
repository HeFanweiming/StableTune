@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0StableTune.ps1"
set "PWSH="

fltmc.exe >nul 2>&1
if errorlevel 1 (
    echo.
    echo [StableTune] Requesting administrator privileges...
    set "FELIX_LAUNCHER=%~f0"
    set "FELIX_LAUNCH_ARGS=%*"
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "try { if ([string]::IsNullOrWhiteSpace($env:FELIX_LAUNCH_ARGS)) { Start-Process -FilePath $env:FELIX_LAUNCHER -Verb RunAs -ErrorAction Stop } else { Start-Process -FilePath $env:FELIX_LAUNCHER -ArgumentList $env:FELIX_LAUNCH_ARGS -Verb RunAs -ErrorAction Stop } } catch { Write-Host '[StableTune] Administrator launch was cancelled or failed.'; Write-Host $_.Exception.Message; exit 1 }"
    if errorlevel 1 (
        echo.
        echo [StableTune] Administrator privileges were not granted.
        pause
        exit /b 5
    )
    exit /b 0
)

for /f "delims=" %%I in ('where pwsh.exe 2^>nul') do (
    if not defined PWSH set "PWSH=%%I"
)

if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Programs\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe" set "PWSH=%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"
if not defined PWSH if exist "%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe" set "PWSH=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"

if not exist "%SCRIPT%" (
    echo.
    echo [StableTune] Main script not found:
    echo %SCRIPT%
    echo.
    pause
    exit /b 2
)

if not defined PWSH (
    echo.
    echo [StableTune] PowerShell 7 was not found.
    echo.
    echo Install PowerShell 7 with:
    echo   winget install --id Microsoft.PowerShell --source winget
    echo.
    echo Close this window, then double-click this launcher again.
    echo.
    pause
    exit /b 1
)

set "IS_ADMIN=No"
fltmc.exe >nul 2>&1 && set "IS_ADMIN=Yes"
if "%IS_ADMIN%"=="No" (
    echo [StableTune] Administrator privileges are required to open the program.
    pause
    exit /b 5
)

echo [StableTune] Using PowerShell 7:
echo %PWSH%
echo.

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo [StableTune] The program exited with code %EXIT_CODE%.
    echo Keep this window open and capture the error message for diagnosis.
    echo.
    pause
)

exit /b %EXIT_CODE%
