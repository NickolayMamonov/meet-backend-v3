#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ADMIT="$ROOT_DIR/scripts/admit-test-image.sh"
FIXTURE_DIR="$ROOT_DIR/scripts/fixtures/test-image-admission"
SOURCE=$(jq -r '.source' "$FIXTURE_DIR/scenarios.json")
VERSION=$(jq -r '.version' "$FIXTURE_DIR/scenarios.json")
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

IMAGE='ghcr.io/nickolaymamonov/meet-backend-v3'
ALIAS="test-sha-$SOURCE"
REUSABLE="$FIXTURE_DIR/reusable.json"
SHIM="$FIXTURE_DIR/input-command.sh"

expected_json() {
  local alias=$1 state=$2 reason=$3
  jq -cnS \
    --arg alias "$alias" --arg image "$IMAGE" --arg reason "$reason" \
    --arg source "$SOURCE" --arg state "$state" \
    '{alias:$alias,image:$image,reason:$reason,source:$source,state:$state}'
}

make_fixture() {
  local name=$1 output=$TMP/$1.json
  case "$name" in
    absent) jq -cn '{schema:"meet-backend/test-image-state/v2",bindings:[]}' >"$output" ;;
    reusable) cp "$REUSABLE" "$output" ;;
    duplicate) jq '.bindings += [.bindings[0]]' "$REUSABLE" >"$output" ;;
    mismatch) jq '.bindings[0].root.manifests[0].digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$REUSABLE" >"$output" ;;
    evidence-gap) jq 'del(.bindings[0].referrers[0])' "$REUSABLE" >"$output" ;;
    partial) jq 'del(.bindings[0].platform.labels["org.opencontainers.image.version"])' "$REUSABLE" >"$output" ;;
    protected-alias) jq '.bindings = [{alias:"v1.2.3"}]' "$REUSABLE" >"$output" ;;
    unknown-alias) jq '.bindings = [{alias:"not-owned"}]' "$REUSABLE" >"$output" ;;
    *) echo "unknown fixture: $name" >&2; exit 1 ;;
  esac
  printf '%s\n' "$output"
}

run_case() {
  local name=$1 expected_state=$2 expected_reason=$3 mode=${4:-inspect}
  local input actual status expected expected_status
  input=$(make_fixture "$name")
  expected=$(expected_json "$ALIAS" "$expected_state" "$expected_reason")
  expected_status=0
  [ "$expected_state" = rejected ] && expected_status=1
  [ "$mode" = verify ] && [ "$expected_state" = absent ] && expected_status=1
  set +e
  actual=$(bash "$ADMIT" "$mode" --source "$SOURCE" --version "$VERSION" \
    --input "$input" 2>"$TMP/$name.$mode.stderr")
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] ||
    { echo "$name/$mode: unexpected exit status $status" >&2; exit 1; }
  [ "$actual" = "$expected" ] ||
    { echo "$name/$mode: unexpected JSON output" >&2; exit 1; }
  [ "$(jq -cS . <<<"$actual")" = "$actual" ] ||
    { echo "$name/$mode: output is not canonical compact sorted JSON" >&2; exit 1; }
}

command -v jq >/dev/null 2>&1
bash -n "$ADMIT"
run_case absent absent no-binding inspect
run_case absent absent no-binding verify
run_case reusable reusable complete inspect
run_case reusable reusable complete verify
run_case duplicate rejected duplicate-binding
run_case mismatch rejected partial-binding
run_case evidence-gap rejected referrer-closure
run_case partial rejected partial-binding
run_case protected-alias rejected protected-alias
run_case unknown-alias rejected unknown-alias

command_output=$(bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input-command "$SHIM" --output "$TMP/command-output.json")
[ "$command_output" = "$(expected_json "$ALIAS" reusable complete)" ]
[ "$(cat "$TMP/command-output.json")" = "$command_output" ]

if ln -s "$TMP/secret-target" "$TMP/symlink-output" 2>/dev/null; then
  printf 'sentinel\n' >"$TMP/secret-target"
  set +e
  bash "$ADMIT" inspect --source "$SOURCE" --version "$VERSION" \
    --input "$TMP/absent.json" --output "$TMP/symlink-output" \
    >"$TMP/symlink.stdout" 2>"$TMP/symlink.stderr"
  symlink_status=$?
  set -e
  [ "$symlink_status" -eq 2 ]
  [ "$(cat "$TMP/secret-target")" = sentinel ]
fi

echo "test image admission fixtures passed: absent, reusable, duplicates, mismatch, evidence gap, partial, protected, unknown, command shim, symlink output"
