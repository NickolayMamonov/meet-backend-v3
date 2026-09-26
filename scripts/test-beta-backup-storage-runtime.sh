#!/usr/bin/env bash
set -euo pipefail

readonly DEADLINE_SECONDS=1800

blocked() {
  printf 'environment-blocked:provider-runtime-approval-required:%s\n' "$1" >&2
  exit 77
}

command -v timeout >/dev/null 2>&1 || blocked timeout_unavailable
[ "${BETA_BACKUP_RUNTIME_APPROVED:-}" = true ] ||
  blocked explicit_disposable_provider_approval_missing
[ "${BETA_BACKUP_RUNTIME_ALLOW_MUTATION:-}" = true ] ||
  blocked mutation_authorization_missing
[ "${BETA_BACKUP_RUNTIME_DISPOSABLE_BUCKET:-}" = true ] ||
  blocked disposable_bucket_confirmation_missing

: "${BETA_BACKUP_BUCKET:?BETA_BACKUP_BUCKET is required}"
: "${BETA_BACKUP_REGION:?BETA_BACKUP_REGION is required}"
: "${BETA_BACKUP_ENDPOINT:?BETA_BACKUP_ENDPOINT is required}"
: "${BETA_BACKUP_BYTE_BUDGET:?BETA_BACKUP_BYTE_BUDGET is required}"
[[ "$BETA_BACKUP_BUCKET" != *production* && "$BETA_BACKUP_BUCKET" != *prod* ]] ||
  blocked production_bucket_refused

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  rm -rf -- "$tmp" || status=1
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

point="$tmp/point"
mkdir -m 700 "$point"
printf 'age-encryption.org/v1\nruntime-database\n' >"$point/postgres.dump.age"
printf 'age-encryption.org/v1\nruntime-media\n' >"$point/uploads.tar.gz.age"
captured_at=$(date -u +%s)
slot=$(date -u +%y%m%d%H%M)
source_revision=${BETA_BACKUP_RUNTIME_SOURCE_REVISION:-0000000000000000000000000000000000000000}
runtime_revision=${BETA_BACKUP_RUNTIME_REVISION:-0000000000000000000000000000000000000000}
digest=$(printf 'runtime-contract\n' | sha256sum | awk '{print $1}')
command_digest=$(sha256sum "$script_dir/run-beta-recurring-capture-command.sh" | awk '{print $1}')
evidence_digest=$(printf 'runtime-evidence\n' | sha256sum | awk '{print $1}')
jq -cnS --argjson captured "$captured_at" --arg slot "$slot" \
  --arg source "$source_revision" --arg runtime "$runtime_revision" \
  --arg command "$command_digest" --arg evidence "$evidence_digest" \
  --arg contract "$digest" --arg proof "$digest" \
  '{schema:"meet-backend/beta-recovery-point/v2",pointId:("runtime-"+$slot),
    slotId:$slot,capture:{capturedAt:$captured,sourceRevision:$source},
    runtimeRevision:$runtime,captureCommandDigest:$command,
    captureEvidenceDigest:$evidence,contractDigest:$contract,proofDigest:$proof}' \
  >"$point/recovery-point.json"

timeout --foreground --signal=TERM "${DEADLINE_SECONDS}s" \
  "$script_dir/run-beta-backup-storage.sh" capability >/dev/null
timeout --foreground --signal=TERM "${DEADLINE_SECONDS}s" \
  "$script_dir/run-beta-backup-storage.sh" reconcile >/dev/null
timeout --foreground --signal=TERM "${DEADLINE_SECONDS}s" \
  "$script_dir/run-beta-backup-storage.sh" publish --source "$point" \
  --point-id "runtime-$slot" --slot "$slot" --captured-at "$captured_at" \
  --owner runtime >/dev/null
timeout --foreground --signal=TERM "${DEADLINE_SECONDS}s" \
  "$script_dir/run-beta-backup-storage.sh" reconcile >/dev/null
printf 'provider_runtime_status=verified disposable_bucket=true point_id=runtime-%s\n' "$slot"
