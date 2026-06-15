param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,
  [int]$HostPort = 33080,
  [string]$PublicUrl = "",
  [ValidateSet("public", "magicball-only")]
  [string]$ExpectedAccessMode = "public",
  [string]$ShellAccessToken = "",
  [string]$ShellAccessTokenFile = ""
)

$ErrorActionPreference = "Continue"

function Resolve-ShellAccessToken {
  if ($ShellAccessToken) {
    return $ShellAccessToken.Trim()
  }
  if (-not $ShellAccessTokenFile) {
    $ShellAccessTokenFile = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")) "secrets\magicball-ai-gateway-shell-access-token.txt"
  }
  if ($ShellAccessTokenFile -and (Test-Path $ShellAccessTokenFile)) {
    return (Get-Content -Path $ShellAccessTokenFile -Raw).Trim()
  }
  return ""
}

function Test-HttpJson($Url, $Headers = @{}) {
  try {
    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 12 -Headers $Headers
    [pscustomobject]@{
      url = $Url
      ok = $true
      status = [int]$response.StatusCode
      contentType = $response.Headers["Content-Type"]
      sample = (($response.Content -replace "\s+", " ").Substring(0, [Math]::Min(180, ($response.Content -replace "\s+", " ").Length)))
    }
  } catch {
    [pscustomobject]@{
      url = $Url
      ok = $false
      status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
      error = $_.Exception.Message
    }
  }
}

$tcpOpen = Test-NetConnection -ComputerName $HostName -Port $HostPort -InformationLevel Quiet -WarningAction SilentlyContinue
$resolvedShellAccessToken = Resolve-ShellAccessToken
$shellHeaders = @{}
if ($resolvedShellAccessToken) {
  $shellHeaders["X-MagicBall-Shell-Access"] = $resolvedShellAccessToken
}
$localStatusWithoutShell = Test-HttpJson "http://${HostName}:${HostPort}/api/status"
$publicStatusWithoutShell = if ($PublicUrl) {
  Test-HttpJson "$PublicUrl/api/status"
} else {
  [pscustomobject]@{
    url = ""
    ok = $false
    status = -1
    error = "public URL not configured"
  }
}
$localStatusWithShell = if ($resolvedShellAccessToken) {
  Test-HttpJson "http://${HostName}:${HostPort}/api/status" $shellHeaders
} else {
  [pscustomobject]@{
    url = "http://${HostName}:${HostPort}/api/status"
    ok = $false
    status = -1
    error = "shell access token not configured locally"
  }
}
$publicStatusWithShell = if ($PublicUrl -and $resolvedShellAccessToken) {
  Test-HttpJson "$PublicUrl/api/status" $shellHeaders
} elseif (-not $PublicUrl) {
  [pscustomobject]@{
    url = ""
    ok = $false
    status = -1
    error = "public URL not configured"
  }
} else {
  [pscustomobject]@{
    url = "$PublicUrl/api/status"
    ok = $false
    status = -1
    error = "shell access token not configured locally"
  }
}
$expectedWithoutShellStatus = if ($ExpectedAccessMode -eq "public") { 200 } else { 403 }
$localWithoutShellMatchesMode = if ($ExpectedAccessMode -eq "public") {
  $localStatusWithoutShell.ok
} else {
  $localStatusWithoutShell.status -eq 403
}
$publicWithoutShellMatchesMode = if (-not $PublicUrl) {
  $null
} elseif ($ExpectedAccessMode -eq "public") {
  $publicStatusWithoutShell.ok
} else {
  $publicStatusWithoutShell.status -eq 403
}
$results = [ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  host = $HostName
  hostPort = $HostPort
  tcpOpen = $tcpOpen
  expectedAccessMode = $ExpectedAccessMode
  expectedWithoutShellStatus = $expectedWithoutShellStatus
  accessModeExpectation = [ordered]@{
    localWithoutShellMatches = $localWithoutShellMatchesMode
    publicWithoutShellMatches = $publicWithoutShellMatchesMode
  }
  shellAccessTokenConfigured = [bool]$resolvedShellAccessToken
  localStatus = $localStatusWithoutShell
  localStatusWithoutShell = $localStatusWithoutShell
  localStatusWithShell = $localStatusWithShell
  publicRoot = if ($PublicUrl) { Test-HttpJson $PublicUrl } else { $null }
  publicStatus = $publicStatusWithoutShell
  publicStatusWithoutShell = $publicStatusWithoutShell
  publicStatusWithShell = $publicStatusWithShell
}

$results | ConvertTo-Json -Depth 6
