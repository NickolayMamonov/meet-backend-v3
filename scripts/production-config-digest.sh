#!/usr/bin/env bash
set -euo pipefail

FILE=${1:-.env.production}
SCRIPTS_DIR=${PRODUCTION_SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
test -f "$FILE" || {
  echo "$FILE does not exist" >&2
  exit 1
}
# The target environment file is the enrollment source of truth. This check
# remains here because the digest helper is also called directly.
# shellcheck source=beta-backup-runtime-gate.sh
source "$SCRIPTS_DIR/beta-backup-runtime-gate.sh"
beta_backup_runtime_require_operation "" production-config-mutation "$FILE"

sed -E '/^BACKEND_(IMAGE|VERSION|REVISION)=/d' "$FILE" | sha256sum | awk '{print $1}'
