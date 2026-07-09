@echo off
REM ==========================================================================
REM  Conduit — capture the Android-side [Conduit][diag] stream to a file.
REM
REM  HOW IT WORKS: Flutter on Android routes every print() to logcat under the
REM  tag `flutter`. We clear the log, then stream that tag to a file. Plug the
REM  phone in via USB (or over `adb tcpip`) and make sure `adb devices` shows it
REM  BEFORE running this.
REM
REM  The phone's app should be a DEBUG or PROFILE build. In release mode
REM  Flutter suppresses print() output. Easiest: run `flutter run` against the
REM  phone (debug) — its prints go straight to this logcat. If you've already
REM  installed a profile APK, that works too.
REM ==========================================================================
setlocal
cd /d "%~dp0"
if not exist logs mkdir logs

REM Verify a device is connected.
adb devices | findstr "device$" >nul
if errorlevel 1 (
  echo.
  echo !! No Android device detected by adb.
  echo Run `adb devices` to check. The phone must be plugged in with USB
  echo debugging on, then re-run this script.
  echo.
  pause
  exit /b 1
)

for /f "tokens=2 delims==" %%a in (
  'wmic os get localdatetime /value ^| find "="'
) do set "dt=%%a"
set "ts=%dt:~0,8%_%dt:~8,6%"
set "LOG=logs\android_diag_%ts%.log"

echo.
echo === Conduit Android diag capture ===
echo Output file: %LOG%
echo.
echo Clearing old logcat buffer...
adb logcat -c

echo.
echo STEPS:
echo   1. Make sure Conduit is running on the phone.
echo   2. Reproduce the timeout ON THE PHONE (accept the folder invite from PC).
echo   3. Wait until you see the timeout on the phone (x3).
echo   4. Come back here and press Ctrl+C to stop capturing.
echo.
echo Streaming logcat (tag: flutter)...
echo.

adb logcat -s flutter:V > "%LOG%"

echo.
echo Capture stopped. Raw log: %LOG%"
echo Now run:  filter_diag.bat "%LOG%"
echo.
endlocal
