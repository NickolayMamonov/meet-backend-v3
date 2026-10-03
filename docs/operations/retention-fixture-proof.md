# Retention fixture proof

This is a separately gated, protected Ubuntu proof path for the existing
test-VPS retention block. It is not the deployment workflow and does not
authorize provider, VPS, backup, restore, prune, deploy, catalog, or live
mutation. Ordinary CI must report the proof as deferred; a privileged CI
runner is not proof authorization.

The sole activation authority is
`.github/retention-proof-registration.json` fetched from the fixed
`refs/heads/master` ref through fresh authenticated Git Contents reads. The
initial record is disabled. A missing, disabled, incomplete, malformed, moved,
or substituted registration denies execution. Each checkpoint must bind the
same repository, ref, path, commit, selected tree, blob, and decoded-content
digest. GitHub Variables, cached checkout state, previous job outputs, and
additional credentials are not registration authority.

## Approval and preparation

Each attempt requires a fresh workflow dispatch and reviewer approval for the
exact attempt-1 tuple. Reruns are not authorized. The reviewer comment must
match `retention-proof:<run-id>:1:<tuple-sha256>`; generic environment
approval is insufficient. Registration, reviewed launcher revision, source,
plan, fixture/helper/toolchain inventory, exact successful ordinary-CI run,
and immutable image identity must all match the tuple.

Image and engine preparation are separate approvals. The proof remains
disabled until Ubuntu base/package snapshot and dependency pins, Dockerfile
digest, Engine version/API/layout, and prepared image digest have reviewed
provenance. The proof job cannot prepare infrastructure, modify protection,
or create a missing protected environment. The token is limited to
Contents/Actions reads and never enters the container.

## Isolation and evidence

The intended fixture runs only in a digest-pinned Ubuntu container with a
read-only source export, no network, fixed synthetic fixture root at
`/fixture`, bounded resources/output/deadlines, and owned-container cleanup.
The helper continues to extract and verify the existing workflow retention
block; it does not edit production guards or the remote block.

Only a closed, bounded, sanitized case summary may be retained. Missing or
incomplete case results, registration drift, failed barrier checks, output
overflow, timeout, signal, cleanup failure, or unverified container
destruction are failures, never a pass. Provider/VPS runtime, backup/restore,
protected incidents, dead-man monitoring, and live acceptance are independent
gates.

## Current status

The source tree contains only a disabled registration and incomplete toolchain
lock. No protected environment/registration, reviewed image preparation,
execution approval, privileged fixture, or runtime proof is present. Windows
control-plane checks cannot establish Ubuntu/Linux runtime behavior.
