# AI Gateway

Docker deployment assets for running `QuantumNous/new-api` behind an Nginx shell gate.

This public repository deliberately avoids environment-specific values such as hostnames, private IP addresses, SSH users, Cloudflare tunnel names, service serial numbers, tokens, provider keys, and administrator passwords. Keep those values in ignored local files, remote `.env` files, or deployment command parameters.

## Components

- Backend service: `new-api-backend:3000`
- Internal automation service: `k12-worker:8796`
- Proxy service: `new-api:3000`
- Optional GEOFlow admin proxy: `/geo_admin`
- Default host port: `33080`
- Image: configured by `NEW_API_IMAGE` (defaults to `calciumion/new-api:latest`)
- Worker image: configured by `K12_WORKER_IMAGE`
- Persistent data: `./data/new-api`
- Worker data: `./data/k12` and `./data/k12-json`
- Runtime logs: `./logs/new-api`

The deployment also keeps the `new-api` `SESSION_SECRET` in ignored runtime storage so browser sessions survive ordinary container restarts without committing the secret.

## Access

The console access mode is controlled by `AI_GATEWAY_ACCESS_MODE` in the remote runtime `.env`:

- `public`: ordinary browsers can open the console.
- `magicball-only`: only shell access, temporary access links, or shell headers can open it; direct browser access receives a friendly HTML `403`.

The default is `public`. The shell-only path remains available for rollback or protected operations. When shell access opens an external browser URL with a `magicball_shell_access` query value, the proxy validates it, sets a `magicball_ai_gateway_shell` cookie with `Max-Age=604800` (one week), then redirects back to the clean URL.

Set `GEOFLOW_ADMIN_UPSTREAM` in the remote `.env` to expose a same-site GEOFlow admin service at `/geo_admin` through the same access gate.

## Deploy

Provide the real host, SSH port, user, and key at runtime:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key>
```

Pin a tested image for production deployments:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -NewApiImage ghcr.io/<owner>/new-api:sha-<commit>
```

For the integrated K12 control plane, pin both images from the same source commit. Digest references are preferred for canary and production:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> `
  -NewApiImage ghcr.io/<owner>/new-api@sha256:<digest> `
  -K12WorkerImage ghcr.io/<owner>/new-api-k12-worker@sha256:<digest>
```

When supplied, `-NewApiImage` is persisted as `NEW_API_IMAGE` in the remote `.env` so later Compose operations use the same image.

The script uploads this project to `~/upservice-ai-gateway`, runs `docker compose pull`, and starts `new-api`. It creates or reads the ignored local files below and syncs their values into the remote runtime `.env`:

```text
secrets/magicball-ai-gateway-shell-access-token.txt
secrets/new-api-session-secret.txt
secrets/k12-internal-token.txt
```

The K12 Worker is internal-only and has no host port. `K12_AUTOMATION_ENABLED` and `K12_SENTINEL_ENABLED` default to `false`; keep them disabled until the canary and compliance review are complete.

To explicitly switch access mode during deploy:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -AccessMode public
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -AccessMode magicball-only
```

If the remote host needs a provider egress proxy, set `AI_GATEWAY_OUTBOUND_PROXY` in the remote `.env`. To recreate a workstation-backed tunnel, pass the real remote target and bind address at runtime:

```powershell
.\scripts\start-outbound-proxy-tunnel.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -RemoteForwardBind <container-reachable-bind-address>
```

## Tunnel Modes

For a locally configured named Cloudflare tunnel, place the real credentials at:

```text
secrets/cloudflared/upservice-ai-gateway.json
```

Copy `cloudflared.yml.example` to `cloudflared.yml`, replace the placeholder tunnel values, then deploy with:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -TunnelMode config
```

For a remotely managed Cloudflare Tunnel token, keep `CLOUDFLARE_TUNNEL_TOKEN` in the remote `.env`, then deploy with:

```powershell
.\scripts\deploy.ps1 -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -TunnelMode token
```

In token mode, the Cloudflare-side public hostname should route to `http://new-api:3000`. The Docker service name `new-api` is intentionally the gate proxy, so this Cloudflare target does not need to change.

## Verify

```powershell
.\scripts\verify.ps1 -HostName <host> -HostPort <host-port> -PublicUrl <public-url>
```

Expected first-stage result after Docker deploy:

- `<host>:<host-port>` is open.
- In `public` mode, `/api/status` without the shell credential returns a new-api status response.
- In `magicball-only` mode, `/api/status` without the shell credential returns `403`.
- The same URL with `X-MagicBall-Shell-Access` returns a new-api status response.

Expected tunnel result after Cloudflare credentials are configured:

- In `public` mode, `<public-url>/api/status` without the shell credential returns a new-api status response.
- In `magicball-only` mode, the same URL without the shell credential returns `403`.
- Shell-gated access reaches the same new-api service.

## Import Codex Resources

Codex OAuth JSON resources are sensitive. Keep source files outside Git and pass the real source directory at runtime:

```powershell
.\scripts\import-codex-resources.ps1 -SourceDir <resource-dir> -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key>
```

The default run is a dry-run. It validates the JSON files and writes only ignored local evidence under `.sce/`.

To import into the remote `new-api` SQLite database, create a backup, and restart services so the channel cache reloads:

```powershell
.\scripts\import-codex-resources.ps1 -SourceDir <resource-dir> -HostName <host> -Port <ssh-port> -User <ssh-user> -IdentityFile <private-key> -Apply -Restart
```

The script maps each JSON file to a `Codex` channel (`ChannelTypeCodex = 57`) and writes matching `abilities` rows for the supported Codex models. Real token values stay in the source directory and remote runtime `secrets/`; they are not committed.
