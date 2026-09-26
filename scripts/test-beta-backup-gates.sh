#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-gates.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
digest=$(printf authority | sha256sum | awk '{print $1}')
now=1790001000
cat >"$tmp/status.json" <<EOF
{"authorityDigest":"$digest","authorityGeneration":1,"capture":{"capturedAt":1790000000,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":1790001000,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":1790000000,"id":"point-1","state":"VALID"}}
EOF
BETA_BACKUP_STATUS_PATH="$tmp/status.json" BETA_BACKUP_ENVIRONMENT=closed-beta \
  BETA_BACKUP_NOW_EPOCH="$now" BETA_BACKUP_SAFETY_ENABLED=true \
  BETA_BACKUP_SAFETY_ENROLLED=true \
  "$root/scripts/beta-backup-runtime-gate.sh" >/dev/null 2>&1 || true
if BETA_BACKUP_STATUS_PATH="$tmp/missing.json" BETA_BACKUP_ENVIRONMENT=closed-beta \
  BETA_BACKUP_NOW_EPOCH="$now" BETA_BACKUP_SAFETY_ENABLED=true \
  BETA_BACKUP_SAFETY_ENROLLED=true \
  bash -c "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' smtp-apply" \
  >/dev/null 2>&1; then
  fail "missing snapshot admitted SMTP mutation"
fi
sed 's/"capturedAt":1790000000/"capturedAt":1788791400/g' "$tmp/status.json" >"$tmp/stale.json"
if BETA_BACKUP_STATUS_PATH="$tmp/stale.json" BETA_BACKUP_ENVIRONMENT=closed-beta \
  BETA_BACKUP_NOW_EPOCH="$now" BETA_BACKUP_SAFETY_ENABLED=true \
  BETA_BACKUP_SAFETY_ENROLLED=true \
  bash -c "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' production-update" \
  >/dev/null 2>&1; then
  fail "stale verified state admitted standalone update"
fi
grep -Fq 'beta_backup_runtime_require_operation' "$root/scripts/configure-test-vps-yandex-smtp.sh" ||
  fail "SMTP tool lacks independent safety admission"
grep -Fq 'production-config-digest.sh' "$root/scripts/update-production-release.sh" ||
  fail "standalone update lacks the pre-mutation digest boundary"
grep -Fq 'beta_backup_runtime_require_operation' "$root/scripts/production-config-digest.sh" ||
  fail "standalone update digest boundary lacks safety admission"
grep -Fq 'beta_backup_runtime_require_operation' "$root/scripts/rollback-production-release.sh" ||
  fail "standalone rollback lacks independent safety admission"
printf 'test-beta-backup-gates.sh: passed\n'
