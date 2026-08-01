@echo off
setlocal

echo ============================================================
echo  Conduit Release Builder (Windows ^& Android APK)
echo ============================================================

:: Optional overrides. Leave these unset to use Flutter/Java from PATH or the
:: standard Android Studio installation on the current machine.
if defined FLUTTER_ROOT set "PATH=%FLUTTER_ROOT%\bin;%PATH%"
if not defined JAVA_HOME if exist "C:\Program Files\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

cd /d "%ROOT%"

echo.
echo [1/3] Verifying environment...
call flutter doctor
if %errorlevel% neq 0 (
    echo [ERROR] Flutter environment check failed.
    goto :err
)

echo.
echo Cleaning build directories...
call flutter clean
if %errorlevel% neq 0 (
    echo [WARNING] Flutter clean failed, continuing build...
)

echo.
echo [2/3] Building Windows Release (.exe)...
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [ERROR] Windows build failed.
    goto :err
)
echo [SUCCESS] Windows Release built at: build\windows\x64\runner\Release\conduit.exe

echo.
echo [3/3] Building Android Release APK...
call flutter build apk --release
if %errorlevel% neq 0 (
    echo [ERROR] Android build failed.
    goto :err
)
echo [SUCCESS] Android Release APK built at: build\app\outputs\flutter-apk\app-release.apk

echo.
echo ============================================================
echo  Builds completed successfully!
echo ============================================================
pause
exit /b 0

:err
echo.
echo ============================================================
echo  Build process failed with error code %errorlevel%.
echo ============================================================
pause
exit /b %errorlevel%
