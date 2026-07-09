@echo off
REM ==========================================================================
REM  Conduit — distill a raw capture (from capture_pc.bat / capture_android.bat)
REM  into just the [Conduit][diag] lines, plus a small summary that counts the
REM  events most relevant to the manifest-timeout bug.
REM
REM  Usage:  filter_diag.bat "logs\pc_diag_20260623_021530.log"
REM  Produces: <that file>.diag.txt   (diag lines only)
REM            <that file>.summary.txt (event counts + the suspicious window)
REM ==========================================================================
setlocal enableextensions
set "IN=%~1"
if "%IN%"=="" (
  echo Usage: filter_diag.bat ^<logfile^>
  echo   e.g. filter_diag.bat "logs\pc_diag_20260623_021530.log"
  exit /b 1
)
if not exist "%IN%" (
  echo File not found: %IN%
  exit /b 1
)

set "DIAG=%IN%.diag.txt"
set "SUM=%IN%.summary.txt"

REM 1. Pull only the diag lines.
findstr /c:"[Conduit][diag]" "%IN%" > "%DIAG%"

REM 2. Build a summary of event counts + any session-lifecycle events that
REM    could be aborting in-flight manifest exchanges.
> "%SUM%" (
  echo === Conduit diag summary for %IN%
  echo Generated %DATE% %TIME%
  echo.
  echo Total diag lines: 
)
for /f %%c in ('find /c /v "" ^< "%DIAG%"') do echo Total diag lines: %%c >> "%SUM%"

echo. >> "%SUM%"
echo === Event counts (what kinds of things happened) === >> "%SUM%"
for %%e in (
  "session_ready"
  "session_lost"
  "resume_reset"
  "hb_dead"
  "hb_send"
  "hb_pong"
  "gen_mismatch"
  "dup_hello_rejected"
  "supervisor_dial"
  "supervisor_dial_failed"
  "manifest_buffered"
  "send"
  "recv"
) do (
  for /f %%n in ('findstr /c:"\"event\":%%~e" "%DIAG%" ^| find /c "event"') do (
    echo %%~e: %%n >> "%SUM%"
  )
)

echo. >> "%SUM%"
echo === All manifest-related traffic (send/recv of t:manifest) === >> "%SUM%"
findstr /c:"\"t\":\"manifest\"" "%DIAG%" >> "%SUM%" 2>nul

echo. >> "%SUM%"
echo === Session-lifecycle events (potential churn aborting exchanges) === >> "%SUM%"
findstr /c:"session_lost" "%DIAG%" /c:"resume_reset" "%DIAG%" /c:"hb_dead" "%DIAG%" /c:"dup_hello_rejected" "%DIAG%" /c:"gen_mismatch" "%DIAG%" >> "%SUM%" 2>nul

echo.
echo Done.
echo   Diag-only:    %DIAG%
echo   Summary:      %SUM%
echo.
echo Paste back BOTH .summary.txt files (PC + phone) — that's what pinpoints the cause.
echo.
endlocal
