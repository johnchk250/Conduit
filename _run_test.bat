@echo off
setlocal
set "GRADLE_USER_HOME=E:\Developer\Gradle"
set "PATH=E:\Developer\flutter\bin;C:\Windows\System32;C:\Windows"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"
flutter test %*
echo TEST_EXIT=%errorlevel%
