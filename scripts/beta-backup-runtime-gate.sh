#!/usr/bin/env bash
set -euo pipefail

beta_backup_runtime_load_env_file() {
  local env_file=${1:-} line key value
  [ -n "$env_file" ] || return 0
  [ -f "$env_file" ] && [ ! -L "$env_file" ] || {
    echo "BACKUP_SAFETY_BLOCKED: production environment is unavailable" >&2
    return 1
  }
  declare -A seen=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
      APP_BACKUP_SAFETY_*=*)
        key=${line%%=*}
        value=${line#*=}
        [[ "$key" =~ ^APP_BACKUP_SAFETY_[A-Z0-9_]+$ ]] ||
          { echo "BACKUP_SAFETY_BLOCKED: enrollment key is invalid" >&2; return 1; }
        [[ "$value" != *[[:cntrl:]]* ]] ||
          { echo "BACKUP_SAFETY_BLOCKED: enrollment value is invalid" >&2; return 1; }
        [ -z "${seen[$key]+present}" ] ||
          { echo "BACKUP_SAFETY_BLOCKED: enrollment key is duplicated" >&2; return 1; }
        seen[$key]=1
        export "$key=$value"
        ;;
    esac
  done <"$env_file"
}

beta_backup_runtime_resolve_config() {
  beta_backup_runtime_load_env_file "${1:-${APP_BACKUP_SAFETY_ENV_FILE:-}}"
  APP_BACKUP_SAFETY_ENABLED=${APP_BACKUP_SAFETY_ENABLED:-false}
  APP_BACKUP_SAFETY_ENROLLED=${APP_BACKUP_SAFETY_ENROLLED:-false}
  APP_BACKUP_SAFETY_ENVIRONMENT=${APP_BACKUP_SAFETY_ENVIRONMENT:-closed-beta}
  APP_BACKUP_SAFETY_STATUS_PATH=${APP_BACKUP_SAFETY_STATUS_PATH:-/var/lib/meet-production/beta-backup-control/status.json}
  APP_BACKUP_SAFETY_WATERMARK_PATH=${APP_BACKUP_SAFETY_WATERMARK_PATH:-${APP_BACKUP_SAFETY_STATUS_PATH%/*}/watermark.json}
  [ "${APP_BACKUP_SAFETY_SNAPSHOT_MAX_AGE_SECONDS:-1800}" = 1800 ] ||
    { echo "BACKUP_SAFETY_BLOCKED: snapshot threshold is not the fixed policy" >&2; return 1; }
  [ "${APP_BACKUP_SAFETY_VERIFIED_MAX_AGE_SECONDS:-1209600}" = 1209600 ] ||
    { echo "BACKUP_SAFETY_BLOCKED: verification threshold is not the fixed policy" >&2; return 1; }
}

beta_backup_runtime_require_mount() {
  local status_path=$1 root=${1%/*}
  [ -d "$root" ] && [ ! -L "$root" ] || {
    echo "BACKUP_SAFETY_BLOCKED: control mount is unavailable" >&2
    return 1
  }
  if [ "$(uname -s)" = Linux ]; then
    [ "$(stat -c '%a' "$root" 2>/dev/null)" = 750 ] ||
      { echo "BACKUP_SAFETY_BLOCKED: control mount mode is invalid" >&2; return 1; }
  fi
  [ -f "$status_path" ] && [ ! -L "$status_path" ] ||
    { echo "BACKUP_SAFETY_BLOCKED: control status is unavailable" >&2; return 1; }
  local watermark=${APP_BACKUP_SAFETY_WATERMARK_PATH:-${root}/watermark.json}
  [ -f "$watermark" ] && [ ! -L "$watermark" ] ||
    { echo "BACKUP_SAFETY_BLOCKED: control watermark is unavailable" >&2; return 1; }
}

beta_backup_runtime_require_operation() {
  local image=${1:-} operation=${2:-operation} env_file=${3:-${APP_BACKUP_SAFETY_ENV_FILE:-}}
  beta_backup_runtime_resolve_config "$env_file"
  [ "$APP_BACKUP_SAFETY_ENABLED" = true ] || return 0
  [ "$APP_BACKUP_SAFETY_ENROLLED" = true ] ||
    { echo "BACKUP_SAFETY_BLOCKED: enrollment is unavailable for $operation" >&2; return 1; }
  local status_path=$APP_BACKUP_SAFETY_STATUS_PATH
  local environment=$APP_BACKUP_SAFETY_ENVIRONMENT
  local now=${APP_BACKUP_SAFETY_NOW_EPOCH:-$(date -u +%s)}
  beta_backup_runtime_require_mount "$status_path"
  APP_BACKUP_SAFETY_STATUS_PATH="$status_path" \
    APP_BACKUP_SAFETY_WATERMARK_PATH="$APP_BACKUP_SAFETY_WATERMARK_PATH" \
    APP_BACKUP_SAFETY_ENVIRONMENT="$environment" \
    APP_BACKUP_SAFETY_NOW_EPOCH="$now" \
    "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/check-beta-backup-safety.sh" \
    "$operation" >/dev/null
  if [ -n "$image" ]; then
    command -v docker >/dev/null 2>&1 ||
      { echo "BACKUP_SAFETY_BLOCKED: image capability cannot be inspected" >&2; return 1; }
    [ "$(docker image inspect "$image" --format '{{ index .Config.Labels "org.opencontainers.image.backup-safety-gate" }}')" = v1 ] ||
      { echo "BACKUP_SAFETY_BLOCKED: image lacks backup gate capability" >&2; return 1; }
  fi
}

beta_backup_runtime_admission_fingerprints() {
  beta_backup_runtime_resolve_config "${1:-${APP_BACKUP_SAFETY_ENV_FILE:-}}"
  local status_path=$APP_BACKUP_SAFETY_STATUS_PATH
  local control_root
  control_root=$(dirname -- "$status_path")
  local status_digest mount_digest enrollment_digest verified_at
  status_digest=$(sha256sum "$status_path" | awk '{print $1}')
  mount_digest=$(stat -c '%d:%i:%a:%u:%g' "$control_root" | sha256sum | awk '{print $1}')
  enrollment_digest=$(printf '%s\0%s\0%s\0%s\0%s' \
    "$APP_BACKUP_SAFETY_ENABLED" "$APP_BACKUP_SAFETY_ENROLLED" \
    "$APP_BACKUP_SAFETY_ENVIRONMENT" "$APP_BACKUP_SAFETY_STATUS_PATH" \
    "$APP_BACKUP_SAFETY_WATERMARK_PATH" |
    sha256sum | awk '{print $1}')
  verified_at=$(jq -er '.verified.capturedAt' "$status_path")
  printf '%s %s %s %s %s\n' \
    "$enrollment_digest" "$mount_digest" "$status_digest" \
    "${APP_BACKUP_SAFETY_NOW_EPOCH:-$(date -u +%s)}" "$verified_at"
}

beta_backup_runtime_validate_watermark() {
  local status_path=$1 watermark_path=$2
  local digest generation observed
  digest=$(sha256sum "$status_path" | awk '{print $1}')
  generation=$(jq -er '.authorityGeneration' "$status_path")
  observed=$(jq -er '.observedAt' "$status_path")
  jq -e --arg digest "$digest" --argjson generation "$generation" \
    --argjson observed "$observed" '
      type=="object" and
      (keys|sort)==["authorityGeneration","observedAt","schema","statusDigest"] and
      .schema=="meet-backend/beta-backup-watermark/v1" and
      .authorityGeneration==$generation and .observedAt==$observed and
      .statusDigest==$digest and (.statusDigest|test("^[0-9a-f]{64}$"))
    ' "$watermark_path" >/dev/null
}

beta_backup_runtime_revalidate_fingerprints() {
  local enrollment=$1 mount=$2 status_digest=$3 observed=$4 verified=$5
  beta_backup_runtime_resolve_config "${6:-${APP_BACKUP_SAFETY_ENV_FILE:-}}"
  [ "$APP_BACKUP_SAFETY_ENABLED" = true ] &&
    [ "$APP_BACKUP_SAFETY_ENROLLED" = true ] || return 1
  local current_mount current_status current_observed current_verified current_enrollment
  beta_backup_runtime_require_mount "$APP_BACKUP_SAFETY_STATUS_PATH"
  local watermark=$APP_BACKUP_SAFETY_WATERMARK_PATH
  [ -f "$watermark" ] && [ ! -L "$watermark" ] || return 1
  beta_backup_runtime_validate_watermark "$APP_BACKUP_SAFETY_STATUS_PATH" "$watermark" ||
    return 1
  local status_generation status_observed watermark_generation watermark_observed watermark_digest
  status_generation=$(jq -er '.authorityGeneration' "$APP_BACKUP_SAFETY_STATUS_PATH")
  status_observed=$(jq -er '.observedAt' "$APP_BACKUP_SAFETY_STATUS_PATH")
  watermark_generation=$(jq -er '.authorityGeneration' "$watermark")
  watermark_observed=$(jq -er '.observedAt' "$watermark")
  watermark_digest=$(jq -er '.statusDigest' "$watermark")
  [ "$status_generation" = "$watermark_generation" ] &&
    [ "$status_observed" = "$watermark_observed" ] &&
    [ "$watermark_digest" = "$(sha256sum "$APP_BACKUP_SAFETY_STATUS_PATH" | awk '{print $1}')" ] ||
    return 1
  current_mount=$(stat -c '%d:%i:%a:%u:%g' "${APP_BACKUP_SAFETY_STATUS_PATH%/*}" |
    sha256sum | awk '{print $1}')
  current_status=$(sha256sum "$APP_BACKUP_SAFETY_STATUS_PATH" | awk '{print $1}')
  current_observed=$(jq -er '.observedAt' "$APP_BACKUP_SAFETY_STATUS_PATH")
  current_verified=$(jq -er '.verified.capturedAt' "$APP_BACKUP_SAFETY_STATUS_PATH")
  current_enrollment=$(printf '%s\0%s\0%s\0%s\0%s' \
    "$APP_BACKUP_SAFETY_ENABLED" "$APP_BACKUP_SAFETY_ENROLLED" \
    "$APP_BACKUP_SAFETY_ENVIRONMENT" "$APP_BACKUP_SAFETY_STATUS_PATH" \
    "$APP_BACKUP_SAFETY_WATERMARK_PATH" |
    sha256sum | awk '{print $1}')
  [ "$enrollment" = "$current_enrollment" ] &&
    [ "$mount" = "$current_mount" ] &&
    [ "$status_digest" = "$current_status" ] &&
    [ "$observed" = "$current_observed" ] &&
    [ "$verified" = "$current_verified" ]
}
