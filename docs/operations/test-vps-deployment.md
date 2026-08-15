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
