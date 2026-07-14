# K12 Worker Deployment Integration - Design

## 1. Repository Boundary

```text
heguangyong/new-api
  -> New API image
  -> K12 Worker image

heguangyong/ai-gateway
  -> Nginx shell gate
  -> New API backend
  -> internal K12 Worker
```

Application code remains in `new-api`. This repository owns only image selection, runtime secrets, persistence, service ordering, verification, and rollback.

## 2. Runtime Topology

```text
Browser / API client
  -> Nginx shell gate :3000
  -> New API backend :3000
  -> http://k12-worker:8796
  -> K12 data and JSON bind mounts
```

The Worker has `expose: 8796` and no `ports` entry. New API sends an internal bearer token over the Compose network. The browser only calls `/api/k12/*` on New API.

## 3. Images

- `NEW_API_IMAGE` selects the application image.
- `K12_WORKER_IMAGE` selects the Worker image.
- Deployment accepts tags for development but canary and production use digest references.
- Both images originate from the same New API source commit.

## 4. Secret Flow

The local ignored file `secrets/k12-internal-token.txt` contains a generated random value. The deployment script copies it to a temporary remote file, writes `K12_INTERNAL_TOKEN` into the remote `.env`, and removes the temporary file. It must not appear in logs or committed files.

## 5. Startup and Health

1. Compose starts `k12-worker`.
2. The Worker health check calls `http://127.0.0.1:8796/healthz`.
3. `new-api-backend` waits for the Worker health condition.
4. The Nginx proxy waits for New API health as before.

## 6. Rollback

Pin the previous New API digest, stop the Worker, and retain `data/k12` plus `data/k12-json`. The existing New API database and Nginx shell-gate configuration are not replaced during rollback.
