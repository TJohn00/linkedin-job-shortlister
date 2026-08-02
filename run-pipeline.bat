@echo off
REM ============================================================
REM  run-pipeline.bat
REM  Hourly run, invoked by Task Scheduler via run-hidden.vbs.
REM
REM  This now runs pipeline.py (hybrid), NOT `claude -p`.
REM  Everything deterministic - MCP calls, paging, state, dedup,
REM  exclusions, applicant parsing, rule scoring, rendering,
REM  notification - happens in Python with no model involved.
REM  A model is invoked once, only when there are new jobs worth
REM  judging, and only sees stripped job descriptions.
REM
REM  Cost: a run that finds nothing new spends ZERO tokens, which
REM  on an hourly schedule is most runs.
REM
REM  To go fully offline, set llm.enabled=false in scoring.json.
REM ============================================================

setlocal EnableExtensions

REM Project root is wherever this file lives - no hardcoded paths, so the
REM repo works from any directory. %~dp0 ends with a backslash.
set "PROJ=%~dp0"
if "%PROJ:~-1%"=="\" set "PROJ=%PROJ:~0,-1%"
cd /d "%PROJ%" || (echo Cannot cd to %PROJ% & exit /b 1)

if not exist "logs" mkdir "logs"
for /f %%d in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyy-MM-dd\")"') do set "TODAY=%%d"
set "LOG=%PROJ%\logs\run-%TODAY%.log"

for /f "delims=" %%t in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyy-MM-dd HH:mm:ss\")"') do set "TS=%%t"
echo. >> "%LOG%"
echo ============================================================ >> "%LOG%"
echo [%TS%] pipeline run starting (hybrid: python + rule scoring) >> "%LOG%"
echo ============================================================ >> "%LOG%"

python "%PROJ%\pipeline.py" >> "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"

for /f "delims=" %%t in ('powershell -NoProfile -Command "(Get-Date).ToString(\"yyyy-MM-dd HH:mm:ss\")"') do set "TS2=%%t"
echo [%TS2%] pipeline run finished, exit=%RC% >> "%LOG%"

endlocal & exit /b %RC%
