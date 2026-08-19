@echo off
chcp 949 >nul
title 개인 서버 드라이브 연결

rem ---- 관리자 권한 확인, 없으면 스스로 승격 ----
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo   관리자 권한이 필요합니다.
  echo   곧 뜨는 UAC 창에서 [예] 를 눌러주세요.
  echo.
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

rem ---- 스크립트 존재 확인 ----
if not exist "%~dp0Connect-PersonalServer.ps1" (
  echo.
  echo   [오류] Connect-PersonalServer.ps1 을 찾을 수 없습니다.
  echo   이 배치 파일과 같은 폴더에 두어야 합니다.
  echo   현재 폴더: %~dp0
  echo.
  pause
  exit /b 1
)

echo.
echo  ===================================================
echo   개인 서버 네트워크 드라이브 연결
echo  ===================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Connect-PersonalServer.ps1"
echo.
echo  ---------------------------------------------------
echo   창을 닫으려면 아무 키나 누르세요.
pause >nul
