#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-test-promotion-environment-policy.sh
FIXTURES=$ROOT_DIR/scripts/fixtures/test-promotion-environment-policy
WORKFLOW=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml

fail() {
  echo "test promotion environment policy fixture failed: $*" >&2
  exit 1
}

[ -x "$VERIFY" ] || fail "policy validator is not executable"
command -v jq >/dev/null 2>&1 || fail "jq is required"

for fixture in valid-live-shape malformed array multiple wrong-branch wrong-type; do
  [ -f "$FIXTURES/$fixture.json" ] || fail "missing $fixture fixture"
done

"$VERIFY" --input "$FIXTURES/valid-live-shape.json" | grep -Fxq 'deployment_branch=dev' ||
  fail "valid live policy shape was rejected"

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
for fixture in malformed array multiple wrong-branch wrong-type; do
  if "$VERIFY" --input "$FIXTURES/$fixture.json" >"$tmp/$fixture.stdout" 2>"$tmp/$fixture.stderr"; then
    fail "$fixture policy shape was accepted"
  fi
  [ ! -s "$tmp/$fixture.stdout" ] || fail "$fixture emitted success output"
  [ -s "$tmp/$fixture.stderr" ] || fail "$fixture did not report a validation error"
done

grep -Fq 'verify-test-promotion-environment-policy.sh' "$WORKFLOW" ||
  fail "workflow does not call the reusable policy validator"
[ "$(grep -Fc 'verify-test-promotion-environment-policy.sh --input' "$WORKFLOW")" -eq 2 ] ||
  fail "workflow must validate both live environment policy objects"
! grep -Fq "jq -e 'any(.[]; .name == \"dev\" and .type == \"branch\")'" "$WORKFLOW" ||
  fail "workflow still iterates the deployment-policy response as an array"
! grep -Fq "jq -e 'any(.[]; .name == \"dev\" and .type == \"branch\")' \\" "$WORKFLOW" ||
  fail "workflow still contains the broken multiline policy predicate"

echo "test promotion environment policy fixtures passed"
