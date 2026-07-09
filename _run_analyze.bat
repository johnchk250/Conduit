@echo off
setlocal
set "DART=C:\Users\Administrator\flutter\bin\cache\dart-sdk\bin\dart.exe"
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"
"%DART%" analyze lib\src\sync\watcher.dart lib\src\sync\engine.dart lib\src\storage\index_db.dart test\watcher_test.dart test\delete_propagation_test.dart
echo ANALYZE_EXIT=%errorlevel%
