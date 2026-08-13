#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOL=$ROOT/scripts/leaf-spki-rollover.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() { echo "leaf SPKI rollover fixture failed: $1" >&2; exit 1; }

make_completed_fixture() {
  local fixture=$1 manifest source_digest rollback_digest source_path
  mkdir -p "$fixture/recovery/completed" "$fixture/state" "$fixture/observations"
  chmod 700 "$fixture/recovery" "$fixture/recovery/completed" "$fixture/state"
  source_path=$(cd "$fixture" && pwd -P)/nginx-source.conf
  printf '%s\n' \
    'server_name api.whysoezzy.online;' \
    'ssl_certificate /etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem;' \
    'ssl_certificate_key /etc/letsencrypt/live/api.whysoezzy.online/privkey.pem;' \
    >"$fixture/nginx-source.conf"
  printf '%064d\n' 0 >"$fixture/topology.digest"
  printf '%s\n' rollback >"$fixture/recovery/completed/nginx-source.rollback"
  source_digest=$(sha256sum "$fixture/nginx-source.conf" | awk '{print $1}')
  rollback_digest=$(sha256sum "$fixture/recovery/completed/nginx-source.rollback" |
    awk '{print $1}')
  printf 'hostname=api.whysoezzy.online\nchain=VERIFIED\nspki=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' \
    >"$fixture/observations/external-primary.kv"
  printf 'status=GREEN\n' >"$fixture/observations/advisory.kv"
  manifest=$fixture/recovery/completed/manifest.kv
  {
    printf 'schema=1\nhostname=api.whysoezzy.online\nsource_path=%s\n' "$source_path"
    printf 'source_digest=%s\nrollback_digest=%s\n' "$source_digest" "$rollback_digest"
    printf 'primary_spki=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n'
    printf 'source_uid=%s\nsource_gid=%s\nsource_mode=%s\n' \
      "$(stat -c '%u' "$fixture/nginx-source.conf")" \
      "$(stat -c '%g' "$fixture/nginx-source.conf")" \
      "$(stat -c '%a' "$fixture/nginx-source.conf")"
    printf 'tool_revision=%s\n' d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
    printf 'topology_digest=%s\n' "$(cat "$fixture/topology.digest")"
    printf 'primary_certificate=/etc/letsencrypt/live/api.whysoezzy.online/fullchain.pem\n'
    printf 'primary_key=/etc/letsencrypt/live/api.whysoezzy.online/privkey.pem\n'
    printf 'candidate_digest=%s\n' "$source_digest"
    printf 'mixed_certificate_digest=%s\n' "$source_digest"
    printf 'mixed_key_digest=%s\n' "$source_digest"
  } >"$manifest"
  printf 'self_sha256=%s\n' "$(sha256sum "$manifest" | awk '{print $1}')" >>"$manifest"
  chmod 600 "$fixture/recovery/completed/"*
}

run_fixture() {
  LEAF_SPKI_FIXTURE_ROOT=$1 "$TOOL" restore --confirm-restore=RESTORE-PRIMARY
}

make_completed_fixture "$TMP/green"
run_fixture "$TMP/green" || fail "valid completed finalization did not return 0"
grep -Fx parent-sync "$TMP/green/effects.log" >/dev/null || fail "sync missing"
grep -Fx evidence-persist "$TMP/green/effects.log" >/dev/null || fail "evidence missing"
! grep -E 'nginx|certbot|rename|unlink|rmdir|compose|database' \
  "$TMP/green/effects.log" >/dev/null || fail "forbidden effect recorded"

make_completed_fixture "$TMP/drift"
sed -i 's/status=GREEN/status=DRIFT/' "$TMP/drift/observations/advisory.kv"
if run_fixture "$TMP/drift"; then fail "drift returned 0"; else test "$?" -eq 10 || fail "drift status"; fi

make_completed_fixture "$TMP/sync-failure"
if LEAF_SPKI_FAIL_SYNC=1 run_fixture "$TMP/sync-failure"; then
  fail "sync failure returned success"
else
  test "$?" -eq 73 || fail "sync failure status"
fi
test -d "$TMP/sync-failure/recovery/completed" || fail "completed was not retained"

make_completed_fixture "$TMP/source-drift"
printf '%s\n' unrelated >>"$TMP/source-drift/nginx-source.conf"
if run_fixture "$TMP/source-drift"; then fail "source drift returned 0"; else test "$?" -eq 20 || fail "source drift status"; fi
test ! -e "$TMP/source-drift/effects.log" || fail "source drift caused effect"

make_completed_fixture "$TMP/unknown"
mkdir "$TMP/unknown/recovery/unknown"
if run_fixture "$TMP/unknown"; then fail "unknown sibling accepted"; else test "$?" -eq 65 || fail "unknown status"; fi
test ! -e "$TMP/unknown/effects.log" || fail "unknown sibling caused effect"

make_completed_fixture "$TMP/cli"
if "$TOOL" restore --confirm-restore=RESTORE-PRIMARY extra >/dev/null 2>&1; then
  fail "extra argument accepted"
else
  test "$?" -eq 64 || fail "extra argument status"
fi

echo "leaf SPKI rollover fixtures passed"
