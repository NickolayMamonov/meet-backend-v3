#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml
FIXTURES=$ROOT_DIR/scripts/fixtures/promote-dev-digest-workflow
[ -f "$WORKFLOW" ] && [ -f "$FIXTURES/authorized-run.json" ] || exit 1
grep -Fq "workflow_dispatch:" "$WORKFLOW"
! grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$WORKFLOW"
for guard in "github.event_name == 'workflow_dispatch'" "github.ref == 'refs/heads/dev'" "github.sha == inputs.source_sha"; do
  [ "$(grep -Fc "$guard" "$WORKFLOW")" -ge 4 ] || { echo "missing direct guard: $guard" >&2; exit 1; }
done
grep -Fq "needs.authorize.outputs.authorized == 'true'" "$WORKFLOW"
grep -Fq 'environment: closed-beta-promotion' "$WORKFLOW"
grep -Fq 'environment: test-vps' "$WORKFLOW"
grep -Fq 'group: backend-release-${{ github.repository }}' "$WORKFLOW"
! grep -Fq 'group: test-vps-promotion-${{ github.repository }}' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
! grep -Fq 'actions/checkout@v4' "$WORKFLOW"
grep -Fq 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$WORKFLOW"
grep -Fq 'capture-test-promotion-protected-state.sh' "$WORKFLOW"
grep -Fq 'collect-test-promotion-protected-state.sh' "$WORKFLOW"
grep -Fq 'verify-oci-referrer-closure.sh' "$WORKFLOW"
grep -Fq 'published OCI subject differs from admitted OCI layout' "$WORKFLOW"
grep -Fq 'oras cp --from-oci-layout' "$WORKFLOW"
grep -Fq 'same-image redeploy requires explicit allow_same_digest_redeploy=true' "$WORKFLOW"
grep -Fq 'if: always()' "$WORKFLOW"
grep -Fq 'build-test-promotion-evidence.sh incident' "$WORKFLOW"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WORKFLOW"
grep -Fq 'verify-test-vps-assets.sh' "$WORKFLOW"
grep -Fq 'validate-test-vps-phase-file.sh' "$WORKFLOW"
grep -Fq 'verify-test-promotion-layout.sh' "$WORKFLOW"
grep -Fq 'verify-test-promotion-required-checks.sh' "$WORKFLOW"
grep -Fq 'actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373' "$WORKFLOW"
grep -Fq 'id-token: write' "$WORKFLOW"
grep -Fq 'push-to-registry: true' "$WORKFLOW"
grep -Fq 'bootstrap-predecessor.json' "$WORKFLOW"
grep -Fq 'bootstrap-rollback.json' "$WORKFLOW"
grep -Fq 'PUBLIC_V1_2_0_BOOTSTRAP_INTRODUCTION_SHA: a8aa869dafc7b23178c6c505ef07faa720a8b923' "$WORKFLOW"
grep -Fq 'git merge-base --is-ancestor "$previous_revision"' "$WORKFLOW"
grep -Fq 'sha256sum -- "$1"' "$WORKFLOW"
grep -Fq 'local_sha=$(sha256sum "$local_file"' "$WORKFLOW"
grep -Fq 'cmp -- "$RUNNER_TEMP/bootstrap-predecessor.json"' "$WORKFLOW"
! grep -Fq 'find /var/lib/meet-test-vps-deploy' "$WORKFLOW"
grep -Fq 'test-vps/deployment-branch-policies' "$WORKFLOW"
! grep -Fq '/deployment-branch-policy"' "$WORKFLOW"
[ "$(grep -Fc '.deployment_branch_policy.custom_branch_policies == true' "$WORKFLOW")" -eq 2 ]
[ "$(grep -Fc '.deployment_branch_policy.protected_branches == false' "$WORKFLOW")" -eq 2 ]
grep -Fq 'dev-promotion-source-final-deploy.json' "$WORKFLOW"
grep -Fq 'mutation_started' "$WORKFLOW"
grep -Fq 'printf '\''root_digest=%s\n'\'' "$root_digest" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
grep -Fq 'printf '\''platform_digest=%s\n'\'' "$platform_digest" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
grep -Fq 'printf '\''admission_mode=%s\n'\'' "$mode" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
! grep -Eiq 'gh[[:space:]]+release|docker[[:space:]]+push|git[[:space:]]+push|refs/tags|--method[[:space:]]+DELETE' "$WORKFLOW"
command -v jq >/dev/null
jq -e '(.event_name == "workflow_dispatch") and (.ref == "refs/heads/dev") and (.head_sha | test("^[0-9a-f]{40}$")) and (.authorized == true)' \
  "$FIXTURES/authorized-run.json" >/dev/null
jq -e '(.head_sha | test("^[0-9a-f]{40}$")) and (.conclusion == "success") and (.workflow == "ci.yml")' \
  "$FIXTURES/authorized-ci-runs.json" >/dev/null
jq -e '(.closed_beta_promotion_branches == ["dev"]) and (.test_vps_branches == ["dev"])' \
  "$FIXTURES/dev-only-environment.json" >/dev/null
echo "dev promotion workflow fixture passed"
