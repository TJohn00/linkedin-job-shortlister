<#
  resume-sync.ps1
  Finds the most recently modified PDF in ./Resumes/ (never hardcoded) and
  compares its SHA256 to state/resume.hash.

  Prints JSON:
    { "resume": "<full path>", "name": "...", "hash": "...",
      "stale": true|false, "reason": "..." }

  stale=true  -> the caller must regenerate state/profile.md from this PDF,
                 then run this script with -Commit to record the new hash.
  stale=false -> profile.md is current; do not touch it.

  Exit 0 always (unless there is no PDF at all -> exit 2).
#>
[CmdletBinding()]
param(
    [switch]$Commit
)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $PSScriptRoot
$resumeDir = Join-Path $root 'Resumes'
$stateDir  = Join-Path $root 'state'
$hashFile  = Join-Path $stateDir 'resume.hash'
$profile   = Join-Path $stateDir 'profile.md'

if (-not (Test-Path $resumeDir)) {
    Write-Error "No Resumes directory at $resumeDir"
    exit 2
}

$pdf = Get-ChildItem -Path $resumeDir -Filter '*.pdf' -File -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTimeUtc -Descending |
       Select-Object -First 1

if ($null -eq $pdf) {
    Write-Error "No PDF found in $resumeDir"
    exit 2
}

$hash = (Get-FileHash -Path $pdf.FullName -Algorithm SHA256).Hash

if ($Commit) {
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    # Record hash + which file it came from, so a rename alone doesn't force a rebuild
    # but a content change does.
    Set-Content -Path $hashFile -Value "$hash  $($pdf.Name)" -Encoding utf8
    [pscustomobject]@{
        resume = $pdf.FullName
        name   = $pdf.Name
        hash   = $hash
        stale  = $false
        reason = 'committed'
    } | ConvertTo-Json -Compress
    exit 0
}

$stale  = $true
$reason = 'no recorded hash'

if (-not (Test-Path $profile)) {
    $reason = 'state/profile.md missing'
}
elseif (Test-Path $hashFile) {
    $recorded = (Get-Content -Path $hashFile -Raw -ErrorAction SilentlyContinue)
    if ($null -ne $recorded) { $recorded = $recorded.Trim() }
    if ($recorded -and $recorded.StartsWith($hash)) {
        $stale  = $false
        $reason = 'unchanged'
    }
    else {
        $reason = 'resume content changed since profile.md was generated'
    }
}

[pscustomobject]@{
    resume = $pdf.FullName
    name   = $pdf.Name
    hash   = $hash
    stale  = $stale
    reason = $reason
} | ConvertTo-Json -Compress

exit 0
