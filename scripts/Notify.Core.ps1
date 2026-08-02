<#
  Notify.Core.ps1
  Shared notification implementation. Dot-sourced by scripts/notify.ps1 (the
  pipeline) and by test-notify.ps1 (the manual/scheduled test), so the test
  exercises the SAME code path the pipeline uses. A test that passes against
  a different implementation is worthless.

  Contract: Send-JobNotification NEVER throws. It returns a result object and
  logs. The shortlist file on disk is the source of truth; a failed toast must
  not fail the run or corrupt state.
#>

function Write-NotifyLog {
    param([string]$Message)
    try {
        $root   = Split-Path -Parent $PSScriptRoot
        $logDir = Join-Path $root 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path (Join-Path $logDir 'notify.log') -Value $line -Encoding utf8
    }
    catch { }   # logging must never be the thing that breaks notification
}

function Invoke-NotifySound {
    <# Plays a sound for the MessageBox path (BurntToast plays its own). #>
    try {
        $wav = 'C:\Windows\Media\notify.wav'
        if (Test-Path $wav) {
            $player = New-Object System.Media.SoundPlayer $wav
            $player.PlaySync()
            return 'notify.wav'
        }
        [System.Media.SystemSounds]::Exclamation.Play()
        Start-Sleep -Milliseconds 600
        return 'SystemSounds.Exclamation'
    }
    catch {
        Write-NotifyLog "sound failed: $($_.Exception.Message)"
        return 'none'
    }
}

function Send-JobNotification {
    <#
      .SYNOPSIS
        Fires ONE batched desktop notification with sound. Never throws.

      .PARAMETER Title
        e.g. "5 LinkedIn matches (score 8+)"

      .PARAMETER Lines
        Up to 3 strings: "Title - Company (score)"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$Lines = @(),
        [switch]$NoSound
    )

    $body   = ($Lines | Where-Object { $_ }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($body)) { $body = '(no detail)' }
    $method = 'none'
    $ok     = $false
    $err    = ''

    # ---------- Path 1: BurntToast (a real Windows toast) ----------
    try {
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast -ErrorAction Stop
            $params = @{
                Text = @($Title, $body)
            }
            if (-not $NoSound) { $params['Sound'] = 'Default' }
            else               { $params['Silent'] = $true }
            New-BurntToastNotification @params -ErrorAction Stop
            $method = 'BurntToast'
            $ok     = $true
            Write-NotifyLog "OK  [BurntToast] $Title | $($body -replace "`n", ' / ')"
        }
        else {
            $err = 'BurntToast module not installed'
        }
    }
    catch {
        $err = "BurntToast failed: $($_.Exception.Message)"
        Write-NotifyLog "WARN $err"
    }

    # ---------- Path 2: MessageBox fallback ----------
    if (-not $ok) {
        try {
            $sound = 'none'
            if (-not $NoSound) { $sound = Invoke-NotifySound }

            # Launched DETACHED on purpose. MessageBox is modal and blocks until
            # dismissed; waiting on it inside an unattended hourly task would
            # hang the run forever. Fire it and move on.
            $msg  = ($Title + "`n`n" + $body)
            $b64  = [Convert]::ToBase64String(
                        [Text.Encoding]::Unicode.GetBytes(
                            'Add-Type -AssemblyName System.Windows.Forms;' +
                            '[System.Windows.Forms.MessageBox]::Show(' +
                            "[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" +
                            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($msg)) +
                            "')), 'LinkedIn Job Pipeline', 'OK', 'Information')"
                        ))
            Start-Process -FilePath 'powershell.exe' `
                          -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $b64 `
                          -WindowStyle Hidden | Out-Null

            $method = "MessageBox (sound: $sound)"
            $ok     = $true
            Write-NotifyLog "OK  [MessageBox] $Title | $($body -replace "`n", ' / ') | prior: $err"
        }
        catch {
            $err = "$err; MessageBox failed: $($_.Exception.Message)"
            Write-NotifyLog "FAIL $err"
        }
    }

    return [pscustomobject]@{
        ok     = $ok
        method = $method
        title  = $Title
        error  = $err
    }
}
