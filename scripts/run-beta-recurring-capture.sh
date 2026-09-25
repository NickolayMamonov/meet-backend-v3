#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --output DIR --slot UTC_SLOT --captured-at EPOCH --source-revision SHA --runtime-revision SHA --contract-digest DIGEST --proof-digest DIGEST" >&2
  exit 2
}

output='' slot='' captured_at='' source_revision='' runtime_revision='' contract_digest='' proof_digest=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --slot) [ "$#" -ge 2 ] || usage; slot=$2; shift 2 ;;
    --captured-at) [ "$#" -ge 2 ] || usage; captured_at=$2; shift 2 ;;
    --source-revision) [ "$#" -ge 2 ] || usage; source_revision=$2; shift 2 ;;
    --runtime-revision) [ "$#" -ge 2 ] || usage; runtime_revision=$2; shift 2 ;;
    --contract-digest) [ "$#" -ge 2 ] || usage; contract_digest=$2; shift 2 ;;
    --proof-digest) [ "$#" -ge 2 ] || usage; proof_digest=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$output" = /* && "$output" != *..* ]] || usage
[[ "$slot" =~ ^[0-9]{10}$ && "$captured_at" =~ ^[0-9]+$ ]] || usage
[[ "$source_revision" =~ ^[0-9a-f]{40}$ && "$runtime_revision" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$contract_digest" =~ ^[0-9a-f]{64}$ && "$proof_digest" =~ ^[0-9a-f]{64}$ ]] || usage
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
if [ ! -d "$output" ]; then
  mkdir -p "$output"
  chmod 700 "$output"
fi
manifest=$output/recovery-point.json
descriptor=$output/point.json
tmp=$(mktemp "$output/.recovery-point.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
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
beta_storage_validate_point "$tmp"
mv -f -- "$tmp" "$manifest"
chmod 600 "$manifest"
# The descriptor is committed last and binds exact ciphertext metadata. The
# capture job supplies only opaque object metadata; plaintext never enters it.
jq -cnS --arg point "slot-$slot" --arg manifest "$(sha256sum "$manifest" | awk '{print $1}')" \
  '{schema:"meet-backend/beta-backup-descriptor/v1",pointId:$point,manifestSha256:$manifest,
    committedAt:(now|floor)}' >"$descriptor"
chmod 600 "$descriptor"
printf 'recurring_capture=staged point_id=slot-%s manifest_last=true\n' "$slot"
