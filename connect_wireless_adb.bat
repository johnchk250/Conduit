@echo off
REM ==========================================================================
REM  Conduit — set up WIRELESS ADB so you can capture logcat WITHOUT a
REM  USB cable. A USB cable in the path disrupts the Conduit Wi-Fi session,
REM  so wireless ADB is the right tool here.
REM
REM  REQUIRES Android 11+ (wireless debugging). On the phone:
REM    Settings > Developer options > Wireless debugging > ON
REM
REM  Two flows below: FIRST-TIME PAIRING (needs the pairing code) and
REM  RECONNECT (already paired, just connect).
REM
REM  After this script connects, run capture_android.bat as normal — it works
REM  identically over wireless ADB.
REM ==========================================================================
setlocal enableextensions

echo.
echo === Conduit wireless ADB setup ===
echo.
echo First, on the phone:
echo   Settings ^> Developer options ^> Wireless debugging ^> ON
echo   Tap into "Wireless debugging" to see IP ^& ports.
echo.
echo Is this the FIRST time (need a pairing code), or are you RECONNECTING?
echo   [1] First-time pairing
echo   [2] Reconnect (already paired before)
echo   [3] Skip — just check status
set /p "MODE=Choose 1/2/3: "

if "%MODE%"=="3" goto :status
if "%MODE%"=="1" goto :pair
if "%MODE%"=="2" goto :connect
echo Invalid choice.
goto :status

:pair
echo.
echo On the phone, in Wireless debugging, tap
echo   "Pair device with pairing code".
echo It shows:  IP address ^& port  (e.g. 192.168.1.50:41235)
echo            Wi-Fi pairing code  (6 digits)
echo.
set /p "PAIRADDR=Enter the PAIRING IP:port (e.g. 192.168.1.50:41235): "
if "%PAIRADDR%"=="" goto :eof
set /p "CODE=Enter the 6-digit pairing code: "
if "%CODE%"=="" goto :eof
echo.
echo Pairing...
adb pair "%PAIRADDR%" "%CODE%"
if errorlevel 1 (
  echo.
  echo !! Pairing failed. Common causes:
  echo    - Pairing port closes quickly — reopen the "Pair device" screen and retry.
  echo    - Wrong code / port.
  echo    - PC and phone not on the same Wi-Fi.
  echo.
  pause
  goto :eof
)
echo Pairing succeeded. Now connect (the CONNECT port is different from the pair port).
echo.

:connect
echo On the phone's main "Wireless debugging" screen it shows:
echo   IP address ^& port   (e.g. 192.168.1.50:41235 — the CONNECT port)
echo.
set /p "ADDR=Enter the CONNECT IP:port (e.g. 192.168.1.50:41235): "
if "%ADDR%"=="" goto :eof
echo.
echo Connecting...
adb connect "%ADDR%"
if errorlevel 1 (
  echo !! Connect failed. Double-check the address/port on the wireless debugging screen.
  pause
  goto :eof
)

:status
echo.
echo === adb devices ===
adb devices
echo.
echo If you see your phone^'s IP:port with status "device", you^'re ready.
echo Run capture_android.bat next.
echo.
endlocal
