@echo off
setlocal EnableExtensions

set "APP=%~dp0bin\StableTune.exe"

if not exist "%APP%" (
    echo.
    echo [稳优 StableTune] Program file not found:
    echo %APP%
    echo.
    pause
    exit /b 2
)

start "" "%APP%"
exit /b 0
