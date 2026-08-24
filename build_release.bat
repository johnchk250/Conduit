@echo off
setlocal

:: Optional overrides. Leave these unset to use Flutter/Java from PATH or the
:: standard Android Studio installation on the current machine.
if defined FLUTTER_ROOT set "PATH=%FLUTTER_ROOT%\bin;%PATH%"
if not defined JAVA_HOME if exist "C:\Program Files\Android\Android Studio\jbr\bin\java.exe" set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
if defined JAVA_HOME set "PATH=%JAVA_HOME%\bin;%PATH%"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

cd /d "%ROOT%"

:menu
cls
echo ============================================================
echo  Conduit Release Builder
echo ============================================================
echo.
echo  [1] Build Windows Release (.exe)
echo  [2] Build Android Release (.apk)
echo  [3] Build Both (Windows + Android APK)
echo  [4] Exit
echo.
set /p "choice=Select an option [1-4]: "

if "%choice%"=="1" goto build_windows
if "%choice%"=="2" goto build_apk
if "%choice%"=="3" goto build_both
if "%choice%"=="4" goto exit_script

echo.
echo [ERROR] Invalid selection. Please choose 1, 2, 3, or 4.
pause
goto menu

:build_windows
echo.
echo ============================================================
echo  Building Windows Release (.exe)...
echo ============================================================
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [ERROR] Windows build failed.
    goto :err
)
echo [SUCCESS] Windows Release built at: build\windows\x64\runner\Release\conduit.exe
echo.
pause
goto menu

:build_apk
echo.
echo ============================================================
echo  Building Android Release APK...
echo ============================================================
call flutter build apk --release
if %errorlevel% neq 0 (
    echo [ERROR] Android build failed.
    goto :err
)
echo [SUCCESS] Android Release APK built at: build\app\outputs\flutter-apk\app-release.apk
echo.
pause
goto menu

:build_both
echo.
echo ============================================================
echo  Building Windows Release (.exe)...
echo ============================================================
call flutter build windows --release
if %errorlevel% neq 0 (
    echo [ERROR] Windows build failed.
    goto :err
)
echo [SUCCESS] Windows Release built at: build\windows\x64\runner\Release\conduit.exe

echo.
echo ============================================================
echo  Building Android Release APK...
echo ============================================================
call flutter build apk --release
if %errorlevel% neq 0 (
    echo [ERROR] Android build failed.
    goto :err
)
echo [SUCCESS] Android Release APK built at: build\app\outputs\flutter-apk\app-release.apk

echo.
echo ============================================================
echo  Both builds completed successfully!
echo ============================================================
echo.
pause
goto menu

:err
echo.
echo ============================================================
echo  Build process failed with error code %errorlevel%.
echo ============================================================
pause
goto menu

:exit_script
exit /b 0
