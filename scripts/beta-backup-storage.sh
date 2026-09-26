#!/usr/bin/env bash
set -euo pipefail

readonly BETA_STORAGE_CONNECT_TIMEOUT_SECONDS=5
readonly BETA_STORAGE_READ_TIMEOUT_SECONDS=30
readonly BETA_STORAGE_REQUEST_TIMEOUT_SECONDS=60
readonly BETA_STORAGE_READ_ATTEMPTS=2
readonly BETA_STORAGE_MAX_PAGES=100

# This module owns the small, versioned writer protocol used by recurring
# backups. A local storage root is the deterministic fixture/provider adapter;
# the AWS path is deliberately read-only capability plumbing until an
# operator-approved endpoint is supplied.

beta_storage_fail() {
  printf 'BACKUP_STORAGE_BLOCKED:%s\n' "$1" >&2
  return 1
}

beta_storage_require_jq() {
  command -v jq >/dev/null 2>&1 || beta_storage_fail jq_unavailable
}

beta_storage_require_local_root() {
  local root=${1:-${BETA_BACKUP_STORAGE_ROOT:-}}
  [ -n "$root" ] && [[ "$root" = /* && "$root" != *..* && "$root" != *$'\n'* ]] ||
    beta_storage_fail storage_root_invalid
  [ ! -L "$root" ] || beta_storage_fail storage_root_symlink
  if [ "$(uname -s)" = Linux ]; then
    install -d -m 700 "$root" "$root/points" "$root/receipts" "$root/control"
    [ "$(stat -c '%a' "$root")" = 700 ] || beta_storage_fail storage_root_mode
  else
    mkdir -p "$root" "$root/points" "$root/receipts" "$root/control"
  fi
  printf '%s\n' "$root"
}

beta_storage_require_config() {
  if [ -n "${BETA_BACKUP_STORAGE_ROOT:-}" ]; then
    beta_storage_require_local_root "$BETA_BACKUP_STORAGE_ROOT" >/dev/null
    return 0
  fi
  : "${BETA_BACKUP_BUCKET:?BETA_BACKUP_BUCKET is required}"
  : "${BETA_BACKUP_REGION:?BETA_BACKUP_REGION is required}"
  : "${BETA_BACKUP_ENDPOINT:?BETA_BACKUP_ENDPOINT is required}"
  [[ "$BETA_BACKUP_BUCKET" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,62}$ ]] ||
    beta_storage_fail bucket_invalid
  [[ "$BETA_BACKUP_REGION" =~ ^[A-Za-z0-9._-]{1,63}$ ]] ||
    beta_storage_fail region_invalid
  [[ "$BETA_BACKUP_ENDPOINT" =~ ^https://[^[:space:]]+$ ]] ||
    beta_storage_fail endpoint_invalid
  command -v "${AWS_BIN:-aws}" >/dev/null 2>&1 ||
    beta_storage_fail aws_unavailable
  command -v timeout >/dev/null 2>&1 || beta_storage_fail timeout_unavailable
}

beta_storage_key() {
  local key=${1:-}
  [[ "$key" =~ ^(points|receipts|control)/[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
    beta_storage_fail key_invalid
  [[ "$key" != *..* && "$key" != *//* ]] || beta_storage_fail key_invalid
  printf '%s\n' "$key"
}

beta_storage_validate_point() {
  local manifest=$1
  beta_storage_require_jq
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
  [[ "$budget" =~ ^[0-9]+$ ]] || beta_storage_fail budget_invalid
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
  [[ "$total" =~ ^[0-9]+$ ]] || beta_storage_fail inventory_invalid
  (( total <= budget )) || beta_storage_fail budget_exceeded
  printf '%s\n' "$total"
}

beta_storage_aws() {
  beta_storage_require_config
  [ -z "${BETA_BACKUP_STORAGE_ROOT:-}" ] || beta_storage_fail local_provider_no_aws
  local aws=${AWS_BIN:-aws} output error status
  output=$(mktemp)
  error=$(mktemp)
  if timeout --foreground --signal=TERM \
      "${BETA_STORAGE_REQUEST_TIMEOUT_SECONDS}s" \
      "$aws" --no-cli-pager --endpoint-url "$BETA_BACKUP_ENDPOINT" \
      --region "$BETA_BACKUP_REGION" \
      --cli-connect-timeout "$BETA_STORAGE_CONNECT_TIMEOUT_SECONDS" \
      --cli-read-timeout "$BETA_STORAGE_READ_TIMEOUT_SECONDS" \
      s3api "$@" >"$output" 2>"$error"; then
    cat "$output"
    status=0
  else
    status=$?
    : >"$output"
    printf 'BACKUP_STORAGE_BLOCKED:%s\n' \
      "$([ "$status" -eq 124 ] && echo provider_timeout || echo provider_unavailable)" >&2
  fi
  rm -f -- "$output" "$error"
  return "$status"
}

beta_storage_aws_read() {
  local attempt
  for attempt in $(seq 1 "$BETA_STORAGE_READ_ATTEMPTS"); do
    : "$attempt"
    if beta_storage_aws "$@"; then
      return 0
    fi
  done
  beta_storage_fail provider_read_exhausted
}

beta_storage_aws_list_versions() {
  local key_marker='' version_marker='' page=0 response truncated
  while (( page < BETA_STORAGE_MAX_PAGES )); do
    page=$((page + 1))
    if [ -n "$key_marker" ]; then
      response=$(beta_storage_aws list-object-versions --bucket "$BETA_BACKUP_BUCKET" \
        --max-keys 1000 --key-marker "$key_marker" --version-id-marker "$version_marker") ||
        beta_storage_fail inventory_unavailable
    else
      response=$(beta_storage_aws list-object-versions --bucket "$BETA_BACKUP_BUCKET" \
        --max-keys 1000) || beta_storage_fail inventory_unavailable
    fi
    jq -e 'type=="object" and (.Versions|type=="array") and
      (.DeleteMarkers|type=="array") and ((.Versions|length)+(.DeleteMarkers|length)<=1000)' \
      <<<"$response" >/dev/null || beta_storage_fail inventory_invalid
    printf '%s\n' "$response"
    truncated=$(jq -er '.IsTruncated // false' <<<"$response")
    [ "$truncated" = true ] || return 0
    key_marker=$(jq -er '.NextKeyMarker // empty' <<<"$response")
    version_marker=$(jq -er '.NextVersionIdMarker // empty' <<<"$response")
    [ -n "$key_marker" ] && [ -n "$version_marker" ] || beta_storage_fail pagination_invalid
  done
  beta_storage_fail pagination_limit
}

beta_storage_local_read_json() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c <"$file")" -le 65536 ] || return 1
  jq -e . "$file" >/dev/null
}

beta_storage_local_atomic_json() {
  local destination=$1
  local temporary
  temporary=$(mktemp "${destination}.XXXXXX")
  chmod 600 "$temporary"
  dd iflag=fullblock of="$temporary" status=none
  mv -f -- "$temporary" "$destination"
}

beta_storage_local_acquire() {
  local root=$1 operation=$2 owner=${3:-${USER:-operator}} txid=$4
  local lock="$root/control/.writer.lock"
  mkdir "$lock" 2>/dev/null || beta_storage_fail writer_busy
  local generation=0
  if [ -f "$root/control/writer.json" ]; then
    beta_storage_local_read_json "$root/control/writer.json" || {
      rmdir "$lock"
      beta_storage_fail writer_state_invalid
    }
    [ "$(jq -er '.locked' "$root/control/writer.json")" = false ] || {
      rmdir "$lock"
      beta_storage_fail writer_state_locked
    }
    generation=$(jq -er '.generation' "$root/control/writer.json")
  fi
  jq -cnS --arg owner "$owner" --arg operation "$operation" --arg tx "$txid" \
    --argjson generation "$((generation + 1))" \
    '{schema:"meet-backend/beta-backup-writer/v1",generation:$generation,locked:true,
      operation:$operation,owner:$owner,transactionId:$tx}' |
    beta_storage_local_atomic_json "$root/control/writer.json"
}

beta_storage_local_release() {
  local root=$1
  local generation=0
  if beta_storage_local_read_json "$root/control/writer.json"; then
    generation=$(jq -er '.generation // 0' "$root/control/writer.json" 2>/dev/null) || generation=0
  fi
  jq -cnS --argjson generation "$((generation + 1))" \
    '{schema:"meet-backend/beta-backup-writer/v1",generation:$generation,locked:false,
      operation:"idle",owner:"none",transactionId:"none"}' |
    beta_storage_local_atomic_json "$root/control/writer.json"
  rmdir "$root/control/.writer.lock"
}

beta_storage_local_validate_point_dir() {
  local directory=$1 point_id=$2
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  for name in postgres.dump.age uploads.tar.gz.age recovery-point.json point.json; do
    [ -f "$directory/$name" ] && [ ! -L "$directory/$name" ] || return 1
  done
  [ -s "$directory/postgres.dump.age" ] && [ -s "$directory/uploads.tar.gz.age" ] || return 1
  beta_storage_validate_point "$directory/recovery-point.json" || return 1
  jq -e --arg id "$point_id" '
    type=="object" and (keys|sort)==["capture","ciphertexts","contractDigest",
    "descriptorDigest","pointId","proofDigest","runtimeRevision","slotId","schema"] and
    .schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.ciphertexts|type=="object" and (keys|sort)==["database","uploads"]) and
    ([.ciphertexts.database,.ciphertexts.uploads][] |
      type=="object" and (keys|sort)==["length","sha256"] and
      (.length|type=="number" and floor==. and .>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
  ' "$directory/point.json" >/dev/null
  [ "$(sha256sum "$directory/recovery-point.json" | awk '{print $1}')" = \
    "$(jq -er '.descriptorDigest' "$directory/point.json")" ] || return 1
  [ "$(wc -c <"$directory/postgres.dump.age")" = \
    "$(jq -er '.ciphertexts.database.length' "$directory/point.json")" ] || return 1
  [ "$(wc -c <"$directory/uploads.tar.gz.age")" = \
    "$(jq -er '.ciphertexts.uploads.length' "$directory/point.json")" ] || return 1
  [ "$(sha256sum "$directory/postgres.dump.age" | awk '{print $1}')" = \
    "$(jq -er '.ciphertexts.database.sha256' "$directory/point.json")" ] || return 1
  [ "$(sha256sum "$directory/uploads.tar.gz.age" | awk '{print $1}')" = \
    "$(jq -er '.ciphertexts.uploads.sha256' "$directory/point.json")" ] || return 1
}

beta_storage_publish_local() {
  local source=$1 root=$2 point_id=$3 slot=$4 captured_at=$5 owner=$6
  local point_dir="$root/points/$point_id"
  [ -d "$source" ] && [ ! -L "$source" ] || beta_storage_fail source_invalid
  [[ "$point_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || beta_storage_fail point_invalid
  [[ "$slot" =~ ^[0-9]{10}$ && "$captured_at" =~ ^[0-9]+$ ]] ||
    beta_storage_fail capture_metadata_invalid
  beta_storage_validate_point "$source/recovery-point.json" ||
    beta_storage_fail manifest_invalid
  for name in postgres.dump.age uploads.tar.gz.age; do
    [ -f "$source/$name" ] && [ ! -L "$source/$name" ] && [ -s "$source/$name" ] ||
      beta_storage_fail ciphertext_missing
  done
  [ ! -e "$point_dir" ] || {
    beta_storage_local_validate_point_dir "$point_dir" "$point_id" ||
      beta_storage_fail duplicate_point_conflict
    printf 'storage_publish=idempotent point_id=%s\n' "$point_id"
    return 0
  }
  local txid="publish-$point_id"
  beta_storage_local_acquire "$root" publish "$owner" "$txid"
  local cleanup=true
  trap 'if [ "$cleanup" = true ]; then rm -rf -- "$point_dir"; fi' RETURN
  local budget=${BETA_BACKUP_BYTE_BUDGET:-9223372036854775807}
  local current=0 file bytes
  for file in "$root"/points/*/* "$root"/receipts/*/* "$root"/control/*.json; do
    [ -f "$file" ] || continue
    bytes=$(wc -c <"$file")
    current=$((current + bytes))
  done
  for file in "$source/postgres.dump.age" "$source/uploads.tar.gz.age" \
    "$source/recovery-point.json"; do
    current=$((current + $(wc -c <"$file")))
  done
  (( current <= budget )) || { beta_storage_local_release "$root"; cleanup=false; beta_storage_fail budget_exceeded; }
  mkdir "$point_dir"
  chmod 700 "$point_dir"
  install -m 600 "$source/postgres.dump.age" "$point_dir/postgres.dump.age"
  install -m 600 "$source/uploads.tar.gz.age" "$point_dir/uploads.tar.gz.age"
  install -m 600 "$source/recovery-point.json" "$point_dir/recovery-point.json"
  local db_len media_len db_sha media_sha manifest_digest
  db_len=$(wc -c <"$point_dir/postgres.dump.age")
  media_len=$(wc -c <"$point_dir/uploads.tar.gz.age")
  db_sha=$(sha256sum "$point_dir/postgres.dump.age" | awk '{print $1}')
  media_sha=$(sha256sum "$point_dir/uploads.tar.gz.age" | awk '{print $1}')
  manifest_digest=$(sha256sum "$source/recovery-point.json" | awk '{print $1}')
  jq -cnS --arg id "$point_id" --arg slot "$slot" --argjson captured "$captured_at" \
    --arg runtime "$(jq -er '.runtimeRevision' "$source/recovery-point.json")" \
    --arg contract "$(jq -er '.contractDigest' "$source/recovery-point.json")" \
    --arg proof "$(jq -er '.proofDigest' "$source/recovery-point.json")" \
    --arg capture "$(jq -er '.capture.capturedAt' "$source/recovery-point.json")" \
    --arg dbsha "$db_sha" --arg mediasha "$media_sha" --argjson dblen "$db_len" \
    --argjson medielen "$media_len" --arg manifest "$manifest_digest" \
    '{schema:"meet-backend/beta-backup-descriptor/v2",pointId:$id,slotId:$slot,
      capture:{capturedAt:($capture|tonumber)},runtimeRevision:$runtime,
      contractDigest:$contract,proofDigest:$proof,
      ciphertexts:{database:{length:$dblen,sha256:$dbsha},
        uploads:{length:$medielen,sha256:$mediasha}},descriptorDigest:$manifest}' |
    beta_storage_local_atomic_json "$point_dir/point.json"
  local head_generation=0
  [ -f "$root/control/capture-head.json" ] &&
    head_generation=$(jq -er '.generation' "$root/control/capture-head.json") || true
  jq -cnS --arg id "$point_id" --argjson captured "$captured_at" \
    --argjson generation "$((head_generation + 1))" \
    --arg digest "$(sha256sum "$point_dir/point.json" | awk '{print $1}')" \
    '{schema:"meet-backend/beta-backup-head/v1",generation:$generation,
      pointId:$id,capturedAt:$captured,descriptorDigest:$digest}' |
    beta_storage_local_atomic_json "$root/control/capture-head.json"
  beta_storage_local_release "$root"
  cleanup=false
  trap - RETURN
  printf 'storage_publish=committed point_id=%s manifest_last=true\n' "$point_id"
}

beta_storage_validate_receipt() {
  local receipt=$1
  beta_storage_require_jq
  [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
  jq -e '
    type=="object" and (keys|sort)==["captureRevision","pointId","proofDigest",
      "receiptId","restoreRevision","schema","verifiedCapturedAt"] and
    .schema=="meet-backend/beta-backup-receipt/v1" and
    (.receiptId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.pointId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.captureRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.restoreRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.proofDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.verifiedCapturedAt|type=="number" and floor==. and .>=0)
  ' "$receipt" >/dev/null
}

beta_storage_promote_local() {
  local receipt=$1 root=$2 owner=$3
  beta_storage_validate_receipt "$receipt" || beta_storage_fail receipt_invalid
  local point_id receipt_id verified_at
  point_id=$(jq -er '.pointId' "$receipt")
  receipt_id=$(jq -er '.receiptId' "$receipt")
  verified_at=$(jq -er '.verifiedCapturedAt' "$receipt")
  beta_storage_local_validate_point_dir "$root/points/$point_id" "$point_id" ||
    beta_storage_fail point_unavailable
  beta_storage_local_acquire "$root" promote "$owner" "promote-$receipt_id"
  local receipt_dir="$root/receipts/$point_id"
  if [ "$(uname -s)" = Linux ]; then
    install -d -m 700 "$receipt_dir"
  else
    mkdir -p "$receipt_dir"
  fi
  install -m 600 "$receipt" "$receipt_dir/$receipt_id.json"
  local old_at=-1 old_id='' old_receipt='' old_gen=0
  if [ -f "$root/control/verified-head.json" ]; then
    old_at=$(jq -er '.verifiedCapturedAt' "$root/control/verified-head.json") || old_at=-1
    old_id=$(jq -er '.pointId' "$root/control/verified-head.json") || old_id=
    old_receipt=$(jq -er '.receiptId' "$root/control/verified-head.json") || old_receipt=
    old_gen=$(jq -er '.generation' "$root/control/verified-head.json") || old_gen=0
  fi
  if (( verified_at < old_at )); then
    beta_storage_local_release "$root"
    beta_storage_fail verified_head_regression
  fi
  if (( verified_at == old_at )); then
    if [ "$old_id" = "$point_id" ] && [ "$old_receipt" = "$receipt_id" ]; then
      beta_storage_local_release "$root"
      printf 'storage_promote=idempotent point_id=%s receipt_id=%s\n' "$point_id" "$receipt_id"
      return 0
    fi
    beta_storage_local_release "$root"
    beta_storage_fail verified_head_tie
  fi
  jq -cnS --arg id "$point_id" --arg rid "$receipt_id" --argjson at "$verified_at" \
    --argjson generation "$((old_gen + 1))" \
    '{schema:"meet-backend/beta-backup-verified-head/v1",generation:$generation,
      pointId:$id,receiptId:$rid,verifiedCapturedAt:$at}' |
    beta_storage_local_atomic_json "$root/control/verified-head.json"
  beta_storage_local_release "$root"
  printf 'storage_promote=committed point_id=%s receipt_id=%s\n' "$point_id" "$receipt_id"
}

beta_storage_prune_local() {
  local root=$1 now=$2 owner=$3
  [[ "$now" =~ ^[0-9]+$ ]] || beta_storage_fail clock_invalid
  beta_storage_local_acquire "$root" prune "$owner" "prune-$now"
  local pinned=
  [ -f "$root/control/verified-head.json" ] &&
    pinned=$(jq -er '.pointId' "$root/control/verified-head.json") || true
  local removed=0 directory point_id captured
  for directory in "$root"/points/*; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    point_id=${directory##*/}
    [ "$point_id" = "$pinned" ] && continue
    [ -f "$directory/recovery-point.json" ] || continue
    captured=$(jq -er '.capture.capturedAt' "$directory/recovery-point.json") || continue
    if (( now - captured >= 2592000 )); then
      rm -rf -- "$directory"
      rm -rf -- "$root/receipts/$point_id"
      removed=$((removed + 1))
    fi
  done
  beta_storage_local_release "$root"
  printf 'storage_prune=committed removed_points=%s pinned_point=%s\n' "$removed" "${pinned:-none}"
}

beta_storage_reconcile_local() {
  local root=$1 incomplete=0 directory
  for directory in "$root"/points/*; do
    [ -d "$directory" ] && [ ! -L "$directory" ] || continue
    if ! beta_storage_local_validate_point_dir "$directory" "${directory##*/}"; then
      incomplete=$((incomplete + 1))
    fi
  done
  [ "$incomplete" -eq 0 ] || beta_storage_fail incomplete_points
  printf 'storage_reconcile=clean points=%s\n' "$(find "$root/points" -mindepth 1 -maxdepth 1 -type d | wc -l)"
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
