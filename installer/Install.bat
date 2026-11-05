@echo off
rem DELTARUNE Online installer. Your Steam copy and normal saves are never changed.
rem Drag your DELTARUNE folder onto this file if it can't be found automatically.
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -GameDir "%~1"
pause
