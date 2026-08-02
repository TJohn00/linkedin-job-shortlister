<#
  test-notify.ps1
  Standalone notification test. Run it by hand, AND register it as a throwaway
  scheduled task - toasts break for reasons that have nothing to do with this
  code (Focus Assist / Do Not Disturb, notification permissions, BurntToast
  app-ID registration, or running in a non-interactive session).

  It calls the SAME Send-JobNotification the pipeline uses, so a pass here
  means the real path works.

  BY HAND (from the repo root):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\test-notify.ps1

  AS A THROWAWAY SCHEDULED TASK (register, run, delete):
    .\scripts\register-schedule.ps1 -NotifyTest
    Start-ScheduledTask -TaskName 'LinkedInNotifyTest'
    .\scripts\register-schedule.ps1 -NotifyTest -Remove

  That registers with LogonType Interactive ("run only when the user is logged
  on"). Without it the task runs in session 0 and NO toast can ever render -
  which looks exactly like broken code but isn't.
#>
[CmdletBinding()]
param(
    [switch]$NoSound
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$core = Join-Path $here 'scripts\Notify.Core.ps1'

Write-Host ''
Write-Host '=== LinkedIn pipeline - notification test ===' -ForegroundColor Cyan
Write-Host ''

# ---- environment diagnostics ----------------------------------------------
Write-Host ('PowerShell     : {0}' -f $PSVersionTable.PSVersion)
Write-Host ('User           : {0}' -f $env:USERNAME)
Write-Host ('Session name   : {0}' -f $env:SESSIONNAME)
if ([string]::IsNullOrWhiteSpace($env:SESSIONNAME)) {
    Write-Host '  !! SESSIONNAME is empty - this looks NON-INTERACTIVE (session 0).' -ForegroundColor Yellow
    Write-Host '     Toasts cannot render here. Re-register the task with /IT.'      -ForegroundColor Yellow
}

$bt = Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue
if ($bt) {
    Write-Host ('BurntToast     : installed v{0}' -f ($bt.Version -join ', ')) -ForegroundColor Green
} else {
    Write-Host 'BurntToast     : NOT installed - will fall back to MessageBox' -ForegroundColor Yellow
    Write-Host '  Install with:  Install-Module -Name BurntToast -Scope CurrentUser -Force'
}

# Focus Assist / notification settings are the usual silent killer.
try {
    $k = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications'
    $toastEnabled = (Get-ItemProperty -Path $k -Name 'ToastEnabled' -ErrorAction SilentlyContinue).ToastEnabled
    if ($null -ne $toastEnabled -and [int]$toastEnabled -eq 0) {
        Write-Host 'Toasts         : DISABLED system-wide (ToastEnabled=0)' -ForegroundColor Red
        Write-Host '  Settings > System > Notifications > turn Notifications ON'
    } else {
        Write-Host 'Toasts         : enabled' -ForegroundColor Green
    }
} catch { }

Write-Host ('notify.wav     : {0}' -f $(if (Test-Path 'C:\Windows\Media\notify.wav') { 'present' } else { 'MISSING - will use SystemSounds' }))
Write-Host ''

# ---- fire the real thing ---------------------------------------------------
if (-not (Test-Path $core)) {
    Write-Host "FAIL: cannot find $core" -ForegroundColor Red
    exit 1
}
. $core

Write-Host 'Firing test notification...' -ForegroundColor Cyan

$res = Send-JobNotification `
    -Title '3 LinkedIn matches (score 8+)' `
    -Lines @(
        'Senior DevOps Engineer - Acme Cloud (9)',
        'Platform Engineer (AWS) - Contoso (9)',
        'Cloud Engineer - Initech (8)'
    ) `
    -NoSound:$NoSound

Write-Host ''
if ($res.ok) {
    Write-Host ('PASS - delivered via {0}' -f $res.method) -ForegroundColor Green
    Write-Host ''
    Write-Host 'If you did NOT see or hear it despite this PASS, the code worked and'
    Write-Host 'the OS swallowed it. Check, in order:'
    Write-Host '  1. Focus Assist / Do Not Disturb is OFF'
    Write-Host '  2. Settings > System > Notifications: ON, and "Windows PowerShell" allowed'
    Write-Host '  3. If via Task Scheduler: the task has /IT (run only when logged on)'
    Write-Host '  4. BurntToast app-ID: try  New-BTAppId -AppId "LinkedIn.JobPipeline"'
} else {
    Write-Host ('FAIL - {0}' -f $res.error) -ForegroundColor Red
}
Write-Host ''
Write-Host ('Log: {0}' -f (Join-Path $here 'logs\notify.log'))
Write-Host ''

if ($res.ok) { exit 0 } else { exit 1 }
