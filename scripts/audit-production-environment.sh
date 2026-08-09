#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-}
[ "$MODE" = --expect-unconfigured ] || [ "$MODE" = --expect-configured ] || {
  echo "usage: $0 --expect-unconfigured|--expect-configured" >&2
  exit 2
}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
: "${PRODUCTION_APPROVER:?PRODUCTION_APPROVER must be supplied by an operator}"
[ "$PRODUCTION_APPROVER" != NickolayMamonov ] || {
  echo "PRODUCTION_APPROVER must be distinct from NickolayMamonov" >&2
  exit 1
}

api() {
  gh api "$@"
}

environment=$(api "repos/$GITHUB_REPOSITORY/environments/production")
deployment_policies=$(api \
  "repos/$GITHUB_REPOSITORY/environments/production/deployment-branch-policies?per_page=100")
required_variables=(
  PRODUCTION_HOST
  PRODUCTION_PORT
  PRODUCTION_USER
  PRODUCTION_PATH
  PRODUCTION_SSH_HOST_FINGERPRINT
)
required_secret=PRODUCTION_SSH_PRIVATE_KEY

variable_names=$(api "repos/$GITHUB_REPOSITORY/environments/production/variables?per_page=100" |
  jq -r '.variables[].name' | sort)
secret_names=$(api "repos/$GITHUB_REPOSITORY/environments/production/secrets?per_page=100" |
  jq -r '.secrets[].name' | sort)
for name in "${required_variables[@]}"; do
  if grep -Fxq "$name" <<<"$variable_names"; then
    found=1
  else
    found=0
  fi
  printf 'variable.%s=%s\n' "$name" "$found"
  if [ "$MODE" = --expect-configured ] && [ "$found" -ne 1 ]; then
    exit 1
  fi
  if [ "$MODE" = --expect-unconfigured ] && [ "$found" -ne 0 ]; then
    exit 1
  fi
done
if grep -Fxq "$required_secret" <<<"$secret_names"; then
  found=1
else
  found=0
fi
printf 'secret.%s=%s\n' "$required_secret" "$found"
if [ "$MODE" = --expect-configured ] && [ "$found" -ne 1 ]; then exit 1; fi
if [ "$MODE" = --expect-unconfigured ] && [ "$found" -ne 0 ]; then exit 1; fi

review_rule=$(jq '[.protection_rules[]? | select(.type == "required_reviewers")][0] // {}' <<<"$environment")
reviewer_count=$(jq '[.reviewers[]?] | length' <<<"$review_rule")
prevent_self_review=$(jq -r '.prevent_self_review // false' <<<"$review_rule")
if [[ "$PRODUCTION_APPROVER" == */* ]]; then
  approver_org=${PRODUCTION_APPROVER%%/*}
  approver_team=${PRODUCTION_APPROVER#*/}
  approver_id=$(api "orgs/$approver_org/teams/$approver_team" --jq '.id')
else
  approver_id=$(api "users/$PRODUCTION_APPROVER" --jq '.id')
fi
reviewer_ids=$(jq -r '.reviewers[]? | (.reviewer.id // .id // empty)' <<<"$review_rule")
printf 'required_reviewers=%s\nprevent_self_review=%s\n' "$reviewer_count" "$prevent_self_review"
[ "$reviewer_count" -ge 1 ] || { echo "production needs a real required reviewer" >&2; exit 1; }
[ "$prevent_self_review" = true ] || { echo "production must prevent self-review" >&2; exit 1; }
grep -Fxq "$approver_id" <<<"$reviewer_ids" || {
  echo "PRODUCTION_APPROVER is not the configured Environment reviewer" >&2
  exit 1
}

custom_policy=$(jq -r '
  if .deployment_branch_policy.custom_branch_policies == true
  then "custom" else "not-custom" end
' <<<"$environment")
printf 'deployment_branch_policy=%s\n' "$custom_policy"
[ "$custom_policy" = custom ] || {
  echo "production must use a selected deployment branch policy" >&2
  exit 1
}
jq -e '
  (.branch_policies | length == 1) and
  (.branch_policies[0].name == "master") and
  ((.branch_policies[0].type? // "branch") == "branch")
' \
  <<<"$deployment_policies" >/dev/null || {
  echo "production deployment policy must allow exact master only" >&2
  exit 1
}
echo "deployment_branch=master"

admin_bypass=$(jq -r '.can_admins_bypass // empty' <<<"$environment")
if [ -n "$admin_bypass" ]; then
  printf 'administrator_bypass=%s\n' "$admin_bypass"
  [ "$admin_bypass" = false ] || {
    echo "production administrator bypass must be disabled" >&2
    exit 1
  }
fi

echo "environment=production"
echo "mode=$MODE"
