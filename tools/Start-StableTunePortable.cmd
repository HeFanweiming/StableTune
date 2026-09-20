@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
if exist "%ROOT%bin\StableTune.exe" goto launch

set "ROOT=%~dp0..\"
if exist "%ROOT%bin\StableTune.exe" goto launch

echo.
echo [StableTune] Program file not found.
echo Checked:
echo   %~dp0bin\StableTune.exe
echo   %~dp0..\bin\StableTune.exe
echo.
pause
exit /b 2

:launch
set "APP=%ROOT%bin\StableTune.exe"
if "%~1"=="" goto background

"%APP%" %*
set "EXIT_CODE=%ERRORLEVEL%"
exit /b %EXIT_CODE%

:background
start "" /D "%ROOT%" "%APP%"
exit /b 0
