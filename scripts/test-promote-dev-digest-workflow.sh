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
grep -Fq 'group: backend-release-writer-${{ github.repository }}' "$WORKFLOW"
grep -Fq 'group: test-vps-promotion-${{ github.repository }}' "$WORKFLOW"
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
grep -Fq 'test-vps/deployment-branch-policies' "$WORKFLOW"
grep -Fq 'dev-promotion-source-final-deploy.json' "$WORKFLOW"
grep -Fq 'mutation_started' "$WORKFLOW"
! grep -Eiq 'gh[[:space:]]+release|docker[[:space:]]+push|git[[:space:]]+push|refs/tags|--method[[:space:]]+DELETE' "$WORKFLOW"
command -v jq >/dev/null
jq -e '(.event_name == "workflow_dispatch") and (.ref == "refs/heads/dev") and (.head_sha | test("^[0-9a-f]{40}$")) and (.authorized == true)' \
  "$FIXTURES/authorized-run.json" >/dev/null
jq -e '(.head_sha | test("^[0-9a-f]{40}$")) and (.conclusion == "success") and (.workflow == "ci.yml")' \
  "$FIXTURES/authorized-ci-runs.json" >/dev/null
jq -e '(.closed_beta_promotion_branches == ["dev"]) and (.test_vps_branches == ["dev"])' \
  "$FIXTURES/dev-only-environment.json" >/dev/null
echo "dev promotion workflow fixture passed"
