#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PRODUCTION_APPROVER:?PRODUCTION_APPROVER must be supplied by an operator}"

api() { gh api "$@"; }

collaborators=$(api "repos/$GITHUB_REPOSITORY/collaborators?per_page=100")
rulesets=$(api "repos/$GITHUB_REPOSITORY/rulesets?per_page=100")
printf 'promotion_authority=NickolayMamonov\n'
printf 'production_approver=%s\n' "$PRODUCTION_APPROVER"
printf 'collaborator_count=%s\n' "$(jq 'length' <<<"$collaborators")"
printf 'ruleset_count=%s\n' "$(jq 'length' <<<"$rulesets")"

if [[ "$PRODUCTION_APPROVER" == */* ]]; then
  approver_org=${PRODUCTION_APPROVER%%/*}
  approver_team=${PRODUCTION_APPROVER#*/}
  api "orgs/$approver_org/teams/$approver_team" >/dev/null || {
    echo "PRODUCTION_APPROVER team is not a recorded real team" >&2
    exit 1
  }
else
  api "repos/$GITHUB_REPOSITORY/collaborators/$PRODUCTION_APPROVER" >/dev/null || {
    echo "PRODUCTION_APPROVER is not a recorded real collaborator" >&2
    exit 1
  }
fi
for branch in dev master; do
  protection=$(api "repos/$GITHUB_REPOSITORY/branches/$branch/protection" 2>/dev/null || true)
  [ -n "$protection" ] || { echo "$branch protection is absent" >&2; exit 1; }
  jq -e '
    (.required_pull_request_reviews.required_approving_review_count >= 1) and
    (.required_pull_request_reviews.dismiss_stale_reviews == true) and
    (.required_pull_request_reviews.require_last_push_approval == true) and
    (.required_pull_request_reviews.require_code_owner_reviews == true) and
    (.required_status_checks.strict == true) and
    ((.required_status_checks.contexts | length) >= 1) and
    (.required_conversation_resolution.enabled == true) and
    (.enforce_admins.enabled == true) and
    (.allow_force_pushes.enabled == false) and
    (.allow_deletions.enabled == false)
  ' <<<"$protection" >/dev/null || {
    echo "$branch protection does not satisfy required PR/check/no-bypass policy" >&2
    exit 1
  }
  printf '%s=protected\n' "$branch"
done
