# Closed-beta backup and restore proof

This manually dispatched, one-shot drill captures one quiesced PostgreSQL
custom dump and uploads tree, encrypts both streams directly with age before
transfer, publishes one unique GitHub Actions artifact with exactly 30 days of
retention, and restores only on a reviewer-approved ephemeral Ubuntu runner.
The capture artifact contains exactly `postgres.dump.age`,
`uploads.tar.gz.age`, and `recovery-point.json`; the aggregate proofs and
runtime fingerprint are embedded only in that manifest.

The capture job has `test-vps` SSH and only the public age recipient. The
protected `closed-beta-restore` job has only the private age identity and no
test-VPS variables, route, active-volume name, or host path. The pre- and
post-restore probes have SSH only. Dispatch requires a new recovery ID and the
exact current `dev` SHA; restore additionally requires the numeric artifact ID.
Authorization proves only the source, CI, workflow registration, dispatch, and
protected Environment policy through supported read-only GitHub APIs. It does
not enumerate Environment secrets or claim that the private identity exists.
After reviewer approval, the restore runner provisions and canaries its pinned
age toolchain, then revalidates the source before the one step that materializes
the private identity.

At each SSH boundary, the runner performs one bounded RSA key scan for the
configured host and port, verifies that key against the configured SHA-256
fingerprint, and uses the resulting temporary known-hosts record with strict
checking. The private key, empty SSH configuration, generated known-hosts file,
and staging directory are removed on every exit path. Malformed configuration,
scan or parser failure, ambiguous or unexpected key output, fingerprint
mismatch, unsafe path, timeout, and publication collision fail closed before
SSH/SCP or downstream recovery work.

A mismatch or host-key rotation requires out-of-band review, an approved
fingerprint update, and a new authorized run. Do not trust a scanned key,
enable TOFU or `accept-new`, retry or rotate automatically, or resume the
failed August 28, 2026 capture.

The protected `TEST_VPS_PATH` Environment value is the release and Compose
root. It must already exist on the test VPS and contain the non-empty,
non-symlink `.env.production` consumed by Compose. It is distinct from the
runtime state root `/var/lib/meet-production`, which owns active and captured
runtime files, and from the shared serialization lock
`/var/lib/meet-test-vps-deploy/.deploy.lock`. Missing, unsafe, or incomplete
release-root configuration requires correction on the VPS or in the protected
Environment, followed by a new authorized run; there is no fallback and failed
runs are not resumed.

Capture holds `/var/lib/meet-test-vps-deploy/.deploy.lock` only for the bounded
snapshot and runtime recovery section. It rejects an active SMTP transaction,
proves a healthy populated runtime and HTTPS edge, and uses fixed
`postgres.dump.age` and `uploads.tar.gz.age` names in a fresh mode-0700
run-owned directory. Plaintext never leaves the VPS.

Capture-local journals are not global gates. A fresh process validates their
schema, digest, recovery ID, and owned paths. An unchanged interrupted runtime
is restarted and terminalized as `incident_resolved`. A healthy independent
runtime replacement is preserved and terminalized as `superseded` only after
the captured container is absent or safely detached. Both paths remove only
capture-owned private/staging state, are idempotent, and admit a new recovery
ID. Malformed, forged, running, or ambiguous state blocks.

Before private identity access or Docker mutation, restore checks unsigned
capacity requirements:

```text
temp_required = 2 * encryptedPairBytes + postgresDatabaseBytes
                + uploadsPlaintextBytes + 2 GiB
docker_required = 4 * postgresDatabaseBytes + 5 GiB
```

Each required filesystem must retain 20 percent after its requirement. The
pinned PostgreSQL 16 image must declare exactly
`/var/lib/postgresql/data` as its only image volume. The restore creates no
operator-supplied mount and accepts only one inspected read-write anonymous
volume at that destination. Bind, named, production, duplicate, missing, or
unexpected mounts fail before start.

The identity is parsed and both ciphertexts are decrypted into a private
mode-0700 directory before any Docker command. Missing, empty, malformed,
wrong-mode, wrong-key, or failed-second-decrypt inputs remove the identity and
private plaintext without Docker activity or successful restore evidence.

Dump listing, restore, the read-only V1-V9 database proof, uploads aggregate,
and every managed media reference must match. Always-run cleanup removes the
identity, decrypted data, references, container with `--volumes`, captured
anonymous volume, and internal network. Docker proves all three are absent
before `cleanup_complete`; failure blocks success and retains only minimum
mode-0600 volume identity state for a fresh-process retry.

The no-identity post-probe runs only after isolated cleanup ends. A successful
drill requires healthy, exactly equal sanitized runtime and HTTPS fingerprints
before and after restore. Mismatch or health failure blocks final evidence and
does not roll back the VPS. Secret-free evidence binds the artifact and
contract digests, equality proofs, mount contract, volume absence, probes,
observed recovery-point age, and dispatch-to-post-probe RTO of at most
7200 seconds. This is not recurring automation or an ongoing RPO guarantee;
recurring backup belongs to MEE2-63.
