<#
  notify.ps1
  Fires ONE batched desktop notification for this run's high scorers.

  Input: a JSON file containing an array of
      { "id": "...", "title": "...", "company": "...", "score": 9 }
  (normally state/pending_notify.json, written by the pipeline).

  Behaviour:
    - keeps only score >= config.limits.notify_score_threshold (default 8)
    - drops IDs already in state/notified.json (so a deferred job processed in
      a later run is never notified twice)
    - ONE notification per run, never one per job
    - records notified IDs ONLY if the notification actually fired; if it
      failed, the IDs stay uncommitted so the next run retries

  This script ALWAYS exits 0. Notification failure must never fail the run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobsJson,
    [switch]$DryRun
)

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'Notify.Core.ps1')

$summary = [ordered]@{ fired = $false; eligible = 0; suppressed = 0; method = 'none'; note = '' }

try {
    # ---- threshold from config -------------------------------------------
    $threshold = 8
    try {
        $cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
        if ($cfg.limits.notify_score_threshold) { $threshold = [int]$cfg.limits.notify_score_threshold }
    } catch { }

    # ---- load candidate jobs ---------------------------------------------
    if (-not (Test-Path $JobsJson)) {
        $summary['note'] = "no jobs file at $JobsJson - nothing to notify"
        Write-NotifyLog $summary['note']
        [pscustomobject]$summary | ConvertTo-Json -Compress
        exit 0
    }

    $raw = Get-Content -Path $JobsJson -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $summary['note'] = 'jobs file empty - nothing to notify'
        [pscustomobject]$summary | ConvertTo-Json -Compress
        exit 0
    }

    # Assign BEFORE wrapping in @(). PowerShell 5.1's ConvertFrom-Json emits a
    # JSON array as a single pipeline object, so @($raw | ConvertFrom-Json)
    # yields a 1-element array holding the whole list. Assignment unwraps it.
    $parsed = $raw | ConvertFrom-Json
    $jobs   = @($parsed)
    $high = @($jobs | Where-Object { $null -ne $_.score -and [int]$_.score -ge $threshold })

    if ($high.Count -eq 0) {
        $summary['note'] = "no jobs at score >= $threshold"
        Write-NotifyLog $summary['note']
        [pscustomobject]$summary | ConvertTo-Json -Compress
        exit 0
    }

    # ---- drop already-notified -------------------------------------------
    $already = New-Object 'System.Collections.Generic.HashSet[string]'
    $notifiedPath = Join-Path $root 'state\notified.json'
    if (Test-Path $notifiedPath) {
        try {
            $n = Get-Content $notifiedPath -Raw | ConvertFrom-Json
            foreach ($i in @($n)) { if ($null -ne $i) { [void]$already.Add([string]$i) } }
        } catch { }
    }

    $fresh = @($high | Where-Object { -not $already.Contains([string]$_.id) })
    $summary['suppressed'] = $high.Count - $fresh.Count
    $summary['eligible']   = $fresh.Count

    if ($fresh.Count -eq 0) {
        $summary['note'] = "all $($high.Count) high scorers were already notified"
        Write-NotifyLog $summary['note']
        [pscustomobject]$summary | ConvertTo-Json -Compress
        exit 0
    }

    # ---- build the ONE batched message -----------------------------------
    $ranked = @($fresh | Sort-Object -Property @{ Expression = { [int]$_.score }; Descending = $true })
    $title  = "$($ranked.Count) LinkedIn matches (score $threshold+)"
    $lines  = @()
    foreach ($j in ($ranked | Select-Object -First 3)) {
        $lines += ("{0} - {1} ({2})" -f $j.title, $j.company, $j.score)
    }

    if ($DryRun) {
        $summary['note']   = 'dry run - not fired'
        $summary['method'] = 'dry-run'
        Write-Host $title
        $lines | ForEach-Object { Write-Host "  $_" }
        [pscustomobject]$summary | ConvertTo-Json -Compress
        exit 0
    }

    # ---- fire -------------------------------------------------------------
    $res = Send-JobNotification -Title $title -Lines $lines
    $summary['fired']  = $res.ok
    $summary['method'] = $res.method

    if ($res.ok) {
        # Commit ONLY on success. A failed toast leaves these uncommitted so
        # the next run retries rather than silently swallowing the alert.
        $ids = ($ranked | ForEach-Object { $_.id }) -join ','
        & (Join-Path $PSScriptRoot 'state-commit.ps1') -AddNotified $ids | Out-Null
        $summary['note'] = "notified $($ranked.Count) job(s)"
    }
    else {
        $summary['note'] = "notification failed ($($res.error)) - IDs left uncommitted for retry"
    }
}
catch {
    # Absolute backstop. Nothing in here may fail the pipeline.
    $summary['note'] = "notify.ps1 caught: $($_.Exception.Message)"
    try { Write-NotifyLog $summary['note'] } catch { }
}

[pscustomobject]$summary | ConvertTo-Json -Compress
exit 0
