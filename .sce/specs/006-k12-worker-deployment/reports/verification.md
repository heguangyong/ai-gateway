# K12 Worker Deployment Integration - Verification

## 1. Release identity

- Verification date: 2026-07-14
- New API source commit: `610d9f8bd4a1fb3434e6ed5b0f930742c9ae7523`
- GitHub Actions run: [29295757393](https://github.com/heguangyong/new-api/actions/runs/29295757393)
- Workflow conclusion: `success`
- New API image: `ghcr.io/heguangyong/new-api@sha256:c27f6262173093c15034843a1a2a4756b0a2f555cb054f9a9ff62efecdb36068`
- K12 Worker image: `ghcr.io/heguangyong/new-api-k12-worker@sha256:0ee31f82f70e61cdaab6011f6cc869c9865213730385c9357b6904b37e4c0e0e`

Both images were published by the same workflow run from the same source commit.

## 2. Source verification

- K12 Worker TypeScript build: passed.
- K12 Worker security tests: 6 passed, 0 failed.
- Container smoke test: health response accepted, unauthenticated summary returned `401`, and authenticated summary returned `200`.

## 3. Deployment repository verification

- `scripts/deploy.ps1` PowerShell parser: passed.
- `scripts/check.ps1` PowerShell parser: passed.
- Base and Cloudflare overlay Compose files parsed with the `yaml` package: passed.
- Structural assertions: Worker has no host `ports`, exposes `8796`, backend waits for Worker health, both services share the token interpolation, and all automation switches default to disabled.
- `scripts/check.ps1`: 23 checks passed.
- Changed-file credential scan: passed.
- `git diff --check`: passed.

Docker Compose runtime rendering was not executed locally because the Docker CLI is unavailable on this workstation. YAML parsing and explicit structural assertions cover the changed Compose contract.

## 4. Release progression

- This file records the predeployment verification boundary at the time it was created.
- A subsequent direct production deployment was explicitly authorized and completed on 2026-07-14.
- K12 automation, Sentinel, and the legacy Worker UI remain disabled.
- See `deployment-20260714.md` for deployment evidence and the documented canary exception.
