@echo off
tasklist 2>nul | findstr /i "flutter.exe"
tasklist 2>nul | findstr /i "dart.exe"
tasklist 2>nul | findstr /i "cmake.exe"
tasklist 2>nul | findstr /i "ninja.exe"
tasklist 2>nul | findstr /i "cl.exe"
echo ---END---
