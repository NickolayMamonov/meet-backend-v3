#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --source DIR --destination DIR --manifest PATH --storage-root DIR --restore-proof PATH" >&2
  exit 2
}

source_dir='' destination_dir='' manifest='' storage_root='' restore_proof=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) [ "$#" -ge 2 ] || usage; source_dir=$2; shift 2 ;;
    --destination) [ "$#" -ge 2 ] || usage; destination_dir=$2; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || usage; manifest=$2; shift 2 ;;
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --restore-proof) [ "$#" -ge 2 ] || usage; restore_proof=$2; shift 2 ;;
    *) usage ;;
  esac
done
for path in "$source_dir" "$destination_dir" "$manifest" "$storage_root" "$restore_proof"; do
  [[ "$path" = /* && "$path" != *..* ]] || usage
done
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:source_unavailable' >&2; exit 1;
}
[ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:destination_unavailable' >&2; exit 1;
}
[ -f "$manifest" ] && [ ! -L "$manifest" ] || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_unavailable' >&2; exit 1;
}
[ -f "$restore_proof" ] && [ ! -L "$restore_proof" ] || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_proof_missing' >&2; exit 1;
}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_validate_point "$manifest" || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_invalid' >&2; exit 1;
}
jq -e '
  type=="object" and (keys|sort)==["cleanup","isolated","postFingerprint","preFingerprint","schema"] and
  .schema=="meet-backend/beta-recurring-drill-proof/v1" and .isolated==true and
  .cleanup==true and .preFingerprint==.postFingerprint and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$"))
' "$restore_proof" >/dev/null || {
  echo 'BACKUP_CUSTODY_BLOCKED:destination_restore_proof_invalid' >&2; exit 1;
}
for object in postgres.dump.age uploads.tar.gz.age; do
  [ -f "$source_dir/$object" ] && [ ! -L "$source_dir/$object" ] && [ -s "$source_dir/$object" ] ||
    { echo "BACKUP_STORAGE_BLOCKED:source_ciphertext_missing" >&2; exit 1; }
  install -m 600 "$source_dir/$object" "$destination_dir/$object"
done
install -m 600 "$manifest" "$destination_dir/recovery-point.json"
point_id=$(jq -er '.pointId' "$manifest")
slot=$(jq -er '.slotId' "$manifest")
captured_at=$(jq -er '.capture.capturedAt' "$manifest")
"$script_dir/run-beta-backup-storage.sh" publish \
  --source "$destination_dir" --storage-root "$storage_root" \
  --point-id "$point_id" --slot "$slot" --captured-at "$captured_at" --owner migration
beta_storage_local_validate_point_dir "$storage_root/points/$point_id" "$point_id" ||
  { echo 'BACKUP_STORAGE_BLOCKED:destination_integrity_failed' >&2; exit 1; }
printf 'migration_status=verified destination_point_id=%s original_manifest_sha256=%s\n' \
  "$point_id" "$(sha256sum "$manifest" | awk '{print $1}')"
