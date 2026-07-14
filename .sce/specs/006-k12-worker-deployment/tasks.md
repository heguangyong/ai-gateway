# K12 Worker Deployment Integration - Tasks

## Phase 1: Governance and image pipeline

- [x] 1.1 Confirm the source/deployment repository boundary.
- [x] 1.2 Create the governed deployment Spec.
- [x] 1.3 Publish and record matching New API and Worker image digests.

## Phase 2: Runtime integration

- [x] 2.1 Add the internal K12 Worker service and persistence.
- [x] 2.2 Add New API-to-Worker environment configuration and startup ordering.
- [x] 2.3 Add runtime token and Worker image handling to the deployment script.
- [x] 2.4 Extend static checks and operator documentation.

## Phase 3: Verification

- [x] 3.1 Validate Compose structure with a YAML parser.
- [x] 3.2 Run deployment static checks and secret scans.
- [x] 3.3 Record local verification evidence.
- [x] 3.4 Commit and push the deployment branch.

## Phase 4: Canary and production

- [x] 4.1 Back up the current runtime and record active image digests.
- [ ] 4.2 Deploy an isolated canary with separate Worker data paths.
  - Not performed. The user explicitly authorized a direct production replacement on 2026-07-14.
- [ ] 4.3 Review canary evidence and obtain user approval.
  - No canary evidence exists. Direct production approval and compensating checks are recorded in the deployment report.
- [x] 4.4 Deploy pinned images to production and verify rollback.
  - Deployment passed. Backup configuration, database integrity, and the retained previous image were verified; rollback was not exercised.
