<#
  health-check.ps1
  Verifies the shared LinkedIn MCP hub is reachable BEFORE any search runs.

  A plain GET on the MCP endpoint returns:
      406 Not Acceptable: Client must accept text/event-stream
  That means the server is UP and speaking MCP. Treat it as success.

  Prints JSON: { "up": true|false, "status": <int|null>, "detail": "..." }
  Exit 0 = up, exit 1 = down.
#>
[CmdletBinding()]
param(
    [string]$Url       = 'http://localhost:8080/mcp',
    [int]   $TimeoutSec = 10
)

$status = $null
$up     = $false
$detail = ''

try {
    $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec -Method GET
    $status = [int]$r.StatusCode
    $up     = $true
    $detail = "HTTP $status - hub responding"
}
catch {
    $resp = $_.Exception.Response
    if ($null -ne $resp) {
        $status = [int]$resp.StatusCode
        if ($status -eq 406) {
            $up     = $true
            $detail = 'HTTP 406 Not Acceptable - hub is UP (expected for a plain GET)'
        }
        elseif ($status -ge 200 -and $status -lt 500) {
            $up     = $true
            $detail = "HTTP $status - hub is answering"
        }
        else {
            $detail = "HTTP $status - hub returned a server error"
        }
    }
    else {
        # No HTTP response at all: connection refused, DNS, timeout.
        $detail = "No response from $Url - $($_.Exception.Message)"
    }
}

[pscustomobject]@{
    up     = $up
    status = $status
    url    = $Url
    detail = $detail
} | ConvertTo-Json -Compress

if ($up) { exit 0 } else { exit 1 }
