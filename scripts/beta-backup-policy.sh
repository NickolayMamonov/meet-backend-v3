#!/usr/bin/env bash
set -euo pipefail

# Shared closed-schema policy primitives. Callers must provide an explicit
# current UTC epoch; this keeps tests deterministic and prevents copy/drill
# operations from renewing the age of a retained capture.
beta_backup_capture_breach_seconds=86400
beta_backup_capture_alert_seconds=108000
beta_backup_verified_block_seconds=1209600
beta_backup_snapshot_block_seconds=1800

beta_backup_fail() {
  printf 'BACKUP_SAFETY_BLOCKED:%s\n' "$1" >&2
  return 1
}

beta_backup_require_jq() {
  command -v jq >/dev/null 2>&1 || beta_backup_fail 'jq_unavailable'
}

beta_backup_validate_status() {
  local file=$1 now=$2 environment=$3
  beta_backup_require_jq
  [[ "$now" =~ ^[0-9]+$ ]] || beta_backup_fail 'clock_invalid'
  [[ "$environment" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    beta_backup_fail 'environment_invalid'
  [ -f "$file" ] && [ ! -L "$file" ] || beta_backup_fail 'snapshot_missing'
  [ "$(wc -c <"$file")" -le 65536 ] || beta_backup_fail 'snapshot_oversize'
  jq -e --arg environment "$environment" '
    type == "object" and
    (keys | sort) == ["authorityDigest","authorityGeneration","capture","environment","observedAt","schema","verified"] and
    .schema == "meet-backend/beta-backup-status/v1" and
    .environment == $environment and
    (.observedAt | type == "number" and floor == . and . >= 0) and
    (.authorityGeneration | type == "number" and floor == . and . >= 0) and
    (.authorityDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    ([.capture, .verified] | all(
      type == "object" and
      (keys | sort) == ["capturedAt","id","state"] and
      (.state == "VALID" or .state == "MISSING" or .state == "INVALID") and
      (if .state == "VALID"
       then (.id | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
            (.capturedAt | type == "number" and floor == . and . >= 0)
       else (.id == null and .capturedAt == null)
       end)
    )) and
    (if .capture.state == "VALID" then .capture.capturedAt <= .observedAt else true end) and
    (if .verified.state == "VALID" then .verified.capturedAt <= .observedAt else true end)
  ' "$file" >/dev/null || beta_backup_fail 'snapshot_invalid'
  local observed
  observed=$(jq -er '.observedAt' "$file")
  (( observed <= now )) || beta_backup_fail 'snapshot_future'
  (( now - observed <= beta_backup_snapshot_block_seconds )) ||
    beta_backup_fail 'snapshot_stale'
}

beta_backup_require_admission() {
  local file=$1 now=$2 environment=$3
  beta_backup_validate_status "$file" "$now" "$environment"
  jq -e '.verified.state == "VALID"' "$file" >/dev/null ||
    beta_backup_fail 'verified_missing'
  local verified
  verified=$(jq -er '.verified.capturedAt' "$file")
  (( verified <= now )) || beta_backup_fail 'verified_future'
  (( now - verified < beta_backup_verified_block_seconds )) ||
    beta_backup_fail 'verified_stale'
}

beta_backup_capture_state() {
  local file=$1 now=$2
  local capture_state capture_time
  capture_state=$(jq -er '.capture.state' "$file")
  if [ "$capture_state" != VALID ]; then
    printf 'capture_state=%s capture_age=unknown breach=true alert=true\n' "$capture_state"
    return 0
  fi
  capture_time=$(jq -er '.capture.capturedAt' "$file")
  if (( capture_time > now )); then
    printf 'capture_state=invalid capture_age=unknown breach=true alert=true\n'
    return 0
  fi
  local age=$((now - capture_time))
  printf 'capture_state=valid capture_age=%s breach=%s alert=%s\n' \
    "$age" "$(( age >= beta_backup_capture_breach_seconds ? 1 : 0 ))" \
    "$(( age >= beta_backup_capture_alert_seconds ? 1 : 0 ))"
}
