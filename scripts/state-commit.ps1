<#
  state-commit.ps1
  The ONLY writer of state/*.json. Every write is atomic (temp file + move),
  so a crash mid-write cannot leave a half-written store behind.

  CRITICAL ORDERING: -AdvanceLastRun must be called ONLY after the shortlist
  file has been successfully written. A crashed run that advanced last_run
  would lose that window permanently.

  Usage:
    # after the shortlist file exists:
    state-commit.ps1 -AddSeen "4123,4124" -AdvanceLastRun -Pairs "devops|Mumbai, Maharashtra;devops|Pune, Maharashtra" -RunUtc "2026-08-01T18:00:00Z"

    # after a notification is actually fired:
    state-commit.ps1 -AddNotified "4123,4124"

  Prints JSON summary of what changed.
#>
[CmdletBinding()]
param(
    [string]$AddSeen,
    [string]$AddNotified,
    [switch]$AdvanceLastRun,
    [string]$Pairs,        # semicolon-separated "keywords|location" keys
    [switch]$AllPairs,     # derive the keys from config.json (PREFERRED)
    [string]$RunUtc        # timestamp to record; defaults to now (UTC)
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $root 'state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Write-JsonAtomic {
    param([string]$Path, $Object)
    $tmp = "$Path.tmp"
    ($Object | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
    Move-Item -Path $tmp -Destination $Path -Force
}

function Read-IdList {
    param([string]$Path)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $Path) {
        try {
            $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $p = $raw | ConvertFrom-Json -ErrorAction Stop
                $list = @()
                if ($p -is [System.Array]) { $list = $p }
                elseif ($p.PSObject.Properties['ids']) { $list = @($p.ids) }
                foreach ($i in $list) { if ($null -ne $i) { [void]$set.Add([string]$i) } }
            }
        } catch { }   # corrupt -> rebuild from scratch
    }
    # Comma operator is load-bearing: PowerShell unrolls an enumerable on
    # return, which would hand the caller a plain array (or $null when empty)
    # instead of the HashSet.
    return ,$set
}

$result = [ordered]@{}

# ---- seen_jobs -------------------------------------------------------------
if ($AddSeen) {
    $path = Join-Path $stateDir 'seen_jobs.json'
    $set  = Read-IdList -Path $path
    $before = $set.Count
    foreach ($raw in ($AddSeen -split ',')) {
        $id = $raw.Trim()
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$set.Add($id) }
    }
    $ids = @($set) | Sort-Object
    Write-JsonAtomic -Path $path -Object $ids
    $result['seen_added'] = $set.Count - $before
    $result['seen_total'] = $set.Count
}

# ---- notified --------------------------------------------------------------
if ($AddNotified) {
    $path = Join-Path $stateDir 'notified.json'
    $set  = Read-IdList -Path $path
    $before = $set.Count
    foreach ($raw in ($AddNotified -split ',')) {
        $id = $raw.Trim()
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$set.Add($id) }
    }
    $ids = @($set) | Sort-Object
    Write-JsonAtomic -Path $path -Object $ids
    $result['notified_added'] = $set.Count - $before
    $result['notified_total'] = $set.Count
}

# ---- last_run --------------------------------------------------------------
if ($AdvanceLastRun) {
    # -AllPairs derives the keys from config.json, which is the only way to be
    # certain they match what state-read.ps1 will look up. Hardcoding or
    # hand-typing them is a silent, permanent failure: last_run advances under
    # a key nothing reads, so every run cold-starts forever while still
    # exiting 0.
    if ($AllPairs) {
        $cfgPath = Join-Path $root 'config.json'
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $keys = @()
        foreach ($search in $cfg.searches) {
            # Must match state-read.ps1's key construction exactly, work_type included.
            $k = "$($cfg.keywords)|$($search.location)"
            if ($search.work_type) { $k = "$k|$($search.work_type)" }
            $keys += $k
        }
        $Pairs = $keys -join ';'
    }

    if ([string]::IsNullOrWhiteSpace($Pairs)) {
        Write-Error '-AdvanceLastRun requires -AllPairs (preferred) or -Pairs "keywords|location;..."'
        exit 2
    }

    $stamp = $RunUtc
    if ([string]::IsNullOrWhiteSpace($stamp)) {
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    $path = Join-Path $stateDir 'last_run.json'
    $map = [ordered]@{}
    if (Test-Path $path) {
        try {
            $raw = Get-Content -Path $path -Raw -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $p = $raw | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $p.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
            }
        } catch { }   # corrupt -> rebuild
    }

    $advanced = @()
    foreach ($k in ($Pairs -split ';')) {
        $key = $k.Trim()
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $map[$key] = $stamp
        $advanced += $key
    }

    Write-JsonAtomic -Path $path -Object $map
    $result['last_run_stamp']    = $stamp
    $result['last_run_advanced'] = $advanced
}

if ($result.Count -eq 0) {
    Write-Error 'Nothing to do. Pass -AddSeen, -AddNotified and/or -AdvanceLastRun.'
    exit 2
}

[pscustomobject]$result | ConvertTo-Json -Depth 4 -Compress
exit 0
