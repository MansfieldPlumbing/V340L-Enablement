@echo off
setlocal
set "V340L_PWSH=C:\bin\pwsh\pwsh.exe"
if not exist "%V340L_PWSH%" set "V340L_PWSH=pwsh.exe"
"%V340L_PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0V340L.ps1" %*
echo.
pause
