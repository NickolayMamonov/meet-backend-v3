#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --output DIR --slot UTC_SLOT --captured-at EPOCH --source-revision SHA --runtime-revision SHA --contract-digest DIGEST --proof-digest DIGEST --postgres-ciphertext PATH --media-ciphertext PATH --storage-root DIR" >&2
  exit 2
}

output='' slot='' captured_at='' source_revision='' runtime_revision=''
contract_digest='' proof_digest='' postgres_ciphertext='' media_ciphertext=''
storage_root='' owner=${BETA_BACKUP_OWNER:-capture}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --slot) [ "$#" -ge 2 ] || usage; slot=$2; shift 2 ;;
    --captured-at) [ "$#" -ge 2 ] || usage; captured_at=$2; shift 2 ;;
    --source-revision) [ "$#" -ge 2 ] || usage; source_revision=$2; shift 2 ;;
    --runtime-revision) [ "$#" -ge 2 ] || usage; runtime_revision=$2; shift 2 ;;
    --contract-digest) [ "$#" -ge 2 ] || usage; contract_digest=$2; shift 2 ;;
    --proof-digest) [ "$#" -ge 2 ] || usage; proof_digest=$2; shift 2 ;;
    --postgres-ciphertext) [ "$#" -ge 2 ] || usage; postgres_ciphertext=$2; shift 2 ;;
    --media-ciphertext) [ "$#" -ge 2 ] || usage; media_ciphertext=$2; shift 2 ;;
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$output" = /* && "$output" != *..* ]] || usage
[[ "$slot" =~ ^[0-9]{10}$ && "$captured_at" =~ ^[0-9]+$ ]] || usage
[[ "$source_revision" =~ ^[0-9a-f]{40}$ && "$runtime_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$contract_digest" =~ ^[0-9a-f]{64}$ && "$proof_digest" =~ ^[0-9a-f]{64}$ ]] || usage
[[ "$storage_root" = /* && "$storage_root" != *..* ]] || usage
for ciphertext in "$postgres_ciphertext" "$media_ciphertext"; do
  [[ "$ciphertext" = /* && "$ciphertext" != *..* ]] || usage
  [ -f "$ciphertext" ] && [ ! -L "$ciphertext" ] && [ -s "$ciphertext" ] ||
    { echo 'BACKUP_STORAGE_BLOCKED:ciphertext_missing' >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "BACKUP_STORAGE_BLOCKED:jq_unavailable" >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_require_local_root "$storage_root" >/dev/null
if [ ! -d "$output" ]; then
  mkdir -p "$output"
  chmod 700 "$output"
fi
[ ! -L "$output" ] || { echo 'BACKUP_STORAGE_BLOCKED:output_symlink' >&2; exit 1; }
manifest=$output/recovery-point.json
tmp=$(mktemp "$output/.recovery-point.XXXXXX")
cleanup() { rm -f -- "$tmp"; }
trap cleanup EXIT
db_file=$output/postgres.dump.age
media_file=$output/uploads.tar.gz.age
install -m 600 "$postgres_ciphertext" "$db_file"
install -m 600 "$media_ciphertext" "$media_file"
jq -cnS \
  --arg slot "$slot" \
  --arg source "$source_revision" \
  --arg runtime "$runtime_revision" \
  --argjson captured "$captured_at" \
  --arg contract "$contract_digest" \
  --arg proof "$proof_digest" \
  '{schema:"meet-backend/beta-recovery-point/v2",pointId:("slot-"+$slot),slotId:$slot,
    capture:{capturedAt:$captured,sourceRevision:$source},
    runtimeRevision:$runtime,contractDigest:$contract,proofDigest:$proof}' >"$tmp"
beta_storage_validate_point "$tmp" || {
  echo 'BACKUP_STORAGE_BLOCKED:manifest_invalid' >&2
  exit 1
}
mv -f -- "$tmp" "$manifest"
chmod 600 "$manifest"
"$script_dir/run-beta-backup-storage.sh" publish \
  --source "$output" --storage-root "$storage_root" --point-id "slot-$slot" \
  --slot "$slot" --captured-at "$captured_at" --owner "$owner"
printf 'recurring_capture=committed point_id=slot-%s ciphertext=true durable=true\n' "$slot"
