<#
  install-startup-shortcut.ps1
  Puts a shortcut to start-linkedin-hub.bat in shell:startup so the shared MCP
  hub comes up when you log on.

    .\scripts\install-startup-shortcut.ps1            # create / overwrite
    .\scripts\install-startup-shortcut.ps1 -Remove    # delete it
    .\scripts\install-startup-shortcut.ps1 -Show      # just report status

  A script rather than a one-liner on purpose: the inline version only works
  from cmd.exe. Pasted into a PowerShell prompt, the OUTER shell expands $s
  inside the double-quoted -Command string before the inner shell sees it, so
  $s.Save() arrives as .Save() and it dies with "An expression was expected
  after '('".
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$Show
)

$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent $PSScriptRoot
$target   = Join-Path $root 'start-linkedin-hub.bat'
$startup  = [Environment]::GetFolderPath('Startup')
$linkPath = Join-Path $startup 'LinkedIn MCP Hub.lnk'

if ($Show) {
    if (Test-Path $linkPath) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($linkPath)
        "Shortcut EXISTS: $linkPath"
        "  TargetPath      : $($lnk.TargetPath)"
        "  WorkingDirectory: $($lnk.WorkingDirectory)"
        if (-not (Test-Path $lnk.TargetPath)) { "  !! target does not exist" }
    }
    else { "No shortcut at $linkPath" }
    exit 0
}

if ($Remove) {
    if (Test-Path $linkPath) { Remove-Item $linkPath -Force; "Removed $linkPath" }
    else { "Nothing to remove at $linkPath" }
    exit 0
}

if (-not (Test-Path $target)) {
    Write-Error "Launcher not found at $target"
    exit 1
}

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($linkPath)
$sc.TargetPath       = $target
$sc.WorkingDirectory = $root
$sc.Description      = 'Starts the shared LinkedIn MCP hub on localhost:8080'
$sc.Save()

"Shortcut created: $linkPath"
"  -> $target"
''
'The hub will now start when you log on. It is port-guarded, so this is safe'
'even if you also launch it by hand.'
exit 0
