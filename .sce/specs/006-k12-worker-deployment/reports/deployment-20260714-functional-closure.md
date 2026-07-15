# K12 Functional Closure Production Iteration - 2026-07-14

## Release identity

- Source commit: `b0bb3546487695161b104b7f707cc5c2e3c11926`.
- GitHub Actions run: `29305896136` (success).
- New API image: `ghcr.io/heguangyong/new-api@sha256:c757c218d92e87571320e93aab90d21eea0a2fc86b2133b28647026f8ae3cc1c`.
- Worker image: `ghcr.io/heguangyong/new-api-k12-worker@sha256:ec2af3cdb6d9702ba96acfabfa15ef22b01f7a92cf41744f47d3c6ac6ff8e22b`.
- Runtime version: `k12-b0bb35464876`.

## Backup and rollout

- Backup set: `/home/zeno-dev/upservice-ai-gateway-backups/20260714-133113-k12-functional-closure`.
- Live and backup SQLite integrity checks returned `ok`; both contained one channel before rollout.
- Deployment used the repository deployment script with pinned digests, public access mode, and Cloudflare token mode.
- Application containers were recreated in dependency order. The existing Cloudflare container ID remained `3fa07afb64630af04fc4e4336f59c61f382d5b4669bb54d30fc3d7e3e8bfde62`.

## Postdeployment evidence

- New API backend, Worker, and Nginx proxy were healthy.
- `K12_AUTOMATION_ENABLED`, `K12_SENTINEL_ENABLED`, and `K12_WEB_UI_ENABLED` remained `false`.
- Worker Readiness returned 200 directly and through backend-to-Worker internal routing.
- Expected Readiness blockers were deployment policy, default password, Workspace, email source, and Sub2API; direct OpenAI connectivity remained a warning.
- Unauthenticated New API `/api/k12/readiness` returned 401.
- Live database integrity returned `ok` and the channel count remained one.
- Local and public status endpoints returned 200.
- The existing service token listed 25 models and retained `gpt-5.5` as an available default.
- Worker, backend, and proxy alert-log scans returned zero matches.

## Rollback and activation boundary

- The backup Compose configuration rendered successfully.
- Both previous image digests remained available on the Docker host.
- The backup database integrity check returned `ok`.
- Rollback was not exercised because postdeployment verification passed.
- Real account registration and external provider activation were not performed; automation remains intentionally disabled until a separate approved acceptance phase.

## Activation follow-up - 2026-07-15

- The user explicitly approved enabling production automation and Sentinel.
- Preflight found that direct `chatgpt.com` access timed out because 151 received an unusable DNS route. The first activation attempt stopped before changing policy.
- The existing workstation-backed proxy path was restored from `127.0.0.1:7890` through an SSH reverse tunnel to `172.29.0.1:17891` on 151.
- Worker proxy probes reached ChatGPT, Sentinel, and Emailnator; the Sentinel SDK download returned 200 through the configured proxy.
- Backup set: `/home/zeno-dev/upservice-ai-gateway-backups/20260715-093747-before-k12-proxy-activation`.
- `K12_AUTOMATION_ENABLED=true` and `K12_SENTINEL_ENABLED=true`; the legacy Worker UI remains disabled.
- Worker startup downloaded and cached the expected Sentinel SDK, then became healthy.
- Production Readiness returned `ready=true`, `configurationReady=true`, `executionEnabled=true`, no blockers, and only the expected Workspace-disabled warning.
- The authenticated New API control-plane request returned the same ready state. No registration task was created during activation.
- Windows scheduled task `Upservice-K12-OutboundProxy` restores the tunnel at user logon. Provider access still depends on the workstation proxy and network availability.
