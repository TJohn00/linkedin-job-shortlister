<#
  state-read.ps1
  Reads config.json + state/last_run.json and computes the paging cutoff for
  every (keywords, location) pair.

  Cutoff = last_run - cutoff_slack_minutes. That slack absorbs scheduler drift
  and run duration, so a job posted while the previous run was still executing
  is not lost.

  Missing or corrupt state => start fresh, treating last_run as N hours ago
  (config.limits.cold_start_hours, default 24). A corrupt file is quarantined
  rather than deleted, and reported as a warning.

  Prints JSON:
  {
    "now_utc": "...",
    "cold_start": false,
    "pairs": [ { "keywords","location","last_run","cutoff","cold" } ],
    "seen_count": N, "notified_count": N,
    "limits": {...},
    "warnings": [...]
  }
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $root 'state'
$warnings = New-Object System.Collections.ArrayList

function Read-JsonFile {
    param([string]$Path, $Fallback, [string]$Label)
    if (-not (Test-Path $Path)) {
        [void]$warnings.Add("$Label missing - starting fresh")
        return $Fallback
    }
    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { throw 'file is empty' }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        # Quarantine rather than destroy - the file may be diagnosable later.
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $q     = "$Path.corrupt-$stamp"
        try { Move-Item -Path $Path -Destination $q -Force } catch { }
        [void]$warnings.Add("$Label was CORRUPT ($($_.Exception.Message)) - quarantined to $(Split-Path -Leaf $q), starting fresh")
        return $Fallback
    }
}

# ---- config ----------------------------------------------------------------
$cfgPath = Join-Path $root 'config.json'
$cfg = Read-JsonFile -Path $cfgPath -Fallback $null -Label 'config.json'
if ($null -eq $cfg) { Write-Error 'config.json is required and could not be read.'; exit 2 }

$limits = $cfg.limits
$slack  = 20; if ($limits.cutoff_slack_minutes) { $slack = [int]$limits.cutoff_slack_minutes }
$cold   = 24; if ($limits.cold_start_hours)     { $cold  = [int]$limits.cold_start_hours }

$now = (Get-Date).ToUniversalTime()

# ---- last_run --------------------------------------------------------------
$lastRunPath = Join-Path $stateDir 'last_run.json'
$lastRun = Read-JsonFile -Path $lastRunPath -Fallback (New-Object psobject) -Label 'last_run.json'

$pairs     = New-Object System.Collections.ArrayList
$anyCold   = $false

foreach ($search in $cfg.searches) {
    $loc      = $search.location
    $workType = $search.work_type

    # Key includes work_type so "India" and "India + remote" can never collide.
    $key = "$($cfg.keywords)|$loc"
    if ($workType) { $key = "$key|$workType" }

    $lr  = $null
    $isCold = $true

    $prop = $lastRun.PSObject.Properties[$key]
    if ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace($prop.Value)) {
        try {
            $lr = [datetime]::Parse(
                    $prop.Value,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind
                  ).ToUniversalTime()
            $isCold = $false
        }
        catch {
            [void]$warnings.Add("last_run for '$key' is unparseable ('$($prop.Value)') - treating as cold start")
        }
    }

    if ($isCold) {
        $lr = $now.AddHours(-1 * $cold)
        $anyCold = $true
    }

    # Never let a stale/absurd future timestamp suppress a search.
    if ($lr -gt $now) {
        [void]$warnings.Add("last_run for '$key' is in the FUTURE - clamping to now")
        $lr = $now
    }

    $cutoff = $lr.AddMinutes(-1 * $slack)

    [void]$pairs.Add([pscustomobject]@{
        keywords  = $cfg.keywords
        location  = $loc
        work_type = $workType
        key       = $key
        last_run = $lr.ToString('yyyy-MM-ddTHH:mm:ssZ')
        cutoff   = $cutoff.ToString('yyyy-MM-ddTHH:mm:ssZ')
        cutoff_age_minutes = [math]::Round(($now - $cutoff).TotalMinutes, 1)
        cold     = $isCold
    })
}

# ---- seen / notified (counts only; use filter-new.ps1 to test membership) ---
function Get-IdCount {
    param([string]$Path, [string]$Label)
    $v = Read-JsonFile -Path $Path -Fallback @() -Label $Label
    if ($null -eq $v) { return 0 }
    if ($v -is [System.Array]) { return $v.Count }
    if ($v.PSObject.Properties['ids']) { return @($v.ids).Count }
    return 0
}

$seenCount     = Get-IdCount -Path (Join-Path $stateDir 'seen_jobs.json') -Label 'seen_jobs.json'
$notifiedCount = Get-IdCount -Path (Join-Path $stateDir 'notified.json')  -Label 'notified.json'

[pscustomobject]@{
    now_utc        = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
    cold_start     = $anyCold
    pairs          = $pairs
    seen_count     = $seenCount
    notified_count = $notifiedCount
    limits         = $limits
    warnings       = $warnings
} | ConvertTo-Json -Depth 6

exit 0
