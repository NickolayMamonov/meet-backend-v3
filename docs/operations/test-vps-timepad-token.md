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
