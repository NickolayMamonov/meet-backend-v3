#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 validate-point|inventory --file PATH [--budget BYTES] | capability" >&2
  exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
operation=${1:-}
shift || true
case "$operation" in
  validate-point)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || usage
    beta_storage_validate_point "$2"
    printf 'storage_point_valid=true\n'
    ;;
  inventory)
    [ "$#" -ge 2 ] && [ "$1" = --file ] || usage
    file=$2
    shift 2
    budget=${BETA_BACKUP_BYTE_BUDGET:-0}
    if [ "$#" -eq 2 ] && [ "$1" = --budget ]; then budget=$2; else [ "$#" -eq 0 ] || usage; fi
    beta_storage_inventory_total "$file" "$budget"
    ;;
  capability)
    beta_storage_require_config
    beta_storage_aws head-bucket --bucket "$BETA_BACKUP_BUCKET" >/dev/null
    printf 'storage_capability=reachable bucket_versioning=operator-proof-required\n'
    ;;
  *) usage ;;
esac
