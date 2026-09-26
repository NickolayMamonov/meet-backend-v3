#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --storage-root DIR --point-id ID --receipt PATH --restore-command PATH --restore-output DIR --identity-file PATH --capture-revision SHA --restore-revision SHA --reviewer-id ID --protection-file PATH --protection-digest DIGEST" >&2
  exit 2
}

root='' point_id='' receipt='' restore_command='' restore_output='' identity=''
capture_revision='' restore_revision='' reviewer_id='' protection_file='' protection_digest=''
while [ "$#" -gt 0 ]; do
  case "$1" in
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
    *) usage ;;
  esac
done

for path in "$root" "$receipt" "$restore_command" "$restore_output" "$identity" "$protection_file"; do
  [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[[ "$point_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || usage
[[ "$capture_revision" =~ ^[0-9a-f]{40}$ && "$restore_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$reviewer_id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] || usage
[[ "$protection_digest" =~ ^[0-9a-f]{64}$ ]] || usage
[ -x "$restore_command" ] && [ ! -L "$restore_command" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_command_unavailable' >&2
  exit 1
}
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
command -v jq >/dev/null 2>&1 || exit 1
command -v timeout >/dev/null 2>&1 || exit 1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_require_local_root "$root" >/dev/null
point="$root/points/$point_id"
beta_storage_local_validate_point_dir "$point" "$point_id" || {
  echo 'BACKUP_CUSTODY_BLOCKED:point_unavailable' >&2
  exit 1
}

jq -e --arg reviewer "$reviewer_id" --arg digest "$protection_digest" '
  type=="object" and
  (keys|sort)==["adminBypassAllowed","branchPolicy","environment","preventSelfReview",
    "protectionDigest","reviewerId","reviewerRequired","schema"] and
  .schema=="meet-backend/beta-recurring-restore-protection/v1" and
  .environment=="closed-beta-recurring-restore" and
  .branchPolicy=="refs/heads/master" and
  .reviewerRequired==true and .preventSelfReview==true and
  .adminBypassAllowed==false and .reviewerId==$reviewer and
  .protectionDigest==$digest and (.protectionDigest|test("^[0-9a-f]{64}$"))
' "$protection_file" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_metadata_invalid' >&2
  exit 1
}
[ "$(jq -cS 'del(.protectionDigest)' "$protection_file" | sha256sum | awk '{print $1}')" = "$protection_digest" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:protection_metadata_changed' >&2
  exit 1
}

descriptor_digest=$(sha256sum "$point/point.json" | awk '{print $1}')
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
trap 'rm -f -- "$proof_tmp"' EXIT HUP INT TERM
timeout --foreground --signal=TERM 1800s "$restore_command" \
  --point-dir "$point" --identity-file "$identity" --output-dir "$restore_output" \
  --capture-revision "$capture_revision" --restore-revision "$restore_revision" \
  --protection-digest "$protection_digest" --proof-output "$proof_tmp"

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
  --argjson captured "$capture_at" '
  type=="object" and
  (keys|sort)==["captureRevision","capturedAt","cleanup","databaseProbe","identityCustody",
    "isolated","mediaProbe","pointDescriptorDigest","postFingerprint","preFingerprint",
    "protectionDigest","restoreRevision","schema"] and
  .schema=="meet-backend/beta-recurring-restore-proof/v2" and
  .captureRevision==$capture and .restoreRevision==$restore and
  .capturedAt==$captured and
  .pointDescriptorDigest==$descriptor and .protectionDigest==$protection and
  .identityCustody=="restore-only" and .isolated==true and .cleanup==true and
  (.databaseProbe==true and .mediaProbe==true) and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  .preFingerprint==.postFingerprint and
  (.capturedAt|type=="number" and floor==. and .>=0)
' "$proof_tmp" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_proof_invalid' >&2
  exit 1
}
proof_digest=$(sha256sum "$proof_tmp" | awk '{print $1}')
receipt_id="receipt-$(date -u +%Y%m%dT%H%M%SZ)-$point_id"
mkdir -p "$(dirname -- "$receipt")"
cp -- "$proof_tmp" "$(dirname -- "$receipt")/$receipt_id.proof.json"
chmod 600 "$(dirname -- "$receipt")/$receipt_id.proof.json"
jq -cnS --arg id "$receipt_id" --arg point "$point_id" \
  --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg proof "$proof_digest" --arg descriptor "$descriptor_digest" \
  --arg protection "$protection_digest" \
  --arg command "$(jq -er '.captureCommandDigest' "$point/recovery-point.json")" \
  --argjson capture_at "$capture_at" --argjson verified "$capture_at" \
  '{schema:"meet-backend/beta-backup-receipt/v2",receiptId:$id,pointId:$point,
    captureAt:$capture_at,verifiedCapturedAt:$verified,captureRevision:$capture,
    restoreRevision:$restore,captureCommandDigest:$command,
    pointDescriptorDigest:$descriptor,protectionDigest:$protection,
    proofDigest:$proof}' >"$receipt"
chmod 600 "$receipt"
beta_storage_validate_receipt "$receipt" || {
  echo 'BACKUP_CUSTODY_BLOCKED:receipt_invalid' >&2
  exit 1
}
printf 'recurring_drill=verified point_id=%s receipt_id=%s proof_digest=%s\n' \
  "$point_id" "$receipt_id" "$proof_digest"
