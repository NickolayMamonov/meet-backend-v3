#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --status PATH --environment NAME --now EPOCH --output PATH" >&2
  exit 2
}

status='' environment='' now='' output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status) [ "$#" -ge 2 ] || usage; status=$2; shift 2 ;;
    --environment) [ "$#" -ge 2 ] || usage; environment=$2; shift 2 ;;
    --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$status" = /* && "$output" = /* && "$status" != *..* && "$output" != *..* ]] || usage
[[ "$now" =~ ^[0-9]+$ ]] || usage
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-policy.sh
source "$script_dir/beta-backup-policy.sh"
: "${beta_backup_capture_breach_seconds:=86400}"
: "${beta_backup_capture_alert_seconds:=108000}"
: "${beta_backup_verified_block_seconds:=1209600}"
beta_backup_validate_status "$status" "$now" "$environment"

capture_state=$(jq -er '.capture.state' "$status")
verified_state=$(jq -er '.verified.state' "$status")
capture_age=null
verified_age=null
if [ "$capture_state" = VALID ]; then
  capture_age=$((now - $(jq -er '.capture.capturedAt' "$status")))
fi
if [ "$verified_state" = VALID ]; then
  verified_age=$((now - $(jq -er '.verified.capturedAt' "$status")))
fi
reasons=()
[ "$capture_state" = VALID ] || reasons+=(capture_missing_or_invalid)
[ "$capture_state" = VALID ] && [ "$capture_age" -ge "$beta_backup_capture_breach_seconds" ] &&
  reasons+=(capture_older_than_24h)
[ "$capture_state" = VALID ] && [ "$capture_age" -ge "$beta_backup_capture_alert_seconds" ] &&
  reasons+=(capture_older_than_30h)
[ "$verified_state" = VALID ] || reasons+=(verified_missing_or_invalid)
[ "$verified_state" = VALID ] && [ "$verified_age" -ge "$beta_backup_verified_block_seconds" ] &&
  reasons+=(verified_older_than_14d)
if [ ! -d "$(dirname -- "$output")" ]; then
  mkdir -p "$(dirname -- "$output")"
  chmod 700 "$(dirname -- "$output")"
fi
tmp=$(mktemp "$(dirname -- "$output")/.monitor.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
jq -cnS \
  --arg environment "$environment" --argjson observed "$now" \
  --arg captureState "$capture_state" --arg verifiedState "$verified_state" \
  --argjson captureAge "$capture_age" --argjson verifiedAge "$verified_age" \
  --argjson reasons "$(printf '%s\n' "${reasons[@]:-}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
  '{schema:"meet-backend/beta-backup-monitor/v1",environment:$environment,
    observedAt:$observed,captureState:$captureState,verifiedState:$verifiedState,
    captureAgeSeconds:$captureAge,verifiedAgeSeconds:$verifiedAge,reasons:$reasons}' >"$tmp"
mv -f -- "$tmp" "$output"
chmod 600 "$output"
printf 'monitor_status=written incident=%s\n' "$([ "${#reasons[@]}" -gt 0 ] && echo true || echo false)"
