# Leaf SPKI rollover

This runbook covers the controlled, edge-specific leaf-key rollover for
`api.whysoezzy.online`. It is additive operational tooling. It does not change
backend source, Android APIs, TIMEPAD ingestion/upsert behavior,
Compose/runtime, PostgreSQL/Flyway, or release metadata. Release `368531227`,
its tag, assets, GHCR objects, and attestations are a permanent no-mutation
boundary.

## Admission and external merge gate

Live mutation is permitted only after the reviewed merge. Immediately before
**each** command, an authorized operator must:

1. Confirm the actual merge commit `C`, its approved parents/tree, current
   target `dev` tip, and the hosted synthetic-merge check identity.
2. Materialize each installed tooling file from `git show C:<path>` outside the
   repository and compare lowercase SHA-256 bytes and approved metadata with
   the fixed installed files:
   `/usr/local/libexec/meet-leaf-spki-rollover/leaf-spki-rollover.sh` and
   its `lib/leaf-spki-rollover.sh`.
3. Require root-owned, non-writable parent directories; regular files,
   no symlink/hardlink, entry mode `0755`, and library mode `0644`.
4. Record only `C`, tree/check IDs, file hashes, metadata status, and gate
   outcome in sanitized evidence. Never record file contents or secrets.

A mismatch blocks invocation. The CLI accepts no revision, hostname, lineage,
root, Nginx path, webroot, release, mode, or dependency arguments. Fixture
mode is unprivileged, temporary-root-only, offline, and cannot address live
paths.

The merge gate is an actual-object check, not a branch-name check. Record
target base `B`, approved head `H`, expected tree
`T = git merge-tree --write-tree B H`, hosted synthetic merge `M` with exactly
parents `B,H` and tree `T`, and the successful required checks attached to
`M`. After merge, the installed/reviewed commit `C` must have exactly those
parents and tree. A squash/rebase merge, stale approval, check rerun on a
different SHA, base drift, dirty working tree, or extra/missing installed
tooling file blocks the operation. The sanitized gate record contains only
`B`, `H`, `T`, `M`, `C`, check IDs/conclusions, allowlisted file SHA-256 values,
and owner/mode status.

## Closed CLI and operator sequence

The interface has exactly eight commands:

```text
inspect
configure-primary
ensure-rollover
configure-rollover
verify-primary-renewal
verify-rollover-renewal
drill
restore --confirm-restore=RESTORE-PRIMARY
```

Run the forward phases as separate confirmed invocations:

1. `inspect` — read-only baseline; records sanitized observations.
2. `configure-primary` — independently re-observe the current primary and
   converge the primary renewal configuration to key
   reuse and prove the primary SPKI and all immutable invariants are unchanged.
3. `ensure-rollover` — independently re-observe the primary, then issue the
   explicitly named rollover lineage only when
   wholly absent, or converge its existing configuration; prove its distinct
   SPKI and dormant/root-only state.
4. `configure-rollover` — independently validate the exact rollover renewal configuration
   without reissuing or serving it; this compatibility phase is idempotent.
5. `verify-primary-renewal`, then `verify-rollover-renewal` — each independently
   re-observes both lineages and runs one isolated dry-run, proving both
   lineage SPKIs remain unchanged.
6. `drill` — re-observe both lineages, run both dry-runs again, then temporarily
   switch exactly two Nginx directives, prove rollover,
   and always attempt primary restoration before returning.
7. Final `inspect`, or the same confirmed `restore` if an interruption leaves
    recoverable active state.

Every forward effect is guarded by the current lock and immediate fresh live
re-observation. Evidence is historical only and never substitutes for current
admission.

## Fixed technical contract

The primary lineage is `api.whysoezzy.online`; the named rollover lineage is
`api.whysoezzy.online-rollover`. Both are ECDSA P-256/webroot lineages. The
primary command is:

```text
certbot reconfigure --non-interactive --cert-name api.whysoezzy.online \
  --reuse-key --key-type ecdsa --elliptic-curve secp256r1 --webroot \
  --webroot-path <DISCOVERED_WEBROOT> --no-directory-hooks
```

When the rollover lineage is wholly absent, use:

```text
certbot certonly --non-interactive --webroot \
  --webroot-path <DISCOVERED_WEBROOT> --domains api.whysoezzy.online \
  --cert-name api.whysoezzy.online-rollover --key-type ecdsa \
  --elliptic-curve secp256r1 --new-key --reuse-key --no-directory-hooks
```

An existing rollover lineage uses the same `reconfigure` form with its exact
`--cert-name`. Each renewal proof uses one fresh command:

```text
certbot renew --non-interactive --cert-name <EXACT_LINEAGE> \
  --dry-run --no-directory-hooks
```

Before any Certbot operation, reject saved `pre_hook`, `post_hook`,
`renew_hook`, or `deploy_hook` settings and inventory renewal-hook directories
without executing them. Every command must prove no Nginx, backend, Docker,
Compose, or database effect. Certbot failure is `74`; rerun the same
independently idempotent phase only after a fresh observation.

Every Certbot invocation must first validate Certbot 2.9.x, both target
lineages' exact renewal settings, certificate/key pairing, ECDSA P-256
identity, SAN, permissions, symlink/archive containment, saved hook fields,
and the pre/deploy/post hook directories. A non-zero result with a proven
unchanged lineage is `74 CERTBOT_OPERATION_FAILED`; a child interruption,
partial lineage, changed SPKI/configuration, or any state that cannot be
classified as unchanged is `76 FORWARD_RECONCILIATION_REQUIRED`. Exit `76`
leaves forward phases blocked until a separate read-only reconciliation/manual
recovery establishes either wholly absent or wholly valid intended state.

Canonical leaf identity is public leaf certificate -> public key -> DER
SubjectPublicKeyInfo -> SHA-256 binary -> Base64. It must decode to exactly
32 bytes and round-trip to the same canonical encoding. The two leaf SPKIs
must be distinct and stable across renewals. Intermediate and root keys are
never pinned.

## Immutable invariants and evidence

The exact Nginx source/topology and discovered ACME webroot are compiled from
read-only operator discovery; no generic target is accepted. Nginx changes are
rendered before manifest publication and may change only:
`ssl_certificate` and `ssl_certificate_key`. The candidate and reverse
candidate are parsed and diffed; unrelated bytes, directive duplication, or
source drift blocks installation.

At every gate, prove the external SNI/hostname/normal CA chain, public API
JSON canary, denied public Actuator and admin probes, immutable backend
source/version/image digest, UID/GID, health, loopback-only `127.0.0.1:8080`
publication, Compose identity, unpublished PostgreSQL, named volumes, and
Flyway migration digest. Never inspect or emit container environments.

Evidence is a fixed, bounded, sanitized key/value schema containing only
phase/outcome, hostname/lineage, public SPKI and approved certificate
metadata, Nginx digest/path names, probe statuses/digests, runtime identity,
database publication/volume/migration digests, and reviewed-merge gate
metadata. It rejects unknown/duplicate keys, control/multiline values, PEM or
raw certificate/private-key material, and authorization, cookie, JWT, OTP,
password, credential, or provider-token patterns. State/evidence directories
must already be the expected root-owned restricted directories; unsafe
pre-existing paths fail closed.

## Recovery, drill, and exit statuses

The recovery namespace is append-only and permits only `preparing`, `active`,
and `completed`. Unknown siblings, dangling recovery-parent symlinks, package
conflicts, invalid metadata, partial packages, and malformed manifests fail
closed without selecting a winner.

`restore --confirm-restore=RESTORE-PRIMARY` selects exactly one mode under the
same global lock:

* **active-only:** validate the complete O/C/M_CERT/M_KEY-bound recovery
  package. If Nginx is on a permitted intermediate, install the exact primary
  directives, run `nginx -t`, reload only after a successful test, prove
  primary, then publish active to completed with no-replace semantics.
* **completed-only:** validate immutable completed, exact manifest-bound O and
  external primary SPKI/hostname/chain before any effect. Its sole admitted
  effect is idempotent recovery-parent sync, followed by completed reopen/full
  revalidation and sanitized evidence. It never writes/tests/reloads Nginx,
  runs Certbot, renames/edits/deletes packages, or mutates backend, Compose,
  PostgreSQL, or the database.

`drill` always attempts restoration. A failed rollover proof is reported as
`10 DRILL_FAILED_PRIMARY_RESTORED` only after complete primary proof.
`0 PRIMARY_RESTORED` proves terminal primary, completed, durability, evidence,
and green invariants. `10` proves those terminal properties with advisory
drift. `20 RESTORE_INCOMPLETE` means primary/package/source proof cannot be
completed; recovery authority remains for reviewed manual handling. `64` is
usage error, `65` validation/stale/conflicting state, `69` required
observation unavailable, `70` internal failure, `73` persistence/reopen/evidence
failure after the relevant proof, `74` Certbot failure, and `75` lock
contention.

After an interruption, rerun the external actual-merge byte gate and the exact
confirmed restore command. Never run a different mode or manually edit
Nginx/package contents. A completed-only `20` is an operator escalation with
zero sync; a completed-only `73` is safely retryable with the same command.
Retain only sanitized evidence.

## Hosted and controlled VPS proof

Before live execution, record `B` (target base), `H` (approved head), expected
tree `T = git merge-tree --write-tree B H`, hosted synthetic merge commit
`M` with parents exactly `B,H` and tree `T`, and the required successful checks
on `M`. After merge, require actual merge `C` to have parents `B,H` and tree
`T`; squash/rebase or base/head/check drift invalidates the proof.

Install a clean root-owned versioned archive of `C` on the controlled VPS and
repeat the external installed-byte gate. Then capture non-secret evidence for
the discovery topology, Certbot version/configuration, both lineages and
SPKIs, exact dry-run argv/results, Nginx candidate/test/reload/restore,
external chain/hostname/SPKI/API/security probes, backend/Compose identity,
PostgreSQL isolation/volume/migration identity, and final primary service.
No live mutation or production-ready claim is valid without this controlled
proof.
