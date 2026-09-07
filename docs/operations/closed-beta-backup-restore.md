# Closed-beta backup and restore proof

This manually dispatched, one-shot drill captures one quiesced PostgreSQL
custom dump and uploads tree, encrypts both streams directly with age before
transfer, publishes one unique GitHub Actions artifact with exactly 30 days of
retention, and restores only on a reviewer-approved ephemeral Ubuntu runner.
The capture artifact contains exactly `postgres.dump.age`,
`uploads.tar.gz.age`, and `recovery-point.json`; the aggregate proofs and
runtime fingerprint are embedded only in that manifest.

The capture job provisions and canaries the repository's pinned age executable
in ephemeral runner storage, then transports exactly that one mode-0755
encryption binary with the reviewed capture scripts and only the public age
recipient. The capture VPS admits the absolute staged path, owner, mode,
platform, exact version, and SHA-256 before taking the deploy lock, probing
runtime state, creating a journal, or stopping the backend. The beta backup
consumer rechecks that the operand is already canonical and non-symlinked and
verifies the same SHA-256 immediately before either encryption stream. Capture never uses
an ambient `PATH` age, a VPS package/download, `age-keygen`, or a private
identity. The
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
SSH receiver or downstream recovery work.

Restore pre- and post-probes use `scripts/run-beta-recovery-remote-probe.sh`.
The helper stages the checked-out `probe-test-vps-recovery-runtime.sh` and
`production-compose.sh` into a unique, phase-bound, marker-authenticated remote
directory, then admits each file by checksum, regular-file type, link count,
owner, and numeric mode before taking the deployment lock or executing the
probe. It never falls back to a persistent recovery script under the deploy
directory. Cleanup removes only a directory authenticated by this recovery's
marker; existing, foreign, symlinked, ambiguous, or drifted state is preserved
and fails the run, while owned state is removed after success, failure,
SSH receiver ambiguity, or HUP, INT, or TERM. The next live drill is a new
authorized run after exact-head CI, review, QA, compliance, release, and final
autoreview gates.

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
snapshot and runtime recovery section. The temporary remote root is
authenticated by a per-run 64-hex ownership token in a strict
`.meet-beta-recovery-owner` marker. Authenticated creation and cleanup use
bounded, validated binary-safe stdin control frames; the identity query carries
no credential. Each allowlisted capture input uses one exact-length-bounded raw
stdin stream, while invariant remote programs are separate from dynamic input.
No payload, owner token, or reversible encoding of either is carried in SSH
argv, remote command source, or exported environment. If SSH reports failure
after root and marker creation, cleanup still removes the root only when path,
type, owner, modes, link count, and marker bytes authenticate this run; absent
or mismatched-marker collisions are preserved byte-for-byte and
metadata-for-metadata, and cleanup failure is fatal. It rejects an active SMTP
transaction,
proves a healthy populated runtime and HTTPS edge, and uses fixed
`postgres.dump.age` and `uploads.tar.gz.age` names in a fresh mode-0700
run-owned directory. Plaintext never leaves the VPS.
Every capture `psql` and `pg_dump` consumer receives the Compose service's
explicit PostgreSQL user and database. If an early query or either
post-quiescence encryption stream fails, the exact backend is restarted once,
all partial or completed capture products and staging are removed, no output or
artifact is published, and the owned nonterminal `pre_stop` journal remains for
reviewed reconciliation. A new authorized run is required after any failed
capture; interrupted runs are not retried or resumed.

Artifact configuration and manifest evidence continue to use the 30-day policy.
GitHub API timestamp serialization may round the observed interval downward by
up to 60 seconds; malformed metadata or any interval outside that bounded
window is terminal and requires a newly authorized run.

After transfer, the database and media proof files are independently hashed and
matched against the exact lowercase SHA-256 digests in the quiesced capture
result before authenticated remote cleanup, evidence construction, or artifact
publication. A malformed, missing, unreadable, unhashable, or mismatched proof
is terminal; authenticated cleanup remains mandatory and a cleanup failure is
fatal. No artifact is eligible and restore custody is never reached after such
a failure. Framing, authentication, transfer, integrity, collision, signal, or
cleanup failures must be reviewed and remediated before dispatching a
brand-new authorized recovery with a new recovery ID. Never rerun or resume
the historical failure, and never substitute SCP, SFTP, or an unreviewed
fallback transport.

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
