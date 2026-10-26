# Timepad token configuration (manual, feed OFF)

`configure-test-vps-timepad-token.yml` uses the `TIMEPAD_TOKEN` Actions secret
in environment `test-vps`. Adding the secret alone does not configure the VPS.
The workflow is manual and `dev`-only; merge, dispatch and provider access
require separate operator approval. It targets only the confirmed test VPS.

Before uploading or executing a helper as root, the workflow checks every staging
ancestor for root ownership, no group/world write access, no symlinks and no ACLs,
then creates a root-only private directory. It verifies existing SSH host trust
and the staged helper checksum,
then sends the token through SSH stdin. It never prints the value, places it
in command arguments, uploads it as an artifact or stores a runner token file.

The helper requires the existing deployment lock, no unresolved provider/SMTP
transaction, a private root-owned environment file and the healthy single
approved 1.5.0 backend with both Timepad and ingestion OFF. It inspects the exact
sole running backend ID and verifies its Compose project/service labels. It makes one
authenticated HTTPS request to the fixed Timepad events endpoint with the
production query, no redirects and finite body/time bounds.

Only a successful JSON response with the expected total/page shape permits
atomic configuration of `TIMEPAD_TOKEN` in `/opt/meet-backend/.env.production`.
Other configuration bytes are preserved; failure before publication preserves
the previous token. `token_stored_durability_uncertain` means publication occurred
but durability confirmation failed: stop and inspect, do not blindly retry.

No backend restart, migration, import, feed enablement, binary rollback or
credential transaction cleanup occurs. The running container retains its old
environment until a separately approved restart/enable operation.

HTTP 200 and token configuration are NOT catalog acceptance. A response total
above 500 is reported as outside the current discovery budget, not silently
truncated. Provider policy, complete observation, import and visible catalog
must still be verified. Never weaken the budget or filters to populate the app.

## Optional LocationIQ fixture diagnostic

The same manual workflow has a `mode` choice. The default, `timepad-token`,
retains the behavior above. `locationiq-diagnostic` runs only the bounded
LocationIQ diagnostic helper against its fixed fixture; it does not modify
Timepad coordinates, call the Timepad API, change application configuration, or
write to the database. The public Timepad URL identity is not treated as
evidence about any unexposed database field.

The fixed fixture is backend meeting ID 7 and the exact external URL
`https://centicore-group.timepad.ru/event/4178295/` (terminal slash optional).
The helper reads this public meeting, then conditionally requests LocationIQ, without updating the
event; events that already have coordinates are skipped. Requests use fixed
phase deadlines (15 seconds each) within a 40-second helper budget, a 45-second
remote-child timeout plus 2-second kill grace, and a 48-second SSH timeout
plus 2-second kill grace. Captured output is capped at 8 KiB. The diagnostic
is not geocoding acceptance: a coarse or otherwise uncertain result must not
be presented as ready.

The diagnostic mode receives `LOCATIONIQ_KEY` only in its guarded step and
passes it to the remote helper over SSH stdin. The workflow stages and
checksum-verifies only that helper and the shared file-trust module, with the
same private staging and strict host trust protections. The remote process
disables core dumps and Python bytecode; the helper has a 45-second timeout
with a 2-second kill grace, and its SSH parent is limited to 48 seconds plus a
2-second kill grace. Staged files are removed individually and the directory
must then be empty for cleanup to succeed.

Diagnostic results may include only the explicitly approved public component
exception: road/house/structure text capped at 128 code points may appear in
Actions logs. Coordinates, the key, raw JSON, full address, user prose, and
other location data must not appear in artifacts, summaries, environment
files, command arguments, or logs. This source-only change has not run the
workflow, contacted LocationIQ, accessed a VPS/device, or performed a
production check; none of those actions was authorized.

Source verification is not dispatch readiness. A future run requires separate
exact-ref/mode and fixed conditional two-GET/output/cleanup permission, fresh
registered-workflow/protection admission, and operator confirmation of secret
custody. This change neither checks secret inventory nor establishes that the
secret has been added.

## LocationIQ key delivery with geocoding held OFF

`locationiq-delivery-off` is a separate manual mode in the same protected
CONFIG workflow. It stages and checksum-verifies only
`configure-test-vps-locationiq.py` and the shared file-trust module, then
passes `LOCATIONIQ_KEY` to that helper over SSH stdin. It performs no
LocationIQ/provider request, Timepad request, restart, recreate, Compose-up,
import, or geocoding enablement. The workflow retains strict SSH host trust,
the `test-vps` environment and shared deployment lock; its selected helper
and trust module must be removed individually and staging cleanup must succeed.

The helper validates the existing deployment/runtime and environment-file
trust, accepts only bounded safe key material, and atomically publishes
`LOCATIONIQ_KEY` together with an explicit `GEOCODER_ENABLED=false`. An absent
key may be set; an identical key is idempotent; a conflicting nonempty key
rejects the whole operation without rotation. A missing enable flag is added
as false; canonical true is set false; false remains false; malformed or
duplicate controlled assignments reject the operation. Other environment
bytes and line endings are preserved. An already active geocoder or runtime
identity/state mismatch is rejected; the persistent file alone does not prove
the already-running process environment is OFF.

The delivery mode does not restart or recreate the process, so it does not
activate a key in the running backend. If publication occurs but durability
confirmation fails, the helper reports an uncertain-published outcome and
exits nonzero: stop and reconcile before any retry. No automatic restore,
restart, or enable action is part of this mode. Any future activation requires
separate authority and a reviewed sequence bound to the approved new backend
deployment window; this delivery mode cannot enable geocoding.

## LocationIQ enable-only for an approved deployed image

`locationiq-enable-only` is a separate manual CONFIG workflow mode. It accepts
only five non-secret values: the approved source commit SHA, repository image
digest, local image ID, canonical application version, and deployment run key
(`run-attempt`). Obtain each from reviewed source/deployment evidence for the
exact deployment; do not infer an image ID from a digest or reuse a tuple from
another run. The workflow validates formats before SSH and passes individually
quoted scalar arguments. It does not accept or transfer `LOCATIONIQ_KEY`.

Before enablement, the approved new image must already be deployed and healthy
with persistent `GEOCODER_ENABLED=false`, and the running backend must have
been verified OFF. The helper validates that tuple and locked runtime/file
state, then performs one same-image Compose recreate. This is global backend
activation, not a one-request test: normal application traffic can make
LocationIQ calls afterward. This workflow grants no dispatch or activation
authority; that consequence requires separate operator authorization.

The helper owns its bounded manual-stop boundary. Rejection, uncertainty, or
manual intervention must be reconciled before retry; the workflow does not
roll back, restore configuration, or rerun the helper. `committed` requires a
successful SSH exit and valid bounded helper status JSON. Missing, malformed,
truncated, or transport-failed status is unknown. Late staged-file or runner
SSH-material cleanup failure is workflow intervention/failure while
preserving the observed helper outcome; it does not mean the helper's
manual-stop path ran. This mode performs no provider probe or credential
rotation.

## First v1.6.0 deployment with pending LocationIQ key held OFF

The provider-release workflow has a separate `apply_pending_locationiq_off`
opt-in, default false. It is narrowly bound to the reviewed v1.6.0 source,
release and image tuple and requires `failure_policy=manual-stop` with the
rollback drill disabled. All ordinary deployments retain strict environment
matching. This exception is not inferred from key presence and does not permit
credential writes, key rotation, enabling geocoding, or restarting the old
image.

The transition is intended to carry the already-pending canonical key and an
explicit `GEOCODER_ENABLED=false` through one deployment of the approved new
image. The deployment proves the candidate is a new healthy instance with the
same intended key explicitly OFF before commit. No provider API call or
migration is added by the exception; existing public health probes and the
workflow's existing retention behavior still apply. Manual-stop means
post-mutation uncertainty requires operator reconciliation; there is no
automatic rollback or restoration of prior configuration. The opt-in only
selects the narrowly defined predecessor-comparison policy and grants no
dispatch, target-access, or activation authority by itself.

Existing startup Flyway migrations can still change the database; named database
and upload volumes are preserved, not read-only. Existing ingestion and Timepad
settings remain effective (including scheduled ingestion when enabled); OFF
geocoding is not an ingestion freeze. Existing Firebase credential validation
and private snapshots remain, without a provider API test or credential rotation.
The successful no-drill path retains its public probes, including unauthorized
and wrong-key bootstrap rejection checks. Retention can remove older eligible
owned states/tooling and can fail after service commit; such a late failure does
not prove the backend stopped. A completed stop command likewise is not a
verified-stop guarantee.
