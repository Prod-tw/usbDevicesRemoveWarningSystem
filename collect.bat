@echo off
REM collect.bat - Serial / disk ID collector
REM Run this as Administrator, then plug the drives in one at a time.
REM Each new drive is appended to deploy-table.csv as you insert it.

cd /d "%~dp0"

echo ============================================
echo   USB Disk ID Collector
echo ============================================
echo.

if exist "%~dp0deploy-table.csv" (
    echo [Note] deploy-table.csv already exists - new rows will be APPENDED.
    echo        Delete or rename it first if you want to start over.
    echo.
    pause
    echo.
)

echo Plug the drives in ONE AT A TIME. Press Ctrl+C when finished.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\collect-serials.ps1" -Watch -Detail -OutFile "%~dp0deploy-table.csv"

echo.
echo ============================================
echo   Stopped. Rows saved to deploy-table.csv
echo   Fill in the deployAt column, then run:
echo     powershell -ExecutionPolicy Bypass -File tools\deploy.ps1 -Table deploy-table.csv
echo ============================================
pause >nul
