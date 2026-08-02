<#
  register-schedule.ps1
  Registers (or removes) the hourly Task Scheduler entry for the pipeline.

    .\scripts\register-schedule.ps1 -Register            # create the hourly task
    .\scripts\register-schedule.ps1 -Register -AtHour 8  # first run at 08:00
    .\scripts\register-schedule.ps1 -Show                # inspect current settings
    .\scripts\register-schedule.ps1 -Remove              # delete it

    .\scripts\register-schedule.ps1 -NotifyTest          # throwaway task that runs
                                                         # test-notify.ps1 once, now
    .\scripts\register-schedule.ps1 -NotifyTest -Remove  # delete that throwaway

  Nothing is registered unless you pass -Register or -NotifyTest.

  A script rather than a one-liner on purpose: pasted into a PowerShell prompt,
  a `powershell -Command "... $a ... $false"` string is expanded by the OUTER
  shell first, so $a becomes empty and -Confirm:$false becomes -Confirm:.

  Why the settings are what they are:
    LogonType Interactive     "Run only when I am logged on". Toasts CANNOT
                              render from session 0. Not hidden, not SYSTEM.
    StartWhenAvailable        "Run as soon as possible after a missed start" -
                              pairs with the self-healing adaptive paging.
    MultipleInstances IgnoreNew   a long catch-up run must not overlap the next
                              hourly trigger.
    ExecutionTimeLimit 30m    a wedged run gets killed instead of blocking
                              every later one.
#>
[CmdletBinding()]
param(
    [switch]$Register,
    [switch]$Remove,
    [switch]$Show,
    [switch]$NotifyTest,
    [ValidateRange(0, 23)][int]$AtHour = 9,
    [ValidateRange(5, 240)][int]$IntervalMinutes = 30
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$taskName = 'LinkedIn Job Pipeline'
$testName = 'LinkedInNotifyTest'
$me       = "$env:USERDOMAIN\$env:USERNAME"

# ---------------------------------------------------------------- notify test
if ($NotifyTest) {
    if ($Remove) {
        try { Unregister-ScheduledTask -TaskName $testName -Confirm:$false; "Removed '$testName'." }
        catch { "Nothing to remove ('$testName' not registered)." }
        exit 0
    }

    $script = Join-Path $root 'test-notify.ps1'
    if (-not (Test-Path $script)) { Write-Error "Missing $script"; exit 1 }

    $a  = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" `
            -WorkingDirectory $root
    $t  = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddYears(1))
    $pr = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
    $s  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    Register-ScheduledTask -TaskName $testName -Action $a -Trigger $t -Principal $pr -Settings $s -Force | Out-Null
    "Registered throwaway task '$testName' (Interactive - toasts can render)."
    ''
    'Run it now:'
    "  Start-ScheduledTask -TaskName '$testName'"
    'Then delete it:'
    "  .\scripts\register-schedule.ps1 -NotifyTest -Remove"
    exit 0
}

# -------------------------------------------------------------------- inspect
if ($Show) {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if (-not $t) { "Task '$taskName' is NOT registered."; exit 0 }

    $info = Get-ScheduledTaskInfo -TaskName $taskName

    # NOTE: the property is .MultipleInstances, NOT .MultipleInstancesPolicy
    # (that is the name in the task XML). Reading the wrong one returns an
    # empty string and makes a correctly-set policy look unset.
    "Task '$taskName' is registered."
    "  State             : $($t.State)"
    "  LogonType         : $($t.Principal.LogonType)   (must be Interactive for toasts)"
    "  StartWhenAvailable: $($t.Settings.StartWhenAvailable)"
    "  MultipleInstances : $($t.Settings.MultipleInstances)"
    "  ExecutionTimeLimit: $($t.Settings.ExecutionTimeLimit)"
    "  Action            : $($t.Actions[0].Execute)"
    "  NextRunTime       : $($info.NextRunTime)"
    "  LastRunTime       : $($info.LastRunTime)"

    # Decode the result code rather than printing a bare number - the
    # "never run yet" value looks alarming but is entirely normal.
    $r = $info.LastTaskResult
    $meaning = switch ($r) {
        0       { 'success' }
        267011  { 'SCHED_S_TASK_HAS_NOT_RUN - has not fired yet (normal for a new task)' }
        267009  { 'SCHED_S_TASK_RUNNING - currently running' }
        267014  { 'SCHED_S_TASK_TERMINATED - killed, likely hit ExecutionTimeLimit' }
        1       { 'exit 1 - check logs\run-<date>.log (auth? hub down?)' }
        default { 'see logs\run-<date>.log' }
    }
    "  LastTaskResult    : $r (0x{0:X}) - $meaning" -f $r
    exit 0
}

# --------------------------------------------------------------------- remove
if ($Remove) {
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; "Removed '$taskName'." }
    catch { "Nothing to remove ('$taskName' not registered)." }
    exit 0
}

# ------------------------------------------------------------------- register
if (-not $Register) {
    'Nothing to do. Pass one of:'
    '  -Register [-AtHour N]   create the hourly task'
    '  -Show                   inspect it'
    '  -Remove                 delete it'
    '  -NotifyTest             register a throwaway notification test task'
    exit 0
}

$bat = Join-Path $root 'run-pipeline.bat'
if (-not (Test-Path $bat)) { Write-Error "Missing $bat"; exit 1 }

# Launch through a hidden VBS shim rather than pointing the task at the .bat
# directly. A .bat action spawns a console window that STEALS FOCUS every hour.
# The shim runs it with window style 0 and waits, so nothing appears on screen
# and LastTaskResult still reflects the real exit code.
#
# This does NOT break toasts. The task remains LogonType Interactive and runs
# in the logged-on session; "hidden window" and "non-interactive session" are
# different things, and only the latter would stop BurntToast rendering.
$vbs = Join-Path $root 'run-hidden.vbs'
if (Test-Path $vbs) {
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' `
                -Argument "`"$vbs`"" -WorkingDirectory $root
}
else {
    Write-Warning "run-hidden.vbs missing - falling back to the .bat, which will flash a console window each run."
    $action = New-ScheduledTaskAction -Execute $bat -WorkingDirectory $root
}

$start   = (Get-Date).Date.AddHours($AtHour)
$trigger = New-ScheduledTaskTrigger -Once -At $start `
             -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)

$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited

# Time limit must stay BELOW the repetition interval. With IgnoreNew, a run
# that outlives its own interval silently swallows the next trigger; capped at
# two thirds, a wedged run is killed in time for the following one to fire.
$limitMin  = [Math]::Max(5, [int]($IntervalMinutes * 2 / 3))
$settings  = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes $limitMin) `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries

Register-ScheduledTask -TaskName $taskName `
                       -Action $action `
                       -Trigger $trigger `
                       -Principal $principal `
                       -Settings $settings `
                       -Force | Out-Null

"Registered '$taskName'."
"  Runs   : $($action.Execute) $($action.Arguments)"
"  Every  : $IntervalMinutes min, first at $($start.ToString('yyyy-MM-dd HH:mm'))"
"  As     : $me (Interactive - runs only when you are logged on)"
''
'Runs with NO visible window - it will not steal focus. Toasts still work,'
'because the task is still Interactive (session), just not visible (window).'
''
'Verify with:  .\scripts\register-schedule.ps1 -Show'
exit 0
