<#
  render-shortlist.ps1
  Turns the run's structured result JSON into the shortlist markdown.

  The model writes DATA (state/run-result.json); this script writes the
  DOCUMENT. Prose generated freehand drifts in structure every run, which
  makes shortlists impossible to skim or diff. Rendering deterministically
  means the layout is byte-identical every time and only the content changes.
  It also cuts model output tokens, since JSON is far terser than markdown.

  Usage:
    render-shortlist.ps1 -ResultJson state\run-result.json
    render-shortlist.ps1 -ResultJson ... -OutFile shortlists\2026-08-01-17.md

  With no -OutFile it derives shortlists\YYYY-MM-DD-HH.md from run_utc and
  appends a letter suffix rather than overwriting an existing file.

  Prints the final path on stdout.

  IMPORTANT: this file is deliberately pure ASCII. PowerShell 5.1 reads a
  BOM-less UTF-8 .ps1 as ANSI, so a literal em-dash (E2 80 94) decodes to
  three CP1252 chars ending in a SMART QUOTE - which the parser treats as a
  string delimiter, breaking every quoted string after it. Non-ASCII output
  characters are emitted via [char] codes below instead of typed literally.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ResultJson,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Unicode used in the OUTPUT, defined without putting it in the SOURCE.
$DASH = [char]0x2014   # em dash
$DOT  = [char]0x00B7   # middot
$WARN = [char]0x26A0   # warning sign

if (-not (Test-Path $ResultJson)) { Write-Error "No result file at $ResultJson"; exit 2 }

# Read as UTF-8 EXPLICITLY. Get-Content -Raw on PowerShell 5.1 decodes as the
# system ANSI codepage, which mangles anything non-ASCII the model wrote -
# em-dashes, and more importantly the rupee sign in salary figures
# ("Rs 1M/yr" listings come through as U+20B9). Those would land in the
# shortlist as mojibake.
$raw = [System.IO.File]::ReadAllText($ResultJson, [System.Text.Encoding]::UTF8)
if ([string]::IsNullOrWhiteSpace($raw)) { Write-Error 'Result file is empty'; exit 2 }
$r = $raw | ConvertFrom-Json

# ---------- resolve output path ------------------------------------------
if ([string]::IsNullOrWhiteSpace($OutFile)) {
    $stamp = [datetime]::Parse(
                $r.run_utc,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind
             ).ToUniversalTime()
    $base = $stamp.ToString('yyyy-MM-dd-HH')
    $dir  = Join-Path $root 'shortlists'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $OutFile = Join-Path $dir "$base.md"

    # Never overwrite an existing record: -17.md -> -17b.md -> -17c.md
    $suffixes = @('b','c','d','e','f','g','h')
    $i = 0
    while ((Test-Path $OutFile) -and $i -lt $suffixes.Count) {
        $OutFile = Join-Path $dir ($base + $suffixes[$i] + '.md')
        $i++
    }
}

# ---------- helpers -------------------------------------------------------
function Esc {
    param($s)
    if ($null -eq $s) { return '' }
    return (([string]$s) -replace '\|', '\|')
}

function Val {
    param($v, $d = '-')
    if ($null -eq $v -or "$v" -eq '') { return $d }
    return "$v"
}

$sb = New-Object System.Text.StringBuilder

function W {
    param($line = '')
    [void]$sb.AppendLine($line)
}

# ---------- prepare -------------------------------------------------------
$jobs = @()
if ($r.jobs) {
    # The outer @() is load-bearing. Sort-Object emits a SCALAR when there is
    # exactly one job, and indexing a PSCustomObject with [0] yields $null - so
    # $jobs[0].score became 0 and the verdict line read "Top score: 0/10" while
    # the job itself rendered as 9/10.
    $jobs = @(@($r.jobs) | Sort-Object -Property @{ Expression = { [int]$_.score }; Descending = $true })
}

$thr  = 8
$high = @($jobs | Where-Object { [int]$_.score -ge $thr })
$top  = 0
if ($jobs.Count -gt 0) { $top = [int]$jobs[0].score }

# ---------- header --------------------------------------------------------
W ("# Shortlist " + $DASH + " " + (Val $r.run_utc))
W

if ($jobs.Count -eq 0) {
    W '**Nothing new this run.** No jobs survived the filters.'
}
elseif ($high.Count -gt 0) {
    W ("**" + $high.Count + " job(s) scored " + $thr + "+.** Top score: **" + $top + "/10**.")
}
else {
    W ("**Nothing worth applying to.** Top score: **" + $top + "/10** (nothing reached " + $thr + ").")
}
W

# ---------- run table -----------------------------------------------------
W '## Run'
W
W '| Search | Pages | Stopped because | Results |'
W '|---|---|---|---|'
foreach ($s in @($r.searches)) {
    $res = Val $s.got
    if ($s.header -and "$($s.header)" -ne "$($s.got)") { $res = "$($s.got) of ~$($s.header)" }
    $row = '| ' + (Esc (Val $s.label)) + ' | ' + (Val $s.pages) + ' | ' + (Esc (Val $s.stop)) + ' | ' + $res + ' |'
    W $row
}
W

$c = $r.counts
$counts = '**Counts** ' + $DASH +
          ' found ' + (Val $c.found 0) +
          ' ' + $DOT + ' unique '   + (Val $c.unique 0) +
          ' ' + $DOT + ' new '      + (Val $c.new 0) +
          ' ' + $DOT + ' detailed ' + (Val $c.detailed 0) +
          ' ' + $DOT + ' stale '    + (Val $c.stale 0) +
          ' ' + $DOT + ' saturated '+ (Val $c.saturated 0) +
          ' ' + $DOT + ' deferred ' + (Val $c.deferred 0) +
          ' ' + $DOT + ' excluded ' + (Val $c.excluded 0)
W $counts
W
W ('**Budget** ' + $DASH + ' search_jobs ' + (Val $r.search_calls '?') + ' ' + $DOT + ' get_job_details ' + (Val $c.detailed 0) + '/25')
W

if ($r.warnings -and @($r.warnings).Count -gt 0) {
    W '### Warnings'
    W
    foreach ($w in @($r.warnings)) { W ('- ' + $w) }
    W
}

W '---'
W

# ---------- scored jobs ---------------------------------------------------
$strong = @($jobs | Where-Object { [int]$_.score -ge 5 })
$weak   = @($jobs | Where-Object { [int]$_.score -lt 5 })

if ($strong.Count -gt 0) {
    W '## Worth a look (score 5+)'
    W
    $n = 0
    foreach ($j in $strong) {
        $n++
        W ('### ' + $n + '. ' + (Val $j.title) + ' ' + $DASH + ' ' + (Val $j.company) + ' ' + $DASH + ' **' + (Val $j.score) + '/10**')
        W
        W '| | |'
        W '|---|---|'
        W ('| **Location** | '   + (Esc (Val $j.loc)) + ' |')
        W ('| **Applicants** | ' + (Esc (Val $j.applicants 'unknown')) + ' |')
        W ('| **Posted** | '     + (Esc (Val $j.age)) + ' |')
        W
        W ('- **Fit:** ' + (Val $j.fit))
        W ('- **Gap:** ' + (Val $j.gap))
        if ($j.mismatch) { W ('- ' + $WARN + ' **Mismatch:** ' + $j.mismatch) }
        W ('- ' + (Val $j.url))
        W
    }
}

if ($weak.Count -gt 0) {
    W '## Rejected (score below 5)'
    W
    W '| Score | Title | Company | Why |'
    W '|---|---|---|---|'
    foreach ($j in $weak) {
        $row = '| ' + (Val $j.score) + ' | ' + (Esc (Val $j.title)) + ' | ' + (Esc (Val $j.company)) + ' | ' + (Esc (Val $j.gap)) + ' |'
        W $row
    }
    W
}

if ($r.notify_held -and @($r.notify_held).Count -gt 0) {
    W '## Scored high but NOT notified'
    W
    W 'These cleared the score bar but failed a notification condition. Shown so a missing toast is never a mystery.'
    W
    W '| Score | Title | Company | Why no toast |'
    W '|---|---|---|---|'
    foreach ($e in @($r.notify_held)) {
        W ('| ' + (Val $e.score) + ' | ' + (Esc (Val $e.title)) + ' | ' + (Esc (Val $e.company)) + ' | ' + (Esc (Val $e.reason)) + ' |')
    }
    W
}

if ($r.stale -and @($r.stale).Count -gt 0) {
    $win = Val $r.stale_window 30
    W ('## Skipped: older than the ' + $win + '-minute freshness window')
    W
    W ('These were never scored. Listed so the cost of the freshness gate stays visible ' + $DASH + ' if good roles keep landing here, widen `freshness.max_age_minutes` in scoring.json.')
    W
    W '| Title | Company | Posted |'
    W '|---|---|---|'
    foreach ($e in @($r.stale)) {
        W ('| ' + (Esc (Val $e.title)) + ' | ' + (Esc (Val $e.company)) + ' | ' + (Esc (Val $e.age)) + ' |')
    }
    W
}

if ($r.saturated -and @($r.saturated).Count -gt 0) {
    W '## Skipped: already saturated'
    W
    W ('Posted under an hour ago and already past the applicant ceiling. Not scored ' + $DASH + ' the pool was gone before the listing was cold.')
    W
    W '| Title | Company | Applicants | Posted |'
    W '|---|---|---|---|'
    foreach ($e in @($r.saturated)) {
        W ('| ' + (Esc (Val $e.title)) + ' | ' + (Esc (Val $e.company)) + ' | ' + (Esc (Val $e.applicants)) + ' | ' + (Esc (Val $e.age)) + ' |')
    }
    W
}

if ($r.excluded -and @($r.excluded).Count -gt 0) {
    W '## Excluded by company filter'
    W
    foreach ($e in @($r.excluded)) {
        W ('- ' + (Val $e.company) + ' ' + $DASH + ' ' + (Val $e.title))
    }
    W
}

if ($r.note) {
    W '---'
    W
    W $r.note
    W
}

# ---------- write ---------------------------------------------------------
$tmp = "$OutFile.tmp"
[System.IO.File]::WriteAllText($tmp, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Move-Item -Path $tmp -Destination $OutFile -Force

$OutFile
exit 0
