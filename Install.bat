@echo off
setlocal EnableExtensions DisableDelayedExpansion
if not exist "%~dp0INSTALL-MANIFEST.json" goto extract
if not exist "%~dp0Installer\Install-AmbientWorkspace.ps1" goto extract
if not exist "%~dp0Browser_Extension\manifest.json" goto extract
if not exist "%~dp0Desktop_Companion\Start.bat" goto extract
rem Do not lower execution policy or bypass downloaded-script/organization protections.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -File "%~dp0Installer\Install-AmbientWorkspace.ps1" -Interactive
if errorlevel 1 (
  echo Install could not start or finish. See docs\TROUBLESHOOTING.md.
  echo If Windows blocks this unsigned installer, stop and verify the official Release.
  echo Do not disable security, unblock scripts, or run as administrator to work around it.
  pause
  exit /b 1
)
exit /b 0
:extract
echo [INSTALL_EXTRACT_ALL] Right-click the ZIP and choose Extract All first.
echo Keep the original ZIP. Run Install.bat from the fully extracted folder.
pause
exit /b 1
