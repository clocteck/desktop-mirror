@echo off
setlocal
powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0build_jpg.ps1"
exit /b %ERRORLEVEL%
