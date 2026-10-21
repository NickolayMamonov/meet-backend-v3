# Timepad MVP first-launch operations

The feed is source-disabled by default. This document is operational guidance,
not launch approval. Do not enable `TIMEPAD_ENABLED` until the operator has
separately approved the exact image, schema compatibility, asset URL, and
single-instance deployment.

## Preconditions

- Confirm the immutable backend image and source revision match the reviewed
  release, and that its additive V11 migration is compatible with the deployed
  database. Existing Timepad rows remain hidden until a complete observation
  accepts them.
- Publish and verify the three owned assets at
  `{TIMEPAD_ASSET_BASE_URL}/timepad-assets/v1/{it,product,design}.png` over
  HTTPS. The configured base URL has no path, query, fragment, or credentials.
- Keep `TIMEPAD_ENABLED=false` until launch approval. Configure any provider
  token only through the deployment secret store; never place it in a command,
  ticket, log, or this runbook.
- Run exactly one backend instance while Timepad scheduling or admin ingestion
  can run. The admission guard is process-local and is not a distributed lock.
- Before the first migration-capable startup, disable every competing
  automatic deployment or rollback route, including `deploy-production`,
  `promote-dev-digest-to-test-vps`, and legacy deployment/SMTP
  reconfiguration paths. Record the disabled state with the release evidence.
  Only the reviewed `manual-stop` deployment path is authorized afterward.
  This operational restriction is not a security boundary: an operator able to
  run an old script can bypass it. If that path cannot be isolated, do not
  launch.

## Failure handling

The first cutover predecessor does not enforce Timepad visibility. Automatic
binary rollback after V11 may therefore expose stale rows. The first release
must use `failure_policy=manual-stop`; the rollback drill is incompatible and
must remain disabled. Once deployment mutation begins, a failure stops the
backend and reports `manual_intervention_required`. Diagnose manually and
restore service only with a separately reviewed forward image that preserves
the visibility contract.

There is no automatic rollback, database reset, down migration, destructive
restore, or volume removal. A failed stop is an incident, not a successful
recovery. Feed disablement does not immediately hide rows already accepted:
their eligibility expires 72 hours after the last complete accepted snapshot.
For emergency withdrawal, stop the backend.

## Limits and evidence

The feed fails closed on incomplete snapshots and bounded catalog limits.
No qualifying catalog is not evidence of success; do not invent events or
weaken policy to populate the app. The 72-hour expiry bounds stale exposure
since the last accepted observation, not organizer truth. Repeatedly accepted
misleading facts and already in-flight push sends cannot be recalled.

Provider access, credentials, live import, VM use, production migration, and
actual enablement require separate operator authorization. This source change
does not claim those checks have occurred.
