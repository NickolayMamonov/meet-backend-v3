#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 validate-point|inventory|capability|provider-put|provider-get|provider-delete|provider-list|publish|promote|prune|reconcile ..." >&2
  exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
operation=${1:-}
shift || true

local_root() {
  local root=${BETA_BACKUP_STORAGE_ROOT:-}
  [ -n "$root" ] || { echo "BACKUP_STORAGE_BLOCKED:storage_root_required" >&2; return 1; }
  beta_storage_require_local_root "$root" >/dev/null
  printf '%s\n' "$root"
}

case "$operation" in
  validate-point)
    [ "$#" -eq 2 ] && [ "$1" = --file ] || usage
    beta_storage_validate_point "$2" || { echo "BACKUP_STORAGE_BLOCKED:point_invalid" >&2; exit 1; }
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
    if [ -n "${BETA_BACKUP_STORAGE_ROOT:-}" ]; then
      root=$(local_root)
      [ -d "$root/points" ] && [ -d "$root/receipts" ] && [ -d "$root/control" ] ||
        { echo "BACKUP_STORAGE_BLOCKED:storage_layout_invalid" >&2; exit 1; }
      printf 'storage_capability=local-versioned-writer conditional_lock=true manifest_last=true\n'
    else
      beta_storage_aws head-bucket --bucket "$BETA_BACKUP_BUCKET" >/dev/null
      versioning=$(beta_storage_aws get-bucket-versioning --bucket "$BETA_BACKUP_BUCKET" |
        jq -er '.Status // empty') || {
          echo "BACKUP_STORAGE_BLOCKED:versioning_unavailable" >&2
          exit 1
        }
      [ "$versioning" = Enabled ] || {
        echo "BACKUP_STORAGE_BLOCKED:versioning_disabled" >&2
        exit 1
      }
      printf 'storage_capability=reachable bucket_versioning=Enabled\n'
    fi
    ;;
  provider-put)
    key='' source='' root=${BETA_BACKUP_STORAGE_ROOT:-}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
        --file) [ "$#" -ge 2 ] || usage; source=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$key" ] && [ -n "$source" ] || usage
    result=$(beta_storage_provider_put "$root" "$key" "$source")
    printf 'storage_provider_put=%s\n' "$result"
    ;;
  provider-get)
    key='' version='' destination='' expected_sha='' root=${BETA_BACKUP_STORAGE_ROOT:-}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
        --version) [ "$#" -ge 2 ] || usage; version=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] || usage; destination=$2; shift 2 ;;
        --sha256) [ "$#" -ge 2 ] || usage; expected_sha=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$key" ] && [ -n "$version" ] && [ -n "$destination" ] || usage
    [[ -z "$expected_sha" || "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || usage
    beta_storage_provider_get "$root" "$key" "$version" "$destination" "$expected_sha"
    printf 'storage_provider_get=verified key=%s version=%s\n' "$key" "$version"
    ;;
  provider-delete)
    key='' version='' root=${BETA_BACKUP_STORAGE_ROOT:-}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
        --version) [ "$#" -ge 2 ] || usage; version=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$key" ] && [ -n "$version" ] || usage
    beta_storage_provider_delete "$root" "$key" "$version"
    printf 'storage_provider_delete=committed key=%s version=%s\n' "$key" "$version"
    ;;
  provider-list)
    root=${BETA_BACKUP_STORAGE_ROOT:-}
    if [ "$#" -eq 2 ] && [ "$1" = --storage-root ]; then root=$2; else [ "$#" -eq 0 ] || usage; fi
    if [ -n "$root" ]; then
      beta_storage_local_provider_list "$root" | jq -s .
    else
      beta_storage_aws_list_versions | jq -s '
        map(.Versions[]? | {key:.Key,versionId:.VersionId,bytes:(.Size // 0),
          sha256:(.Metadata.sha256 // null)})'
    fi
    ;;
  publish)
    source_dir='' root='' point_id='' slot='' captured_at='' owner=${BETA_BACKUP_OWNER:-operator}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --source) [ "$#" -ge 2 ] || usage; source_dir=$2; shift 2 ;;
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --point-id) [ "$#" -ge 2 ] || usage; point_id=$2; shift 2 ;;
        --slot) [ "$#" -ge 2 ] || usage; slot=$2; shift 2 ;;
        --captured-at) [ "$#" -ge 2 ] || usage; captured_at=$2; shift 2 ;;
        --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -n "$root" ]; then
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_publish_local "$source_dir" "$root" "$point_id" "$slot" "$captured_at" "$owner"
    else
      beta_storage_publish_remote "$source_dir" "$point_id" "$slot" "$captured_at" "$owner"
    fi
    ;;
  promote)
    receipt='' receipt_key='' root='' owner=${BETA_BACKUP_OWNER:-operator} probe_binding=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
        --receipt-key) [ "$#" -ge 2 ] || usage; receipt_key=$2; shift 2 ;;
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
        --probe-binding) [ "$#" -ge 2 ] || usage; probe_binding=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -n "$root" ]; then
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_promote_local "$receipt" "$root" "$owner"
    else
      [ -n "$receipt" ] || [ -n "$receipt_key" ] || usage
      beta_storage_promote_remote "$receipt" "$receipt_key" "$owner" "$probe_binding"
    fi
    ;;
  prune)
    root='' now='' owner=${BETA_BACKUP_OWNER:-operator}
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
        --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$now" ] || usage
    # Prune is destructive and always requires a complete A3 admission.
    # shellcheck source=beta-backup-runtime-gate.sh
    source "$script_dir/beta-backup-runtime-gate.sh"
    beta_backup_runtime_require_operation "" storage-prune \
      "${APP_BACKUP_SAFETY_ENV_FILE:-}"
    if [ -n "$root" ]; then
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_prune_local "$root" "$now" "$owner"
    else
      beta_storage_prune_remote "$now" "$owner"
    fi
    ;;
  reconcile)
    root=''
    if [ "$#" -eq 2 ] && [ "$1" = --storage-root ]; then
      root=$2
    elif [ "$#" -ne 0 ]; then
      usage
    fi
    if [ -n "$root" ]; then
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_reconcile_local "$root"
    else
      beta_storage_reconcile_remote
    fi
    ;;
  *) usage ;;
esac
