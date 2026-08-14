#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
fail() { echo "release-please bootstrap verification failed: $*" >&2; exit 1; }

required=(
  .release-please-manifest.json version.json CHANGELOG.md
  .github/workflows/release-please.yml
  docs/operations/backend-release-publishing.md
  scripts/resolve-release-descriptor.sh
  scripts/release-mutation-policy.sh
  scripts/verify-immutable-policy-reader-credential.sh
  scripts/verify-immutable-release-policy.sh
  scripts/verify-immutable-release-proof.sh
  scripts/verify-release-evidence.sh
  docs/evidence/MEE2-48-protected-history-v1.json
  docs/evidence/MEE2-48-protected-history-v1.json.sha256
  scripts/test-immutable-policy-reader-credential.sh
  scripts/test-immutable-release-policy.sh
  scripts/test-immutable-release-proof.sh
  scripts/test-release-evidence.sh
  scripts/test-release-mutation-policy.sh
  scripts/test-release-current-action-freshness.sh
  scripts/test-release-controller-queue.sh
  scripts/test-release-post-publication-routing.sh
  scripts/test-release-protected-snapshot.sh
)
for path in "${required[@]}"; do
  [ -f "$path" ] || fail "missing required file: $path"
done
"$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
  --snapshot docs/evidence/MEE2-48-protected-history-v1.json
sha256sum -c docs/evidence/MEE2-48-protected-history-v1.json.sha256 >/dev/null ||
  fail "protected-history snapshot checksum does not match"
for retired in .github/workflows/release-recovery.yml \
  scripts/acquire-release-lease.sh scripts/verify-release-resume-state.sh \
  scripts/test-release-resume-state.sh; do
  [ ! -e "$retired" ] || fail "retired release path remains: $retired"
done
command -v jq >/dev/null 2>&1 || fail "jq is required"
jq -e '
  type == "object" and length == 1 and
  (.["."] | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
' .release-please-manifest.json >/dev/null || fail "manifest is malformed"
version=$(jq -r '.version' version.json)
manifest=$(jq -r '."."' .release-please-manifest.json)
[ "$version" = "$manifest" ] || fail "manifest/version authority disagrees"
grep -Fq 'docs/operations/backend-release-publishing.md' README.md ||
  fail "README does not link the publication runbook"
grep -Fq 'backend-release-publishing.md' docs/production-deployment.md ||
  fail "deployment guide does not link the publication runbook"
workflow=$(sed 's/\r$//' .github/workflows/release-please.yml)
for required_text in \
  'queue: max' 'cancel-in-progress: false' \
  'googleapis/release-please-action@' \
  'scripts/resolve-release-descriptor.sh pre-action' \
  'scripts/resolve-release-descriptor.sh post-action' \
  'scripts/verify-immutable-policy-reader-credential.sh' \
  'scripts/verify-immutable-release-policy.sh' \
  'scripts/verify-immutable-release-proof.sh' \
  '--before-releases-file' '--after-releases-file' \
  '--release-created true' '--release-created false' \
  'Verify exact v1.2.0 publication tuple' \
  'release-manifest.json' 'image-index.json' 'image-inspect.txt' 'SHA256SUMS'; do
  grep -Fq -- "$required_text" <<<"$workflow" ||
    fail "workflow misses required invariant: $required_text"
done
for stale in \
  'release-recovery.yml' 'workflow_dispatch' 'route=recover' 'route=deep-recover' \
  'route=resume' 'route=resume-registry' 'mutate-release-metadata.sh canonicalize' \
  'acquire-release-lease.sh' 'generated placeholder publication'; do
  grep -Fq -- "$stale" <<<"$workflow" &&
    fail "stale controller construct remains: $stale" || true
done
runbook=$(sed 's/\r$//' docs/operations/backend-release-publishing.md)
for stale in \
  'release-recovery.yml' 'route=deep-recover' 'route=resume-registry' \
  'mutate-release-metadata.sh canonicalize' 'acquire-release-lease.sh'; do
  grep -Fq -- "$stale" <<<"$runbook" &&
    fail "stale runbook construct remains: $stale" || true
done
grep -Fq 'gh release verify-asset v1.2.0' <<<"$runbook" ||
  fail "runbook does not pin explicit v1.2.0 asset verification"
echo "release-please bootstrap=verified"
