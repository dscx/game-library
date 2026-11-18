@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scan.ps1" -Push
pause
