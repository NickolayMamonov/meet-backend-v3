#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--validate-only] [--storage-root DIR] --point-id ID [--receipt PATH --restore-command PATH --restore-output DIR --identity-file PATH --capture-revision SHA --restore-revision SHA --reviewer-id ID --protection-file PATH --protection-digest DIGEST --approval-api-evidence PATH]" >&2
  exit 2
}

root='' point_id='' receipt='' restore_command='' restore_output='' identity=''
capture_revision='' restore_revision='' reviewer_id='' protection_file='' protection_digest=''
approval_api_evidence=''
validate_only=false
root_owned=false
proof_tmp=''
cleanup_drill() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$proof_tmp" ] || rm -f -- "$proof_tmp" || status=1
  [ -z "$identity" ] || rm -f -- "$identity" || status=1
  if [ "${root_owned:-false}" = true ] && [ -n "$root" ]; then
    rm -rf -- "$root" || status=1
  fi
  if [ "$status" -ne 0 ] && [ -n "$restore_output" ]; then
    rm -rf -- "$restore_output" || status=1
  fi
  exit "$status"
}
trap cleanup_drill EXIT HUP INT TERM
while [ "$#" -gt 0 ]; do
  case "$1" in
    --validate-only) validate_only=true; shift ;;
    --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --point-id) [ "$#" -ge 2 ] || usage; point_id=$2; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
    --restore-command) [ "$#" -ge 2 ] || usage; restore_command=$2; shift 2 ;;
    --restore-output) [ "$#" -ge 2 ] || usage; restore_output=$2; shift 2 ;;
    --identity-file) [ "$#" -ge 2 ] || usage; identity=$2; shift 2 ;;
    --capture-revision) [ "$#" -ge 2 ] || usage; capture_revision=$2; shift 2 ;;
    --restore-revision) [ "$#" -ge 2 ] || usage; restore_revision=$2; shift 2 ;;
    --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
    --protection-file) [ "$#" -ge 2 ] || usage; protection_file=$2; shift 2 ;;
    --protection-digest) [ "$#" -ge 2 ] || usage; protection_digest=$2; shift 2 ;;
    --approval-api-evidence) [ "$#" -ge 2 ] || usage; approval_api_evidence=$2; shift 2 ;;
    *) usage ;;
  esac
done

[ -z "$root" ] || [[ "$root" = /* && "$root" != *..* && "$root" != *$'\n'* ]] || usage
[[ "$point_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || usage
if [ "$validate_only" = false ]; then
  for path in "$receipt" "$restore_command" "$restore_output" "$identity" "$protection_file"; do
    [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
  done
  [[ -z "$capture_revision" || "$capture_revision" =~ ^[0-9a-f]{40}$ ]] || usage
  [[ "$restore_revision" =~ ^[0-9a-f]{40}$ ]] || usage
  [[ "$reviewer_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || usage
  [[ "$protection_digest" =~ ^[0-9a-f]{64}$ ]] || usage
  [[ "$approval_api_evidence" = /* && "$approval_api_evidence" != *..* &&
    "$approval_api_evidence" != *$'\n'* ]] || usage
fi
command -v jq >/dev/null 2>&1 || exit 1
if [ "$validate_only" = false ]; then
  command -v timeout >/dev/null 2>&1 || exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
if [ -z "$root" ]; then
  beta_storage_require_config
  root=$(mktemp -d)
  root_owned=true
  beta_storage_require_local_root "$root" >/dev/null
  point="$root/points/$point_id"
  mkdir -p "$point"
  remote_scratch="$root/.remote"
  mkdir -p "$remote_scratch"
  capture_head_meta="$remote_scratch/capture-head.meta"
  capture_head="$remote_scratch/capture-head.json"
  beta_storage_remote_head control/capture-head.json "$capture_head_meta" || {
    echo 'BACKUP_CUSTODY_BLOCKED:capture_head_unavailable' >&2
    exit 1
  }
  beta_storage_remote_get_json control/capture-head.json "$capture_head" \
    "$(jq -er '.VersionId' "$capture_head_meta")"
  jq -e '
    type=="object" and
    (keys|sort)==["capturedAt","descriptorDigest","descriptorVersion",
      "generation","pointId","schema"] and
    .schema=="meet-backend/beta-backup-head/v2" and
    (.pointId|type=="string") and (.descriptorVersion|type=="string" and length>0) and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$"))
  ' "$capture_head" >/dev/null || {
    echo 'BACKUP_CUSTODY_BLOCKED:capture_head_invalid' >&2
    exit 1
  }
  [ "$(jq -er '.pointId' "$capture_head")" = "$point_id" ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:capture_point_mismatch' >&2
    exit 1
  }
  beta_storage_remote_get_json "points/$point_id/point.json" \
    "$remote_scratch/point.json" \
    "$(jq -er '.descriptorVersion' "$capture_head")"
  beta_storage_remote_validate_descriptor "$point_id" \
    "$remote_scratch/point.json" "$remote_scratch"
  [ "$(beta_storage_descriptor_digest "$remote_scratch/point.json")" = \
    "$(jq -er '.descriptorDigest' "$capture_head")" ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:capture_descriptor_binding' >&2
    exit 1
  }
  cp -- "$remote_scratch/point.json" "$point/point.json"
  cp -- "$remote_scratch/manifest.json" "$point/recovery-point.json"
  cp -- "$remote_scratch/database.age" "$point/postgres.dump.age"
  cp -- "$remote_scratch/uploads.age" "$point/uploads.tar.gz.age"
  if [ "$(jq -er '.proofs|keys|length' "$remote_scratch/point.json")" -eq 2 ]; then
    beta_storage_provider_get '' "points/$point_id/capture-database-proof.json" \
      "$(jq -er '.proofs.database.versionId' "$remote_scratch/point.json")" \
      "$point/capture-database-proof.json" \
      "$(jq -er '.proofs.database.sha256' "$remote_scratch/point.json")" >/dev/null
    beta_storage_provider_get '' "points/$point_id/capture-media-proof.json" \
      "$(jq -er '.proofs.media.versionId' "$remote_scratch/point.json")" \
      "$point/capture-media-proof.json" \
      "$(jq -er '.proofs.media.sha256' "$remote_scratch/point.json")" >/dev/null
  fi
else
  [ "${BETA_BACKUP_TEST_FIXTURE:-false}" = true ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:local_authority_fixture_only' >&2
    exit 1
  }
  beta_storage_require_local_root "$root" >/dev/null
  point="$root/points/$point_id"
fi
beta_storage_local_validate_point_dir "$point" "$point_id" || {
  echo 'BACKUP_CUSTODY_BLOCKED:point_unavailable' >&2
  exit 1
}
if [ "$validate_only" = true ]; then
  printf 'recurring_point_valid=true point_id=%s\n' "$point_id"
  [ "$root_owned" = true ] && rm -rf -- "$root"
  exit 0
fi
[ -x "$restore_command" ] && [ ! -L "$restore_command" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_command_unavailable' >&2
  exit 1
}
if [ "${BETA_BACKUP_TEST_FIXTURE:-false}" != true ]; then
  [ "$restore_command" = "$script_dir/run-beta-recurring-restore-command.sh" ] || {
    echo 'BACKUP_CUSTODY_BLOCKED:restore_command_not_reviewed' >&2
    exit 1
  }
  allowlist=${BETA_RECURRING_TOOLING_ALLOWLIST:-$script_dir/fixtures/beta-recurring/tooling-allowlist.json}
  "$script_dir/validate-beta-recurring-tooling.sh" \
    --role restore --path "$restore_command" --allowlist "$allowlist" >/dev/null
fi
[ -f "$identity" ] && [ ! -L "$identity" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_identity_unavailable' >&2
  exit 1
}
[ -s "$identity" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_identity_empty' >&2
  exit 1
}
[ -f "$protection_file" ] && [ ! -L "$protection_file" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_metadata_unavailable' >&2
  exit 1
}
approval_digest=''
if [ -f "$approval_api_evidence" ] && [ ! -L "$approval_api_evidence" ]; then
  jq -e --arg reviewer "$reviewer_id" --arg environment closed-beta-recurring-restore '
    type=="object" and
    (keys|sort)==["approvalApiDigest","approvalDigest","environment","reviewerId",
      "reviewerLogin","runId","schema","state"] and
    .schema=="meet-backend/beta-recurring-approval/v1" and
    .environment==$environment and .state=="approved" and
    (.reviewerId|type=="number" and tostring==$reviewer) and
    (.reviewerLogin|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9-]{0,38}$")) and
    (.runId|type=="number" and floor==. and .>0) and
    (.approvalApiDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.approvalDigest|type=="string" and test("^[0-9a-f]{64}$"))
  ' "$approval_api_evidence" >/dev/null || {
    echo 'BACKUP_CUSTODY_BLOCKED:approval_api_evidence_invalid' >&2
    exit 1
  }
  approval_digest=$(jq -er '.approvalDigest' "$approval_api_evidence")
else
  echo 'BACKUP_CUSTODY_BLOCKED:approval_api_evidence_unavailable' >&2
  exit 1
fi
if [ -z "$capture_revision" ]; then
  capture_revision=$(jq -er '.capture.sourceRevision' "$point/recovery-point.json")
fi
[[ "$capture_revision" =~ ^[0-9a-f]{40}$ ]] || usage

jq -e --arg reviewer "$reviewer_id" --arg digest "$protection_digest" \
  --arg approval "$approval_digest" '
  type=="object" and
  ((.schema=="meet-backend/beta-recurring-restore-protection/v1" and
    (keys|sort)==["adminBypassAllowed","branchPolicy","environment",
      "preventSelfReview","protectionDigest","reviewerId","reviewerRequired",
      "schema"]) or
   (.schema=="meet-backend/beta-recurring-restore-protection/v2" and
    (keys|sort)==["adminBypassAllowed","apiEvidenceDigest","approvalDigest",
      "branchPolicy","environment","preventSelfReview","protectionDigest",
      "reviewerId","reviewerRequired","schema"] and
    (.apiEvidenceDigest|type=="string" and test("^[0-9a-f]{64}$")))) and
  .environment=="closed-beta-recurring-restore" and
  .branchPolicy=="refs/heads/master" and
  .reviewerRequired==true and .preventSelfReview==true and
  .adminBypassAllowed==false and .reviewerId==$reviewer and
  .protectionDigest==$digest and (.protectionDigest|test("^[0-9a-f]{64}$")) and
  (if .schema=="meet-backend/beta-recurring-restore-protection/v2"
   then .approvalDigest==$approval else true end)
' "$protection_file" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_metadata_invalid' >&2
  exit 1
}
[ "$(jq -cS 'del(.protectionDigest)' "$protection_file" | sha256sum | awk '{print $1}')" = "$protection_digest" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_metadata_changed' >&2
  exit 1
}

descriptor_digest=$(beta_storage_descriptor_digest "$point/point.json")
capture_at=$(jq -er '.capture.capturedAt' "$point/recovery-point.json")
capture_source=$(jq -er '.capture.sourceRevision' "$point/recovery-point.json")
[ "$capture_revision" = "$capture_source" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:capture_revision_mismatch' >&2
  exit 1
}

mkdir -p "$restore_output"
[ ! -L "$restore_output" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_output_symlink' >&2
  exit 1
}
[ -z "$(find "$restore_output" -mindepth 1 -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_output_not_empty' >&2
  exit 1
}
restore_parent=$(dirname -- "$restore_output")
[ -d "$restore_parent" ] && [ ! -L "$restore_parent" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_parent_unavailable' >&2
  exit 1
}
proof_tmp=$(mktemp "$restore_parent/.restore-proof.XXXXXX")
timeout --foreground --signal=TERM 1800s "$restore_command" \
  --point-dir "$point" --identity-file "$identity" --output-dir "$restore_output" \
  --capture-revision "$capture_revision" --restore-revision "$restore_revision" \
  --protection-digest "$protection_digest" --approval-digest "$approval_digest" \
  --proof-output "$proof_tmp"

[ -f "$proof_tmp" ] && [ ! -L "$proof_tmp" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_proof_missing' >&2
  exit 1
}
[ -z "$(find "$restore_output" -mindepth 1 -print -quit)" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_cleanup_incomplete' >&2
  exit 1
}
jq -e --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg descriptor "$descriptor_digest" --arg protection "$protection_digest" \
  --arg approval "$approval_digest" \
  --argjson captured "$capture_at" '
  type=="object" and
  (keys|sort)==["approvalDigest","captureRevision","capturedAt","cleanup","databaseProbe",
    "identityCustody","isolated","mediaProbe","pointDescriptorDigest",
    "postFingerprint","preFingerprint","protectionDigest","restoreRevision","schema"] and
  .schema=="meet-backend/beta-recurring-restore-proof/v2" and
  .captureRevision==$capture and .restoreRevision==$restore and
  .capturedAt==$captured and
  .pointDescriptorDigest==$descriptor and .protectionDigest==$protection and
  .approvalDigest==$approval and
  .identityCustody=="restore-only" and .isolated==true and .cleanup==true and
  (.databaseProbe==true and .mediaProbe==true) and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  .preFingerprint == .postFingerprint and
  (.capturedAt|type=="number" and floor==. and .>=0)
' "$proof_tmp" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_proof_invalid' >&2
  exit 1
}
proof_digest=$(sha256sum "$proof_tmp" | awk '{print $1}')
receipt_id="receipt-$(date -u +%Y%m%dT%H%M%SZ)-$point_id"
mkdir -p "$(dirname -- "$receipt")"
cp -- "$proof_tmp" "$(dirname -- "$receipt")/$receipt_id.proof.json"
cp -- "$proof_tmp" "$(dirname -- "$receipt")/$(basename -- "$receipt" .json).proof.json"
chmod 600 "$(dirname -- "$receipt")/$receipt_id.proof.json"
chmod 600 "$(dirname -- "$receipt")/$(basename -- "$receipt" .json).proof.json"
jq -cnS --arg id "$receipt_id" --arg point "$point_id" \
  --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg proof "$proof_digest" --arg descriptor "$descriptor_digest" \
  --arg protection "$protection_digest" \
  --arg approval "$approval_digest" \
  --arg reviewer_id "$reviewer_id" \
  --arg command "$(jq -er '.captureCommandDigest' "$point/recovery-point.json")" \
  --argjson capture_at "$capture_at" --argjson verified "$capture_at" \
  '{schema:"meet-backend/beta-backup-receipt/v2",receiptId:$id,pointId:$point,
    captureAt:$capture_at,verifiedCapturedAt:$verified,captureRevision:$capture,
    restoreRevision:$restore,captureCommandDigest:$command,
    pointDescriptorDigest:$descriptor,protectionDigest:$protection,
    approvalDigest:$approval,
    reviewerId:$reviewer_id,proofDigest:$proof}' >"$receipt"
chmod 600 "$receipt"
beta_storage_validate_receipt "$receipt" || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_invalid' >&2
  exit 1
}
printf 'recurring_drill=verified point_id=%s receipt_id=%s proof_digest=%s\n' \
  "$point_id" "$receipt_id" "$proof_digest"
