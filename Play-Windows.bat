@echo off
rem PK:GB - double-click launcher for a source checkout on Windows.
rem First run: decodes a user-provided .gb and installs Python/LOVE if needed,
rem builds the game data, then launches. Later runs: launches straight away.
title PK:GB (from source)
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "scripts\bootstrap.ps1"
if errorlevel 1 (
  echo.
  echo Something went wrong - see the messages above.
  pause
)
