@echo off
setlocal
set "SteamLspPowerShell=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "SteamLspPowerShell=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%SteamLspPowerShell%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Steam-Lsp-Compatibility.ps1" -Action Apply %*
set "SteamLspExitCode=%errorlevel%"
echo.
if not "%SteamLspExitCode%"=="0" echo The tool did not complete successfully. Please keep the output for troubleshooting.
pause
exit /b %SteamLspExitCode%
