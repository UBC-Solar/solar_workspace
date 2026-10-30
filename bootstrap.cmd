@echo off
rem Runs bootstrap.ps1 without changing the PowerShell execution policy (Windows blocks
rem downloaded .ps1 files by default). Options are passed through, e.g.
rem   bootstrap.cmd -SkipBundles -CubeMX "D:\STM32CubeMX\STM32CubeMX.exe"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" %*
set "RC=%ERRORLEVEL%"
rem Keep the window open when started by double-clicking in Explorer
echo %CMDCMDLINE% | findstr /i /c:"%~nx0" >nul && pause
exit /b %RC%
