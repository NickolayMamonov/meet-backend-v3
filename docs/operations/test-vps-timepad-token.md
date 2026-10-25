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
