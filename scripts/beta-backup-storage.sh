#!/usr/bin/env bash
set -euo pipefail

beta_storage_require_config() {
  : "${BETA_BACKUP_BUCKET:?BETA_BACKUP_BUCKET is required}"
  : "${BETA_BACKUP_REGION:?BETA_BACKUP_REGION is required}"
  : "${BETA_BACKUP_ENDPOINT:?BETA_BACKUP_ENDPOINT is required}"
  [[ "$BETA_BACKUP_BUCKET" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,62}$ ]] ||
    { echo "storage bucket is invalid" >&2; return 1; }
  [[ "$BETA_BACKUP_REGION" =~ ^[A-Za-z0-9._-]{1,63}$ ]] ||
    { echo "storage region is invalid" >&2; return 1; }
  [[ "$BETA_BACKUP_ENDPOINT" =~ ^https://[^[:space:]]+$ ]] ||
    { echo "storage endpoint must use HTTPS" >&2; return 1; }
  command -v "${AWS_BIN:-aws}" >/dev/null 2>&1 ||
    { echo "AWS CLI is unavailable" >&2; return 1; }
}

beta_storage_key() {
  local key=${1:-}
  [[ "$key" =~ ^(points|receipts|control)/[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
    { echo "storage key is unsafe" >&2; return 1; }
  [[ "$key" != *..* && "$key" != *'//'* ]] ||
    { echo "storage key is unsafe" >&2; return 1; }
  printf '%s\n' "$key"
}

beta_storage_validate_point() {
  local manifest=$1
  command -v jq >/dev/null 2>&1 || { echo "jq is unavailable" >&2; return 1; }
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  [ "$(wc -c <"$manifest")" -le 1048576 ] || return 1
  jq -e '
    type == "object" and
    (keys | sort) == ["capture","contractDigest","pointId","proofDigest","runtimeRevision","schema","slotId"] and
    .schema == "meet-backend/beta-recovery-point/v2" and
    (.pointId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.slotId | type == "string" and test("^[0-9]{10}$")) and
    (.capture | type == "object" and (keys | sort) == ["capturedAt","sourceRevision"] and
      (.capturedAt | type == "number" and floor == . and . >= 0) and
      (.sourceRevision | type == "string" and test("^[0-9a-f]{40}$"))) and
    (.runtimeRevision | type == "string" and test("^[0-9a-f]{40}$")) and
    (.contractDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.proofDigest | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null
}

beta_storage_inventory_total() {
  local inventory=$1 budget=$2
  [[ "$budget" =~ ^[0-9]+$ ]] || { echo "budget is invalid" >&2; return 1; }
  local total
  total=$(jq -r '
    if type != "array" then error("inventory") else
      reduce .[] as $item (0;
        if ($item | type) != "object" or
           (($item | keys | sort) != ["bytes","key","versions"]) then error("inventory")
        elif ($item.bytes | type) != "number" or ($item.bytes < 0) or
             ($item.bytes | floor) != $item.bytes then error("bytes")
        elif ($item.versions | type) != "number" or ($item.versions < 1) or
             ($item.versions | floor) != $item.versions then error("versions")
        elif . > (9223372036854775807 - ($item.bytes * $item.versions)) then error("overflow")
        else . + ($item.bytes * $item.versions)
        end)
    end
  ' "$inventory") || return 1
  [[ "$total" =~ ^[0-9]+$ ]] || { echo "inventory total is invalid" >&2; return 1; }
  (( total <= budget )) || { echo "storage budget exceeded" >&2; return 1; }
  printf '%s\n' "$total"
}

beta_storage_aws() {
  beta_storage_require_config
  local aws=${AWS_BIN:-aws}
  "$aws" --no-cli-pager --endpoint-url "$BETA_BACKUP_ENDPOINT" \
    --region "$BETA_BACKUP_REGION" s3api "$@"
}

beta_storage_validate_control() {
  local control=$1
  [ -f "$control" ] && [ ! -L "$control" ] || return 1
  [ "$(wc -c <"$control")" -le 65536 ] || return 1
  jq -e '
    type == "object" and
    (keys | sort) == ["generation","locked","operation","owner","transactionId"] and
    (.generation | type == "number" and floor == . and . >= 0) and
    (.locked | type == "boolean") and
    (.operation | type == "string" and test("^[a-z][a-z0-9_-]{0,31}$")) and
    (.owner | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")) and
    (.transactionId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"))
  ' "$control" >/dev/null
}
