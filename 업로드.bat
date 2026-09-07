@echo off
chcp 949 >nul
title 리포트 아카이브 - GitHub 업로드
REM ============================================================
REM  reports/ 스캔 -> reports.json 갱신 -> 커밋 -> 푸시
REM  각 단계 실패 시 이유를 화면에 남기고 멈춘다
REM ============================================================
setlocal

set "REPO=C:\Users\LION\Documents\GitHub\projecti"

REM ---- git 실행파일 찾기 (PATH 우선, 없으면 GitHub Desktop 내장 git) ----
set "GIT=git"
where git >nul 2>nul
if not errorlevel 1 goto :GITOK
for /d %%D in ("%LocalAppData%\GitHubDesktop\app-*") do set "GIT=%%D\resources\app\git\cmd\git.exe"
:GITOK

REM ---- 파이썬 찾기 ----
set "PY=python"
where python >nul 2>nul
if not errorlevel 1 goto :PYOK
set "PY=py"
where py >nul 2>nul
if not errorlevel 1 goto :PYOK
goto :NOPY
:PYOK

cd /d "%REPO%"
if errorlevel 1 goto :NOREPO

REM ---- 이전 실행이 남긴 잠금 파일 정리 (이게 남으면 git이 통째로 멈춘다) ----
if exist "%REPO%\.git\index.lock" del /f /q "%REPO%\.git\index.lock" >nul 2>nul
if exist "%REPO%\.git\HEAD.lock" del /f /q "%REPO%\.git\HEAD.lock" >nul 2>nul
if exist "%REPO%\.git\objects\maintenance.lock" del /f /q "%REPO%\.git\objects\maintenance.lock" >nul 2>nul
if exist "%REPO%\.git\index.lock" goto :LOCKED

for /f %%D in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "TODAY=%%D"

echo.
echo [1/5] 리포트 목록 생성 (reports.json)...
"%PY%" scripts\build-reports.py
if errorlevel 1 goto :FAILBUILD

echo.
echo [2/5] 원격 동기화...
"%GIT%" ls-remote --exit-code --heads origin main >nul 2>nul
if errorlevel 1 goto :SKIPPULL
"%GIT%" pull --rebase --autostash
if errorlevel 1 goto :FAILPULL
goto :PULLDONE
:SKIPPULL
echo       원격에 main 브랜치가 아직 없습니다. 첫 업로드로 진행합니다.
:PULLDONE

echo.
echo [3/5] 스테이징...
"%GIT%" add -A
if errorlevel 1 goto :FAILADD

"%GIT%" diff --cached --quiet
if not errorlevel 1 goto :NOCHANGE

echo.
echo [4/5] 커밋...
"%GIT%" commit -m "리포트 갱신 %TODAY%"
if errorlevel 1 goto :FAILCOMMIT

echo.
echo [5/5] 푸시...
"%GIT%" push -u origin main
if errorlevel 1 goto :FAILPUSH

echo.
echo ============================================
echo  [완료] %TODAY% GitHub 반영 완료
echo  https://lionheartscy-source.github.io/projecti/
echo ============================================
goto :END

:NOCHANGE
echo.
echo  [알림] 커밋할 변경사항이 없습니다. (이미 모두 반영된 상태)
goto :END

:NOREPO
echo.
echo  [오류] 저장소 폴더를 찾을 수 없습니다: %REPO%
goto :END

:NOPY
echo.
echo  [오류] 파이썬을 찾을 수 없습니다.
echo         https://www.python.org 에서 설치 후 다시 실행하세요.
echo         설치 시 "Add Python to PATH" 를 반드시 체크하세요.
goto :END

:LOCKED
echo.
echo  [오류] .git\index.lock 을 지울 수 없습니다.
echo         GitHub Desktop 이나 다른 git 프로그램이 실행 중이면 종료하고 다시 시도하세요.
goto :END

:FAILBUILD
echo.
echo  [오류] reports.json 생성 실패. 위 메시지를 확인하세요.
goto :END

:FAILPULL
echo.
echo  [오류] 원격 동기화(pull) 실패. 네트워크 문제이거나 충돌일 수 있습니다.
goto :END

:FAILADD
echo.
echo  [오류] 스테이징(add) 실패. 위 메시지를 확인하세요.
goto :END

:FAILCOMMIT
echo.
echo  [오류] 커밋 실패. 위 메시지를 확인하세요.
goto :END

:FAILPUSH
echo.
echo  [오류] 푸시 실패.
echo         로그인이 안 된 상태일 수 있습니다. GitHub Desktop 으로 한 번 로그인한 뒤
echo         다시 실행하거나, 아래 명령으로 직접 확인하세요.
echo             git push -u origin main
goto :END

:END
echo.
pause
endlocal
