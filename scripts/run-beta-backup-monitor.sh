#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --storage-root DIR --environment NAME --now EPOCH --receiver-root DIR --incident-state PATH --deadman-url URL" >&2
  exit 2
}
storage_root='' environment='' now='' receiver_root='' incident_state='' deadman_url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --storage-root) [ "$#" -ge 2 ] || usage; storage_root=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    --receiver-root) [ "$#" -ge 2 ] || usage; receiver_root=$2; shift 2 ;;
    --incident-state) [ "$#" -ge 2 ] || usage; incident_state=$2; shift 2 ;;
    --deadman-url) [ "$#" -ge 2 ] || usage; deadman_url=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$storage_root" = /* && "$storage_root" != *..* &&
  "$receiver_root" = /* && "$receiver_root" != *..* &&
  "$incident_state" = /* && "$incident_state" != *..* ]] || usage
[[ "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && "$now" =~ ^[0-9]+$ ]] || usage
[[ -z "$deadman_url" || "$deadman_url" =~ ^https://[^[:space:]]+$ ]] || usage
for tool in jq sha256sum stat find; do command -v "$tool" >/dev/null 2>&1 || exit 1; done
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
beta_storage_require_local_root "$storage_root" >/dev/null
if [ -e "$receiver_root" ] || [ -L "$receiver_root" ]; then
  [ -d "$receiver_root" ] && [ ! -L "$receiver_root" ] || {
    echo 'BACKUP_SAFETY_BLOCKED:receiver_root_unavailable' >&2
    exit 1
  }
else
  mkdir -p "$(dirname -- "$receiver_root")"
fi

head_digest() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  sha256sum "$file" | awk '{print $1}'
}
point_capture() {
  local point_id=$1 point
  point="$storage_root/points/$point_id"
  beta_storage_local_validate_point_dir "$point" "$point_id" || return 1
  jq -er '.capture.capturedAt' "$point/recovery-point.json"
}
capture_state=MISSING capture_id=null capture_at=null verified_state=MISSING
verified_id=null verified_at=null
if [ -f "$storage_root/control/capture-head.json" ] &&
  [ "$(jq -er '.schema' "$storage_root/control/capture-head.json")" = meet-backend/beta-backup-head/v1 ]; then
  candidate=$(jq -er '.pointId' "$storage_root/control/capture-head.json") || candidate=
  if [ -n "$candidate" ] && capture_at=$(point_capture "$candidate"); then
    capture_state=VALID
    capture_id=$candidate
  else
    capture_state=INVALID
  fi
fi
if [ -f "$storage_root/control/verified-head.json" ] &&
  [ "$(jq -er '.schema' "$storage_root/control/verified-head.json")" = meet-backend/beta-backup-verified-head/v1 ]; then
  candidate=$(jq -er '.pointId' "$storage_root/control/verified-head.json") || candidate=
  if [ -n "$candidate" ] && verified_at=$(point_capture "$candidate"); then
    verified_state=VALID
    verified_id=$candidate
  else
    verified_state=INVALID
  fi
fi
authority_digest=$(
{
  head_digest "$storage_root/control/capture-head.json" 2>/dev/null || true
  head_digest "$storage_root/control/verified-head.json" 2>/dev/null || true
} | sha256sum | awk '{print $1}')
generation=0
for head in "$storage_root/control/capture-head.json" "$storage_root/control/verified-head.json"; do
  [ -f "$head" ] || continue
  value=$(jq -er '.generation' "$head") || value=0
  (( value > generation )) && generation=$value
done
status_tmp=$(mktemp)
trap 'rm -f -- "$status_tmp"' EXIT
jq -cnS --arg environment "$environment" --arg digest "$authority_digest" \
  --arg captureState "$capture_state" --arg verifiedState "$verified_state" \
  --arg captureId "$capture_id" --arg verifiedId "$verified_id" \
  --argjson observed "$now" --argjson generation "$generation" \
  --argjson captureAt "$capture_at" --argjson verifiedAt "$verified_at" \
  '{schema:"meet-backend/beta-backup-status/v1",environment:$environment,
    observedAt:$observed,authorityGeneration:$generation,authorityDigest:$digest,
    capture:{state:$captureState,id:(if $captureId=="null" then null else $captureId end),
      capturedAt:(if $captureAt==null then null else $captureAt end)},
    verified:{state:$verifiedState,id:(if $verifiedId=="null" then null else $verifiedId end),
      capturedAt:(if $verifiedAt==null then null else $verifiedAt end)}}' >"$status_tmp"
mkdir -p "$(dirname -- "$incident_state")"
reasons=()
[ "$capture_state" = VALID ] || reasons+=(capture_missing_or_invalid)
[ "$capture_state" = VALID ] && (( now - capture_at >= 86400 )) && reasons+=(capture_older_than_24h)
[ "$capture_state" = VALID ] && (( now - capture_at >= 108000 )) && reasons+=(capture_older_than_30h)
[ "$verified_state" = VALID ] || reasons+=(verified_missing_or_invalid)
[ "$verified_state" = VALID ] && (( now - verified_at >= 1209600 )) && reasons+=(verified_older_than_14d)
if [ "${#reasons[@]}" -gt 0 ]; then
  jq -cnS --arg environment "$environment" \
    --argjson reasons "$(printf '%s\n' "${reasons[@]}" | jq -Rsc 'split("\n")|map(select(length>0))')" \
    '{schema:"meet-backend/beta-backup-incident/v1",environment:$environment,
      state:"active",reasons:$reasons}' >"$incident_state"
else
  jq -cnS --arg environment "$environment" \
    '{schema:"meet-backend/beta-backup-incident/v1",environment:$environment,
      state:"recovered",reasons:[]}' >"$incident_state"
fi
chmod 600 "$incident_state"
"$script_dir/receive-beta-backup-status.sh" --input "$status_tmp" \
  --root "$receiver_root" --environment "$environment" --now "$now" >/dev/null
if [ -n "$deadman_url" ]; then
  curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
    --max-redirs 0 --request POST --data-binary '' "$deadman_url" >/dev/null 2>/dev/null ||
    { echo 'BACKUP_SAFETY_BLOCKED:deadman_failed' >&2; exit 1; }
fi
printf 'monitor_status=delivered incident=%s heartbeat=%s\n' \
  "$([ "${#reasons[@]}" -gt 0 ] && echo true || echo false)" \
  "$([ -n "$deadman_url" ] && echo sent || echo not_configured)"
