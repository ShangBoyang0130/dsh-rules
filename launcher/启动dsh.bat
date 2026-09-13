@echo off
setlocal
set "WS=__WORKSPACE__"
set "PORT=3080"
set "URL=http://127.0.0.1:%PORT%"
set "APP=%~dp0DeepSeek Harness.lnk"
set "LOG=%WS%\_dsh-web.log"

if not exist "%WS%\" (
  echo [x] Workspace not found: %WS%
  pause
  exit /b 1
)

where dsh >nul 2>nul
if errorlevel 1 (
  echo [x] "dsh" not found in PATH. Check Node.js and the npm global bin directory.
  pause
  exit /b 1
)

netstat -ano | findstr /c:"127.0.0.1:%PORT%" | findstr /i "LISTENING" >nul
if not errorlevel 1 (
  echo [i] Server already running on port %PORT%.
  goto :open
)

echo [i] Workspace : %WS%
echo [i] Starting the server on port %PORT% ...
echo     First start after a reboot is the slowest; please wait.
start "dsh web" /min /d "%WS%" cmd /c "dsh web --port %PORT% --no-open > %LOG% 2>&1"

set /a n=0
:wait
>nul ping -n 2 127.0.0.1
netstat -ano | findstr /c:"127.0.0.1:%PORT%" | findstr /i "LISTENING" >nul
if not errorlevel 1 goto :ready
set /a n+=1
if %n%==10 echo     ... still waiting, %n%s
if %n%==30 echo     ... still waiting, %n%s
if %n%==60 echo     ... still waiting, %n%s
if %n%==90 echo     ... still waiting, %n%s
if %n% lss 120 goto :wait

echo [x] Gave up after %n%s waiting for port %PORT%.
echo     Server output was written to:
echo     %LOG%
echo     Check the minimized "dsh web" window too.
pause
exit /b 1

:ready
echo [i] Server ready in about %n%s. Opening the app window.
>nul ping -n 2 127.0.0.1

:open
if exist "%APP%" (
  start "" "%APP%"
) else (
  start "" "%URL%"
)
exit /b 0
