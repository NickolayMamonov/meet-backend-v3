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

The following is the minimum executable operator gate. It is run outside the
installed tool and immediately before every live invocation; it is not a
runtime manifest and is not replaced by a branch or tag check. `B`, `H`, `M`,
and `C` must be supplied from the hosted merge record for the current retry.
The hosted check conclusions are recorded separately from this shell check and
must identify the same `M`.

```bash
set -euo pipefail
repo=/srv/meet-backend-v3
installed=/usr/local/libexec/meet-leaf-spki-rollover
: "${B:?target dev base commit}"
: "${H:?approved head commit}"
: "${M:?hosted synthetic merge commit}"
: "${C:?actual merge commit}"
: "${HOSTED_CHECK_RECORD:?sanitized hosted check record for M}"

cd "$repo"
test -z "$(git status --porcelain)"
test "$(git rev-parse --verify "$B^{commit}")" = "$B"
test "$(git rev-parse --verify "$H^{commit}")" = "$H"
test "$(git rev-parse --verify "$M^{commit}")" = "$M"
test "$(git rev-parse --verify "$C^{commit}")" = "$C"
T=$(git merge-tree --write-tree "$B" "$H")
test "$(git rev-parse "$M^1")" = "$B"
test "$(git rev-parse "$M^2")" = "$H"
test "$(git rev-parse "$M^{tree}")" = "$T"
test "$(git rev-parse "$C^1")" = "$B"
test "$(git rev-parse "$C^2")" = "$H"
test "$(git rev-parse "$C^{tree}")" = "$T"
expected_tooling=$(printf '%s\n' \
  scripts/leaf-spki-rollover.sh scripts/lib/leaf-spki-rollover.sh \
  scripts/test-leaf-spki-rollover.sh docs/operations/leaf-spki-rollover.md | sort)
actual_tooling=$(git ls-tree -r --name-only "$C" -- \
  scripts/leaf-spki-rollover.sh scripts/lib/leaf-spki-rollover.sh \
  scripts/test-leaf-spki-rollover.sh docs/operations/leaf-spki-rollover.md | sort)
test "$actual_tooling" = "$expected_tooling"
while IFS= read -r record; do
  mode=${record%% *}
  rest=${record#* }
  type=${rest%% *}
  rest=${rest#* }
  object=${rest%%$'\t'*}
  path=${rest#*$'\t'}
  test "$type" = blob
  case "$path" in
    scripts/leaf-spki-rollover.sh|scripts/test-leaf-spki-rollover.sh)
      test "$mode" = 100755 ;;
    scripts/lib/leaf-spki-rollover.sh|docs/operations/leaf-spki-rollover.md)
      test "$mode" = 100644 ;;
    *) exit 65 ;;
  esac
  test "$(git cat-file -t "$C:$path")" = blob
done < <(git ls-tree -r "$C" -- \
  scripts/leaf-spki-rollover.sh scripts/lib/leaf-spki-rollover.sh \
  scripts/test-leaf-spki-rollover.sh docs/operations/leaf-spki-rollover.md)
test -s "$HOSTED_CHECK_RECORD"
grep -F "merge=$M" "$HOSTED_CHECK_RECORD" >/dev/null
grep -F "conclusion=success" "$HOSTED_CHECK_RECORD" >/dev/null

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT
git show "$C:scripts/leaf-spki-rollover.sh" >"$tmp/leaf-spki-rollover.sh"
git show "$C:scripts/lib/leaf-spki-rollover.sh" >"$tmp/lib-leaf-spki-rollover.sh"
test "$(sha256sum "$tmp/leaf-spki-rollover.sh" | awk '{print tolower($1)}')" =
  "$(sha256sum "$installed/leaf-spki-rollover.sh" | awk '{print tolower($1)}')"
test "$(sha256sum "$tmp/lib-leaf-spki-rollover.sh" | awk '{print tolower($1)}')" =
  "$(sha256sum "$installed/lib/leaf-spki-rollover.sh" | awk '{print tolower($1)}')"
test "$(stat -c '%u:%g:%a:%h' "$installed/leaf-spki-rollover.sh")" = 0:0:755:1
test "$(stat -c '%u:%g:%a:%h' "$installed/lib/leaf-spki-rollover.sh")" = 0:0:644:1
for directory in /usr/local /usr/local/libexec "$installed" "$installed/lib"; do
  test -d "$directory" && test ! -L "$directory"
  test "$(stat -c '%u:%g' "$directory")" = 0:0
  test $((8#$(stat -c '%a' "$directory") & 8#022)) -eq 0
done
test "$(find "$installed" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" =
  $'leaf-spki-rollover.sh\nlib'
test "$(find "$installed/lib" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)" =
  'leaf-spki-rollover.sh'
for file in "$installed/leaf-spki-rollover.sh" "$installed/lib/leaf-spki-rollover.sh"; do
  test -f "$file" && test ! -L "$file"
  test "$(stat -c '%h' "$file")" = 1
done
```

The operator signs the sanitized output with the run identifier and stores
only the commit IDs, `T`, check IDs/conclusions, two installed-file hashes,
and metadata results. A failure stops the phase before the CLI is started.

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
  --webroot-path <DISCOVERED_WEBROOT> --preferred-challenges http-01 \
  --no-random-sleep-on-renew --no-directory-hooks
```

When the rollover lineage is wholly absent, use:

```text
certbot certonly --non-interactive --webroot \
  --webroot-path <DISCOVERED_WEBROOT> --domains api.whysoezzy.online \
  --cert-name api.whysoezzy.online-rollover --key-type ecdsa \
  --elliptic-curve secp256r1 --new-key --reuse-key \
  --preferred-challenges http-01 --no-random-sleep-on-renew --no-directory-hooks
```

An existing rollover lineage uses the same `reconfigure` form with its exact
`--cert-name`. Each renewal proof uses one fresh command:

```text
certbot renew --non-interactive --cert-name <EXACT_LINEAGE> \
  --dry-run --preferred-challenges http-01 --no-random-sleep-on-renew \
  --no-directory-hooks
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
Flyway migration digest. The fixed live Compose observer is
`/usr/local/libexec/meet-production/production-compose.sh`; it must be a
root-owned, non-symlink regular executable and is the only Compose entry
point. Never inspect or emit container environments.

Evidence is a fixed, bounded, sanitized key/value schema containing only
phase/outcome, hostname/lineage, public SPKI and approved certificate
metadata, Nginx digest/path names, probe statuses/digests, runtime identity,
database publication/volume/migration digests, and reviewed-merge gate
metadata. It rejects unknown/duplicate keys, control/multiline values, PEM or
raw certificate/private-key material, and authorization, cookie, JWT, OTP,
password, credential, or provider-token patterns. State/evidence directories
must already be the expected root-owned restricted directories; unsafe
pre-existing paths fail closed.

The exact runtime observation contract is:

```text
api_status=200
api_shape=VALID
api_digest=<SHA-256 of canonical /api/v1/tags JSON>
actuator_status=401
admin_status=401
backend_source=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
backend_image_digest=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
backend_version=1.0.1
backend_user=10001:10001
backend_listener=127.0.0.1:8080
backend_health=healthy
compose_project=meet-production
compose_service=backend
postgres_image_digest=sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2
postgres_published=NO
backend_volume=meet-production_uploads_data
postgres_volume=meet-production_postgres_data
flyway_migration_digest=8bdd5aa46f7efe03882e787b36eb701423d35c24eb2681759375b7f360b3277c
```

Live values are obtained from public HTTPS probes and `docker inspect`,
the fixed Compose helper, container health and published-port metadata,
named-volume mounts, and the immutable database migration inventory. The
public `/api/v1/tags` response must be an object with exactly
`success,data,message,error`; `success=true`, `message=null`, `error=null`,
and `data` is an array of objects whose exact keys are positive integral `id`
and string `text`. The public `/meetings` canary must return HTTP 200 and a
JSON array. `api_digest` is the SHA-256 of the sorted canonical tags object.
The public readiness and admin probes are unauthenticated `GET` requests and
must each return the reviewed 401 JSON shape with the request path, fixed
`Authentication is required` message, `UNAUTHORIZED` code, and a validated
RFC-3339 timestamp normalized to a sentinel before hashing. Internal readiness
is obtained only through the Compose helper and must be exactly
`{"status":"UP"}`. The Flyway digest is computed from the ordered
`flyway_schema_history` rows through the PostgreSQL container's `psql`; it is
captured before and after every effect and must remain equal to
`LEAF_SPKI_FLYWAY_MIGRATION_DIGEST`. The observer must not inspect or emit
container environments, command-line secrets, or application credentials.
The PostgreSQL publication value must be `NO`, and the backend listener must
be exactly loopback-only `127.0.0.1:8080`. Fixture mode must provide every
key above and applies the same value validation; missing, duplicate,
malformed, or unexpected observations block the phase.

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
