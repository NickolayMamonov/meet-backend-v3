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
cleanup_capture_runner_temp() {
  local status=${1:-$?}
  trap - EXIT HUP INT TERM
  rm -f -- "$RUNNER_TEMP/postgres.dump.age" \
    "$RUNNER_TEMP/uploads.tar.gz.age" \
    "$RUNNER_TEMP/database-proof.json" \
    "$RUNNER_TEMP/media-proof.json" \
    "$RUNNER_TEMP/capture-database-proof.json" \
    "$RUNNER_TEMP/capture-media-proof.json" \
    "$RUNNER_TEMP/capture-runtime.json" \
    "$RUNNER_TEMP/capture-result.json" ||
    status=1
  if [ "$status" -ne 0 ]; then
    rm -f -- "$output"/* 2>/dev/null || status=1
  fi
  exit "$status"
}
trap 'cleanup_capture_runner_temp "$?"' EXIT
trap 'cleanup_capture_runner_temp 129' HUP
trap 'cleanup_capture_runner_temp 130' INT
trap 'cleanup_capture_runner_temp 143' TERM
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
remote_capture="$output/remote-capture-result.json"
cp -- "$output/capture-result.json" "$remote_capture"
remote_capture_time=$(jq -er '.recoveryPointTime' "$remote_capture") || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_evidence_invalid' >&2
  exit 1
}
remote_captured_at=$(date -u -d "$remote_capture_time" +%s) || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_time_invalid' >&2
  exit 1
}
[[ "$remote_captured_at" =~ ^[0-9]+$ ]] || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_time_invalid' >&2
  exit 1
}
remote_observed_at=$(date -u +%s)
(( remote_captured_at <= remote_observed_at )) || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_time_future' >&2
  exit 1
}
jq -e --arg id "recurring-$slot" --argjson captured "$remote_captured_at" '
  type=="object" and
  (keys|sort)==["capturedAt","ciphertexts","proofs","recoveryId",
    "recoveryPointTime","schema"] and
  .schema=="meet-backend/beta-recovery-capture/v1" and
  .recoveryId==$id and
  (.recoveryPointTime|type=="string") and
  (.capturedAt|type=="string") and
  (.ciphertexts|type=="object" and (keys|sort)==["database","uploads"] and
    all(.[]; (keys|sort)==["name","sha256","size"] and
      (.name|type=="string") and (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and
      (.size|type=="number" and floor==. and .>0)))
' "$remote_capture" >/dev/null || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_evidence_invalid' >&2
  exit 1
}
db_sha=$(sha256sum "$output/postgres.dump.age" | awk '{print $1}')
media_sha=$(sha256sum "$output/uploads.tar.gz.age" | awk '{print $1}')
jq -e --arg name postgres.dump.age --arg sha "$db_sha" \
  --argjson size "$(wc -c <"$output/postgres.dump.age")" \
  '.ciphertexts.database.name==$name and .ciphertexts.database.sha256==$sha and
   .ciphertexts.database.size==$size' "$remote_capture" >/dev/null ||
  { echo 'BACKUP_CAPTURE_BLOCKED:database_ciphertext_evidence_mismatch' >&2; exit 1; }
jq -e --arg name uploads.tar.gz.age --arg sha "$media_sha" \
  --argjson size "$(wc -c <"$output/uploads.tar.gz.age")" \
  '.ciphertexts.uploads.name==$name and .ciphertexts.uploads.sha256==$sha and
   .ciphertexts.uploads.size==$size' "$remote_capture" >/dev/null ||
  { echo 'BACKUP_CAPTURE_BLOCKED:media_ciphertext_evidence_mismatch' >&2; exit 1; }
stage_database_proof="$RUNNER_TEMP/database-proof.json"
stage_media_proof="$RUNNER_TEMP/media-proof.json"
if [ -e "$stage_database_proof" ] || [ -e "$stage_media_proof" ]; then
  [ -s "$stage_database_proof" ] && [ ! -L "$stage_database_proof" ] &&
    [ -s "$stage_media_proof" ] && [ ! -L "$stage_media_proof" ] || {
      echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_proof_pair_incomplete' >&2
      exit 1
    }
  cp -- "$stage_database_proof" "$output/capture-database-proof.json"
  cp -- "$stage_media_proof" "$output/capture-media-proof.json"
fi
[ -s "$RUNNER_TEMP/capture-runtime.json" ] &&
  [ ! -L "$RUNNER_TEMP/capture-runtime.json" ] ||
  { echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_runtime_missing' >&2; exit 1; }
cp -- "$RUNNER_TEMP/capture-runtime.json" "$output/capture-runtime.json"
[ -s "$output/capture-runtime.json" ] || {
  echo 'BACKUP_CAPTURE_BLOCKED:remote_capture_runtime_missing' >&2
  exit 1
}
runtime_digest=$(sha256sum "$output/capture-runtime.json" | awk '{print $1}')
remote_digest=$(sha256sum "$remote_capture" | awk '{print $1}')
jq -cnS --arg slot "$slot" --arg source "$GITHUB_SHA" \
  --arg command "$(sha256sum "$0" | awk '{print $1}')" \
  --arg host_fingerprint "$BETA_RECURRING_HOST_FINGERPRINT" \
  --argjson captured "$remote_captured_at" \
  --arg db_sha "$db_sha" --arg media_sha "$media_sha" \
  --argjson db_len "$(wc -c <"$output/postgres.dump.age")" \
  --argjson media_len "$(wc -c <"$output/uploads.tar.gz.age")" \
  --arg remote "$remote_digest" --arg runtime "$runtime_digest" \
  '{schema:"meet-backend/beta-recurring-capture-source/v2",slotId:$slot,
    capturedAt:$captured,sourceRevision:$source,captureCommandDigest:$command,
    captureTransport:"ssh-host-key-verified-v1",
    captureHostFingerprint:$host_fingerprint,
    remoteCaptureDigest:$remote,captureRuntimeDigest:$runtime,
    database:{name:"postgres.dump.age",length:$db_len,sha256:$db_sha},
    media:{name:"uploads.tar.gz.age",length:$media_len,sha256:$media_sha}}' \
  >"$output/capture-result.json"
chmod 600 "$output"/*
