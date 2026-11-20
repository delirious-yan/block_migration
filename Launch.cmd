@echo off
where pwsh.exe >nul 2>nul
if errorlevel 1 (
    echo Install PowerShell 7.2 or newer, then run Launch.cmd again.
    pause
    exit /b 1
)
pwsh.exe -NoLogo -NoProfile -STA -File "%~dp0Gojira.ps1"
if errorlevel 1 pause
