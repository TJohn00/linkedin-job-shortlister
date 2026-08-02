<#
  filter-new.ps1
  Membership test against state/seen_jobs.json (or notified.json), so the
  pipeline never has to pull the whole ID list into context.

  Usage:
    filter-new.ps1 -Ids "4123,4124,4125"
    filter-new.ps1 -Ids "4123,4124" -Against notified

  Prints JSON: { "new": [...], "known": [...], "new_count": N, "known_count": N }
  A missing or corrupt store is treated as empty (everything is new).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Ids,
    [ValidateSet('seen', 'notified')][string]$Against = 'seen'
)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $PSScriptRoot
$stateDir = Join-Path $root 'state'

$fileName = 'seen_jobs.json'
if ($Against -eq 'notified') { $fileName = 'notified.json' }
$path = Join-Path $stateDir $fileName

$known = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $path) {
    try {
        $raw = Get-Content -Path $path -Raw -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
            $list = @()
            if ($parsed -is [System.Array]) { $list = $parsed }
            elseif ($parsed.PSObject.Properties['ids']) { $list = @($parsed.ids) }
            foreach ($i in $list) { if ($null -ne $i) { [void]$known.Add([string]$i) } }
        }
    }
    catch {
        # Corrupt store: treat as empty. state-read.ps1 does the quarantining
        # and warning; this script must never block a run.
    }
}

$new    = New-Object System.Collections.ArrayList
$seen   = New-Object System.Collections.ArrayList
$emitted = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($raw in ($Ids -split ',')) {
    $id = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if (-not $emitted.Add($id)) { continue }   # de-dup within the input itself
    if ($known.Contains($id)) { [void]$seen.Add($id) } else { [void]$new.Add($id) }
}

[pscustomobject]@{
    store       = $fileName
    new         = $new
    known       = $seen
    new_count   = $new.Count
    known_count = $seen.Count
} | ConvertTo-Json -Depth 4 -Compress

exit 0
