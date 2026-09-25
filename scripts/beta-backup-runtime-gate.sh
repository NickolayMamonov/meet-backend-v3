#!/usr/bin/env bash
set -euo pipefail

beta_backup_runtime_require_operation() {
  local image=${1:-} operation=${2:-operation}
  [ "${BETA_BACKUP_SAFETY_ENABLED:-false}" = true ] || return 0
  [ "${BETA_BACKUP_SAFETY_ENROLLED:-false}" = true ] ||
    { echo "BACKUP_SAFETY_BLOCKED: enrollment is unavailable for $operation" >&2; return 1; }
  local status_path=${BETA_BACKUP_STATUS_PATH:-/var/lib/meet-production/beta-backup-control/status.json}
  local environment=${BETA_BACKUP_ENVIRONMENT:-closed-beta}
  local now=${BETA_BACKUP_NOW_EPOCH:-$(date -u +%s)}
  BETA_BACKUP_STATUS_PATH="$status_path" \
    BETA_BACKUP_ENVIRONMENT="$environment" \
    BETA_BACKUP_NOW_EPOCH="$now" \
    "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/check-beta-backup-safety.sh" \
    "$operation" >/dev/null
  [ -d "$(dirname -- "$status_path")" ] && [ ! -L "$(dirname -- "$status_path")" ] ||
    { echo "BACKUP_SAFETY_BLOCKED: control mount is unavailable" >&2; return 1; }
  if [ -n "$image" ]; then
    command -v docker >/dev/null 2>&1 ||
      { echo "BACKUP_SAFETY_BLOCKED: image capability cannot be inspected" >&2; return 1; }
    [ "$(docker image inspect "$image" --format '{{ index .Config.Labels "org.opencontainers.image.backup-safety-gate" }}')" = v1 ] ||
      { echo "BACKUP_SAFETY_BLOCKED: image lacks backup gate capability" >&2; return 1; }
  fi
}

beta_backup_runtime_admission_fingerprints() {
  local status_path=${BETA_BACKUP_STATUS_PATH:-/var/lib/meet-production/beta-backup-control/status.json}
  local control_root
  control_root=$(dirname -- "$status_path")
  local status_digest mount_digest enrollment_digest verified_at
  status_digest=$(sha256sum "$status_path" | awk '{print $1}')
  mount_digest=$(stat -c '%d:%i:%a:%u:%g' "$control_root" | sha256sum | awk '{print $1}')
  enrollment_digest=$(printf '%s' "${BETA_BACKUP_ENVIRONMENT:-closed-beta}:enrolled" |
    sha256sum | awk '{print $1}')
  verified_at=$(jq -er '.verified.capturedAt' "$status_path")
  printf '%s %s %s %s %s\n' \
    "$enrollment_digest" "$mount_digest" "$status_digest" \
    "${BETA_BACKUP_NOW_EPOCH:-$(date -u +%s)}" "$verified_at"
}
