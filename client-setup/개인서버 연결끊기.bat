@echo off
chcp 949 >nul
title 개인 서버 드라이브 연결 해제

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo   관리자 권한이 필요합니다. UAC 창에서 [예] 를 눌러주세요.
  echo.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

if not exist "%~dp0Connect-PersonalServer.ps1" (
  echo   [오류] Connect-PersonalServer.ps1 을 찾을 수 없습니다.
  pause
  exit /b 1
)

echo.
echo  ===================================================
echo   개인 서버 드라이브 연결 해제
echo  ===================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-PersonalServer.ps1" -Uninstall
echo.
pause >nul
