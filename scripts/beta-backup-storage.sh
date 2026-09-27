#!/usr/bin/env bash
set -euo pipefail

readonly BETA_STORAGE_CONNECT_TIMEOUT_SECONDS=5
readonly BETA_STORAGE_READ_TIMEOUT_SECONDS=30
readonly BETA_STORAGE_REQUEST_TIMEOUT_SECONDS=60
readonly BETA_STORAGE_READ_ATTEMPTS=2
readonly BETA_STORAGE_MAX_PAGES=100
readonly BETA_STORAGE_MULTIPART_THRESHOLD_BYTES=8388608
readonly BETA_STORAGE_MULTIPART_PART_BYTES=8388608
readonly BETA_STORAGE_MULTIPART_MAX_PARTS=10000
readonly BETA_STORAGE_MULTIPART_TOTAL_TIMEOUT_SECONDS=3600
readonly BETA_STORAGE_CONDITIONAL_PUT_MAX_BYTES=5368709120
readonly BETA_STORAGE_WRITER_CONTROL_VERSION_BYTES=65536

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

beta_storage_require_unique_json() {
  local file=$1
  command -v python3 >/dev/null 2>&1 || beta_storage_fail strict_json_unavailable
  timeout --foreground 5s python3 - "$file" <<'PY'
import json
import sys

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result

with open(sys.argv[1], encoding="utf-8") as stream:
    json.load(stream, object_pairs_hook=reject_duplicates)
PY
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
  [[ "${BETA_BACKUP_BYTE_BUDGET:-}" =~ ^[1-9][0-9]{0,18}$ ]] ||
    beta_storage_fail budget_required
  (( BETA_BACKUP_BYTE_BUDGET <= 9223372036854775807 )) ||
    beta_storage_fail budget_overflow
  [[ "${AWS_BIN:-}" = /* && -x "${AWS_BIN:-}" && ! -L "${AWS_BIN:-}" ]] ||
    beta_storage_fail pinned_aws_unavailable
  [[ "${BETA_BACKUP_AWS_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] ||
    beta_storage_fail pinned_aws_digest_missing
  [[ "${BETA_BACKUP_AWS_VERSION:-}" =~ ^2\.[0-9]+\.[0-9]+$ ]] ||
    beta_storage_fail pinned_aws_version_missing
  "$AWS_BIN" --version 2>/dev/null |
    grep -Fq "aws-cli/$BETA_BACKUP_AWS_VERSION" ||
    beta_storage_fail pinned_aws_version_mismatch
  local install_proof binary_sha256
  install_proof="${AWS_BIN%/*}/meet-backup-install-proof.json"
  [ -f "$install_proof" ] && [ ! -L "$install_proof" ] ||
    beta_storage_fail pinned_aws_proof_missing
  binary_sha256=$(sha256sum "$AWS_BIN" | awk '{print $1}')
  jq -e --arg version "$BETA_BACKUP_AWS_VERSION" \
    --arg archive "$BETA_BACKUP_AWS_SHA256" --arg binary "$binary_sha256" '
    type=="object" and
    (keys|sort)==["archiveSha256","binarySha256","schema","version"] and
    .schema=="meet-backend/beta-backup-aws-install-proof/v1" and
    .version==$version and .archiveSha256==$archive and .binarySha256==$binary
  ' "$install_proof" >/dev/null || beta_storage_fail pinned_aws_proof_invalid
  [[ "${BETA_BACKUP_SCOPED_CREDENTIALS:-}" = true ]] ||
    beta_storage_fail scoped_credentials_missing
  [ -z "${AWS_PROFILE:-}" ] &&
    [ -z "${AWS_DEFAULT_PROFILE:-}" ] &&
    [ -z "${AWS_CONFIG_FILE:-}" ] &&
    [ -z "${AWS_SHARED_CREDENTIALS_FILE:-}" ] ||
    beta_storage_fail ambient_credentials_blocked
  [ "${AWS_EC2_METADATA_DISABLED:-}" = true ] ||
    beta_storage_fail ambient_metadata_blocked
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] ||
    [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    [ -n "${AWS_ROLE_ARN:-}" ] &&
      [ -n "${AWS_WEB_IDENTITY_TOKEN_FILE:-}" ] &&
      [ -f "$AWS_WEB_IDENTITY_TOKEN_FILE" ] &&
      [ ! -L "$AWS_WEB_IDENTITY_TOKEN_FILE" ] ||
      beta_storage_fail scoped_credentials_missing
  fi
  command -v timeout >/dev/null 2>&1 || beta_storage_fail timeout_unavailable
}

beta_storage_remote() {
  [ -z "${BETA_BACKUP_STORAGE_ROOT:-}" ]
}

beta_storage_key() {
  local key=${1:-}
  [[ "$key" =~ ^(points|receipts|control)/[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
    { beta_storage_fail key_invalid; return 1; }
  [[ "$key" != *..* && "$key" != *//* ]] ||
    { beta_storage_fail key_invalid; return 1; }
  printf '%s\n' "$key"
}

beta_storage_validate_point() {
  local manifest=$1
  beta_storage_require_jq
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
  [ "$(wc -c <"$manifest")" -le 1048576 ] || return 1
  beta_storage_require_unique_json "$manifest" || return 1
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

beta_storage_descriptor_digest() {
  local descriptor=$1
  jq -cS 'del(.descriptorDigest)' "$descriptor" |
    sha256sum | awk '{print $1}'
}

beta_storage_validate_capture_proof() {
  local kind=$1 proof=$2
  beta_storage_require_jq
  [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
  [ "$(wc -c <"$proof")" -le 1048576 ] || return 1
  beta_storage_require_unique_json "$proof" || return 1
  case "$kind" in
    database)
      jq -e '
        type=="object" and
        (keys|sort)==["authStorage","demoCatalog","flyway","mediaReferences",
          "relationships","rows","schema","schemaChecks","valid","validity"] and
        .schema=="meet-backend/closed-beta-database-proof/v1" and .valid==true and
        (.validity|type=="object" and
          (keys|sort)==["auth","constraints","demoCatalog","flyway",
            "indexes","mediaReferences","relationships","schema","tables"]) and
        (.flyway|type=="object" and
          (keys|sort)==["orderedV1ToV9","successfulVersionCount"]) and
        (.schemaChecks|type=="object" and
          (keys|sort)==["exactRequiredTableCount","legacyPlaintextColumnsAbsent",
            "requiredConstraints","requiredIndexes","requiredTableCount",
            "requiredTablesAndColumns","validatedConstraints"]) and
        (.rows|type=="object" and
          (keys|sort)==["ad_block_communities","ad_block_users","ad_blocks",
            "auth_identities","communities","community_subscribers",
            "community_tags","demo_catalog_state","ingestion_runs",
            "meeting_participants","meeting_tags","meetings","otp_codes",
            "otp_rate_limit_attempts","refresh_tokens","tags","user_interests",
            "user_social_media","users"]) and
        (.relationships|type=="object" and
          (keys|sort)==["adBlockCommunities","adBlockUsers","communitySubscribers",
            "communityTags","duplicateEdgeRows","duplicateSourceKeys",
            "meetingParticipants","meetingTags","orphanRows","userInterests"]) and
        (.authStorage|type=="object" and
          (keys|sort)==["blankIdentityRows","duplicateIdentityRows",
            "identityUserOrphans","invalidIdentityRows","invalidOtpRows",
            "invalidRefreshHashes","legacyPlaintextColumnsAbsent"]) and
        (.demoCatalog|type=="object" and
          (keys|sort)==["matchingStateRows","ownershipKeyViolations",
            "ownershipTypeViolations","stateCoherent","stateRows"]) and
        (.mediaReferences|type=="object" and
          (keys|sort)==["managedReferences","nullRequiredReferences",
            "unsafeManagedReferences"])
      ' \
        "$proof" >/dev/null
      ;;
    media)
      jq -e '
        type=="object" and
        (keys|sort)==["bytes","canonicalDigest","files","referencesResolved",
          "referencesTotal","schema"] and
        .schema=="meet-backend/beta-recovery-media-proof/v1" and
        .referencesResolved==true and
        (.files|type=="number" and floor==. and .>=0) and
        (.bytes|type=="number" and floor==. and .>=0) and
        (.canonicalDigest|type=="string" and test("^[0-9a-f]{64}$")) and
        (.referencesTotal|type=="number" and floor==. and .>=0)
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
  BETA_STORAGE_LAST_ERROR=''
  output=$(mktemp)
  error=$(mktemp)
  if timeout --foreground --signal=TERM \
      "${BETA_STORAGE_REQUEST_TIMEOUT_SECONDS}s" \
      "$aws" --no-cli-pager --no-paginate --endpoint-url "$BETA_BACKUP_ENDPOINT" \
      --region "$BETA_BACKUP_REGION" \
      --cli-connect-timeout "$BETA_STORAGE_CONNECT_TIMEOUT_SECONDS" \
      --cli-read-timeout "$BETA_STORAGE_READ_TIMEOUT_SECONDS" \
      s3api "$@" >"$output" 2>"$error"; then
    cat "$output"
    status=0
  else
    status=$?
    BETA_STORAGE_LAST_ERROR=$(tr '\n' ' ' <"$error" | sed 's/[[:space:]]\+/ /g')
    : >"$output"
    printf 'BACKUP_STORAGE_BLOCKED:%s\n' \
      "$([ "$status" -eq 124 ] && echo provider_timeout || echo provider_unavailable)" >&2
  fi
  rm -f -- "$output" "$error"
  local operation=${1:-}
  case "$operation" in
    head-object)
      [[ "$BETA_STORAGE_LAST_ERROR" =~ ^An[[:space:]]error[[:space:]]occurred[[:space:]]\((404|NoSuchKey)\)[[:space:]]when[[:space:]]calling[[:space:]](the[[:space:]])?HeadObject[[:space:]]operation: ]] &&
        return 3
      ;;
    get-object)
      [[ "$BETA_STORAGE_LAST_ERROR" =~ ^An[[:space:]]error[[:space:]]occurred[[:space:]]\((404|NoSuchKey)\)[[:space:]]when[[:space:]]calling[[:space:]](the[[:space:]])?GetObject[[:space:]]operation: ]] &&
        return 3
      ;;
    get-bucket-lifecycle-configuration)
      [[ "$BETA_STORAGE_LAST_ERROR" =~ ^An[[:space:]]error[[:space:]]occurred[[:space:]]\(NoSuchLifecycleConfiguration\)[[:space:]]when[[:space:]]calling[[:space:]](the[[:space:]])?GetBucketLifecycleConfiguration[[:space:]]operation: ]] &&
        return 3
      ;;
    list-parts)
      [[ "$BETA_STORAGE_LAST_ERROR" =~ ^An[[:space:]]error[[:space:]]occurred[[:space:]]\(NoSuchUpload\)[[:space:]]when[[:space:]]calling[[:space:]](the[[:space:]])?ListParts[[:space:]]operation: ]] &&
        return 3
      ;;
  esac
  [ "$status" -eq 0 ] && return 0
  # The caller reserves status 3 for a proven provider absence.  AWS CLI
  # exit codes are not semantic provider results: in particular, an adapter
  # or permission failure may also return 3.  Normalize every unrecognized
  # failure so it cannot be mistaken for a missing object.
  return 1
}

beta_storage_aws_read() {
  local attempt status
  for attempt in $(seq 1 "$BETA_STORAGE_READ_ATTEMPTS"); do
    beta_storage_aws "$@" && {
      return 0
    }
    status=$?
    [ "$status" -eq 3 ] && return 3
    [ "$attempt" -lt "$BETA_STORAGE_READ_ATTEMPTS" ] || break
  done
  beta_storage_fail provider_read_exhausted
}

beta_storage_aws_mutation() {
  if [ -n "${BETA_STORAGE_MUTATION_STARTED_MARKER:-}" ]; then
    : >"$BETA_STORAGE_MUTATION_STARTED_MARKER"
  fi
  if beta_storage_aws "$@"; then
    return 0
  fi
  if [ -n "${BETA_STORAGE_AMBIGUOUS_MARKER:-}" ]; then
    : >"$BETA_STORAGE_AMBIGUOUS_MARKER"
  fi
  if [ -n "${BETA_STORAGE_REMOTE_WRITER_TX:-}" ] &&
    [ "${BETA_STORAGE_AMBIGUITY_MARKING:-false}" != true ]; then
    # A writer-state CAS can itself lose its response. Re-read the fenced
    # record and try to publish the durable ambiguity bit through a separate
    # guarded CAS. If that CAS is also unknown, reconciliation still refuses
    # every locked nonterminal state and requires an operator fence.
    local previous_marking=${BETA_STORAGE_AMBIGUITY_MARKING:-false}
    BETA_STORAGE_AMBIGUITY_MARKING=true
    beta_storage_remote_writer_transition ambiguous true \
      "${BETA_STORAGE_REMOTE_EXPECTED_KEYS:-[]}" >/dev/null 2>&1 || true
    BETA_STORAGE_AMBIGUITY_MARKING=$previous_marking
  fi
  return 1
}

beta_storage_aws_list_versions() {
  local key_marker='' version_marker='' page=0 response truncated
  while (( page < BETA_STORAGE_MAX_PAGES )); do
    page=$((page + 1))
    if [ -n "$key_marker" ]; then
      response=$(beta_storage_aws_read list-object-versions --bucket "$BETA_BACKUP_BUCKET" \
        --max-keys 1000 --key-marker "$key_marker" --version-id-marker "$version_marker") ||
        beta_storage_fail inventory_unavailable
    else
      response=$(beta_storage_aws_read list-object-versions --bucket "$BETA_BACKUP_BUCKET" \
        --max-keys 1000) || beta_storage_fail inventory_unavailable
    fi
    jq -e '
      type=="object" and (.Versions|type=="array") and
      (.DeleteMarkers|type=="array") and
      ((.Versions|length)+(.DeleteMarkers|length)<=1000) and
      all(.Versions[]?;
        (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
        (.VersionId|type=="string" and test("^[A-Za-z0-9._:-]{1,160}$")) and
        (.Size|type=="number" and floor==. and .>=0 and
          .<=9223372036854775807)) and
      all(.DeleteMarkers[]?;
        (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
        (.VersionId|type=="string" and test("^[A-Za-z0-9._:-]{1,160}$"))) and
      (([.Versions[]? | "v\(.Key)\u0000\(.VersionId)"] +
        [.DeleteMarkers[]? | "d\(.Key)\u0000\(.VersionId)"]) |
        unique | length ==
        ([.Versions[]? | "v\(.Key)\u0000\(.VersionId)"] +
         [.DeleteMarkers[]? | "d\(.Key)\u0000\(.VersionId)"] | length))
    ' <<<"$response" >/dev/null || beta_storage_fail inventory_invalid
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
  beta_storage_key "$key" >/dev/null || return 1
  if [ -n "$root" ]; then
    beta_storage_local_provider_put "$root" "$key" "$source"
    return
  fi
  beta_storage_require_config
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    beta_storage_fail provider_source_invalid
  local source_length
  source_length=$(wc -c <"$source" | tr -d '[:space:]')
  if (( source_length > BETA_STORAGE_MULTIPART_THRESHOLD_BYTES )); then
    beta_storage_provider_put_multipart '' "$key" "$source"
    return
  fi
  local sha output version
  sha=$(sha256sum "$source" | awk '{print $1}')
  output=$(beta_storage_aws_mutation put-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --body "$source" --metadata "sha256=$sha") || beta_storage_fail provider_put_failed
  version=$(jq -er '.VersionId // empty' <<<"$output") || beta_storage_fail provider_version_missing
  [[ "$version" != null && -n "$version" ]] || beta_storage_fail provider_version_missing
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$(wc -c <"$source")" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_provider_put_multipart() {
  local root=$1 key=$2 source=$3 if_none_match=${4:-false}
  [ -z "$root" ] || beta_storage_fail multipart_local_unsupported
  beta_storage_require_config
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    beta_storage_fail provider_source_invalid
  [ "$if_none_match" != true ] ||
    [ -n "${BETA_STORAGE_REMOTE_WRITER_TX:-}" ] ||
    beta_storage_fail conditional_multipart_writer_required
  local existing_meta='' existing_status
  if [ "$if_none_match" = true ]; then
    existing_meta=$(mktemp)
    if beta_storage_remote_head "$key" "$existing_meta"; then
      rm -f -- "$existing_meta"
      beta_storage_fail cas_conflict
    else
      existing_status=$?
      rm -f -- "$existing_meta"
      [ "$existing_status" -eq 1 ] ||
        beta_storage_fail conditional_multipart_head_failed
    fi
  fi
  local length sha scratch create_result upload_id part_number=1 offset=0
  local part_length part_file part_result etag parts='[]' complete_file result version
  local deadline=$((SECONDS + BETA_STORAGE_MULTIPART_TOTAL_TIMEOUT_SECONDS))
  length=$(wc -c <"$source" | tr -d '[:space:]')
  sha=$(sha256sum "$source" | awk '{print $1}')
  (( length > BETA_STORAGE_MULTIPART_THRESHOLD_BYTES )) ||
    { beta_storage_fail multipart_not_required; return 1; }
  scratch=$(mktemp -d)
  cleanup_multipart() {
    rm -rf -- "$scratch"
  }
  abort_multipart() {
    [ -n "$upload_id" ] || return 0
    if ! beta_storage_aws_mutation abort-multipart-upload \
      --bucket "$BETA_BACKUP_BUCKET" --key "$key" --upload-id "$upload_id" >/dev/null; then
      [ -n "${BETA_STORAGE_AMBIGUOUS_MARKER:-}" ] &&
        : >"$BETA_STORAGE_AMBIGUOUS_MARKER"
      printf 'BACKUP_STORAGE_BLOCKED:multipart_abort_unconfirmed key=%s\n' "$key" >&2
      return 1
    fi
    if beta_storage_aws_read list-parts --bucket "$BETA_BACKUP_BUCKET" \
      --key "$key" --upload-id "$upload_id" --max-parts 1000 >/dev/null; then
      [ -n "${BETA_STORAGE_AMBIGUOUS_MARKER:-}" ] &&
        : >"$BETA_STORAGE_AMBIGUOUS_MARKER"
      printf 'BACKUP_STORAGE_BLOCKED:multipart_abort_unconfirmed key=%s\n' "$key" >&2
      return 1
    else
      local abort_status=$?
      if [ "$abort_status" -ne 3 ]; then
        [ -n "${BETA_STORAGE_AMBIGUOUS_MARKER:-}" ] &&
          : >"$BETA_STORAGE_AMBIGUOUS_MARKER"
        printf 'BACKUP_STORAGE_BLOCKED:multipart_abort_verification_failed key=%s\n' \
          "$key" >&2
        return 1
      fi
    fi
    upload_id=''
  }
  multipart_fail() {
    beta_storage_fail "$1" || true
    abort_multipart || true
    trap - EXIT
    cleanup_multipart
    return 1
  }
  trap cleanup_multipart EXIT
  create_result=$(beta_storage_aws_mutation create-multipart-upload \
    --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --metadata "sha256=$sha") ||
    multipart_fail multipart_create_failed
  upload_id=$(jq -er '.UploadId // empty' <<<"$create_result") ||
    multipart_fail multipart_upload_id_missing
  [[ "$upload_id" =~ ^[A-Za-z0-9._-]+$ ]] && [ "${#upload_id}" -le 256 ] ||
    multipart_fail multipart_upload_id_invalid
  while (( offset < length )); do
    (( SECONDS < deadline )) || multipart_fail multipart_deadline
    part_length=$BETA_STORAGE_MULTIPART_PART_BYTES
    (( part_length <= length - offset )) || part_length=$((length - offset))
    (( part_number <= BETA_STORAGE_MULTIPART_MAX_PARTS )) ||
      multipart_fail multipart_part_limit
    part_file="$scratch/part-$part_number"
    dd if="$source" of="$part_file" iflag=skip_bytes,count_bytes \
      skip="$offset" count="$part_length" status=none
    [ "$(wc -c <"$part_file" | tr -d '[:space:]')" = "$part_length" ] ||
      multipart_fail multipart_part_length
    part_result=$(beta_storage_aws_mutation upload-part \
      --bucket "$BETA_BACKUP_BUCKET" --key "$key" --upload-id "$upload_id" \
      --part-number "$part_number" --body "$part_file") ||
      multipart_fail multipart_part_failed
    etag=$(jq -er '.ETag // empty' <<<"$part_result") ||
      multipart_fail multipart_etag_missing
    [[ "$etag" =~ ^\"?[A-Za-z0-9+/=_-]+\"?$ ]] ||
      multipart_fail multipart_etag_invalid
    parts=$(jq -cn --argjson parts "$parts" --arg etag "$etag" \
      --argjson number "$part_number" \
      '$parts + [{ETag:$etag,PartNumber:$number}]')
    offset=$((offset + part_length))
    part_number=$((part_number + 1))
  done
  complete_file="$scratch/complete.json"
  jq -cn --argjson parts "$parts" '{Parts:$parts}' >"$complete_file"
  (( SECONDS < deadline )) || multipart_fail multipart_deadline
  result=$(beta_storage_aws_mutation complete-multipart-upload \
    --bucket "$BETA_BACKUP_BUCKET" --key "$key" --upload-id "$upload_id" \
    --multipart-upload "file://$complete_file") ||
    multipart_fail multipart_complete_failed
  version=$(jq -er '.VersionId // empty' <<<"$result") ||
    multipart_fail provider_version_missing
  upload_id=''
  trap - EXIT
  cleanup_multipart
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$length" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_provider_put_conditional() {
  local root=$1 key=$2 source=$3 if_match=${4:-} if_none_match=${5:-false}
  beta_storage_key "$key" >/dev/null || return 1
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
  local sha output version source_length
  sha=$(sha256sum "$source" | awk '{print $1}')
  source_length=$(wc -c <"$source" | tr -d '[:space:]')
  if (( source_length > BETA_STORAGE_MULTIPART_THRESHOLD_BYTES )); then
    if [ "$if_none_match" = true ]; then
      (( source_length <= BETA_STORAGE_CONDITIONAL_PUT_MAX_BYTES )) ||
        beta_storage_fail conditional_object_too_large
      output=$(beta_storage_provider_put_multipart '' "$key" "$source" true) ||
        beta_storage_fail provider_multipart_failed
      version=$(jq -er '.versionId // empty' <<<"$output") ||
        beta_storage_fail provider_version_missing
      local verify
      verify=$(mktemp)
      beta_storage_provider_get '' "$key" "$version" "$verify" "$sha" || {
        rm -f -- "$verify"
        beta_storage_fail provider_put_unverified
      }
      rm -f -- "$verify"
      jq -cnS --arg version "$version" --arg sha "$sha" \
        --argjson length "$source_length" \
        '{versionId:$version,sha256:$sha,length:$length}'
      return
    fi
    [ -z "$if_match" ] || beta_storage_fail multipart_cas_unsupported
    output=$(beta_storage_provider_put_multipart '' "$key" "$source") ||
      beta_storage_fail provider_multipart_failed
    version=$(jq -er '.versionId // empty' <<<"$output") ||
      beta_storage_fail provider_version_missing
    local verify
    verify=$(mktemp)
    beta_storage_provider_get '' "$key" "$version" "$verify" "$sha" || {
      rm -f -- "$verify"
      beta_storage_fail provider_put_unverified
    }
    rm -f -- "$verify"
    jq -cnS --arg version "$version" --arg sha "$sha" \
      --argjson length "$source_length" \
      '{versionId:$version,sha256:$sha,length:$length}'
    return
  fi
  local args=(put-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" --body "$source"
    --metadata "sha256=$sha")
  [ -z "$if_match" ] || args+=(--if-match "$if_match")
  [ "$if_none_match" = true ] || true
  [ "$if_none_match" != true ] || args+=(--if-none-match '*')
  output=$(beta_storage_aws_mutation "${args[@]}") ||
    beta_storage_fail provider_conditional_write_failed
  version=$(jq -er '.VersionId // empty' <<<"$output") ||
    beta_storage_fail provider_version_missing
  local verify
  verify=$(mktemp)
  beta_storage_provider_get '' "$key" "$version" "$verify" "$sha" || {
    rm -f -- "$verify"
    beta_storage_fail provider_put_unverified
  }
  rm -f -- "$verify"
  jq -cnS --arg version "$version" --arg sha "$sha" \
    --argjson length "$(wc -c <"$source")" \
    '{versionId:$version,sha256:$sha,length:$length}'
}

beta_storage_source_matches_descriptor() {
  local source=$1 descriptor=$2
  local manifest_sha db_sha media_sha db_len media_len
  manifest_sha=$(sha256sum "$source/recovery-point.json" | awk '{print $1}')
  db_sha=$(sha256sum "$source/postgres.dump.age" | awk '{print $1}')
  media_sha=$(sha256sum "$source/uploads.tar.gz.age" | awk '{print $1}')
  db_len=$(wc -c <"$source/postgres.dump.age" | tr -d '[:space:]')
  media_len=$(wc -c <"$source/uploads.tar.gz.age" | tr -d '[:space:]')
  jq -e --arg point "$(jq -er '.pointId' "$source/recovery-point.json")" \
    --arg slot "$(jq -er '.slotId' "$source/recovery-point.json")" \
    --arg source_revision "$(jq -er '.capture.sourceRevision' "$source/recovery-point.json")" \
    --arg runtime "$(jq -er '.runtimeRevision' "$source/recovery-point.json")" \
    --arg contract "$(jq -er '.contractDigest' "$source/recovery-point.json")" \
    --arg proof "$(jq -er '.proofDigest' "$source/recovery-point.json")" \
    --arg command "$(jq -er '.captureCommandDigest' "$source/recovery-point.json")" \
    --arg evidence "$(jq -er '.captureEvidenceDigest' "$source/recovery-point.json")" \
    --arg manifest "$manifest_sha" --arg db_sha "$db_sha" --arg media_sha "$media_sha" \
    --argjson captured "$(jq -er '.capture.capturedAt' "$source/recovery-point.json")" \
    --argjson db_len "$db_len" --argjson media_len "$media_len" '
    .schema=="meet-backend/beta-backup-descriptor/v2" and
    .pointId==$point and .slotId==$slot and
    .capture.capturedAt==$captured and
    .capture.sourceRevision==$source_revision and
    .runtimeRevision==$runtime and .contractDigest==$contract and
    .proofDigest==$proof and .captureCommandDigest==$command and
    .captureEvidenceDigest==$evidence and .manifestDigest==$manifest and
    .ciphertexts.database.length==$db_len and
    .ciphertexts.database.sha256==$db_sha and
    .ciphertexts.uploads.length==$media_len and
    .ciphertexts.uploads.sha256==$media_sha
  ' "$descriptor" >/dev/null || return 1
  if [ -e "$source/capture-database-proof.json" ] ||
    [ -e "$source/capture-media-proof.json" ]; then
    [ -f "$source/capture-database-proof.json" ] &&
      [ -f "$source/capture-media-proof.json" ] || return 1
    local database_sha media_proof_sha database_len media_proof_len
    database_sha=$(sha256sum "$source/capture-database-proof.json" | awk '{print $1}')
    media_proof_sha=$(sha256sum "$source/capture-media-proof.json" | awk '{print $1}')
    database_len=$(wc -c <"$source/capture-database-proof.json" | tr -d '[:space:]')
    media_proof_len=$(wc -c <"$source/capture-media-proof.json" | tr -d '[:space:]')
    jq -e --arg db_sha "$database_sha" --arg media_sha "$media_proof_sha" \
      --argjson db_len "$database_len" --argjson media_len "$media_proof_len" \
      '.proofs|keys|sort==["database","media"] and
       .database.sha256==$db_sha and .database.length==$db_len and
       .media.sha256==$media_sha and .media.length==$media_len' \
      "$descriptor" >/dev/null || return 1
  else
    jq -e '.proofs|keys|length==0' "$descriptor" >/dev/null || return 1
  fi
}

beta_storage_source_matches_local_point() {
  local source=$1 directory=$2
  cmp -s "$source/recovery-point.json" "$directory/recovery-point.json" &&
    cmp -s "$source/postgres.dump.age" "$directory/postgres.dump.age" &&
    cmp -s "$source/uploads.tar.gz.age" "$directory/uploads.tar.gz.age" || return 1
  if [ -e "$source/capture-database-proof.json" ] ||
    [ -e "$source/capture-media-proof.json" ]; then
    [ -f "$source/capture-database-proof.json" ] &&
      [ -f "$source/capture-media-proof.json" ] &&
      cmp -s "$source/capture-database-proof.json" "$directory/capture-database-proof.json" &&
      cmp -s "$source/capture-media-proof.json" "$directory/capture-media-proof.json" ||
      return 1
  else
    [ ! -e "$directory/capture-database-proof.json" ] &&
      [ ! -e "$directory/capture-media-proof.json" ] || return 1
  fi
}

beta_storage_capture_reservation() {
  beta_storage_require_config
  local budget=$BETA_BACKUP_BYTE_BUDGET allowance overhead
  allowance=${BETA_BACKUP_CAPTURE_ALLOWANCE_BYTES:-$((budget / 2))}
  [[ "$allowance" =~ ^[1-9][0-9]{0,18}$ ]] ||
    { beta_storage_fail capture_allowance_invalid; return 1; }
  overhead=$((16 * BETA_STORAGE_WRITER_CONTROL_VERSION_BYTES))
  (( allowance <= 9223372036854775807 - overhead )) ||
    { beta_storage_fail capture_allowance_overflow; return 1; }
  (( allowance + overhead <= budget )) ||
    { beta_storage_fail capture_allowance_exceeds_budget; return 1; }
  (( allowance <= BETA_STORAGE_CONDITIONAL_PUT_MAX_BYTES )) ||
    { beta_storage_fail capture_allowance_exceeds_object_limit; return 1; }
  if [ -n "${BETA_BACKUP_CAPTURE_FILE_LIMIT_BYTES:-}" ]; then
    [[ "$BETA_BACKUP_CAPTURE_FILE_LIMIT_BYTES" =~ ^[1-9][0-9]{0,18}$ ]] ||
      { beta_storage_fail capture_file_limit_invalid; return 1; }
    (( BETA_BACKUP_CAPTURE_FILE_LIMIT_BYTES <= BETA_STORAGE_CONDITIONAL_PUT_MAX_BYTES )) ||
      { beta_storage_fail capture_file_limit_exceeds_object_limit; return 1; }
  fi
  printf '%s\n' "$((allowance + overhead))"
}

beta_storage_capture_allowance_check() {
  local source=$1 reservation=$2 total=0 file bytes
  [[ "$reservation" =~ ^[1-9][0-9]{0,18}$ ]] || beta_storage_fail reservation_invalid
  for file in "$source/postgres.dump.age" "$source/uploads.tar.gz.age" \
    "$source/recovery-point.json" "$source/capture-database-proof.json" \
    "$source/capture-media-proof.json"; do
    [ -f "$file" ] || continue
    bytes=$(wc -c <"$file" | tr -d '[:space:]')
    (( total <= 9223372036854775807 - bytes )) ||
      beta_storage_fail capture_allowance_overflow
    total=$((total + bytes))
  done
  (( total <= reservation )) || beta_storage_fail capture_allowance_exceeded
  printf '%s\n' "$total"
}

beta_storage_object_max_bytes() {
  local key=$1
  case "$key" in
    control/*) printf '65536\n' ;;
    points/*/point.json|points/*/recovery-point.json|points/*/capture-*.json)
      printf '1048576\n' ;;
    receipts/*) printf '1048576\n' ;;
    points/*/*.age) printf '%s\n' "$BETA_BACKUP_BYTE_BUDGET" ;;
    *) printf '%s\n' "$BETA_BACKUP_BYTE_BUDGET" ;;
  esac
}

beta_storage_remote_version_metadata() {
  local key=$1 version=$2 output=$3 size limit
  beta_storage_key "$key" >/dev/null
  [[ "$version" =~ ^[A-Za-z0-9._:-]{1,160}$ ]] ||
    beta_storage_fail provider_version_invalid
  beta_storage_aws_read head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >"$output" ||
    beta_storage_fail provider_head_failed
  limit=$(beta_storage_object_max_bytes "$key")
  jq -e --arg version "$version" '
    type=="object" and .VersionId==$version and
    (.ContentLength|type=="number" and floor==. and .>=0)
  ' "$output" >/dev/null || beta_storage_fail provider_head_invalid
  size=$(jq -er '.ContentLength' "$output")
  (( size <= limit )) || beta_storage_fail provider_object_too_large
}

beta_storage_provider_get() {
  local root=$1 key=$2 version=$3 destination=$4 expected_sha=${5:-}
  if [ -n "$root" ]; then
    beta_storage_local_provider_get "$root" "$key" "$version" "$destination" "$expected_sha"
    return
  fi
  beta_storage_require_config
  local metadata content_length actual_length
  metadata=$(mktemp)
  beta_storage_remote_version_metadata "$key" "$version" "$metadata" || {
    rm -f -- "$metadata"
    return 1
  }
  content_length=$(jq -er '.ContentLength' "$metadata")
  beta_storage_aws_read get-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" "$destination" >/dev/null ||
    { rm -f -- "$metadata"; beta_storage_fail provider_get_failed; }
  actual_length=$(wc -c <"$destination")
  rm -f -- "$metadata"
  [ "$actual_length" = "$content_length" ] ||
    beta_storage_fail provider_length_mismatch
  [ -z "$expected_sha" ] ||
    [ "$(sha256sum "$destination" | awk '{print $1}')" = "$expected_sha" ] ||
    beta_storage_fail provider_integrity_mismatch
}

beta_storage_remote_validate_object_metadata() {
  local key=$1 version=$2 expected_length=$3 expected_sha=$4 metadata
  metadata=$(mktemp)
  beta_storage_remote_version_metadata "$key" "$version" "$metadata" || {
    rm -f -- "$metadata"
    return 1
  }
  jq -e --argjson length "$expected_length" --arg sha "$expected_sha" '
    .ContentLength==$length and .Metadata.sha256==$sha
  ' "$metadata" >/dev/null || {
    rm -f -- "$metadata"
    beta_storage_fail provider_metadata_mismatch
  }
  rm -f -- "$metadata"
}

beta_storage_provider_delete() {
  local root=$1 key=$2 version=$3
  beta_storage_key "$key" >/dev/null || return 1
  if [ -n "$root" ]; then
    beta_storage_local_provider_delete "$root" "$key" "$version"
    return
  fi
  beta_storage_require_config
  beta_storage_aws_mutation delete-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >/dev/null ||
    beta_storage_fail provider_delete_failed
}

beta_storage_remote_head() {
  local key=$1 output=$2 status
  beta_storage_key "$key" >/dev/null
  if beta_storage_aws_read head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" >"$output"; then
    jq -e 'type=="object" and (.VersionId|type=="string" and length>0) and
      (.ETag|type=="string" and length>0)' "$output" >/dev/null || return 2
    return 0
  fi
  status=$?
  [ "$status" -eq 3 ] && return 1
  return 2
}

beta_storage_remote_get_json() {
  local key=$1 output=$2 version=${3:-}
  [ -n "$version" ] || beta_storage_fail version_required
  beta_storage_provider_get '' "$key" "$version" "$output" >/dev/null
  beta_storage_require_unique_json "$output" || beta_storage_fail duplicate_json_key
}

beta_storage_remote_writer_acquire() {
  local operation=$1 owner=$2 txid=$3 reservation=${4:-0} intent=${5:-}
  local expected_keys=${6:-[]} head state body etag version
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
      ((keys|sort)==["ambiguous","expectedKeys","fencingToken","generation","intentDigest",
        "phase",
        "leaseUntil","locked","operation","owner","reservationBytes","schema",
        "transactionId"] and .schema=="meet-backend/beta-backup-writer/v3") and
      (.generation|type=="number" and floor==. and .>=0) and
      (.fencingToken|type=="number" and floor==. and .>=0) and
      (.leaseUntil|type=="number" and floor==. and .>=0) and
      (.locked|type=="boolean") and (.ambiguous|type=="boolean") and
      (.reservationBytes|type=="number" and floor==. and .>=0) and
      (.intentDigest|type=="string" and test("^[0-9a-f]{64}$")) and
      (.owner|type=="string") and
      (.transactionId|type=="string")
    ' "$state" >/dev/null || beta_storage_fail writer_state_invalid
    [ "$(jq -er '.locked' "$state")" = false ] || beta_storage_fail writer_busy
    jq -e '
      .ambiguous==false and .operation=="idle" and .phase=="idle" and
      .leaseUntil==0 and .reservationBytes==0 and .expectedKeys==[] and
      .intentDigest=="0000000000000000000000000000000000000000000000000000000000000000"
    ' "$state" >/dev/null || beta_storage_fail writer_state_not_terminal
    generation=$(jq -er '.generation' "$state")
    fencing=$(jq -er '.fencingToken' "$state")
    if_match=$etag
  else
    case "$?" in
      1) if_none=true ;;
      *) rm -f -- "$head" "$state" "$body"; beta_storage_fail writer_state_unreadable ;;
    esac
  fi
  [[ "$reservation" =~ ^[0-9]+$ ]] || beta_storage_fail reservation_invalid
  [[ "$intent" =~ ^[0-9a-f]{64}$ ]] || beta_storage_fail intent_invalid
  jq -e 'type=="array" and all(.[]; type=="string" and
    test("^(points|receipts|control)/[A-Za-z0-9._/-]+$"))' <<<"$expected_keys" >/dev/null ||
    beta_storage_fail expected_keys_invalid
  jq -cnS --arg operation "$operation" --arg owner "$owner" --arg tx "$txid" \
    --arg intent "$intent" --argjson reservation "$reservation" \
    --argjson expected "$expected_keys" \
    --argjson generation "$((generation + 1))" --argjson fencing "$((fencing + 1))" \
    --argjson lease "$(($(date -u +%s) + 3600))" \
    '{schema:"meet-backend/beta-backup-writer/v3",generation:$generation,
      fencingToken:$fencing,leaseUntil:$lease,locked:true,operation:$operation,
      owner:$owner,transactionId:$tx,ambiguous:false,phase:"acquired",
      expectedKeys:$expected,reservationBytes:$reservation,intentDigest:$intent}' >"$body"
  if [ "$if_none" = true ]; then
    if beta_storage_provider_put_conditional '' control/writer.json "$body" '' true >/dev/null; then
      :
    elif beta_storage_remote_head control/writer.json "$head" &&
      beta_storage_remote_get_json control/writer.json "$state" \
        "$(jq -er '.VersionId' "$head")" &&
      jq -e --arg owner "$owner" --arg tx "$txid" --arg intent "$intent" \
        --argjson reservation "$reservation" '
        .locked==true and .owner==$owner and .transactionId==$tx and
        .intentDigest==$intent and .reservationBytes==$reservation
      ' "$state" >/dev/null; then
      BETA_STORAGE_REMOTE_WRITER_ETAG=$(jq -er '.ETag' "$head")
      BETA_STORAGE_REMOTE_WRITER_FENCING=$(jq -er '.fencingToken' "$state")
      BETA_STORAGE_REMOTE_WRITER_TX=$txid
      BETA_STORAGE_REMOTE_WRITER_OWNER=$owner
      BETA_STORAGE_REMOTE_EXPECTED_KEYS=$(jq -c '.expectedKeys' "$state")
      rm -f -- "$head" "$state" "$body"
      return 0
    else
      rm -f -- "$head" "$state" "$body"
      beta_storage_fail writer_acquire_ambiguous
    fi
  else
    if beta_storage_provider_put_conditional '' control/writer.json "$body" \
      "$if_match" false >/dev/null; then
      :
    elif beta_storage_remote_head control/writer.json "$head" &&
      beta_storage_remote_get_json control/writer.json "$state" \
        "$(jq -er '.VersionId' "$head")" &&
      jq -e --arg owner "$owner" --arg tx "$txid" --arg intent "$intent" \
        --argjson reservation "$reservation" '
        .locked==true and .owner==$owner and .transactionId==$tx and
        .intentDigest==$intent and .reservationBytes==$reservation
      ' "$state" >/dev/null; then
      BETA_STORAGE_REMOTE_WRITER_ETAG=$(jq -er '.ETag' "$head")
      BETA_STORAGE_REMOTE_WRITER_FENCING=$(jq -er '.fencingToken' "$state")
      BETA_STORAGE_REMOTE_WRITER_TX=$txid
      BETA_STORAGE_REMOTE_WRITER_OWNER=$owner
      BETA_STORAGE_REMOTE_EXPECTED_KEYS=$(jq -c '.expectedKeys' "$state")
      rm -f -- "$head" "$state" "$body"
      return 0
    else
      rm -f -- "$head" "$state" "$body"
      beta_storage_fail writer_acquire_ambiguous
    fi
  fi
  beta_storage_remote_head control/writer.json "$head" || beta_storage_fail writer_state_unreadable
  BETA_STORAGE_REMOTE_WRITER_ETAG=$(jq -er '.ETag' "$head")
  BETA_STORAGE_REMOTE_WRITER_FENCING=$((fencing + 1))
  BETA_STORAGE_REMOTE_WRITER_TX=$txid
  BETA_STORAGE_REMOTE_WRITER_OWNER=$owner
  BETA_STORAGE_REMOTE_EXPECTED_KEYS=$expected_keys
  rm -f -- "$head" "$state" "$body"
}

beta_storage_remote_writer_transition() {
  local phase=$1 ambiguous=$2 expected_keys=${3:-${BETA_STORAGE_REMOTE_EXPECTED_KEYS:-[]}}
  local owner=${BETA_STORAGE_REMOTE_WRITER_OWNER:-}
  local txid=${BETA_STORAGE_REMOTE_WRITER_TX:-}
  [ "$ambiguous" = true ] || [ "$ambiguous" = false ] ||
    beta_storage_fail writer_ambiguity_invalid
  [ "$phase" != idle ] || beta_storage_fail writer_phase_invalid
  [ -n "$owner" ] && [ -n "$txid" ] || beta_storage_fail stale_owner
  jq -e 'type=="array" and all(.[]; type=="string" and
    test("^(points|receipts|control)/[A-Za-z0-9._/-]+$"))' <<<"$expected_keys" >/dev/null ||
    beta_storage_fail expected_keys_invalid
  local head state body current_etag generation fencing
  head=$(mktemp)
  state=$(mktemp)
  body=$(mktemp)
  beta_storage_remote_head control/writer.json "$head" || {
    rm -f -- "$head" "$state" "$body"
    beta_storage_fail writer_state_unreadable
  }
  current_etag=$(jq -er '.ETag' "$head")
  [ "$current_etag" = "${BETA_STORAGE_REMOTE_WRITER_ETAG:-}" ] ||
    { rm -f -- "$head" "$state" "$body"; beta_storage_fail stale_owner; }
  beta_storage_remote_get_json control/writer.json "$state" "$(jq -er '.VersionId' "$head")"
  jq -e --arg owner "$owner" --arg tx "$txid" \
    --argjson fencing "${BETA_STORAGE_REMOTE_WRITER_FENCING:-0}" \
    '.locked==true and .owner==$owner and .transactionId==$tx and
     .fencingToken==$fencing' "$state" >/dev/null || {
    rm -f -- "$head" "$state" "$body"
    beta_storage_fail stale_owner
  }
  generation=$(jq -er '.generation' "$state")
  fencing=$(jq -er '.fencingToken' "$state")
  jq -cnS --arg operation "$(jq -er '.operation' "$state")" \
    --arg owner "$owner" --arg tx "$txid" --arg phase "$phase" \
    --arg intent "$(jq -er '.intentDigest' "$state")" \
    --argjson ambiguous "$ambiguous" --argjson expected "$expected_keys" \
    --argjson reservation "$(jq -er '.reservationBytes' "$state")" \
    --argjson generation "$((generation + 1))" --argjson fencing "$fencing" \
    --argjson lease "$(jq -er '.leaseUntil' "$state")" \
    '{schema:"meet-backend/beta-backup-writer/v3",generation:$generation,
      fencingToken:$fencing,leaseUntil:$lease,locked:true,operation:$operation,
      owner:$owner,transactionId:$tx,ambiguous:$ambiguous,phase:$phase,
      expectedKeys:$expected,reservationBytes:$reservation,intentDigest:$intent}' >"$body"
  local previous_guard=${BETA_STORAGE_WRITER_STATE_MUTATION:-false}
  BETA_STORAGE_WRITER_STATE_MUTATION=true
  if ! beta_storage_provider_put_conditional '' control/writer.json "$body" \
    "$current_etag" false >/dev/null; then
    BETA_STORAGE_WRITER_STATE_MUTATION=$previous_guard
    rm -f -- "$head" "$state" "$body"
    beta_storage_fail writer_state_transition_failed
  fi
  BETA_STORAGE_WRITER_STATE_MUTATION=$previous_guard
  beta_storage_remote_head control/writer.json "$head" ||
    { rm -f -- "$head" "$state" "$body"; beta_storage_fail writer_state_unreadable; }
  BETA_STORAGE_REMOTE_WRITER_ETAG=$(jq -er '.ETag' "$head")
  BETA_STORAGE_REMOTE_EXPECTED_KEYS=$expected_keys
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
    '.locked==true and .ambiguous==false and .owner==$owner and
     .transactionId==$tx and .fencingToken==$fencing' \
    "$state" >/dev/null || beta_storage_fail stale_owner
  generation=$(jq -er '.generation' "$state")
  fencing=$(jq -er '.fencingToken' "$state")
  jq -cnS --arg owner "$owner" --arg tx "$txid" \
    --argjson generation "$((generation + 1))" --argjson fencing "$fencing" \
    '{schema:"meet-backend/beta-backup-writer/v3",generation:$generation,
      fencingToken:$fencing,leaseUntil:0,locked:false,operation:"idle",
      owner:$owner,transactionId:$tx,ambiguous:false,phase:"idle",
      expectedKeys:[],
      reservationBytes:0,intentDigest:"0000000000000000000000000000000000000000000000000000000000000000"}' >"$body"
  local previous_guard=${BETA_STORAGE_WRITER_STATE_MUTATION:-false}
  BETA_STORAGE_WRITER_STATE_MUTATION=true
  if ! beta_storage_provider_put_conditional '' control/writer.json "$body" \
    "$current_etag" false >/dev/null; then
    BETA_STORAGE_WRITER_STATE_MUTATION=$previous_guard
    rm -f -- "$head" "$state" "$body"
    beta_storage_fail writer_release_failed
  fi
  BETA_STORAGE_WRITER_STATE_MUTATION=$previous_guard
  BETA_STORAGE_REMOTE_WRITER_ETAG=''
  BETA_STORAGE_REMOTE_WRITER_TX=''
  BETA_STORAGE_REMOTE_WRITER_OWNER=''
  BETA_STORAGE_REMOTE_WRITER_FENCING=''
  BETA_STORAGE_REMOTE_EXPECTED_KEYS=''
  rm -f -- "$head" "$state" "$body"
}

beta_storage_remote_inventory_total() {
  local budget=${1:-${BETA_BACKUP_BYTE_BUDGET:-0}} additional=${2:-0}
  local enforce_budget=${3:-true} response parts
  [[ "$budget" =~ ^[0-9]+$ ]] || beta_storage_fail budget_invalid
  [[ "$additional" =~ ^[0-9]+$ ]] || beta_storage_fail reservation_invalid
  (( budget <= 9223372036854775807 &&
    additional <= 9223372036854775807 )) ||
    beta_storage_fail budget_overflow
  response=$(beta_storage_aws_list_versions | jq -s '
    [.[].Versions[]? | (.Size // 0)] | add // 0') ||
    beta_storage_fail inventory_unavailable
  [[ "$response" =~ ^[0-9]+$ ]] || beta_storage_fail inventory_invalid
  (( response <= 9223372036854775807 )) || beta_storage_fail budget_overflow
  local key_marker='' upload_id_marker='' page=0 multipart_bytes=0
  while (( page < BETA_STORAGE_MAX_PAGES )); do
    page=$((page + 1))
    if [ -n "$key_marker" ]; then
      parts=$(beta_storage_aws_read list-multipart-uploads --bucket "$BETA_BACKUP_BUCKET" \
        --max-uploads 1000 --key-marker "$key_marker" --upload-id-marker "$upload_id_marker") ||
        beta_storage_fail multipart_inventory_unavailable
    else
      parts=$(beta_storage_aws_read list-multipart-uploads --bucket "$BETA_BACKUP_BUCKET" \
        --max-uploads 1000) || beta_storage_fail multipart_inventory_unavailable
    fi
    jq -e '
      type=="object" and (.Uploads|type=="array") and
      all(.Uploads[]?;
        (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
        (.UploadId|type=="string" and test("^[A-Za-z0-9._:-]{1,256}$")) and
        (.Initiated|type=="string" and length>0))
    ' <<<"$parts" >/dev/null || beta_storage_fail multipart_inventory_invalid
    while IFS=$'\t' read -r upload_key upload_id; do
      [ -n "$upload_key" ] && [ -n "$upload_id" ] || continue
      part_page=$(beta_storage_aws_read list-parts --bucket "$BETA_BACKUP_BUCKET" \
        --key "$upload_key" --upload-id "$upload_id" --max-parts 1000) ||
        beta_storage_fail multipart_parts_unavailable
      jq -e '
        type=="object" and (.Parts|type=="array") and
        ((.IsTruncated // false)==false) and
        all(.Parts[]?;
          (.PartNumber|type=="number" and floor==. and .>=1 and .<=10000) and
          (.Size|type=="number" and floor==. and .>=0 and
            .<=9223372036854775807) and
          (.ETag|type=="string" and length>0)) and
        ([.Parts[]?.PartNumber] | unique | length ==
          ([.Parts[]?.PartNumber] | length))
      ' <<<"$part_page" >/dev/null ||
        beta_storage_fail multipart_parts_incomplete
      part_bytes=$(jq -r '[.Parts[]?.Size] | add // 0' <<<"$part_page")
      [[ "$part_bytes" =~ ^[0-9]+$ ]] || beta_storage_fail multipart_parts_invalid
      (( part_bytes <= 9223372036854775807 - multipart_bytes )) ||
        beta_storage_fail budget_overflow
      multipart_bytes=$((multipart_bytes + part_bytes))
    done < <(jq -r '.Uploads[]? | [.Key,.UploadId]|@tsv' <<<"$parts")
    [ "$(jq -er '.IsTruncated // false' <<<"$parts")" = true ] || break
    key_marker=$(jq -er '.NextKeyMarker // empty' <<<"$parts")
    upload_id_marker=$(jq -er '.NextUploadIdMarker // empty' <<<"$parts")
    [ -n "$key_marker" ] && [ -n "$upload_id_marker" ] ||
      beta_storage_fail multipart_pagination_invalid
  done
  (( page < BETA_STORAGE_MAX_PAGES )) || beta_storage_fail multipart_pagination_limit
  (( multipart_bytes <= 9223372036854775807 - response )) ||
    beta_storage_fail budget_overflow
  local total=$((response + multipart_bytes))
  (( additional <= 9223372036854775807 - total )) ||
    beta_storage_fail budget_overflow
  total=$((total + additional))
  if [ "$enforce_budget" = true ]; then
    (( total <= budget )) || beta_storage_fail budget_exceeded
  fi
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
  local txid
  if [ "${BETA_STORAGE_PREACQUIRED_CAPTURE:-false}" = true ]; then
    txid=${BETA_STORAGE_REMOTE_WRITER_TX:-}
  else
    txid="publish-$point_id-$(date -u +%s)"
  fi
  local reserve
  reserve=$(( $(wc -c <"$source/postgres.dump.age") +
    $(wc -c <"$source/uploads.tar.gz.age") +
    $(wc -c <"$source/recovery-point.json") + 16 * 65536 ))
  for proof in "$source/capture-database-proof.json" \
    "$source/capture-media-proof.json"; do
    [ -f "$proof" ] && reserve=$((reserve + $(wc -c <"$proof")))
  done
  local intent_digest
  intent_digest=$(printf '%s\0%s\0%s\0%s' "$point_id" "$slot" \
    "$captured_at" "$reserve" | sha256sum | awk '{print $1}')
  local expected_keys
  expected_keys=$(jq -cn --arg point "$point_id" '
    ["points/"+$point+"/postgres.dump.age",
     "points/"+$point+"/uploads.tar.gz.age",
     "points/"+$point+"/recovery-point.json",
     "points/"+$point+"/point.json",
     "control/capture-head.json"]')
  if [ -e "$source/capture-database-proof.json" ] &&
    [ -e "$source/capture-media-proof.json" ]; then
    expected_keys=$(jq -c --arg point "$point_id" \
      '. + ["points/"+$point+"/capture-database-proof.json",
        "points/"+$point+"/capture-media-proof.json"]' <<<"$expected_keys")
  fi
  local writer_control_reserve=$((4 * BETA_STORAGE_WRITER_CONTROL_VERSION_BYTES))
  local preacquired=${BETA_STORAGE_PREACQUIRED_CAPTURE:-false}
  if [ "$preacquired" = true ]; then
    [ "$txid" = "${BETA_STORAGE_REMOTE_WRITER_TX:-}" ] ||
      beta_storage_fail capture_writer_mismatch
    [[ "${BETA_STORAGE_CAPTURE_RESERVATION_BYTES:-}" =~ ^[1-9][0-9]{0,18}$ ]] ||
      beta_storage_fail capture_reservation_missing
    (( reserve + writer_control_reserve <= BETA_STORAGE_CAPTURE_RESERVATION_BYTES )) ||
      beta_storage_fail capture_reservation_exceeded
    beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" 0 false >/dev/null
  else
    beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
      "$((reserve + writer_control_reserve))" >/dev/null
    beta_storage_remote_writer_acquire publish "$owner" "$txid" \
      "$reserve" "$intent_digest" "$expected_keys"
  fi
  local cleanup=true release_allowed=true scratch
  scratch=$(mktemp -d)
  export BETA_STORAGE_AMBIGUOUS_MARKER="$scratch/ambiguous"
  export BETA_STORAGE_MUTATION_STARTED_MARKER="$scratch/mutation-started"
  cleanup_remote_publish() {
    local status=$?
    trap - RETURN
    if [ -e "$BETA_STORAGE_AMBIGUOUS_MARKER" ] ||
      { [ "$status" -ne 0 ] && [ -e "$BETA_STORAGE_MUTATION_STARTED_MARKER" ]; }; then
      release_allowed=false
      printf 'BACKUP_STORAGE_BLOCKED:ambiguous_transaction_retained tx=%s\n' "$txid" >&2
    fi
    if [ "$cleanup" = true ]; then
      rm -rf -- "$scratch" || status=1
    fi
    if [ "$cleanup" = true ] && [ "$release_allowed" = true ]; then
      beta_storage_remote_writer_release "$owner" "$txid" || status=1
    fi
    return "$status"
  }
  trap cleanup_remote_publish RETURN
  local existing_head="$scratch/existing-point.meta"
  local existing_descriptor="$scratch/existing-point.json"
  local duplicate_scratch="$scratch/duplicate"
  if beta_storage_remote_head "points/$point_id/point.json" "$existing_head"; then
    local existing_point_version
    existing_point_version=$(jq -er '.VersionId' "$existing_head")
    beta_storage_remote_get_json "points/$point_id/point.json" "$existing_descriptor" \
      "$existing_point_version"
    mkdir "$duplicate_scratch"
    beta_storage_remote_validate_descriptor "$point_id" "$existing_descriptor" \
      "$duplicate_scratch" false ||
      beta_storage_fail duplicate_point_conflict
    beta_storage_source_matches_descriptor "$source" "$existing_descriptor" ||
      beta_storage_fail duplicate_point_conflict
    local capture_head="$scratch/existing-capture-head.json"
    local capture_head_meta="$scratch/existing-capture-head.meta"
    if beta_storage_remote_head control/capture-head.json "$capture_head_meta"; then
      beta_storage_remote_get_json control/capture-head.json "$capture_head" \
        "$(jq -er '.VersionId' "$capture_head_meta")"
      jq -e --arg point "$point_id" --arg version "$existing_point_version" \
        --arg digest "$(beta_storage_descriptor_digest "$existing_descriptor")" \
        --argjson captured "$captured_at" '
        type=="object" and
        .schema=="meet-backend/beta-backup-head/v2" and
        .pointId==$point and .capturedAt==$captured and
        .descriptorVersion==$version and .descriptorDigest==$digest
      ' "$capture_head" >/dev/null ||
        beta_storage_fail duplicate_point_conflict
      beta_storage_remote_writer_release "$owner" "$txid"
      cleanup=false
      trap - RETURN
      rm -rf -- "$scratch"
      unset BETA_STORAGE_AMBIGUOUS_MARKER
      unset BETA_STORAGE_MUTATION_STARTED_MARKER
      printf 'storage_publish=idempotent point_id=%s\n' "$point_id"
      return 0
    fi
    [ "$?" -eq 1 ] || beta_storage_fail capture_head_read_failed
    beta_storage_fail duplicate_point_uncommitted
  else
    case "$?" in
      1) : ;;
      *) beta_storage_fail point_descriptor_read_failed ;;
    esac
  fi
  beta_storage_remote_writer_transition publishing false "$expected_keys"
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$((reserve + writer_control_reserve))" >/dev/null
  local db_json media_json manifest_json db_version media_version manifest_version
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
    --arg source "$(jq -er '.capture.sourceRevision' "$source/recovery-point.json")" \
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
    --arg manifest "$(sha256sum "$source/recovery-point.json" | awk '{print $1}')" \
    --argjson proofs "$proofs_json" \
    '{schema:"meet-backend/beta-backup-descriptor/v2",pointId:$id,slotId:$slot,
      capture:{capturedAt:$captured,sourceRevision:$source},runtimeRevision:$runtime,
      captureCommandDigest:$command,captureEvidenceDigest:$evidence,
      contractDigest:$contract,proofDigest:$proof,
      ciphertexts:{database:{length:$dblen,sha256:$dbsha},
        uploads:{length:$medielen,sha256:$mediasha}},
      versions:{database:$dbversion,manifest:$manifestversion,uploads:$mediaversion},
      proofs:$proofs,manifestDigest:$manifest,
      descriptorDigest:"0000000000000000000000000000000000000000000000000000000000000000"}' \
    >"$descriptor"
  local descriptor_digest descriptor_with_digest="$scratch/point-with-digest.json"
  descriptor_digest=$(beta_storage_descriptor_digest "$descriptor")
  jq --arg digest "$descriptor_digest" '.descriptorDigest=$digest' "$descriptor" \
    >"$descriptor_with_digest"
  mv -f -- "$descriptor_with_digest" "$descriptor"
  local descriptor_result descriptor_version
  descriptor_result=$(beta_storage_provider_put_conditional '' \
    "points/$point_id/point.json" "$descriptor" '' true)
  descriptor_version=$(jq -er '.versionId' <<<"$descriptor_result")
  local head="$scratch/capture-head.json" generation=0 head_meta="$scratch/head-meta.json"
  local head_etag='' head_version=''
  if beta_storage_remote_head control/capture-head.json "$head_meta"; then
    head_etag=$(jq -er '.ETag' "$head_meta")
    head_version=$(jq -er '.VersionId' "$head_meta")
    beta_storage_remote_get_json control/capture-head.json "$head" "$head_version"
    generation=$(jq -er '.generation // 0' "$head" 2>/dev/null) || generation=0
  else
    case "$?" in
      1) : ;;
      *) beta_storage_fail capture_head_read_failed ;;
    esac
  fi
  jq -cnS --arg id "$point_id" --argjson captured "$captured_at" \
    --argjson generation "$((generation + 1))" --arg digest "$descriptor_digest" \
    --arg descriptorVersion "$descriptor_version" \
    '{schema:"meet-backend/beta-backup-head/v2",generation:$generation,
      pointId:$id,capturedAt:$captured,descriptorDigest:$digest,
      descriptorVersion:$descriptorVersion}' >"$head"
  local committed_head
  committed_head=$(beta_storage_provider_put_conditional '' control/capture-head.json "$head" \
    "$head_etag" "$([ -z "$head_etag" ] && echo true || echo false)")
  local committed_head_version
  committed_head_version=$(jq -er '.versionId' <<<"$committed_head")
  beta_storage_remote_get_json control/capture-head.json "$scratch/committed-head.json" \
    "$committed_head_version"
  cmp -s "$head" "$scratch/committed-head.json" ||
    beta_storage_fail capture_head_commit_ambiguous
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$writer_control_reserve" >/dev/null
  cleanup=false
  beta_storage_remote_writer_release "$owner" "$txid"
  trap - RETURN
  rm -rf -- "$scratch"
  unset BETA_STORAGE_AMBIGUOUS_MARKER
  unset BETA_STORAGE_MUTATION_STARTED_MARKER
  printf 'storage_publish=provider_committed point_id=%s manifest_last=true\n' "$point_id"
}

beta_storage_remote_validate_descriptor() {
  local point_id=$1 descriptor=$2 scratch=$3 verify_payloads=${4:-true}
  beta_storage_require_unique_json "$descriptor" || beta_storage_fail duplicate_json_key
  jq -e --arg id "$point_id" '
    type=="object" and
    (keys|sort)==["capture","captureCommandDigest","captureEvidenceDigest",
      "ciphertexts","contractDigest","descriptorDigest","manifestDigest",
      "pointId","proofDigest","proofs","runtimeRevision","slotId","schema",
      "versions"] and
    .schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.manifestDigest|type=="string" and test("^[0-9a-f]{64}$")) and
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
  [ "$(beta_storage_descriptor_digest "$descriptor")" = \
    "$(jq -er '.descriptorDigest' "$descriptor")" ] ||
    beta_storage_fail descriptor_digest_mismatch
  [ "$(sha256sum "$manifest" | awk '{print $1}')" = "$(jq -er '.manifestDigest' "$descriptor")" ] ||
    beta_storage_fail descriptor_manifest_binding
  [ "$(jq -er '.pointId' "$manifest")" = "$point_id" ] ||
    beta_storage_fail descriptor_point_mismatch
  jq -e --arg slot "$(jq -er '.slotId' "$manifest")" \
    --argjson captured "$(jq -er '.capture.capturedAt' "$manifest")" \
    --arg source "$(jq -er '.capture.sourceRevision' "$manifest")" \
    --arg runtime "$(jq -er '.runtimeRevision' "$manifest")" \
    --arg contract "$(jq -er '.contractDigest' "$manifest")" \
    --arg proof "$(jq -er '.proofDigest' "$manifest")" \
    --arg command "$(jq -er '.captureCommandDigest' "$manifest")" \
    --arg evidence "$(jq -er '.captureEvidenceDigest' "$manifest")" '
    .slotId==$slot and .capture.capturedAt==$captured and
    .capture.sourceRevision==$source and .runtimeRevision==$runtime and
    .contractDigest==$contract and .proofDigest==$proof and
    .captureCommandDigest==$command and .captureEvidenceDigest==$evidence
  ' "$descriptor" >/dev/null || beta_storage_fail descriptor_provenance_mismatch
  if [ "$verify_payloads" = true ]; then
    beta_storage_provider_get '' "points/$point_id/postgres.dump.age" \
      "$(jq -er '.versions.database' "$descriptor")" "$db" \
      "$(jq -er '.ciphertexts.database.sha256' "$descriptor")" >/dev/null
    beta_storage_provider_get '' "points/$point_id/uploads.tar.gz.age" \
      "$(jq -er '.versions.uploads' "$descriptor")" "$media" \
      "$(jq -er '.ciphertexts.uploads.sha256' "$descriptor")" >/dev/null
  else
    beta_storage_remote_validate_object_metadata \
      "points/$point_id/postgres.dump.age" \
      "$(jq -er '.versions.database' "$descriptor")" \
      "$(jq -er '.ciphertexts.database.length' "$descriptor")" \
      "$(jq -er '.ciphertexts.database.sha256' "$descriptor")"
    beta_storage_remote_validate_object_metadata \
      "points/$point_id/uploads.tar.gz.age" \
      "$(jq -er '.versions.uploads' "$descriptor")" \
      "$(jq -er '.ciphertexts.uploads.length' "$descriptor")" \
      "$(jq -er '.ciphertexts.uploads.sha256' "$descriptor")"
  fi
  if [ "$verify_payloads" = true ]; then
    [ "$(wc -c <"$db")" = "$(jq -er '.ciphertexts.database.length' "$descriptor")" ] ||
      beta_storage_fail descriptor_database_length
    [ "$(wc -c <"$media")" = "$(jq -er '.ciphertexts.uploads.length' "$descriptor")" ] ||
      beta_storage_fail descriptor_uploads_length
  fi
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

beta_storage_remote_point_graph_state() {
  local point_id=$1 inventory=$2 scratch=$3
  local descriptor_version descriptor_path error index=0
  while IFS= read -r descriptor_version; do
    [ -n "$descriptor_version" ] || continue
    index=$((index + 1))
    descriptor_path="$scratch/graph-descriptor-$index.json"
    if error=$(beta_storage_provider_get '' "points/$point_id/point.json" \
      "$descriptor_version" "$descriptor_path" 2>&1); then
      :
    else
      [[ "$error" =~ BACKUP_STORAGE_BLOCKED:(provider_|inventory_|multipart_|pagination_|budget_) ]] &&
        return 2
      continue
    fi
    if error=$(beta_storage_remote_validate_descriptor "$point_id" \
      "$descriptor_path" "$scratch" false 2>&1); then
      return 0
    fi
    [[ "$error" =~ BACKUP_STORAGE_BLOCKED:(provider_|inventory_|multipart_|pagination_|budget_) ]] &&
      return 2
  done < <(jq -r --arg point "$point_id" '
    .[].Versions[]? | select(.Key=="points/"+$point+"/point.json") |
    .VersionId
  ' <<<"$inventory")
  return 1
}

beta_storage_remote_require_safety() {
  local status_file=$1 watermark_file=$2 environment=$3 now=$4
  local script_dir
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  [ -f "$status_file" ] && [ ! -L "$status_file" ] ||
    beta_storage_fail safety_snapshot_missing
  [ -f "$watermark_file" ] && [ ! -L "$watermark_file" ] ||
    beta_storage_fail safety_watermark_missing
  # shellcheck source=beta-backup-policy.sh
  source "$script_dir/beta-backup-policy.sh"
  beta_backup_require_admission "$status_file" "$now" "$environment" "$watermark_file" ||
    beta_storage_fail safety_snapshot_invalid
}

beta_storage_remote_build_status_once() {
  local output=$1 environment=$2 now=$3 scratch
  beta_storage_require_config
  scratch=$(mktemp -d)
  cleanup_status() {
    local status=$?
    trap - RETURN
    rm -rf -- "$scratch" || status=1
    return "$status"
  }
  trap cleanup_status RETURN
  local capture_state=MISSING capture_id=null capture_at=null
  local verified_state=MISSING verified_id=null verified_at=null generation=0
  local authority_files=()
  read_head() {
    local kind=$1
    local key meta body descriptor point descriptor_version
    key="control/${kind}-head.json"
    meta="$scratch/$kind-head.meta"
    body="$scratch/$kind-head.json"
    if beta_storage_remote_head "$key" "$meta"; then
      :
    else
      head_status=$?
      [ "$head_status" -eq 1 ] || beta_storage_fail authority_read_failed
      return 1
    fi
    beta_storage_remote_get_json "$key" "$body" "$(jq -er '.VersionId' "$meta")"
    authority_files+=("$body")
    if [ "$kind" = capture ]; then
      jq -e '
        type=="object" and
        (keys|sort)==["capturedAt","descriptorDigest","descriptorVersion",
          "generation","pointId","schema"] and
        .schema=="meet-backend/beta-backup-head/v2" and
        (.generation|type=="number" and floor==.) and
        (.capturedAt|type=="number" and floor==.) and
        (.pointId|type=="string") and
        (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
        (.descriptorVersion|type=="string" and length>0)
      ' "$body" >/dev/null || beta_storage_fail capture_head_invalid
      point=$(jq -er '.pointId' "$body")
      descriptor_version=$(jq -er '.descriptorVersion' "$body")
      descriptor="$scratch/$kind-descriptor.json"
      beta_storage_remote_get_json "points/$point/point.json" "$descriptor" \
        "$descriptor_version"
      beta_storage_remote_validate_descriptor "$point" "$descriptor" "$scratch" false
      [ "$(beta_storage_descriptor_digest "$descriptor")" = \
        "$(jq -er '.descriptorDigest' "$body")" ] ||
        beta_storage_fail capture_descriptor_binding
      [ "$(jq -er '.capture.capturedAt' "$descriptor")" = \
        "$(jq -er '.capturedAt' "$body")" ] ||
        beta_storage_fail capture_time_binding
      capture_state=VALID
      capture_id=$point
      capture_at=$(jq -er '.capture.capturedAt' "$descriptor")
      (( capture_at <= now )) || beta_storage_fail capture_time_future
      (( generation < $(jq -er '.generation' "$body") )) &&
        generation=$(jq -er '.generation' "$body")
    else
      jq -e '
        type=="object" and
        (keys|sort)==["descriptorDigest","descriptorVersion","generation",
          "pointId","proofVersion","receiptId","receiptVersion",
          "schema","verifiedCapturedAt"] and
        .schema=="meet-backend/beta-backup-verified-head/v2" and
        (.generation|type=="number" and floor==.) and
        (.pointId|type=="string") and (.receiptId|type=="string") and
        (.verifiedCapturedAt|type=="number" and floor==.) and
        (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
        (.descriptorVersion|type=="string" and length>0) and
        (.receiptVersion|type=="string" and length>0) and
        (.proofVersion|type=="string" and length>0)
      ' "$body" >/dev/null || beta_storage_fail verified_head_invalid
      point=$(jq -er '.pointId' "$body")
      descriptor_version=$(jq -er '.descriptorVersion' "$body")
      descriptor="$scratch/$kind-descriptor.json"
      beta_storage_remote_get_json "points/$point/point.json" "$descriptor" \
        "$descriptor_version"
      beta_storage_remote_validate_descriptor "$point" "$descriptor" "$scratch" false
      [ "$(beta_storage_descriptor_digest "$descriptor")" = \
        "$(jq -er '.descriptorDigest' "$body")" ] ||
        beta_storage_fail verified_descriptor_binding
      [ "$(jq -er '.capture.capturedAt' "$descriptor")" = \
        "$(jq -er '.verifiedCapturedAt' "$body")" ] ||
        beta_storage_fail verified_time_binding
      receipt="$scratch/receipt.json"
      beta_storage_remote_get_json "receipts/$point/$(jq -er '.receiptId' "$body").json" \
        "$receipt" "$(jq -er '.receiptVersion' "$body")"
      proof="$scratch/$(jq -er '.receiptId' "$body").proof.json"
      beta_storage_remote_get_json \
        "receipts/$point/$(jq -er '.receiptId' "$body").proof.json" \
        "$proof" "$(jq -er '.proofVersion' "$body")"
      beta_storage_validate_receipt "$receipt" || beta_storage_fail receipt_invalid
      jq -e --arg point "$point" \
        --arg descriptor "$(beta_storage_descriptor_digest "$descriptor")" \
        --arg source "$(jq -er '.capture.sourceRevision' "$descriptor")" \
        --arg command "$(jq -er '.captureCommandDigest' "$descriptor")" \
        --argjson captured "$(jq -er '.capture.capturedAt' "$descriptor")" \
        --argjson verified "$(jq -er '.verifiedCapturedAt' "$body")" \
        '.pointId==$point and .pointDescriptorDigest==$descriptor and
         .captureAt==$captured and .verifiedCapturedAt==$captured and
         .verifiedCapturedAt==$verified and .captureRevision==$source and
         .captureCommandDigest==$command' "$receipt" >/dev/null ||
        beta_storage_fail receipt_descriptor_binding
      verified_state=VALID
      verified_id=$point
      verified_at=$(jq -er '.capture.capturedAt' "$descriptor")
      (( verified_at <= now )) || beta_storage_fail verified_time_future
      (( generation < $(jq -er '.generation' "$body") )) &&
        generation=$(jq -er '.generation' "$body")
    fi
    return 0
  }
  if read_head capture; then
    :
  else
    capture_status=$?
    [ "$capture_status" -eq 1 ] || beta_storage_fail authority_read_failed
  fi
  if read_head verified; then
    :
  else
    verified_status=$?
    [ "$verified_status" -eq 1 ] || beta_storage_fail authority_read_failed
  fi
  local authority_changed=false final_meta head_status
  for kind in capture verified; do
    final_meta="$scratch/$kind-head-final.meta"
    if [ -f "$scratch/$kind-head.meta" ]; then
      if beta_storage_remote_head "control/$kind-head.json" "$final_meta"; then
        cmp -s "$scratch/$kind-head.meta" "$final_meta" || authority_changed=true
      else
        head_status=$?
        [ "$head_status" -eq 1 ] || beta_storage_fail authority_read_failed
        authority_changed=true
      fi
    elif beta_storage_remote_head "control/$kind-head.json" "$final_meta"; then
      authority_changed=true
    else
      head_status=$?
      [ "$head_status" -eq 1 ] || beta_storage_fail authority_read_failed
    fi
  done
  [ "$authority_changed" = false ] || {
    cleanup_status
    return 75
  }
  local authority_digest
  authority_digest=$(
    for file in "${authority_files[@]}"; do
      sha256sum "$file" | awk '{print $1}'
    done | sha256sum | awk '{print $1}'
  )
  jq -cnS --arg environment "$environment" --arg digest "$authority_digest" \
    --arg captureState "$capture_state" --arg verifiedState "$verified_state" \
    --arg captureId "$capture_id" --arg verifiedId "$verified_id" \
    --argjson observed "$now" --argjson generation "$generation" \
    --argjson captureAt "$capture_at" --argjson verifiedAt "$verified_at" \
    '{schema:"meet-backend/beta-backup-status/v1",environment:$environment,
      observedAt:$observed,authorityGeneration:$generation,authorityDigest:$digest,
      capture:{state:$captureState,id:(if $captureId=="null" then null else $captureId end),
        capturedAt:(if $captureAt==null then null else $captureAt end)},
      verified:{state:$verifiedState,id:(if $verifiedId=="null" then null else $verifiedId end),
        capturedAt:(if $verifiedAt==null then null else $verifiedAt end)}}' |
    install -m 600 /dev/stdin "$output"
  cleanup_status
}

beta_storage_remote_build_status() {
  local output=$1 environment=$2 now=$3 attempt status
  for attempt in 1 2; do
    beta_storage_remote_build_status_once "$output" "$environment" "$now" && return 0
    status=$?
    [ "$status" -eq 75 ] || return "$status"
  done
  beta_storage_fail authority_changed
}

beta_storage_promote_remote() {
  local receipt=$1 receipt_key=$2 owner=$3 probe_binding=${4:-}
  local provenance=${5:-} scratch
  scratch=$(mktemp -d)
  export BETA_STORAGE_AMBIGUOUS_MARKER="$scratch/ambiguous"
  export BETA_STORAGE_MUTATION_STARTED_MARKER="$scratch/mutation-started"
  local acquired=false txid=''
  cleanup_remote_promotion() {
    local status=$?
    trap - RETURN
    if [ -e "$BETA_STORAGE_AMBIGUOUS_MARKER" ] ||
      { [ "$status" -ne 0 ] && [ -e "$BETA_STORAGE_MUTATION_STARTED_MARKER" ]; }; then
      printf 'BACKUP_STORAGE_BLOCKED:ambiguous_transaction_retained tx=%s\n' \
        "${txid:-unknown}" >&2
    elif [ "$acquired" = true ]; then
      beta_storage_remote_writer_release "$owner" "$txid" || status=1
    fi
    rm -rf -- "$scratch" || status=1
    unset BETA_STORAGE_AMBIGUOUS_MARKER
    unset BETA_STORAGE_MUTATION_STARTED_MARKER
    return "$status"
  }
  trap cleanup_remote_promotion RETURN
  if [ -n "$receipt_key" ]; then
    beta_storage_remote_head "$receipt_key" "$scratch/receipt.meta" ||
      beta_storage_fail receipt_read_failed
    beta_storage_remote_get_json "$receipt_key" "$scratch/receipt.json" \
      "$(jq -er '.VersionId' "$scratch/receipt.meta")"
    receipt="$scratch/receipt.json"
    local receipt_id_from_remote
    receipt_id_from_remote=$(jq -er '.receiptId' "$receipt")
    local proof_key
    proof_key="receipts/$(jq -er '.pointId' "$receipt")/$receipt_id_from_remote.proof.json"
    beta_storage_remote_head "$proof_key" "$scratch/proof.meta" ||
      beta_storage_fail proof_read_failed
    beta_storage_remote_get_json \
      "$proof_key" "$scratch/$receipt_id_from_remote.proof.json" \
      "$(jq -er '.VersionId' "$scratch/proof.meta")"
  fi
  beta_storage_validate_receipt "$receipt" || beta_storage_fail receipt_invalid
  [ -n "$provenance" ] && [ -f "$provenance" ] && [ ! -L "$provenance" ] ||
    beta_storage_fail promotion_provenance_missing
  local promotion_adapter_digest
  promotion_adapter_digest=$(sha256sum \
    "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/query-beta-recurring-promotion.sh" |
    awk '{print $1}')
  jq -e --arg receipt "$(sha256sum "$receipt" | awk '{print $1}')" \
    --arg reviewer "$(jq -er '.reviewerId' "$receipt")" \
    --arg receiptProtection "$(jq -er '.protectionDigest' "$receipt")" \
    --arg adapterDigest "$promotion_adapter_digest" '
    type=="object" and
    (keys|sort)==["adapter","adapterDigest","apiEvidenceDigest","environment","policyDigest",
      "postProbeArtifactDigest","postProbeArtifactId","postProbeJobId",
      "postProbeSuccessful","protectedRestore","receiptArtifactDigest",
      "receiptArtifactId","receiptDigest","receiptProtectionDigest",
      "protectionDigest","restoreJobId","reviewerId","runRef","schema",
      "workflowRunId"] and
    .schema=="meet-backend/beta-recurring-promotion-evidence/v1" and
    .adapter=="scripts/query-beta-recurring-promotion.sh" and
    .adapterDigest==$adapterDigest and
    .receiptDigest==$receipt and .reviewerId==$reviewer and
    .receiptProtectionDigest==$receiptProtection and
    .protectionDigest == .receiptProtectionDigest and
    .runRef=="refs/heads/master" and .environment=="closed-beta-recurring-restore" and
    .protectedRestore==true and .postProbeSuccessful==true and
    (.workflowRunId|type=="number" and .workflowRunId>0) and
    (.restoreJobId|type=="number" and .restoreJobId>0) and
    (.postProbeJobId|type=="number" and .postProbeJobId>0) and
    (.reviewerId|test("^[0-9]+$")) and
    (.policyDigest|test("^[0-9a-f]{64}$")) and
    (.protectionDigest|test("^[0-9a-f]{64}$")) and
    (.receiptProtectionDigest|test("^[0-9a-f]{64}$")) and
    (.apiEvidenceDigest|test("^[0-9a-f]{64}$")) and
    (.receiptArtifactId|type=="number" and floor==. and .>0) and
    (.receiptArtifactDigest|test("^sha256:[0-9a-f]{64}$")) and
    (.postProbeArtifactId|type=="number" and floor==. and .>0) and
    (.postProbeArtifactDigest|test("^sha256:[0-9a-f]{64}$"))
  ' "$provenance" >/dev/null || beta_storage_fail promotion_provenance_invalid
  [ "$(jq -er '.reviewerId' "$provenance")" = "$(jq -er '.reviewerId' "$receipt")" ] ||
    beta_storage_fail promotion_reviewer_mismatch
  local point_id receipt_id descriptor proof_source proof_digest
  point_id=$(jq -er '.pointId' "$receipt")
  receipt_id=$(jq -er '.receiptId' "$receipt")
  if [ -z "$receipt_key" ]; then
    proof_source="$(dirname "$receipt")/$receipt_id.proof.json"
    [ -s "$proof_source" ] || proof_source="$(dirname "$receipt")/$(basename "$receipt" .json).proof.json"
    cp -- "$proof_source" "$scratch/$receipt_id.proof.json"
  fi
  local proof="$scratch/$receipt_id.proof.json"
  [ -s "$proof" ] || beta_storage_fail receipt_proof_missing
  proof_digest=$(sha256sum "$proof" | awk '{print $1}')
  [ "$proof_digest" = "$(jq -er '.proofDigest' "$receipt")" ] ||
    beta_storage_fail receipt_proof_binding
  if [ -n "$probe_binding" ]; then
    [ -f "$probe_binding" ] && [ ! -L "$probe_binding" ] || beta_storage_fail probe_binding_missing
    beta_storage_require_unique_json "$probe_binding" ||
      beta_storage_fail probe_binding_ambiguous
    jq -e --arg receipt "$receipt_id" --arg point "$point_id" \
      --arg proofDigest "$proof_digest" \
      --arg descriptor "$(jq -er '.pointDescriptorDigest' "$receipt")" '
      type=="object" and
      (keys|sort)==["pointDescriptorDigest","pointId","postProbeDigest",
        "postProbeVersion","postRuntimeFingerprint","preProbeDigest",
        "preProbeVersion","preRuntimeFingerprint","receiptId",
        "restorePostFingerprint","restorePreFingerprint","restoreProofDigest",
        "schema"] and
      .schema=="meet-backend/beta-recurring-probe-binding/v2" and
      .receiptId==$receipt and .pointId==$point and
      .pointDescriptorDigest==$descriptor and
      (.preProbeDigest|type=="string" and test("^[0-9a-f]{64}$")) and
      (.postProbeDigest|type=="string" and test("^[0-9a-f]{64}$")) and
      .preProbeVersion==.preProbeDigest and .postProbeVersion==.postProbeDigest and
      (.preRuntimeFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
      (.postRuntimeFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
      .preRuntimeFingerprint == .postRuntimeFingerprint and
      (.restoreProofDigest|type=="string" and test("^[0-9a-f]{64}$")) and
      .restoreProofDigest == $proofDigest and
      (.restorePreFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
      (.restorePostFingerprint|type=="string" and test("^[0-9a-f]{64}$")) and
      .restorePreFingerprint == .restorePostFingerprint
    ' "$probe_binding" >/dev/null || beta_storage_fail probe_binding_invalid
    jq -e --slurpfile binding "$probe_binding" \
      '.[0].preFingerprint == $binding[0].restorePreFingerprint and
       .[0].postFingerprint == $binding[0].restorePostFingerprint' \
      "$proof" >/dev/null || beta_storage_fail probe_fingerprint_binding
  fi
  descriptor="$scratch/point.json"
  beta_storage_remote_head "points/$point_id/point.json" "$scratch/descriptor.meta" ||
    beta_storage_fail descriptor_read_failed
  descriptor_version=$(jq -er '.VersionId' "$scratch/descriptor.meta")
  beta_storage_remote_get_json "points/$point_id/point.json" "$descriptor" \
    "$descriptor_version"
  beta_storage_remote_validate_descriptor "$point_id" "$descriptor" "$scratch"
  [ "$(beta_storage_descriptor_digest "$descriptor")" = \
    "$(jq -er '.pointDescriptorDigest' "$receipt")" ] ||
    beta_storage_fail descriptor_binding
  jq -e --arg id "$point_id" --argjson captured "$(jq -er '.captureAt' "$receipt")" \
    --arg command "$(jq -er '.captureCommandDigest' "$receipt")" \
    --arg source "$(jq -er '.capture.sourceRevision' "$scratch/manifest.json")" \
    '.pointId==$id and .capture.capturedAt==$captured and
     .captureCommandDigest==$command and .capture.sourceRevision==$source' \
    "$scratch/manifest.json" >/dev/null || beta_storage_fail receipt_provenance_binding

  local receipt_target="receipts/$point_id/$receipt_id.json"
  local proof_target="receipts/$point_id/$receipt_id.proof.json"
  local preflight_receipt="$scratch/preflight-receipt.json"
  local preflight_proof="$scratch/preflight-proof.json"
  local preflight_head="$scratch/preflight-head.json"
  local preflight_receipt_present=false preflight_proof_present=false
  if beta_storage_remote_head "$receipt_target" "$scratch/preflight-receipt-meta.json"; then
    preflight_receipt_present=true
    receipt_version=$(jq -er '.VersionId' "$scratch/preflight-receipt-meta.json")
    beta_storage_remote_get_json "$receipt_target" "$preflight_receipt" \
      "$(jq -er '.VersionId' "$scratch/preflight-receipt-meta.json")"
    cmp -s "$receipt" "$preflight_receipt" ||
      beta_storage_fail promotion_replay_conflict
  else
    [ "$?" -eq 1 ] || beta_storage_fail receipt_read_failed
  fi
  if beta_storage_remote_head "$proof_target" "$scratch/preflight-proof-meta.json"; then
    preflight_proof_present=true
    proof_version=$(jq -er '.VersionId' "$scratch/preflight-proof-meta.json")
    beta_storage_remote_get_json "$proof_target" "$preflight_proof" \
      "$(jq -er '.VersionId' "$scratch/preflight-proof-meta.json")"
    cmp -s "$proof" "$preflight_proof" ||
      beta_storage_fail promotion_replay_conflict
  else
    [ "$?" -eq 1 ] || beta_storage_fail proof_read_failed
  fi
  if [ "$preflight_receipt_present" = true ] &&
    [ "$preflight_proof_present" = true ]; then
    if beta_storage_remote_head control/verified-head.json \
      "$scratch/preflight-head-meta.json"; then
      beta_storage_remote_get_json control/verified-head.json "$preflight_head" \
        "$(jq -er '.VersionId' "$scratch/preflight-head-meta.json")"
      if [ "$(jq -er '.pointId' "$preflight_head")" = "$point_id" ] &&
        [ "$(jq -er '.receiptId' "$preflight_head")" = "$receipt_id" ]; then
        printf 'storage_promote=idempotent point_id=%s receipt_id=%s\n' \
          "$point_id" "$receipt_id"
        return 0
      fi
    else
      [ "$?" -eq 1 ] || beta_storage_fail verified_head_read_failed
    fi
  fi

  local reserve intent_digest
  reserve=$(( $(wc -c <"$receipt") + $(wc -c <"$proof") + 12 * 65536 ))
  intent_digest=$(printf '%s\0%s\0%s' "$point_id" "$receipt_id" "$reserve" |
    sha256sum | awk '{print $1}')
  local expected_keys
  expected_keys=$(jq -cn --arg point "$point_id" --arg receipt "$receipt_id" '
    ["points/"+$point+"/point.json",
     "receipts/"+$point+"/"+$receipt+".json",
     "receipts/"+$point+"/"+$receipt+".proof.json",
     "control/verified-head.json"]')
  local writer_control_reserve=$((4 * BETA_STORAGE_WRITER_CONTROL_VERSION_BYTES))
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$((reserve + writer_control_reserve))" >/dev/null
  txid="promote-$receipt_id"
  beta_storage_remote_writer_acquire promote "$owner" "$txid" \
    "$reserve" "$intent_digest" "$expected_keys"
  beta_storage_remote_writer_transition promoting false "$expected_keys"
  acquired=true
  local existing_receipt="$scratch/existing-receipt.json"
  local existing_proof="$scratch/existing-proof.json"
  local receipt_present=$preflight_receipt_present
  local proof_present=$preflight_proof_present
  if beta_storage_remote_head "$receipt_target" "$scratch/receipt-meta.json"; then
    receipt_present=true
    beta_storage_remote_get_json "$receipt_target" "$existing_receipt" \
      "$(jq -er '.VersionId' "$scratch/receipt-meta.json")"
    cmp -s "$receipt" "$existing_receipt" ||
      beta_storage_fail promotion_replay_conflict
  else
    [ "$?" -eq 1 ] || beta_storage_fail receipt_read_failed
  fi
  if beta_storage_remote_head "$proof_target" "$scratch/proof-meta.json"; then
    proof_present=true
    beta_storage_remote_get_json "$proof_target" "$existing_proof" \
      "$(jq -er '.VersionId' "$scratch/proof-meta.json")"
    cmp -s "$proof" "$existing_proof" ||
      beta_storage_fail promotion_replay_conflict
  else
    [ "$?" -eq 1 ] || beta_storage_fail proof_read_failed
  fi
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$((reserve + writer_control_reserve))" >/dev/null
  : "${receipt_version:=}"
  : "${proof_version:=}"
  if [ "$receipt_present" = false ]; then
    receipt_version=$(jq -er '.versionId' <<<"$(
      beta_storage_provider_put_conditional '' "$receipt_target" "$receipt" '' true
    )")
  fi
  if [ "$proof_present" = false ]; then
    proof_version=$(jq -er '.versionId' <<<"$(
      beta_storage_provider_put_conditional '' "$proof_target" "$proof" '' true
    )")
  fi
  local head="$scratch/verified-head.json" generation=0 old_at=-1
  local head_meta="$scratch/verified-head.meta.json" head_etag='' head_version=''
  if beta_storage_remote_head control/verified-head.json "$head_meta"; then
    head_etag=$(jq -er '.ETag' "$head_meta")
    head_version=$(jq -er '.VersionId' "$head_meta")
    beta_storage_remote_get_json control/verified-head.json "$head" "$head_version"
    generation=$(jq -er '.generation // 0' "$head")
    old_at=$(jq -er '.verifiedCapturedAt // -1' "$head")
  else
    case "$?" in
      1) : ;;
      *) beta_storage_fail verified_head_read_failed ;;
    esac
  fi
  local verified_at
  verified_at=$(jq -er '.verifiedCapturedAt' "$receipt")
  if [ "$old_at" = "$verified_at" ] &&
    [ -f "$head" ] &&
    [ "$(jq -er '.pointId' "$head")" = "$point_id" ] &&
    [ "$(jq -er '.receiptId' "$head")" = "$receipt_id" ]; then
    printf 'storage_promote=idempotent point_id=%s receipt_id=%s\n' "$point_id" "$receipt_id"
    return 0
  fi
  (( verified_at > old_at )) || beta_storage_fail verified_head_not_newer
  jq -cnS --arg id "$point_id" --arg rid "$receipt_id" --argjson at "$verified_at" \
    --arg descriptorVersion "$descriptor_version" \
    --arg receiptVersion "$receipt_version" --arg proofVersion "$proof_version" \
    --arg descriptorDigest "$(beta_storage_descriptor_digest "$descriptor")" \
    --argjson generation "$((generation + 1))" \
    '{schema:"meet-backend/beta-backup-verified-head/v2",generation:$generation,
      pointId:$id,receiptId:$rid,verifiedCapturedAt:$at,
      descriptorVersion:$descriptorVersion,descriptorDigest:$descriptorDigest,
      receiptVersion:$receiptVersion,proofVersion:$proofVersion}' >"$head"
  local committed_head
  committed_head=$(beta_storage_provider_put_conditional '' control/verified-head.json \
    "$head" "$head_etag" "$([ -z "$head_etag" ] && echo true || echo false)")
  local committed_head_version
  committed_head_version=$(jq -er '.versionId' <<<"$committed_head")
  beta_storage_remote_get_json control/verified-head.json "$scratch/committed-head.json" \
    "$committed_head_version"
  cmp -s "$head" "$scratch/committed-head.json" ||
    beta_storage_fail verified_head_commit_ambiguous
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$writer_control_reserve" >/dev/null
  printf 'storage_promote=provider_committed point_id=%s receipt_id=%s\n' \
    "$point_id" "$receipt_id"
}

beta_storage_remote_delete_version() {
  local key=$1 version=$2 head
  head=$(mktemp)
  beta_storage_aws_read head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >"$head" ||
    { rm -f "$head"; beta_storage_fail deletion_version_unreadable; }
  jq -e --arg version "$version" '.VersionId==$version' "$head" >/dev/null ||
    { rm -f "$head"; beta_storage_fail deletion_version_mismatch; }
  rm -f "$head"
  beta_storage_provider_delete '' "$key" "$version"
  if beta_storage_aws_read head-object --bucket "$BETA_BACKUP_BUCKET" --key "$key" \
    --version-id "$version" >"$head"; then
    rm -f "$head"
    beta_storage_fail deletion_not_confirmed
  else
    local status=$?
    rm -f "$head"
    [ "$status" -eq 3 ] || beta_storage_fail deletion_verification_failed
  fi
}

beta_storage_remote_multipart_eligible() {
  local key=$1 initiated=$2 now=$3 initiated_at
  [[ "$key" == points/* || "$key" == receipts/* ]] || return 1
  [ -n "$initiated" ] || return 1
  initiated_at=$(date -u -d "$initiated" +%s 2>/dev/null) || return 1
  (( initiated_at <= now - 3600 ))
}

beta_storage_prune_remote() {
  local now=$1 owner=$2 safety_status=$3 safety_watermark=$4 safety_environment=$5
  local pinned='' capture_pinned='' head_version
  [[ "$now" =~ ^[0-9]+$ ]] || beta_storage_fail clock_invalid
  beta_storage_remote_require_safety "$safety_status" "$safety_watermark" \
    "$safety_environment" "$now"
  beta_storage_require_config
  local writer_control_reserve=$((5 * BETA_STORAGE_WRITER_CONTROL_VERSION_BYTES))
  local intent_digest
  intent_digest=$(printf '%s\0%s\0%s\0%s' prune "$now" "$BETA_BACKUP_BYTE_BUDGET" \
    "$writer_control_reserve" |
    sha256sum | awk '{print $1}')
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$writer_control_reserve" false >/dev/null
  beta_storage_remote_writer_acquire prune "$owner" "prune-$now" \
    "$writer_control_reserve" \
    "$intent_digest" '["control/verified-head.json"]'
  beta_storage_remote_writer_transition pruning false \
    '["control/verified-head.json"]'
  local release=true head='' seen='' deleted_point_ids='' ambiguous_marker scratch
  local deleted_points=0 deleted_object_versions=0 deleted_object_bytes=0
  local deleted_multipart_uploads=0 deleted_multipart_bytes=0
  scratch=$(mktemp -d)
  ambiguous_marker=$(mktemp)
  rm -f "$ambiguous_marker"
  export BETA_STORAGE_AMBIGUOUS_MARKER="$ambiguous_marker"
  mutation_started_marker="$ambiguous_marker.started"
  export BETA_STORAGE_MUTATION_STARTED_MARKER="$mutation_started_marker"
  cleanup_remote_prune() {
    local status=$?
    trap - RETURN
    if [ -e "$BETA_STORAGE_AMBIGUOUS_MARKER" ] ||
      { [ "$status" -ne 0 ] && [ -e "$BETA_STORAGE_MUTATION_STARTED_MARKER" ]; }; then
      release=false
      printf 'BACKUP_STORAGE_BLOCKED:ambiguous_transaction_retained tx=prune-%s\n' "$now" >&2
    fi
    if [ "$release" = true ]; then
      beta_storage_remote_writer_release "$owner" "prune-$now" || status=1
    fi
    rm -f -- "$head" "$head.meta" "$seen" "$deleted_point_ids" \
      "$ambiguous_marker" \
      "$mutation_started_marker" 2>/dev/null ||
      status=1
    rm -rf -- "$scratch" 2>/dev/null || status=1
    unset BETA_STORAGE_AMBIGUOUS_MARKER
    unset BETA_STORAGE_MUTATION_STARTED_MARKER
    return "$status"
  }
  trap cleanup_remote_prune RETURN
  beta_storage_remote_require_safety "$safety_status" "$safety_watermark" \
    "$safety_environment" "$now"
  head=$(mktemp)
  if beta_storage_remote_head control/verified-head.json "$head.meta"; then
    head_version=$(jq -er '.VersionId' "$head.meta")
    beta_storage_remote_get_json control/verified-head.json "$head" "$head_version"
    pinned=$(jq -er '.pointId' "$head")
  else
    beta_storage_fail verified_head_read_failed
  fi
  [ -n "$pinned" ] || beta_storage_fail verified_head_missing
  beta_storage_remote_build_status_once "$scratch/pinned-status.json" \
    "$safety_environment" "$now" || beta_storage_fail pinned_closure_unreadable
  jq -e --arg pinned "$pinned" \
    '.verified.state=="VALID" and .verified.id==$pinned' \
    "$scratch/pinned-status.json" >/dev/null ||
    beta_storage_fail pinned_closure_invalid
  capture_pinned=$(jq -er '.capture.id // empty' "$scratch/pinned-status.json")
  [ -n "$capture_pinned" ] || beta_storage_fail capture_head_missing
  local expected_keys
  expected_keys=$(jq -cn --arg point "$pinned" --arg capture "$capture_pinned" \
    --arg receipt "$(jq -er '.receiptId' "$head")" \
    '(["points/"+$point+"/point.json",
      "points/"+$point+"/recovery-point.json",
      "points/"+$point+"/postgres.dump.age",
      "points/"+$point+"/uploads.tar.gz.age",
      "receipts/"+$point+"/"+$receipt+".json",
      "receipts/"+$point+"/"+$receipt+".proof.json",
      "control/verified-head.json",
      "points/"+$capture+"/point.json",
      "points/"+$capture+"/recovery-point.json",
      "points/"+$capture+"/postgres.dump.age",
      "points/"+$capture+"/uploads.tar.gz.age",
      "control/capture-head.json",
      "control/prune-summary.json"] | unique)')
  beta_storage_remote_writer_transition pruning false "$expected_keys"
  local inventory key version inventory_before
  inventory_before=$(beta_storage_remote_inventory_total \
    "$BETA_BACKUP_BYTE_BUDGET" 0 false)
  inventory=$(beta_storage_aws_list_versions | jq -s '.')
  jq -e 'type=="array" and all(.[]; type=="object" and
    all(.Versions[]?; (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
      (.VersionId|type=="string" and length>0) and
      (.Size|type=="number" and floor==. and .>=0)) and
    all(.DeleteMarkers[]?; (.Key|type=="string") and
      (.VersionId|type=="string" and length>0)))' <<<"$inventory" >/dev/null ||
    beta_storage_fail inventory_invalid
  seen=$(mktemp)
  deleted_point_ids=$(mktemp)
  delete_inventory_version() {
    local object_key=$1 object_version=$2 object_bytes
    object_bytes=$(jq -er --arg key "$object_key" --arg version "$object_version" '
      [.[].Versions[]? | select(.Key==$key and .VersionId==$version) | .Size][0]
    ' <<<"$inventory") || beta_storage_fail inventory_invalid
    beta_storage_remote_delete_version "$object_key" "$object_version"
    (( deleted_object_bytes <= 9223372036854775807 - object_bytes )) ||
      beta_storage_fail budget_overflow
    deleted_object_bytes=$((deleted_object_bytes + object_bytes))
    deleted_object_versions=$((deleted_object_versions + 1))
  }
  while IFS=$'\t' read -r key version; do
    [[ "$key" == points/*/recovery-point.json ]] || continue
    local point_id=${key#points/}; point_id=${point_id%/recovery-point.json}
    if [ "$point_id" = "$pinned" ] || [ "$point_id" = "$capture_pinned" ]; then
      continue
    fi
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
        delete_inventory_version "$object_key" "$object_version"
      done < <(jq -r --arg id "$point_id" '.Versions[]? |
        select(.Key|startswith("points/"+$id+"/") or startswith("receipts/"+$id+"/")) |
        [.Key,.VersionId]|@tsv' <<<"$inventory")
      printf '%s\n' "$point_id" >>"$deleted_point_ids"
      deleted_points=$((deleted_points + 1))
    fi
    rm -f "$manifest"
  done < <(jq -r '.[].Versions[]? | [.Key,.VersionId]|@tsv' <<<"$inventory")
  # Remove incomplete orphan graphs, including receipts left after a failed
  # manifest-last publication. A point is live only when one complete
  # descriptor/manifest/ciphertext/proof closure validates.
  local orphan_points
  orphan_points=$(mktemp)
  jq -r '.[].Versions[]? | .Key |
    if test("^points/[^/]+/") then
      capture("^points/(?<id>[^/]+)/") | .id
    elif test("^receipts/[^/]+/") then
      capture("^receipts/(?<id>[^/]+)/") | .id
    else empty end' <<<"$inventory" | sort -u >"$orphan_points"
  while IFS= read -r point_id; do
    [ -n "$point_id" ] || continue
    [ "$point_id" = "$pinned" ] || [ "$point_id" = "$capture_pinned" ] && continue
    grep -Fxq -- "$point_id" "$deleted_point_ids" && continue
    if beta_storage_remote_point_graph_state "$point_id" "$inventory" "$scratch"; then
      continue
    else
      local graph_status=$?
      [ "$graph_status" -eq 1 ] ||
        beta_storage_fail orphan_graph_unreadable
    fi
    while IFS=$'\t' read -r object_key object_version; do
      [[ "$object_key" == "points/$point_id/"* ||
        "$object_key" == "receipts/$point_id/"* ]] || continue
      delete_inventory_version "$object_key" "$object_version"
    done < <(jq -r --arg id "$point_id" '.[].Versions[]? |
      select(.Key|startswith("points/"+$id+"/") or
        startswith("receipts/"+$id+"/")) | [.Key,.VersionId]|@tsv' <<<"$inventory")
    printf '%s\n' "$point_id" >>"$deleted_point_ids"
    deleted_points=$((deleted_points + 1))
  done <"$orphan_points"
  rm -f -- "$orphan_points"
  # Every control object is budgeted. Retain only its current live version;
  # this includes incident state, whose historical versions are not authority.
  local control_key
  while IFS= read -r control_key; do
    [ -n "$control_key" ] || continue
    if beta_storage_remote_head "$control_key" "$head.meta"; then
      current_control_version=$(jq -er '.VersionId' "$head.meta")
      while IFS=$'\t' read -r control_version_key control_version; do
        [ "$control_version" = "$current_control_version" ] && continue
        delete_inventory_version "$control_version_key" "$control_version"
      done < <(jq -r --arg key "$control_key" '.[].Versions[]? |
        select(.Key==$key) | [.Key,.VersionId]|@tsv' <<<"$inventory")
    else
      [ "$?" -eq 1 ] || beta_storage_fail control_read_failed
    fi
  done < <(jq -r '.[].Versions[]? | .Key | select(startswith("control/"))' \
    <<<"$inventory" | sort -u)
  local multipart key_marker='' upload_id_marker='' multipart_page=0
  while (( multipart_page < BETA_STORAGE_MAX_PAGES )); do
    multipart_page=$((multipart_page + 1))
    if [ -n "$key_marker" ]; then
      multipart=$(beta_storage_aws_read list-multipart-uploads \
        --bucket "$BETA_BACKUP_BUCKET" --max-uploads 1000 \
        --key-marker "$key_marker" --upload-id-marker "$upload_id_marker") ||
        beta_storage_fail multipart_inventory_unavailable
    else
      multipart=$(beta_storage_aws_read list-multipart-uploads \
        --bucket "$BETA_BACKUP_BUCKET" --max-uploads 1000) ||
        beta_storage_fail multipart_inventory_unavailable
    fi
    jq -e '
      type=="object" and (.Uploads|type=="array") and
      all(.Uploads[]?;
        (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
        (.UploadId|type=="string" and test("^[A-Za-z0-9._:-]{1,256}$")) and
        (.Initiated|type=="string" and length>0))
    ' <<<"$multipart" >/dev/null ||
      beta_storage_fail multipart_inventory_invalid
    while IFS=$'\t' read -r upload_key upload_id initiated; do
      [ -n "$upload_key" ] && [ -n "$upload_id" ] || continue
      beta_storage_remote_multipart_eligible "$upload_key" "$initiated" "$now" ||
        continue
      beta_storage_key "$upload_key" >/dev/null
      part_page=$(beta_storage_aws_read list-parts --bucket "$BETA_BACKUP_BUCKET" \
        --key "$upload_key" --upload-id "$upload_id" --max-parts 1000) ||
        beta_storage_fail multipart_parts_unavailable
      jq -e '
        type=="object" and (.Parts|type=="array") and
        ((.IsTruncated // false)==false) and
        all(.Parts[]?;
          (.PartNumber|type=="number" and floor==. and .>=1 and .<=10000) and
          (.Size|type=="number" and floor==. and .>=0 and
            .<=9223372036854775807) and
          (.ETag|type=="string" and length>0))
      ' <<<"$part_page" >/dev/null ||
        beta_storage_fail multipart_parts_incomplete
      part_bytes=$(jq -r '[.Parts[]?.Size] | add // 0' <<<"$part_page")
      beta_storage_aws_mutation abort-multipart-upload --bucket "$BETA_BACKUP_BUCKET" \
        --key "$upload_key" --upload-id "$upload_id" >/dev/null ||
        beta_storage_fail multipart_abort_failed
      if beta_storage_aws_read list-parts --bucket "$BETA_BACKUP_BUCKET" \
        --key "$upload_key" --upload-id "$upload_id" --max-parts 1000 >/dev/null; then
        beta_storage_fail multipart_abort_not_confirmed
      else
        local abort_status=$?
        [ "$abort_status" -eq 3 ] ||
          beta_storage_fail multipart_abort_verification_failed
      fi
      (( deleted_multipart_bytes <= 9223372036854775807 - part_bytes )) ||
        beta_storage_fail budget_overflow
      deleted_multipart_bytes=$((deleted_multipart_bytes + part_bytes))
      deleted_multipart_uploads=$((deleted_multipart_uploads + 1))
    done < <(jq -r '.Uploads[]? | [.Key,.UploadId,.Initiated // ""]|@tsv' <<<"$multipart")
    [ "$(jq -er '.IsTruncated // false' <<<"$multipart")" = true ] || break
    key_marker=$(jq -er '.NextKeyMarker // empty' <<<"$multipart")
    upload_id_marker=$(jq -er '.NextUploadIdMarker // empty' <<<"$multipart")
    [ -n "$key_marker" ] && [ -n "$upload_id_marker" ] ||
      beta_storage_fail multipart_pagination_invalid
  done
  (( multipart_page < BETA_STORAGE_MAX_PAGES )) ||
    beta_storage_fail multipart_pagination_limit
  local inventory_after reclaimed_bytes summary summary_result summary_version
  summary="$scratch/prune-summary.json"
  local summary_meta summary_current_version summary_status
  summary_meta="$scratch/prune-summary.meta"
  if beta_storage_remote_head control/prune-summary.json "$summary_meta"; then
    summary_current_version=$(jq -er '.VersionId' "$summary_meta")
    delete_inventory_version control/prune-summary.json "$summary_current_version"
  else
    summary_status=$?
    [ "$summary_status" -eq 1 ] ||
      beta_storage_fail prune_summary_read_failed
  fi
  inventory_after=$(beta_storage_remote_inventory_total \
    "$BETA_BACKUP_BYTE_BUDGET" 0 false)
  (( deleted_object_bytes <= 9223372036854775807 - deleted_multipart_bytes )) ||
    beta_storage_fail budget_overflow
  reclaimed_bytes=$((deleted_object_bytes + deleted_multipart_bytes))
  jq -cnS --arg tx "prune-$now" --arg pinned "$pinned" \
    --arg capture "$capture_pinned" --arg outcome committed \
    --argjson completed "$now" --argjson age 2592000 \
    --argjson points "$deleted_points" \
    --argjson versions "$deleted_object_versions" \
    --argjson objectBytes "$deleted_object_bytes" \
    --argjson multipartUploads "$deleted_multipart_uploads" \
    --argjson multipartBytes "$deleted_multipart_bytes" \
    --argjson before "$inventory_before" --argjson after "$inventory_after" \
    --argjson reclaimed "$reclaimed_bytes" \
    '{
      schema:"meet-backend/beta-backup-prune-summary/v1",
      transactionId:$tx,completedAt:$completed,eligibilityAgeSeconds:$age,
      pinnedPointId:$pinned,capturePinnedPointId:$capture,
      deletedPoints:$points,deletedObjectVersions:$versions,
      deletedObjectBytes:$objectBytes,
      abortedMultipartUploads:$multipartUploads,
      reclaimedMultipartBytes:$multipartBytes,
      inventoryBeforeBytes:$before,inventoryAfterBytes:$after,
      reclaimedBytes:$reclaimed,outcome:$outcome
    }' >"$summary"
  summary_result=$(beta_storage_provider_put_conditional '' \
    control/prune-summary.json "$summary" '' true)
  summary_version=$(jq -er '.versionId' <<<"$summary_result")
  beta_storage_remote_get_json control/prune-summary.json \
    "$scratch/committed-prune-summary.json" "$summary_version"
  cmp -s "$summary" "$scratch/committed-prune-summary.json" ||
    beta_storage_fail prune_summary_commit_ambiguous
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" \
    "$writer_control_reserve" >/dev/null
  rm -f "$head" "$head.meta" "$seen" "$deleted_point_ids"
  beta_storage_remote_writer_release "$owner" "prune-$now"
  release=false
  trap - RETURN
  printf 'storage_prune=provider_committed pinned_point=%s\n' "${pinned:-none}"
}

beta_storage_reconcile_remote() {
  local inventory scratch key version descriptor writer_meta writer_state
  beta_storage_require_config
  scratch=$(mktemp -d)
  writer_meta=$(mktemp)
  writer_state=$(mktemp)
  if beta_storage_remote_head control/writer.json "$writer_meta"; then
    :
  else
    writer_status=$?
    rm -f -- "$writer_meta" "$writer_state"
    [ "$writer_status" -eq 1 ] &&
      beta_storage_fail writer_state_missing ||
      beta_storage_fail writer_state_unreadable
  fi
  beta_storage_remote_get_json control/writer.json "$writer_state" \
    "$(jq -er '.VersionId' "$writer_meta")"
  jq -e '
    type=="object" and
    (keys|sort)==["ambiguous","expectedKeys","fencingToken","generation",
      "intentDigest","leaseUntil","locked","operation","owner","phase",
      "reservationBytes","schema","transactionId"] and
    .schema=="meet-backend/beta-backup-writer/v3" and
    (.generation|type=="number" and floor==. and .>=0) and
    (.fencingToken|type=="number" and floor==. and .>=0) and
    (.leaseUntil|type=="number" and floor==. and .>=0) and
    (.locked|type=="boolean") and (.ambiguous|type=="boolean") and
    (.phase|type=="string" and test("^[a-z][a-z0-9_-]{0,31}$")) and
    (.expectedKeys|type=="array" and all(.[]; type=="string" and
      test("^(points|receipts|control)/[A-Za-z0-9._/-]+$"))) and
    (.reservationBytes|type=="number" and floor==. and .>=0) and
    (.intentDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.owner|type=="string" and length>0) and
    (.transactionId|type=="string" and length>0)
  ' "$writer_state" >/dev/null || {
    rm -f -- "$writer_meta" "$writer_state"
    beta_storage_fail writer_state_invalid
  }
  if [ "$(jq -er '.locked' "$writer_state")" = true ] &&
    [ "$(jq -er '.ambiguous' "$writer_state")" = true ]; then
    local operation owner txid expected_keys current_etag point_id
    operation=$(jq -er '.operation' "$writer_state")
    owner=$(jq -er '.owner' "$writer_state")
    txid=$(jq -er '.transactionId' "$writer_state")
    expected_keys=$(jq -c '.expectedKeys' "$writer_state")
    current_etag=$(jq -er '.ETag' "$writer_meta")
    BETA_STORAGE_REMOTE_WRITER_ETAG=$current_etag
    BETA_STORAGE_REMOTE_WRITER_FENCING=$(jq -er '.fencingToken' "$writer_state")
    BETA_STORAGE_REMOTE_WRITER_TX=$txid
    BETA_STORAGE_REMOTE_WRITER_OWNER=$owner
    BETA_STORAGE_REMOTE_EXPECTED_KEYS=$expected_keys
    if [ "$operation" = publish ]; then
      point_id=$(jq -r 'map(select(startswith("points/"))) |
        .[0] // empty' <<<"$expected_keys" |
        sed -E 's#^points/([^/]+)/.*#\1#')
      if [ -n "$point_id" ] &&
        beta_storage_remote_head "points/$point_id/point.json" "$scratch/reconcile-point.meta" &&
        beta_storage_remote_get_json "points/$point_id/point.json" \
          "$scratch/reconcile-point.json" \
          "$(jq -er '.VersionId' "$scratch/reconcile-point.meta")" &&
        beta_storage_remote_validate_descriptor "$point_id" \
          "$scratch/reconcile-point.json" "$scratch" false &&
        beta_storage_remote_head control/capture-head.json \
          "$scratch/reconcile-capture.meta" &&
        beta_storage_remote_get_json control/capture-head.json \
          "$scratch/reconcile-capture.json" \
          "$(jq -er '.VersionId' "$scratch/reconcile-capture.meta")" &&
        jq -e --arg point "$point_id" \
          --arg descriptor "$(beta_storage_descriptor_digest \
            "$scratch/reconcile-point.json")" '
          .schema=="meet-backend/beta-backup-head/v2" and
          .pointId==$point and .descriptorDigest==$descriptor
        ' "$scratch/reconcile-capture.json" >/dev/null; then
        beta_storage_remote_writer_transition reconciled false "$expected_keys" &&
          beta_storage_remote_writer_release "$owner" "$txid" &&
          printf 'storage_reconcile=provider_committed transaction=%s\n' "$txid"
        rm -rf -- "$scratch" "$writer_meta" "$writer_state"
        return $?
      fi
    elif [ "$operation" = promote ]; then
      point_id=$(jq -r 'map(select(startswith("receipts/"))) |
        .[0] // empty' <<<"$expected_keys" |
        sed -E 's#^receipts/([^/]+)/.*#\1#')
      if [ -n "$point_id" ] &&
        beta_storage_remote_build_status_once \
          "$scratch/reconcile-status.json" closed-beta "$(date -u +%s)" &&
        jq -e --arg point "$point_id" \
          '.verified.state=="VALID" and .verified.id==$point' \
          "$scratch/reconcile-status.json" >/dev/null; then
        beta_storage_remote_writer_transition reconciled false "$expected_keys" &&
          beta_storage_remote_writer_release "$owner" "$txid" &&
          printf 'storage_reconcile=provider_committed transaction=%s\n' "$txid"
        rm -rf -- "$scratch" "$writer_meta" "$writer_state"
        return $?
      fi
    fi
    printf 'storage_reconcile=pending writer_locked=%s ambiguous=%s transaction=%s\n' \
      "$(jq -er '.locked' "$writer_state")" \
      "$(jq -er '.ambiguous' "$writer_state")" \
      "$(jq -er '.transactionId' "$writer_state")"
    rm -f -- "$writer_meta" "$writer_state"
    beta_storage_fail writer_reconciliation_pending
  fi
  if [ "$(jq -er '.locked' "$writer_state")" = true ]; then
    # A lost writer-state CAS can leave a nonterminal record with
    # ambiguous:false. It is still unknown: reconciliation must not release
    # or rewrite it merely because the last response was not classified as
    # ambiguous. An operator must fence the exact transaction before closure.
    printf 'storage_reconcile=pending writer_locked=true operator_fence_required=true transaction=%s\n' \
      "$(jq -er '.transactionId' "$writer_state")"
    rm -f -- "$writer_meta" "$writer_state"
    beta_storage_fail writer_operator_fence_required
  fi
  jq -e '
    .locked==false and .ambiguous==false and .operation=="idle" and
    .phase=="idle" and .leaseUntil==0 and .reservationBytes==0 and
    .expectedKeys==[] and
    .intentDigest=="0000000000000000000000000000000000000000000000000000000000000000"
  ' "$writer_state" >/dev/null ||
    { rm -f -- "$writer_meta" "$writer_state"; beta_storage_fail writer_state_not_terminal; }
  rm -f -- "$writer_meta" "$writer_state"
  beta_storage_remote_inventory_total "$BETA_BACKUP_BYTE_BUDGET" >/dev/null
  inventory=$(beta_storage_aws_list_versions | jq -s '.') ||
    beta_storage_fail inventory_unavailable
  jq -e 'type=="array" and all(.[]; type=="object" and
    all(.Versions[]?; (.Key|type=="string" and test("^(points|receipts|control)/[A-Za-z0-9._/-]+$")) and
      (.VersionId|type=="string" and length>0) and
      (.Size|type=="number" and floor==. and .>=0)))' <<<"$inventory" >/dev/null ||
    beta_storage_fail inventory_invalid
  while IFS=$'\t' read -r receipt_key; do
    [ -n "$receipt_key" ] || continue
    local receipt_point=${receipt_key#receipts/}
    receipt_point=${receipt_point%%/*}
    jq -e --arg point "$receipt_point" '
      any(.[].Versions[]?; .Key=="points/"+$point+"/recovery-point.json")
    ' <<<"$inventory" >/dev/null ||
      { rm -rf "$scratch"; beta_storage_fail orphan_receipt_graph; }
  done < <(jq -r '.[].Versions[]? | select(.Key|startswith("receipts/")) | .Key' <<<"$inventory")
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
  done < <(jq -r '.[].Versions[]? | [.Key,.VersionId]|@tsv' <<<"$inventory")
  rm -rf "$scratch"
  printf 'storage_reconcile=provider_clean\n'
}

beta_storage_local_read_json() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(wc -c <"$file")" -le 65536 ] || return 1
  beta_storage_require_unique_json "$file" || return 1
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
  beta_storage_require_unique_json "$directory/point.json" || return 1
  jq -e --arg id "$point_id" '
    type=="object" and (keys|sort)==["capture","captureCommandDigest","captureEvidenceDigest",
    "ciphertexts","contractDigest","descriptorDigest","manifestDigest","pointId",
    "proofDigest","proofs","runtimeRevision","slotId","schema","versions"] and
    .schema=="meet-backend/beta-backup-descriptor/v2" and .pointId==$id and
    (.descriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.manifestDigest|type=="string" and test("^[0-9a-f]{64}$")) and
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
  [ "$(beta_storage_descriptor_digest "$directory/point.json")" = \
    "$(jq -er '.descriptorDigest' "$directory/point.json")" ] || return 1
  [ "$(sha256sum "$directory/recovery-point.json" | awk '{print $1}')" = \
    "$(jq -er '.manifestDigest' "$directory/point.json")" ] || return 1
  [ "$(jq -er '.captureCommandDigest' "$directory/recovery-point.json")" = \
    "$(jq -er '.captureCommandDigest' "$directory/point.json")" ] || return 1
  [ "$(jq -er '.captureEvidenceDigest' "$directory/recovery-point.json")" = \
    "$(jq -er '.captureEvidenceDigest' "$directory/point.json")" ] || return 1
  jq -e --arg slot "$(jq -er '.slotId' "$directory/recovery-point.json")" \
    --argjson captured "$(jq -er '.capture.capturedAt' "$directory/recovery-point.json")" \
    --arg source "$(jq -er '.capture.sourceRevision' "$directory/recovery-point.json")" \
    --arg runtime "$(jq -er '.runtimeRevision' "$directory/recovery-point.json")" \
    --arg contract "$(jq -er '.contractDigest' "$directory/recovery-point.json")" \
    --arg proof "$(jq -er '.proofDigest' "$directory/recovery-point.json")" \
    '.slotId==$slot and .capture.capturedAt==$captured and
     .capture.sourceRevision==$source and .runtimeRevision==$runtime and
     .contractDigest==$contract and .proofDigest==$proof' \
    "$directory/point.json" >/dev/null || return 1
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
      [ "$(wc -c <"$directory/$proof_file")" = "$(jq -er ".proofs.$proof_kind.length" "$directory/point.json")" ] || return 1
      [ "$(sha256sum "$directory/$proof_file" | awk '{print $1}')" = "$(jq -er ".proofs.$proof_kind.sha256" "$directory/point.json")" ] || return 1
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
  local txid="publish-$point_id"
  beta_storage_local_acquire "$root" publish "$owner" "$txid"
  local cleanup=true
  trap 'if [ "$cleanup" = true ]; then rm -rf -- "$point_dir"; fi' RETURN
  if [ -e "$point_dir" ]; then
    beta_storage_local_validate_point_dir "$point_dir" "$point_id" ||
      { cleanup=false; beta_storage_local_release "$root"; trap - RETURN;
        beta_storage_fail duplicate_point_conflict; }
    beta_storage_source_matches_local_point "$source" "$point_dir" ||
      { cleanup=false; beta_storage_local_release "$root"; trap - RETURN;
        beta_storage_fail duplicate_point_conflict; }
    [ -f "$root/control/capture-head.json" ] &&
      [ ! -L "$root/control/capture-head.json" ] &&
      beta_storage_require_unique_json "$root/control/capture-head.json" &&
      jq -e --arg point "$point_id" \
        --arg digest "$(beta_storage_descriptor_digest "$point_dir/point.json")" \
        --argjson captured "$captured_at" '
        .schema=="meet-backend/beta-backup-head/v1" and
        .pointId==$point and .capturedAt==$captured and
        .descriptorDigest==$digest
      ' "$root/control/capture-head.json" >/dev/null ||
      { cleanup=false; beta_storage_local_release "$root"; trap - RETURN;
        beta_storage_fail duplicate_point_uncommitted; }
    cleanup=false
    beta_storage_local_release "$root"
    trap - RETURN
    printf 'storage_publish=idempotent point_id=%s\n' "$point_id"
    return 0
  fi
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
    --arg source "$(jq -er '.capture.sourceRevision' "$source/recovery-point.json")" \
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
      capture:{capturedAt:($capture|tonumber),sourceRevision:$source},
      runtimeRevision:$runtime,
      captureCommandDigest:$command,captureEvidenceDigest:$evidence,
      contractDigest:$contract,proofDigest:$proof,
      ciphertexts:{database:{length:$dblen,sha256:$dbsha},
        uploads:{length:$medielen,sha256:$mediasha}},
      versions:{database:$dbversion,manifest:$manifestversion,uploads:$mediaversion},
      proofs:$proofs,manifestDigest:$manifest,
      descriptorDigest:"0000000000000000000000000000000000000000000000000000000000000000"}' \
    >"$point_dir/.point.json.initial"
  descriptor_digest=$(beta_storage_descriptor_digest "$point_dir/.point.json.initial")
  jq --arg digest "$descriptor_digest" '.descriptorDigest=$digest' \
    "$point_dir/.point.json.initial" |
    beta_storage_local_atomic_json "$point_dir/point.json"
  rm -f -- "$point_dir/.point.json.initial"
  local head_generation=0
  [ -f "$root/control/capture-head.json" ] &&
    head_generation=$(jq -er '.generation' "$root/control/capture-head.json") || true
  jq -cnS --arg id "$point_id" --argjson captured "$captured_at" \
    --argjson generation "$((head_generation + 1))" \
    --arg digest "$descriptor_digest" \
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
  beta_storage_require_unique_json "$receipt" || return 1
  jq -e '
    type=="object" and (keys|sort)==["captureAt","captureCommandDigest","captureRevision",
      "pointDescriptorDigest","pointId","proofDigest","protectionDigest","receiptId",
      "restoreRevision","reviewerId","schema","verifiedCapturedAt"] and
    .schema=="meet-backend/beta-backup-receipt/v2" and
    (.receiptId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.pointId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
    (.captureRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.restoreRevision|type=="string" and test("^[0-9a-f]{40}$")) and
    (.reviewerId|type=="string" and test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")) and
    (.captureCommandDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.pointDescriptorDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.protectionDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.captureAt|type=="number" and floor==. and .>=0) and
    (.proofDigest|type=="string" and test("^[0-9a-f]{64}$")) and
    (.verifiedCapturedAt|type=="number" and floor==. and .>=0) and
    .verifiedCapturedAt == .captureAt
  ' "$receipt" >/dev/null
  local proof_path
  proof_path="$(dirname -- "$receipt")/$(jq -er '.receiptId' "$receipt").proof.json"
  [ -f "$proof_path" ] && [ ! -L "$proof_path" ] ||
    proof_path="$(dirname -- "$receipt")/$(basename "$receipt" .json).proof.json"
  [ -f "$proof_path" ] && [ ! -L "$proof_path" ] || return 1
  beta_storage_require_unique_json "$proof_path" || return 1
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
    .preFingerprint == .postFingerprint
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
  descriptor_digest=$(beta_storage_descriptor_digest \
    "$root/points/$point_id/point.json")
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
