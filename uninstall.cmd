@echo off
setlocal

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0scripts\uninstall.ps1"

echo.
pause
