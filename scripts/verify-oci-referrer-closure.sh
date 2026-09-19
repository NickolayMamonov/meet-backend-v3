#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --image IMAGE --index-file PATH --inventory-file PATH --subject-digest sha256:... --platform-subject sha256:... [--promotion-baseline-file PATH --protected-state-file PATH --candidate-alias ALIAS] [--fixture-dir PATH] [--output PATH]" >&2
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
PROMOTION_BASELINE=
PROMOTION_PROTECTED=
CANDIDATE_ALIAS=
REQUIRE_SIGNATURE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || usage; IMAGE=$2; shift 2 ;;
    --index-file) [ "$#" -ge 2 ] || usage; INDEX_FILE=$2; shift 2 ;;
    --inventory-file) [ "$#" -ge 2 ] || usage; INVENTORY_FILE=$2; shift 2 ;;
    --subject-digest) [ "$#" -ge 2 ] || usage; SUBJECT_DIGEST=$2; shift 2 ;;
    --platform-subject) [ "$#" -ge 2 ] || usage; PLATFORM_SUBJECT=$2; shift 2 ;;
    --fixture-dir) [ "$#" -ge 2 ] || usage; FIXTURE_DIR=$2; shift 2 ;;
    --output) [ "$#" -ge 2 ] || usage; OUTPUT=$2; shift 2 ;;
    --promotion-baseline-file) [ "$#" -ge 2 ] || usage; PROMOTION_BASELINE=$2; shift 2 ;;
    --protected-state-file) [ "$#" -ge 2 ] || usage; PROMOTION_PROTECTED=$2; shift 2 ;;
    --candidate-alias) [ "$#" -ge 2 ] || usage; CANDIDATE_ALIAS=$2; shift 2 ;;
    --require-signature) [ "$#" -ge 2 ] || usage; REQUIRE_SIGNATURE=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$INDEX_FILE" ] || usage
[ -f "$INVENTORY_FILE" ] || usage
[[ "$SUBJECT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$PLATFORM_SUBJECT" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[ -n "$FIXTURE_DIR" ] || command -v docker >/dev/null 2>&1 ||
  fail "docker is required for live OCI manifest reads"
[ -z "$PROMOTION_BASELINE" ] && [ -z "$PROMOTION_PROTECTED" ] &&
  [ -z "$CANDIDATE_ALIAS" ] || {
  [ -f "$PROMOTION_BASELINE" ] && [ -f "$PROMOTION_PROTECTED" ] &&
    [[ "$CANDIDATE_ALIAS" =~ ^test-sha-[0-9a-f]{40}$ ]] ||
    usage
}
[ "$REQUIRE_SIGNATURE" = true ] || [ "$REQUIRE_SIGNATURE" = false ] || usage
[ "sha256:$(sha256sum -- "$INDEX_FILE" | awk '{print $1}')" = "$SUBJECT_DIGEST" ] ||
  fail "selected OCI index bytes do not match the subject digest"
PROMOTION=false
[ -z "$PROMOTION_BASELINE" ] || PROMOTION=true

WORK_DIR=$(mktemp -d)
trap 'rm -r -- "$WORK_DIR"' EXIT HUP INT TERM
REFERRERS=$WORK_DIR/referrers
INVENTORY_DIGESTS=$WORK_DIR/inventory-digests
ATTRIBUTIONS=$WORK_DIR/attributions.jsonl
: >"$ATTRIBUTIONS"

if [ "$PROMOTION" = true ]; then
  jq -e '
    type == "array" and length > 0 and all(.[]; type == "array") and
    all(.[][];
      type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.metadata.container.tags | type == "array" and
        all(.[]; type == "string" and length > 0))
    ) and
    ([.[][] | .id] | unique | length) == ([.[][]] | length) and
    ([.[][] | .name] | unique | length) == ([.[][]] | length) and
    ([.[][] | .metadata.container.tags[]] | unique | length) ==
      ([.[][] | .metadata.container.tags[]] | length)
  ' "$PROMOTION_BASELINE" >/dev/null ||
    fail "promotion baseline snapshot is malformed"
  jq -e '
    type == "array" and length > 0 and all(.[]; type == "array") and
    all(.[][]; type == "object" and
      (.id | type == "number" and floor == . and . > 0) and
      (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      (.metadata.container.tags | type == "array" and
        all(.[]; type == "string" and length > 0)))
  ' "$INVENTORY_FILE" >/dev/null ||
    fail "promotion fresh snapshot is malformed"
  jq -c --arg subject "$SUBJECT_DIGEST" --arg alias "$CANDIDATE_ALIAS" '
    [.[][]] as $rows |
    {digest:$subject,aliases:{($alias):$subject},latest:null,
     versions:[$rows[] | {
       id,digest:.name,tags:.metadata.container.tags
     }]}
  ' "$INVENTORY_FILE" >"$WORK_DIR/promotion-inventory.json" ||
    fail "promotion inventory normalization failed"
  INVENTORY_FILE=$WORK_DIR/promotion-inventory.json
fi

validate_digest() {
  [[ "$1" =~ ^sha256:[0-9a-f]{64}$ ]] ||
    fail "OCI digest is malformed"
}

validate_descriptor() {
  local descriptor=$1 expected_digest=${2:-}
  jq -e --arg expected "$expected_digest" '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    ($expected == "" or .digest == $expected) and
    (.mediaType | type == "string" and length > 0) and
    (.size | type == "number" and floor == . and . > 0)
  ' <<<"$descriptor" >/dev/null ||
    fail "OCI descriptor is malformed"
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
      .mediaType == "application/vnd.oci.image.manifest.v1+json" and
      (
        (.platform.os == "linux" and .platform.architecture == "amd64") or
        (
          .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
          (.annotations["vnd.docker.reference.digest"] == $platform or
           .annotations["vnd.docker.reference.digest"] == $subject)
        )
      )
    )
  ' "$INDEX_FILE" >/dev/null ||
  fail "top-level OCI index contains an invalid subject or foreign descriptor"

while IFS= read -r descriptor; do
  validate_descriptor "$descriptor"
done < <(jq -c '.manifests[]' "$INDEX_FILE")

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

if [ "$PROMOTION" = true ]; then
  jq -r --arg platform "$PLATFORM_SUBJECT" \
    '[$platform, (.manifests[] | .digest)] | unique[]' \
    "$INDEX_FILE" |
    tr -d '\r' | sort -u >"$INVENTORY_DIGESTS" ||
    fail "package inventory digest projection failed"
else
  jq -r --arg subject "$SUBJECT_DIGEST" \
    '.versions[] | select(.digest != $subject) | .digest' \
    "$INVENTORY_FILE" |
    tr -d '\r' | sort -u >"$INVENTORY_DIGESTS" ||
    fail "package inventory digest projection failed"
fi
[ -s "$INVENTORY_DIGESTS" ] || fail "package inventory has no child or referrer versions"
while IFS= read -r digest; do validate_digest "$digest"; done <"$INVENTORY_DIGESTS"
while IFS= read -r digest; do
  jq -e --arg digest "$digest" 'any(.versions[]; .digest == $digest)' \
    "$INVENTORY_FILE" >/dev/null ||
    fail "candidate package version is absent from package inventory"
done <"$INVENTORY_DIGESTS"
while IFS= read -r digest; do
  grep -Fqx "$digest" "$INVENTORY_DIGESTS" ||
    fail "top-level subject-bound referrer is absent from package inventory"
done <"$REFERRERS"

fetch_raw() {
  local digest=$1 destination=$2 expected_size=${3:-} expected_media=${4:-}
  if [ -n "$FIXTURE_DIR" ]; then
    local fixture="$FIXTURE_DIR/${digest#sha256:}.json"
    [ -f "$fixture" ] || fail "OCI child manifest is missing"
    cp -- "$fixture" "$destination" ||
      fail "OCI child manifest could not be copied"
  else
    docker buildx imagetools inspect --raw "$IMAGE@$digest" >"$destination" ||
      fail "OCI child manifest lookup failed"
  fi
  jq -e 'type == "object"' "$destination" >/dev/null ||
    fail "OCI child response is not a JSON object"
  [ "sha256:$(sha256sum -- "$destination" | awk '{print $1}')" = "$digest" ] ||
    fail "OCI child bytes do not match its descriptor digest"
  actual_size=$(wc -c <"$destination" | tr -d '[:space:]')
  [ -z "$expected_size" ] || [ "$actual_size" -eq "$expected_size" ] ||
    fail "OCI child bytes do not match its descriptor size"
  actual_media=$(jq -r '.mediaType // empty' "$destination")
  [ -z "$expected_media" ] || [ "$actual_media" = "$expected_media" ] ||
    fail "OCI child media type does not match its descriptor"
}

REACHABLE=$WORK_DIR/reachable
VISITED=$WORK_DIR/visited
: >"$REACHABLE"
: >"$VISITED"

mark_reachable() {
  local digest=$1
  grep -Fqx "$digest" "$REACHABLE" || printf '%s\n' "$digest" >>"$REACHABLE"
}

collect_reachable() {
  local digest=$1 depth=$2 expected_size=${3:-} expected_media=${4:-}
  local file media descriptor child child_media child_size
  [ "$depth" -le 8 ] || fail "OCI referrer graph exceeds the verification bound"
  validate_digest "$digest"
  mark_reachable "$digest"
  if grep -Fqx "$digest" "$VISITED"; then
    return
  fi
  printf '%s\n' "$digest" >>"$VISITED"
  file=$WORK_DIR/node-${digest#sha256:}.json
  fetch_raw "$digest" "$file" "$expected_size" "$expected_media"
  media=$(jq -r '.mediaType // empty' "$file")
  case "$media" in
    application/vnd.oci.image.index.v1+json)
      jq -e '
        .schemaVersion == 2 and
        (.manifests | type == "array" and length > 0)
      ' "$file" >/dev/null || fail "reachable OCI referrer index is invalid"
      while IFS= read -r descriptor; do
        validate_descriptor "$descriptor"
        child=$(jq -r '.digest' <<<"$descriptor")
        child_media=$(jq -r '.mediaType' <<<"$descriptor")
        child_size=$(jq -r '.size' <<<"$descriptor")
        case "$child_media" in
          application/vnd.oci.image.manifest.v1+json|\
          application/vnd.oci.image.index.v1+json) ;;
          *) fail "reachable OCI child media type is foreign" ;;
        esac
        collect_reachable "$child" "$((depth + 1))" "$child_size" "$child_media"
      done < <(jq -c '.manifests[]' "$file")
      ;;
    application/vnd.oci.image.manifest.v1+json)
      jq -e '.schemaVersion == 2' "$file" >/dev/null ||
        fail "reachable OCI manifest schema is invalid"
      ;;
    *) fail "reachable OCI node has an unsupported media type" ;;
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

if [ "$PROMOTION" = true ]; then
  jq -e --arg alias "$CANDIDATE_ALIAS" --arg subject "$SUBJECT_DIGEST" '
    ([.versions[] | select(.digest == $subject)] | length) == 1 and
    ([.versions[] | select(.digest == $subject)][0].tags == [$alias])
  ' "$INVENTORY_FILE" >/dev/null ||
    fail "promotion candidate alias is not bound exactly to the subject"
fi

mark_reachable "$SUBJECT_DIGEST"
mark_reachable "$PLATFORM_SUBJECT"
platform_descriptor=$(jq -c --arg digest "$PLATFORM_SUBJECT" \
  '.manifests[] | select(.digest == $digest)' "$INDEX_FILE")
collect_reachable "$PLATFORM_SUBJECT" 0 \
  "$(jq -r '.size' <<<"$platform_descriptor")" \
  "$(jq -r '.mediaType' <<<"$platform_descriptor")"
while IFS= read -r digest; do
  mark_reachable "$digest"
  referrer_descriptor=$(jq -c --arg digest "$digest" \
    '.manifests[] | select(.digest == $digest)' "$INDEX_FILE")
  collect_reachable "$digest" 0 \
    "$(jq -r '.size' <<<"$referrer_descriptor")" \
    "$(jq -r '.mediaType' <<<"$referrer_descriptor")"
done <"$REFERRERS"
if [ -n "$MARKER_ROOT" ] &&
   ! grep -Fqx "$MARKER_ROOT" "$REACHABLE"; then
  collect_reachable "$MARKER_ROOT" 0
  marker_file=$WORK_DIR/node-${MARKER_ROOT#sha256:}.json
  jq -e '.mediaType == "application/vnd.oci.image.index.v1+json"' \
    "$marker_file" >/dev/null ||
    fail "subject marker does not identify a referrer index"
fi

while IFS= read -r digest; do
  grep -Fqx "$digest" "$REACHABLE" ||
    fail "package inventory version is absent from the referrer graph"
done <"$INVENTORY_DIGESTS"

if [ "$PROMOTION" = true ]; then
  reachable_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$REACHABLE")
  baseline_non_candidate=$(jq -cS --argjson reachable "$reachable_json" '
    [.[][] | {id,digest:.name,tags:.metadata.container.tags} as $row |
      select(($reachable | index($row.digest)) == null)] | sort_by(.id,.digest)
  ' "$PROMOTION_BASELINE")
  current_non_candidate=$(jq -cS --argjson reachable "$reachable_json" '
    [.versions[] as $row | select(($reachable | index($row.digest)) == null)] |
    sort_by(.id,.digest)
  ' "$INVENTORY_FILE")
  [ "$baseline_non_candidate" = "$current_non_candidate" ] ||
    fail "noncandidate package inventory changed during promotion"
  protected_digests=$(jq -c '
    [
      (.protected.rootDigests[]?),
      (.protected.platformDigests[]?),
      (.protected.subjectDigests[]?),
      (.protected.versions[]?.digest?),
      (.protected.subjects[]?.digest?),
      (.protected.manifests[]?.digest?),
      (.registry.versions[]?.digest?),
      (.registry.subjects[]?.digest?),
      (.registry.manifests[]?.digest?)
    ] | map(select(type == "string")) | unique
  ' "$PROMOTION_PROTECTED") || fail "promotion protected state is malformed"
  jq -e --argjson reachable "$reachable_json" --argjson protected "$protected_digests" '
    any($reachable[]; . as $digest | any($protected[]; . == $digest))
  ' <<<null >/dev/null &&
    fail "promotion candidate intersects protected state"
  jq -e --arg subject "$SUBJECT_DIGEST" --arg marker "$MARKER" \
    --arg alias "$CANDIDATE_ALIAS" --argjson reachable "$reachable_json" '
    all(.versions[] as $row | select(($reachable | index($row.digest)) != null);
      if $row.digest == $subject then $row.tags == [$alias]
      else all($row.tags[]; . == $marker)
      end)
  ' "$INVENTORY_FILE" >/dev/null ||
    fail "promotion candidate has an unexpected alias or marker"
fi

NODE_PROVENANCE=0
NODE_SBOM=0
NODE_SIGNATURE=0
validate_image_manifest() {
  local file=$1
  jq -e '
    .schemaVersion == 2 and
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    (.config | type == "object") and
    (.layers | type == "array" and length > 0)
  ' "$file" >/dev/null || fail "subject OCI manifest shape is invalid"
  descriptor=$(jq -c '.config' "$file")
  validate_descriptor "$descriptor"
  jq -e '
    (.config.mediaType == "application/vnd.oci.image.config.v1+json" or
     .config.mediaType == "application/vnd.oci.empty.v1+json") and
    all(.layers[];
      (.mediaType == "application/vnd.oci.image.layer.v1.tar+gzip" or
       .mediaType == "application/vnd.oci.image.layer.v1.tar+zstd" or
       .mediaType == "application/vnd.oci.image.rootfs.diff.tar.gzip"))
  ' "$file" >/dev/null || fail "subject OCI manifest descriptor media type is invalid"
  while IFS= read -r descriptor; do validate_descriptor "$descriptor"; done < <(
    jq -c '.layers[]' "$file"
  )
}

validate_node() {
  local digest=$1 inherited_subject=$2 depth=$3 allow_inherited=$4
  local expected_size=${5:-} expected_media=${6:-}
  local file media descriptor child child_media child_size declared_subject
  [ "$depth" -le 8 ] || fail "OCI referrer graph exceeds the verification bound"
  file=$WORK_DIR/node-${digest#sha256:}.json
  fetch_raw "$digest" "$file" "$expected_size" "$expected_media"
  media=$(jq -r '.mediaType // empty' "$file")
  case "$media" in
    application/vnd.oci.image.index.v1+json)
      jq -e '
        .schemaVersion == 2 and
        (.manifests | type == "array" and length > 0)
      ' "$file" >/dev/null || fail "nested OCI referrer index is invalid"
      if jq -e '.subject != null' "$file" >/dev/null; then
        declared_subject=$(jq -r '.subject.digest // empty' "$file")
        validate_digest "$declared_subject"
        [ "$declared_subject" = "$SUBJECT_DIGEST" ] ||
          [ "$declared_subject" = "$PLATFORM_SUBJECT" ] ||
          fail "nested OCI index subject is not the release image"
        NODE_BOUND=1
      fi
      while IFS= read -r descriptor; do
        validate_descriptor "$descriptor"
        child=$(jq -r '.digest' <<<"$descriptor")
        child_media=$(jq -r '.mediaType' <<<"$descriptor")
        child_size=$(jq -r '.size' <<<"$descriptor")
        case "$child_media" in
          application/vnd.oci.image.manifest.v1+json|\
          application/vnd.oci.image.index.v1+json) ;;
          *) fail "nested OCI child media type is foreign" ;;
        esac
        validate_node "$child" "$inherited_subject" "$((depth + 1))" \
          "$allow_inherited" "$child_size" "$child_media"
      done < <(jq -c '.manifests[]' "$file")
      ;;
    application/vnd.oci.image.manifest.v1+json)
      if jq -e '.subject != null' "$file" >/dev/null; then
        declared_subject=$(jq -r '.subject.digest // empty' "$file")
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
      descriptor=$(jq -c '.config' "$file")
      validate_descriptor "$descriptor"
      jq -e '
        (.config.mediaType == "application/vnd.oci.image.config.v1+json" or
         .config.mediaType == "application/vnd.oci.empty.v1+json")
      ' "$file" >/dev/null || fail "OCI referrer config media type is invalid"
      while IFS= read -r descriptor; do
        validate_descriptor "$descriptor"
        child_media=$(jq -r '.mediaType' <<<"$descriptor")
        case "$child_media" in
          application/vnd.in-toto+json|\
          application/vnd.oci.image.layer.v1.tar+gzip|\
          application/vnd.dev.sigstore.bundle.v0.3+json) ;;
          *) fail "OCI referrer layer media type is foreign" ;;
        esac
        predicate=$(jq -r \
          '.annotations["in-toto.io/predicate-type"] // empty' \
          <<<"$descriptor")
        case "$predicate" in
          *slsa.dev/provenance*|*in-toto.io/Statement*) NODE_PROVENANCE=1 ;;
          *spdx.dev/Document*|*cyclonedx.org/bom*) NODE_SBOM=1 ;;
          "") [ "$child_media" = "application/vnd.dev.sigstore.bundle.v0.3+json" ] ||
              fail "OCI referrer predicate is missing" ;;
          *) fail "OCI referrer predicate is not provenance or SBOM" ;;
        esac
        if [ "$child_media" = "application/vnd.dev.sigstore.bundle.v0.3+json" ]; then
          [ "$(jq -r '.artifactType // empty' "$file")" = \
            "application/vnd.dev.sigstore.bundle.v0.3+json" ] ||
            fail "OCI signature node artifact type is missing"
          [ -n "$declared_subject" ] || fail "OCI signature node has no subject"
          NODE_SIGNATURE=1
          SIGNATURE_FOUND=1
        fi
      done < <(jq -c '.layers[]' "$file")
      ;;
    *) fail "OCI referrer node has an unsupported media type" ;;
  esac
}

NODE_BOUND=0
NODE_PROVENANCE=0
NODE_SBOM=0
NODE_SIGNATURE=0
SIGNATURE_FOUND=0

while IFS= read -r digest; do
  NODE_PROVENANCE=0
  NODE_SBOM=0
  NODE_SIGNATURE=0
  NODE_BOUND=0
  subject=
  kind=
  if [ "$digest" = "$PLATFORM_SUBJECT" ]; then
    platform_file=$WORK_DIR/platform-${digest#sha256:}.json
    platform_size=$(jq -er --arg digest "$digest" \
      '.manifests[] | select(.digest == $digest) | .size' "$INDEX_FILE")
    platform_media=$(jq -er --arg digest "$digest" \
      '.manifests[] | select(.digest == $digest) | .mediaType' "$INDEX_FILE")
    fetch_raw "$digest" "$platform_file" "$platform_size" "$platform_media"
    validate_image_manifest "$platform_file"
    NODE_BOUND=1
    kind=subject
    subject=$SUBJECT_DIGEST
  elif grep -Fqx "$digest" "$REFERRERS"; then
    referrer_size=$(jq -er --arg digest "$digest" \
      '.manifests[] | select(.digest == $digest) | .size' "$INDEX_FILE")
    referrer_media=$(jq -er --arg digest "$digest" \
      '.manifests[] | select(.digest == $digest) | .mediaType' "$INDEX_FILE")
    subject=$(jq -r --arg digest "$digest" '
      .manifests[] | select(.digest == $digest) |
      .annotations["vnd.docker.reference.digest"]
    ' "$INDEX_FILE")
    validate_node "$digest" "$subject" 0 1 "$referrer_size" "$referrer_media"
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
  jq -cn \
    --arg digest "$digest" \
    --arg subject "$subject" \
    --arg platform "$PLATFORM_SUBJECT" \
    --arg kind "$kind" \
    '{digest:$digest,attribution:{
      verified:true,subject:$subject,platformSubject:$platform,kind:$kind
    }}' >>"$ATTRIBUTIONS"
done <"$INVENTORY_DIGESTS"

if [ "$REQUIRE_SIGNATURE" = true ] && [ "$SIGNATURE_FOUND" -ne 1 ]; then
  fail "required subject-bound OCI signature node is missing"
fi

jq \
  --slurpfile attrs "$ATTRIBUTIONS" \
  --arg subject "$SUBJECT_DIGEST" \
  --argjson reachable "$(jq -Rsc 'split("\n") | map(select(length > 0))' "$REACHABLE")" \
  --argjson promotion "$PROMOTION" '
    .versions |= map(
      . as $version |
      if $promotion and (($reachable | index($version.digest)) == null) then empty
      elif $version.digest == $subject then .
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
  mv "$WORK_DIR/inventory-attributed.json" "$OUTPUT"
else
  cat "$WORK_DIR/inventory-attributed.json"
fi
