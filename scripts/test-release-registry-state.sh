#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$ROOT_DIR/scripts/release-registry-state.sh"
FAKE_DOCKER="$ROOT_DIR/scripts/fixtures/release-registry-state/fake-docker.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

mkdir "$TMP/bin"
cp "$FAKE_DOCKER" "$TMP/bin/docker"
chmod +x "$TMP/bin/docker"
PATH="$TMP/bin:$PATH"
export PATH

IMAGE=ghcr.io/example/meet-backend
VERSION=1.0.1
SOURCE_SHA=0123456789abcdef0123456789abcdef01234567

run_inspection() {
  local latest_state=$1 expected_status=$2 output_file=$3 quarantine_file=$4
  export FAKE_LATEST_STATE=$latest_state
  set +e
  "$CHECKER" inspect "$IMAGE" "$VERSION" "$SOURCE_SHA" \
    --quarantine-file "$quarantine_file" >"$output_file" 2>"$output_file.err"
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ]
}

ABSENT_OUTPUT=$TMP/absent.out
run_inspection absent 0 "$ABSENT_OUTPUT" "$TMP/absent.json"
grep -Fx 'latest=absent' "$ABSENT_OUTPUT"
grep -Fx 'state=empty' "$ABSENT_OUTPUT"

PRESENT_OUTPUT=$TMP/present.out
run_inspection present 42 "$PRESENT_OUTPUT" "$TMP/present.json"
grep -Fx 'latest=present' "$PRESENT_OUTPUT"
grep -Fx 'state=quarantined' "$PRESENT_OUTPUT"
jq -e '.registryWrites == 0 and .latestPresent == true' "$TMP/present.json" >/dev/null

ERROR_OUTPUT=$TMP/error.out
run_inspection error 1 "$ERROR_OUTPUT" "$TMP/error.json"
grep -Fx 'latest=inspection-failed' "$ERROR_OUTPUT"
grep -Fx 'state=inspection-failed' "$ERROR_OUTPUT"
[ ! -e "$TMP/error.json" ]

WORKFLOW="$ROOT_DIR/.github/workflows/release-please.yml"
grep -Fq '[ "$latest" = absent ]' "$WORKFLOW"
grep -Fq 'release-registry-state.sh inspect "$IMAGE" "$VERSION" "$SOURCE_SHA"' "$WORKFLOW"
echo "release registry latest preflight fixtures passed: absent, present, inspection-error"
