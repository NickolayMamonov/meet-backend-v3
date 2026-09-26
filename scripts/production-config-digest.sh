#!/usr/bin/env bash
set -euo pipefail

FILE=${1:-.env.production}
SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
if [ "${BETA_BACKUP_SAFETY_ENABLED:-false}" = true ]; then
  # shellcheck source=beta-backup-runtime-gate.sh
  source "$SCRIPTS_DIR/beta-backup-runtime-gate.sh"
  beta_backup_runtime_require_operation "" production-config-mutation
fi
test -f "$FILE" || {
  echo "$FILE does not exist" >&2
  exit 1
}

sed -E '/^BACKEND_(IMAGE|VERSION|REVISION)=/d' "$FILE" | sha256sum | awk '{print $1}'
