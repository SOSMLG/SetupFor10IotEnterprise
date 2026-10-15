@echo off
rem one click: elevates, runs the full setup (base + study pack), keeps the window open.
rem extra flags pass straight through: Setup.cmd -TweaksOnly / -SkipApps / -NoTweaks ...
cd /d "%~dp0"
fltmc >nul 2>&1
if "%errorlevel%"=="0" goto run
rem probe failed: if we already bounced through uac, the probe is the broken part. run.
if defined WI_ELEVATED goto run
set "WI_ELEVATED=1"
echo need admin, asking...
set "WI_SELF=%~f0"
if "%~1"=="" (
  powershell -NoProfile -Command "Start-Process -FilePath $env:WI_SELF -Verb RunAs"
) else (
  set "WI_ARGS=%*"
  powershell -NoProfile -Command "Start-Process -FilePath $env:WI_SELF -ArgumentList $env:WI_ARGS -Verb RunAs"
)
exit /b
:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-Win-Iot.ps1" -Unattended -IncludeStudy %*
echo.
echo all done. log + report live in C:\Windows\Logs\Win-Iot-Setup
pause
