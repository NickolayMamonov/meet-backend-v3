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

jq -e --arg repo "$GITHUB_REPOSITORY" '
  (.id|type=="number" and .>0) and
  .path==".github/workflows/beta-recurring-backups.yml" and
  .repository.full_name==$repo and .head_branch=="master" and
  .head_repository.full_name==$repo and .status=="completed" and
  .conclusion=="success" and
  (.event=="schedule" or .event=="workflow_dispatch")
' "$tmp/run" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protected_run_invalid' >&2
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
api_evidence_digest=$(
  jq -cS -n --slurpfile run "$tmp/run" --slurpfile jobs "$tmp/jobs" \
    --slurpfile artifacts "$tmp/artifacts" \
    '{run:$run[0],jobs:$jobs[0],artifacts:$artifacts[0]}' |
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
  --arg evidence "$api_evidence_digest" \
  '{schema:"meet-backend/beta-recurring-promotion-evidence/v1",
    workflowRunId:$run,restoreJobId:$restore,postProbeJobId:$post,
    reviewerId:$reviewer,receiptDigest:$receipt,
    receiptArtifactId:$receiptArtifactId,receiptArtifactDigest:$receiptArtifact,
    postProbeArtifactId:$postArtifactId,postProbeArtifactDigest:$postArtifact,
    policyDigest:$policy,apiEvidenceDigest:$evidence,
    runRef:"refs/heads/master",environment:"closed-beta-recurring-restore",
    protectedRestore:true,postProbeSuccessful:true}' |
  install -m 600 /dev/stdin "$output"
