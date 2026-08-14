#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOL=$ROOT/scripts/leaf-spki-rollover.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

readonly PRIMARY_SPKI=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
readonly ROLLOVER_SPKI=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
readonly OTHER_SPKI=AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=
readonly HOSTNAME=api.whysoezzy.online
readonly PRIMARY_LINEAGE=api.whysoezzy.online
readonly ROLLOVER_LINEAGE=api.whysoezzy.online-rollover
readonly PRIMARY_CERT=/etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem
readonly PRIMARY_KEY=/etc/letsencrypt/live/api.whysoezzy.online/privkey.pem
readonly ROLLOVER_CERT=/etc/letsencrypt/live/api.whysoezzy.online-rollover/fullchain.pem
readonly ROLLOVER_KEY=/etc/letsencrypt/live/api.whysoezzy.online-rollover/privkey.pem
readonly TOOL_REVISION=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc

fail() {
  printf 'leaf SPKI rollover fixture failed: %s\n' "$1" >&2
  exit 1
}

digest() {
  sha256sum -- "$1" | awk '{print $1}'
}

write_primary_source() {
  printf '%s\n' \
    "server_name $HOSTNAME;" \
    "ssl_certificate $PRIMARY_CERT;" \
    "ssl_certificate_key $PRIMARY_KEY;" \
    'location / { proxy_pass http://127.0.0.1:8080; }' \
    >"$1"
}

write_rollover_source() {
  printf '%s\n' \
    "server_name $HOSTNAME;" \
    "ssl_certificate $ROLLOVER_CERT;" \
    "ssl_certificate_key $ROLLOVER_KEY;" \
    'location / { proxy_pass http://127.0.0.1:8080; }' \
    >"$1"
}

write_mixed_source() {
  local destination=$1 kind=$2
  case "$kind" in
    certificate)
      printf '%s\n' \
        "server_name $HOSTNAME;" \
        "ssl_certificate $ROLLOVER_CERT;" \
        "ssl_certificate_key $PRIMARY_KEY;" \
        'location / { proxy_pass http://127.0.0.1:8080; }' \
        >"$destination"
      ;;
    key)
      printf '%s\n' \
        "server_name $HOSTNAME;" \
        "ssl_certificate $PRIMARY_CERT;" \
        "ssl_certificate_key $ROLLOVER_KEY;" \
        'location / { proxy_pass http://127.0.0.1:8080; }' \
        >"$destination"
      ;;
    *) fail "unknown mixed source kind $kind" ;;
  esac
}

make_fixture() {
  local fixture=$1
  mkdir -p "$fixture/observations"
  write_primary_source "$fixture/nginx-source.conf"
  printf '%064d\n' 0 >"$fixture/topology.digest"
  {
    printf 'primary_spki=%s\n' "$PRIMARY_SPKI"
    printf 'rollover_spki=%s\n' "$ROLLOVER_SPKI"
    printf 'external_rollover_spki=%s\n' "$ROLLOVER_SPKI"
    printf 'rollover_present=YES\n'
    printf 'rollover_present_after_certbot=YES\n'
    printf 'rollover_configuration=VALID\n'
    printf 'api.whysoezzy.online-rollover_configuration=VALID\n'
    printf 'certbot_version=2.9.0\n'
    printf 'primary_hooks=NONE\nrollover_hooks=NONE\nhook_directories=EMPTY\n'
    printf 'api.whysoezzy.online_configuration=VALID\n'
    printf 'api.whysoezzy.online_permissions=VALID\n'
    printf 'api.whysoezzy.online_pairing=VALID\n'
    printf 'api.whysoezzy.online_san=VALID\n'
    printf 'api.whysoezzy.online_hooks=NONE\n'
    printf 'api.whysoezzy.online-rollover_permissions=VALID\n'
    printf 'api.whysoezzy.online-rollover_pairing=VALID\n'
    printf 'api.whysoezzy.online-rollover_san=VALID\n'
    printf 'api.whysoezzy.online-rollover_hooks=NONE\n'
    printf 'webroot=/var/www/certbot\n'
    printf 'production_account=production_account\n'
    printf 'staging_account=staging_account\n'
    printf 'api_status=200\napi_shape=VALID\n'
    printf 'actuator_status=403\nadmin_status=403\n'
    printf 'backend_source=%s\nbackend_image_digest=%s\nbackend_version=1.0.1\n' \
      "$TOOL_REVISION" \
      'sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6'
    printf 'backend_user=10001:10001\nbackend_listener=127.0.0.1:8080\n'
    printf 'backend_health=healthy\ncompose_project=meet-production\ncompose_service=backend\n'
    printf 'postgres_image_digest=%s\npostgres_published=NO\n' \
      'sha256:4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2'
    printf 'backend_volume=meet-production_uploads_data\n'
    printf 'postgres_volume=meet-production_postgres_data\n'
    printf 'flyway_migration_digest=%s\n' \
      '8bdd5aa46f7efe03882e787b36eb701423d35c24eb2681759375b7f360b3277c'
  } >"$fixture/observations/leaf-spki.kv"
  printf 'hostname=%s\nchain=VERIFIED\nspki=%s\n' \
    "$HOSTNAME" "$PRIMARY_SPKI" >"$fixture/observations/external-primary.kv"
  printf 'hostname=%s\nchain=VERIFIED\nspki=%s\n' \
    "$HOSTNAME" "$ROLLOVER_SPKI" >"$fixture/observations/external-rollover.kv"
  printf 'status=GREEN\n' >"$fixture/observations/advisory.kv"
}

make_package() {
  local fixture=$1 name=$2 installed=${3:-primary}
  local package="$fixture/recovery/$name" source_path manifest
  local original candidate mixed_certificate mixed_key
  mkdir -p "$package" "$fixture/state"
  chmod 700 "$fixture/recovery" "$package" "$fixture/state"
  original=$fixture/package-original
  candidate=$fixture/package-candidate
  mixed_certificate=$fixture/package-mixed-certificate
  mixed_key=$fixture/package-mixed-key
  write_primary_source "$original"
  write_rollover_source "$candidate"
  write_mixed_source "$mixed_certificate" certificate
  write_mixed_source "$mixed_key" key
  cp -- "$original" "$package/nginx-source.rollback"
  case "$installed" in
    primary) cp -- "$original" "$fixture/nginx-source.conf" ;;
    candidate) cp -- "$candidate" "$fixture/nginx-source.conf" ;;
    mixed-certificate) cp -- "$mixed_certificate" "$fixture/nginx-source.conf" ;;
    mixed-key) cp -- "$mixed_key" "$fixture/nginx-source.conf" ;;
    *) fail "unknown installed package source $installed" ;;
  esac
  source_path=$(cd "$fixture" && pwd -P)/nginx-source.conf
  manifest=$package/manifest.kv
  {
    printf 'schema=1\nhostname=%s\nsource_path=%s\n' "$HOSTNAME" "$source_path"
    printf 'source_digest=%s\nrollback_digest=%s\n' \
      "$(digest "$original")" "$(digest "$package/nginx-source.rollback")"
    printf 'primary_spki=%s\n' "$PRIMARY_SPKI"
    printf 'source_uid=%s\nsource_gid=%s\nsource_mode=%s\n' \
      "$(stat -c '%u' "$original")" "$(stat -c '%g' "$original")" \
      "$(stat -c '%a' "$original")"
    printf 'tool_revision=%s\n' "$TOOL_REVISION"
    printf 'topology_digest=%s\n' "$(<"$fixture/topology.digest")"
    printf 'primary_certificate=%s\nprimary_key=%s\n' "$PRIMARY_CERT" "$PRIMARY_KEY"
    printf 'candidate_digest=%s\n' "$(digest "$candidate")"
    printf 'mixed_certificate_digest=%s\n' "$(digest "$mixed_certificate")"
    printf 'mixed_key_digest=%s\n' "$(digest "$mixed_key")"
  } >"$manifest"
  printf 'self_sha256=%s\n' "$(digest "$manifest")" >>"$manifest"
  chmod 600 "$package/manifest.kv" "$package/nginx-source.rollback"
}

run_tool() {
  local fixture=$1
  shift
  env LEAF_SPKI_FIXTURE_ROOT="$fixture" "$TOOL" "$@"
}

expect_status() {
  local expected=$1 label=$2
  shift 2
  local rc timer_pid=
  set +e
  "$@" >"$TMP/last.stdout" 2>"$TMP/last.stderr"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expected" ]]; then
    printf '%s\n' "--- stdout: $label ---" >&2
    sed 's/^/  /' "$TMP/last.stdout" >&2
    printf '%s\n' "--- stderr: $label ---" >&2
    sed 's/^/  /' "$TMP/last.stderr" >&2
    fail "$label returned $rc, expected $expected"
  fi
}

expect_status_bounded() {
  local expected=$1 label=$2
  shift 2
  local rc command_pid timer_pid
  set +e
  "$@" >"$TMP/last.stdout" 2>"$TMP/last.stderr" &
  command_pid=$!
  (
    sleep 10
    kill "$command_pid" 2>/dev/null || true
  ) &
  timer_pid=$!
  wait "$command_pid"
  rc=$?
  kill "$timer_pid" 2>/dev/null || true
  wait "$timer_pid" 2>/dev/null || true
  set -e
  if [[ "$rc" -ne "$expected" ]]; then
    printf '%s\n' "--- stdout: $label ---" >&2
    sed 's/^/  /' "$TMP/last.stdout" >&2
    printf '%s\n' "--- stderr: $label ---" >&2
    sed 's/^/  /' "$TMP/last.stderr" >&2
    fail "$label returned $rc, expected $expected"
  fi
}

assert_output() {
  grep -Fx -- "$1" "$TMP/last.stdout" >/dev/null ||
    fail "$2 output is missing: $1"
}

assert_effect() {
  grep -Fx -- "$2" "$1/effects.log" >/dev/null ||
    fail "$3 effect is missing: $2"
}

assert_no_effects() {
  [[ ! -s "$1/effects.log" ]] || {
    sed 's/^/  /' "$1/effects.log" >&2
    fail "$2 caused an effect"
  }
}

assert_argv() {
  local fixture=$1 label=$2
  shift 2
  local line=certbot-argv argument
  for argument in "$@"; do
    line+=$'\t'"$argument"
  done
  assert_effect "$fixture" "$line" "$label"
}

replace_observation() {
  local fixture=$1 key=$2 value=$3
  sed -i "s#^$key=.*#$key=$value#" "$fixture/observations/leaf-spki.kv"
}

make_symlink() {
  local target=$1 link=$2
  if ln -s "$target" "$link" 2>/dev/null; then
    [[ -L "$link" ]] && return 0
  fi
  return 1
}

make_file_symlink() {
  local target=$1 link=$2
  if ln -s "$target" "$link" 2>/dev/null; then
    [[ -L "$link" ]] && return 0
  fi
  return 1
}

# Exercise the complete eight-command happy path and assert the external
# process contract rather than merely accepting each exit status.
fixture=$TMP/eight-command-flow
make_fixture "$fixture"
expect_status 0 inspect run_tool "$fixture" inspect
assert_output namespace=NONE inspect
assert_output "primary_spki=$PRIMARY_SPKI" inspect
assert_effect "$fixture" evidence-persist inspect

: >"$fixture/effects.log"
expect_status 0 configure-primary run_tool "$fixture" configure-primary
assert_argv "$fixture" configure-primary \
  /usr/bin/certbot reconfigure --non-interactive --cert-name "$PRIMARY_LINEAGE" \
  --webroot --webroot-path /var/www/certbot \
  --key-type ecdsa --elliptic-curve secp256r1 --reuse-key --no-directory-hooks

: >"$fixture/effects.log"
expect_status 0 ensure-rollover-existing run_tool "$fixture" ensure-rollover
assert_output "rollover_spki=$ROLLOVER_SPKI" ensure-rollover-existing
assert_argv "$fixture" ensure-rollover-existing \
  /usr/bin/certbot reconfigure --non-interactive --cert-name "$ROLLOVER_LINEAGE" \
  --webroot --webroot-path /var/www/certbot \
  --key-type ecdsa --elliptic-curve secp256r1 --reuse-key --no-directory-hooks

: >"$fixture/effects.log"
expect_status 0 configure-rollover run_tool "$fixture" configure-rollover
! grep -F 'certbot-' "$fixture/effects.log" >/dev/null ||
  fail "configure-rollover invoked Certbot"

: >"$fixture/effects.log"
expect_status 0 verify-primary-renewal run_tool "$fixture" verify-primary-renewal
assert_argv "$fixture" verify-primary-renewal \
  /usr/bin/certbot renew --non-interactive --cert-name "$PRIMARY_LINEAGE" \
  --dry-run --server https://acme-staging-v02.api.letsencrypt.org/directory \
  --account staging_account --no-directory-hooks

: >"$fixture/effects.log"
expect_status 0 verify-rollover-renewal run_tool "$fixture" verify-rollover-renewal
assert_argv "$fixture" verify-rollover-renewal \
  /usr/bin/certbot renew --non-interactive --cert-name "$ROLLOVER_LINEAGE" \
  --dry-run --server https://acme-staging-v02.api.letsencrypt.org/directory \
  --account staging_account --no-directory-hooks

: >"$fixture/effects.log"
expect_status 0 drill run_tool "$fixture" drill
test -d "$fixture/recovery/completed" || fail "drill did not publish completed"
test ! -e "$fixture/recovery/active" || fail "drill retained active"
write_primary_source "$TMP/expected-primary"
cmp -s "$TMP/expected-primary" "$fixture/nginx-source.conf" ||
  fail "drill did not restore the primary Nginx source"
assert_effect "$fixture" preparing-to-active drill
assert_effect "$fixture" active-to-completed drill
assert_effect "$fixture" nginx-test drill
assert_effect "$fixture" nginx-reload drill
assert_effect "$fixture" parent-sync drill
assert_argv "$fixture" drill-primary-renewal \
  /usr/bin/certbot renew --non-interactive --cert-name "$PRIMARY_LINEAGE" \
  --dry-run --no-directory-hooks
assert_argv "$fixture" drill-rollover-renewal \
  /usr/bin/certbot renew --non-interactive --cert-name "$ROLLOVER_LINEAGE" \
  --dry-run --no-directory-hooks
grep -Fx restore_mode=DRILL "$fixture/state/evidence.kv" >/dev/null ||
  fail "drill evidence did not supersede restore evidence"

# The absent-lineage branch is a distinct Certbot package contract.
fixture=$TMP/ensure-absent
make_fixture "$fixture"
replace_observation "$fixture" rollover_present NO
expect_status 0 ensure-rollover-absent run_tool "$fixture" ensure-rollover
assert_argv "$fixture" ensure-rollover-absent \
  /usr/bin/certbot certonly --non-interactive \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --account production_account --webroot --webroot-path /var/www/certbot \
  --domains "$HOSTNAME" \
  --cert-name "$ROLLOVER_LINEAGE" --key-type ecdsa \
  --elliptic-curve secp256r1 --new-key --reuse-key --no-directory-hooks

# Active-only restore accepts each explicitly bound intermediate and ends in
# completed. Completed-only finalization has a deliberately tiny effect set.
for installed in primary candidate mixed-certificate mixed-key; do
  fixture=$TMP/active-$installed
  make_fixture "$fixture"
  make_package "$fixture" active "$installed"
  expect_status 0 "active restore $installed" \
    run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
  test -d "$fixture/recovery/completed" ||
    fail "active restore $installed did not publish completed"
  test ! -e "$fixture/recovery/active" ||
    fail "active restore $installed retained active"
  if [[ "$installed" = primary ]]; then
    ! grep -E '^nginx-(install|test|reload)$' "$fixture/effects.log" >/dev/null ||
      fail "active restore primary needlessly changed Nginx"
  else
    assert_effect "$fixture" nginx-install "active restore $installed"
    assert_effect "$fixture" nginx-test "active restore $installed"
    assert_effect "$fixture" nginx-reload "active restore $installed"
  fi
  assert_effect "$fixture" active-to-completed "active restore $installed"
done

fixture=$TMP/completed-only
make_fixture "$fixture"
make_package "$fixture" completed primary
expect_status 0 completed-only \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
printf '%s\n' parent-sync evidence-persist >"$TMP/completed-effects"
cmp -s "$TMP/completed-effects" "$fixture/effects.log" ||
  fail "completed-only restore recorded a forbidden effect"
test -d "$fixture/recovery/completed" ||
  fail "completed-only restore removed recovery authority"

# Advisory drift is terminal and proved, while a failed rollover proof is an
# advisory drill failure only after a complete successful primary restore.
fixture=$TMP/advisory-drill
make_fixture "$fixture"
printf 'status=DRIFT\n' >"$fixture/observations/advisory.kv"
rm -f "$fixture/observations/external-rollover.kv"
expect_status 10 advisory-drill run_tool "$fixture" drill
grep -Fx outcome=DRILL_FAILED_PRIMARY_RESTORED "$fixture/state/evidence.kv" >/dev/null ||
  fail "advisory drill outcome was not retained"
grep -Fx invariant_status=ADVISORY_DRIFT "$fixture/state/evidence.kv" >/dev/null ||
  fail "advisory drill status was not retained"

fixture=$TMP/rollover-proof-failure
make_fixture "$fixture"
expect_status 10 rollover-proof-failure env \
  LEAF_SPKI_FIXTURE_ROOT="$fixture" LEAF_SPKI_FAIL_ROLLOVER_PROOF=1 "$TOOL" drill
test -d "$fixture/recovery/completed" ||
  fail "failed rollover proof did not complete primary restoration"

# Nginx test/reload failures also apply to restoration. They therefore return
# RESTORE_INCOMPLETE and retain active recovery authority for a clean retry.
for knob in LEAF_SPKI_FAIL_NGINX_TEST LEAF_SPKI_FAIL_NGINX_RELOAD; do
  fixture=$TMP/${knob#LEAF_SPKI_FAIL_}
  make_fixture "$fixture"
  expect_status 20 "$knob drill" env \
    LEAF_SPKI_FIXTURE_ROOT="$fixture" "$knob"=1 "$TOOL" drill
  test -d "$fixture/recovery/active" ||
    fail "$knob did not retain active recovery authority"
  test ! -e "$fixture/recovery/completed" ||
    fail "$knob incorrectly published completed"
  unset "$knob"
  expect_status 0 "$knob retry" \
    run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
done

# Certbot failures are always 74 and do
# not cross an Nginx or recovery-package boundary.
fixture=$TMP/certbot-failure
make_fixture "$fixture"
expect_status 74 certbot-failure env \
  LEAF_SPKI_FIXTURE_ROOT="$fixture" LEAF_SPKI_FAIL_CERTBOT_OPERATION=primary-reconfigure \
  "$TOOL" configure-primary
assert_argv "$fixture" certbot-failure \
  /usr/bin/certbot reconfigure --non-interactive --cert-name "$PRIMARY_LINEAGE" \
  --webroot --webroot-path /var/www/certbot \
  --key-type ecdsa --elliptic-curve secp256r1 --reuse-key --no-directory-hooks
! grep -E 'nginx|preparing-to-active|active-to-completed' "$fixture/effects.log" >/dev/null ||
  fail "Certbot failure crossed a forbidden boundary"

# SPKI and lineage observations must be complete, canonical, stable, and
# distinct from the primary.
fixture=$TMP/equal-spki
make_fixture "$fixture"
replace_observation "$fixture" rollover_spki "$PRIMARY_SPKI"
expect_status 65 equal-spki run_tool "$fixture" ensure-rollover

fixture=$TMP/partial-lineage
make_fixture "$fixture"
replace_observation "$fixture" rollover_present MAYBE
expect_status 69 partial-lineage run_tool "$fixture" ensure-rollover

fixture=$TMP/missing-lineage-spki
make_fixture "$fixture"
sed -i '/^rollover_spki=/d' "$fixture/observations/leaf-spki.kv"
expect_status 69 missing-lineage-spki run_tool "$fixture" ensure-rollover

fixture=$TMP/conflicting-lineage
make_fixture "$fixture"
replace_observation "$fixture" rollover_spki "$OTHER_SPKI"
replace_observation "$fixture" rollover_configuration INVALID
expect_status 65 conflicting-lineage run_tool "$fixture" configure-rollover
assert_no_effects "$fixture" conflicting-lineage

fixture=$TMP/noncanonical-spki
make_fixture "$fixture"
sed -i "s#^primary_spki=.*#primary_spki=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB=#" \
  "$fixture/observations/leaf-spki.kv"
expect_status 20 noncanonical-spki run_tool "$fixture" inspect
assert_no_effects "$fixture" noncanonical-spki

fixture=$TMP/hidden-unknown-recovery
make_fixture "$fixture"
mkdir -p "$fixture/recovery"
chmod 700 "$fixture/recovery"
printf 'hidden\n' >"$fixture/recovery/.unknown"
expect_status 65 hidden-unknown-recovery run_tool "$fixture" inspect
assert_no_effects "$fixture" hidden-unknown-recovery

fixture=$TMP/certbot-ambiguous
make_fixture "$fixture"
expect_status 76 certbot-ambiguous env \
  LEAF_SPKI_FIXTURE_ROOT="$fixture" \
  LEAF_SPKI_FAIL_CERTBOT_OPERATION=primary-reconfigure \
  LEAF_SPKI_CERTBOT_POST_STATE=partial "$TOOL" configure-primary

# Recovery namespace/package ambiguity is rejected before effects.
fixture=$TMP/partial-package
make_fixture "$fixture"
mkdir -p "$fixture/recovery/active"
chmod 700 "$fixture/recovery" "$fixture/recovery/active"
printf 'partial\n' >"$fixture/recovery/active/manifest.kv"
chmod 600 "$fixture/recovery/active/manifest.kv"
expect_status 20 partial-package \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
assert_no_effects "$fixture" partial-package

fixture=$TMP/conflicting-packages
make_fixture "$fixture"
make_package "$fixture" active candidate
cp -R "$fixture/recovery/active" "$fixture/recovery/completed"
chmod 700 "$fixture/recovery/completed"
expect_status 65 conflicting-packages \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
assert_no_effects "$fixture" conflicting-packages

fixture=$TMP/unknown-package
make_fixture "$fixture"
mkdir -p "$fixture/recovery/unknown"
chmod 700 "$fixture/recovery" "$fixture/recovery/unknown"
expect_status 65 unknown-package run_tool "$fixture" inspect
assert_no_effects "$fixture" unknown-package

fixture=$TMP/dangling-recovery-parent
make_fixture "$fixture"
mkdir -p "$fixture"
if make_symlink "$fixture/missing-recovery-target" "$fixture/recovery"; then
  expect_status 65 dangling-recovery-parent run_tool "$fixture" inspect
  assert_no_effects "$fixture" dangling-recovery-parent
fi

# Unsafe state paths fail closed, including paths that would otherwise permit
# atomic replacement of attacker-controlled files.
fixture=$TMP/state-symlink
make_fixture "$fixture"
mkdir -p "$fixture/elsewhere"
if make_symlink "$fixture/elsewhere" "$fixture/state"; then
  expect_status 65 state-symlink run_tool "$fixture" inspect
  assert_no_effects "$fixture" state-symlink
fi

fixture=$TMP/state-mode
make_fixture "$fixture"
printf 'unsafe\n' >"$fixture/state"
expect_status 65 state-mode run_tool "$fixture" inspect
assert_no_effects "$fixture" state-mode

fixture=$TMP/evidence-symlink
make_fixture "$fixture"
if make_file_symlink "$fixture/observations/advisory.kv" "$fixture/state/evidence.kv"; then
  expect_status 65 evidence-symlink run_tool "$fixture" inspect
  test ! -s "$fixture/effects.log" ||
    fail "evidence symlink failure recorded an unexpected effect"
  grep -Fx status=GREEN "$fixture/observations/advisory.kv" >/dev/null ||
    fail "evidence symlink target was modified"
fi

# Crash/persistence knobs retain the strongest already-published authority and
# are retryable where the contract says they are.
fixture=$TMP/active-persist-crash
make_fixture "$fixture"
expect_status 73 active-persist-crash env \
  LEAF_SPKI_FIXTURE_ROOT="$fixture" LEAF_SPKI_FAIL_ACTIVE_PERSIST=1 "$TOOL" drill
test -d "$fixture/recovery/active" ||
  fail "active persist crash did not retain active"
cmp -s "$TMP/expected-primary" "$fixture/nginx-source.conf" ||
  fail "active persist crash changed Nginx before package durability"
expect_status 0 active-persist-retry \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY

fixture=$TMP/evidence-persist-crash
make_fixture "$fixture"
expect_status 73 evidence-persist-crash env \
  LEAF_SPKI_FIXTURE_ROOT="$fixture" LEAF_SPKI_FAIL_EVIDENCE=1 "$TOOL" inspect
if [[ -e "$fixture/effects.log" ]] &&
  grep -Fx evidence-persist "$fixture/effects.log" >/dev/null; then
  fail "failed evidence persistence claimed success"
fi

for knob in LEAF_SPKI_FAIL_SYNC LEAF_SPKI_FAIL_REOPEN; do
  fixture=$TMP/${knob#LEAF_SPKI_FAIL_}-completed
  make_fixture "$fixture"
  make_package "$fixture" completed primary
  expect_status 73 "$knob completed" env \
    LEAF_SPKI_FIXTURE_ROOT="$fixture" "$knob"=1 "$TOOL" \
    restore --confirm-restore=RESTORE-PRIMARY
  test -d "$fixture/recovery/completed" ||
    fail "$knob did not retain completed"
  ! grep -E 'nginx|certbot|active-to-completed' "$fixture/effects.log" >/dev/null ||
    fail "$knob crossed a forbidden completed-only boundary"
done

# Completed-only source/package/external failures are RESTORE_INCOMPLETE with
# zero effects and immutable completed authority.
fixture=$TMP/completed-source-drift
make_fixture "$fixture"
make_package "$fixture" completed primary
printf '# drift\n' >>"$fixture/nginx-source.conf"
expect_status 20 completed-source-drift \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
assert_no_effects "$fixture" completed-source-drift
test -d "$fixture/recovery/completed" ||
  fail "source drift removed completed"

fixture=$TMP/completed-external-drift
make_fixture "$fixture"
make_package "$fixture" completed primary
sed -i "s#^spki=.*#spki=$OTHER_SPKI#" \
  "$fixture/observations/external-primary.kv"
expect_status 20 completed-external-drift \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY
assert_no_effects "$fixture" completed-external-drift

# Lock contention must be deterministic: wait until another process confirms
# ownership of this fixture's exact lock before invoking the CLI.
fixture=$TMP/lock-contention
make_fixture "$fixture"
if command -v flock >/dev/null 2>&1; then
  (
    exec 9>"$fixture/rollover.lock"
    flock 9
    : >"$fixture/lock-held"
    while [[ ! -e "$fixture/release-lock" ]]; do sleep 0.05; done
  ) &
  lock_pid=$!
  for _ in {1..200}; do
    [[ -e "$fixture/lock-held" ]] && break
    sleep 0.01
  done
  [[ -e "$fixture/lock-held" ]] || fail "lock holder did not become ready"
  expect_status_bounded 75 lock-contention run_tool "$fixture" inspect
  : >"$fixture/release-lock"
  wait "$lock_pid"
else
  mkdir "$fixture/rollover.lock.d"
  expect_status_bounded 75 lock-contention run_tool "$fixture" inspect
  rmdir "$fixture/rollover.lock.d"
fi
assert_no_effects "$fixture" lock-contention

# The wrapper rejects malformed invocations before fixture admission or any
# completed-package effect.
fixture=$TMP/malformed-cli
make_fixture "$fixture"
make_package "$fixture" completed primary
expect_status 64 cli-no-command "$TOOL"
expect_status 64 cli-unknown "$TOOL" explode
expect_status 64 cli-extra run_tool "$fixture" inspect extra
expect_status 64 cli-restore-missing run_tool "$fixture" restore
expect_status 64 cli-restore-wrong \
  run_tool "$fixture" restore --confirm-restore=WRONG
expect_status 64 cli-restore-extra \
  run_tool "$fixture" restore --confirm-restore=RESTORE-PRIMARY extra
assert_no_effects "$fixture" malformed-cli

printf 'leaf SPKI rollover fixtures passed\n'
