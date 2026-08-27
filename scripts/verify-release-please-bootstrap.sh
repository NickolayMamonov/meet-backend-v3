#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
fail() { echo "release-please bootstrap verification failed: $*" >&2; exit 1; }

required=(
  .release-please-manifest.json version.json CHANGELOG.md
  .github/workflows/ci.yml
  .github/workflows/release-please.yml
  .github/workflows/deploy-test-vps.yml
  docs/operations/backend-release-publishing.md
  docs/operations/test-vps-deployment.md
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
  scripts/verify-release-checksums.sh
  scripts/test-release-checksums.sh
  scripts/test-release-evidence.sh
  scripts/test-release-mutation-policy.sh
  scripts/test-release-current-action-freshness.sh
  scripts/test-release-artifact-attestation-gate.sh
  scripts/test-release-controller-queue.sh
  scripts/test-release-controller-output-contract.sh
  scripts/test-release-reader-credential-routing.sh
  scripts/classify-release-continuation.sh
  scripts/test-classify-release-continuation.sh
  scripts/normalize-release-please-action-output.sh
  scripts/test-release-please-action-output.sh
  scripts/normalize-release-pages.sh
  scripts/test-release-page-normalization.sh
  scripts/admit-empty-release-continuation.sh
  scripts/test-empty-release-continuation.sh
  scripts/test-release-publish-tooling-routing.sh
  scripts/deploy-test-vps-release.sh
  scripts/test-test-vps-deploy-workflow.sh
  scripts/normalize-github-attestations.sh
  scripts/resolve-ghcr-username.sh
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
grep -Fq 'test-vps-deployment.md' README.md ||
  fail "README does not link the test VPS deployment runbook"
grep -Fq 'test-vps-deployment.md' docs/production-deployment.md ||
  fail "production guide does not link the test VPS deployment runbook"
workflow=$(sed 's/\r$//' .github/workflows/release-please.yml)
for required_text in \
  'queue: max' 'cancel-in-progress: false' \
  'googleapis/release-please-action@' \
  'scripts/resolve-release-descriptor.sh pre-action' \
  'scripts/resolve-release-descriptor.sh post-action' \
  'scripts/verify-immutable-policy-reader-credential.sh' \
  'scripts/verify-immutable-release-policy.sh' \
  'scripts/verify-immutable-release-proof.sh' \
  'actions/attest-build-provenance@' \
  'gh attestation verify "$ARTIFACT"' \
  '--phase empty' '--policy-token-file' 'attestations: write' \
  'artifactAttestation:$artifact_attestation' \
  '--before-releases-file' '--after-releases-file' \
  '--release-created true' '--release-created false' \
  'normalize-release-please-action-output.sh' \
  'scripts/classify-release-continuation.sh' \
  'admit-empty-release-continuation.sh' \
  'release_tag: ${{ steps.route.outputs.tag }}' \
  'release_version: ${{ steps.route.outputs.version }}' \
  'Checkout reviewed publication tooling' \
  'Set up attestation-capable Buildx' \
  'scripts/normalize-release-pages.sh' \
  '--build-arg "BACKEND_REVISION=$SOURCE_SHA" source' \
  'cd "$RUNNER_TEMP/release-assets"' \
  'sha256sum -c SHA256SUMS >/dev/null' \
  'Verify canonical publication tuple' \
  'release-manifest.json' 'image-index.json' 'image-inspect.txt' 'SHA256SUMS'; do
  grep -Fq -- "$required_text" <<<"$workflow" ||
    fail "workflow misses required invariant: $required_text"
done
if grep -Fq "jq -c 'add // []'" <<<"$workflow"; then
  fail "workflow release-list paths bypass normalize-release-pages.sh"
fi
controller=$(sed -n '/^  controller:/,/^  gates:/p' <<<"$workflow")
grep -Fq '      packages: read' <<<"$controller" ||
  fail "controller does not grant packages: read"
step_block() {
  local name=$1
  awk -v marker="      - name: $name" '
    $0 == marker { in_step=1 }
    in_step && $0 ~ /^      - name: / && $0 != marker { exit }
    in_step { print }
  ' <<<"$controller"
}
for helper_step in \
  'Enforce protected history before Release Please' \
  'Classify current action before Release Please' \
  'Enforce protected history after Release Please' \
  'Normalize action result and current-action set difference'; do
  helper_block=$(step_block "$helper_step")
  [ -n "$helper_block" ] || fail "missing controller helper step: $helper_step"
  grep -Fq 'GH_TOKEN: ${{ github.token }}' <<<"$helper_block" ||
    fail "controller helper does not use github.token: $helper_step"
  if grep -Fq 'secrets.RELEASE_PLEASE_TOKEN' <<<"$helper_block"; then
    fail "controller helper uses RELEASE_PLEASE_TOKEN: $helper_step"
  fi
done
[ "$(grep -Fc 'GH_TOKEN: ${{ github.token }}' <<<"$controller")" -eq 4 ] ||
  fail "controller must have exactly four github.token helper routes"
[ "$(grep -Fc 'secrets.RELEASE_PLEASE_TOKEN' <<<"$workflow")" -eq 1 ] ||
  fail "RELEASE_PLEASE_TOKEN must appear exactly once"
ci_workflow=$(sed 's/\r$//' .github/workflows/ci.yml)
if grep -Fq 'secrets.RELEASE_PLEASE_TOKEN' <<<"$ci_workflow"; then
  fail "CI workflow must not use RELEASE_PLEASE_TOKEN"
fi
release_action=$(step_block 'Release Please current action')
grep -Fq \
  'uses: googleapis/release-please-action@c2a5a2bd6a758a0937f1ddb1e8950609867ed15c' \
  <<<"$release_action" || fail "Release Please action is not pinned"
grep -Fq 'token: ${{ secrets.RELEASE_PLEASE_TOKEN }}' <<<"$release_action" ||
  fail "pinned Release Please action does not use RELEASE_PLEASE_TOKEN"
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
grep -Fq 'gh release verify-asset <tag>' <<<"$runbook" ||
  fail "runbook does not use parameterized asset verification"
grep -Fq 'continuation_id=377201468' <<<"$controller" || fail "continuation ID is not exact"
grep -Fq 'continuation_tag=v1.3.0' <<<"$controller" || fail "continuation tag is not exact"
grep -Fq 'continuation_version=1.3.0' <<<"$controller" || fail "continuation version is not exact"
grep -Fq 'continuation_source=a7abfe04f6852f479291a4710ebdee23e9ae8a34' <<<"$controller" || fail "continuation source is not exact"
for required_text in \
  'continuation_state=$(scripts/classify-release-continuation.sh \' \
  'case "$continuation_state" in' \
  'pending)' \
  'published|absent)' \
  '*)' \
  'continuation classifier returned an invalid state'; do
  grep -Fq -- "$required_text" <<<"$controller" ||
    fail "continuation classifier routing misses required invariant: $required_text"
done
for inline_predicate in \
  'then "pending"' 'then "published"' \
  '.draft == true' '.draft == false' \
  '.immutable == false' '.immutable == true' \
  '.published_at' '[.assets[].name]'; do
  if grep -Fq -- "$inline_predicate" <<<"$controller"; then
    fail "controller duplicates continuation classifier predicate: $inline_predicate"
  fi
done
wildcard_route=$(sed -n '/^            \*)/,/^          esac/p' <<<"$controller")
grep -Fq 'continuation classifier returned an invalid state' <<<"$wildcard_route" ||
  fail "continuation classifier wildcard does not report an invalid state"
grep -Fq 'exit 1' <<<"$wildcard_route" ||
  fail "continuation classifier wildcard does not fail closed"
grep -Fq 'Verify canonical publication tuple' <<<"$workflow" || fail "publication tuple is not generic"
if grep -Fq 'Verify exact v1.2.0 publication tuple' <<<"$workflow"; then fail "v1.2.0-only publication assertion remains"; fi
grep -Fq 'gh release verify-asset <tag> <asset-path>' <<<"$runbook" || fail "runbook does not use a parameterized asset tag"
grep -Fq 'Release ID `371012814`' <<<"$runbook" || fail "historical v1.2.0 recovery facts are missing"
grep -Fq 'permanently no-touch' <<<"$runbook" || fail "v1.1.0 no-touch policy is missing"
echo "release-please bootstrap=verified"
