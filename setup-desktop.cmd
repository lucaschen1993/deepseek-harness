@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0apps\desktop\scripts\setup-local.ps1"
set "setup_exit=%errorlevel%"
if not "%setup_exit%"=="0" pause
exit /b %setup_exit%
