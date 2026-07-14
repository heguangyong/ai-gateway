# K12 Worker Deployment Integration - Requirements

## 1. Objective

Deploy the K12 automation capability as part of the existing AI Gateway runtime while preserving New API as the only user-facing control plane.

## 2. Functional Requirements

### 2.1 Immutable application images

- SHALL deploy a New API image built from the K12 control-plane source branch.
- SHALL deploy a separate K12 Worker image built from the same source commit.
- SHALL allow both images to be pinned by digest during canary and production deployment.

### 2.2 Internal Worker boundary

- SHALL expose the Worker only to the Compose network on port 8796.
- SHALL NOT map a Worker port to the host.
- SHALL share one runtime-only internal token between New API and the Worker.
- SHALL persist Worker data and JSON output outside the container.
- SHALL keep automation, Sentinel, and the legacy Worker UI disabled by default.

### 2.3 Deployment operations

- SHALL generate or load the K12 internal token from ignored local secret storage.
- SHALL transfer the token to the remote runtime without printing or committing it.
- SHALL start the Worker before New API and require a healthy Worker.
- SHALL preserve the existing Nginx shell gate and Cloudflare service naming.

### 2.4 Verification and release

- SHALL validate Compose structure, secret boundaries, image parameters, and deployment scripts locally.
- SHALL record GitHub Actions image digests before canary deployment.
- SHALL NOT change the production host until canary evidence is reviewed.

## 3. Non-Goals

- Do not merge New API application source into this deployment repository.
- Do not expose the legacy K12 web interface.
- Do not enable account automation or Sentinel during deployment integration.
- Do not commit private hosts, SSH identities, passwords, provider credentials, or internal tokens.
