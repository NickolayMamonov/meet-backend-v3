# Test VPS deployment

The **Deploy backend release to test VPS** workflow is the manual promotion
path for the current test edge at `api.whysoezzy.online`. It is independent
from Release Please and never publishes or changes a GitHub Release, tag, or
GHCR alias.

Dispatch the workflow from `dev` with a published immutable release tag. The
default `v1.2.0` run verifies release ID, source, immutable-release attestation,
all four release assets, OCI index bytes, image labels, provenance, SBOM, and
the exact image digest before contacting the VPS.

The protected `test-vps` Environment supplies:

- `TEST_VPS_HOST`, `TEST_VPS_PORT`, `TEST_VPS_USER`, and `TEST_VPS_PATH`;
- `TEST_VPS_SSH_HOST_FINGERPRINT`;
- secret `TEST_VPS_SSH_PRIVATE_KEY`.

The SSH key and any application credentials remain outside the repository.
The workflow pins host trust to the configured SHA-256 fingerprint and stages
checksum-bound tooling for each run.

## Rollback drill

Keep **Prove automatic rollback before the final deployment** enabled for the
first promotion to a new image. The drill requires the candidate image to
differ from the running predecessor. It starts the verified candidate, checks
its exact image/runtime/volume/network contract, deliberately exits with the
reserved drill status, and relies on the remote deployment trap to restore the
captured predecessor. The workflow then verifies the restored image ID before
performing the final successful deployment.

Routine redeployment of an image that is already running must disable the
drill; a same-image rollback is intentionally rejected because it proves
nothing.

## Test-edge constraints

This path preserves the named PostgreSQL and uploads volumes, keeps PostgreSQL
unpublished, and binds the backend only to loopback. It changes only the three
release identity fields in the existing `.env.production`; it does not replace
application secrets or durable configuration.

The current backend security configuration does not expose Actuator publicly.
The workflow therefore installs a test-only Compose health override that probes
`/meetings`. Final evidence still requires:

- healthy exact-digest container running as `10001:10001`;
- `meet-production_postgres_data` and
  `meet-production_uploads_data`;
- loopback-only backend and no PostgreSQL host port;
- HTTPS `/meetings` returning `200` JSON;
- HTTPS `/actuator` returning `404`;
- HTTP redirecting to HTTPS with normal CA validation.

This is not the production workflow. It intentionally does not claim the
production backup/off-host recovery infrastructure required by
[`docs/production-deployment.md`](../production-deployment.md).

## Immutable v1.2.0 checksum exception

Public immutable release ID `371012814` has a known `SHA256SUMS` formatting
defect: each record is `64 lowercase hex characters + filename`, without the
standard two-space separator. The bytes cannot be replaced. Deployment uses a
strict exception limited to that numeric release ID, exactly three expected
filenames, and matching downloaded-byte digests. Future releases must use the
canonical `sha256sum` format and are rejected if they use the compact form.

## Bounded retention

After final runtime and public evidence passes, the workflow acquires the same
remote deployment lock, removes only checksum-bound
`.test-vps-tooling-<run>-<attempt>` directories, and retains the ten newest
deployment-state directories under `/var/lib/meet-test-vps-deploy`. Failed
runs remain available until the next successful deployment applies retention.
The active Compose/runtime files under `/var/lib/meet-production` are outside
the cleanup roots and must still exist after cleanup.

## Yandex SMTP transaction workflow

The **Configure Yandex SMTP on test VPS** workflow is the only supported path
for changing email runtime fields. It must be dispatched from `dev` and uses
the protected `test-vps` Environment. Configure these secrets without
disclosing them in task text, shell arguments, workflow output, summaries, or
artifacts:

- `TEST_VPS_SMTP_FROM` and `TEST_VPS_SMTP_FROM_NAME`;
- `TEST_VPS_SMTP_USERNAME` and `TEST_VPS_SMTP_PASSWORD`;
- `TEST_VPS_SMTP_CONNECT_TIMEOUT_MS`,
  `TEST_VPS_SMTP_READ_TIMEOUT_MS`, and
  `TEST_VPS_SMTP_WRITE_TIMEOUT_MS`.

The workflow builds a mode-0600 NUL-delimited payload, changes only the
SMTP/email allowlist, and uses `smtp.yandex.ru:587` with the application's
authenticated STARTTLS and certificate-hostname checks. It never changes
database settings, HMAC/JWT keys, volumes, image/release identity, Compose
topology, or public releases. The remote operation holds the existing
`/var/lib/meet-test-vps-deploy/.deploy.lock` for its complete lifetime and
recreates only `backend`.

### Durable transaction and startup rules

The remote state root contains one mode-0600
`.smtp-transaction.current` selector and a mode-0700 transaction directory.
Journal transitions are complete mode-0600 records replaced through a sibling
temporary file, file sync, atomic rename, and transaction-directory sync.
`COMMITTED` is one complete `critical=false`,
`deploy_succeeded`, status `0` record. `RECOVERED` is one complete
`critical=false`, `deploy_failed_rollback_succeeded`, status `22` record.
There is no durable phase-before-result state.

On startup:

1. No pointer permits normal preflight.
2. A proven precritical `SNAPSHOTTED` transaction clears and syncs the pointer
   before deleting its now-unreferenced transaction.
3. Any critical/pre-commit phase is recovery-only. It restores and verifies
   the exact environment, runtime fingerprint, and tagged prior selector
   (`absent` or `present`), then records `RECOVERED`/22.
4. A valid terminal `COMMITTED` or `RECOVERED` record is finalized only; it is
   never replayed as a new deployment.
5. Malformed pointers, symlinks, directories, FIFOs, missing transactions,
   invalid phases, incomplete terminal tuples, and hash mismatches preserve
   evidence and fail closed with `deploy_failed_rollback_failed`/23.

The last-good store contains immutable mode-0600 `env` and safe manifest files
under mode-0700 generation directories, selected by one atomic synced
`.smtp-last-good.current` pointer. A first-generation absence is a legitimate
state. `rollback_last` returns `precheck_failed`/20 without mutation when no
selector exists; after a generation exists, it is idempotent. The manifest
binds the generation name, environment hash, non-email configuration hash,
full and non-email runtime fingerprints, and release image/version/revision.
The non-email fingerprint covers the backend and PostgreSQL identities,
health/hardening, volumes, network/port topology, active Compose files, and
release tuple, so a stale generation cannot replace a later database, release,
HMAC/JWT, TIMEPAD, or other non-SMTP configuration. Recovery also verifies the
full pre-state fingerprint after restoring the protected snapshots.

The fake-remote interruption matrix exercises every journal and pointer
publication boundary under `TERM`, `INT`, `HUP`, `SIGKILL`, and reboot-like
fresh-process recovery. It accepts only complete old/new records, never
replays a requested operation from a critical record, and preserves malformed
or incomplete material for operator inspection.

Release deployment and bounded retention acquire the same lock and reject
every present `.smtp-transaction.current` object before creating run state,
snapshotting, mutating Docker/Compose, enumerating retention, or deleting
anything. Only the SMTP workflow may reconcile that pointer. Pointer clear and
state-root sync always precede transaction deletion.

The five remote results are:

| Category                           | Status | Meaning                                        |
| ---------------------------------- | -----: | ---------------------------------------------- |
| `deploy_succeeded`                 |      0 | Verified SMTP configuration committed          |
| `precheck_failed`                  |     20 | No live mutation was authorized                |
| `lock_busy`                        |     21 | Another deployment owns the canonical lock     |
| `deploy_failed_rollback_succeeded` |     22 | Exact pre-state restored                       |
| `deploy_failed_rollback_failed`    |     23 | Evidence preserved; operator recovery required |

The workflow accepts exactly one result line and the matching SSH status.
Missing, duplicate, malformed, unknown, or mismatched output fails closed and
skips retention. If SSH is lost after the remote pointer was durably cleared,
the result is **client-acknowledgment ambiguity**, not an inferred rollback.
Do not dispatch again until an authorized operator inspects only safe evidence:
pointer presence/absence, exact config and runtime hashes, selected generation
integrity, image/release identity, backend health, and public edge invariants.
Record no mailbox address, password, OTP, JWT, refresh token, provider token,
database credential, or response body.

After controlled canary approval, request delivery to the protected mailbox,
verify the existing auth response privately, rotate refresh credentials and
reject the old one, then logout and reject the rotated credential. Record only
safe success booleans and status categories.

## Closed-beta promotion from `dev`

The closed-beta promotion workflow is registered on `master` only so GitHub
can discover it, but it must be dispatched explicitly with
`gh workflow run promote-dev-digest-to-test-vps.yml --ref dev -f source_sha=<40-hex-dev-sha>`.
The run proves that the event is `workflow_dispatch`, the ref is exactly
`refs/heads/dev`, the run head SHA equals the input SHA, the detached checkout
is clean, the current remote `origin/dev` and source tree match, and the
master registration blob is byte-identical to the reviewed `dev` workflow.
It also requires a successful exact-SHA CI run before any writer is reached.

Only `test-sha-<source-sha>` is admissible. The read-only admission step
requires the Linux/amd64 image identity, source/revision/version labels,
provenance, SBOM, GitHub attestation, and complete referrer closure. Protected
release, ref, asset, alias, digest, and subject state is captured first;
candidate root/platform/evidence subjects are excluded from that closure
before any copy or attestation writer is allowed to run.

The remote deploy remains locked and exact-digest based. Candidate and
predecessor bootstrap proofs are bound to the exact source tree, boot JAR
properties, image digest, and image ID. A distinct-image rollback drill must
return exit 86 and restore the exact predecessor before final deployment;
same-image redeploys are explicit and cannot claim rollback proof. Closed-beta
phase files use closed schemas, fixed paths, and mode/type/owner/size/hash
validation. Every failed mutation or verifier selects sanitized incident
evidence and leaves retention unauthorized. Retention is authorized only
after final verification, required rollback policy, evidence sanitation, and
artifact upload all succeed.
