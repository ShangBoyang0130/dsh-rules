@echo off
REM Double-click entry point. Exists because Windows blocks .ps1 by default,
REM and a beginner should not have to know about ExecutionPolicy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
