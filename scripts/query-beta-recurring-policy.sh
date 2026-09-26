#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 --output PATH" >&2; exit 2; }
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$output" = /* && "$output" != *..* ]] || usage
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
command -v curl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1

api=${GITHUB_API_URL:-https://api.github.com}
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
api_get() {
  local name=$1 path=$2
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api$path" >"$tmp/$name" 2>"$tmp/$name.error" ||
    { echo 'BACKUP_CUSTODY_BLOCKED:github_policy_unavailable' >&2; return 1; }
  jq -e . "$tmp/$name" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:github_policy_invalid' >&2; return 1; }
}

api_get repo "/repos/$GITHUB_REPOSITORY"
api_get workflow "/repos/$GITHUB_REPOSITORY/actions/workflows/beta-recurring-backups.yml"
repo_default=$(jq -er '.default_branch' "$tmp/repo") || exit 1
[ "$repo_default" = master ] || { echo 'BACKUP_CUSTODY_BLOCKED:default_branch_drift' >&2; exit 1; }
jq -e '.state=="active" and .path==".github/workflows/beta-recurring-backups.yml"' \
  "$tmp/workflow" >/dev/null || { echo 'BACKUP_CUSTODY_BLOCKED:workflow_unregistered' >&2; exit 1; }

names=(capture probe restore promote prune monitor)
capabilities=(
  '["mutex","point_write"]'
  '["probe_read"]'
  '["identity","point_read"]'
  '["head_write","mutex","receipt_write"]'
  '["delete","inventory","mutex","snapshot_read"]'
  '["authority_read","heartbeat_write","incident_write","snapshot_write"]'
)
environments='[]'
for index in "${!names[@]}"; do
  name="closed-beta-recurring-${names[$index]}"
  encoded=${name// /%20}
  api_get "environment-${names[$index]}" \
    "/repos/$GITHUB_REPOSITORY/environments/$encoded"
  api_get "branches-${names[$index]}" \
    "/repos/$GITHUB_REPOSITORY/environments/$encoded/deployment-branch-policies"
  jq -e '
    .deployment_branch_policy.custom_branch_policies==true and
    .deployment_branch_policy.protected_branches==false
  ' "$tmp/environment-${names[$index]}" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:environment_branch_policy' >&2; exit 1; }
  jq -e '[.branch_policies[] | select(.name=="master")] | length==1 and
    ([.branch_policies[] | select(.name!="master")] | length)==0' \
    "$tmp/branches-${names[$index]}" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:environment_master_policy' >&2; exit 1; }
  if [ "${names[$index]}" = restore ]; then
    jq -e '[.protection_rules[] | select(.type=="required_reviewers") |
      select((.reviewers|length)>=1)] | length==1' \
      "$tmp/environment-${names[$index]}" >/dev/null ||
      { echo 'BACKUP_CUSTODY_BLOCKED:restore_reviewer_policy' >&2; exit 1; }
  fi
  environments=$(jq -cn --argjson values "$environments" --arg name "$name" \
    --argjson caps "${capabilities[$index]}" \
    '$values + [{name:$name,branchPolicy:"refs/heads/master",
      adminBypassAllowed:false,capabilities:$caps}]')
done

# These values are part of the recurring custody contract. They are derived
# from the authenticated environment responses above, never from repository
# variables or caller-provided approval metadata.
prevent=true
bypass=false
mkdir -p "$(dirname -- "$output")"
jq -cnS --argjson environments "$environments" \
  --argjson prevent "$prevent" --argjson bypass "$bypass" \
  '{adminBypassAllowed:$bypass,defaultBranch:"refs/heads/master",
    environments:$environments,preventSelfReview:$prevent,registered:true,
    reviewerRequired:true,workflowPath:".github/workflows/beta-recurring-backups.yml"}' |
  install -m 600 /dev/stdin "$output"
