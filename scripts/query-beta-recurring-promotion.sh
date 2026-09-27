#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --run-id ID --reviewer-id ID --receipt PATH --probe-binding PATH --output PATH" >&2
  exit 2
}

run_id='' reviewer_id='' receipt='' probe_binding='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
    --probe-binding) [ "$#" -ge 2 ] || usage; probe_binding=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$run_id" =~ ^[0-9]+$ && "$reviewer_id" =~ ^[0-9]+$ ]] || usage
for file in "$receipt" "$probe_binding" "$output"; do
  [[ "$file" = /* && "$file" != *..* && "$file" != *$'\n'* ]] || usage
done
[ -f "$receipt" ] && [ ! -L "$receipt" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_missing' >&2
  exit 1
}
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
command -v curl >/dev/null 2>&1 || exit 1
command -v jq >/dev/null 2>&1 || exit 1
command -v unzip >/dev/null 2>&1 || exit 1
command -v python3 >/dev/null 2>&1 || exit 1

require_unique_json() {
  local file=$1
  timeout --foreground 5s python3 - "$file" <<'PY'
import json
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject_duplicates)
PY
}

api=${GITHUB_API_URL:-https://api.github.com}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT HUP INT TERM
api_get() {
  local name=$1 path=$2
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api$path" >"$tmp/$name" 2>"$tmp/$name.error" ||
    { echo 'BACKUP_CUSTODY_BLOCKED:promotion_api_unavailable' >&2; exit 1; }
  require_unique_json "$tmp/$name" &&
    jq -e . "$tmp/$name" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:promotion_api_invalid' >&2; exit 1; }
}
api_download() {
  local name=$1 path=$2
  curl --fail --silent --show-error --location --connect-timeout 5 --max-time 60 \
    --max-filesize 67108864 \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$api$path" >"$tmp/$name" 2>"$tmp/$name.error" ||
    { echo 'BACKUP_CUSTODY_BLOCKED:promotion_artifact_unavailable' >&2; exit 1; }
  [ "$(wc -c <"$tmp/$name")" -le 67108864 ] ||
    { echo 'BACKUP_CUSTODY_BLOCKED:promotion_artifact_too_large' >&2; exit 1; }
}

api_get run "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id"
api_get jobs "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100"
api_get artifacts "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/artifacts?per_page=100"
api_get approvals "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/approvals"
api_get environment \
  "/repos/$GITHUB_REPOSITORY/environments/closed-beta-recurring-restore"
api_get branches \
  "/repos/$GITHUB_REPOSITORY/environments/closed-beta-recurring-restore/deployment-branch-policies"

jq -e --arg repo "$GITHUB_REPOSITORY" '
  (.id|type=="number" and .>0) and
  (.head_sha|type=="string" and test("^[0-9a-f]{40}$")) and
  .path==".github/workflows/beta-recurring-backups.yml" and
  .repository.full_name==$repo and .head_branch=="master" and
  .head_repository.full_name==$repo and .status=="completed" and
  .conclusion=="success" and
  (.event=="schedule" or .event=="workflow_dispatch")
' "$tmp/run" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protected_run_invalid' >&2
  exit 1
}
jq -e '
  .can_admins_bypass==false and
  .deployment_branch_policy.custom_branch_policies==true and
  .deployment_branch_policy.protected_branches==false and
  ([.protection_rules[] | select(.type=="required_reviewers") |
    select(.prevent_self_review==true and
      all(.reviewers[]?; ((.reviewer.id // .id)|type=="number" and .>0)))] | length)==1
' "$tmp/environment" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_policy_invalid' >&2
  exit 1
}
jq -e '[.branch_policies[] | select(.name=="master")] | length==1 and
  ([.branch_policies[] | select(.name!="master")] | length)==0' \
  "$tmp/branches" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_branch_policy_invalid' >&2
  exit 1
}
reviewer_policy_bound=$(jq -e --argjson reviewer "$reviewer_id" '
  any(.protection_rules[] | select(.type=="required_reviewers") |
    .reviewers[]?; ((.reviewer.id // .id)|type=="number" and .==$reviewer))
' "$tmp/environment" 2>/dev/null) || false
[ "$reviewer_policy_bound" = true ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:reviewer_policy_binding_invalid' >&2
  exit 1
}

jobs=$(jq -cS --argjson run "$run_id" '
  [.jobs[] | select(.run_id==$run and .status=="completed" and
    .conclusion=="success" and
    (.name=="protected-drill" or .name=="post-probe")) |
    {id,name,run_id,conclusion,completed_at}] |
  sort_by(.name,.id) |
  if length == 2 and
    (map(.name)|sort)==["post-probe","protected-drill"] then . else
    error("required protected jobs missing") end
' "$tmp/jobs") || {
  echo 'BACKUP_CUSTODY_BLOCKED:protected_jobs_invalid' >&2
  exit 1
}
restore_job_id=$(jq -er '[.[]|select(.name=="protected-drill")][0].id' <<<"$jobs")
post_job_id=$(jq -er '[.[]|select(.name=="post-probe")][0].id' <<<"$jobs")
protected_restore=$(jq -er 'any(.[]; .name=="protected-drill" and .conclusion=="success")' <<<"$jobs")
post_probe_successful=$(jq -er 'any(.[]; .name=="post-probe" and .conclusion=="success")' <<<"$jobs")
api_get restore_job_artifacts "/repos/$GITHUB_REPOSITORY/actions/jobs/$restore_job_id/artifacts?per_page=100"
api_get post_job_artifacts "/repos/$GITHUB_REPOSITORY/actions/jobs/$post_job_id/artifacts?per_page=100"
receipt_artifact=$(jq -cS --arg name "beta-recurring-restore-receipt-$run_id" '
  [.artifacts[] | select(.name==$name and .expired==false and
    (.workflow_run.id|tostring)==("'"$run_id"'"))] |
  if length == 1 then .[0] else error("receipt artifact invalid") end
' "$tmp/artifacts") || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_artifact_invalid' >&2
  exit 1
}
post_artifact=$(jq -cS --arg name "beta-recurring-post-probe-$run_id" '
  [.artifacts[] | select(.name==$name and .expired==false and
    (.workflow_run.id|tostring)==("'"$run_id"'"))] |
  if length == 1 then .[0] else error("post artifact invalid") end
' "$tmp/artifacts") || {
  echo 'BACKUP_CUSTODY_BLOCKED:post_probe_artifact_invalid' >&2
  exit 1
}
reviewer_approved=$(jq -e --argjson reviewer "$reviewer_id" '
  any(.[]?;
    .state=="approved" and .user.id==$reviewer and
    any(.environments[]?; .name=="closed-beta-recurring-restore"))
' "$tmp/approvals" 2>/dev/null) || false
[ "$reviewer_approved" = true ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:reviewer_approval_missing' >&2
  exit 1
}
receipt_digest=$(sha256sum "$receipt" | awk '{print $1}')
probe_digest=$(sha256sum "$probe_binding" | awk '{print $1}')
receipt_artifact_id=$(jq -er '.id' <<<"$receipt_artifact")
post_artifact_id=$(jq -er '.id' <<<"$post_artifact")
jq -e --argjson id "$receipt_artifact_id" \
  '[.artifacts[]? | select(.id==$id)] | length == 1' \
  "$tmp/restore_job_artifacts" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_artifact_job_binding_invalid' >&2
  exit 1
}
jq -e --argjson id "$post_artifact_id" \
  '[.artifacts[]? | select(.id==$id)] | length == 1' \
  "$tmp/post_job_artifacts" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:post_probe_artifact_job_binding_invalid' >&2
  exit 1
}
receipt_artifact_digest=$(jq -er '.digest // empty' <<<"$receipt_artifact")
post_artifact_digest=$(jq -er '.digest // empty' <<<"$post_artifact")
[[ "$receipt_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ &&
  "$post_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo 'BACKUP_CUSTODY_BLOCKED:artifact_digest_missing' >&2
  exit 1
}
verify_receipt_artifact() {
  local zip=$1 dir=$2 expected_digest=$3 expected_files=$4
  local digest files
  digest="sha256:$(sha256sum "$zip" | awk '{print $1}')"
  [ "$digest" = "$expected_digest" ] || return 1
  rm -rf -- "$dir"
  mkdir -p -- "$dir"
  unzip -q -o "$zip" -d "$dir"
  files=$(find "$dir" -type f -printf '%P\n' | sort)
  [ "$files" = "$expected_files" ] || return 1
}
receipt_zip="$tmp/receipt.zip"
post_zip="$tmp/post.zip"
api_download receipt.zip "/repos/$GITHUB_REPOSITORY/actions/artifacts/$receipt_artifact_id/zip"
api_download post.zip "/repos/$GITHUB_REPOSITORY/actions/artifacts/$post_artifact_id/zip"
verify_receipt_artifact "$receipt_zip" "$tmp/receipt-artifact" "$receipt_artifact_digest" \
  $'protected-receipt.json\nprotected-receipt.proof.json' || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_artifact_bytes_invalid' >&2
  exit 1
}
cmp -s "$receipt" "$tmp/receipt-artifact/protected-receipt.json" || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_artifact_binding_invalid' >&2
  exit 1
}
verify_receipt_artifact "$post_zip" "$tmp/post-artifact" "$post_artifact_digest" \
  $'post-probe.json\nprobe-binding.json' || {
  echo 'BACKUP_CUSTODY_BLOCKED:post_probe_artifact_bytes_invalid' >&2
  exit 1
}
cmp -s "$probe_binding" "$tmp/post-artifact/probe-binding.json" || {
  echo 'BACKUP_CUSTODY_BLOCKED:probe_binding_artifact_invalid' >&2
  exit 1
}
reviewer_from_receipt=$(jq -er '.reviewerId' "$receipt")
[ "$reviewer_from_receipt" = "$reviewer_id" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:reviewer_binding_mismatch' >&2
  exit 1
}
policy_digest=${BETA_RECURRING_POLICY_DIGEST:-}
protection_digest=$(
  jq -cS -n --slurpfile environment "$tmp/environment" \
    --slurpfile branches "$tmp/branches" \
    '{environment:$environment[0],branches:$branches[0]}' |
    sha256sum | awk '{print $1}'
)
api_evidence_digest=$(
  jq -cS -n --slurpfile run "$tmp/run" --slurpfile jobs "$tmp/jobs" \
    --slurpfile artifacts "$tmp/artifacts" --slurpfile approvals "$tmp/approvals" \
    --slurpfile restore "$tmp/restore_job_artifacts" \
    --slurpfile post "$tmp/post_job_artifacts" \
    --slurpfile environment "$tmp/environment" --slurpfile branches "$tmp/branches" \
    --arg receipt "$receipt_digest" --arg probe "$probe_digest" \
    '{run:$run[0],jobs:$jobs[0],artifacts:$artifacts[0],
      approvals:$approvals[0],restoreJobArtifacts:$restore[0],
      postProbeJobArtifacts:$post[0],environment:$environment[0],
      branches:$branches[0],receiptDigest:$receipt,probeBindingDigest:$probe}' |
    sha256sum | awk '{print $1}'
)
[[ "$policy_digest" =~ ^[0-9a-f]{64}$ ]] || {
  echo 'BACKUP_CUSTODY_BLOCKED:policy_digest_missing' >&2
  exit 1
}
jq -cnS --argjson run "$run_id" --argjson restore "$restore_job_id" \
  --argjson post "$post_job_id" --arg reviewer "$reviewer_id" \
  --arg receipt "$receipt_digest" --arg receiptArtifact "$receipt_artifact_digest" \
  --argjson receiptArtifactId "$receipt_artifact_id" \
  --arg postArtifact "$post_artifact_digest" --arg policy "$policy_digest" \
  --argjson postArtifactId "$post_artifact_id" \
  --arg evidence "$api_evidence_digest" --arg protection "$protection_digest" \
  --arg adapterDigest "$(sha256sum "$script_dir/query-beta-recurring-promotion.sh" | awk '{print $1}')" \
  --arg receiptProtection "$(jq -er '.protectionDigest' "$receipt")" \
  --argjson protectedRestore "$protected_restore" \
  --argjson postProbeSuccessful "$post_probe_successful" \
  '{schema:"meet-backend/beta-recurring-promotion-evidence/v1",
    workflowRunId:$run,restoreJobId:$restore,postProbeJobId:$post,
    reviewerId:$reviewer,receiptDigest:$receipt,
    receiptArtifactId:$receiptArtifactId,receiptArtifactDigest:$receiptArtifact,
    postProbeArtifactId:$postArtifactId,postProbeArtifactDigest:$postArtifact,
    policyDigest:$policy,protectionDigest:$protection,
    receiptProtectionDigest:$receiptProtection,apiEvidenceDigest:$evidence,
    adapter:"scripts/query-beta-recurring-promotion.sh",adapterDigest:$adapterDigest,
    runRef:"refs/heads/master",environment:"closed-beta-recurring-restore",
    protectedRestore:$protectedRestore,postProbeSuccessful:$postProbeSuccessful}' |
  install -m 600 /dev/stdin "$output"
