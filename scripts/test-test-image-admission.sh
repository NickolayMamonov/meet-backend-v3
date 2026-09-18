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
ROOT_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PLATFORM_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REUSABLE="$FIXTURE_DIR/reusable.json"
SHIM="$FIXTURE_DIR/input-command.sh"

expected_json() {
  local state=$1 reason=$2
  if [ "$state" = reusable ] || [ "$state" = partial ]; then
    jq -cnS --arg alias "$ALIAS" --arg image "$IMAGE" --arg reason "$reason" \
      --arg source "$SOURCE" --arg state "$state" --arg root "$ROOT_DIGEST" \
      --arg platform "$PLATFORM_DIGEST" --arg attestation \
      "$([ "$state" = partial ] && echo missing || echo verified)" \
      '{alias:$alias,image:$image,reason:$reason,source:$source,state:$state,
        rootDigest:$root,platformDigest:$platform,attestationStatus:$attestation}'
  else
    jq -cnS --arg alias "$ALIAS" --arg image "$IMAGE" --arg reason "$reason" \
      --arg source "$SOURCE" --arg state "$state" \
      '{alias:$alias,image:$image,reason:$reason,source:$source,state:$state}'
  fi
}

make_fixture() {
  local name=$1 output=$TMP/$1.json
  case "$name" in
    absent) jq -cn '{bindings:[]}' >"$output" ;;
    reusable) cp "$REUSABLE" "$output" ;;
    duplicate) jq '.bindings += [.bindings[0]]' "$REUSABLE" >"$output" ;;
    mismatch) jq '.bindings[0].root.manifests[0].digest = "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"' "$REUSABLE" >"$output" ;;
    evidence-gap) jq 'del(.bindings[0].referrers[0])' "$REUSABLE" >"$output" ;;
    partial)
      jq '.bindings[0].attestationStatus = "missing" | .bindings[0].githubAttestations = []' \
        "$REUSABLE" >"$output"
      ;;
    missing-with-claims)
      jq '.bindings[0].attestationStatus = "missing"' "$REUSABLE" >"$output"
      ;;
    missing-status)
      jq '.bindings[0].githubAttestations = []' "$REUSABLE" >"$output"
      ;;
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
  expected=$(expected_json "$expected_state" "$expected_reason")
  expected_status=0
  [ "$expected_state" = rejected ] && expected_status=1
  [ "$mode" = verify ] && [ "$expected_state" != reusable ] && expected_status=1
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
run_case partial partial missing-github-attestation inspect
run_case partial partial missing-github-attestation verify
run_case duplicate rejected duplicate-binding
run_case mismatch rejected partial-binding
run_case evidence-gap rejected referrer-closure
run_case missing-with-claims rejected partial-binding
run_case missing-status rejected missing-attestation-status
run_case protected-alias rejected protected-alias
run_case unknown-alias rejected unknown-alias

set +e
bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" --input "$REUSABLE" \
  --expected-root-digest "$ROOT_DIGEST" --expected-platform-digest "$PLATFORM_DIGEST" \
  >"$TMP/expected-ok.json" 2>"$TMP/expected-ok.stderr"
[ "$?" -eq 0 ]
bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" --input "$REUSABLE" \
  --expected-root-digest sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
  --expected-platform-digest "$PLATFORM_DIGEST" >"$TMP/digest-bad.json" 2>"$TMP/digest-bad.stderr"
[ "$?" -eq 1 ]
bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" --input "$REUSABLE" \
  --expected-root-digest "$ROOT_DIGEST" >"$TMP/unpaired.json" 2>"$TMP/unpaired.stderr"
[ "$?" -eq 2 ]
set -e

command_output=$(bash "$ADMIT" verify --source "$SOURCE" --version "$VERSION" \
  --input-command "$SHIM" --output "$TMP/command-output.json")
[ "$command_output" = "$(expected_json reusable complete)" ]
[ "$(cat "$TMP/command-output.json")" = "$command_output" ]

echo "test image admission fixtures passed: signed compatibility, unsigned quarantine, paired digests, identity rejection, and command shim"
