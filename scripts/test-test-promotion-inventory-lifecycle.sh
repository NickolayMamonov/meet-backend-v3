#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml
CLOSURE_TEST=$ROOT_DIR/scripts/test-oci-referrer-closure.sh

fail() {
  echo "test promotion inventory lifecycle fixture failed: $*" >&2
  exit 1
}

[ -f "$WORKFLOW" ] || fail "promotion workflow is missing"
[ -x "$CLOSURE_TEST" ] || fail "closure fixture is not executable"

protected_capture=$(grep -nF 'protected-state-input.json' "$WORKFLOW" |
  head -1 | cut -d: -f1)
protected_before=$(grep -nF 'protected-before.json' "$WORKFLOW" |
  head -1 | cut -d: -f1)
pre_sign_inventory=$(grep -nF 'registry-inventory.json' "$WORKFLOW" |
  head -1 | cut -d: -f1)
post_sign_inventory=$(grep -nF 'post-attestation-registry-inventory.json' "$WORKFLOW" |
  head -1 | cut -d: -f1)
signing=$(grep -nF 'actions/attest-build-provenance' "$WORKFLOW" |
  head -1 | cut -d: -f1)

[ -n "$protected_capture" ] || fail "protected inventory capture is absent"
[ -n "$protected_before" ] || fail "protected before snapshot is absent"
[ -n "$pre_sign_inventory" ] || fail "pre-signing candidate inventory is absent"
[ -n "$post_sign_inventory" ] || fail "post-signing candidate inventory is absent"
[ -n "$signing" ] || fail "signing stage is absent"
[ "$protected_capture" -lt "$protected_before" ] ||
  fail "protected snapshot ordering changed"
[ "$protected_before" -lt "$signing" ] ||
  fail "signing moved before protected snapshot"
[ "$pre_sign_inventory" -lt "$signing" ] ||
  fail "pre-signing candidate refresh is not before signing"
[ "$signing" -lt "$post_sign_inventory" ] ||
  fail "publication and post-signing refreshes are not separate"

grep -Fq 'candidate-bundle.json' "$WORKFLOW" ||
  fail "candidate bundle output is not separated"
grep -Fq 'post-attestation-closure.json' "$WORKFLOW" ||
  fail "candidate closure output is not separated"
grep -Fq -- '--require-bundle' "$WORKFLOW" ||
  fail "candidate verification does not require a complete bundle"
grep -Fq -- '--subject-digest "$root_digest"' "$WORKFLOW" ||
  fail "candidate closure is not subject scoped"
! grep -Fq 'protected-before.json" --output' "$WORKFLOW" ||
  fail "protected snapshot is overwritten"

# The closure fixture constructs real byte-backed OCI descriptors and exercises
# reachable-child, duplicate, collision, size, and convergence rejection.
bash "$CLOSURE_TEST" >/dev/null ||
  fail "real-byte scoped closure fixture failed"

echo "test promotion inventory lifecycle fixture passed: separated refreshes, protected ordering, subject closure, and real-byte graph proof"
