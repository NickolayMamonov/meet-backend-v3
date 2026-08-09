#!/usr/bin/env bash
set -euo pipefail

MODE=${1:-}
[ "$MODE" = --expect-unconfigured ] || [ "$MODE" = --expect-configured ] || {
  echo "usage: $0 --expect-unconfigured|--expect-configured" >&2
  exit 2
}
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

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
printf 'required_reviewers=%s\nprevent_self_review=%s\n' "$reviewer_count" "$prevent_self_review"
[ "$reviewer_count" -ge 1 ] || { echo "production needs a real required reviewer" >&2; exit 1; }
[ "$prevent_self_review" = true ] || { echo "production must prevent self-review" >&2; exit 1; }

branch_policy=$(jq '[.protection_rules[]? | select(.type == "branch_policy")][0] // {}' <<<"$environment")
custom_policy=$(jq -r 'if .custom_branch_policies == true then "custom" else "not-custom" end' <<<"$branch_policy")
printf 'deployment_branch_policy=%s\n' "$custom_policy"
[ "$custom_policy" = custom ] || {
  echo "production must use a selected deployment branch policy" >&2
  exit 1
}
jq -e 'length == 1 and .[0].type == "branch" and .[0].name == "master"' \
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
