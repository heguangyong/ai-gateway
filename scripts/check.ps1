$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$compose = Get-Content (Join-Path $root "docker-compose.yml") -Raw
$readme = Get-Content (Join-Path $root "README.md") -Raw
$cloudflared = Get-Content (Join-Path $root "cloudflared.yml.example") -Raw
$nginxTemplate = Get-Content (Join-Path $root "nginx\templates\ai-gateway-shell.conf.template") -Raw
$envExample = Get-Content (Join-Path $root ".env.example") -Raw
$codexImportScriptPath = Join-Path $root "scripts\import-codex-resources.ps1"
$codexImportScript = if (Test-Path $codexImportScriptPath) { Get-Content $codexImportScriptPath -Raw } else { "" }
$deployScript = Get-Content (Join-Path $root "scripts\deploy.ps1") -Raw
$publicText = $readme + $cloudflared + $envExample + $compose
$privateHostPattern = "(?<![0-9])(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2\d|3[0-1])\.\d{1,3}\.\d{1,3}|192\.168\.(?!0\.0/16)\d{1,3}\.\d{1,3})(?!/[0-9])"
$localPathPattern = "[A-Za-z]:\\Users\\[^\\\s]+|[A-Za-z]:\\[^<\s]+"

$checks = @(
  [pscustomobject]@{ key = "new-api-image"; passed = $compose.Contains('${NEW_API_IMAGE:-calciumion/new-api:latest}') -and $envExample.Contains("NEW_API_IMAGE=calciumion/new-api:latest") -and $deployScript.Contains('$NewApiImage') -and $deployScript.Contains("^NEW_API_IMAGE=") },
  [pscustomobject]@{ key = "k12-worker-image"; passed = $compose.Contains('${K12_WORKER_IMAGE:-ghcr.io/heguangyong/new-api-k12-worker:k12-worker-integrated}') -and $envExample.Contains("K12_WORKER_IMAGE=ghcr.io/heguangyong/new-api-k12-worker:k12-worker-integrated") -and $deployScript.Contains('$K12WorkerImage') -and $deployScript.Contains("^K12_WORKER_IMAGE=") },
  [pscustomobject]@{ key = "k12-worker-internal-only"; passed = $compose.Contains("k12-worker:") -and $compose.Contains('      - "8796"') -and -not $compose.Contains('${K12_WORKER_HOST_PORT') },
  [pscustomobject]@{ key = "k12-worker-health-ordering"; passed = $compose.Contains("condition: service_healthy") -and $compose.Contains("http://127.0.0.1:8796/healthz") -and $compose.Contains("http://k12-worker:8796") },
  [pscustomobject]@{ key = "k12-worker-safe-defaults"; passed = $compose.Contains('K12_AUTOMATION_ENABLED: "${K12_AUTOMATION_ENABLED:-false}"') -and $compose.Contains('K12_SENTINEL_ENABLED: "${K12_SENTINEL_ENABLED:-false}"') -and $compose.Contains('K12_WEB_UI_ENABLED: "false"') },
  [pscustomobject]@{ key = "k12-runtime-secret"; passed = $compose.Contains("K12_INTERNAL_TOKEN") -and $deployScript.Contains("k12-internal-token.txt") -and $deployScript.Contains('$RemoteK12TokenPath') -and $deployScript.Contains("trap cleanup_runtime_secrets EXIT") },
  [pscustomobject]@{ key = "application-images-only-pull"; passed = $deployScript.Contains('docker compose $composeFiles pull k12-worker new-api-backend') -and -not ([regex]::IsMatch($deployScript, '(?m)^docker compose \$composeFiles pull\s*$')) },
  [pscustomobject]@{ key = "k12-worker-no-proxy-migration"; passed = $envExample.Contains("new-api-backend,k12-worker") -and $deployScript.Contains('current_no_proxy=') -and $deployScript.Contains('*,k12-worker,*') -and $deployScript.Contains("^AI_GATEWAY_NO_PROXY=") },
  [pscustomobject]@{ key = "host-port"; passed = $compose.Contains('${AI_GATEWAY_HOST_PORT:-33080}:3000') },
  [pscustomobject]@{ key = "proxy-service-name-compatible"; passed = $compose.Contains("container_name: upservice-ai-gateway-proxy") },
  [pscustomobject]@{ key = "backend-is-internal"; passed = $compose.Contains("new-api-backend") -and $compose.Contains("expose:") },
  [pscustomobject]@{ key = "shell-token-required"; passed = $compose.Contains("AI_GATEWAY_SHELL_ACCESS_TOKEN") },
  [pscustomobject]@{ key = "access-mode-control"; passed = $compose.Contains('AI_GATEWAY_ACCESS_MODE: "${AI_GATEWAY_ACCESS_MODE:-public}"') -and $envExample.Contains("AI_GATEWAY_ACCESS_MODE=public") -and $nginxTemplate.Contains('$magicball_access_mode_public_granted') },
  [pscustomobject]@{ key = "session-secret-required"; passed = $compose.Contains("SESSION_SECRET") },
  [pscustomobject]@{ key = "geoflow-admin-proxy"; passed = $compose.Contains("GEOFLOW_ADMIN_UPSTREAM") -and $nginxTemplate.Contains("location ^~ /geo_admin") -and $envExample.Contains("GEOFLOW_ADMIN_UPSTREAM=") },
  [pscustomobject]@{ key = "iframe-session-cookie-compatible"; passed = $nginxTemplate.Contains("proxy_cookie_flags session secure samesite=none") },
  [pscustomobject]@{ key = "magicball-only-fallback-403"; passed = $nginxTemplate.Contains("MagicBall shell access required") -and $nginxTemplate.Contains("return 403") },
  [pscustomobject]@{ key = "unauthenticated-403-html"; passed = $nginxTemplate.Contains("default_type text/html") -and $nginxTemplate.Contains("Direct browser visits are intentionally blocked") },
  [pscustomobject]@{ key = "temporary-browser-cookie-grant"; passed = $nginxTemplate.Contains('$arg_magicball_shell_access') -and $nginxTemplate.Contains("Max-Age=604800") -and $nginxTemplate.Contains('return 302 https://$host$uri') },
  [pscustomobject]@{ key = "data-volume"; passed = $compose.Contains("./data/new-api:/data") },
  [pscustomobject]@{ key = "k12-data-volumes"; passed = $compose.Contains("./data/k12:/worker/data") -and $compose.Contains("./data/k12-json:/worker/json") },
  [pscustomobject]@{ key = "deployment-target-parameterized"; passed = $readme.Contains("-HostName <host>") -and $cloudflared.Contains("hostname: <public-hostname>") },
  [pscustomobject]@{ key = "no-public-private-targets"; passed = -not ($publicText -match $privateHostPattern) -and -not ($publicText -match $localPathPattern) },
  [pscustomobject]@{ key = "no-secret-values"; passed = -not ($compose -match "(?i)(sk-[a-z0-9]|api[_-]?key\\s*=\\s*[^#\\s]+|token\\s*=\\s*[^#\\s]+|password\\s*=\\s*[^#\\s]+)") },
  [pscustomobject]@{ key = "codex-import-script"; passed = $codexImportScript.Contains('$ChannelTypeCodex = 57') -and $codexImportScript.Contains('resource-inventory.redacted.json') }
)

$failed = @($checks | Where-Object { -not $_.passed })
[pscustomobject]@{
  verdict = if ($failed.Count) { "failed" } else { "passed" }
  checks = $checks
} | ConvertTo-Json -Depth 4

if ($failed.Count) {
  exit 1
}
