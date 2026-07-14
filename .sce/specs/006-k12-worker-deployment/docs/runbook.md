# K12 Worker Deployment Runbook

## Preconditions

- Matching New API and K12 Worker image digests are available.
- The deployment workstation has SSH/SCP access and ignored secret storage.
- Automation and Sentinel remain disabled.

## Canary

1. Record the current New API image digest and database backup.
2. Use separate canary host ports and Worker data directories.
3. Set both image parameters to digest references from the same source commit.
4. Verify Worker health, New API `/api/status`, K12 read-only status, and Nginx access behavior.
5. Stop the canary and retain its evidence before any production change.

## Rollback

1. Restore the previous `NEW_API_IMAGE` digest.
2. Stop `k12-worker` without deleting its data directories.
3. Restart `new-api-backend` and the Nginx proxy.
4. Verify the existing gateway API and channel pool.
