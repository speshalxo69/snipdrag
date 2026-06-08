@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\install.ps1"

echo.
pause
