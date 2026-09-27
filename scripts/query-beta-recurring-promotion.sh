#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --run-id ID --reviewer-id ID --receipt PATH --output PATH" >&2
  exit 2
}

run_id='' reviewer_id='' receipt='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
    --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$run_id" =~ ^[0-9]+$ && "$reviewer_id" =~ ^[0-9]+$ ]] || usage
for file in "$receipt" "$output"; do
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
  jq -e . "$tmp/$name" >/dev/null ||
    { echo 'BACKUP_CUSTODY_BLOCKED:promotion_api_invalid' >&2; exit 1; }
}

api_get run "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id"
api_get jobs "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/jobs?per_page=100"
api_get artifacts "/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/artifacts?per_page=100"

jq -e --arg repo "$GITHUB_REPOSITORY" '
  (.id|type=="number" and .>0) and
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
    ((.name|test("protected-drill";"i")) or (.name|test("post-probe";"i")))) |
    {id,name,run_id,conclusion,completed_at}] |
  sort_by(.name,.id) | unique_by(.name) |
  if length == 2 then . else error("required protected jobs missing") end
' "$tmp/jobs") || {
  echo 'BACKUP_CUSTODY_BLOCKED:protected_jobs_invalid' >&2
  exit 1
}
restore_job_id=$(jq -er '[.[]|select(.name|test("protected-drill";"i"))][0].id' <<<"$jobs")
post_job_id=$(jq -er '[.[]|select(.name|test("post-probe";"i"))][0].id' <<<"$jobs")
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
receipt_digest=$(sha256sum "$receipt" | awk '{print $1}')
receipt_artifact_id=$(jq -er '.id' <<<"$receipt_artifact")
post_artifact_id=$(jq -er '.id' <<<"$post_artifact")
receipt_artifact_digest=$(jq -er '.digest // empty' <<<"$receipt_artifact")
post_artifact_digest=$(jq -er '.digest // empty' <<<"$post_artifact")
[[ "$receipt_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ &&
  "$post_artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo 'BACKUP_CUSTODY_BLOCKED:artifact_digest_missing' >&2
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
