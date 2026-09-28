#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 validate-point|inventory|capability|provider-put|provider-get|provider-delete|provider-list|publish|promote|prune|reconcile ..." >&2
  exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=beta-backup-storage.sh
source "$script_dir/beta-backup-storage.sh"
require_fixture_root() {
  local root=$1
  [ -z "$root" ] || [ "${BETA_BACKUP_TEST_FIXTURE:-false}" = true ] || {
    echo 'BACKUP_STORAGE_BLOCKED:local_authority_fixture_only' >&2
    exit 1
  }
}
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
      require_fixture_root "$root"
      [ -d "$root/points" ] && [ -d "$root/receipts" ] && [ -d "$root/control" ] ||
        { echo "BACKUP_STORAGE_BLOCKED:storage_layout_invalid" >&2; exit 1; }
      printf 'storage_capability=local-versioned-writer conditional_lock=true manifest_last=true\n'
    else
      beta_storage_aws_read head-bucket --bucket "$BETA_BACKUP_BUCKET" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:bucket_unavailable" >&2
        exit 1
      }
      versioning=$(beta_storage_aws_read get-bucket-versioning --bucket "$BETA_BACKUP_BUCKET" |
        jq -er '.Status // empty') || {
          echo "BACKUP_STORAGE_BLOCKED:versioning_unavailable" >&2
          exit 1
        }
      [ "$versioning" = Enabled ] || {
        echo "BACKUP_STORAGE_BLOCKED:versioning_disabled" >&2
        exit 1
      }
      jq -e 'type=="object" and
        ((keys - ["MFADelete","Status"])|length==0) and
        .Status=="Enabled" and
        ((.MFADelete // "Disabled")=="Enabled" or (.MFADelete // "Disabled")=="Disabled")' \
        <<<"$(beta_storage_aws_read get-bucket-versioning \
          --bucket "$BETA_BACKUP_BUCKET")" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:versioning_response_invalid" >&2
        exit 1
      }
      lifecycle='{"Rules":[]}'
      if lifecycle=$(beta_storage_aws_read get-bucket-lifecycle-configuration \
        --bucket "$BETA_BACKUP_BUCKET"); then
        :
      else
        lifecycle_status=$?
        [ "$lifecycle_status" -eq 3 ] || {
          echo "BACKUP_STORAGE_BLOCKED:lifecycle_unavailable" >&2
          exit 1
        }
      fi
      jq -e 'type=="object" and (.Rules|type=="array") and
        ((keys - ["Rules","ResponseMetadata"])|length==0) and
        all(.Rules[]?;
          (.Status=="Disabled") or
          ((.Expiration|not) and (.NoncurrentVersionExpiration|not) and
            (.Transitions|not) and (.NoncurrentVersionTransitions|not)))' \
        <<<"$lifecycle" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:lifecycle_policy_unsafe" >&2
        exit 1
      }
      probe_key="control/capability-probe-$(date -u +%s)-$$"
      probe=$(mktemp)
      probe_update=$(mktemp)
      probe_version_one=''
      probe_version_two=''
      capability_cleanup() {
        local status=$?
        trap - EXIT HUP INT TERM
        for probe_version in "$probe_version_two" "$probe_version_one"; do
          [ -n "$probe_version" ] || continue
          beta_storage_provider_delete '' "$probe_key" "$probe_version" || status=1
          if beta_storage_aws_read head-object --bucket "$BETA_BACKUP_BUCKET" \
            --key "$probe_key" --version-id "$probe_version" >/dev/null; then
            status=1
          else
            [ "$?" -eq 3 ] || status=1
          fi
        done
        rm -f -- "$probe" "$probe_update" "$probe_update.copy" || status=1
        return "$status"
      }
      trap capability_cleanup EXIT HUP INT TERM
      printf 'capability-probe-v1\n' >"$probe"
      first=$(beta_storage_provider_put_conditional '' "$probe_key" "$probe" '' true) || {
        echo "BACKUP_STORAGE_BLOCKED:conditional_create_unavailable" >&2
        exit 1
      }
      probe_version_one=$(jq -er '.versionId' <<<"$first") || {
        echo "BACKUP_STORAGE_BLOCKED:conditional_create_invalid" >&2
        exit 1
      }
      first_sha=$(jq -er '.sha256' <<<"$first")
      beta_storage_provider_get '' "$probe_key" "$probe_version_one" \
        "$probe_update.copy" "$first_sha" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:exact_version_get_unavailable" >&2
        exit 1
      }
      if beta_storage_aws put-object --bucket "$BETA_BACKUP_BUCKET" \
        --key "$probe_key" --body "$probe" --if-none-match '*' \
        --metadata "sha256=$first_sha" >/dev/null; then
        echo "BACKUP_STORAGE_BLOCKED:conditional_create_conflict_not_enforced" >&2
        exit 1
      fi
      [[ "${BETA_STORAGE_LAST_ERROR:-}" =~ (PreconditionFailed|ConditionalRequestConflict|412) ]] || {
        echo "BACKUP_STORAGE_BLOCKED:conditional_create_conflict_unproven" >&2
        exit 1
      }
      printf 'capability-probe-v2\n' >"$probe_update"
      first_meta=$(mktemp)
      beta_storage_remote_head "$probe_key" "$first_meta" || {
        rm -f -- "$first_meta"
        echo "BACKUP_STORAGE_BLOCKED:conditional_head_unavailable" >&2
        exit 1
      }
      first_etag=$(jq -er '.ETag' "$first_meta")
      rm -f -- "$first_meta"
      second=$(beta_storage_provider_put_conditional '' "$probe_key" "$probe_update" \
        "$first_etag" false) || {
        echo "BACKUP_STORAGE_BLOCKED:conditional_update_unavailable" >&2
        exit 1
      }
      probe_version_two=$(jq -er '.versionId' <<<"$second") || {
        echo "BACKUP_STORAGE_BLOCKED:conditional_update_invalid" >&2
        exit 1
      }
      second_sha=$(jq -er '.sha256' <<<"$second")
      beta_storage_provider_get '' "$probe_key" "$probe_version_two" \
        "$probe_update.copy" "$second_sha" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:updated_version_get_unavailable" >&2
        exit 1
      }
      versions=$(beta_storage_aws_list_versions | jq -s '.')
      jq -e --arg key "$probe_key" --arg one "$probe_version_one" \
        --arg two "$probe_version_two" '
        ([.[].Versions[]? | select(.Key==$key and
          (.VersionId==$one or .VersionId==$two))] | map(.VersionId) | unique | sort)
        == ([$one,$two] | sort)
      ' <<<"$versions" >/dev/null || {
        echo "BACKUP_STORAGE_BLOCKED:version_list_consistency_failed" >&2
        exit 1
      }
      beta_storage_provider_delete '' "$probe_key" "$probe_version_two" ||
        { echo "BACKUP_STORAGE_BLOCKED:exact_version_delete_unavailable" >&2; exit 1; }
      beta_storage_provider_delete '' "$probe_key" "$probe_version_one" ||
        { echo "BACKUP_STORAGE_BLOCKED:exact_version_delete_unavailable" >&2; exit 1; }
      probe_version_two=''
      probe_version_one=''
      rm -f -- "$probe_update.copy"
      trap - EXIT HUP INT TERM
      capability_cleanup
      printf 'storage_capability=reachable bucket_versioning=Enabled lifecycle_pins=protected conditional_create=true conditional_update=true exact_version_get=true exact_version_delete=true list_consistent=true\n'
    fi
    ;;
  provider-put)
    key='' source='' root=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
        --file) [ "$#" -ge 2 ] || usage; source=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$key" ] && [ -n "$source" ] || usage
    [ -n "$root" ] || {
      echo 'BACKUP_STORAGE_BLOCKED:generic_remote_write_forbidden' >&2
      exit 1
    }
    require_fixture_root "$root"
    beta_storage_require_local_root "$root" >/dev/null
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
    require_fixture_root "$root"
    beta_storage_provider_get "$root" "$key" "$version" "$destination" "$expected_sha"
    printf 'storage_provider_get=verified key=%s version=%s\n' "$key" "$version"
    ;;
  provider-delete)
    key='' version='' root=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --key) [ "$#" -ge 2 ] || usage; key=$2; shift 2 ;;
        --version) [ "$#" -ge 2 ] || usage; version=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$key" ] && [ -n "$version" ] || usage
    [ -n "$root" ] || {
      echo 'BACKUP_STORAGE_BLOCKED:generic_remote_delete_forbidden' >&2
      exit 1
    }
    require_fixture_root "$root"
    beta_storage_require_local_root "$root" >/dev/null
    beta_storage_provider_delete "$root" "$key" "$version"
    printf 'storage_provider_delete=committed key=%s version=%s\n' "$key" "$version"
    ;;
  provider-list)
    root=${BETA_BACKUP_STORAGE_ROOT:-}
    if [ "$#" -eq 2 ] && [ "$1" = --storage-root ]; then root=$2; else [ "$#" -eq 0 ] || usage; fi
    if [ -n "$root" ]; then
      require_fixture_root "$root"
      beta_storage_require_local_root "$root" >/dev/null
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
      require_fixture_root "$root"
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_publish_local "$source_dir" "$root" "$point_id" "$slot" "$captured_at" "$owner"
    else
      beta_storage_publish_remote "$source_dir" "$point_id" "$slot" "$captured_at" "$owner"
    fi
    ;;
  promote)
    receipt='' receipt_key='' root='' owner=${BETA_BACKUP_OWNER:-operator}
    probe_binding='' provenance='' run_id='' reviewer_id=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --receipt) [ "$#" -ge 2 ] || usage; receipt=$2; shift 2 ;;
        --receipt-key) [ "$#" -ge 2 ] || usage; receipt_key=$2; shift 2 ;;
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
        --probe-binding) [ "$#" -ge 2 ] || usage; probe_binding=$2; shift 2 ;;
        --provenance) [ "$#" -ge 2 ] || usage; provenance=$2; shift 2 ;;
        --run-id) [ "$#" -ge 2 ] || usage; run_id=$2; shift 2 ;;
        --reviewer-id) [ "$#" -ge 2 ] || usage; reviewer_id=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    if [ -n "$root" ]; then
      require_fixture_root "$root"
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_promote_local "$receipt" "$root" "$owner"
    else
      [ -n "$receipt" ] || {
        echo 'BACKUP_STORAGE_BLOCKED:promotion_receipt_required' >&2
        exit 1
      }
      [[ "$run_id" =~ ^[0-9]+$ && "$reviewer_id" =~ ^[0-9]+$ ]] || {
        echo 'BACKUP_STORAGE_BLOCKED:promotion_api_identity_required' >&2
        exit 1
      }
      [ -z "$provenance" ] || {
        echo 'BACKUP_STORAGE_BLOCKED:caller_provenance_forbidden' >&2
        exit 1
      }
      promotion_adapter="$script_dir/query-beta-recurring-promotion.sh"
      provenance=$(mktemp)
      cleanup_promotion_adapter() { rm -f -- "$provenance"; }
      trap cleanup_promotion_adapter EXIT HUP INT TERM
      "$promotion_adapter" --run-id "$run_id" --reviewer-id "$reviewer_id" \
        --receipt "$receipt" --probe-binding "$probe_binding" \
        --output "$provenance"
      beta_storage_promote_remote "$receipt" "$receipt_key" "$owner" \
        "$probe_binding" "$provenance"
    fi
    ;;
  prune)
    root='' now='' owner=${BETA_BACKUP_OWNER:-operator}
    safety_status='' safety_watermark='' safety_environment=closed-beta
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --storage-root) [ "$#" -ge 2 ] || usage; root=$2; shift 2 ;;
        --now) [ "$#" -ge 2 ] || usage; now=$2; shift 2 ;;
        --owner) [ "$#" -ge 2 ] || usage; owner=$2; shift 2 ;;
        --safety-status) [ "$#" -ge 2 ] || usage; safety_status=$2; shift 2 ;;
        --safety-watermark) [ "$#" -ge 2 ] || usage; safety_watermark=$2; shift 2 ;;
        --safety-environment) [ "$#" -ge 2 ] || usage; safety_environment=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$now" ] || usage
    if [ -n "$root" ]; then
      require_fixture_root "$root"
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_prune_local "$root" "$now" "$owner"
    else
      [ -n "$safety_status" ] && [ -n "$safety_watermark" ] || {
        echo 'BACKUP_SAFETY_BLOCKED:safety_snapshot_required' >&2
        exit 1
      }
      beta_storage_prune_remote "$now" "$owner" "$safety_status" \
        "$safety_watermark" "$safety_environment"
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
      require_fixture_root "$root"
      beta_storage_require_local_root "$root" >/dev/null
      beta_storage_reconcile_local "$root"
    else
      beta_storage_reconcile_remote
    fi
    ;;
  *) usage ;;
esac
