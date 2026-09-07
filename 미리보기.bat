@echo off
chcp 949 >nul
title 리포트 아카이브 - 로컬 미리보기
REM ============================================================
REM  index.html 을 그냥 열면 reports.json 을 못 읽습니다(file:// 제약).
REM  이 스크립트는 로컬 서버를 띄워 실제 목록까지 보여줍니다.
REM ============================================================
setlocal

set "REPO=C:\Users\LION\Documents\GitHub\projecti"
set "PORT=8000"

set "PY=python"
where python >nul 2>nul
if not errorlevel 1 goto :PYOK
set "PY=py"
where py >nul 2>nul
if not errorlevel 1 goto :PYOK
echo.
echo  [오류] 파이썬을 찾을 수 없습니다. https://www.python.org 에서 설치하세요.
echo.
pause
goto :END
:PYOK

cd /d "%REPO%"

echo.
echo  리포트 목록을 먼저 갱신합니다...
"%PY%" scripts\build-reports.py

echo.
echo ============================================
echo  http://localhost:%PORT%  에서 확인하세요
echo  종료하려면 이 창에서 Ctrl+C
echo ============================================
echo.
start "" "http://localhost:%PORT%"
"%PY%" -m http.server %PORT%

:END
endlocal
