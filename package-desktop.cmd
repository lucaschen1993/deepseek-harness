@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0apps\desktop\scripts\setup-local.ps1" -Package
set "package_exit=%errorlevel%"
pause
exit /b %package_exit%
