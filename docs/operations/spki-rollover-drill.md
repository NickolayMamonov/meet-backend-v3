# Minimal SPKI rollover drill

This is a bounded, operator-driven test-edge drill for
`api.whysoezzy.online`. It is a reviewed command sheet, not an executable,
library, launcher, journal, state machine, or production-certification
artifact. The only repository change authorized by this task is this file.

The drill does not change backend source or API/DTO behavior, TIMEPAD
mapping/upsert behavior, Flyway history, Android artifacts (including Android
PR #67), release metadata or images, deployment configuration, DNS,
environment values, database data, or volumes. Immutable backend release
`368531227`, its tag, assets, GHCR aliases, and attestations are a permanent
no-mutation boundary. The backend remains v1.0.1, runs as `10001:10001`, and
is published only on `127.0.0.1:8080`; PostgreSQL remains unpublished.

## Stop rules and evidence boundary

Stop immediately, without guessing or substituting a value, if any of these
conditions is false:

- the installed bytes are the exact runbook blob resolved from the actual
  merge commit;
- the actual merge has the reviewed base/head/tree and changes only this file;
- a fresh read-only inventory equals every literal in the reviewed inventory
  below;
- a path is of the expected class, owner, mode, containment, or hardlink
  count;
- a Certbot, Nginx, TLS, endpoint, runtime, PostgreSQL, volume, or migration
  proof is unavailable or differs from the reviewed result; or
- a command would print a secret, private key, certificate bytes, account
  identifier, environment value, OTP, JWT, refresh token, database
  credential, provider token, or real admin credential.

Do not continue after a mismatch. A changed host requires a new reviewed
literal inventory and a new merge. Do not put observed evidence into this
file after merge: the execution blob is immutable. Record merge identifiers in
one task comment and sanitized drill results in a separate task comment (or a
separately reviewed follow-up that is never used as the execution blob).

The only temporary drill artifact is a root-owned, mode `0600`, one-hardlink
copy of the canonical Nginx source. It is removed only after externally
proven primary restoration. If restoration cannot be fully proven, retain it
and both Certbot lineages for review.

## Reviewed merge and blob gate

The implementation merge is a normal, reviewed merge to `dev`. Before live
execution, record these values outside the runbook:

```text
base_commit=
approved_head=
expected_merge_tree=
actual_merge_commit=
runbook_blob=
installed_runbook_git_hash=
hosted_check_record=
```

`actual_merge_commit` must have exactly `base_commit` and `approved_head` as
its first and second parents, and its tree must equal
`expected_merge_tree`. A squash, rebase, base drift, stale check, or extra
changed path is a stop condition.

Immediately before **each** live block below, an independent operator repeats
this gate from a clean checkout. The values are supplied from the current
review record; they are not branch-name or task-name authorization.

```bash
set -euo pipefail

readonly REPO=/srv/meet-backend-v3
readonly RUNBOOK="$REPO/docs/operations/spki-rollover-drill.md"
readonly EXPECTED_PATH=docs/operations/spki-rollover-drill.md
: "${BASE_COMMIT:?reviewed target-dev base}"
: "${APPROVED_HEAD:?reviewed PR head}"
: "${ACTUAL_MERGE:?actual merge commit}"
: "${HOSTED_CHECK_RECORD:?sanitized successful checks for ACTUAL_MERGE}"

cd "$REPO"
test -z "$(git status --porcelain)"
test "$(git rev-parse --verify "$BASE_COMMIT^{commit}")" = "$BASE_COMMIT"
test "$(git rev-parse --verify "$APPROVED_HEAD^{commit}")" = "$APPROVED_HEAD"
test "$(git rev-parse --verify "$ACTUAL_MERGE^{commit}")" = "$ACTUAL_MERGE"
test "$(git rev-parse "$ACTUAL_MERGE^1")" = "$BASE_COMMIT"
test "$(git rev-parse "$ACTUAL_MERGE^2")" = "$APPROVED_HEAD"
test "$(git rev-parse "$ACTUAL_MERGE^{tree}")" =
  "$(git merge-tree --write-tree "$BASE_COMMIT" "$APPROVED_HEAD")"
test -s "$HOSTED_CHECK_RECORD"
grep -F "merge=$ACTUAL_MERGE" "$HOSTED_CHECK_RECORD" >/dev/null
grep -F "conclusion=success" "$HOSTED_CHECK_RECORD" >/dev/null

test "$(git diff --name-only "$ACTUAL_MERGE^1" "$ACTUAL_MERGE")" =
  "$EXPECTED_PATH"
test -z "$(git diff --name-only "$ACTUAL_MERGE^2" "$ACTUAL_MERGE")"
test "$(git diff --name-only "$BASE_COMMIT" "$ACTUAL_MERGE")" =
  "$EXPECTED_PATH"
test "$(git diff --name-only "$BASE_COMMIT" "$APPROVED_HEAD")" = "$EXPECTED_PATH"
test "$(git cat-file -t "$ACTUAL_MERGE:$EXPECTED_PATH")" = blob
readonly RUNBOOK_BLOB=$(git rev-parse "$ACTUAL_MERGE:$EXPECTED_PATH")
test "$(git hash-object --no-filters "$RUNBOOK")" = "$RUNBOOK_BLOB"
git cat-file blob "$ACTUAL_MERGE:$EXPECTED_PATH" | cmp - "$RUNBOOK"
```

The no-filter hash and byte-for-byte `cmp` are the raw installed-file proof;
the gate produces only the commit IDs, tree, blob, check conclusion, and
boolean gate result. It does not create a token or a durable authorization
file. The merge/blob comment is separate from this file and must include the
actual PR head, target base, merge tree, merge commit, runbook blob, and
installed Git blob hash.

## Literal host inventory

The values below are the only reviewed literals permitted in the command
sheet. The host inventory must be captured read-only immediately before the
first live block and compared literally. A mismatch is a stop condition that
requires a new reviewed merge; do not discover a value and substitute it in
the same session.

| Item | Reviewed literal |
| --- | --- |
| Hostname/SNI | `api.whysoezzy.online` |
| Primary Certbot lineage | `api.whysoezzy.online` |
| Fresh rollover lineage | `api.whysoezzy.online-rollover` |
| Nginx canonical source | `/etc/nginx/sites-available/api.whysoezzy.online` |
| Nginx enabled symlink | `/etc/nginx/sites-enabled/api.whysoezzy.online` |
| Nginx enabled target | `/etc/nginx/sites-available/api.whysoezzy.online` |
| Certbot live root | `/etc/letsencrypt/live` |
| Certbot archive root | `/etc/letsencrypt/archive` |
| Certbot renewal root | `/etc/letsencrypt/renewal` |
| Certbot hook roots | `/etc/letsencrypt/renewal-hooks/{pre,deploy,post}` |
| Certbot version | `2.9.0` |
| Primary live `cert.pem` link target | `../../archive/api.whysoezzy.online/cert1.pem` |
| Primary live `chain.pem` link target | `../../archive/api.whysoezzy.online/chain1.pem` |
| Primary live `fullchain.pem` link target | `../../archive/api.whysoezzy.online/fullchain1.pem` |
| Primary live `privkey.pem` link target | `../../archive/api.whysoezzy.online/privkey1.pem` |
| Rollover live `cert.pem` link target | `../../archive/api.whysoezzy.online-rollover/cert1.pem` |
| Rollover live `chain.pem` link target | `../../archive/api.whysoezzy.online-rollover/chain1.pem` |
| Rollover live `fullchain.pem` link target | `../../archive/api.whysoezzy.online-rollover/fullchain1.pem` |
| Rollover live `privkey.pem` link target | `../../archive/api.whysoezzy.online-rollover/privkey1.pem` |
| ACME webroot | `/var/www/certbot` |
| ACME webroot root | `/var/www` |
| Deploy hook | `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx`, SHA-256 `342a163b2e884ec7ba68a2a3ff08fc9461b5c672050c71f5f4f19465b9e9ec63` |
| Backend listener | `127.0.0.1:8080` |
| Backend version | `1.0.1` |
| Immutable release | `368531227` |
| Backend user | `10001:10001` |
| Public meetings probe | `GET /meetings` |
| Public actuator probe | `GET /actuator/health/readiness` must be `404` |
| Invalid admin probe | `GET /admin/ingest` with no or deliberately invalid key, `403` |
| PostgreSQL publication | none |
| PostgreSQL volume | `meet-production_postgres_data` |
| Upload volume | `meet-production_uploads_data` |
| Migration inventory | existing Flyway history, unchanged |

The inventory record must also contain the observed source/enabled-link
topology, Certbot version, lineage symlink targets, renewal settings, hook
directory contents, source mode/owner/hardlink count, and the current primary
public SPKI. Record only sanitized paths, modes, counts, digests, and
outcomes.

## Path classes and validation

Path checks are class-aware. An expected symlink is allowed only where listed
below; canonical files are never accepted through a symlink. All canonical
paths must resolve inside the reviewed root, be root-owned, have no
group/other write bit, and have exactly one hardlink.

| Class | Allowed paths | Required checks |
| --- | --- | --- |
| Exact reviewed symlink | Nginx enabled link and Certbot `live/<lineage>/{cert,chain,fullchain,privkey}.pem` links | `-L`, exact `readlink` text, root-owned link, link mode `0777`, one hardlink, safe canonical parent, target contained in the reviewed root |
| Canonical directory | Nginx parents, `/etc/letsencrypt` roots, each lineage `live`/`archive` directory, hook directories | `-d` and not `-L`, `realpath -e` containment, owner `0:0`, exact reviewed mode `0755`, no group/other write |
| Canonical regular file | Nginx source, renewal files, deploy hook, archive cert/chain/fullchain/key targets, rollback copy | `-f` and not `-L`, contained canonical path, owner `0:0`, reviewed mode (`0644` public/source/renewal, `0755` deploy hook, `0600` key/rollback), no group/other write, hardlink count `1` |

The following is the required positive gate. `WEBROOT` is not inferred by
this command; it must be the reviewed literal from the inventory.

```bash
set -euo pipefail
readonly HOST=api.whysoezzy.online
readonly PRIMARY=api.whysoezzy.online
readonly ROLLOVER=api.whysoezzy.online-rollover
readonly NGINX_SOURCE=/etc/nginx/sites-available/api.whysoezzy.online
readonly NGINX_ENABLED=/etc/nginx/sites-enabled/api.whysoezzy.online
readonly WEBROOT=/var/www/certbot
readonly WEBROOT_ROOT=/var/www
readonly PRIMARY_CERT_TARGET=../../archive/api.whysoezzy.online/cert1.pem
readonly PRIMARY_CHAIN_TARGET=../../archive/api.whysoezzy.online/chain1.pem
readonly PRIMARY_FULLCHAIN_TARGET=../../archive/api.whysoezzy.online/fullchain1.pem
readonly PRIMARY_PRIVKEY_TARGET=../../archive/api.whysoezzy.online/privkey1.pem
readonly ROLLOVER_CERT_TARGET=../../archive/api.whysoezzy.online-rollover/cert1.pem
readonly ROLLOVER_CHAIN_TARGET=../../archive/api.whysoezzy.online-rollover/chain1.pem
readonly ROLLOVER_FULLCHAIN_TARGET=../../archive/api.whysoezzy.online-rollover/fullchain1.pem
readonly ROLLOVER_PRIVKEY_TARGET=../../archive/api.whysoezzy.online-rollover/privkey1.pem

assert_dir() {
  local path=$1 root=$2
  test -d "$path" && test ! -L "$path"
  local real
  real=$(realpath -e -- "$path")
  case "$real" in "$root"|"$root"/*) ;; *) return 65 ;; esac
  test "$(stat -c '%u:%g:%a' -- "$path")" = 0:0:755
  test $((8#$(stat -c '%a' -- "$path") & 8#022)) -eq 0
}

assert_file() {
  local path=$1 mode=$2 root=$3 real
  test -f "$path" && test ! -L "$path"
  real=$(realpath -e -- "$path")
  case "$real" in "$root"|"$root"/*) ;; *) return 65 ;; esac
  test "$(stat -c '%u:%g:%a:%h' -- "$path")" = "0:0:$mode:1"
  test $((8#$(stat -c '%a' -- "$path") & 8#022)) -eq 0
}

assert_link() {
  local path=$1 expected=$2 root=$3 parent
  test -L "$path"
  test "$(readlink -- "$path")" = "$expected"
  test "$(stat -c '%u:%g:%a:%h' -- "$path")" = 0:0:777:1
  parent=$(dirname -- "$path")
  assert_dir "$parent" "$root"
  local real
  real=$(realpath -e -- "$path")
  case "$real" in "$root"|"$root"/*) ;; *) return 65 ;; esac
}

assert_dir /etc/nginx /etc
assert_dir /etc/nginx/sites-available /etc
assert_dir /etc/nginx/sites-enabled /etc
assert_dir /etc/letsencrypt /etc
assert_dir /etc/letsencrypt/live /etc/letsencrypt
assert_dir /etc/letsencrypt/archive /etc/letsencrypt
assert_dir /etc/letsencrypt/renewal /etc/letsencrypt
assert_dir "$WEBROOT" "$WEBROOT_ROOT"
for hook in pre post; do
  assert_dir "/etc/letsencrypt/renewal-hooks/$hook" /etc/letsencrypt
  test -z "$(find "/etc/letsencrypt/renewal-hooks/$hook" -mindepth 1 -maxdepth 1 -print -quit)"
done
assert_dir /etc/letsencrypt/renewal-hooks/deploy /etc/letsencrypt
assert_file /etc/letsencrypt/renewal-hooks/deploy/reload-nginx 755 /etc/letsencrypt
test "$(sha256sum /etc/letsencrypt/renewal-hooks/deploy/reload-nginx | awk '{print $1}')" =
  342a163b2e884ec7ba68a2a3ff08fc9461b5c672050c71f5f4f19465b9e9ec63
assert_file "$NGINX_SOURCE" 644 /etc/nginx
assert_link "$NGINX_ENABLED" "$NGINX_SOURCE" /etc/nginx

assert_lineage() {
  local lineage=$1 live archive renewal name link target expected resolved
  live="/etc/letsencrypt/live/$lineage"
  archive="/etc/letsencrypt/archive/$lineage"
  renewal="/etc/letsencrypt/renewal/$lineage.conf"
  assert_dir "$live" /etc/letsencrypt
  assert_dir "$archive" /etc/letsencrypt
  assert_file "$renewal" 644 /etc/letsencrypt
  for name in cert chain fullchain privkey; do
    link="$live/$name.pem"
    target=$(readlink -- "$link")
    case "$lineage:$name" in
      "$PRIMARY":cert) expected=$PRIMARY_CERT_TARGET ;;
      "$PRIMARY":chain) expected=$PRIMARY_CHAIN_TARGET ;;
      "$PRIMARY":fullchain) expected=$PRIMARY_FULLCHAIN_TARGET ;;
      "$PRIMARY":privkey) expected=$PRIMARY_PRIVKEY_TARGET ;;
      "$ROLLOVER":cert) expected=$ROLLOVER_CERT_TARGET ;;
      "$ROLLOVER":chain) expected=$ROLLOVER_CHAIN_TARGET ;;
      "$ROLLOVER":fullchain) expected=$ROLLOVER_FULLCHAIN_TARGET ;;
      "$ROLLOVER":privkey) expected=$ROLLOVER_PRIVKEY_TARGET ;;
      *) exit 65 ;;
    esac
    test "$target" = "$expected"
    assert_link "$link" "$target" /etc/letsencrypt
    resolved=$(realpath -e -- "$link")
    case "$name:$resolved" in
      cert:"$archive"/cert[0-9]*.pem|chain:"$archive"/chain[0-9]*.pem|\
      fullchain:"$archive"/fullchain[0-9]*.pem|privkey:"$archive"/privkey[0-9]*.pem) ;;
      *) exit 65 ;;
    esac
  done
}
assert_lineage "$PRIMARY"
```

The link itself is validated by `assert_link`; its resolved target is
validated separately. The operator must run the following target checks
instead of weakening the class distinction:

```bash
for lineage in "$PRIMARY"; do
  archive="/etc/letsencrypt/archive/$lineage"
  for name in cert chain fullchain; do
    assert_file "$(realpath -e -- "/etc/letsencrypt/live/$lineage/$name.pem")" \
      644 /etc/letsencrypt
  done
  assert_file "$(realpath -e -- "/etc/letsencrypt/live/$lineage/privkey.pem")" \
    600 /etc/letsencrypt
done
```

The primary-only gate above is the pre-creation topology gate: the rollover
lineage is intentionally absent at that point. After the creation block
below succeeds, rerun the following post-creation topology gate in the same
reviewed shell. It uses the same `assert_lineage` helper and now requires
both complete lineages and their reviewed first archive targets:

```bash
set -euo pipefail
assert_lineage "$PRIMARY"
assert_lineage "$ROLLOVER"
for lineage in "$PRIMARY" "$ROLLOVER"; do
  archive="/etc/letsencrypt/archive/$lineage"
  for name in cert chain fullchain; do
    assert_file "$(realpath -e -- "/etc/letsencrypt/live/$lineage/$name.pem")" \
      644 /etc/letsencrypt
  done
  assert_file "$(realpath -e -- "/etc/letsencrypt/live/$lineage/privkey.pem")" \
    600 /etc/letsencrypt
done
```

Negative review cases must be exercised on an isolated copy or by read-only
inspection: wrong link text, a target escaping its root, a missing or
unexpected symlink, owner mismatch, group/other writability, mode mismatch,
regular-file-versus-directory mismatch, and hardlink count other than one
must each fail. Never inject a negative case into the live Nginx or Certbot
tree.

## Read-only preflight

Run the blob gate and path-class gate immediately before this block. No
Certbot, Nginx, Docker, Compose, database, or filesystem mutation is allowed
in preflight.

### Certificate and renewal observations

At this pre-creation stage, prove the primary renewal file contains exactly
one `key_type = ecdsa`, `elliptic_curve = secp256r1`, and `reuse_key = True`
entry. The rollover lineage is intentionally absent and is checked only after
the creation block. Reject any `pre_hook`, `post_hook`, `renew_hook`, or
`deploy_hook` setting and do not execute hook directories. Verify Certbot is
version `2.9.x`; a different version is a stop condition.

The only accepted public-key identity is:

```text
leaf certificate -> public key -> DER SubjectPublicKeyInfo ->
SHA-256(binary) -> canonical Base64
```

Use these functions in the operator shell. They never print a certificate or
private key:

```bash
set -euo pipefail
spki_from_cert() {
  openssl x509 -in "$1" -pubkey -noout |
    openssl pkey -pubin -outform DER |
    openssl dgst -sha256 -binary | base64 | tr -d '\r\n'
}
spki_from_key() {
  openssl pkey -in "$1" -pubout -outform DER |
    openssl dgst -sha256 -binary | base64 | tr -d '\r\n'
}
assert_p256_pair() {
  local cert=$1 key=$2 cert_spki key_spki
  openssl x509 -in "$cert" -noout -checkhost api.whysoezzy.online >/dev/null
  openssl x509 -in "$cert" -text -noout |
    grep -Fq 'Public Key Algorithm: id-ecPublicKey'
  openssl x509 -in "$cert" -text -noout |
    grep -Fq 'ASN1 OID: prime256v1'
  cert_spki=$(spki_from_cert "$cert")
  key_spki=$(spki_from_key "$key")
  test "$cert_spki" = "$key_spki"
  test "$(printf %s "$cert_spki" | base64 -d | wc -c)" = 32
  printf '%s\n' "$cert_spki"
}

for lineage in api.whysoezzy.online; do
  renewal="/etc/letsencrypt/renewal/$lineage.conf"
  test "$(grep -Ec '^key_type = ecdsa$' "$renewal")" = 1
  test "$(grep -Ec '^elliptic_curve = secp256r1$' "$renewal")" = 1
  test "$(grep -Ec '^reuse_key = True$' "$renewal")" = 1
  ! grep -Eq '^(pre|post|renew|deploy)_hook[[:space:]]*=' "$renewal"
  assert_p256_pair \
    "/etc/letsencrypt/live/$lineage/cert.pem" \
    "/etc/letsencrypt/live/$lineage/privkey.pem" >/dev/null
done
readonly CERTBOT_VERSION=2.9.0
test "$(certbot --version 2>&1)" = "certbot $CERTBOT_VERSION"
```

The reviewed inventory binds the exact installed Certbot version to `2.9.0`;
a range check is not a substitute for inventory.

### Public edge and runtime invariants

The following checks record only status, schema validity, public certificate
metadata, and sanitized identity results:

```bash
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

curl --silent --show-error --fail \
  --output "$tmp/meetings.json" \
  --write-out '%{http_code}\n' \
  https://api.whysoezzy.online/meetings >"$tmp/meetings.status"
test "$(cat "$tmp/meetings.status")" = 200
jq -e 'type == "array"' "$tmp/meetings.json" >/dev/null

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  https://api.whysoezzy.online/actuator/health/readiness)" = 404
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  https://api.whysoezzy.online/admin/ingest)" = 403
test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H 'X-Admin-Key: deliberately-invalid-for-drill' \
  https://api.whysoezzy.online/admin/ingest)" = 403

cid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q backend)
pgid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q postgres)
test -n "$cid" && test -n "$pgid"
test "$(docker inspect -f '{{.Config.User}}' "$cid")" = 10001:10001
test "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{if eq $p "8080/tcp"}}{{range $b}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}{{end}}' "$cid")" =
  127.0.0.1:8080
test -z "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{if eq $p "5432/tcp"}}{{$p}}{{end}}{{end}}' "$pgid")"
test "$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$cid")" = 1.0.1
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$cid")" =
  volume\|meet-production_uploads_data
test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$pgid")" =
  volume\|meet-production_postgres_data
docker exec "$pgid" psql -Atqc \
  'SELECT count(*) > 0 FROM flyway_schema_history WHERE success = true;' |
  grep -Fxq t
```

The formatted `docker inspect` calls are identity assertions, not permission
to print full container objects or environments. The operator must also check
the already-reviewed deployment/release record for immutable release
`368531227` without fetching, changing, or printing release assets. If that
record, the image label, the migration inventory, the two named volumes,
published-PostgreSQL absence, or any runtime identity differs, stop. Do not
inspect container environment variables.

Capture the primary SPKI from the canonical primary `cert.pem` and from the
public HTTPS edge; they must match. The HTTPS certificate must pass normal CA
validation, hostname validation, and chain validation:

```bash
set -euo pipefail
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
public_spki=$(
  openssl s_client -connect api.whysoezzy.online:443 \
    -servername api.whysoezzy.online \
    -verify_hostname api.whysoezzy.online \
    -verify_return_error </dev/null 2>"$tmp/tls.stderr" |
    openssl x509 -pubkey -noout |
    openssl pkey -pubin -outform DER |
    openssl dgst -sha256 -binary | base64 | tr -d '\r\n'
)
printf '%s\n' "$public_spki" | grep -Eq '^[A-Za-z0-9+/]{43}=$'
test "$public_spki" =
  "$(spki_from_cert /etc/letsencrypt/live/api.whysoezzy.online/cert.pem)"
```

## Certbot configuration and staging proofs

Run the independent blob/path/runtime gates before each of the following
blocks. Keep Nginx on the primary lineage throughout this section.

### Primary reuse configuration

The primary lineage must already exist. Reconfigure it for ECDSA P-256
reuse, using only the reviewed webroot and no hooks:

```bash
set -euo pipefail
certbot reconfigure --non-interactive \
  --cert-name api.whysoezzy.online \
  --reuse-key --key-type ecdsa --elliptic-curve secp256r1 \
  --webroot --webroot-path "$WEBROOT" \
  --preferred-challenges http-01 \
  --no-random-sleep-on-renew --no-directory-hooks
test "$(grep -Ec '^key_type = ecdsa$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online.conf)" = 1
test "$(grep -Ec '^elliptic_curve = secp256r1$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online.conf)" = 1
test "$(grep -Ec '^reuse_key = True$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online.conf)" = 1
```

### Fresh rollover lineage

The rollover lineage must be wholly absent before this block:

```bash
set -euo pipefail
for path in \
  /etc/letsencrypt/live/api.whysoezzy.online-rollover \
  /etc/letsencrypt/archive/api.whysoezzy.online-rollover \
  /etc/letsencrypt/renewal/api.whysoezzy.online-rollover.conf; do
  test ! -e "$path"
  test ! -L "$path"
done
certbot certonly --non-interactive --webroot \
  --webroot-path "$WEBROOT" \
  --domains api.whysoezzy.online \
  --cert-name api.whysoezzy.online-rollover \
  --key-type ecdsa --elliptic-curve secp256r1 \
  --reuse-key --preferred-challenges http-01 \
  --no-random-sleep-on-renew --no-directory-hooks
test "$(grep -Ec '^key_type = ecdsa$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online-rollover.conf)" = 1
test "$(grep -Ec '^elliptic_curve = secp256r1$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online-rollover.conf)" = 1
test "$(grep -Ec '^reuse_key = True$' \
  /etc/letsencrypt/renewal/api.whysoezzy.online-rollover.conf)" = 1
```

If any rollover path exists, including a dangling symlink, do not delete,
overwrite, or adopt it. Stop for review. The creation command uses a new
lineage and a new P-256 key; it does not copy the primary key.

Run the post-creation topology gate above immediately after this block. It
must pass before any staging dry-run or later live block. In particular, the
new `live` links must have the reviewed `../../archive/.../{cert1,chain1,
fullchain1,privkey1}.pem` targets and their canonical targets must pass the
regular-file checks.

### Per-lineage staging dry-runs

Before each dry-run, save the canonical live SPKI for that lineage. Run one
lineage-specific staging dry-run and then revalidate the complete lineage
layout, persisted settings, public certificate/private-key correspondence,
and live SPKI. Both commands must succeed:

```bash
set -euo pipefail
for lineage in api.whysoezzy.online api.whysoezzy.online-rollover; do
  before=$(spki_from_cert "/etc/letsencrypt/live/$lineage/cert.pem")
  certbot renew --non-interactive --cert-name "$lineage" \
    --dry-run --preferred-challenges http-01 \
    --no-random-sleep-on-renew --no-directory-hooks
  after=$(spki_from_cert "/etc/letsencrypt/live/$lineage/cert.pem")
  test "$before" = "$after"
  assert_p256_pair \
    "/etc/letsencrypt/live/$lineage/cert.pem" \
    "/etc/letsencrypt/live/$lineage/privkey.pem" >/dev/null
done
primary_spki=$(spki_from_cert \
  /etc/letsencrypt/live/api.whysoezzy.online/cert.pem)
rollover_spki=$(spki_from_cert \
  /etc/letsencrypt/live/api.whysoezzy.online-rollover/cert.pem)
test "$primary_spki" != "$rollover_spki"
```

This proves persisted ECDSA/secp256r1/reuse configuration, P-256 live
certificates, secret-safe public certificate/private-key correspondence,
successful staging dry-runs, unchanged live SPKIs, and distinct primary and
rollover live SPKIs. Certbot 2.9 dry-run does not expose the temporary staging
certificate's leaf SPKI through this command sheet; **do not claim to have
observed or proved that temporary staging-certificate SPKI**.

## Bounded Nginx switch and restoration

Run the independent blob/path/runtime gates immediately before this block.
The enabled symlink is never switched. Only the two certificate path
directives in the canonical Nginx source may change.

### Checked restore routine and traps

Paste and review this complete routine in the same shell as the switch. It is
the one and only restore routine. It is non-recursive: failure handling
disables all traps and implicit errexit before calling it. It performs one
copy restore, one `nginx -t`, one reload, and a complete external primary
proof. It returns success only after that proof.

`RELEASE_RECORD` must name a pre-existing, separately reviewed, sanitized
one-line record. The routine accepts only this exact binding format, with the
two image values obtained from the running backend container at proof time:
`release=368531227 image=<Config.Image> image_id=<container Image ID>`.
The record is read-only evidence; it is not a release asset, deployment
command, or authorization to mutate release `368531227`.

```bash
set -euo pipefail
readonly NGINX_SOURCE=/etc/nginx/sites-available/api.whysoezzy.online
readonly ROLLBACK_DIR=/run/meet-spki-rollover
readonly ROLLBACK=/run/meet-spki-rollover.nginx.rollback
: "${RELEASE_RECORD:?sanitized reviewed release record for immutable 368531227}"
armed=0
restore_attempted=0
restore_in_progress=0
stage=pre-switch
candidate=
cid=
pgid=
migration_before=
primary_spki_before_switch=
rollover_spki_before_switch=

prove_primary_external() (
  set -e
  local expected_spki=$1
  test -n "$expected_spki"
  test ! -L "$NGINX_SOURCE"
  test "$(stat -c '%u:%g:%a:%h' -- "$NGINX_SOURCE")" = 0:0:644:1
  test -L "$NGINX_ENABLED"
  test "$(readlink -- "$NGINX_ENABLED")" = "$NGINX_SOURCE"
  test "$(realpath -e -- "$NGINX_ENABLED")" = "$NGINX_SOURCE"
  test "$(stat -c '%u:%g:%a:%h' -- "$NGINX_ENABLED")" = 0:0:777:1
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/meetings)" = 200
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/actuator/health/readiness)" = 404
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/admin/ingest)" = 403
  test "$(openssl s_client -connect api.whysoezzy.online:443 \
    -servername api.whysoezzy.online -verify_hostname api.whysoezzy.online \
    -verify_return_error </dev/null 2>/dev/null |
    openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER |
    openssl dgst -sha256 -binary | base64 | tr -d '\r\n')" =
    "$expected_spki"
  test "$(spki_from_cert \
    /etc/letsencrypt/live/api.whysoezzy.online/cert.pem)" = "$expected_spki"
  grep -Fq \
    'ssl_certificate /etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem;' \
    "$NGINX_SOURCE"
  grep -Fq \
    'ssl_certificate_key /etc/letsencrypt/live/api.whysoezzy.online/privkey.pem;' \
    "$NGINX_SOURCE"
)

prove_service_invariants() (
  set -e
  local expected_migration=$1 current_migration running_image running_image_id
  test -f "$RELEASE_RECORD"
  test "$(wc -l < "$RELEASE_RECORD")" = 1
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/meetings)" = 200
  curl --silent --show-error --fail \
    https://api.whysoezzy.online/meetings | jq -e 'type == "array"' >/dev/null
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/actuator/health/readiness)" = 404
  test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
    https://api.whysoezzy.online/admin/ingest)" = 403
  cid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q backend)
  pgid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q postgres)
  test -n "$cid" && test -n "$pgid"
  running_image=$(docker inspect -f '{{.Config.Image}}' "$cid")
  running_image_id=$(docker inspect -f '{{.Image}}' "$cid")
  test -n "$running_image" && test -n "$running_image_id"
  test "$(docker image inspect -f '{{.Id}}' "$running_image")" =
    "$running_image_id"
  test "$(grep -Fxc \
    "release=368531227 image=$running_image image_id=$running_image_id" \
    "$RELEASE_RECORD")" = 1
  test "$(docker inspect -f '{{.Config.User}}' "$cid")" = 10001:10001
  test "$(docker inspect -f \
    '{{index .Config.Labels "org.opencontainers.image.version"}}' "$cid")" = 1.0.1
  test "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{if eq $p "8080/tcp"}}{{range $b}}{{.HostIp}}:{{.HostPort}}{{end}}{{end}}{{end}}' "$cid")" =
    127.0.0.1:8080
  test -z "$(docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{if eq $p "5432/tcp"}}{{$p}}{{end}}{{end}}' "$pgid")"
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data/uploads"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$cid")" =
    volume\|meet-production_uploads_data
  test "$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Type}}|{{.Name}}{{end}}{{end}}' "$pgid")" =
    volume\|meet-production_postgres_data
  current_migration=$(docker exec "$pgid" psql -Atqc \
    'SELECT installed_rank,version,description,type,script,checksum,success FROM flyway_schema_history ORDER BY installed_rank' |
    sha256sum | awk '{print $1}')
  test "$current_migration" = "$expected_migration"
)

prove_lineages_retained() (
  set -e
  for lineage in "$PRIMARY" "$ROLLOVER"; do
    test -d "/etc/letsencrypt/live/$lineage" &&
      test ! -L "/etc/letsencrypt/live/$lineage"
    test -d "/etc/letsencrypt/archive/$lineage" &&
      test ! -L "/etc/letsencrypt/archive/$lineage"
    test -f "/etc/letsencrypt/renewal/$lineage.conf" &&
      test ! -L "/etc/letsencrypt/renewal/$lineage.conf"
    for name in cert chain fullchain privkey; do
      test -L "/etc/letsencrypt/live/$lineage/$name.pem"
      test -e "/etc/letsencrypt/live/$lineage/$name.pem"
    done
  done
)

prove_saved_spkis() (
  set -e
  test -n "$primary_spki_before_switch"
  test -n "$rollover_spki_before_switch"
  test "$(spki_from_cert \
    /etc/letsencrypt/live/api.whysoezzy.online/cert.pem)" =
    "$primary_spki_before_switch"
  test "$(spki_from_cert \
    /etc/letsencrypt/live/api.whysoezzy.online-rollover/cert.pem)" =
    "$rollover_spki_before_switch"
)

restore_primary_once() {
  if test "$restore_attempted" -ne 0; then
    return 90
  fi
  restore_attempted=1
  restore_in_progress=1
  local status=0
  cp -- "$ROLLBACK" "$NGINX_SOURCE" || status=$?
  if test "$status" -eq 0; then
    chown 0:0 -- "$NGINX_SOURCE" || status=$?
    chmod 0644 -- "$NGINX_SOURCE" || status=$?
  fi
  if test "$status" -eq 0; then
    cmp -- "$NGINX_SOURCE" "$ROLLBACK" || status=$?
  fi
  if test "$status" -eq 0; then
    nginx -t || status=$?
  fi
  if test "$status" -eq 0; then
    systemctl reload nginx || status=$?
  fi
  if test "$status" -eq 0; then
    prove_primary_external "$primary_spki_before_switch"
    status=$?
  fi
  if test "$status" -eq 0; then
    prove_service_invariants "$migration_before"
    status=$?
  fi
  if test "$status" -eq 0; then
    prove_lineages_retained
    status=$?
  fi
  if test "$status" -eq 0; then
    prove_saved_spkis
    status=$?
  fi
  restore_in_progress=0
  return "$status"
}

finish_failure() {
  local original_status=$1 failed_stage=$2 restore_status cleanup_status=0
  trap - EXIT INT TERM
  set +e
  restore_primary_once
  restore_status=$?
  if test "$restore_status" -eq 0; then
    armed=0
    if test -n "$candidate"; then
      rm -f -- "$candidate" || cleanup_status=$?
    fi
    if test "$cleanup_status" -eq 0; then
      rmdir -- "$ROLLBACK_DIR" || cleanup_status=$?
    fi
    if test "$cleanup_status" -eq 0; then
      rm -f -- "$ROLLBACK" || cleanup_status=$?
    fi
    if test "$cleanup_status" -ne 0; then
      printf 'restore_failure original_status=%s stage=cleanup\n' \
        "$original_status" >&2
      exit 91
    fi
    printf 'restored original_status=%s stage=%s\n' \
      "$original_status" "$failed_stage" >&2
    exit "$original_status"
  fi
  printf 'restore_failure original_status=%s stage=%s restore_status=%s\n' \
    "$original_status" "$failed_stage" "$restore_status" >&2
  exit 91
}

on_exit() {
  local status=$?
  test "$status" -ne 0 || status=70
  if test "$restore_in_progress" -eq 1; then
    trap - EXIT INT TERM
    armed=0
    printf 'restore_failure original_status=%s stage=restore-interrupted\n' \
      "$status" >&2
    exit 91
  fi
  test "$armed" -eq 1 || exit "$status"
  finish_failure "$status" "$stage"
}
on_int() {
  if test "$restore_in_progress" -eq 1; then
    trap - EXIT INT TERM
    armed=0
    printf 'restore_failure original_status=130 stage=restore-interrupted\n' >&2
    exit 91
  fi
  finish_failure 130 "$stage"
}
on_term() {
  if test "$restore_in_progress" -eq 1; then
    trap - EXIT INT TERM
    armed=0
    printf 'restore_failure original_status=143 stage=restore-interrupted\n' >&2
    exit 91
  fi
  finish_failure 143 "$stage"
}
```

The `finish_failure` function disables traps before failure restoration and
runs with `set +e`. The normal path keeps all traps armed while the checked
restore runs; `restore_in_progress` makes a signal during that proof a
critical failure without recursively invoking restoration. A successful
restore exits with the original nonzero trigger. A restore failure exits `91`,
reports only sanitized status/stage values, and retains the rollback copy and
both lineages. An armed zero-status `EXIT` is treated as trigger `70`. The
handlers make exactly one restore attempt.

### Switch, proof, and normal restoration

Run the source copy and candidate construction only after the routine above
has been reviewed in the current shell:

```bash
set -euo pipefail
cid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q backend)
pgid=$(/usr/local/libexec/meet-production/production-compose.sh ps -q postgres)
primary_spki_before_switch=$(spki_from_cert \
  /etc/letsencrypt/live/api.whysoezzy.online/cert.pem)
rollover_spki_before_switch=$(spki_from_cert \
  /etc/letsencrypt/live/api.whysoezzy.online-rollover/cert.pem)
test "$primary_spki_before_switch" = "$primary_spki"
test "$rollover_spki_before_switch" = "$rollover_spki"
migration_before=$(docker exec "$pgid" psql -Atqc \
  'SELECT installed_rank,version,description,type,script,checksum,success FROM flyway_schema_history ORDER BY installed_rank' |
  sha256sum | awk '{print $1}')
[[ "$migration_before" =~ ^[0-9a-f]{64}$ ]]
test ! -e "$ROLLBACK_DIR"
test ! -L "$ROLLBACK_DIR"
test ! -e "$ROLLBACK"
test ! -L "$ROLLBACK"
mkdir --mode=0700 -- "$ROLLBACK_DIR"
test "$(stat -c '%u:%g:%a' -- "$ROLLBACK_DIR")" = 0:0:700
test ! -e "$ROLLBACK"
test ! -L "$ROLLBACK"
test "$(stat -c '%h' -- "$NGINX_SOURCE")" = 1
cp -- "$NGINX_SOURCE" "$ROLLBACK"
chown 0:0 -- "$ROLLBACK"
chmod 0600 -- "$ROLLBACK"
test "$(stat -c '%u:%g:%a:%h' -- "$ROLLBACK")" = 0:0:600:1

trap on_exit EXIT
trap on_int INT
trap on_term TERM
armed=1

stage=render-candidate
candidate=$(mktemp "$ROLLBACK_DIR/candidate.XXXXXX")
chown 0:0 -- "$candidate"
chmod 0600 -- "$candidate"
sed \
  -e 's#^[[:space:]]*ssl_certificate[[:space:]].*#    ssl_certificate /etc/letsencrypt/live/api.whysoezzy.online-rollover/fullchain.pem;#' \
  -e 's#^[[:space:]]*ssl_certificate_key[[:space:]].*#    ssl_certificate_key /etc/letsencrypt/live/api.whysoezzy.online-rollover/privkey.pem;#' \
  "$NGINX_SOURCE" >"$candidate"
test "$(grep -Ec '^[[:space:]]*ssl_certificate ' "$NGINX_SOURCE")" = 1
test "$(grep -Ec '^[[:space:]]*ssl_certificate_key ' "$NGINX_SOURCE")" = 1
test "$(grep -Ec '^[[:space:]]*ssl_certificate ' "$candidate")" = 1
test "$(grep -Ec '^[[:space:]]*ssl_certificate_key ' "$candidate")" = 1
diff_lines=$(diff -u "$NGINX_SOURCE" "$candidate" |
  grep -E '^[+-][^+-]' || true)
test "$(printf '%s\n' "$diff_lines" | sed '/^$/d' | wc -l)" = 4
printf '%s\n' "$diff_lines" |
  grep -Ev '^[+-][[:space:]]*ssl_certificate(_key)?[[:space:]]' >/dev/null &&
  exit 70 || true
install -o 0 -g 0 -m 0644 "$candidate" "$NGINX_SOURCE"
rm -f -- "$candidate"
candidate=
test "$(stat -c '%u:%g:%a:%h' -- "$NGINX_SOURCE")" = 0:0:644:1
stage=nginx-test
nginx -t
stage=nginx-reload
systemctl reload nginx

stage=rollover-proof
prove_service_invariants "$migration_before"
test "$(openssl s_client -connect api.whysoezzy.online:443 \
  -servername api.whysoezzy.online -verify_hostname api.whysoezzy.online \
  -verify_return_error </dev/null 2>/dev/null |
  openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER |
  openssl dgst -sha256 -binary | base64 | tr -d '\r\n')" =
  "$rollover_spki"
test "$(grep -c \
  'ssl_certificate /etc/letsencrypt/live/api.whysoezzy.online-rollover/fullchain.pem;' \
  "$NGINX_SOURCE")" = 1
test "$(grep -c \
  'ssl_certificate_key /etc/letsencrypt/live/api.whysoezzy.online-rollover/privkey.pem;' \
  "$NGINX_SOURCE")" = 1

stage=normal-restore
set +e
if restore_primary_once; then
  armed=0
  trap - EXIT INT TERM
  cleanup_status=0
  if test -n "$candidate"; then
    rm -f -- "$candidate" || cleanup_status=$?
  fi
  if test "$cleanup_status" -eq 0; then
    rmdir -- "$ROLLBACK_DIR" || cleanup_status=$?
  fi
  if test "$cleanup_status" -eq 0; then
    rm -f -- "$ROLLBACK" || cleanup_status=$?
  fi
  if test "$cleanup_status" -ne 0; then
    printf 'restore_failure original_status=0 stage=cleanup\n' >&2
    exit 91
  fi
else
  restore_status=$?
  armed=0
  trap - EXIT INT TERM
  printf 'restore_failure original_status=0 stage=normal-restore restore_status=%s\n' \
    "$restore_status" >&2
  exit 91
fi
```

The rollover proof must include the exact public hostname, valid chain, exact
rollover SPKI, `GET /meetings` 200 JSON, external actuator `404`, invalid or
unauthenticated admin `403`, backend v1.0.1, and the exact
`release=368531227 image=<Config.Image> image_id=<container Image ID>`
binding, plus user `10001:10001`, loopback binding, unpublished PostgreSQL,
named volumes, and unchanged Flyway inventory. The final proof must repeat
all of those checks with the exact primary SPKI, primary Nginx source
directives, unchanged enabled symlink, and both retained lineages.

If the switch or any proof fails, call `finish_failure <status> <stage>` while
the traps are armed; do not call `restore_primary_once` a second time. If
`INT` or `TERM` arrives, the handler uses `130` or `143`. If restoration
fails, do not remove the rollback copy, do not delete either lineage, do not
retry, and do not mutate any other service.

## Rollback review and isolated simulation

Before authorizing a live drill, review or simulate the control flow in an
isolated temporary directory. The simulation must demonstrate:

1. `EXIT` captures its original status and a zero-status armed `EXIT` becomes
   nonzero.
2. `INT` and `TERM` use exactly `130` and `143`.
3. switch, `nginx -t`, reload, TLS, endpoint, runtime, and database proof
   failures invoke one handler restore attempt.
4. all three traps are disabled before failure restoration and `set +e` is
   active during restoration.
5. successful restoration returns the original nonzero trigger.
6. restore validation/reload/external-primary failure returns distinct `91`,
   reports only sanitized original-trigger/stage evidence, and leaves the
   rollback copy and both lineages.
7. normal restoration is an explicitly checked conditional while armed, and
   cleanup occurs only after complete external primary proof.

This review must not alter a live Nginx file, Certbot lineage, backend,
database, volume, release, DNS record, or environment. A passing simulation
does not replace the live test-edge evidence.

## Sanitized evidence templates

After merge, add a task comment titled **Implementation result** containing
the changed path, design decisions, verification commands/results, commit
SHA, branch, PR URL targeting `dev`, and caveats. After the drill, add a
separate comment titled **Post-drill sanitized evidence**. The latter may
contain only:

```text
phase=post-drill
classification=test-edge-evidence-not-production-certification
hostname=api.whysoezzy.online
actual_merge_commit=<40-hex>
runbook_blob=<40-hex>
primary_live_spki=<canonical-base64-sha256>
rollover_live_spki=<canonical-base64-sha256>
primary_spki_unchanged=yes
rollover_spki_unchanged=yes
distinct_live_spkis=yes
primary_cert_key_public_digest_match=yes
rollover_cert_key_public_digest_match=yes
primary_staging_dry_run=success
rollover_staging_dry_run=success
temporary_staging_certificate_spki=not-observable-not-claimed
rollover_hostname_chain=pass
restored_primary_hostname_chain=pass
meetings_status=200
actuator_status=404
admin_status=403
backend_version=1.0.1
release=368531227
release_running_image_binding=pass
backend_user=10001:10001
backend_listener=127.0.0.1:8080
postgres_published=no
named_volumes=unchanged
flyway_inventory=unchanged
nginx_source_topology=restored
primary_active=yes
both_lineages_retained=yes
restore_status=<sanitized outcome>
```

Do not include PEM, certificate bytes, key material, raw logs, request
headers, cookies, tokens, account or environment values, database data,
credentials, provider payloads, or secret-like command output. Public
certificate metadata and canonical Base64 SHA-256 SPKIs are allowed. The
evidence is test-edge evidence for a later separately authorized Android
decision; it is not production certification.
