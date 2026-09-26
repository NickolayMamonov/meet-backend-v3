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
[ "$pre_digest" != "$post_digest" ] || beta_storage_fail probe_replay
pre_version=$pre_digest
post_version=$post_digest
jq -e '
  type=="object" and .schema=="meet-backend/test-vps-recovery-runtime/v1" and
  .healthy==true and .runtime.health=="healthy" and
  .runtime.uploadsMount=="volume" and .https.meetingsStatus=="200" and
  .https.actuatorStatus=="404" and .https.httpRedirectHttps==true and
  .https.meetingsJson==true
' "$pre_probe" "$post_probe" >/dev/null || beta_storage_fail probe_invalid
pre_fingerprint=$(jq -er '.preFingerprint' \
  "$(dirname "$receipt")/$(jq -er '.receiptId' "$receipt").proof.json")
post_fingerprint=$(jq -er '.postFingerprint' \
  "$(dirname "$receipt")/$(jq -er '.receiptId' "$receipt").proof.json")
[ "$pre_fingerprint" != "$post_fingerprint" ] || beta_storage_fail fingerprint_replay
descriptor=$(jq -er '.pointDescriptorDigest' "$receipt")
point=$(jq -er '.pointId' "$receipt")
receipt_id=$(jq -er '.receiptId' "$receipt")
jq -e --arg pre "$pre_fingerprint" --arg post "$post_fingerprint" \
  '.preFingerprint==$pre and .postFingerprint==$post and
   .preFingerprint != .postFingerprint' \
  "$(dirname "$receipt")/$receipt_id.proof.json" >/dev/null ||
  beta_storage_fail probe_fingerprint_binding
mkdir -p "$(dirname -- "$output")"
jq -cnS --arg receipt "$receipt_id" --arg point "$point" \
  --arg descriptor "$descriptor" --arg pre "$pre_digest" --arg post "$post_digest" \
  --arg preVersion "$pre_version" --arg postVersion "$post_version" \
  --arg preFingerprint "$pre_fingerprint" --arg postFingerprint "$post_fingerprint" \
  '{schema:"meet-backend/beta-recurring-probe-binding/v1",
    receiptId:$receipt,pointId:$point,pointDescriptorDigest:$descriptor,
    preProbeDigest:$pre,postProbeDigest:$post,
    preProbeVersion:$preVersion,postProbeVersion:$postVersion,
    preFingerprint:$preFingerprint,postFingerprint:$postFingerprint}' |
  install -m 600 /dev/stdin "$output"
