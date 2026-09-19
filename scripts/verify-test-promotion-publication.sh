#!/usr/bin/env bash
set -euo pipefail

SCHEMA='meet-backend/test-promotion-publication/v1'
INDEX_MEDIA='application/vnd.oci.image.index.v1+json'
MANIFEST_MEDIA='application/vnd.oci.image.manifest.v1+json'

usage() {
  cat >&2 <<'EOF'
usage:
  verify-test-promotion-publication.sh create
    --image IMAGE --source-sha SHA --tree-id TREE --version VERSION
    --run-id ID --run-attempt N --layout DIR --layout-proof FILE
    --source-proof FILE --before-inventory FILE --protected-state FILE
    --output FILE
  verify-test-promotion-publication.sh verify
    --proof FILE --expected-proof-sha256 SHA256 --index-file FILE
    --candidate-inventory FILE --observed-reader FILE --registry-journal FILE
    --before-inventory FILE --protected-state FILE --layout-proof FILE
    --image IMAGE --source-sha SHA --tree-id TREE --version VERSION
    --run-id ID --run-attempt N
EOF
  exit 2
}

fail() {
  echo "test promotion publication proof failed: $*" >&2
  exit 1
}

usage_fail() {
  echo "test promotion publication proof: invalid arguments" >&2
  usage
}

is_digest() { [[ ${1:-} =~ ^sha256:[0-9a-f]{64}$ ]]; }
is_sha256() { [[ ${1:-} =~ ^[0-9a-f]{64}$ ]]; }
is_sha() { [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]; }
is_integer() { [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; }
is_safe_path() {
  local path=$1
  [ -n "$path" ] && [ -e "$path" ] && [ ! -L "$path" ]
}
regular_file() {
  is_safe_path "$1" && [ -f "$1" ] && [ -r "$1" ]
}
directory() {
  is_safe_path "$1" && [ -d "$1" ] && [ -r "$1" ] && [ -x "$1" ]
}
sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}
json_file() {
  regular_file "$1" || fail "unsafe or missing JSON input: $1"
  jq -e 'type == "object" or type == "array"' "$1" >/dev/null ||
    fail "malformed JSON input: $1"
}
sha256_json() {
  sha256_file "$1"
}

MODE=${1:-}
[ "$MODE" = create ] || [ "$MODE" = verify ] || usage_fail
shift

IMAGE=
SOURCE_SHA=
TREE_ID=
VERSION=
RUN_ID=
RUN_ATTEMPT=
LAYOUT=
LAYOUT_PROOF=
SOURCE_PROOF=
BEFORE_INVENTORY=
PROTECTED_STATE=
OUTPUT=
PROOF=
EXPECTED_PROOF_SHA=
INDEX_FILE=
CANDIDATE_INVENTORY=
OBSERVED_READER=
REGISTRY_JOURNAL=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || usage_fail; IMAGE=$2; shift 2 ;;
    --repository) [ "$#" -ge 2 ] || usage_fail; IMAGE=$2; shift 2 ;;
    --source-sha|--source) [ "$#" -ge 2 ] || usage_fail; SOURCE_SHA=$2; shift 2 ;;
    --tree-id|--tree) [ "$#" -ge 2 ] || usage_fail; TREE_ID=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage_fail; VERSION=$2; shift 2 ;;
    --run-id) [ "$#" -ge 2 ] || usage_fail; RUN_ID=$2; shift 2 ;;
    --run-attempt|--attempt) [ "$#" -ge 2 ] || usage_fail; RUN_ATTEMPT=$2; shift 2 ;;
    --layout) [ "$#" -ge 2 ] || usage_fail; LAYOUT=$2; shift 2 ;;
    --layout-proof) [ "$#" -ge 2 ] || usage_fail; LAYOUT_PROOF=$2; shift 2 ;;
    --source-proof) [ "$#" -ge 2 ] || usage_fail; SOURCE_PROOF=$2; shift 2 ;;
    --before-inventory) [ "$#" -ge 2 ] || usage_fail; BEFORE_INVENTORY=$2; shift 2 ;;
    --protected-state) [ "$#" -ge 2 ] || usage_fail; PROTECTED_STATE=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage_fail; OUTPUT=$2; shift 2 ;;
    --proof) [ "$#" -ge 2 ] || usage_fail; PROOF=$2; shift 2 ;;
    --expected-proof-sha256|--expected-proof-sha) [ "$#" -ge 2 ] || usage_fail; EXPECTED_PROOF_SHA=$2; shift 2 ;;
    --index-file|--selected-raw-index) [ "$#" -ge 2 ] || usage_fail; INDEX_FILE=$2; shift 2 ;;
    --candidate-inventory|--inventory) [ "$#" -ge 2 ] || usage_fail; CANDIDATE_INVENTORY=$2; shift 2 ;;
    --observed-reader|--observed-snapshot) [ "$#" -ge 2 ] || usage_fail; OBSERVED_READER=$2; shift 2 ;;
    --registry-journal|--journal) [ "$#" -ge 2 ] || usage_fail; REGISTRY_JOURNAL=$2; shift 2 ;;
    --help|-h) usage ;;
    *) usage_fail ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
[ -n "$IMAGE" ] || usage_fail
[[ "$IMAGE" =~ ^ghcr\.io/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage_fail
is_sha "$SOURCE_SHA" || usage_fail
[ -n "$TREE_ID" ] || usage_fail
is_integer "$RUN_ID" || usage_fail
is_integer "$RUN_ATTEMPT" || usage_fail
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage_fail

write_atomic() {
  local source=$1 destination=$2
  local parent
  parent=$(dirname -- "$destination")
  directory "$parent" || fail "output directory is unsafe"
  [ ! -e "$destination" ] || fail "output already exists"
  [ ! -L "$destination" ] || fail "output is a symlink"
  local temp
  temp=$(mktemp "$parent/.publication-proof.XXXXXX") || fail "cannot create output temporary"
  # The temporary path is intentionally captured before nested function returns.
  # shellcheck disable=SC2064
  trap "rm -f -- '$temp'" RETURN
  chmod 600 "$temp" || fail "cannot protect output"
  cp -- "$source" "$temp" || fail "cannot write output"
  ln -- "$temp" "$destination" || fail "cannot publish output without overwrite"
  rm -f -- "$temp" || fail "cannot remove publication temporary"
  trap - RETURN
}

validate_descriptor() {
  jq -e '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . >= 0)
  ' <<<"$1" >/dev/null || fail "malformed OCI descriptor: $1"
}

layout_blob() {
  local layout=$1 digest=$2
  printf '%s/blobs/sha256/%s\n' "$layout" "${digest#sha256:}"
}

digest_bytes() {
  local file=$1 expected=$2 expected_size=${3:-}
  [ -f "$file" ] || fail "missing content-addressed blob"
  local actual size
  actual="sha256:$(sha256_file "$file")"
  size=$(wc -c <"$file" | tr -d ' ')
  [ "$actual" = "$expected" ] || fail "content-addressed blob hash mismatch"
  [ "$size" -gt 0 ] || fail "content-addressed blob is empty"
  [ -z "$expected_size" ] || [ "$size" -eq "$expected_size" ] ||
    fail "content-addressed blob size mismatch"
}

build_closure() {
  local layout=$1 root=$2 output=$3
  local work=$4
  [ -n "$work" ] || fail "closure workspace is unavailable"
  local queue=$work/queue
  local seen=$work/seen
  : >"$queue"
  : >"$seen"
  printf '%s\t%s\n' "$root" "$(jq -r '.manifests[0].size' "$layout/index.json")" >"$queue"
  local queue_position=1 queue_length digest queue_entry expected_size
  while :; do
    queue_length=$(wc -l <"$queue" | tr -d ' ')
    [ "$queue_position" -le "$queue_length" ] || break
    queue_entry=$(sed -n "${queue_position}p" "$queue")
    digest=${queue_entry%%$'\t'*}
    expected_size=${queue_entry#*$'\t'}
    queue_position=$((queue_position + 1))
    [ -n "$digest" ] || continue
    grep -Fqx "$digest" "$seen" && continue
    printf '%s\n' "$digest" >>"$seen"
    local blob media
    blob=$(layout_blob "$layout" "$digest")
    digest_bytes "$blob" "$digest" "$expected_size"
    media=$(jq -r '.mediaType // empty' "$blob" 2>/dev/null || true)
    [ -n "$media" ] || continue
    case "$media" in
      "$INDEX_MEDIA")
        jq -e '.schemaVersion == 2 and (.manifests | type == "array" and length > 0)' \
          "$blob" >/dev/null || fail "malformed OCI index"
        while IFS= read -r descriptor; do
          validate_descriptor "$descriptor"
          printf '%s\t%s\n' "$(jq -r '.digest' <<<"$descriptor")" \
            "$(jq -r '.size' <<<"$descriptor")" >>"$queue"
        done < <(jq -c '.manifests[]' "$blob")
        ;;
      "$MANIFEST_MEDIA")
        jq -e '.schemaVersion == 2 and (.config | type == "object") and (.layers | type == "array")' \
          "$blob" >/dev/null || fail "malformed OCI manifest"
        while IFS= read -r descriptor; do
          validate_descriptor "$descriptor"
          printf '%s\t%s\n' "$(jq -r '.digest' <<<"$descriptor")" \
            "$(jq -r '.size' <<<"$descriptor")" >>"$queue"
        done < <(jq -c '.config, .layers[]' "$blob")
        ;;
      *) fail "unsupported OCI media type in closure" ;;
    esac
  done

  : >"$output"
  while IFS= read -r digest; do
    local blob media size subject children
    blob=$(layout_blob "$layout" "$digest")
    media=$(jq -r '.mediaType // empty' "$blob" 2>/dev/null || true)
    [ -n "$media" ] || continue
    size=$(wc -c <"$blob" | tr -d ' ')
    subject=$(jq -r '.subject.digest // empty' "$blob")
    children=$(jq -c 'if .mediaType == "'"$INDEX_MEDIA"'" then [.manifests[].digest] | sort
                         elif .mediaType == "'"$MANIFEST_MEDIA"'" then
                           ([.config.digest] + [.layers[].digest]) | sort
                         else [] end' "$blob")
    jq -cnS --arg digest "$digest" --arg mediaType "$media" --argjson size "$size" \
      --arg subjectDigest "${subject:-}" --argjson children "$children" '
      {digest:$digest,mediaType:$mediaType,size:$size,
       subjectDigest:(if $subjectDigest == "" then null else $subjectDigest end),
       children:$children}
    ' >>"$output"
  done < <(sort -u "$seen")
  jq -s 'sort_by(.digest)' "$output" >"$output.sorted"
  mv -- "$output.sorted" "$output"
}

validate_source_identity() {
  local file=$1
  json_file "$file"
  jq -e --arg source "$SOURCE_SHA" --arg tree "$TREE_ID" --arg version "$VERSION" '
    type == "object" and
    (keys | sort) == [
      "authoritySha","clean","detached","remoteSha","schema",
      "sourceSha","treeId","version"
    ] and
    .schema == "meet-backend/dev-promotion-source/v1" and
    .authoritySha == $source and .remoteSha == $source and
    .clean == true and .detached == true and
    (.sourceSha | type == "string" and . == $source) and
    (.treeId | type == "string" and . == $tree) and
    (.version | type == "string" and . == $version)
  ' "$file" >/dev/null || fail "source identity proof does not match"
}

validate_layout_proof() {
  local file=$1 root=$2 platform=$3
  jq -e --arg root "$root" --arg platform "$platform" '
    type == "object" and
    .schema == "meet-backend/test-promotion-layout/v1" and
    .rootDigest == $root and .platformDigest == $platform and
    (.descriptors | type == "array" and length > 0) and
    (.referrerTargets | type == "array") and
    .protectedSubjectsExcluded == true
  ' "$file" >/dev/null || fail "layout proof schema or identity is incomplete"
}

create_proof() {
  [ -n "$LAYOUT" ] && [ -n "$LAYOUT_PROOF" ] && [ -n "$SOURCE_PROOF" ] &&
    [ -n "$BEFORE_INVENTORY" ] && [ -n "$PROTECTED_STATE" ] && [ -n "$OUTPUT" ] || usage_fail
  directory "$LAYOUT" || fail "layout is unsafe"
  for file in "$LAYOUT_PROOF" "$SOURCE_PROOF" "$BEFORE_INVENTORY" "$PROTECTED_STATE"; do
    json_file "$file"
  done
  validate_source_identity "$SOURCE_PROOF"
  local index="$LAYOUT/index.json"
  json_file "$index"
  local root_desc root platform_desc platform
  root_desc=$(jq -c 'if (.manifests | type == "array" and length == 1) then .manifests[0] else empty end' "$index")
  [ -n "$root_desc" ] || fail "layout index must select exactly one root"
  validate_descriptor "$root_desc"
  root=$(jq -r '.digest' <<<"$root_desc")
  local root_blob
  root_blob=$(layout_blob "$LAYOUT" "$root")
  digest_bytes "$root_blob" "$root"
  [ "$(jq -r '.mediaType' <<<"$root_desc")" = "$INDEX_MEDIA" ] ||
    fail "layout root is not an OCI index"
  platform_desc=$(jq -c '
    [.manifests[] | select(.mediaType == "'"$MANIFEST_MEDIA"'" and
      .platform.os == "linux" and .platform.architecture == "amd64")] |
    if length == 1 then .[0] else empty end
  ' "$root_blob")
  [ -n "$platform_desc" ] || fail "layout has no unique linux/amd64 platform"
  validate_descriptor "$platform_desc"
  platform=$(jq -r '.digest' <<<"$platform_desc")
  is_digest "$root" || fail "layout root digest is malformed"
  is_digest "$platform" || fail "layout platform digest is malformed"
  [ "$root" != "$platform" ] || fail "root and platform digests collide"
  platform_blob=$(layout_blob "$LAYOUT" "$platform")
  digest_bytes "$platform_blob" "$platform" "$(jq -r '.size' <<<"$platform_desc")"
  config_descriptor=$(jq -c '.config' "$platform_blob")
  validate_descriptor "$config_descriptor"
  config_blob=$(layout_blob "$LAYOUT" "$(jq -r '.digest' <<<"$config_descriptor")")
  digest_bytes "$config_blob" "$(jq -r '.digest' <<<"$config_descriptor")" \
    "$(jq -r '.size' <<<"$config_descriptor")"
  jq -e --arg source "$SOURCE_SHA" --arg version "$VERSION" '
    .architecture == "amd64" and .os == "linux" and
    (.config.Labels | type == "object") and
    .config.Labels["org.opencontainers.image.source"] ==
      "https://github.com/NickolayMamonov/meet-backend-v3" and
    .config.Labels["org.opencontainers.image.revision"] == $source and
    .config.Labels["org.opencontainers.image.version"] == $version
  ' "$config_blob" >/dev/null || fail "platform config is not source-bound"
  validate_layout_proof "$LAYOUT_PROOF" "$root" "$platform"
  local work closure
  work=$(mktemp -d)
  closure=$work/closure.jsonl
  # The workspace path is intentionally captured for EXIT cleanup.
  # shellcheck disable=SC2064
  trap "rm -r -- '$work'" EXIT HUP INT TERM
  build_closure "$LAYOUT" "$root" "$closure" "$work"
  local before_sha protected_sha layout_sha
  before_sha=$(sha256_json "$BEFORE_INVENTORY")
  protected_sha=$(sha256_json "$PROTECTED_STATE")
  layout_sha=$(sha256_json "$LAYOUT_PROOF")
  local candidate
  candidate=$(mktemp)
  jq -cnS \
    --arg schema "$SCHEMA" --arg image "$IMAGE" --arg sourceSha "$SOURCE_SHA" \
    --arg treeId "$TREE_ID" --arg version "$VERSION" --arg runId "$RUN_ID" \
    --arg runAttempt "$RUN_ATTEMPT" --arg rootDigest "$root" \
    --arg platformDigest "$platform" --arg layoutProofSha256 "$layout_sha" \
    --arg beforeInventorySha256 "$before_sha" \
    --arg protectedStateSha256 "$protected_sha" \
    --argjson closure "$(jq -c . "$closure")" '
    {schema:$schema,image:$image,sourceSha:$sourceSha,treeId:$treeId,
     version:$version,runId:$runId,runAttempt:($runAttempt|tonumber),
     rootDigest:$rootDigest,platformDigest:$platformDigest,
     manifestClosure:($closure | sort_by(.digest)),
     layoutProofSha256:$layoutProofSha256,
     beforeInventorySha256:$beforeInventorySha256,
     protectedStateSha256:$protectedStateSha256}
  ' >"$candidate" || fail "proof construction failed"
  write_atomic "$candidate" "$OUTPUT"
  rm -f -- "$candidate"
  rm -r -- "$work"
  trap - EXIT HUP INT TERM
  jq -e . "$OUTPUT" >/dev/null
  printf '%s\n' "$OUTPUT"
}

verify_proof() {
  for file in "$PROOF" "$INDEX_FILE" "$CANDIDATE_INVENTORY" "$OBSERVED_READER" \
    "$REGISTRY_JOURNAL" "$BEFORE_INVENTORY" "$PROTECTED_STATE" "$LAYOUT_PROOF"; do
    [ -n "$file" ] || usage_fail
    json_file "$file"
  done
  is_sha256 "$EXPECTED_PROOF_SHA" || usage_fail
  [ "$(sha256_file "$PROOF")" = "$EXPECTED_PROOF_SHA" ] ||
    fail "publication proof hash does not match the carried creation hash"
  jq -e --arg schema "$SCHEMA" --arg image "$IMAGE" --arg source "$SOURCE_SHA" \
    --arg tree "$TREE_ID" --arg version "$VERSION" --arg run "$RUN_ID" \
    --arg attempt "$RUN_ATTEMPT" '
    .schema == $schema and .image == $image and .sourceSha == $source and
    .treeId == $tree and .version == $version and .runId == $run and
    (.runAttempt == ($attempt|tonumber)) and
    (.rootDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.platformDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.manifestClosure | type == "array" and length > 0 and
      all(.[]; type == "object" and
        (.digest | test("^sha256:[0-9a-f]{64}$")) and
        (.mediaType | type == "string" and length > 0) and
        (.size | type == "number" and floor == . and . > 0) and
        (.subjectDigest == null or (.subjectDigest | test("^sha256:[0-9a-f]{64}$"))) and
        (.children | type == "array" and all(.[]; test("^sha256:[0-9a-f]{64}$")))) and
      ([.[].digest] | unique | length) == length) and
    (.layoutProofSha256 | test("^[0-9a-f]{64}$")) and
    (.beforeInventorySha256 | test("^[0-9a-f]{64}$")) and
    (.protectedStateSha256 | test("^[0-9a-f]{64}$"))
  ' "$PROOF" >/dev/null || fail "publication proof identity or schema is invalid"
  local proof_before proof_protected layout_sha
  proof_before=$(jq -r '.beforeInventorySha256' "$PROOF")
  proof_protected=$(jq -r '.protectedStateSha256' "$PROOF")
  layout_sha=$(jq -r '.layoutProofSha256' "$PROOF")
  [ "$proof_before" = "$(sha256_file "$BEFORE_INVENTORY")" ] ||
    fail "before inventory identity changed"
  [ "$proof_protected" = "$(sha256_file "$PROTECTED_STATE")" ] ||
    fail "protected state identity changed"
  [ "$layout_sha" = "$(sha256_file "$LAYOUT_PROOF")" ] ||
    fail "layout proof identity changed"
  local root platform alias
  root=$(jq -r '.rootDigest' "$PROOF")
  platform=$(jq -r '.platformDigest' "$PROOF")
  alias="test-sha-$SOURCE_SHA"
  jq -e --arg root "$root" --arg platform "$platform" '
    .schemaVersion == 2 and .mediaType == "'"$INDEX_MEDIA"'" and
    ([.manifests[] | select(.digest == $platform and
      .platform.os == "linux" and .platform.architecture == "amd64")] | length) == 1
  ' "$INDEX_FILE" >/dev/null || fail "selected raw index is not bound to proof"
  local selected_hash
  selected_hash="sha256:$(sha256_file "$INDEX_FILE")"
  [ "$selected_hash" = "$root" ] || fail "selected raw index bytes do not match root digest"
  root_children=$(jq -c '[.manifests[].digest] | sort' "$INDEX_FILE")
  root_size=$(wc -c <"$INDEX_FILE" | tr -d '[:space:]')
  jq -e --arg root "$root" --argjson children "$root_children" \
    --argjson size "$root_size" '
    ([.manifestClosure[] | select(.digest == $root)] | length) == 1 and
    ([.manifestClosure[] | select(.digest == $root)][0] |
      .mediaType == "application/vnd.oci.image.index.v1+json" and
      .size == $size and .children == $children)
  ' "$PROOF" >/dev/null || fail "publication proof root closure is not exact"
  jq -e --arg alias "$alias" --arg root "$root" --arg platform "$platform" '
    (.versions | type == "array") and
    any(.versions[]; .digest == $root and ((.tags // []) | index($alias))) and
    (any(.versions[]; .digest == $platform) or
      any(.versions[]; .digest == $platform[7:]))
  ' "$CANDIDATE_INVENTORY" >/dev/null || fail "candidate inventory is not bound to proof"
  jq -e --arg root "$root" --arg platform "$platform" '
    .state == "partial" and .attestationStatus == "missing" and
    .rootDigest == $root and .platformDigest == $platform
  ' "$OBSERVED_READER" >/dev/null || fail "observed reader snapshot is not bound to proof"
  jq -e --arg run "$RUN_ID" --arg attempt "$RUN_ATTEMPT" --arg source "$SOURCE_SHA" '
    (keys | sort) == [
      "attestationWrite","initialAliasState","registryPublication",
      "runAttempt","runId","schema","sourceSha"
    ] and
    (.initialAliasState == "absent") and
    .registryPublication == "confirmed" and
    .attestationWrite == "notStarted" and
    .sourceSha == $source and
    .runId == ($run|tonumber) and
    .runAttempt == ($attempt|tonumber)
  ' "$REGISTRY_JOURNAL" >/dev/null || fail "current-run publication journal is not confirmed"
  printf '%s\n' "$PROOF"
}

case "$MODE" in
  create) create_proof ;;
  verify) verify_proof ;;
esac
