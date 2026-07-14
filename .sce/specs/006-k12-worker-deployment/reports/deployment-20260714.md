# K12 Worker Production Deployment - 2026-07-14

## 1. Authorization and scope

- The user explicitly authorized replacing the existing production New API deployment.
- The required iteration order was followed: local verification, GitHub push, then production synchronization.
- The production access mode remained `public`.
- The existing Cloudflare token-mode connector was preserved.
- K12 automation, Sentinel, and the legacy Worker UI remained disabled.

## 2. Release identity

- New API source commit: `610d9f8bd4a1fb3434e6ed5b0f930742c9ae7523`
- Deployment code commit: `d957bb498eea99da4d0b79e0391797461c734ca8`
- New API image: `ghcr.io/heguangyong/new-api@sha256:c27f6262173093c15034843a1a2a4756b0a2f555cb054f9a9ff62efecdb36068`
- K12 Worker image: `ghcr.io/heguangyong/new-api-k12-worker@sha256:0ee31f82f70e61cdaab6011f6cc869c9865213730385c9357b6904b37e4c0e0e`
- Reported runtime version: `k12-610d9f8bd4a1`

## 3. Predeployment controls

- The existing local and public status endpoints returned `200`.
- The active database was backed up with the SQLite backup API and passed `PRAGMA integrity_check`.
- Configuration, Compose files, Nginx templates, scripts, and the prior database were retained in backup set `20260714-085420-k12-upgrade`.
- The prior New API image was recorded as `ghcr.io/heguangyong/new-api@sha256:9952a89f0b22b137b9821c45796429a2ef63d6144e78089569ffbb330d6efb54`.
- Local and remote shell-token and session-secret fingerprints matched before deployment.
- The deployment pull scope was restricted to New API and K12 Worker so mutable Nginx and Cloudflare images were not updated.

## 4. Deployment iteration

1. The first pinned-image rollout started all services successfully.
2. A postdeployment network probe found that an inherited `AI_GATEWAY_NO_PROXY` value omitted `k12-worker`, causing backend-to-Worker traffic to use the outbound proxy.
3. The deployment script was updated locally to append `k12-worker` idempotently, validated with three migration fixtures, committed, and pushed to GitHub.
4. Production was synchronized again from commit `d957bb4`; the backend then reached the Worker directly.

## 5. Postdeployment verification

- Compose runtime rendering: passed.
- Nginx proxy, New API backend, K12 Worker, and Cloudflare connector: running; all services with health checks were healthy.
- Backend-to-Worker authenticated request: passed.
- Worker health, unauthenticated summary, and authenticated summary returned `200`, `401`, and `200` respectively.
- New API and Worker internal-token fingerprints matched.
- Worker port `8796` had no host publication.
- `K12_AUTOMATION_ENABLED=false`.
- `K12_SENTINEL_ENABLED=false`.
- `K12_WEB_UI_ENABLED=false`.
- Live database `PRAGMA integrity_check`: passed.
- Local and public status endpoints returned `200` after deployment.
- Unauthenticated New API K12 route returned `401`, confirming the admin boundary.
- Existing service token listed 25 models and retained the configured default model.
- Worker, backend, and proxy alert-log scans returned no errors.
- The Cloudflare connector retained its predeployment container identity.
- Remote deployment files matched local SHA-256 fingerprints.

## 6. Rollback readiness

- The backup Compose configuration renders successfully with the backed-up runtime environment.
- The previous New API image remains available on the production Docker host.
- Remote temporary secret-transfer files were removed.
- Rollback was not exercised because all production verification gates passed.

## 7. Governance deviation

- The original Spec required an isolated canary before production.
- The user explicitly authorized a direct production replacement, so canary tasks 4.2 and 4.3 remain unchecked rather than being reported as completed.
- Compensating controls were a live SQLite backup, immutable image digests, preservation of the existing connector, application-only image pulls, staged health checks, and retained rollback artifacts.

## 8. Outcome

Production deployment and verification completed successfully. Future iterations should continue the same local verification, GitHub push, pinned-image synchronization, and postdeployment evidence sequence.
