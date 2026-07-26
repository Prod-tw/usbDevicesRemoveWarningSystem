@echo off
REM run.bat - USB Monitor Launcher
REM Double-click this file to start the USB removal monitor.
REM It will automatically unblock files and bypass execution policy for this session only.

cd /d "%~dp0"

echo ============================================
echo   USB Device Monitor - Starting...
echo ============================================
echo.

if not exist "%~dp0config.json" (
    echo [Error] config.json not found in this folder.
    echo         Open generator.html in a browser to produce one,
    echo         then drop it next to monitor.ps1.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -Path '%~dp0' -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1"

echo.
echo ============================================
echo   Monitor stopped. Press any key to close.
echo ============================================
pause >nul