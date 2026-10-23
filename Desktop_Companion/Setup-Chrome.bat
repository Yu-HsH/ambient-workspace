@echo off
setlocal EnableExtensions DisableDelayedExpansion
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Register-NativeHost.ps1" -Gui
exit /b %errorlevel%
