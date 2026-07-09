@echo off
REM ==========================================================================
REM  Conduit — capture the PC-side [Conduit][diag] stream to a file.
REM
REM  HOW IT WORKS: `flutter run -d windows` launches the app in its OWN window
REM  but pipes the app's stdout (where Diag prints) back to this console. We
REM  redirect ALL of it to a timestamped file so nothing is lost, then you drive
REM  the app normally from its window. Close the app window (or press 'q' here)
REM  to stop capturing.
REM
REM  TWO REQUIREMENTS for the diag stream to be visible:
REM    1. Run via `flutter run` (this script does) — the built .exe has no
REM       console, so its prints vanish.
REM    2. Use --profile, NOT --release. In release mode Flutter suppresses
REM       print() output (the VM service that forwards it isn't attached).
REM       Profile mode keeps near-release perf WITH the diag stream.
REM ==========================================================================
setlocal
set "PATH=C:\Users\Administrator\flutter\bin;%PATH%"
cd /d "%~dp0"
if not exist logs mkdir logs

REM Build a timestamp like 20260623_021530
for /f "tokens=2 delims==" %%a in (
  'wmic os get localdatetime /value ^| find "="'
) do set "dt=%%a"
set "ts=%dt:~0,8%_%dt:~8,6%"
set "LOG=logs\pc_diag_%ts%.log"

echo.
echo === Conduit PC diag capture ===
echo Output file: %LOG%
echo.
echo STEPS:
echo   1. The Flutter app window will open shortly.
echo   2. Reproduce the timeout (pair ^> add folder ^> Send to peer ^> accept on phone).
echo   3. After the "Manifest exchange timed out" message appears (x3), close the
echo      app window or press 'q' here to stop.
echo.
echo Starting flutter run...
echo.

flutter run -d windows --profile > "%LOG%" 2>&1

echo.
echo Capture stopped. Raw log: %LOG%
echo Now run:  filter_diag.bat "%LOG%"
echo.
endlocal
