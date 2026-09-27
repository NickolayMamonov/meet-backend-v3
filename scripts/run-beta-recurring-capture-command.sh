#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --output-dir DIR --slot SLOT --captured-at EPOCH" >&2
  exit 2
}

output='' slot='' captured_at=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) [ "$#" -ge 2 ] || usage; output=$2; shift 2 ;;
    --slot) [ "$#" -ge 2 ] || usage; slot=$2; shift 2 ;;
    --captured-at) [ "$#" -ge 2 ] || usage; captured_at=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$output" = /* && "$output" != *..* ]] || usage
[[ "$slot" =~ ^[0-9]{10}$ && "$captured_at" =~ ^[0-9]+$ ]] || usage
: "${BETA_RECURRING_PUBLIC_URL:?BETA_RECURRING_PUBLIC_URL is required}"
: "${BETA_RECURRING_AGE_RECIPIENT:?BETA_RECURRING_AGE_RECIPIENT is required}"
: "${BETA_RECURRING_AGE_BINARY:?BETA_RECURRING_AGE_BINARY is required}"
: "${BETA_RECURRING_AGE_SHA256:?BETA_RECURRING_AGE_SHA256 is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${BETA_RECURRING_HOST:?BETA_RECURRING_HOST is required}"
: "${BETA_RECURRING_PORT:?BETA_RECURRING_PORT is required}"
: "${BETA_RECURRING_SSH_USER:?BETA_RECURRING_SSH_USER is required}"
: "${BETA_RECURRING_HOST_FINGERPRINT:?BETA_RECURRING_HOST_FINGERPRINT is required}"
: "${BETA_RECURRING_RELEASE_ROOT:?BETA_RECURRING_RELEASE_ROOT is required}"
: "${BETA_RECURRING_SSH_PRIVATE_KEY:?BETA_RECURRING_SSH_PRIVATE_KEY is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
install -d -m 700 "$output"
AGE_RECIPIENT="$BETA_RECURRING_AGE_RECIPIENT" \
  PUBLIC_URL="$BETA_RECURRING_PUBLIC_URL" \
  HOST="$BETA_RECURRING_HOST" \
  PORT="$BETA_RECURRING_PORT" \
  SSH_USER="$BETA_RECURRING_SSH_USER" \
  HOST_FINGERPRINT="$BETA_RECURRING_HOST_FINGERPRINT" \
  PATH_ON_HOST="$BETA_RECURRING_RELEASE_ROOT" \
  SSH_PRIVATE_KEY="$BETA_RECURRING_SSH_PRIVATE_KEY" \
  RECOVERY_ID="recurring-$slot" \
  SOURCE_SHA="$GITHUB_SHA" \
  RECOVERY_WORKFLOW=".github/workflows/beta-recurring-backups.yml" \
  GITHUB_REPOSITORY="$GITHUB_REPOSITORY" \
  GITHUB_RUN_ID="$GITHUB_RUN_ID" \
  "$script_dir/run-beta-recovery-capture-stage.sh"

for file in postgres.dump.age uploads.tar.gz.age capture-result.json; do
  [ -s "$RUNNER_TEMP/$file" ] && [ ! -L "$RUNNER_TEMP/$file" ] ||
    { echo "BACKUP_CAPTURE_BLOCKED:remote_capture_file_missing" >&2; exit 1; }
  cp -- "$RUNNER_TEMP/$file" "$output/$file"
done
db_sha=$(sha256sum "$output/postgres.dump.age" | awk '{print $1}')
media_sha=$(sha256sum "$output/uploads.tar.gz.age" | awk '{print $1}')
jq -cnS --arg slot "$slot" --arg source "$GITHUB_SHA" \
  --arg command "$(sha256sum "$0" | awk '{print $1}')" \
  --arg host_fingerprint "$BETA_RECURRING_HOST_FINGERPRINT" \
  --argjson captured "$captured_at" \
  --arg db_sha "$db_sha" --arg media_sha "$media_sha" \
  --argjson db_len "$(wc -c <"$output/postgres.dump.age")" \
  --argjson media_len "$(wc -c <"$output/uploads.tar.gz.age")" \
  '{schema:"meet-backend/beta-recurring-capture-source/v1",slotId:$slot,
    capturedAt:$captured,sourceRevision:$source,captureCommandDigest:$command,
    captureTransport:"ssh-host-key-verified-v1",
    captureHostFingerprint:$host_fingerprint,
    database:{length:$db_len,sha256:$db_sha},media:{length:$media_len,sha256:$media_sha}}' \
  >"$output/capture-result.json"
chmod 600 "$output"/*
