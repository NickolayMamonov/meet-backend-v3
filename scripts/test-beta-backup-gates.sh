#!/usr/bin/env bash
set -euo pipefail

fail() { echo "test-beta-backup-gates.sh: $1" >&2; exit 1; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
digest=$(printf authority | sha256sum | awk '{print $1}')
now=1790001000
mkdir "$tmp/control"
chmod 750 "$tmp/control" 2>/dev/null || true
cat >"$tmp/control/status.json" <<EOF
{"authorityDigest":"$digest","authorityGeneration":1,"capture":{"capturedAt":1790000000,"id":"point-1","state":"VALID"},"environment":"closed-beta","observedAt":1790001000,"schema":"meet-backend/beta-backup-status/v1","verified":{"capturedAt":1790000000,"id":"point-1","state":"VALID"}}
EOF
status_digest=$(sha256sum "$tmp/control/status.json" | awk '{print $1}')
chmod 640 "$tmp/control/status.json"
mount_identity=$(stat -c '%d:%i:%a:%u:%g' "$tmp/control")
mount_uid=$(stat -c '%u' "$tmp/control")
mount_gid=$(stat -c '%g' "$tmp/control")
jq -cnS --arg digest "$status_digest" \
  '{schema:"meet-backend/beta-backup-watermark/v1",authorityGeneration:1,
    observedAt:1790001000,statusDigest:$digest}' >"$tmp/control/watermark.json"
chmod 640 "$tmp/control/watermark.json"
cat >"$tmp/.env.production" <<EOF
APP_BACKUP_SAFETY_ENABLED=true
APP_BACKUP_SAFETY_ENROLLED=true
APP_BACKUP_SAFETY_ENVIRONMENT=closed-beta
APP_BACKUP_SAFETY_STATUS_PATH=$tmp/control/status.json
APP_BACKUP_SAFETY_WATERMARK_PATH=$tmp/control/watermark.json
APP_BACKUP_SAFETY_SNAPSHOT_MAX_AGE_SECONDS=1800
APP_BACKUP_SAFETY_VERIFIED_MAX_AGE_SECONDS=1209600
APP_BACKUP_SAFETY_CONTROL_ROOT_UID=$mount_uid
APP_BACKUP_SAFETY_CONTROL_ROOT_GID=$mount_gid
APP_BACKUP_SAFETY_MOUNT_IDENTITY=$mount_identity
EOF
if APP_BACKUP_SAFETY_NOW_EPOCH="$now" bash -c \
  "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' smtp-apply '$tmp/.env.production'" \
  >/dev/null 2>&1; then
  :
else
  fail "healthy documented APP enrollment was denied"
fi
if APP_BACKUP_SAFETY_NOW_EPOCH="$now" bash -c \
  "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' smtp-apply '$tmp/missing.env'" \
  >/dev/null 2>&1; then
  fail "missing enrollment file admitted SMTP mutation"
fi
sed 's/1790001000/1789999000/g' "$tmp/control/status.json" >"$tmp/control/stale.json"
sed "s#status.json#stale.json#" "$tmp/.env.production" >"$tmp/stale.env.production"
if APP_BACKUP_SAFETY_NOW_EPOCH="$now" bash -c \
  "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' production-update '$tmp/stale.env.production'" \
  >/dev/null 2>&1; then
  fail "stale snapshot admitted standalone update"
fi
sed 's/APP_BACKUP_SAFETY_ENABLED=true/APP_BACKUP_SAFETY_ENABLED=false/' \
  "$tmp/.env.production" >"$tmp/disabled-enrolled.env.production"
if APP_BACKUP_SAFETY_NOW_EPOCH="$now" bash -c \
  "source '$root/scripts/beta-backup-runtime-gate.sh'; beta_backup_runtime_require_operation '' smtp-apply '$tmp/disabled-enrolled.env.production'" \
  >/dev/null 2>&1; then
  fail "enrolled but disabled configuration was admitted"
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
