<#
  set-last-run.ps1
  Test helper for the recovery / deep-paging check (README section 8.3).

  Rewinds last_run for every configured pair so the next run has to page back
  through a gap.

    .\scripts\set-last-run.ps1 -HoursAgo 12     # rewind 12h
    .\scripts\set-last-run.ps1 -Clear           # delete it -> cold start
    .\scripts\set-last-run.ps1 -Show            # just print current state

  This exists so the docs do not have to carry a nest of escaped quotes.
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set')][double]$HoursAgo = 12,
    [Parameter(ParameterSetName = 'Clear')][switch]$Clear,
    [Parameter(ParameterSetName = 'Show')][switch]$Show
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'state\last_run.json'

if ($Show) {
    if (Test-Path $path) { Get-Content $path -Raw } else { 'last_run.json does not exist (cold start)' }
    exit 0
}

if ($Clear) {
    if (Test-Path $path) { Remove-Item $path -Force; "Deleted $path - next run is a cold start (24h)." }
    else { 'Already absent - next run is a cold start (24h).' }
    exit 0
}

$cfg = Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
$stamp = (Get-Date).ToUniversalTime().AddHours(-1 * $HoursAgo).ToString('yyyy-MM-ddTHH:mm:ssZ')

# Keys must match state-read.ps1 / state-commit.ps1 / pipeline.py exactly,
# including work_type. config.locations was renamed to config.searches when
# the remote entry was added.
$map = [ordered]@{}
foreach ($search in $cfg.searches) {
    $k = "$($cfg.keywords)|$($search.location)"
    if ($search.work_type) { $k = "$k|$($search.work_type)" }
    $map[$k] = $stamp
}

$tmp = "$path.tmp"
($map | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
Move-Item -Path $tmp -Destination $path -Force

"Rewound last_run to $stamp ($HoursAgo h ago) for $($map.Count) pair(s):"
Get-Content $path -Raw
''
'Now run:  run-pipeline.bat   and check the header logs 2-4 pages per location.'
exit 0
