#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --storage-root DIR --point-id ID --receipt PATH --proof-file PATH --capture-revision SHA --restore-revision SHA" >&2
  exit 2
}
root='' point_id='' receipt='' proof='' capture_revision='' restore_revision=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
    --point-id) [ "$#" -ge 2 ] || usage; point_id=$2; shift 2 ;;
    --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
    --proof-file) [ "$#" -ge 2 ] || usage; proof=$2; shift 2 ;;
    --capture-revision) [ "$#" -ge 2 ] || usage; capture_revision=$2; shift 2 ;;
    --restore-revision) [ "$#" -ge 2 ] || usage; restore_revision=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$root" = /* && "$root" != *..* && "$receipt" = /* && "$receipt" != *..* &&
  "$proof" = /* && "$proof" != *..* ]] || usage
[[ "$point_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || usage
[[ "$capture_revision" =~ ^[0-9a-f]{40}$ && "$restore_revision" =~ ^[0-9a-f]{40}$ ]] || usage
command -v jq >/dev/null 2>&1 || exit 1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_require_local_root "$root" >/dev/null
point="$root/points/$point_id"
beta_storage_local_validate_point_dir "$point" "$point_id" ||
  { echo 'BACKUP_STORAGE_BLOCKED:point_unavailable' >&2; exit 1; }
[ -f "$proof" ] && [ ! -L "$proof" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_proof_missing' >&2
  exit 1
}
jq -e '
  type=="object" and (keys|sort)==["cleanup","isolated","postFingerprint","preFingerprint","schema"] and
  .schema=="meet-backend/beta-recurring-drill-proof/v1" and .isolated==true and .cleanup==true and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  .preFingerprint==.postFingerprint
' "$proof" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:restore_proof_invalid' >&2
  exit 1
}
mkdir -p "$(dirname -- "$receipt")"
receipt_id="receipt-$(date -u +%Y%m%dT%H%M%SZ)-$point_id"
jq -cnS --arg id "$receipt_id" --arg point "$point_id" \
  --arg capture "$capture_revision" --arg restore "$restore_revision" \
  --arg proof "$(sha256sum "$proof" | awk '{print $1}')" \
  --argjson verified "$(jq -er '.capture.capturedAt' "$point/recovery-point.json")" \
  '{schema:"meet-backend/beta-backup-receipt/v1",receiptId:$id,pointId:$point,
    captureRevision:$capture,restoreRevision:$restore,proofDigest:$proof,
    verifiedCapturedAt:$verified}' >"$receipt"
chmod 600 "$receipt"
beta_storage_validate_receipt "$receipt" ||
  { echo 'BACKUP_CUSTODY_BLOCKED:receipt_invalid' >&2; exit 1; }
printf 'recurring_drill=verified point_id=%s receipt_id=%s\n' "$point_id" "$receipt_id"
