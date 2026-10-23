@echo off
setlocal DisableDelayedExpansion
set "AMBIENT_DESKTOP_HOME=%~dp0"
set "AMBIENT_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%AMBIENT_POWERSHELL%" (
  echo Windows PowerShell 5.1 is required. See docs/WINDOWS_PORTABLE_GUIDE.md.
  pause
  exit /b 1
)
rem The inline catch also handles a policy blocking the launcher before it can run.
rem Use an environment value for the path: spaces, apostrophes and ampersands stay data.
start "" "%AMBIENT_POWERSHELL%" -NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { . (Join-Path $env:AMBIENT_DESKTOP_HOME 'Launch-AmbientDesktop.ps1') } catch { try { Add-Type -AssemblyName PresentationFramework; [void][System.Windows.MessageBox]::Show('Ambient Workspace could not load the launcher (BOOTSTRAP). Extract the complete ZIP first. See docs/WINDOWS_PORTABLE_GUIDE.md. If your organization blocks scripts, contact its administrator.','Ambient Workspace') } catch { Start-Process $env:ComSpec -ArgumentList '/d /k echo Ambient Workspace BOOTSTRAP error. See docs/WINDOWS_PORTABLE_GUIDE.md.' }; exit 1 }"
if errorlevel 1 (
  echo Could not start Windows PowerShell. See docs/WINDOWS_PORTABLE_GUIDE.md.
  pause
  exit /b 1
)
exit /b 0
