@echo off
REM ============================================================
REM  start-linkedin-hub.bat
REM  Launches the shared, long-lived LinkedIn MCP server.
REM  Safe to double-click twice: if 8080 is already serving,
REM  this exits without spawning a second browser-owning process.
REM ============================================================

setlocal EnableExtensions

set "HUB_PORT=8080"
set "HUB_HOST=127.0.0.1"
set "HUB_PATH=/mcp"
set "HUB_URL=http://%HUB_HOST%:%HUB_PORT%%HUB_PATH%"
REM Max seconds to wait for the endpoint to answer. First ever launch
REM may download Chromium, so this is generous.
set "HUB_WAIT=180"

echo.
echo  LinkedIn MCP hub  -^>  %HUB_URL%
echo  ------------------------------------------------------------

REM ---------- 1. Refuse to double-start -----------------------
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "if (Get-NetTCPConnection -LocalPort %HUB_PORT% -State Listen -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"

if %ERRORLEVEL% EQU 0 (
    echo  [skip] Port %HUB_PORT% is already LISTENING.
    echo         Not starting a second server - two processes would
    echo         fight over the same browser profile.
    goto :probe
)

echo  [start] Port %HUB_PORT% is free. Launching hub in a new window...

REM ---------- 2. Launch in its own window ----------------------
REM --browser-idle-timeout 0 keeps Chromium warm between hourly runs.
REM The default (600s) would tear the browser down after 10 idle
REM minutes and cold-start it on every single scheduled run, which
REM defeats the point of a shared persistent hub.
start "LinkedIn MCP Hub" cmd /k uvx mcp-server-linkedin@latest ^
  --transport streamable-http ^
  --host %HUB_HOST% ^
  --port %HUB_PORT% ^
  --path %HUB_PATH% ^
  --browser-idle-timeout 0 ^
  --log-level INFO

:probe
REM ---------- 3. Poll until it actually answers ----------------
REM A plain GET returns 406 "Not Acceptable: Client must accept
REM text/event-stream". That is the server telling us it is UP and
REM speaking MCP. Treat 406 (and 200) as success. Connection
REM refused / no response means keep waiting.
echo  [wait] Polling %HUB_URL% (up to %HUB_WAIT%s)...

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$deadline=(Get-Date).AddSeconds(%HUB_WAIT%);" ^
  "while((Get-Date) -lt $deadline){" ^
  "  try{" ^
  "    $r=Invoke-WebRequest -Uri '%HUB_URL%' -UseBasicParsing -TimeoutSec 5 -Method GET;" ^
  "    if($r.StatusCode -eq 200){Write-Host '  [ok] 200 - hub is up.';exit 0}" ^
  "  }catch{" ^
  "    $resp=$_.Exception.Response;" ^
  "    if($resp -ne $null){" ^
  "      $code=[int]$resp.StatusCode;" ^
  "      if($code -eq 406){Write-Host '  [ok] 406 Not Acceptable - hub is up (expected for a plain GET).';exit 0}" ^
  "      if($code -ge 200 -and $code -lt 500){Write-Host \"  [ok] HTTP $code - hub is answering.\";exit 0}" ^
  "    }" ^
  "  }" ^
  "  Start-Sleep -Milliseconds 500;" ^
  "}" ^
  "Write-Host '  [FAIL] Endpoint never answered.';exit 1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  [FAILED] Hub did not come up within %HUB_WAIT%s.
    echo           Check the "LinkedIn MCP Hub" window for errors.
    echo.
    pause
    exit /b 1
)

echo.
echo  [READY] Hub is serving on %HUB_URL%
echo          Leave the "LinkedIn MCP Hub" window open.
echo.
endlocal
exit /b 0
