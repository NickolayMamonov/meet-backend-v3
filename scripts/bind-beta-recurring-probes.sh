#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --receipt PATH --pre-probe PATH --post-probe PATH --output PATH" >&2
  exit 2
}

receipt='' pre_probe='' post_probe='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
    --pre-probe) [ "$#" -ge 2 ] || usage; pre_probe=$2; shift 2 ;;
    --post-probe) [ "$#" -ge 2 ] || usage; post_probe=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
for path in "$receipt" "$pre_probe" "$post_probe" "$output"; do
  [[ "$path" = /* && "$path" != *..* && "$path" != *$'\n'* ]] || usage
done
[ -f "$receipt" ] && [ ! -L "$receipt" ] || exit 1
[ -f "$pre_probe" ] && [ ! -L "$pre_probe" ] || exit 1
[ -f "$post_probe" ] && [ ! -L "$post_probe" ] || exit 1
command -v jq >/dev/null 2>&1 || exit 1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_validate_receipt "$receipt" || beta_storage_fail receipt_invalid
pre_digest=$(sha256sum "$pre_probe" | awk '{print $1}')
post_digest=$(sha256sum "$post_probe" | awk '{print $1}')
pre_version=$pre_digest
post_version=$post_digest
jq -e '
  type=="object" and
  (keys|sort)==["healthy","https","runtime","schema"] and
  .schema=="meet-backend/test-vps-recovery-runtime/v1" and
  .healthy==true and .runtime.health=="healthy" and
  (.runtime | (keys|sort)==["configHash","health","imageId","uploadsMount"]) and
  (.runtime.configHash|type=="string" and test("^[0-9a-f]{64}$")) and
  .runtime.uploadsMount=="volume" and
  (.https | (keys|sort)==["actuatorStatus","httpRedirectHttps","meetingsJson","meetingsStatus"]) and
  .https.meetingsStatus=="200" and .https.actuatorStatus=="404" and
  .https.httpRedirectHttps==true and .https.meetingsJson==true
' "$pre_probe" "$post_probe" >/dev/null || beta_storage_fail probe_invalid
pre_runtime_fingerprint=$(jq -cS '{schema,healthy,runtime,https}' "$pre_probe" |
  sha256sum | awk '{print $1}')
post_runtime_fingerprint=$(jq -cS '{schema,healthy,runtime,https}' "$post_probe" |
  sha256sum | awk '{print $1}')
[[ "$pre_runtime_fingerprint" =~ ^[0-9a-f]{64}$ &&
  "$post_runtime_fingerprint" =~ ^[0-9a-f]{64}$ ]] ||
  beta_storage_fail runtime_fingerprint_invalid
descriptor=$(jq -er '.pointDescriptorDigest' "$receipt")
point=$(jq -er '.pointId' "$receipt")
receipt_id=$(jq -er '.receiptId' "$receipt")
restore_proof="$(dirname "$receipt")/$receipt_id.proof.json"
jq -e '
  .schema=="meet-backend/beta-recurring-restore-proof/v2" and
  (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
  .preFingerprint == .postFingerprint
' "$restore_proof" >/dev/null || beta_storage_fail restore_fingerprint_binding
mkdir -p "$(dirname -- "$output")"
jq -cnS --arg receipt "$receipt_id" --arg point "$point" \
  --arg descriptor "$descriptor" --arg pre "$pre_digest" --arg post "$post_digest" \
  --arg preVersion "$pre_version" --arg postVersion "$post_version" \
  --arg preRuntime "$pre_runtime_fingerprint" --arg postRuntime "$post_runtime_fingerprint" \
  --arg restoreProof "$(jq -er '.proofDigest' "$receipt")" \
  --arg restorePre "$(jq -er '.preFingerprint' "$restore_proof")" \
  --arg restorePost "$(jq -er '.postFingerprint' "$restore_proof")" \
  '{schema:"meet-backend/beta-recurring-probe-binding/v2",
    receiptId:$receipt,pointId:$point,pointDescriptorDigest:$descriptor,
    preProbeDigest:$pre,postProbeDigest:$post,
    preProbeVersion:$preVersion,postProbeVersion:$postVersion,
    preRuntimeFingerprint:$preRuntime,postRuntimeFingerprint:$postRuntime,
    restoreProofDigest:$restoreProof,restorePreFingerprint:$restorePre,
    restorePostFingerprint:$restorePost}' |
  install -m 600 /dev/stdin "$output"
