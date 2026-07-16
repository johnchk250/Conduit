@echo off
setlocal
set "GRADLE_USER_HOME=E:\Developer\Gradle"
set "PATH=E:\Developer\flutter\bin;E:\Developer\Android\SDK\platform-tools;C:\Windows\System32;C:\Windows"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"
flutter build apk --profile
echo BUILD_EXIT=%errorlevel%
