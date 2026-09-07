@echo off
chcp 65001 >nul
title 리포트 아카이브 - GitHub 업로드
REM ============================================================
REM  reports/ 스캔 -> reports.json / reports.js 갱신 -> 커밋 -> 푸시
REM  PowerShell 로 동작하므로 별도 설치가 필요 없습니다.
REM ============================================================
setlocal
cd /d "%~dp0"

REM ---- git 실행파일 찾기 (PATH 우선, 없으면 GitHub Desktop 내장 git) ----
set "GIT=git"
where git >nul 2>nul
if not errorlevel 1 goto :GITOK
for /d %%D in ("%LocalAppData%\GitHubDesktop\app-*") do set "GIT=%%D\resources\app\git\cmd\git.exe"
if not exist "%GIT%" goto :NOGIT
:GITOK

where powershell >nul 2>nul
if errorlevel 1 goto :NOPS

REM ---- 이전 실행이 남긴 잠금 파일 정리 (이게 남으면 git이 통째로 멈춘다) ----
if exist ".git\index.lock" del /f /q ".git\index.lock" >nul 2>nul
if exist ".git\HEAD.lock" del /f /q ".git\HEAD.lock" >nul 2>nul
if exist ".git\objects\maintenance.lock" del /f /q ".git\objects\maintenance.lock" >nul 2>nul
if exist ".git\index.lock" goto :LOCKED

for /f %%D in ('powershell -NoProfile -Command "Get-Date -Format yyyy-MM-dd"') do set "TODAY=%%D"

echo.
echo [1/5] 리포트 목록 생성...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-reports.ps1" -GitExe "%GIT%"
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

:NOGIT
echo.
echo  [오류] git 을 찾을 수 없습니다.
echo         GitHub Desktop 을 설치했다면 한 번 실행해 로그인해 주세요.
goto :END

:NOPS
echo.
echo  [오류] PowerShell 을 찾을 수 없습니다.
echo         Windows 기본 구성 요소라 보통 있어야 합니다.
goto :END

:LOCKED
echo.
echo  [오류] .git\index.lock 을 지울 수 없습니다.
echo         GitHub Desktop 이나 다른 git 프로그램이 실행 중이면 종료하고 다시 시도하세요.
goto :END

:FAILBUILD
echo.
echo  [오류] 리포트 목록 생성 실패. 위 메시지를 확인하세요.
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
echo         다시 실행해 주세요.
goto :END

:END
echo.
pause
endlocal
