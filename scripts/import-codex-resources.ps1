param(
  [Parameter(Mandatory = $true)]
  [string]$SourceDir,
  [Parameter(Mandatory = $true)]
  [string]$HostName,
  [int]$Port = 22,
  [Parameter(Mandatory = $true)]
  [string]$User,
  [string]$IdentityFile = "",
  [string]$RemoteDir = "~/upservice-ai-gateway",
  [string]$Group = "default",
  [string]$Tag = ("codex-import-{0}" -f (Get-Date -Format "yyyyMMdd")),
  [string]$NamePrefix = "codex",
  [string[]]$Models = @(
    "gpt-5",
    "gpt-5-codex",
    "gpt-5-codex-mini",
    "gpt-5.1",
    "gpt-5.1-codex",
    "gpt-5.1-codex-max",
    "gpt-5.1-codex-mini",
    "gpt-5.2",
    "gpt-5.2-codex",
    "gpt-5.3-codex",
    "gpt-5.3-codex-spark",
    "gpt-5.4",
    "gpt-5.5"
  ),
  [switch]$Apply,
  [switch]$UpdateExisting,
  [switch]$Restart,
  [string]$DockerPythonImage = "python:3.10.19-slim"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$SpecDir = Join-Path $ProjectRoot ".sce\specs\005-codex-resource-import-to-new-api"
$ManifestPath = Join-Path $SpecDir "resource-inventory.redacted.json"
$RunReportPath = Join-Path $SpecDir "last-run.json"
$ChannelTypeCodex = 57
$CodexBaseUrl = "https://chatgpt.com"
$BatchId = Get-Date -Format "yyyyMMddHHmmss"

function Get-Sha256Hex {
  param([string]$Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Convert-UnixSecondsToIso {
  param($Value)
  if ($null -eq $Value -or "$Value" -eq "") {
    return $null
  }
  try {
    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value).UtcDateTime.ToString("o")
  } catch {
    return $null
  }
}

function Get-JsonPropertyValue {
  param($Object, [string]$Name)
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function ConvertTo-BashSingleQuoted {
  param([string]$Value)
  return "'" + ($Value -replace "'", "'""'""'") + "'"
}

function Read-CodexResource {
  param([System.IO.FileInfo]$File)

  $raw = Get-Content -LiteralPath $File.FullName -Raw
  $json = $raw | ConvertFrom-Json

  $required = @("access_token", "account_id", "refresh_token", "type")
  foreach ($field in $required) {
    $value = Get-JsonPropertyValue $json $field
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
      throw "Resource $($File.Name) is missing required field: $field"
    }
  }
  if ([string](Get-JsonPropertyValue $json "type") -ne "codex") {
    throw "Resource $($File.Name) has unsupported type: $(Get-JsonPropertyValue $json "type")"
  }

  $accountId = [string](Get-JsonPropertyValue $json "account_id")
  $email = [string](Get-JsonPropertyValue $json "email")
  $refreshToken = [string](Get-JsonPropertyValue $json "refresh_token")
  $expiresAt = Get-JsonPropertyValue $json "expires_at"
  $refreshTokenFingerprint = Get-Sha256Hex $refreshToken
  $emailKey = if ([string]::IsNullOrWhiteSpace($email)) { "" } else { $email.ToLowerInvariant() }
  $resourceFingerprint = Get-Sha256Hex ("{0}|{1}|{2}" -f $accountId, $emailKey, $refreshTokenFingerprint)

  return [pscustomobject]@{
    FileName = $File.Name
    FullName = $File.FullName
    ResourceFingerprint = $resourceFingerprint
    AccountFingerprint = Get-Sha256Hex $accountId
    EmailFingerprint = if ([string]::IsNullOrWhiteSpace($email)) { $null } else { Get-Sha256Hex $email.ToLowerInvariant() }
    EmailDomain = if ($email -match "@") { ($email -split "@")[-1] } else { $null }
    Type = [string](Get-JsonPropertyValue $json "type")
    ExpiresAtUnix = $expiresAt
    ExpiresAtIso = Convert-UnixSecondsToIso $expiresAt
    HasAccessToken = -not [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $json "access_token"))
    HasRefreshToken = -not [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $json "refresh_token"))
  }
}

if (-not (Test-Path -LiteralPath $SourceDir)) {
  throw "SourceDir does not exist: $SourceDir"
}
if (-not (Test-Path -LiteralPath $SpecDir)) {
  New-Item -ItemType Directory -Force -Path $SpecDir | Out-Null
}

$files = @(Get-ChildItem -LiteralPath $SourceDir -Filter "*.json" -File | Sort-Object Name)
if ($files.Count -eq 0) {
  throw "No JSON resources found in SourceDir: $SourceDir"
}

$resources = @()
foreach ($file in $files) {
  $resources += Read-CodexResource $file
}

$allModels = @()
foreach ($model in $Models) {
  if (-not [string]::IsNullOrWhiteSpace($model) -and -not $allModels.Contains($model)) {
    $allModels += $model
  }
  $compact = "$model-openai-compact"
  if (-not [string]::IsNullOrWhiteSpace($model) -and -not $allModels.Contains($compact)) {
    $allModels += $compact
  }
}

$sharedAccountGroups = @(
  $resources |
    Group-Object AccountFingerprint |
    Where-Object { $_.Count -gt 1 } |
    ForEach-Object {
      [pscustomobject]@{
        accountFingerprint = $_.Name
        count = $_.Count
        files = @($_.Group | ForEach-Object { $_.FileName })
      }
    }
)
$duplicateResources = @(
  $resources |
    Group-Object ResourceFingerprint |
    Where-Object { $_.Count -gt 1 } |
    ForEach-Object {
      [pscustomobject]@{
        resourceFingerprint = $_.Name
        count = $_.Count
        files = @($_.Group | ForEach-Object { $_.FileName })
      }
    }
)

$manifest = [ordered]@{
  schemaVersion = "ai-gateway.codex-resource-inventory.redacted/v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  sourceDir = $SourceDir
  target = [ordered]@{
    host = $HostName
    remoteDir = $RemoteDir
    newApiDb = "data/new-api/one-api.db"
    channelType = $ChannelTypeCodex
    baseUrl = $CodexBaseUrl
    group = $Group
    tag = $Tag
  }
  totals = [ordered]@{
    files = $files.Count
    validResources = $resources.Count
    sharedAccountFingerprintGroups = $sharedAccountGroups.Count
    duplicateResourceFingerprints = $duplicateResources.Count
  }
  models = $allModels
  resources = @($resources | Select-Object FileName, ResourceFingerprint, AccountFingerprint, EmailFingerprint, EmailDomain, Type, ExpiresAtUnix, ExpiresAtIso, HasAccessToken, HasRefreshToken)
  sharedAccountGroups = $sharedAccountGroups
  duplicateResources = $duplicateResources
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

$baseSummary = [ordered]@{
  schemaVersion = "ai-gateway.codex-resource-import-run/v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  mode = if ($Apply) { "apply" } else { "dry-run" }
  sourceDir = $SourceDir
  manifestPath = $ManifestPath
  resourceCount = $resources.Count
  sharedAccountFingerprintGroups = $sharedAccountGroups.Count
  duplicateResourceFingerprints = $duplicateResources.Count
  target = [ordered]@{
    host = $HostName
    remoteDir = $RemoteDir
    channelType = $ChannelTypeCodex
    group = $Group
    tag = $Tag
  }
}

if (-not $Apply) {
  $report = [ordered]@{}
  foreach ($key in $baseSummary.Keys) {
    $report[$key] = $baseSummary[$key]
  }
  $report["verdict"] = "dry-run-passed"
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $RunReportPath -Encoding UTF8
  $report | ConvertTo-Json -Depth 8
  return
}

$sshArgs = @("-p", "$Port", "-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=30")
$scpArgs = @("-P", "$Port", "-o", "StrictHostKeyChecking=accept-new")
if ($IdentityFile) {
  $sshArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
  $scpArgs += @("-i", $IdentityFile, "-o", "IdentitiesOnly=yes")
}
$Target = "{0}@{1}" -f $User, $HostName

$remoteDirResolved = (& ssh @sshArgs $Target "mkdir -p $RemoteDir && cd $RemoteDir && pwd").Trim()
if (-not $remoteDirResolved.StartsWith("/")) {
  throw "Could not resolve remote directory: $remoteDirResolved"
}

$remoteBatchDir = "$remoteDirResolved/secrets/codex-resources/$BatchId"
$remoteDbPath = "$remoteDirResolved/data/new-api/one-api.db"
$remoteScriptPath = "/tmp/ai-gateway-codex-import-$BatchId.py"
$remoteShellPath = "/tmp/ai-gateway-codex-import-$BatchId.sh"
$localScriptPath = Join-Path $env:TEMP ("ai-gateway-codex-import-{0}.py" -f $BatchId)
$localShellPath = Join-Path $env:TEMP ("ai-gateway-codex-import-{0}.sh" -f $BatchId)

$remoteImporter = @'
import argparse
import datetime as dt
import glob
import hashlib
import json
import os
import shutil
import sqlite3
import time

CHANNEL_TYPE_CODEX = 57
CODEX_BASE_URL = "https://chatgpt.com"

def sha256_hex(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def iso_from_unix(value):
    if value in (None, ""):
        return ""
    try:
        return dt.datetime.fromtimestamp(int(value), tz=dt.timezone.utc).isoformat().replace("+00:00", "Z")
    except Exception:
        return ""

def load_resource(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    for field in ("access_token", "account_id", "refresh_token", "type"):
        if not str(data.get(field, "")).strip():
            raise ValueError(f"{os.path.basename(path)} missing required field {field}")
    if data.get("type") != "codex":
        raise ValueError(f"{os.path.basename(path)} has unsupported type {data.get('type')}")
    return data

def sha256_hex_or_empty(value):
    value = str(value or "").strip()
    if not value:
        return ""
    return sha256_hex(value)

def resource_identity(data):
    account_id = str(data.get("account_id", "")).strip()
    email = str(data.get("email", "")).strip().lower()
    refresh_hash = sha256_hex_or_empty(data.get("refresh_token", ""))
    return "\0".join([account_id, email, refresh_hash])

def canonical_key(data):
    out = {}
    for field in ("id_token", "access_token", "refresh_token", "account_id", "email", "type", "last_refresh", "expired"):
        value = data.get(field)
        if value not in (None, ""):
            out[field] = value
    if "expired" not in out:
        expired = iso_from_unix(data.get("expires_at"))
        if expired:
            out["expired"] = expired
    if "type" not in out:
        out["type"] = "codex"
    return json.dumps(out, ensure_ascii=False, sort_keys=True, separators=(",", ":"))

def channel_name(prefix, index, filename, data):
    stem = os.path.splitext(os.path.basename(filename))[0]
    local = stem
    if "-" in stem:
        parts = stem.split("-", 1)
        if len(parts) == 2:
            local = parts[1]
    name = f"{prefix}-{index:03d}-{local}"
    return name[:255]

def read_existing_codex_channels(conn):
    existing = {}
    for row in conn.execute("select id, key, name from channels where type = ?", (CHANNEL_TYPE_CODEX,)):
        channel_id, raw_key, name = row
        try:
            data = json.loads(raw_key or "{}")
        except Exception:
            continue
        identity = resource_identity(data)
        if identity.strip("\0"):
            existing[identity] = {"id": channel_id, "name": name}
    return existing

def insert_abilities(conn, channel_id, group_name, models, enabled, priority, weight, tag):
    for model in models:
        conn.execute(
            'insert or ignore into abilities ("group", model, channel_id, enabled, priority, weight, tag) values (?, ?, ?, ?, ?, ?, ?)',
            (group_name, model, channel_id, enabled, priority, weight, tag),
        )

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--db-path", required=True)
    parser.add_argument("--backup-path", required=True)
    parser.add_argument("--group", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--name-prefix", required=True)
    parser.add_argument("--models", required=True)
    parser.add_argument("--update-existing", action="store_true")
    args = parser.parse_args()

    files = sorted(glob.glob(os.path.join(args.source_dir, "*.json")))
    if not files:
        raise SystemExit("no json resources found")
    models = [m.strip() for m in args.models.split(",") if m.strip()]
    if not models:
        raise SystemExit("models list cannot be empty")

    resources = []
    seen_resources = set()
    duplicates = []
    for path in files:
        data = load_resource(path)
        identity = resource_identity(data)
        if identity in seen_resources:
            duplicates.append(os.path.basename(path))
            continue
        seen_resources.add(identity)
        resources.append((path, data))

    if not os.path.exists(args.db_path):
        raise SystemExit(f"database does not exist: {args.db_path}")
    os.makedirs(os.path.dirname(args.backup_path), exist_ok=True)
    shutil.copy2(args.db_path, args.backup_path)

    conn = sqlite3.connect(args.db_path, timeout=30)
    conn.execute("pragma busy_timeout = 30000")
    conn.execute("begin immediate")
    inserted = []
    updated = []
    skipped = []
    try:
        existing = read_existing_codex_channels(conn)
        now = int(time.time())
        models_csv = ",".join(models)
        channel_info = json.dumps({
            "is_multi_key": False,
            "multi_key_size": 0,
            "multi_key_status_list": None,
            "multi_key_polling_index": 0,
            "multi_key_mode": "",
        }, separators=(",", ":"))
        channel_info_value = sqlite3.Binary(channel_info.encode("utf-8"))
        settings = "{}"

        for index, (path, data) in enumerate(resources, start=1):
            account_id = str(data.get("account_id", "")).strip()
            identity = resource_identity(data)
            key_json = canonical_key(data)
            name = channel_name(args.name_prefix, index, path, data)
            remark = ("Imported by ai-gateway codex resource import from " + os.path.basename(path))[:255]
            existing_channel = existing.get(identity)

            if existing_channel and not args.update_existing:
                skipped.append({
                    "file": os.path.basename(path),
                    "reason": "existing-account",
                    "channel_id": existing_channel["id"],
                    "account_fingerprint": sha256_hex(account_id),
                    "resource_fingerprint": sha256_hex(identity),
                })
                continue

            if existing_channel and args.update_existing:
                channel_id = existing_channel["id"]
                conn.execute(
                    '''update channels
                       set key = ?, name = ?, base_url = ?, models = ?, "group" = ?, tag = ?, remark = ?,
                           status = 1, weight = 1, priority = 0, auto_ban = 1, channel_info = ?, settings = ?
                       where id = ?''',
                    (key_json, name, CODEX_BASE_URL, models_csv, args.group, args.tag, remark, channel_info_value, settings, channel_id),
                )
                conn.execute("delete from abilities where channel_id = ?", (channel_id,))
                insert_abilities(conn, channel_id, args.group, models, 1, 0, 1, args.tag)
                updated.append({
                    "file": os.path.basename(path),
                    "channel_id": channel_id,
                    "account_fingerprint": sha256_hex(account_id),
                    "resource_fingerprint": sha256_hex(identity),
                })
                continue

            cursor = conn.execute(
                '''insert into channels
                   (type, key, open_ai_organization, test_model, status, name, weight, created_time,
                    test_time, response_time, base_url, other, balance, balance_updated_time, models,
                    "group", used_quota, model_mapping, status_code_mapping, priority, auto_ban,
                    other_info, tag, setting, param_override, header_override, remark, channel_info, settings)
                   values
                   (?, ?, null, ?, 1, ?, 1, ?, 0, 0, ?, '', 0, 0, ?, ?, 0, '',
                    '', 0, 1, '', ?, '', '', '', ?, ?, ?)''',
                (
                    CHANNEL_TYPE_CODEX,
                    key_json,
                    "gpt-5.5",
                    name,
                    now,
                    CODEX_BASE_URL,
                    models_csv,
                    args.group,
                    args.tag,
                    remark,
                    channel_info_value,
                    settings,
                ),
            )
            channel_id = cursor.lastrowid
            insert_abilities(conn, channel_id, args.group, models, 1, 0, 1, args.tag)
            inserted.append({
                "file": os.path.basename(path),
                "channel_id": channel_id,
                "account_fingerprint": sha256_hex(account_id),
                "resource_fingerprint": sha256_hex(identity),
            })

        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

    result = {
        "success": True,
        "source_count": len(files),
        "unique_source_resources": len(resources),
        "duplicate_source_files": duplicates,
        "inserted_count": len(inserted),
        "updated_count": len(updated),
        "skipped_count": len(skipped),
        "inserted": inserted,
        "updated": updated,
        "skipped": skipped,
        "backup_path": args.backup_path,
        "db_path": args.db_path,
        "tag": args.tag,
        "group": args.group,
        "channel_type": CHANNEL_TYPE_CODEX,
        "model_count": len(models),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))

if __name__ == "__main__":
    main()
'@

try {
  [System.IO.File]::WriteAllText($localScriptPath, $remoteImporter, [System.Text.Encoding]::UTF8)
  & ssh @sshArgs $Target "mkdir -p $remoteBatchDir"
  foreach ($file in $files) {
    & scp @scpArgs $file.FullName "${Target}:$remoteBatchDir/"
  }
  & scp @scpArgs $localScriptPath "${Target}:$remoteScriptPath"

  $modelCsv = ($allModels -join ",")
  $updateArg = if ($UpdateExisting) { "--update-existing" } else { "" }

  $dockerRunLine = @(
    "docker run --rm --user 0:0",
    ("-v {0}:/import:ro" -f (ConvertTo-BashSingleQuoted $remoteBatchDir)),
    ("-v {0}:/data" -f (ConvertTo-BashSingleQuoted "$remoteDirResolved/data/new-api")),
    ("-v {0}:/importer.py:ro" -f (ConvertTo-BashSingleQuoted $remoteScriptPath)),
    (ConvertTo-BashSingleQuoted $DockerPythonImage),
    "python /importer.py",
    "--source-dir /import",
    "--db-path /data/one-api.db",
    ("--backup-path {0}" -f (ConvertTo-BashSingleQuoted ("/data/one-api.db.backup-codex-import-{0}" -f $BatchId))),
    ("--group {0}" -f (ConvertTo-BashSingleQuoted $Group)),
    ("--tag {0}" -f (ConvertTo-BashSingleQuoted $Tag)),
    ("--name-prefix {0}" -f (ConvertTo-BashSingleQuoted $NamePrefix)),
    ("--models {0}" -f (ConvertTo-BashSingleQuoted $modelCsv)),
    $updateArg
  ) -join " "

  if ($Restart) {
    $remoteShell = @"
set -e
cd $(ConvertTo-BashSingleQuoted $remoteDirResolved)
cleanup() {
  docker compose up -d new-api-backend new-api >/dev/null
}
docker compose stop new-api new-api-backend >/dev/null
trap cleanup EXIT
$dockerRunLine
"@
  } else {
    $remoteShell = @"
set -e
cd $(ConvertTo-BashSingleQuoted $remoteDirResolved)
$dockerRunLine
"@
  }

  [System.IO.File]::WriteAllText($localShellPath, ($remoteShell -replace "`r`n", "`n"), [System.Text.Encoding]::ASCII)
  & scp @scpArgs $localShellPath "${Target}:$remoteShellPath"
  $remoteResultRaw = & ssh @sshArgs $Target "bash $remoteShellPath"
  if ($LASTEXITCODE -ne 0) {
    throw "Remote import failed."
  }
  $remoteResult = ($remoteResultRaw -join "`n") | ConvertFrom-Json

  $restartResult = $null
  if ($Restart) {
    $restartRaw = & ssh @sshArgs $Target "cd $remoteDirResolved && docker compose ps --format json"
    $restartResult = @($restartRaw)
  }

  $report = [ordered]@{}
  foreach ($key in $baseSummary.Keys) {
    $report[$key] = $baseSummary[$key]
  }
  $report["verdict"] = "apply-completed"
  $report["remoteBatchDir"] = $remoteBatchDir
  $report["remoteResult"] = $remoteResult
  $report["restartRequested"] = [bool]$Restart
  $report["dockerPythonImage"] = $DockerPythonImage
  $report["restartResult"] = $restartResult

  $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RunReportPath -Encoding UTF8
  $report | ConvertTo-Json -Depth 10
} finally {
  if (Test-Path -LiteralPath $localScriptPath) {
    Remove-Item -LiteralPath $localScriptPath -Force
  }
  if (Test-Path -LiteralPath $localShellPath) {
    Remove-Item -LiteralPath $localShellPath -Force
  }
  if ($Apply) {
    try {
      & ssh @sshArgs $Target "rm -f $remoteScriptPath $remoteShellPath" | Out-Null
    } catch {
      Write-Warning "Could not remove remote temporary importer files."
    }
  }
}
