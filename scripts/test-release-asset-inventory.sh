#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER=$ROOT_DIR/scripts/release-asset-inventory.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/release-asset-inventory-incident.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

EXPECTED_DIGEST=a7a762e42d972e3131090effe5706265e03d21de8d47c7d2761f65096e7fa3f9
EXPECTED_CANONICAL='[{"name":"SHA256SUMS","id":508490119,"size":255,"state":"uploaded","created_at":"2026-08-10T08:13:11Z","updated_at":"2026-08-10T08:13:12Z","url":"https://api.github.com/repos/NickolayMamonov/meet-backend-v3/releases/assets/508490119"},{"name":"image-index.json","id":508490090,"size":856,"state":"uploaded","created_at":"2026-08-10T08:13:10Z","updated_at":"2026-08-10T08:13:11Z","url":"https://api.github.com/repos/NickolayMamonov/meet-backend-v3/releases/assets/508490090"},{"name":"image-inspect.txt","id":508490102,"size":1047,"state":"uploaded","created_at":"2026-08-10T08:13:11Z","updated_at":"2026-08-10T08:13:11Z","url":"https://api.github.com/repos/NickolayMamonov/meet-backend-v3/releases/assets/508490102"},{"name":"release-manifest.json","id":508490083,"size":661,"state":"uploaded","created_at":"2026-08-10T08:13:10Z","updated_at":"2026-08-10T08:13:10Z","url":"https://api.github.com/repos/NickolayMamonov/meet-backend-v3/releases/assets/508490083"}]'

"$HELPER" canonical-json --release-file "$FIXTURE" >"$TMP/canonical.json"
canonical=$(cat "$TMP/canonical.json")
[ "$canonical" = "$EXPECTED_CANONICAL" ]
[ "$(tail -c 1 "$TMP/canonical.json" | od -An -tx1 | tr -d ' ')" != 0a ]
[ "$("$HELPER" fingerprint --release-file "$FIXTURE")" = "$EXPECTED_DIGEST" ]
[ "$("$HELPER" fingerprint <"$FIXTURE")" = "$EXPECTED_DIGEST" ]

jq '
  .assets |= reverse |
  .extra = "ignored"
' "$FIXTURE" >"$TMP/shuffled.json"
[ "$("$HELPER" canonical-json --release-file "$TMP/shuffled.json")" = "$EXPECTED_CANONICAL" ]
[ "$("$HELPER" fingerprint --release-file "$TMP/shuffled.json")" = "$EXPECTED_DIGEST" ]

printf '{"assets":[]}\n' >"$TMP/empty.json"
set +e
"$HELPER" fingerprint --release-file "$TMP/empty.json" \
  >"$TMP/stdout" 2>"$TMP/stderr"
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -s "$TMP/stdout" ]
[ -s "$TMP/stderr" ]
[ "$("$HELPER" canonical-json --allow-empty --release-file "$TMP/empty.json")" = '[]' ]

expect_failure() {
  expected_status=$1
  shift
  output=$TMP/stdout
  error=$TMP/stderr
  set +e
  "$@" >"$output" 2>"$error"
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] || {
    echo "unexpected status $status, expected $expected_status" >&2
    exit 1
  }
  [ ! -s "$output" ] || {
    echo "failure emitted stdout" >&2
    exit 1
  }
  ! grep -Eq '/|unexpected|secret|Authorization' "$error" || {
    echo "failure emitted unsanitized details" >&2
    exit 1
  }
}

expect_failure 2 "$HELPER"
expect_failure 2 "$HELPER" fingerprint --unknown
expect_failure 2 "$HELPER" fingerprint --allow-empty --allow-empty
expect_failure 2 "$HELPER" fingerprint --release-file
expect_failure 2 "$HELPER" fingerprint --release-file --allow-empty
expect_failure 2 "$HELPER" fingerprint positional
set +e
"$HELPER" fingerprint --release-file "" <"$FIXTURE" \
  >"$TMP/stdout" 2>"$TMP/stderr"
status=$?
set -e
[ "$status" -eq 2 ]
[ ! -s "$TMP/stdout" ]
[ -s "$TMP/stderr" ]
! grep -Eq '/|unexpected|secret|Authorization' "$TMP/stderr"
expect_failure 1 "$HELPER" fingerprint --release-file "$TMP/missing.json"
mkdir "$TMP/directory"
expect_failure 1 "$HELPER" fingerprint --release-file "$TMP/directory"
chmod 000 "$TMP/empty.json"
if [ "$(id -u)" -ne 0 ]; then
  expect_failure 1 "$HELPER" fingerprint --release-file "$TMP/empty.json"
fi
chmod 600 "$TMP/empty.json"

for mutation in \
  '.assets = .assets[0:3]' \
  '.assets[0].name = "unexpected.txt"' \
  '.assets[1].id = .assets[0].id' \
  '.assets[0].state = "new"' \
  '.assets[0].size = 0' \
  '.assets[0].created_at = ""' \
  '.assets[0].url = null' \
  '.assets[0].id = 1.5' \
  '.assets[0].name = null' \
  '.assets = "not-an-array"' \
  '.'; do
  jq "$mutation" "$FIXTURE" >"$TMP/mutated.json"
  if [ "$mutation" = '.' ]; then
    printf '%s\n' 'not json' >"$TMP/mutated.json"
  fi
  expect_failure 1 "$HELPER" canonical-json --release-file "$TMP/mutated.json"
done

echo "release asset inventory fixtures passed: canonical bytes, full digest, ordering, policy, and failure contracts"
