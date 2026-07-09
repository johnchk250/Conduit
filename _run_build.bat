@echo off
setlocal
set "PATH=C:\Users\Administrator\flutter\bin;C:\Windows\System32;C:\Windows"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"
flutter build windows --profile
echo BUILD_EXIT=%errorlevel%
