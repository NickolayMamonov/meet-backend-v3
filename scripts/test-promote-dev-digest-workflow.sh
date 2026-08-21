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
grep -Fq 'actions/checkout@v4' "$WORKFLOW"
! grep -Eiq 'gh[[:space:]]+release|docker[[:space:]]+push|git[[:space:]]+push|refs/tags|--method[[:space:]]+DELETE' "$WORKFLOW"
command -v jq >/dev/null
jq -e '(.event_name == "workflow_dispatch") and (.ref == "refs/heads/dev") and (.head_sha | test("^[0-9a-f]{40}$")) and (.authorized == true)' \
  "$FIXTURES/authorized-run.json" >/dev/null
jq -e '(.head_sha | test("^[0-9a-f]{40}$")) and (.conclusion == "success") and (.workflow == "ci.yml")' \
  "$FIXTURES/authorized-ci-runs.json" >/dev/null
jq -e '(.closed_beta_promotion_branches == ["dev"]) and (.test_vps_branches == ["dev"])' \
  "$FIXTURES/dev-only-environment.json" >/dev/null
echo "dev promotion workflow fixture passed"
