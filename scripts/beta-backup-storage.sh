#!/usr/bin/env bash
set -euo pipefail

readonly BETA_STORAGE_CONNECT_TIMEOUT_SECONDS=5
readonly BETA_STORAGE_READ_TIMEOUT_SECONDS=30
readonly BETA_STORAGE_REQUEST_TIMEOUT_SECONDS=60
readonly BETA_STORAGE_READ_ATTEMPTS=2
readonly BETA_STORAGE_MAX_PAGES=100

# This module owns the bounded versioned writer protocol used by recurring
# backups. A local storage root is a deterministic fixture adapter only;
# recurring workflows use the authenticated versioned provider path.

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

beta_storage_remote() {
  [ -z "${BETA_BACKUP_STORAGE_ROOT:-}" ]
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
    (keys | sort) == ["capture","captureCommandDigest","captureEvidenceDigest","contractDigest","pointId","proofDigest","runtimeRevision","schema","slotId"] and
    .schema == "meet-backend/beta-recovery-point/v2" and
    (.pointId | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.slotId | type == "string" and test("^[0-9]{10}$")) and
    (.capture | type == "object" and (keys | sort) == ["capturedAt","sourceRevision"] and
      (.capturedAt | type == "number" and floor == . and . >= 0) and
      (.sourceRevision | type == "string" and test("^[0-9a-f]{40}$"))) and
    (.runtimeRevision | type == "string" and test("^[0-9a-f]{40}$")) and
    (.captureCommandDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.captureEvidenceDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.contractDigest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.proofDigest | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$manifest" >/dev/null
}

beta_storage_validate_capture_proof() {
  local kind=$1 proof=$2
  beta_storage_require_jq
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  [ "$(wc -c <"$proof")" -le 1048576 ] || return 1
  case "$kind" in
    database)
      jq -e 'type=="object" and .schema=="meet-backend/closed-beta-database-proof/v1"' \
        "$proof" >/dev/null
      ;;
    media)
      jq -e '
        type=="object" and .schema=="meet-backend/beta-recovery-media-proof/v1" and
        .referencesResolved==true and
        (.files|type=="number" and floor==. and .>=0) and
        (.bytes|type=="number" and floor==. and .>=0) and
        (.canonicalDigest|type=="string" and test("^[0-9a-f]{64}$"))
      ' "$proof" >/dev/null
      ;;
    *) return 1 ;;
  esac
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

beta_storage_local_provider_put() {
  local root=$1 key=$2 source=$3
  beta_storage_require_local_root "$root" >/dev/null
  beta_storage_key "$key" >/dev/null
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    beta_storage_fail provider_source_invalid
  local sha version destination
  sha=$(sha256sum "$source" | awk '{print $1}')
  version="local-$sha"
  destination="$root/provider/$key/versions/$version"
  mkdir -p "$(dirname -- "$destination")"
  [ ! -L "$root/provider" ] && [ ! -L "$(dirname -- "$destination")" ] ||
    beta_storage_fail provider_path_symlink
  if [ -e "$destination" ]; then
    cmp -s "$source" "$destination" || beta_storage_fail provider_version_conflict
  else
    install -m 600 "$source" "$destination"
  fi
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$(wc -c <"$source")" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_local_provider_get() {
  local root=$1 key=$2 version=$3 destination=$4 expected_sha=${5:-}
  beta_storage_require_local_root "$root" >/dev/null
  beta_storage_key "$key" >/dev/null
  [[ "$version" =~ ^local-[0-9a-f]{64}$ ]] || beta_storage_fail provider_version_invalid
  local source="$root/provider/$key/versions/$version"
  [ -f "$source" ] && [ ! -L "$source" ] || beta_storage_fail provider_object_missing
  install -m 600 "$source" "$destination"
  [ "$(sha256sum "$source" | awk '{print $1}')" = \
    "$(sha256sum "$destination" | awk '{print $1}')" ] ||
    beta_storage_fail provider_integrity_mismatch
  [ -z "$expected_sha" ] ||
    [ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_sha" ] ||
    beta_storage_fail provider_integrity_mismatch
}

beta_storage_local_provider_delete() {
  local root=$1 key=$2 version=$3
  beta_storage_require_local_root "$root" >/dev/null
  beta_storage_key "$key" >/dev/null
  [[ "$version" =~ ^local-[0-9a-f]{64}$ ]] || beta_storage_fail provider_version_invalid
  local source="$root/provider/$key/versions/$version"
  [ ! -e "$source" ] && [ ! -L "$source" ] && return 0
  [ -f "$source" ] && [ ! -L "$source" ] || beta_storage_fail provider_object_invalid
  rm -f -- "$source"
}

beta_storage_local_provider_list() {
  local root=$1
  beta_storage_require_local_root "$root" >/dev/null
  local provider_root="$root/provider"
  [ ! -e "$provider_root" ] && { printf '[]\n'; return 0; }
  [ -d "$provider_root" ] && [ ! -L "$provider_root" ] || beta_storage_fail provider_root_invalid
  local file relative key version bytes sha
  while IFS= read -r -d '' file; do
    relative=${file#"$provider_root"/}
    [[ "$relative" == */versions/local-* ]] || beta_storage_fail provider_layout_invalid
    key=${relative%/versions/*}
    version=${relative##*/}
    bytes=$(wc -c <"$file")
    sha=$(sha256sum "$file" | awk '{print $1}')
    jq -cnS --arg key "$key" --arg version "$version" --arg sha "$sha" \
      --argjson bytes "$bytes" \
      '{key:$key,versionId:$version,bytes:$bytes,sha256:$sha}'
  done < <(find "$provider_root" -type f -name 'local-*' -print0 | sort -z)
}

beta_storage_provider_put() {
  local root=$1 key=$2 source=$3
  if [ -n "$root" ]; then
    beta_storage_local_provider_put "$root" "$key" "$source"
    return
  fi
  beta_storage_require_config
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    beta_storage_fail provider_source_invalid
  local sha output version
  sha=$(sha256sum "$source" | awk '{print $1}')
  output=$(beta_storage_aws put-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --body "$source" --metadata "sha256=$sha") || beta_storage_fail provider_put_failed
  version=$(jq -er '.VersionId // empty' <<<"$output") || beta_storage_fail provider_version_missing
  [[ "$version" != null && -n "$version" ]] || beta_storage_fail provider_version_missing
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$(wc -c <"$source")" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_provider_put_conditional() {
  local root=$1 key=$2 source=$3 if_match=${4:-} if_none_match=${5:-false}
  [ -z "$if_match" ] || [[ "$if_match" =~ ^\"?[A-Za-z0-9+/=_-]+\"?$ ]] ||
    beta_storage_fail etag_invalid
  if [ -n "$root" ]; then
    [ -z "$if_match" ] || {
      local current
      current=$(sha256sum "$root/provider/$key/versions/"* 2>/dev/null |
        awk 'NR==1{print $1}') || beta_storage_fail cas_conflict
      [ "$current" = "${if_match//\"/}" ] || beta_storage_fail cas_conflict
    }
    [ "$if_none_match" != true ] || {
      [ ! -e "$root/provider/$key" ] || beta_storage_fail cas_conflict
    }
    beta_storage_local_provider_put "$root" "$key" "$source"
    return
  fi
  beta_storage_require_config
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    beta_storage_fail provider_source_invalid
  local sha output version
  sha=$(sha256sum "$source" | awk '{print $1}')
  local args=(put-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" --body "$source"
    --metadata "sha256=$sha")
  [ -z "$if_match" ] || args+=(--if-match "$if_match")
  [ "$if_none_match" = true ] || true
  [ "$if_none_match" != true ] || args+=(--if-none-match '*')
  output=$(beta_storage_aws "${args[@]}") || beta_storage_fail provider_conditional_write_failed
  version=$(jq -er '.VersionId // empty' <<<"$output") ||
    beta_storage_fail provider_version_missing
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$(wc -c <"$source")" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_provider_get() {
  local root=$1 key=$2 version=$3 destination=$4 expected_sha=${5:-}
  if [ -n "$root" ]; then
    beta_storage_local_provider_get "$root" "$key" "$version" "$destination" "$expected_sha"
    return
  fi
  beta_storage_require_config
  beta_storage_aws get-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" "$destination" >/dev/null ||
    beta_storage_fail provider_get_failed
  [ -z "$expected_sha" ] ||
    [ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_sha" ] ||
    beta_storage_fail provider_integrity_mismatch
}

beta_storage_provider_delete() {
  local root=$1 key=$2 version=$3
  if [ -n "$root" ]; then
    beta_storage_local_provider_delete "$root" "$key" "$version"
    return
  fi
  beta_storage_require_config
  beta_storage_aws delete-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >/dev/null ||
    beta_storage_fail provider_delete_failed
}

beta_storage_remote_latest_version() {
  local key=$1 response
  beta_storage_key "$key" >/dev/null
  response=$(beta_storage_aws head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key") ||
    beta_storage_fail provider_object_missing
  jq -er '.VersionId // empty' <<<"$response" ||
    beta_storage_fail provider_version_missing
}

beta_storage_remote_head() {
  local key=$1 output=$2
  beta_storage_key "$key" >/dev/null
  beta_storage_aws head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" >"$output" ||
    return 1
  jq -e 'type=="object" and (.VersionId|type=="string" and length>0) and
    (.ETag|type=="string" and length>0)' "$output" >/dev/null || return 1
}

beta_storage_remote_get_json() {
  local key=$1 output=$2 version=${3:-}
  if [ -z "$version" ]; then
    version=$(beta_storage_remote_latest_version "$key")
  fi
  beta_storage_provider_get '' "$key" "$version" "$output" >/dev/null
}

beta_storage_remote_writer_acquire() {
  local operation=$1 owner=$2 txid=$3 head state body etag version
  beta_storage_require_config
  : "${BETA_STORAGE_REMOTE_WRITER_ETAG:=}"
  BETA_STORAGE_REMOTE_WRITER_ETAG=''
  BETA_STORAGE_REMOTE_WRITER_FENCING=''
  BETA_STORAGE_REMOTE_WRITER_TX=''
  BETA_STORAGE_REMOTE_WRITER_OWNER=''
  head=$(mktemp)
  state=$(mktemp)
  body=$(mktemp)
  trap - RETURN
  local generation=0 fencing=0 if_match='' if_none=false
  if beta_storage_remote_head control/writer.json "$head"; then
    etag=$(jq -er '.ETag' "$head")
    version=$(jq -er '.VersionId' "$head")
    beta_storage_remote_get_json control/writer.json "$state" "$version"
    jq -e '
      type=="object" and
      (keys|sort)==["fencingToken","generation","leaseUntil","locked","operation","owner","schema","transactionId"] and
      .schema=="meet-backend/beta-backup-writer/v2" and
      (.generation|type=="number" and floor==. and .>=0) and
      (.fencingToken|type=="number" and floor==. and .>=0) and
      (.leaseUntil|type=="number" and floor==. and .>=0) and
      (.locked|type=="boolean") and (.owner|type=="string") and
      (.transactionId|type=="string")
    ' "$state" >/dev/null || beta_storage_fail writer_state_invalid
    [ "$(jq -er '.locked' "$state")" = false ] || beta_storage_fail writer_busy
    generation=$(jq -er '.generation' "$state")
    fencing=$(jq -er '.fencingToken' "$state")
    if_match=$etag
  else
    if_none=true
  fi
  jq -cnS --arg operation "$operation" --arg owner "$owner" --arg tx "$txid" \
    --argjson generation "$((generation + 1))" --argjson fencing "$((fencing + 1))" \
    --argjson lease "$(($(date -u +%s) + 3600))" \
    '{schema:"meet-backend/beta-backup-writer/v2",generation:$generation,
      fencingToken:$fencing,leaseUntil:$lease,locked:true,operation:$operation,
      owner:$owner,transactionId:$tx}' >"$body"
  if [ "$if_none" = true ]; then
    beta_storage_provider_put_conditional '' control/writer.json "$body" '' true >/dev/null
  else
    beta_storage_provider_put_conditional '' control/writer.json "$body" "$if_match" false >/dev/null
  fi || beta_storage_fail writer_race
  beta_storage_remote_head control/writer.json "$head" || beta_storage_fail writer_state_unreadable
  BETA_STORAGE_REMOTE_WRITER_ETAG=$(jq -er '.ETag' "$head")
  BETA_STORAGE_REMOTE_WRITER_FENCING=$((fencing + 1))
  BETA_STORAGE_REMOTE_WRITER_TX=$txid
  BETA_STORAGE_REMOTE_WRITER_OWNER=$owner
  rm -f -- "$head" "$state" "$body"
}

beta_storage_remote_writer_release() {
  local owner=$1 txid=$2 body head state current_etag generation fencing
  [ "$owner" = "${BETA_STORAGE_REMOTE_WRITER_OWNER:-}" ] &&
    [ "$txid" = "${BETA_STORAGE_REMOTE_WRITER_TX:-}" ] &&
    [ -n "${BETA_STORAGE_REMOTE_WRITER_ETAG:-}" ] ||
    beta_storage_fail stale_owner
  head=$(mktemp)
  state=$(mktemp)
  body=$(mktemp)
  trap - RETURN
  beta_storage_remote_head control/writer.json "$head" || beta_storage_fail stale_owner
  current_etag=$(jq -er '.ETag' "$head")
  [ "$current_etag" = "$BETA_STORAGE_REMOTE_WRITER_ETAG" ] || beta_storage_fail stale_owner
  beta_storage_remote_get_json control/writer.json "$state" "$(jq -er '.VersionId' "$head")"
  jq -e --arg owner "$owner" --arg tx "$txid" --argjson fencing "$BETA_STORAGE_REMOTE_WRITER_FENCING" \
    '.locked==true and .owner==$owner and .transactionId==$tx and .fencingToken==$fencing' \
    "$state" >/dev/null || beta_storage_fail stale_owner
  generation=$(jq -er '.generation' "$state")
  fencing=$(jq -er '.fencingToken' "$state")
  jq -cnS --arg owner "$owner" --arg tx "$txid" \
    --argjson generation "$((generation + 1))" --argjson fencing "$fencing" \
    '{schema:"meet-backend/beta-backup-writer/v2",generation:$generation,
      fencingToken:$fencing,leaseUntil:0,locked:false,operation:"idle",
      owner:$owner,transactionId:$tx}' >"$body"
  beta_storage_provider_put_conditional '' control/writer.json "$body" "$current_etag" false >/dev/null ||
    beta_storage_fail writer_release_failed
  BETA_STORAGE_REMOTE_WRITER_ETAG=''
  BETA_STORAGE_REMOTE_WRITER_TX=''
  BETA_STORAGE_REMOTE_WRITER_OWNER=''
  BETA_STORAGE_REMOTE_WRITER_FENCING=''
  rm -f -- "$head" "$state" "$body"
}

beta_storage_remote_inventory_total() {
  local budget=${1:-${BETA_BACKUP_BYTE_BUDGET:-0}} additional=${2:-0} response parts
  [[ "$budget" =~ ^[0-9]+$ ]] || beta_storage_fail budget_invalid
  [[ "$additional" =~ ^[0-9]+$ ]] || beta_storage_fail reservation_invalid
  response=$(beta_storage_aws_list_versions | jq -s '
    [.[].Versions[]? | (.Size // 0)] | add // 0') ||
    beta_storage_fail inventory_unavailable
  [[ "$response" =~ ^[0-9]+$ ]] || beta_storage_fail inventory_invalid
  local key_marker='' upload_id_marker='' page=0
  while (( page < BETA_STORAGE_MAX_PAGES )); do
    page=$((page + 1))
    if [ -n "$key_marker" ]; then
      parts=$(beta_storage_aws list-multipart-uploads --bucket "$BETA_BACKUP_BUCKET" \
        --max-uploads 1000 --key-marker "$key_marker" --upload-id-marker "$upload_id_marker") ||
        beta_storage_fail multipart_inventory_unavailable
    else
      parts=$(beta_storage_aws list-multipart-uploads --bucket "$BETA_BACKUP_BUCKET" \
        --max-uploads 1000) || beta_storage_fail multipart_inventory_unavailable
    fi
    jq -e 'type=="object" and (.Uploads|type=="array")' <<<"$parts" >/dev/null ||
      beta_storage_fail multipart_inventory_invalid
    [ "$(jq -er '.Uploads|length' <<<"$parts")" -eq 0 ] ||
      beta_storage_fail incomplete_uploads_present
    [ "$(jq -er '.IsTruncated // false' <<<"$parts")" = true ] || break
    key_marker=$(jq -er '.NextKeyMarker // empty' <<<"$parts")
    upload_id_marker=$(jq -er '.NextUploadIdMarker // empty' <<<"$parts")
    [ -n "$key_marker" ] && [ -n "$upload_id_marker" ] ||
      beta_storage_fail multipart_pagination_invalid
  done
  (( page < BETA_STORAGE_MAX_PAGES )) || beta_storage_fail multipart_pagination_limit
  local total=$((response + additional))
  (( total >= response )) || beta_storage_fail budget_overflow
  (( total <= budget )) || beta_storage_fail budget_exceeded
  printf '%s\n' "$total"
}

beta_storage_publish_remote() {
  local source=$1 point_id=$2 slot=$3 captured_at=$4 owner=$5
  [ -d "$source" ] && [ ! -L "$source" ] || beta_storage_fail source_invalid
  beta_storage_validate_point "$source/recovery-point.json" ||
    beta_storage_fail manifest_invalid
  [ "$point_id" = "$(jq -er '.pointId' "$source/recovery-point.json")" ] ||
    beta_storage_fail point_manifest_mismatch
  [ "$slot" = "$(jq -er '.slotId' "$source/recovery-point.json")" ] ||
    beta_storage_fail slot_manifest_mismatch
  [ "$captured_at" = "$(jq -er '.capture.capturedAt' "$source/recovery-point.json")" ] ||
    beta_storage_fail capture_time_mismatch
  for name in postgres.dump.age uploads.tar.gz.age; do
    [ -s "$source/$name" ] && [ ! -L "$source/$name" ] ||
      beta_storage_fail ciphertext_missing
  done
  local existing_head="$source/.remote-point-head.json" existing_descriptor="$source/.remote-point.json"
  if beta_storage_remote_head "points/$point_id/point.json" "$existing_head"; then
    beta_storage_remote_get_json "points/$point_id/point.json" "$existing_descriptor" \
      "$(jq -er '.VersionId' "$existing_head")"
    jq -e --arg id "$point_id" --arg slot "$slot" --argjson captured "$captured_at" \
      '.schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
       .slotId==$slot and .capture.capturedAt==$captured' "$existing_descriptor" >/dev/null ||
      beta_storage_fail duplicate_point_conflict
    rm -f -- "$existing_head" "$existing_descriptor"
    printf 'storage_publish=idempotent point_id=%s\n' "$point_id"
    return 0
  fi
  rm -f -- "$existing_head" "$existing_descriptor"
  local txid="publish-$point_id-$(date -u +%s)"
  beta_storage_remote_writer_acquire publish "$owner" "$txid"
  local cleanup=true release_allowed=true scratch
  scratch=$(mktemp -d)
  cleanup_remote_publish() {
    local status=$?
    trap - RETURN
    if [ "$cleanup" = true ]; then
      rm -rf -- "$scratch" || status=1
    fi
    if [ "$cleanup" = true ] && [ "$release_allowed" = true ]; then
      beta_storage_remote_writer_release "$owner" "$txid" || status=1
    fi
    return "$status"
  }
  trap cleanup_remote_publish RETURN
  local reserve
  reserve=$(( $(wc -c <"$source/postgres.dump.age") +
    $(wc -c <"$source/uploads.tar.gz.age") + 4 * 65536 ))
  beta_storage_remote_inventory_total "${BETA_BACKUP_BYTE_BUDGET:-9223372036854775807}" \
    "$reserve" >/dev/null
  local db_json media_json manifest_json db_version media_version manifest_version
  release_allowed=false
  db_json=$(beta_storage_provider_put_conditional '' "points/$point_id/postgres.dump.age" \
    "$source/postgres.dump.age" '' true)
  media_json=$(beta_storage_provider_put_conditional '' "points/$point_id/uploads.tar.gz.age" \
    "$source/uploads.tar.gz.age" '' true)
  manifest_json=$(beta_storage_provider_put_conditional '' "points/$point_id/recovery-point.json" \
    "$source/recovery-point.json" '' true)
  db_version=$(jq -er '.versionId' <<<"$db_json")
  media_version=$(jq -er '.versionId' <<<"$media_json")
  manifest_version=$(jq -er '.versionId' <<<"$manifest_json")
  local proofs_json='{}' proof_db_json proof_media_json
  if [ -e "$source/capture-database-proof.json" ] ||
    [ -e "$source/capture-media-proof.json" ]; then
    [ -s "$source/capture-database-proof.json" ] &&
      [ -s "$source/capture-media-proof.json" ] ||
      beta_storage_fail capture_proof_pair_incomplete
    beta_storage_validate_capture_proof database "$source/capture-database-proof.json" ||
      beta_storage_fail database_proof_invalid
    beta_storage_validate_capture_proof media "$source/capture-media-proof.json" ||
      beta_storage_fail media_proof_invalid
    proof_db_json=$(beta_storage_provider_put_conditional '' \
      "points/$point_id/capture-database-proof.json" \
      "$source/capture-database-proof.json" '' true)
    proof_media_json=$(beta_storage_provider_put_conditional '' \
      "points/$point_id/capture-media-proof.json" \
      "$source/capture-media-proof.json" '' true)
    proofs_json=$(jq -cn \
      --arg dbversion "$(jq -er '.versionId' <<<"$proof_db_json")" \
      --arg mediaversion "$(jq -er '.versionId' <<<"$proof_media_json")" \
      --arg dbsha "$(jq -er '.sha256' <<<"$proof_db_json")" \
      --arg mediasha "$(jq -er '.sha256' <<<"$proof_media_json")" \
      --argjson dblen "$(jq -er '.length' <<<"$proof_db_json")" \
      --argjson medielen "$(jq -er '.length' <<<"$proof_media_json")" \
      '{database:{length:$dblen,sha256:$dbsha,versionId:$dbversion},
        media:{length:$medielen,sha256:$mediasha,versionId:$mediaversion}}')
  fi
  local descriptor="$scratch/point.json"
  jq -cnS --arg id "$point_id" --arg slot "$slot" --argjson captured "$captured_at" \
    --arg runtime "$(jq -er '.runtimeRevision' "$source/recovery-point.json")" \
    --arg contract "$(jq -er '.contractDigest' "$source/recovery-point.json")" \
    --arg proof "$(jq -er '.proofDigest' "$source/recovery-point.json")" \
    --arg command "$(jq -er '.captureCommandDigest' "$source/recovery-point.json")" \
    --arg evidence "$(jq -er '.captureEvidenceDigest' "$source/recovery-point.json")" \
    --arg dbsha "$(jq -er '.sha256' <<<"$db_json")" \
    --arg mediasha "$(jq -er '.sha256' <<<"$media_json")" \
    --argjson dblen "$(jq -er '.length' <<<"$db_json")" \
    --argjson medielen "$(jq -er '.length' <<<"$media_json")" \
    --arg dbversion "$db_version" --arg mediaversion "$media_version" \
    --arg manifestversion "$manifest_version" \
    --argjson proofs "$proofs_json" \
    '{schema:"meet-backend/beta-backup-descriptor/v2",pointId:$id,slotId:$slot,
      capture:{capturedAt:$captured},runtimeRevision:$runtime,
      captureCommandDigest:$command,captureEvidenceDigest:$evidence,
      contractDigest:$contract,proofDigest:$proof,
      ciphertexts:{database:{length:$dblen,sha256:$dbsha},
        uploads:{length:$medielen,sha256:$mediasha}},
      versions:{database:$dbversion,manifest:$manifestversion,uploads:$mediaversion},
      proofs:$proofs,
      descriptorDigest:"pending"}' >"$descriptor"
  local descriptor_digest
  descriptor_digest=$(sha256sum "$source/recovery-point.json" | awk '{print $1}')
  jq --arg digest "$descriptor_digest" '.descriptorDigest=$digest' "$descriptor" >"$descriptor.tmp"
  mv -f "$descriptor.tmp" "$descriptor"
  beta_storage_provider_put_conditional '' "points/$point_id/point.json" "$descriptor" '' true >/dev/null
  local head="$scratch/capture-head.json" generation=0 head_meta="$scratch/head-meta.json"
  local head_etag='' head_version=''
  if beta_storage_remote_head control/capture-head.json "$head_meta"; then
    head_etag=$(jq -er '.ETag' "$head_meta")
    head_version=$(jq -er '.VersionId' "$head_meta")
    beta_storage_remote_get_json control/capture-head.json "$head" "$head_version" || true
    generation=$(jq -er '.generation // 0' "$head" 2>/dev/null) || generation=0
  fi
  jq -cnS --arg id "$point_id" --argjson captured "$captured_at" \
    --argjson generation "$((generation + 1))" --arg digest "$descriptor_digest" \
    '{schema:"meet-backend/beta-backup-head/v2",generation:$generation,
      pointId:$id,capturedAt:$captured,descriptorDigest:$digest}' >"$head"
  beta_storage_provider_put_conditional '' control/capture-head.json "$head" "$head_etag" \
    "$([ -z "$head_etag" ] && echo true || echo false)" >/dev/null
  cleanup=false
  beta_storage_remote_writer_release "$owner" "$txid"
  trap - RETURN
  rm -rf -- "$scratch"
  printf 'storage_publish=provider_committed point_id=%s manifest_last=true\n' "$point_id"
}

beta_storage_remote_validate_descriptor() {
  local point_id=$1 descriptor=$2 scratch=$3
  jq -e --arg id "$point_id" '
    type=="object" and
    (keys|sort)==["capture","captureCommandDigest","captureEvidenceDigest",
      "ciphertexts","contractDigest","descriptorDigest","pointId","proofDigest",
      "proofs","runtimeRevision","slotId","schema","versions"] and
    .schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.versions|type=="object" and (keys|sort)==["database","manifest","uploads"] and
      all(.[]; type=="string" and test("^[A-Za-z0-9._:-]{1,160}$"))) and
    (.proofs|type=="object" and ((keys|sort)==[] or
      ((keys|sort)==["database","media"] and
       (.database|type=="object" and (keys|sort)==["length","sha256","versionId"] and
        (.length|type=="number" and floor==. and .>0) and
        (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and
        (.versionId|type=="string" and test("^[A-Za-z0-9._:-]{1,160}$"))) and
       (.media|type=="object" and (keys|sort)==["length","sha256","versionId"] and
        (.length|type=="number" and floor==. and .>0) and
        (.sha256|type=="string" and test("^[0-9a-f]{64}$")) and
        (.versionId|type=="string" and test("^[A-Za-z0-9._:-]{1,160}$")))))) and
    ([.ciphertexts.database,.ciphertexts.uploads][] |
      type=="object" and (keys|sort)==["length","sha256"] and
      (.length|type=="number" and floor==. and .>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
  ' "$descriptor" >/dev/null || beta_storage_fail descriptor_invalid
  local manifest="$scratch/manifest.json" db="$scratch/database.age" media="$scratch/uploads.age"
  beta_storage_provider_get '' "points/$point_id/recovery-point.json" \
    "$(jq -er '.versions.manifest' "$descriptor")" "$manifest" >/dev/null
  beta_storage_validate_point "$manifest" || beta_storage_fail manifest_invalid
  [ "$(sha256sum "$manifest" | awk '{print $1}')" =
    "$(jq -er '.descriptorDigest' "$descriptor")" ] ||
    beta_storage_fail descriptor_manifest_mismatch
  [ "$(jq -er '.pointId' "$manifest")" = "$point_id" ] ||
    beta_storage_fail descriptor_point_mismatch
  beta_storage_provider_get '' "points/$point_id/postgres.dump.age" \
    "$(jq -er '.versions.database' "$descriptor")" "$db" \
    "$(jq -er '.ciphertexts.database.sha256' "$descriptor")" >/dev/null
  beta_storage_provider_get '' "points/$point_id/uploads.tar.gz.age" \
    "$(jq -er '.versions.uploads' "$descriptor")" "$media" \
    "$(jq -er '.ciphertexts.uploads.sha256' "$descriptor")" >/dev/null
  [ "$(wc -c <"$db")" = "$(jq -er '.ciphertexts.database.length' "$descriptor")" ] ||
    beta_storage_fail descriptor_database_length
  [ "$(wc -c <"$media")" = "$(jq -er '.ciphertexts.uploads.length' "$descriptor")" ] ||
    beta_storage_fail descriptor_uploads_length
  if [ "$(jq -er '.proofs|keys|length' "$descriptor")" -eq 2 ]; then
    local dbproof="$scratch/database-proof.json" mediaproof="$scratch/media-proof.json"
    beta_storage_provider_get '' "points/$point_id/capture-database-proof.json" \
      "$(jq -er '.proofs.database.versionId' "$descriptor")" "$dbproof" \
      "$(jq -er '.proofs.database.sha256' "$descriptor")" >/dev/null
    beta_storage_provider_get '' "points/$point_id/capture-media-proof.json" \
      "$(jq -er '.proofs.media.versionId' "$descriptor")" "$mediaproof" \
      "$(jq -er '.proofs.media.sha256' "$descriptor")" >/dev/null
    [ "$(wc -c <"$dbproof")" = "$(jq -er '.proofs.database.length' "$descriptor")" ] ||
      beta_storage_fail descriptor_database_proof_length
    [ "$(wc -c <"$mediaproof")" = "$(jq -er '.proofs.media.length' "$descriptor")" ] ||
      beta_storage_fail descriptor_media_proof_length
    beta_storage_validate_capture_proof database "$dbproof" ||
      beta_storage_fail descriptor_database_proof_invalid
    beta_storage_validate_capture_proof media "$mediaproof" ||
      beta_storage_fail descriptor_media_proof_invalid
  fi
}

beta_storage_promote_remote() {
  local receipt=$1 receipt_key=$2 owner=$3 scratch
  scratch=$(mktemp -d)
  if [ -n "$receipt_key" ]; then
    beta_storage_remote_get_json "$receipt_key" "$scratch/receipt.json"
    receipt="$scratch/receipt.json"
    local receipt_id
    receipt_id=$(jq -er '.receiptId' "$receipt")
    beta_storage_remote_get_json "receipts/$(jq -er '.pointId' "$receipt")/$receipt_id.proof.json" \
      "$scratch/$receipt_id.proof.json"
  fi
  beta_storage_validate_receipt "$receipt" || {
    rm -rf "$scratch"; beta_storage_fail receipt_invalid;
  }
  local point_id receipt_id txid="promote-$(date -u +%s)" descriptor="$scratch/point.json"
  point_id=$(jq -er '.pointId' "$receipt")
  receipt_id=$(jq -er '.receiptId' "$receipt")
  cp -- "$(dirname "$receipt")/$receipt_id.proof.json" "$scratch/$receipt_id.proof.json"
  beta_storage_remote_get_json "points/$point_id/point.json" "$descriptor"
  beta_storage_remote_validate_descriptor "$point_id" "$descriptor" "$scratch"
  [ "$(sha256sum "$descriptor" | awk '{print $1}')" =
    "$(jq -er '.pointDescriptorDigest' "$receipt")" ] ||
    { rm -rf "$scratch"; beta_storage_fail descriptor_binding; }
  jq -e --arg id "$point_id" --argjson captured "$(jq -er '.captureAt' "$receipt")" \
    --arg command "$(jq -er '.captureCommandDigest' "$receipt")" \
    --arg source "$(jq -er '.capture.sourceRevision' "$scratch/manifest.json")" \
    '.pointId==$id and .capture.capturedAt==$captured and
     .captureCommandDigest==$command and .capture.sourceRevision==$source' "$scratch/manifest.json" >/dev/null ||
    { rm -rf "$scratch"; beta_storage_fail receipt_provenance_binding; }
  beta_storage_remote_writer_acquire promote "$owner" "$txid"
  beta_storage_provider_put_conditional '' "receipts/$point_id/$receipt_id.json" "$receipt" '' true >/dev/null
  beta_storage_provider_put_conditional '' "receipts/$point_id/$receipt_id.proof.json" \
    "$scratch/$receipt_id.proof.json" '' true >/dev/null
  local head="$scratch/verified-head.json" generation=0 old old_at=-1
  local head_meta="$scratch/verified-head.meta.json" head_etag='' head_version=''
  if beta_storage_remote_head control/verified-head.json "$head_meta"; then
    head_etag=$(jq -er '.ETag' "$head_meta")
    head_version=$(jq -er '.VersionId' "$head_meta")
    beta_storage_remote_get_json control/verified-head.json "$head" "$head_version"
    generation=$(jq -er '.generation // 0' "$head")
    old_at=$(jq -er '.verifiedCapturedAt // -1' "$head")
  fi
  local verified_at
  verified_at=$(jq -er '.verifiedCapturedAt' "$receipt")
  (( verified_at > old_at )) ||
    { beta_storage_remote_writer_release "$owner" "$txid"; rm -rf "$scratch"; beta_storage_fail verified_head_not_newer; }
  jq -cnS --arg id "$point_id" --arg rid "$receipt_id" --argjson at "$verified_at" \
    --argjson generation "$((generation + 1))" \
    '{schema:"meet-backend/beta-backup-verified-head/v2",generation:$generation,
      pointId:$id,receiptId:$rid,verifiedCapturedAt:$at}' >"$head"
  beta_storage_provider_put_conditional '' control/verified-head.json "$head" "$head_etag" \
    "$([ -z "$head_etag" ] && echo true || echo false)" >/dev/null
  beta_storage_remote_writer_release "$owner" "$txid"
  rm -rf "$scratch"
  printf 'storage_promote=provider_committed point_id=%s receipt_id=%s\n' "$point_id" "$receipt_id"
}

beta_storage_remote_delete_version() {
  local key=$1 version=$2 head
  head=$(mktemp)
  beta_storage_aws head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >"$head" ||
    { rm -f "$head"; beta_storage_fail deletion_version_unreadable; }
  jq -e --arg version "$version" '.VersionId==$version' "$head" >/dev/null ||
    { rm -f "$head"; beta_storage_fail deletion_version_mismatch; }
  rm -f "$head"
  beta_storage_provider_delete '' "$key" "$version"
}

beta_storage_prune_remote() {
  local now=$1 owner=$2 pinned='' head_version
  [[ "$now" =~ ^[0-9]+$ ]] || beta_storage_fail clock_invalid
  beta_storage_remote_writer_acquire prune "$owner" "prune-$now"
  local head
  head=$(mktemp)
  if head_version=$(beta_storage_remote_latest_version control/verified-head.json 2>/dev/null); then
    beta_storage_remote_get_json control/verified-head.json "$head" "$head_version"
    pinned=$(jq -er '.pointId' "$head")
  fi
  local inventory key version seen
  inventory=$(beta_storage_aws_list_versions | jq -c '.')
  jq -e 'type=="array" and all(.[]; type=="object" and
    all(.Versions[]?; (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
      (.VersionId|type=="string" and length>0) and
      (.Size|type=="number" and floor==. and .>=0)) and
    all(.DeleteMarkers[]?; (.Key|type=="string") and
      (.VersionId|type=="string" and length>0)))' <<<"$inventory" >/dev/null ||
    beta_storage_fail inventory_invalid
  seen=$(mktemp)
  while IFS=$'\t' read -r key version; do
    [[ "$key" == points/*/recovery-point.json ]] || continue
    local point_id=${key#points/}; point_id=${point_id%/recovery-point.json}
    [ "$point_id" = "$pinned" ] && continue
    grep -Fxq -- "$point_id" "$seen" && continue
    printf '%s\n' "$point_id" >>"$seen"
    local manifest
    manifest=$(mktemp)
    beta_storage_provider_get '' "$key" "$version" "$manifest" >/dev/null || {
      rm -f "$manifest" "$seen"
      beta_storage_fail stale_manifest_unreadable
    }
    local captured
    captured=$(jq -er '.capture.capturedAt' "$manifest") || {
      rm -f "$manifest" "$seen"
      beta_storage_fail stale_manifest_invalid
    }
    if (( now - captured >= 2592000 )); then
      while IFS=$'\t' read -r object_key object_version; do
        [[ "$object_key" == "points/$point_id/"* || "$object_key" == "receipts/$point_id/"* ]] ||
          continue
        beta_storage_remote_delete_version "$object_key" "$object_version"
      done < <(jq -r --arg id "$point_id" '.Versions[]? |
        select(.Key|startswith("points/"+$id+"/") or startswith("receipts/"+$id+"/")) |
        [.Key,.VersionId]|@tsv' <<<"$inventory")
    fi
    rm -f "$manifest"
  done < <(jq -r '.Versions[]? | [.Key,.VersionId]|@tsv' <<<"$inventory")
  rm -f "$head" "$seen"
  beta_storage_remote_writer_release "$owner" "prune-$now"
  printf 'storage_prune=provider_committed pinned_point=%s\n' "${pinned:-none}"
}

beta_storage_reconcile_remote() {
  local inventory scratch key version descriptor
  beta_storage_remote_inventory_total "${BETA_BACKUP_BYTE_BUDGET:-9223372036854775807}" >/dev/null
  inventory=$(beta_storage_aws_list_versions | jq -c '.') ||
    beta_storage_fail inventory_unavailable
  jq -e 'type=="array" and all(.[]; type=="object" and
    all(.Versions[]?; (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
      (.VersionId|type=="string" and length>0) and
      (.Size|type=="number" and floor==. and .>=0)))' <<<"$inventory" >/dev/null ||
    beta_storage_fail inventory_invalid
  scratch=$(mktemp -d)
  while IFS=$'\t' read -r key version; do
    [[ "$key" == points/*/point.json ]] || continue
    local point_id=${key#points/}
    point_id=${point_id%/point.json}
    descriptor="$scratch/descriptor.json"
    beta_storage_provider_get '' "$key" "$version" "$descriptor" >/dev/null ||
      { rm -rf "$scratch"; beta_storage_fail descriptor_unreadable; }
    beta_storage_remote_validate_descriptor \
      "$point_id" "$descriptor" "$scratch" ||
      { rm -rf "$scratch"; beta_storage_fail descriptor_graph_invalid; }
  done < <(jq -r '.Versions[]? | [.Key,.VersionId]|@tsv' <<<"$inventory")
  rm -rf "$scratch"
  printf 'storage_reconcile=provider_clean\n'
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
    type=="object" and (keys|sort)==["capture","captureCommandDigest","captureEvidenceDigest",
    "ciphertexts","contractDigest","descriptorDigest","pointId","proofDigest",
    "proofs","runtimeRevision","slotId","schema","versions"] and
    .schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.captureCommandDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.captureEvidenceDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.versions|type=="object" and (keys|sort)==["database","manifest","uploads"] and
      all(.[]; type=="string" and test("^[A-Za-z0-9._:-]{1,160}$"))) and
    (.proofs|type=="object" and ((keys|sort)==[] or (keys|sort)==["database","media"])) and
    (.ciphertexts|type=="object" and (keys|sort)==["database","uploads"]) and
    ([.ciphertexts.database,.ciphertexts.uploads][] |
      type=="object" and (keys|sort)==["length","sha256"] and
      (.length|type=="number" and floor==. and .>0) and
      (.sha256|type=="string" and test("^[0-9a-f]{64}$")))
  ' "$directory/point.json" >/dev/null
  [ "$(sha256sum "$directory/recovery-point.json" | awk '{print $1}')" = \
    "$(jq -er '.descriptorDigest' "$directory/point.json")" ] || return 1
  [ "$(jq -er '.captureCommandDigest' "$directory/recovery-point.json")" = \
    "$(jq -er '.captureCommandDigest' "$directory/point.json")" ] || return 1
  [ "$(jq -er '.captureEvidenceDigest' "$directory/recovery-point.json")" = \
    "$(jq -er '.captureEvidenceDigest' "$directory/point.json")" ] || return 1
  [ "$(wc -c <"$directory/postgres.dump.age")" = \
    "$(jq -er '.ciphertexts.database.length' "$directory/point.json")" ] || return 1
  [ "$(wc -c <"$directory/uploads.tar.gz.age")" = \
    "$(jq -er '.ciphertexts.uploads.length' "$directory/point.json")" ] || return 1
  [ "$(sha256sum "$directory/postgres.dump.age" | awk '{print $1}')" = \
    "$(jq -er '.ciphertexts.database.sha256' "$directory/point.json")" ] || return 1
  [ "$(sha256sum "$directory/uploads.tar.gz.age" | awk '{print $1}')" = \
    "$(jq -er '.ciphertexts.uploads.sha256' "$directory/point.json")" ] || return 1
  if [ "$(jq -er '.proofs|keys|length' "$directory/point.json")" -eq 2 ]; then
    local proof_kind proof_file
    for proof_spec in database:capture-database-proof.json media:capture-media-proof.json; do
      proof_kind=${proof_spec%%:*}
      proof_file=${proof_spec#*:}
      [ -f "$directory/$proof_file" ] && [ ! -L "$directory/$proof_file" ] || return 1
      [ "$(wc -c <"$directory/$proof_file")" =
        "$(jq -er ".proofs.$proof_kind.length" "$directory/point.json")" ] || return 1
      [ "$(sha256sum "$directory/$proof_file" | awk '{print $1}')" =
        "$(jq -er ".proofs.$proof_kind.sha256" "$directory/point.json")" ] || return 1
      beta_storage_validate_capture_proof "$proof_kind" "$directory/$proof_file" || return 1
    done
  fi
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
  if [ -e "$source/capture-database-proof.json" ] ||
    [ -e "$source/capture-media-proof.json" ]; then
    [ -s "$source/capture-database-proof.json" ] &&
      [ -s "$source/capture-media-proof.json" ] ||
      beta_storage_fail capture_proof_pair_incomplete
    beta_storage_validate_capture_proof database "$source/capture-database-proof.json" ||
      beta_storage_fail database_proof_invalid
    beta_storage_validate_capture_proof media "$source/capture-media-proof.json" ||
      beta_storage_fail media_proof_invalid
  fi
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
    "$source/recovery-point.json" "$source/capture-database-proof.json" \
    "$source/capture-media-proof.json"; do
    [ -f "$file" ] || continue
    current=$((current + $(wc -c <"$file")))
  done
  current=$((current + 4 * 65536))
  (( current <= budget )) || { beta_storage_local_release "$root"; cleanup=false; beta_storage_fail budget_exceeded; }
  mkdir "$point_dir"
  chmod 700 "$point_dir"
  install -m 600 "$source/postgres.dump.age" "$point_dir/postgres.dump.age"
  install -m 600 "$source/uploads.tar.gz.age" "$point_dir/uploads.tar.gz.age"
  install -m 600 "$source/recovery-point.json" "$point_dir/recovery-point.json"
  local proofs_json='{}' proof_db_sha proof_media_sha
  if [ -e "$source/capture-database-proof.json" ] ||
    [ -e "$source/capture-media-proof.json" ]; then
    install -m 600 "$source/capture-database-proof.json" \
      "$point_dir/capture-database-proof.json"
    install -m 600 "$source/capture-media-proof.json" \
      "$point_dir/capture-media-proof.json"
    proof_db_sha=$(sha256sum "$source/capture-database-proof.json" | awk '{print $1}')
    proof_media_sha=$(sha256sum "$source/capture-media-proof.json" | awk '{print $1}')
    proofs_json=$(jq -cn --arg db "local-$proof_db_sha" --arg media "local-$proof_media_sha" \
      --arg dbsha "$proof_db_sha" --arg mediasha "$proof_media_sha" \
      --argjson dblen "$(wc -c <"$source/capture-database-proof.json")" \
      --argjson medielen "$(wc -c <"$source/capture-media-proof.json")" \
      '{database:{length:$dblen,sha256:$dbsha,versionId:$db},
        media:{length:$medielen,sha256:$mediasha,versionId:$media}}')
  fi
  local db_len media_len db_sha media_sha manifest_digest
  db_len=$(wc -c <"$point_dir/postgres.dump.age")
  media_len=$(wc -c <"$point_dir/uploads.tar.gz.age")
  db_sha=$(sha256sum "$point_dir/postgres.dump.age" | awk '{print $1}')
  media_sha=$(sha256sum "$point_dir/uploads.tar.gz.age" | awk '{print $1}')
  manifest_digest=$(sha256sum "$source/recovery-point.json" | awk '{print $1}')
  local capture_command_digest capture_evidence_digest
  capture_command_digest=$(jq -er '.captureCommandDigest' "$source/recovery-point.json")
  capture_evidence_digest=$(jq -er '.captureEvidenceDigest' "$source/recovery-point.json")
  jq -cnS --arg id "$point_id" --arg slot "$slot" --argjson captured "$captured_at" \
    --arg runtime "$(jq -er '.runtimeRevision' "$source/recovery-point.json")" \
    --arg contract "$(jq -er '.contractDigest' "$source/recovery-point.json")" \
    --arg proof "$(jq -er '.proofDigest' "$source/recovery-point.json")" \
    --arg command "$capture_command_digest" --arg evidence "$capture_evidence_digest" \
    --arg capture "$(jq -er '.capture.capturedAt' "$source/recovery-point.json")" \
    --arg dbsha "$db_sha" --arg mediasha "$media_sha" --argjson dblen "$db_len" \
    --argjson medielen "$media_len" --arg manifest "$manifest_digest" \
    --arg dbversion "local-$db_sha" --arg mediaversion "local-$media_sha" \
    --arg manifestversion "local-$manifest_digest" \
    --argjson proofs "$proofs_json" \
    '{schema:"meet-backend/beta-backup-descriptor/v2",pointId:$id,slotId:$slot,
      capture:{capturedAt:($capture|tonumber)},runtimeRevision:$runtime,
      captureCommandDigest:$command,captureEvidenceDigest:$evidence,
      contractDigest:$contract,proofDigest:$proof,
      ciphertexts:{database:{length:$dblen,sha256:$dbsha},
        uploads:{length:$medielen,sha256:$mediasha}},
      versions:{database:$dbversion,manifest:$manifestversion,uploads:$mediaversion},
      proofs:$proofs,
      descriptorDigest:$manifest}' |
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
    type=="object" and (keys|sort)==["captureAt","captureCommandDigest","captureRevision",
      "pointDescriptorDigest","pointId","proofDigest","protectionDigest","receiptId",
      "restoreRevision","schema","verifiedCapturedAt"] and
    .schema=="meet-backend/beta-backup-receipt/v2" and
    (.receiptId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.pointId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.captureRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.restoreRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.captureCommandDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.pointDescriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.protectionDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.captureAt|type=="number" and floor==. and .>=0) and
    (.proofDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.verifiedCapturedAt|type=="number" and floor==. and .>=0)
  ' "$receipt" >/dev/null
  local proof_path
  proof_path="$(dirname -- "$receipt")/$(jq -er '.receiptId' "$receipt").proof.json"
  [ -f "$proof_path" ] && [ ! -L "$proof_path" ] || return 1
  [ "$(sha256sum "$proof_path" | awk '{print $1}')" = \
    "$(jq -er '.proofDigest' "$receipt")" ] || return 1
  jq -e --arg capture "$(jq -er '.captureRevision' "$receipt")" \
    --arg restore "$(jq -er '.restoreRevision' "$receipt")" \
    --arg descriptor "$(jq -er '.pointDescriptorDigest' "$receipt")" \
    --arg protection "$(jq -er '.protectionDigest' "$receipt")" \
    --argjson captured "$(jq -er '.captureAt' "$receipt")" '
    type=="object" and
    (keys|sort)==["captureRevision","capturedAt","cleanup","databaseProbe",
      "identityCustody","isolated","mediaProbe","pointDescriptorDigest",
      "postFingerprint","preFingerprint","protectionDigest","restoreRevision",
      "schema"] and
    .schema=="meet-backend/beta-recurring-restore-proof/v2" and
    .captureRevision==$capture and .restoreRevision==$restore and
    .capturedAt==$captured and .pointDescriptorDigest==$descriptor and
    .protectionDigest==$protection and .identityCustody=="restore-only" and
    .isolated==true and .databaseProbe==true and .mediaProbe==true and
    .cleanup==true and
    (.preFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
    (.postFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
    .preFingerprint==.postFingerprint
  ' "$proof_path" >/dev/null
}

beta_storage_promote_local() {
  local receipt=$1 root=$2 owner=$3
  beta_storage_validate_receipt "$receipt" || beta_storage_fail receipt_invalid
  local point_id receipt_id verified_at descriptor_digest capture_at
  point_id=$(jq -er '.pointId' "$receipt")
  receipt_id=$(jq -er '.receiptId' "$receipt")
  verified_at=$(jq -er '.verifiedCapturedAt' "$receipt")
  capture_at=$(jq -er '.captureAt' "$receipt")
  descriptor_digest=$(sha256sum "$root/points/$point_id/point.json" | awk '{print $1}')
  beta_storage_local_validate_point_dir "$root/points/$point_id" "$point_id" ||
    beta_storage_fail point_unavailable
  [ "$(jq -er '.pointDescriptorDigest' "$receipt")" = "$descriptor_digest" ] ||
    beta_storage_fail receipt_descriptor_mismatch
  [ "$capture_at" = "$(jq -er '.capture.capturedAt' "$root/points/$point_id/recovery-point.json")" ] ||
    beta_storage_fail receipt_capture_time_mismatch
  [ "$(jq -er '.captureRevision' "$receipt")" = \
    "$(jq -er '.capture.sourceRevision' "$root/points/$point_id/recovery-point.json")" ] ||
    beta_storage_fail receipt_capture_revision_mismatch
  [ "$(jq -er '.captureCommandDigest' "$receipt")" = \
    "$(jq -er '.captureCommandDigest' "$root/points/$point_id/recovery-point.json")" ] ||
    beta_storage_fail receipt_capture_provenance_mismatch
  beta_storage_local_acquire "$root" promote "$owner" "promote-$receipt_id"
  local receipt_dir="$root/receipts/$point_id"
  if [ "$(uname -s)" = Linux ]; then
    install -d -m 700 "$receipt_dir"
  else
    mkdir -p "$receipt_dir"
  fi
  install -m 600 "$receipt" "$receipt_dir/$receipt_id.json"
  local proof_path destination_proof old_at=-1 old_id='' old_receipt='' old_gen=0
  proof_path="$(dirname -- "$receipt")/$(jq -er '.receiptId' "$receipt").proof.json"
  if [ -f "$root/control/verified-head.json" ]; then
    old_at=$(jq -er '.verifiedCapturedAt' "$root/control/verified-head.json") || old_at=-1
    old_id=$(jq -er '.pointId' "$root/control/verified-head.json") || old_id=
    old_receipt=$(jq -er '.receiptId' "$root/control/verified-head.json") || old_receipt=
    old_gen=$(jq -er '.generation' "$root/control/verified-head.json") || old_gen=0
  fi
  destination_proof="$receipt_dir/$receipt_id.proof.json"
  if [ "$proof_path" != "$destination_proof" ]; then
    install -m 600 "$proof_path" "$destination_proof"
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
