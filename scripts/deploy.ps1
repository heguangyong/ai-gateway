param(
  [Parameter(Mandatory = $true)]
  [string]$HostName,
  [int]$Port = 22,
  [Parameter(Mandatory = $true)]
  [string]$User,
  [string]$IdentityFile = "",
  [string]$RemoteDir = "~/upservice-ai-gateway",
  [string]$NewApiImage = "",
  [string]$K12WorkerImage = "",
  [string]$ShellAccessTokenFile = "",
  [string]$K12InternalTokenFile = "",
  [ValidateSet("", "public", "magicball-only")]
  [string]$AccessMode = "",
  [ValidateSet("none", "config", "token")]
  [string]$TunnelMode = "none",
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$Archive = Join-Path $env:TEMP ("upservice-ai-gateway-{0}.tar" -f ([guid]::NewGuid().ToString("N")))
$RemoteDeployScriptPath = "/tmp/upservice-ai-gateway-deploy-{0}.sh" -f ([guid]::NewGuid().ToString("N"))
$LocalDeployScriptPath = Join-Path $env:TEMP ("upservice-ai-gateway-deploy-{0}.sh" -f ([guid]::NewGuid().ToString("N")))
$RemoteShellTokenPath = "/tmp/upservice-ai-gateway-shell-access-token"
$RemoteSessionSecretPath = "/tmp/upservice-ai-gateway-session-secret"
$RemoteK12TokenPath = "/tmp/upservice-ai-gateway-k12-internal-token"
$Target = "{0}@{1}" -f $User, $HostName

if ($NewApiImage -and $NewApiImage -notmatch '^[A-Za-z0-9][A-Za-z0-9._/@:-]*$') {
  throw "NewApiImage must be a valid Docker image reference without whitespace."
}
if ($K12WorkerImage -and $K12WorkerImage -notmatch '^[A-Za-z0-9][A-Za-z0-9._/@:-]*$') {
  throw "K12WorkerImage must be a valid Docker image reference without whitespace."
}

function New-RuntimeSecret {
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($bytes)
  } finally {
    $rng.Dispose()
  }
  return ([BitConverter]::ToString($bytes) -replace "-", "").ToLowerInvariant()
}

if (-not $ShellAccessTokenFile) {
  $ShellAccessTokenFile = Join-Path $ProjectRoot "secrets\magicball-ai-gateway-shell-access-token.txt"
}
$ShellAccessTokenFile = [System.IO.Path]::GetFullPath($ShellAccessTokenFile)
if (-not (Test-Path $ShellAccessTokenFile)) {
  $secretDir = Split-Path $ShellAccessTokenFile -Parent
  if ($secretDir -and -not (Test-Path $secretDir)) {
    New-Item -ItemType Directory -Force -Path $secretDir | Out-Null
  }
  Set-Content -Path $ShellAccessTokenFile -Value (New-RuntimeSecret) -NoNewline -Encoding ascii
}
$ShellAccessToken = (Get-Content -Path $ShellAccessTokenFile -Raw).Trim()
if (-not ($ShellAccessToken -match '^[A-Za-z0-9._~-]{32,}$')) {
  throw "Shell access token file must contain at least 32 URL-safe characters."
}

$SessionSecretFile = Join-Path $ProjectRoot "secrets\new-api-session-secret.txt"
if (-not (Test-Path $SessionSecretFile)) {
  $sessionSecretDir = Split-Path $SessionSecretFile -Parent
  if ($sessionSecretDir -and -not (Test-Path $sessionSecretDir)) {
    New-Item -ItemType Directory -Force -Path $sessionSecretDir | Out-Null
  }
  Set-Content -Path $SessionSecretFile -Value (New-RuntimeSecret) -NoNewline -Encoding ascii
}
$SessionSecret = (Get-Content -Path $SessionSecretFile -Raw).Trim()
if (-not ($SessionSecret -match '^[A-Za-z0-9._~-]{32,}$')) {
  throw "New API session secret file must contain at least 32 URL-safe characters."
}

if (-not $K12InternalTokenFile) {
  $K12InternalTokenFile = Join-Path $ProjectRoot "secrets\k12-internal-token.txt"
}
$K12InternalTokenFile = [System.IO.Path]::GetFullPath($K12InternalTokenFile)
if (-not (Test-Path $K12InternalTokenFile)) {
  $k12TokenDir = Split-Path $K12InternalTokenFile -Parent
  if ($k12TokenDir -and -not (Test-Path $k12TokenDir)) {
    New-Item -ItemType Directory -Force -Path $k12TokenDir | Out-Null
  }
  Set-Content -Path $K12InternalTokenFile -Value (New-RuntimeSecret) -NoNewline -Encoding ascii
}
$K12InternalToken = (Get-Content -Path $K12InternalTokenFile -Raw).Trim()
if (-not ($K12InternalToken -match '^[A-Za-z0-9._~-]{32,}$')) {
  throw "K12 internal token file must contain at least 32 URL-safe characters."
}

$sshArgs = @("-p", "$Port", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=30")
$scpArgs = @("-P", "$Port", "-o", "StrictHostKeyChecking=accept-new")
if ($IdentityFile) {
  $sshArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
  $scpArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
}

Push-Location $ProjectRoot
try {
  tar -cf $Archive `
    .env.example `
    .gitignore `
    README.md `
    cloudflared.yml.example `
    docker-compose.yml `
    docker-compose.cloudflared-config.yml `
    docker-compose.cloudflared-token.yml `
    nginx `
    scripts
} finally {
  Pop-Location
}

try {
  ssh @sshArgs $Target "mkdir -p $RemoteDir"
  scp @scpArgs $Archive "${Target}:/tmp/upservice-ai-gateway.tar"
  scp @scpArgs $ShellAccessTokenFile "${Target}:$RemoteShellTokenPath"
  scp @scpArgs $SessionSecretFile "${Target}:$RemoteSessionSecretPath"
  scp @scpArgs $K12InternalTokenFile "${Target}:$RemoteK12TokenPath"

  $composeFiles = "-f docker-compose.yml"
  if ($TunnelMode -eq "config") {
    $composeFiles = "$composeFiles -f docker-compose.cloudflared-config.yml"
  }
  if ($TunnelMode -eq "token") {
    $composeFiles = "$composeFiles -f docker-compose.cloudflared-token.yml"
  }
  $removeOrphansArg = if ($TunnelMode -eq "none") { "" } else { " --remove-orphans" }

  $remote = @"
set -e
cleanup_runtime_secrets() {
  rm -f "$RemoteShellTokenPath" "$RemoteSessionSecretPath" "$RemoteK12TokenPath"
}
trap cleanup_runtime_secrets EXIT
cd $RemoteDir
tar -xf /tmp/upservice-ai-gateway.tar -C .
cp -n .env.example .env
if [ -n "$NewApiImage" ]; then
  tmp_env="`$(mktemp)"
  grep -v '^NEW_API_IMAGE=' .env > "`$tmp_env" || true
  printf '\nNEW_API_IMAGE=$NewApiImage\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
fi
if [ -n "$K12WorkerImage" ]; then
  tmp_env="`$(mktemp)"
  grep -v '^K12_WORKER_IMAGE=' .env > "`$tmp_env" || true
  printf '\nK12_WORKER_IMAGE=$K12WorkerImage\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
fi
if [ -n "$AccessMode" ]; then
  tmp_env="`$(mktemp)"
  grep -v '^AI_GATEWAY_ACCESS_MODE=' .env > "`$tmp_env" || true
  printf '\nAI_GATEWAY_ACCESS_MODE=$AccessMode\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
fi
current_no_proxy="`$(sed -n 's/^AI_GATEWAY_NO_PROXY=//p' .env | tail -n 1)"
case ",`$current_no_proxy," in
  *,k12-worker,*) ;;
  *) current_no_proxy="`$current_no_proxy`$([ -n "`$current_no_proxy" ] && printf ',')k12-worker" ;;
esac
tmp_env="`$(mktemp)"
grep -v '^AI_GATEWAY_NO_PROXY=' .env > "`$tmp_env" || true
printf '\nAI_GATEWAY_NO_PROXY=%s\n' "`$current_no_proxy" >> "`$tmp_env"
mv "`$tmp_env" .env
if [ -f "$RemoteShellTokenPath" ]; then
  if [ ! -s "$RemoteShellTokenPath" ]; then
    echo "AI_GATEWAY_SHELL_ACCESS_TOKEN is empty" >&2
    rm -f "$RemoteShellTokenPath"
    exit 1
  fi
  tmp_env="`$(mktemp)"
  grep -v '^AI_GATEWAY_SHELL_ACCESS_TOKEN=' .env > "`$tmp_env"
  printf '\nAI_GATEWAY_SHELL_ACCESS_TOKEN=' >> "`$tmp_env"
  tr -d '\015\012' < "$RemoteShellTokenPath" >> "`$tmp_env"
  printf '\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
  rm -f "`$tmp_env" "$RemoteShellTokenPath"
fi
if [ -f "$RemoteSessionSecretPath" ]; then
  if [ ! -s "$RemoteSessionSecretPath" ]; then
    echo "SESSION_SECRET is empty" >&2
    rm -f "$RemoteSessionSecretPath"
    exit 1
  fi
  tmp_env="`$(mktemp)"
  grep -v '^SESSION_SECRET=' .env > "`$tmp_env"
  printf '\nSESSION_SECRET=' >> "`$tmp_env"
  tr -d '\015\012' < "$RemoteSessionSecretPath" >> "`$tmp_env"
  printf '\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
  rm -f "`$tmp_env" "$RemoteSessionSecretPath"
fi
if [ -f "$RemoteK12TokenPath" ]; then
  if [ ! -s "$RemoteK12TokenPath" ]; then
    echo "K12_INTERNAL_TOKEN is empty" >&2
    rm -f "$RemoteK12TokenPath"
    exit 1
  fi
  tmp_env="`$(mktemp)"
  grep -v '^K12_INTERNAL_TOKEN=' .env > "`$tmp_env" || true
  printf '\nK12_INTERNAL_TOKEN=' >> "`$tmp_env"
  tr -d '\015\012' < "$RemoteK12TokenPath" >> "`$tmp_env"
  printf '\n' >> "`$tmp_env"
  mv "`$tmp_env" .env
  rm -f "`$tmp_env" "$RemoteK12TokenPath"
fi
if [ "$TunnelMode" = "config" ] && [ ! -f cloudflared.yml ]; then
  cp cloudflared.yml.example cloudflared.yml
fi
if [ "$TunnelMode" = "token" ]; then
  if [ -z "`$CLOUDFLARE_TUNNEL_TOKEN" ] && ! grep -Eq '^CLOUDFLARE_TUNNEL_TOKEN=.+$' .env; then
    echo "CLOUDFLARE_TUNNEL_TOKEN is not available in the remote shell or .env" >&2
    exit 1
  fi
  if [ -n "`$CLOUDFLARE_TUNNEL_TOKEN" ]; then
    export CLOUDFLARE_TUNNEL_TOKEN
  fi
fi
docker compose $composeFiles pull k12-worker new-api-backend
"@

  if (-not $NoStart) {
    $remote += @"

docker compose $composeFiles up -d$removeOrphansArg --force-recreate k12-worker new-api-backend new-api
docker compose $composeFiles up -d$removeOrphansArg
docker compose $composeFiles ps
"@
  }

  [System.IO.File]::WriteAllText($LocalDeployScriptPath, ($remote -replace "`r`n", "`n"), [System.Text.Encoding]::ASCII)
  scp @scpArgs $LocalDeployScriptPath "${Target}:$RemoteDeployScriptPath"
  ssh @sshArgs $Target "bash $RemoteDeployScriptPath; status=`$?; rm -f $RemoteDeployScriptPath; exit `$status"
} finally {
  if (Test-Path $Archive) {
    Remove-Item -LiteralPath $Archive -Force
  }
  if (Test-Path $LocalDeployScriptPath) {
    Remove-Item -LiteralPath $LocalDeployScriptPath -Force
  }
}
