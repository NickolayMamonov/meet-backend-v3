#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-policy.sh
source "$script_dir/beta-backup-policy.sh"

status_path=${BETA_BACKUP_STATUS_PATH:-/var/lib/meet-production/beta-backup-control/status.json}
environment=${BETA_BACKUP_ENVIRONMENT:-closed-beta}
operation=${1:-operation}
now=${BETA_BACKUP_NOW_EPOCH:-$(date -u +%s)}

case "$operation" in
  capture|monitor)
    beta_backup_validate_status "$status_path" "$now" "$environment"
    ;;
  *)
    beta_backup_require_admission "$status_path" "$now" "$environment"
    ;;
esac

printf 'backup_safety_admitted operation=%s\n' "$operation"
