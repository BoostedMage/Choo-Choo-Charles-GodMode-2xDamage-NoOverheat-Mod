@echo off
setlocal
cd /d "%~dp0"
chcp 65001 >nul 2>&1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL_God_Mode.ps1" %*
set "rc=%errorlevel%"
echo.
if not "%rc%"=="0" echo Installation did not complete. Read the message above.
pause
exit /b %rc%
