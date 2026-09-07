@echo off
chcp 65001 >nul
title 리포트 아카이브 - 미리보기
REM ============================================================
REM  리포트 목록을 갱신하고 index.html 을 브라우저로 엽니다.
REM  업로드 전에 눈으로 확인할 때 쓰세요.
REM ============================================================
setlocal
cd /d "%~dp0"

where powershell >nul 2>nul
if errorlevel 1 goto :NOPS

set "GIT=git"
where git >nul 2>nul
if not errorlevel 1 goto :GITOK
for /d %%D in ("%LocalAppData%\GitHubDesktop\app-*") do set "GIT=%%D\resources\app\git\cmd\git.exe"
:GITOK

echo.
echo  리포트 목록을 갱신합니다...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-reports.ps1" -Root "%CD%" -GitExe "%GIT%"
if errorlevel 1 goto :FAILBUILD

echo.
echo  브라우저를 엽니다...
start "" "%~dp0index.html"
goto :END

:NOPS
echo.
echo  [오류] PowerShell 을 찾을 수 없습니다.
goto :END

:FAILBUILD
echo.
echo  [오류] 리포트 목록 생성 실패. 위 메시지를 확인하세요.
goto :END

:END
echo.
pause
endlocal
