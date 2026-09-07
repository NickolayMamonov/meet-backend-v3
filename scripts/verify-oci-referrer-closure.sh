#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --image IMAGE --index-file PATH --inventory-file PATH --subject-digest sha256:... --platform-subject sha256:... [--fixture-dir PATH] [--require-bundle --bundle-output PATH] [--output PATH]" >&2
  exit 2
}

fail() {
  echo "OCI referrer closure verification failed: $*" >&2
  exit 1
}

IMAGE=
INDEX_FILE=
INVENTORY_FILE=
SUBJECT_DIGEST=
PLATFORM_SUBJECT=
FIXTURE_DIR=
OUTPUT=
REQUIRE_BUNDLE=0
BUNDLE_OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || usage; IMAGE=$2; shift 2 ;;
    --index-file) [ "$#" -ge 2 ] || usage; INDEX_FILE=$2; shift 2 ;;
    --inventory-file) [ "$#" -ge 2 ] || usage; INVENTORY_FILE=$2; shift 2 ;;
    --subject-digest) [ "$#" -ge 2 ] || usage; SUBJECT_DIGEST=$2; shift 2 ;;
    --platform-subject) [ "$#" -ge 2 ] || usage; PLATFORM_SUBJECT=$2; shift 2 ;;
    --fixture-dir) [ "$#" -ge 2 ] || usage; FIXTURE_DIR=$2; shift 2 ;;
    --require-bundle) [ "$REQUIRE_BUNDLE" -eq 0 ] || usage; REQUIRE_BUNDLE=1; shift ;;
    --bundle-output) [ "$#" -ge 2 ] || usage; [ -z "$BUNDLE_OUTPUT" ] || usage; BUNDLE_OUTPUT=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
[ -f "$INDEX_FILE" ] || usage
[ -f "$INVENTORY_FILE" ] || usage
[[ "$SUBJECT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$PLATFORM_SUBJECT" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[ -n "$FIXTURE_DIR" ] || command -v docker >/dev/null 2>&1 ||
  fail "docker is required for live OCI manifest reads"
[ "$REQUIRE_BUNDLE" -eq 0 ] || [ -n "$BUNDLE_OUTPUT" ] ||
  fail "--bundle-output is required with --require-bundle"
[ -z "$BUNDLE_OUTPUT" ] || [ ! -L "$BUNDLE_OUTPUT" ] ||
  fail "bundle output is unsafe"
[ -z "$BUNDLE_OUTPUT" ] || [ ! -e "$BUNDLE_OUTPUT" ] || [ -f "$BUNDLE_OUTPUT" ] ||
  fail "bundle output is unsafe"
[ -z "$BUNDLE_OUTPUT" ] || [ -d "$(dirname -- "$BUNDLE_OUTPUT")" ] ||
  fail "bundle output directory is unavailable"
[ -z "$OUTPUT" ] || [ ! -L "$OUTPUT" ] ||
  fail "closure output is unsafe"
[ -z "$OUTPUT" ] || [ ! -e "$OUTPUT" ] || [ -f "$OUTPUT" ] ||
  fail "closure output is unsafe"
[ -z "$OUTPUT" ] || [ -d "$(dirname -- "$OUTPUT")" ] ||
  fail "closure output directory is unavailable"

WORK_DIR=$(mktemp -d)
temporary_bundle=
temporary_output=
cleanup_workspace() {
  local status=$?
  trap - EXIT HUP INT TERM
  [ -z "$temporary_bundle" ] || rm -f -- "$temporary_bundle"
  [ -z "$temporary_output" ] || rm -f -- "$temporary_output"
  rm -r -- "$WORK_DIR"
  exit "$status"
}
trap cleanup_workspace EXIT HUP INT TERM
REFERRERS=$WORK_DIR/referrers
INVENTORY_DIGESTS=$WORK_DIR/inventory-digests
ATTRIBUTIONS=$WORK_DIR/attributions.jsonl
: >"$ATTRIBUTIONS"
BUNDLE_MANIFEST=
BUNDLE_LAYER=
BUNDLE_LAYER_MEDIA=
BUNDLE_LAYER_SIZE=
actual_media=
referrer_descriptor=
current_referrer_descriptor=
node_media=
bundle_layer_fields=

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "OCI digest is malformed"
}

read_descriptor() {
  local descriptor=$1 expected_digest=${2:-}
  local input output
  input=$(mktemp "$WORK_DIR/jq-input.XXXXXX")
  output=$(mktemp "$WORK_DIR/jq-value.XXXXXX")
  printf '%s\n' "$descriptor" >"$input"
  jq -r --arg expected "$expected_digest" '
    if type != "object" or
       (.digest | type != "string" or
        (test("^sha256:[0-9a-f]{64}$") | not)) or
       ($expected != "" and .digest != $expected) or
       (.mediaType | type != "string" or length == 0) or
       (.size | type != "number" or floor != . or . < 0)
    then error("invalid OCI descriptor")
    else [
      .digest,
      .mediaType,
      (.size | tostring),
      (.annotations["in-toto.io/predicate-type"] // ""),
      (.annotations["vnd.docker.reference.type"] // ""),
      (.annotations["vnd.docker.reference.digest"] // ""),
      (.platform.os // ""),
      (.platform.architecture // "")
    ] | join("\u001c")
    end
  ' "$input" >"$output" || fail "OCI descriptor is malformed"
  IFS=$'\034' read -r DESCRIPTOR_DIGEST DESCRIPTOR_MEDIA DESCRIPTOR_SIZE \
    DESCRIPTOR_PREDICATE DESCRIPTOR_REFERENCE_TYPE DESCRIPTOR_REFERENCE_DIGEST \
    DESCRIPTOR_OS DESCRIPTOR_ARCH <"$output" || fail "OCI descriptor is malformed"
  : "$DESCRIPTOR_REFERENCE_TYPE" "$DESCRIPTOR_REFERENCE_DIGEST" \
    "$DESCRIPTOR_OS" "$DESCRIPTOR_ARCH"
  rm -f -- "$input" "$output"
}

jq_read() {
  local variable=$1
  shift
  local output value
  output=$(mktemp "$WORK_DIR/jq-value.XXXXXX")
  jq "$@" >"$output" || fail "JSON value could not be read"
  if IFS= read -r value <"$output"; then
    value=${value%$'\r'}
  else
    value=
  fi
  printf -v "$variable" '%s' "$value"
  rm -f -- "$output"
}

jq_read_text() {
  local variable=$1 text=$2
  shift 2
  local input output value
  input=$(mktemp "$WORK_DIR/jq-input.XXXXXX")
  output=$(mktemp "$WORK_DIR/jq-value.XXXXXX")
  printf '%s\n' "$text" >"$input"
  jq "$@" "$input" >"$output" || fail "JSON value could not be read"
  if IFS= read -r value <"$output"; then
    value=${value%$'\r'}
  else
    value=
  fi
  printf -v "$variable" '%s' "$value"
  rm -f -- "$input" "$output"
}

jq -e \
  --arg subject "$SUBJECT_DIGEST" \
  --arg platform "$PLATFORM_SUBJECT" '
    type == "object" and
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.index.v1+json" and
    (.manifests | type == "array" and length > 0) and
    ([
      .manifests[] |
      select(
        .mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .platform.os == "linux" and
        .platform.architecture == "amd64"
      )
    ] | length) == 1 and
    any(.manifests[];
      .digest == $platform and
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      .platform.os == "linux" and
      .platform.architecture == "amd64"
    ) and
    all(.manifests[];
      (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
       .mediaType == "application/vnd.oci.image.index.v1+json") and
      (
        (.mediaType == "application/vnd.oci.image.manifest.v1+json" and
         .platform.os == "linux" and .platform.architecture == "amd64") or
        (
          .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
          (.annotations["vnd.docker.reference.digest"] == $platform or
           .annotations["vnd.docker.reference.digest"] == $subject)
        )
      )
    )
  ' "$INDEX_FILE" >/dev/null ||
  fail "top-level OCI index contains an invalid subject or foreign descriptor"

jq -e '
  ([.manifests[].digest] | length) ==
    ([.manifests[].digest] | unique | length)
' "$INDEX_FILE" >/dev/null ||
  fail "top-level OCI index contains duplicate descriptors"

while IFS= read -r descriptor; do
  read_descriptor "$descriptor"
done <<<"$(jq -c '.manifests[]' "$INDEX_FILE")"

jq -r \
  --arg subject "$SUBJECT_DIGEST" \
  --arg platform "$PLATFORM_SUBJECT" '
    .manifests[] |
    select(
      .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
      (.annotations["vnd.docker.reference.digest"] == $subject or
       .annotations["vnd.docker.reference.digest"] == $platform)
    ) | .digest
  ' "$INDEX_FILE" | tr -d '\r' | sort -u >"$REFERRERS"
[ -s "$REFERRERS" ] || fail "subject-bound OCI referrer descriptors are missing"
declare -A referrer_set=()
while IFS= read -r digest; do referrer_set["$digest"]=1; done <"$REFERRERS"

jq -r --arg subject "$SUBJECT_DIGEST" '
  .versions[] | select(.digest != $subject) | .digest
' "$INVENTORY_FILE" | tr -d '\r' | sort -u >"$INVENTORY_DIGESTS"
[ -s "$INVENTORY_DIGESTS" ] || fail "package inventory has no child or referrer versions"
while IFS= read -r digest; do validate_digest "$digest"; done <"$INVENTORY_DIGESTS"
declare -A inventory_set=()
while IFS= read -r digest; do inventory_set["$digest"]=1; done <"$INVENTORY_DIGESTS"
while IFS= read -r digest; do
  [ "${inventory_set[$digest]+present}" = present ] ||
    fail "top-level subject-bound referrer is absent from package inventory"
done <"$REFERRERS"

fetch_raw() {
  local digest=$1 destination=$2 expected_media=${3:-} expected_size=${4:-}
  if [ -n "$FIXTURE_DIR" ]; then
    local fixture="$FIXTURE_DIR/${digest#sha256:}.json"
    [ -f "$fixture" ] || fixture="$FIXTURE_DIR/data/${digest#sha256:}.json"
    [ -f "$fixture" ] || fail "OCI child manifest is missing"
    cp -- "$fixture" "$destination" ||
      fail "OCI child manifest could not be read"
  else
    docker buildx imagetools inspect --raw "$IMAGE@$digest" >"$destination" ||
      fail "OCI child manifest lookup failed"
  fi
  jq -e 'type == "object"' "$destination" >/dev/null ||
    fail "OCI child response is not a JSON object"
  if [ "$REQUIRE_BUNDLE" -eq 1 ]; then
    actual_digest="sha256:$(sha256sum "$destination" | awk '{print $1}')"
    actual_size=$(wc -c <"$destination" | tr -d ' ')
    [ "$actual_digest" = "$digest" ] ||
      fail "OCI child bytes do not match its descriptor digest"
    if [ -n "$expected_media" ]; then
      jq_read actual_media -r '.mediaType // empty' "$destination"
      [ "$actual_media" = "$expected_media" ] ||
        fail "OCI child media type disagrees with its descriptor"
    fi
    [ -z "$expected_size" ] || [ "$actual_size" -eq "$expected_size" ] ||
      fail "OCI child bytes do not match its descriptor size"
  fi
}

fetch_bundle_bytes() {
  local digest=$1 destination=$2
  if [ -n "$FIXTURE_DIR" ]; then
    local candidate
    for candidate in \
      "$FIXTURE_DIR/${digest#sha256:}" \
      "$FIXTURE_DIR/${digest#sha256:}.bundle" \
      "$FIXTURE_DIR/${digest#sha256:}.json" \
      "$FIXTURE_DIR/bundles/${digest#sha256:}" \
      "$FIXTURE_DIR/bundles/${digest#sha256:}.json"; do
      if [ -f "$candidate" ]; then
        cp -- "$candidate" "$destination" ||
          fail "Sigstore bundle fixture could not be read"
        return
      fi
    done
    fail "Sigstore bundle bytes are missing from the fixture"
  fi
  command -v curl >/dev/null 2>&1 ||
    fail "curl is required for live Sigstore bundle reads"
  local registry="${IMAGE#ghcr.io/}"
  local token_url="https://ghcr.io/token?scope=repository:${registry}:pull"
  local token
  token=$(curl --fail --silent --show-error --location --max-time 10 \
    "$token_url" | jq -r '.token // empty') ||
    fail "GHCR bundle authorization failed"
  [ -n "$token" ] || fail "GHCR bundle authorization returned no token"
  curl --fail --silent --show-error --location --max-time 10 \
    -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.dev.sigstore.bundle.v0.3+json' \
    "https://ghcr.io/v2/$registry/blobs/$digest" >"$destination" ||
    fail "GHCR Sigstore bundle read failed"
}

REACHABLE=$WORK_DIR/reachable
VISITED=$WORK_DIR/visited
: >"$REACHABLE"
: >"$VISITED"
declare -A reachable_set=()
declare -A visited_set=()

mark_reachable() {
  local digest=$1
  if [ "${reachable_set[$digest]+present}" != present ]; then
    reachable_set["$digest"]=1
    printf '%s\n' "$digest" >>"$REACHABLE"
  fi
}

collect_reachable() {
  local digest=$1 depth=$2 expected_media=${3:-} expected_size=${4:-}
  local file media descriptor child child_media child_size
  [ "$depth" -le 8 ] || fail "OCI referrer graph exceeds the verification bound"
  validate_digest "$digest"
  mark_reachable "$digest"
  if [ "${visited_set[$digest]+present}" = present ]; then
    return
  fi
  visited_set["$digest"]=1
  printf '%s\n' "$digest" >>"$VISITED"
  file=$WORK_DIR/node-${digest#sha256:}.json
  fetch_raw "$digest" "$file" "$expected_media" "$expected_size"
  jq_read media -r '.mediaType // empty' "$file"
  case "$media" in
    application/vnd.oci.image.index.v1+json)
      jq -e '
        .schemaVersion == 2 and
        (.manifests | type == "array" and length > 0)
      ' "$file" >/dev/null || fail "reachable OCI referrer index is invalid"
      while IFS= read -r descriptor; do
        read_descriptor "$descriptor"
        child=$DESCRIPTOR_DIGEST
        child_media=$DESCRIPTOR_MEDIA
        child_size=$DESCRIPTOR_SIZE
        case "$child_media" in
          application/vnd.oci.image.manifest.v1+json|\
          application/vnd.oci.image.index.v1+json) ;;
          *) fail "reachable OCI child media type is foreign" ;;
        esac
        collect_reachable "$child" "$((depth + 1))" "$child_media" "$child_size"
      done <<<"$(jq -c '.manifests[]' "$file")"
      ;;
    application/vnd.oci.image.manifest.v1+json|\
    application/vnd.docker.attestation.manifest.v1+json)
      jq -e '.schemaVersion == 2' "$file" >/dev/null ||
        fail "reachable OCI manifest schema is invalid"
      ;;
    *) fail "reachable OCI node has an unsupported media type: $media ($digest)" ;;
  esac
}

MARKER="sha256-${SUBJECT_DIGEST#sha256:}"
MARKER_DIGESTS=$WORK_DIR/marker-digests
jq -r --arg marker "$MARKER" '
  .versions[] | select((.tags | index($marker)) != null) | .digest
' "$INVENTORY_FILE" | tr -d '\r' | sort -u >"$MARKER_DIGESTS"
[ "$(wc -l <"$MARKER_DIGESTS" | tr -d ' ')" -le 1 ] ||
  fail "subject marker identifies multiple package versions"
MARKER_ROOT=$(head -1 "$MARKER_DIGESTS" || true)

platform_descriptor_file=$WORK_DIR/platform-descriptor
jq -c --arg platform "$PLATFORM_SUBJECT" \
  '.manifests[] | select(.digest == $platform)' "$INDEX_FILE" \
  >"$platform_descriptor_file" ||
  fail "platform descriptor could not be read"
IFS= read -r platform_descriptor <"$platform_descriptor_file"
read_descriptor "$platform_descriptor" "$PLATFORM_SUBJECT"
platform_media=$DESCRIPTOR_MEDIA
platform_size=$DESCRIPTOR_SIZE
mark_reachable "$PLATFORM_SUBJECT"
collect_reachable "$PLATFORM_SUBJECT" 0 "$platform_media" "$platform_size"
while IFS= read -r digest; do
  mark_reachable "$digest"
  jq_read referrer_descriptor -c --arg digest "$digest" \
    '.manifests[] | select(.digest == $digest)' "$INDEX_FILE"
  read_descriptor "$referrer_descriptor" "$digest"
  referrer_media=$DESCRIPTOR_MEDIA
  referrer_size=$DESCRIPTOR_SIZE
  collect_reachable "$digest" 0 "$referrer_media" "$referrer_size"
done <"$REFERRERS"
if [ -n "$MARKER_ROOT" ] &&
   [ "${reachable_set[$MARKER_ROOT]+present}" != present ]; then
  collect_reachable "$MARKER_ROOT" 0
  marker_file=$WORK_DIR/node-${MARKER_ROOT#sha256:}.json
  jq -e '.mediaType == "application/vnd.oci.image.index.v1+json"' \
    "$marker_file" >/dev/null ||
    fail "subject marker does not identify a referrer index"
fi

while IFS= read -r digest; do
  [ "${reachable_set[$digest]+present}" = present ] ||
    fail "package inventory version is absent from the referrer graph"
done <"$INVENTORY_DIGESTS"

NODE_PROVENANCE=0
NODE_SBOM=0
NODE_SIGNATURE=0
validate_image_manifest() {
  local file=$1
  jq -e '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    (.config | type == "object") and
    (.layers | type == "array")
  ' "$file" >/dev/null || fail "subject OCI manifest shape is invalid"
  jq_read descriptor -c '.config' "$file"
  read_descriptor "$descriptor"
  jq -e '
    (.config.mediaType == "application/vnd.oci.image.config.v1+json" or
     .config.mediaType == "application/vnd.oci.empty.v1+json") and
    all(.layers[];
      (.mediaType == "application/vnd.oci.image.layer.v1.tar+gzip" or
       .mediaType == "application/vnd.oci.image.layer.v1.tar+zstd" or
       .mediaType == "application/vnd.oci.image.rootfs.diff.tar.gzip"))
  ' "$file" >/dev/null || fail "subject OCI manifest descriptor media type is invalid"
  while IFS= read -r descriptor; do read_descriptor "$descriptor"; done <<<"$(jq -c '.layers[]' "$file")"
}

validate_node() {
  local digest=$1 inherited_subject=$2 depth=$3 allow_inherited=$4
  local expected_media=${5:-} expected_size=${6:-}
  local file media descriptor child child_media child_size declared_subject
  [ "$depth" -le 8 ] || fail "OCI referrer graph exceeds the verification bound"
  file=$WORK_DIR/node-${digest#sha256:}.json
  fetch_raw "$digest" "$file" "$expected_media" "$expected_size"
  jq_read media -r '.mediaType // empty' "$file"
  case "$media" in
    application/vnd.oci.image.index.v1+json)
      jq -e '
        .schemaVersion == 2 and
        (.manifests | type == "array" and length > 0)
      ' "$file" >/dev/null || fail "nested OCI referrer index is invalid"
      if jq -e '.subject != null' "$file" >/dev/null; then
        jq_read declared_subject -r '.subject.digest // empty' "$file"
        validate_digest "$declared_subject"
        [ "$declared_subject" = "$SUBJECT_DIGEST" ] ||
          [ "$declared_subject" = "$PLATFORM_SUBJECT" ] ||
          fail "nested OCI index subject is not the release image"
        NODE_BOUND=1
      fi
      while IFS= read -r descriptor; do
        read_descriptor "$descriptor"
        child=$DESCRIPTOR_DIGEST
        child_media=$DESCRIPTOR_MEDIA
        child_size=$DESCRIPTOR_SIZE
        case "$child_media" in
          application/vnd.oci.image.manifest.v1+json|\
          application/vnd.oci.image.index.v1+json) ;;
          *) fail "nested OCI child media type is foreign" ;;
        esac
        validate_node "$child" "$inherited_subject" "$((depth + 1))" \
          "$allow_inherited" "$child_media" "$child_size"
      done <<<"$(jq -c '.manifests[]' "$file")"
      ;;
    application/vnd.oci.image.manifest.v1+json|\
    application/vnd.docker.attestation.manifest.v1+json)
      if jq -e '.subject != null' "$file" >/dev/null; then
        jq_read declared_subject -r '.subject.digest // empty' "$file"
        validate_digest "$declared_subject"
        [ "$declared_subject" = "$SUBJECT_DIGEST" ] ||
          [ "$declared_subject" = "$PLATFORM_SUBJECT" ] ||
          fail "OCI referrer subject is not the release image"
        NODE_BOUND=1
      elif [ "$allow_inherited" -eq 1 ]; then
        NODE_BOUND=1
      fi
      jq -e '
        .schemaVersion == 2 and
        (.config | type == "object") and
        (.layers | type == "array" and length > 0)
      ' "$file" >/dev/null || fail "OCI referrer manifest shape is invalid"
      jq_read descriptor -c '.config' "$file"
      read_descriptor "$descriptor"
      jq -e '
        (.config.mediaType == "application/vnd.oci.image.config.v1+json" or
         .config.mediaType == "application/vnd.oci.empty.v1+json")
      ' "$file" >/dev/null || fail "OCI referrer config media type is invalid"
      while IFS= read -r descriptor; do
        read_descriptor "$descriptor"
        child_media=$DESCRIPTOR_MEDIA
        case "$child_media" in
          application/vnd.in-toto+json|\
          application/spdx+json|\
          application/vnd.spdx+json|\
          application/vnd.cyclonedx+json|\
          application/vnd.oci.image.layer.v1.tar+gzip|\
          application/vnd.dev.sigstore.bundle.v0.3+json) ;;
          *) fail "OCI referrer layer media type is foreign" ;;
        esac
        predicate=$DESCRIPTOR_PREDICATE
        case "$predicate" in
          *slsa.dev/provenance*|*in-toto.io/Statement*) NODE_PROVENANCE=1 ;;
          *spdx.dev/Document*|*cyclonedx.org/bom*) NODE_SBOM=1 ;;
          "") [ "$child_media" = "application/vnd.dev.sigstore.bundle.v0.3+json" ] ||
              fail "OCI referrer predicate is missing" ;;
          *) fail "OCI referrer predicate is not provenance or SBOM" ;;
        esac
        if [ "$child_media" = "application/vnd.dev.sigstore.bundle.v0.3+json" ]; then
          NODE_SIGNATURE=1
        fi
      done <<<"$(jq -c '.layers[]' "$file")"
      ;;
    *) fail "OCI referrer node has an unsupported media type" ;;
  esac
}

NODE_BOUND=0
NODE_PROVENANCE=0
NODE_SBOM=0
NODE_SIGNATURE=0

while IFS= read -r digest; do
  NODE_PROVENANCE=0
  NODE_SBOM=0
  NODE_SIGNATURE=0
  NODE_BOUND=0
  subject=
  kind=
  if [ "$digest" = "$PLATFORM_SUBJECT" ]; then
    platform_file=$WORK_DIR/platform-${digest#sha256:}.json
    fetch_raw "$digest" "$platform_file" "$platform_media" "$platform_size"
    validate_image_manifest "$platform_file"
    NODE_BOUND=1
    kind=subject
    subject=$SUBJECT_DIGEST
  elif [ "${referrer_set[$digest]+present}" = present ]; then
    jq_read current_referrer_descriptor -c --arg digest "$digest" \
      '.manifests[] | select(.digest == $digest)' "$INDEX_FILE"
    read_descriptor "$current_referrer_descriptor" "$digest"
    current_referrer_media=$DESCRIPTOR_MEDIA
    current_referrer_size=$DESCRIPTOR_SIZE
    jq_read subject -r --arg digest "$digest" '
      .manifests[] | select(.digest == $digest) |
      .annotations["vnd.docker.reference.digest"]
    ' "$INDEX_FILE"
    validate_node "$digest" "$subject" 0 1 \
      "$current_referrer_media" "$current_referrer_size"
  elif [ "$digest" = "$MARKER_ROOT" ]; then
    validate_node "$digest" "$SUBJECT_DIGEST" 0 0
  else
    validate_node "$digest" "$SUBJECT_DIGEST" 0 1
  fi
  [ "$NODE_BOUND" -eq 1 ] ||
    fail "OCI package version is not subject-bound"
  if [ "$kind" = subject ]; then
    :
  elif [ "$NODE_SIGNATURE" -eq 1 ] && [ "$NODE_PROVENANCE" -eq 0 ] &&
     [ "$NODE_SBOM" -eq 0 ]; then
    kind=signature
  elif [ "$NODE_PROVENANCE" -eq 1 ] && [ "$NODE_SBOM" -eq 1 ]; then
    kind=referrer
  elif [ "$NODE_PROVENANCE" -eq 1 ]; then
    kind=provenance
  elif [ "$NODE_SBOM" -eq 1 ]; then
    kind=sbom
  else
    kind=referrer
  fi
  subject=${subject:-$SUBJECT_DIGEST}
  node_file=$WORK_DIR/node-${digest#sha256:}.json
  jq_read node_media -r '.mediaType // empty' "$node_file"
  if [ "$REQUIRE_BUNDLE" -eq 1 ] &&
     [ "$NODE_SIGNATURE" -eq 1 ] &&
     [ "$node_media" = "application/vnd.oci.image.manifest.v1+json" ]; then
    [ -z "$BUNDLE_MANIFEST" ] || fail "multiple Sigstore manifests are reachable"
    BUNDLE_MANIFEST=$digest
    jq_read bundle_layer_fields -r '
      [.layers[] |
        select(.mediaType == "application/vnd.dev.sigstore.bundle.v0.3+json")] |
      if length == 1 then
        [length, .[0].digest, .[0].mediaType, (.[0].size | tostring)] |
          map(tostring) | join("\u001f")
      else
        [length, "", "", ""] | join("\u001f")
      end
    ' "$node_file"
    IFS=$'\x1f' read -r local_bundle_layer_count BUNDLE_LAYER \
      BUNDLE_LAYER_MEDIA BUNDLE_LAYER_SIZE <<<"$bundle_layer_fields"
    [ "$local_bundle_layer_count" -eq 1 ] ||
      fail "Sigstore manifest does not contain exactly one bundle layer"
  fi
  jq -cn \
    --arg digest "$digest" \
    --arg subject "$subject" \
    --arg platform "$PLATFORM_SUBJECT" \
    --arg kind "$kind" \
    '{digest:$digest,attribution:{
      verified:true,subject:$subject,platformSubject:$platform,kind:$kind
    }}' >>"$ATTRIBUTIONS"
done <"$INVENTORY_DIGESTS"

if [ "$REQUIRE_BUNDLE" -eq 1 ]; then
  [ -n "$BUNDLE_MANIFEST" ] || fail "a reachable Sigstore manifest is required"
  [[ "$BUNDLE_LAYER" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "Sigstore bundle layer digest is malformed"
  [ "$BUNDLE_LAYER_MEDIA" = "application/vnd.dev.sigstore.bundle.v0.3+json" ] ||
    fail "Sigstore bundle layer media type is invalid"
  [[ "$BUNDLE_LAYER_SIZE" =~ ^[0-9]+$ ]] && [ "$BUNDLE_LAYER_SIZE" -gt 0 ] ||
    fail "Sigstore bundle layer size is invalid"
  bundle_file=$WORK_DIR/bundle
  fetch_bundle_bytes "$BUNDLE_LAYER" "$bundle_file"
  actual_bundle_size=$(wc -c <"$bundle_file" | tr -d ' ')
  [ "$actual_bundle_size" -eq "$BUNDLE_LAYER_SIZE" ] ||
    fail "Sigstore bundle size disagrees with its descriptor"
  actual_bundle_digest="sha256:$(sha256sum "$bundle_file" | awk '{print $1}')"
  [ "$actual_bundle_digest" = "$BUNDLE_LAYER" ] ||
    fail "Sigstore bundle bytes disagree with its descriptor"
  jq -e '
    type == "object" and
    (.mediaType? // "application/vnd.dev.sigstore.bundle.v0.3+json") ==
      "application/vnd.dev.sigstore.bundle.v0.3+json"
  ' "$bundle_file" >/dev/null ||
    fail "Sigstore bundle JSON is malformed"
  [ ! -e "$BUNDLE_OUTPUT.tmp.$$" ] && [ ! -L "$BUNDLE_OUTPUT.tmp.$$" ] ||
    fail "bundle output staging path is unsafe"
  temporary_bundle=$BUNDLE_OUTPUT.tmp.$$
  cp -- "$bundle_file" "$temporary_bundle" || fail "bundle output staging failed"
  chmod 600 "$temporary_bundle" 2>/dev/null || true
  mv -f -- "$temporary_bundle" "$BUNDLE_OUTPUT" ||
    fail "bundle output publication failed"
  temporary_bundle=
fi

jq \
  --slurpfile attrs "$ATTRIBUTIONS" \
  --arg subject "$SUBJECT_DIGEST" '
    .versions |= map(
      . as $version |
      if .digest == $subject then .
      else
        ($attrs | map(select(.digest == $version.digest))[0]) as $match |
        if $match == null then error("missing referrer attribution")
        else .attribution = $match.attribution
        end
      end
    )
  ' "$INVENTORY_FILE" >"$WORK_DIR/inventory-attributed.json" ||
  fail "normalized OCI referrer inventory could not be emitted"

if [ -n "$OUTPUT" ]; then
  [ ! -e "$OUTPUT" ] || [ -f "$OUTPUT" ] ||
    fail "closure output is unsafe"
  [ ! -e "$OUTPUT.tmp.$$" ] && [ ! -L "$OUTPUT.tmp.$$" ] ||
    fail "closure output staging path is unsafe"
  temporary_output=$OUTPUT.tmp.$$
  if [ "$REQUIRE_BUNDLE" -eq 1 ]; then
    jq -cS \
      --arg signatureManifestDigest "$BUNDLE_MANIFEST" \
      --arg bundleLayerDigest "$BUNDLE_LAYER" \
      --argjson bundleLayerSize "$BUNDLE_LAYER_SIZE" \
      --arg bundleLayerMediaType "$BUNDLE_LAYER_MEDIA" \
      --arg bundleDigest "$actual_bundle_digest" \
      '. + {bundle:{
        signatureManifestDigest:$signatureManifestDigest,
        bundleLayerDigest:$bundleLayerDigest,
        bundleLayerSize:$bundleLayerSize,
        bundleLayerMediaType:$bundleLayerMediaType,
        bundleDigest:$bundleDigest
      }}' "$WORK_DIR/inventory-attributed.json" >"$temporary_output" ||
      fail "closure evidence could not be emitted"
    mv -f -- "$temporary_output" "$OUTPUT"
    temporary_output=
  else
    mv "$WORK_DIR/inventory-attributed.json" "$OUTPUT"
    temporary_output=
  fi
else
  if [ "$REQUIRE_BUNDLE" -eq 1 ]; then
    jq -cS \
      --arg signatureManifestDigest "$BUNDLE_MANIFEST" \
      --arg bundleLayerDigest "$BUNDLE_LAYER" \
      --argjson bundleLayerSize "$BUNDLE_LAYER_SIZE" \
      --arg bundleLayerMediaType "$BUNDLE_LAYER_MEDIA" \
      --arg bundleDigest "$actual_bundle_digest" \
      '. + {bundle:{
        signatureManifestDigest:$signatureManifestDigest,
        bundleLayerDigest:$bundleLayerDigest,
        bundleLayerSize:$bundleLayerSize,
        bundleLayerMediaType:$bundleLayerMediaType,
        bundleDigest:$bundleDigest
      }}'
  else
    cat "$WORK_DIR/inventory-attributed.json"
  fi
fi
