@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Desktop startup
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Start-Desktop.ps1" -GlazeCli "%~1"
set "glazewm_startup_result=%errorlevel%"
if not "%glazewm_startup_result%"=="0" (
    echo Startup needs attention. Log: "%~dp0startup.log"
    pause
)
exit /b %glazewm_startup_result%
