@echo off
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
pause
