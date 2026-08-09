#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
api() { gh api "$@"; }

default_branch=$(api "repos/$GITHUB_REPOSITORY" --jq '.default_branch')
[ "$default_branch" = master ] || {
  echo "default branch must remain master" >&2
  exit 1
}

required_paths=(
  .github/workflows/deploy-production.yml
  .github/workflows/release-recovery.yml
  scripts/release-registry-state.sh
  scripts/verify-release-consistency.sh
)
for path in "${required_paths[@]}"; do
  master_sha=$(api "repos/$GITHUB_REPOSITORY/contents/$path?ref=master" --jq '.sha')
  dev_sha=$(api "repos/$GITHUB_REPOSITORY/contents/$path?ref=dev" --jq '.sha')
  [ "$master_sha" = "$dev_sha" ] || {
    echo "master/dev workflow-helper drift: $path" >&2
    exit 1
  }
  printf 'promoted_blob=%s\n' "$path"
done

workflows=$(api "repos/$GITHUB_REPOSITORY/actions/workflows?per_page=100")
for workflow in deploy-production.yml release-recovery.yml; do
  jq -e --arg path ".github/workflows/$workflow" \
    '.workflows[] | select(.path == $path and .state == "active")' <<<"$workflows" >/dev/null || {
    echo "workflow $workflow is not active on default master" >&2
    exit 1
  }
  printf 'active_workflow=%s\n' "$workflow"
done
echo "default_branch_bootstrap=verified"
