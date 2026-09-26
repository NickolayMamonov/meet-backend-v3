#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --event schedule|workflow_dispatch --run-ref refs/heads/master --default-ref refs/heads/master --scheduler-sha SHA --checkout-sha SHA --ci-sha SHA --environment NAME [--run-id ID --policy-file PATH --post-policy-file PATH --ci-result-file PATH --actor LOGIN --reviewer LOGIN --approval-file PATH --post-approval-file PATH --reviewer-id ID]" >&2
  exit 2
}

fail() {
  echo "BACKUP_CUSTODY_BLOCKED:$1" >&2
  exit 1
}

event='' run_ref='' default_ref='' scheduler_sha='' checkout_sha='' ci_sha=''
environment='' policy_file='' post_policy_file='' ci_result_file='' actor='' reviewer=''
approval_file='' post_approval_file='' reviewer_id='' run_id=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --event) [ "$#" -ge 2 ] || usage; event=$2; shift 2 ;;
    --run-ref) [ "$#" -ge 2 ] || usage; run_ref=$2; shift 2 ;;
    --default-ref) [ "$#" -ge 2 ] || usage; default_ref=$2; shift 2 ;;
    --scheduler-sha) [ "$#" -ge 2 ] || usage; scheduler_sha=$2; shift 2 ;;
    --checkout-sha) [ "$#" -ge 2 ] || usage; checkout_sha=$2; shift 2 ;;
    --ci-sha) [ "$#" -ge 2 ] || usage; ci_sha=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --policy-file) [ "$#" -ge 2 ] || usage; policy_file=$2; shift 2 ;;
    --post-policy-file) [ "$#" -ge 2 ] || usage; post_policy_file=$2; shift 2 ;;
    --ci-result-file) [ "$#" -ge 2 ] || usage; ci_result_file=$2; shift 2 ;;
    --actor) [ "$#" -ge 2 ] || usage; actor=$2; shift 2 ;;
    --reviewer) [ "$#" -ge 2 ] || usage; reviewer=$2; shift 2 ;;
    --approval-file) [ "$#" -ge 2 ] || usage; approval_file=$2; shift 2 ;;
    --post-approval-file) [ "$#" -ge 2 ] || usage; post_approval_file=$2; shift 2 ;;
    --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
    *) usage ;;
  esac
done
case "$event" in schedule|workflow_dispatch) ;; *) usage ;; esac
[ "$run_ref" = refs/heads/master ] && [ "$default_ref" = refs/heads/master ] ||
  fail scheduler_ref
for sha in "$scheduler_sha" "$checkout_sha" "$ci_sha"; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail revision
done
[[ "$environment" =~ ^closed-beta-recurring-(capture|probe|restore|promote|prune|monitor)$ ]] ||
  fail environment
[ "$scheduler_sha" != "$checkout_sha" ] || fail revision_collision

validate_policy() {
  local policy=$1
  command -v jq >/dev/null 2>&1 || fail jq_unavailable
  [ -f "$policy" ] && [ ! -L "$policy" ] || fail policy_missing
  jq -e --arg environment "$environment" --arg run_ref "$run_ref" '
    type=="object" and
    (keys|sort)==["adminBypassAllowed","defaultBranch","environments",
      "preventSelfReview","registered","reviewerRequired","workflowPath"] and
    .registered==true and .defaultBranch=="refs/heads/master" and
    .workflowPath==".github/workflows/beta-recurring-backups.yml" and
    .adminBypassAllowed==false and .preventSelfReview==true and
    (.reviewerRequired==true or $environment != "closed-beta-recurring-restore") and
    ([.environments[] | select(.name==$environment) |
      select(.branchPolicy==$run_ref) |
      select(.adminBypassAllowed==false) |
      select((.apiEvidenceDigest|type=="string" and test("^[0-9a-f]{64}$"))) |
      select((.reviewerIds|type=="array" and
        all(.[]; type=="number" and floor==. and .>0))) |
      select(if $environment=="closed-beta-recurring-restore"
        then .reviewerRequired==true and .preventSelfReview==true and
          (.reviewerIds|length>=1)
        else .reviewerRequired==false and .preventSelfReview==false
        end)] | length)==1 and
    ([.environments[] | select(.name==$environment) | .capabilities] | length)==1
  ' "$policy" >/dev/null || fail policy_drift
  local expected
  case "$environment" in
    closed-beta-recurring-capture) expected='["mutex","point_write"]' ;;
    closed-beta-recurring-probe) expected='["probe_read"]' ;;
    closed-beta-recurring-restore) expected='["identity","point_read"]' ;;
    closed-beta-recurring-promote) expected='["head_write","mutex","receipt_write"]' ;;
    closed-beta-recurring-prune) expected='["delete","inventory","mutex","snapshot_read"]' ;;
    closed-beta-recurring-monitor) expected='["authority_read","heartbeat_write","incident_write","snapshot_write"]' ;;
  esac
  jq -e --arg environment "$environment" --argjson expected "$expected" \
    '([.environments[] | select(.name==$environment) | .capabilities] | .[0]) == $expected' \
    "$policy" >/dev/null || fail role_capability_drift
}

validate_ci() {
  local result=$1
  command -v jq >/dev/null 2>&1 || fail jq_unavailable
  [ -f "$result" ] && [ ! -L "$result" ] || fail ci_evidence_missing
  jq -e --arg checkout "$checkout_sha" --arg ci "$ci_sha" '
    type=="object" and
    (keys|sort)==["conclusion","ref","sha","sourceSha","workflowPath"] and
    .conclusion=="success" and .ref=="refs/heads/dev" and
    .sourceSha==$checkout and .sha==$ci and
    .workflowPath==".github/workflows/ci.yml"
  ' "$result" >/dev/null || fail ci_provenance
}

if [ -n "$policy_file" ] || [ -n "$ci_result_file" ]; then
  [ -n "$policy_file" ] && [ -n "$ci_result_file" ] || usage
  validate_policy "$policy_file"
  validate_ci "$ci_result_file"
  [[ "$actor" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || fail actor
  if [ "$environment" = closed-beta-recurring-restore ] && [ -n "$reviewer" ]; then
    [[ "$reviewer" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]] || fail reviewer_missing
    [ "$reviewer" != "$actor" ] || fail self_review
    [ -n "$reviewer_id" ] || fail reviewer_id_missing
    [[ "$reviewer_id" =~ ^[0-9]+$ ]] || fail reviewer_id_invalid
    jq -e --arg environment "$environment" --arg reviewer "$reviewer_id" \
      '[.environments[] | select(.name==$environment) |
        .reviewerIds[] | select((tostring) == $reviewer)] | length == 1' \
      "$policy_file" >/dev/null || fail reviewer_not_authenticated
  fi
fi
validate_approval() {
  local file=$1 policy_digest protection_digest policy_source=${post_policy_file:-$policy_file}
  [ -f "$file" ] && [ ! -L "$file" ] || fail approval_missing
  [[ "$run_id" =~ ^[0-9]+$ ]] || fail approval_run_missing
  policy_digest=$(jq -cS . "$policy_source" | sha256sum | awk '{print $1}')
  local api_evidence_digest
  api_evidence_digest=$(jq -er --arg environment "$environment" \
    '[.environments[] | select(.name==$environment) | .apiEvidenceDigest] | .[0]' \
    "$policy_source")
  jq -e --arg environment "$environment" --arg reviewer "$reviewer" \
    --arg reviewer_id "$reviewer_id" --arg actor "$actor" \
    --arg branch "$run_ref" --arg policy "$policy_digest" \
    --arg evidence "$api_evidence_digest" --arg run "$run_id" '
    type=="object" and
    (keys|sort)==["adminBypassAllowed","apiEvidenceDigest","approvalRunId","approvedAt","branchPolicy",
      "environment","policyDigest","preventSelfReview","protectionDigest",
      "reviewerId","reviewerLogin","reviewerRequired","schema"] and
    .schema=="meet-backend/beta-backup-custody-approval/v1" and
    .environment==$environment and .branchPolicy==$branch and
    .reviewerLogin==$reviewer and
    .reviewerId==$reviewer_id and
    .reviewerRequired==true and .preventSelfReview==true and
    .adminBypassAllowed==false and .apiEvidenceDigest==$evidence and
    .policyDigest==$policy and .approvalRunId==$run and
    (.protectionDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.approvalRunId|type=="string" and test("^[A-Za-z0-9._:-]{1,128}$")) and
    (.approvedAt|type=="number" and floor==. and .>=0)
  ' "$file" >/dev/null || fail approval_drift
  protection_digest=$(jq -cS 'del(.protectionDigest)' "$file" |
    sha256sum | awk '{print $1}') || fail approval_drift
  [ "$protection_digest" = "$(jq -er '.protectionDigest' "$file")" ] ||
    fail approval_drift
}
if [ "$environment" = closed-beta-recurring-restore ] &&
  { [ -n "$approval_file" ] || [ -n "$post_approval_file" ]; }; then
  [ -n "$approval_file" ] || fail approval_required
  [ -n "$post_policy_file" ] || fail post_policy_required
  validate_policy "$post_policy_file"
  jq -cS . "$policy_file" >"$policy_file.canonical"
  jq -cS . "$post_policy_file" >"$post_policy_file.canonical"
  cmp -s "$policy_file.canonical" "$post_policy_file.canonical" || fail policy_changed_after_approval
  validate_approval "$approval_file"
  if [ -n "$post_approval_file" ]; then
    validate_approval "$post_approval_file"
    cmp -s "$approval_file" "$post_approval_file" || fail approval_changed
  fi
fi
[ -n "$policy_file" ] && [ -n "$ci_result_file" ] || fail policy_evidence_required

printf 'recurring_authorized=true environment=%s run_ref=%s scheduler_sha=%s checkout_sha=%s ci_sha=%s policy_validated=%s\n' \
  "$environment" "$run_ref" "$scheduler_sha" "$checkout_sha" "$ci_sha" \
  "$([ -n "$policy_file" ] && echo true || echo false)"
