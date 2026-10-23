@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "glazewm_startup_log=%~dp0startup.log"
set "glazewm_startup_cli=%~1"
rem Keep one output handle open while the CLI spawns its child processes.
call :launch >>"%glazewm_startup_log%" 2>&1
exit /b %errorlevel%

:launch
echo [%date% %time%] Startup launcher invoked.
if not defined glazewm_startup_cli (
    echo ERROR: No GlazeWM CLI path was provided.
    exit /b 2
)
if not exist "%glazewm_startup_cli%" (
    echo ERROR: GlazeWM CLI not found: "%glazewm_startup_cli%"
    exit /b 2
)
"%glazewm_startup_cli%" query monitors >nul 2>&1
if not errorlevel 1 (
    echo [%date% %time%] GlazeWM already running; skipping launch.
    exit /b 0
)
echo Launching: "%glazewm_startup_cli%" start
"%glazewm_startup_cli%" start
set "glazewm_startup_result=%errorlevel%"
echo [%date% %time%] CLI exit code: %glazewm_startup_result%. Dispatch success does not confirm GlazeWM readiness.
exit /b %glazewm_startup_result%
