#!/bin/sh
set -eu

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)

usage() {
  echo "usage: $0 <release-id> --repository owner/repo --version x.y.z --tag vX.Y.Z --source-sha sha --target sha --image registry/image [--observed-state canonical|generated_placeholder --observed-tag tag] [--fixture directory]" >&2
  exit 2
}

fail() {
  echo "release resume verification failed: $*" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage
RELEASE_ID=$1
shift
REPOSITORY=
VERSION=
TAG=
SOURCE_SHA=
TARGET=
IMAGE=
FIXTURE=
OBSERVED_STATE=canonical
OBSERVED_TAG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || usage; TARGET=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] || usage; IMAGE=$2; shift 2 ;;
    --observed-state) [ "$#" -ge 2 ] || usage; OBSERVED_STATE=$2; shift 2 ;;
    --observed-tag) [ "$#" -ge 2 ] || usage; OBSERVED_TAG=$2; shift 2 ;;
    --fixture) [ "$#" -ge 2 ] || usage; FIXTURE=$2; shift 2 ;;
    *) usage ;;
  esac
done

case "$RELEASE_ID" in ''|*[!0-9]*) usage ;; esac
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 2; }
jq -ne --arg version "$VERSION" \
  '$version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")' \
  >/dev/null || usage
case "$SOURCE_SHA" in ''|*[!0-9a-f]*) usage ;; esac
[ "${#SOURCE_SHA}" -eq 40 ] || usage
case "$TARGET" in ''|*[!0-9a-f]*) usage ;; esac
[ "${#TARGET}" -eq 40 ] || usage
[ -n "$REPOSITORY" ] && [ -n "$TAG" ] && [ -n "$IMAGE" ] || usage
[ "$TAG" = "v$VERSION" ] || usage
[ "$OBSERVED_STATE" = canonical ] ||
  [ "$OBSERVED_STATE" = generated_placeholder ] || usage
if [ "$OBSERVED_STATE" = generated_placeholder ]; then
  printf '%s\n' "$OBSERVED_TAG" |
    grep -Eq '^untagged-[0-9a-f]{20}$' || usage
fi

WORK_DIR=$(mktemp -d)
trap 'rm -r "$WORK_DIR"' EXIT HUP INT TERM
ASSET_DIR=$WORK_DIR/assets
mkdir "$ASSET_DIR"

if [ -n "$FIXTURE" ]; then
  [ -f "$FIXTURE/release.json" ] || fail "fixture release descriptor is missing"
  [ -f "$FIXTURE/tag.json" ] || fail "fixture tag evidence is missing"
  [ -f "$FIXTURE/registry.json" ] || fail "fixture registry evidence is missing"
  [ -f "$FIXTURE/attestation.json" ] || fail "fixture attestation evidence is missing"
  RELEASE_JSON=$FIXTURE/release.json
else
  command -v gh >/dev/null 2>&1 || { echo "gh is required in live mode" >&2; exit 2; }
  command -v docker >/dev/null 2>&1 || { echo "docker is required in live mode" >&2; exit 2; }
  RELEASE_JSON=$WORK_DIR/release.json
  gh api "repos/$REPOSITORY/releases/$RELEASE_ID" > "$RELEASE_JSON" ||
    fail "release API lookup failed"
fi

jq -e \
  --argjson id "$RELEASE_ID" \
  --arg tag "$TAG" \
  --arg observed_state "$OBSERVED_STATE" \
  --arg observed_tag "$OBSERVED_TAG" \
  --arg target "$TARGET" '
    type == "object" and
    .id == $id and
    (
      .tag_name == $tag or
      (
        $observed_state == "generated_placeholder" and
        .tag_name == $observed_tag
      )
    ) and
    .target_commitish == $target and
    .draft == true and
    .published_at == null and
    (.assets | type == "array")
  ' "$RELEASE_JSON" >/dev/null || fail "release identity is not the expected unpublished draft"

if [ -n "$FIXTURE" ]; then
  if [ "$OBSERVED_STATE" = generated_placeholder ]; then
    jq -e '.exists == false' "$FIXTURE/tag.json" >/dev/null ||
      fail "generated placeholder has a materialized canonical tag ref"
  else
    jq -e --arg source "$SOURCE_SHA" '
      type == "object" and
      (
        .exists == false or
        (.exists == true and .targetSha == $source)
      )
    ' "$FIXTURE/tag.json" >/dev/null ||
      fail "existing fixture tag does not resolve to the release source"
  fi
else
  ENCODED_TAG=$(jq -nr --arg tag "$TAG" '$tag | @uri')
  TAG_OBJECT=$WORK_DIR/tag-object.json
  TAG_ERROR=$WORK_DIR/tag-error
  if gh api "repos/$REPOSITORY/git/ref/tags/$ENCODED_TAG" \
    > "$TAG_OBJECT" 2> "$TAG_ERROR"; then
    OBJECT_TYPE=$(jq -r '.object.type // empty' "$TAG_OBJECT")
    OBJECT_SHA=$(jq -r '.object.sha // empty' "$TAG_OBJECT")
    TAG_DEPTH=0
    SEEN_TAGS=$WORK_DIR/seen-tags
    : > "$SEEN_TAGS"
    while [ "$OBJECT_TYPE" = tag ]; do
      TAG_DEPTH=$((TAG_DEPTH + 1))
      [ "$TAG_DEPTH" -le 8 ] || fail "annotated tag chain exceeds the verification bound"
      case "$OBJECT_SHA" in
        ''|*[!0-9a-f]*) fail "annotated tag object SHA is invalid" ;;
      esac
      [ "${#OBJECT_SHA}" -eq 40 ] || fail "annotated tag object SHA is invalid"
      if grep -Fqx "$OBJECT_SHA" "$SEEN_TAGS"; then
        fail "annotated tag chain contains a cycle"
      fi
      printf '%s\n' "$OBJECT_SHA" >> "$SEEN_TAGS"
      gh api "repos/$REPOSITORY/git/tags/$OBJECT_SHA" > "$TAG_OBJECT" ||
        fail "annotated tag object lookup failed"
      OBJECT_TYPE=$(jq -r '.object.type // empty' "$TAG_OBJECT")
      OBJECT_SHA=$(jq -r '.object.sha // empty' "$TAG_OBJECT")
    done
    [ "$OBJECT_TYPE" = commit ] && [ "$OBJECT_SHA" = "$SOURCE_SHA" ] ||
      fail "existing release tag does not resolve to the release source"
  elif ! grep -Eq '\(HTTP 404\)|[[:space:]]404([[:space:]]|$)' "$TAG_ERROR"; then
    fail "release tag lookup failed"
  fi
fi

EXPECTED_ASSETS='["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"]'
jq -e --argjson expected "$EXPECTED_ASSETS" '
  (.assets | length) == 4 and
  ([.assets[].name] | sort) == $expected and
  ([.assets[].name] | unique | length) == 4 and
  ([.assets[].id] | unique | length) == 4 and
  all(.assets[]; (.id | type == "number") and (.id > 0) and (.id | floor == .))
' "$RELEASE_JSON" >/dev/null || fail "asset inventory is not the exact four-file evidence set"

download_asset() {
  asset_id=$1
  asset_name=$2
  destination=$ASSET_DIR/$asset_name
  if [ -n "$FIXTURE" ]; then
    [ -f "$FIXTURE/assets/$asset_id" ] || fail "asset payload $asset_id is missing"
    cp "$FIXTURE/assets/$asset_id" "$destination"
  else
    gh api -H "Accept: application/octet-stream" \
      "repos/$REPOSITORY/releases/assets/$asset_id" > "$destination" ||
      fail "asset download $asset_id failed"
  fi
  [ -s "$destination" ] || fail "asset $asset_name is empty"
}

for asset_name in release-manifest.json image-index.json image-inspect.txt SHA256SUMS; do
  asset_id=$(jq -r --arg name "$asset_name" \
    '.assets[] | select(.name == $name) | .id' "$RELEASE_JSON" |
    tr -d '\r')
  download_asset "$asset_id" "$asset_name"
done

CHECKSUMS=$ASSET_DIR/SHA256SUMS
if [ -n "$FIXTURE" ]; then
  for asset_name in release-manifest.json image-index.json image-inspect.txt; do
    tr -d '\r' <"$ASSET_DIR/$asset_name" >"$ASSET_DIR/$asset_name.lf"
    mv "$ASSET_DIR/$asset_name.lf" "$ASSET_DIR/$asset_name"
  done
fi
tr -d '\r' <"$CHECKSUMS" >"$CHECKSUMS.lf"
mv "$CHECKSUMS.lf" "$CHECKSUMS"
[ "$(wc -l < "$CHECKSUMS" | tr -d ' ')" -eq 3 ] ||
  fail "checksum inventory must contain exactly three entries"
jq -Rse '
  split("\n")[:-1] as $lines |
  ($lines | length) == 3 and
  ([$lines[] | capture("^(?<sum>[0-9a-f]{64})  (?<name>[^/\\\\]+)$").name] | sort) ==
    ["image-index.json","image-inspect.txt","release-manifest.json"] and
  ([$lines[] | capture("^(?<sum>[0-9a-f]{64})  (?<name>[^/\\\\]+)$").name] | unique | length) == 3 and
  all($lines[]; (contains("..") | not))
' "$CHECKSUMS" >/dev/null || fail "checksum inventory is malformed, duplicated, extra, or unsafe"
(cd "$ASSET_DIR" && sha256sum -c SHA256SUMS >/dev/null) ||
  fail "asset checksum verification failed"

MANIFEST=$ASSET_DIR/release-manifest.json
jq -e \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --arg source "$SOURCE_SHA" \
  --argjson release_id "$RELEASE_ID" \
  --arg target "$TARGET" \
  --arg image "$IMAGE" '
    type == "object" and
    .releaseId == $release_id and
    .targetCommitish == $target and
    .version == $version and
    .tag == $tag and
    .sourceSha == $source and
    .image == $image and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    .aliases == [$tag, $version, ("sha-" + $source)] and
    .platform == "linux/amd64" and
    .publicationPolicy == "exactly-three-aliases-publish-last" and
    .provenance == true and
    .sbom == true and
    .artifactAttestation == true and
    .evidence == ["image-index.json", "image-inspect.txt"]
  ' "$MANIFEST" >/dev/null || fail "release manifest identity or evidence policy is invalid"
DIGEST=$(jq -r '.digest' "$MANIFEST" | tr -d '\r')

INDEX=$ASSET_DIR/image-index.json
jq -e --arg digest "$DIGEST" '
  . as $index |
  (
    [
      $index.manifests[]?
      | select(
          .mediaType == "application/vnd.oci.image.manifest.v1+json" and
          .platform.os == "linux" and
          .platform.architecture == "amd64"
        )
      | .digest
    ] | if length == 1 then .[0] else "" end
  ) as $platform_subject |
  $index.mediaType == "application/vnd.oci.image.index.v1+json" and
  ($index.manifests | type == "array") and
  ($platform_subject | length) > 0 and
  ([$index.manifests[] | select(
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .platform.os == "linux" and .platform.architecture == "amd64"
  )] | length) == 1 and
  ([$index.manifests[] | select(
    .mediaType == "application/vnd.oci.image.manifest.v1+json" and
    .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
    (
      .annotations["vnd.docker.reference.digest"] == $digest or
      .annotations["vnd.docker.reference.digest"] == $platform_subject
    )
  )] | length) >= 1
' "$INDEX" >/dev/null || fail "OCI descriptor evidence is invalid"

grep -Eq "^Digest:[[:space:]]+$DIGEST$" "$ASSET_DIR/image-inspect.txt" ||
  fail "image inspection digest is inconsistent"

inspect_field() {
  field=$1
  expected=$2
  awk -v field="$field" -v expected="$expected" '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      prefix = field ":"
      if (index(line, prefix) == 1) {
        sub("^[^:]+:[[:space:]]*", "", line)
        if (line == expected) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$ASSET_DIR/image-inspect.txt"
}

inspect_field Platform linux/amd64 ||
  fail "image inspection platform is inconsistent"
if ! inspect_field Version "$VERSION"; then
  inspect_field org.opencontainers.image.version "$VERSION" ||
    fail "image inspection version is inconsistent"
fi
if ! inspect_field Revision "$SOURCE_SHA"; then
  inspect_field org.opencontainers.image.revision "$SOURCE_SHA" ||
    fail "image inspection revision is inconsistent"
fi
if ! inspect_field Source "https://github.com/$REPOSITORY"; then
  inspect_field org.opencontainers.image.source "https://github.com/$REPOSITORY" ||
    fail "image inspection source is inconsistent"
fi

if [ -n "$FIXTURE" ]; then
  REGISTRY_JSON=$FIXTURE/registry.json
  "$SCRIPT_DIR/verify-ghcr-package-inventory.sh" \
    --inventory-file "$REGISTRY_JSON" \
    --digest "$DIGEST" \
    --tag "$TAG" \
    --version "$VERSION" \
    --source-sha "$SOURCE_SHA" >/dev/null ||
    fail "GHCR package inventory is not cryptographically closed"
  jq -e \
    --arg tag "$TAG" \
    --arg version "$VERSION" \
    --arg source "$SOURCE_SHA" \
    --arg image "$IMAGE" \
    --arg digest "$DIGEST" \
    --arg repository "$REPOSITORY" '
      type == "object" and
      (.aliases | type == "object") and
      (.aliases | keys | sort) == ([$tag, $version, ("sha-" + $source)] | sort) and
      all(.aliases[]; . == $digest) and
      .latest == null and
      .digest == $digest and
      .image == $image and
      .identity.version == $version and
      .identity.revision == $source and
      .identity.source == ("https://github.com/" + $repository) and
      .identity.platform == "linux/amd64" and
      .identity.user == "10001:10001" and
      .identity.filesystem == true and
      .identity.readiness == true and
      .ociEvidence.subjectDigest == $digest and
      .ociEvidence.provenance == true and
      .ociEvidence.sbom == true
    ' "$REGISTRY_JSON" >/dev/null || fail "registry aliases, identity, or OCI evidence are incomplete"
  jq -e \
    --arg repository "$REPOSITORY" \
    --arg image "$IMAGE" \
    --arg digest "$DIGEST" '
      type == "object" and
      .verified == true and
      .repository == $repository and
      .subjectName == $image and
      .subjectDigest == $digest
    ' "$FIXTURE/attestation.json" >/dev/null ||
    fail "GitHub attestation evidence is invalid"
else
  REGISTRY_DIGESTS=$WORK_DIR/registry-digests
  : > "$REGISTRY_DIGESTS"
  for alias in "$TAG" "$VERSION" "sha-$SOURCE_SHA"; do
    inspection=$(docker buildx imagetools inspect "$IMAGE:$alias" 2>&1) ||
      fail "required registry alias $alias is absent"
    alias_digest=$(printf '%s\n' "$inspection" |
      awk '$1 == "Digest:" { print $2; exit }')
    [ "$alias_digest" = "$DIGEST" ] || fail "registry alias $alias is divergent"
    printf '%s\n' "$alias_digest" >> "$REGISTRY_DIGESTS"
  done
  [ "$(sort -u "$REGISTRY_DIGESTS" | wc -l | tr -d ' ')" -eq 1 ] ||
    fail "registry aliases do not resolve to one digest"
  latest_output=
  if latest_output=$(docker buildx imagetools inspect "$IMAGE:latest" 2>&1); then
    fail "latest registry alias is forbidden"
  elif ! printf '%s\n' "$latest_output" |
    grep -Eqi 'manifest unknown|name unknown|repository does not exist|not found'; then
    fail "latest registry alias inspection failed"
  fi
  registry_path=${IMAGE#ghcr.io/}
  registry_owner=${registry_path%%/*}
  registry_package=${registry_path#*/}
  [ "$registry_owner" != "$registry_path" ] && [ -n "$registry_package" ] ||
    fail "only GHCR image references can be inventory-verified"
  encoded_package=$(jq -nr --arg package "$registry_package" '$package | @uri')
  PACKAGE_VERSIONS=$WORK_DIR/package-versions.json
  if ! gh api --paginate --slurp \
    "/users/$registry_owner/packages/container/$encoded_package/versions?per_page=100" \
    > "$PACKAGE_VERSIONS" 2>/dev/null; then
    gh api --paginate --slurp \
      "/orgs/$registry_owner/packages/container/$encoded_package/versions?per_page=100" \
      > "$PACKAGE_VERSIONS" ||
      fail "GHCR package inventory lookup failed"
  fi
  LIVE_INDEX=$WORK_DIR/live-index.json
  docker buildx imagetools inspect --raw "$IMAGE@$DIGEST" > "$LIVE_INDEX" ||
    fail "registry OCI index inspection failed"
  [ "$(jq -S -c . "$LIVE_INDEX")" = "$(jq -S -c . "$INDEX")" ] ||
    fail "attached OCI index is not the live registry index"
  PACKAGE_INVENTORY=$WORK_DIR/package-inventory.json
  "$SCRIPT_DIR/normalize-ghcr-package-inventory.sh" \
    --package-versions-file "$PACKAGE_VERSIONS" \
    --digest "$DIGEST" \
    --output "$PACKAGE_INVENTORY" ||
    fail "GHCR package inventory normalization failed"
  PLATFORM_SUBJECT=$(jq -r '
    [
      .manifests[]?
      | select(
          .mediaType == "application/vnd.oci.image.manifest.v1+json" and
          .platform.os == "linux" and
          .platform.architecture == "amd64"
        )
      | .digest
    ] | if length == 1 then .[0] else empty end
  ' "$LIVE_INDEX")
  [ -n "$PLATFORM_SUBJECT" ] ||
    fail "live OCI index does not contain exactly one linux/amd64 subject manifest"
  "$SCRIPT_DIR/verify-oci-referrer-closure.sh" \
    --image "$IMAGE" \
    --index-file "$LIVE_INDEX" \
    --inventory-file "$PACKAGE_INVENTORY" \
    --subject-digest "$DIGEST" \
    --platform-subject "$PLATFORM_SUBJECT" \
    --output "$PACKAGE_INVENTORY.attributed" ||
    fail "subject-bound OCI referrer closure verification failed"
  mv "$PACKAGE_INVENTORY.attributed" "$PACKAGE_INVENTORY"
  "$SCRIPT_DIR/verify-ghcr-package-inventory.sh" \
    --inventory-file "$PACKAGE_INVENTORY" \
    --digest "$DIGEST" \
    --tag "$TAG" \
    --version "$VERSION" \
    --source-sha "$SOURCE_SHA" \
    --platform-subject "$PLATFORM_SUBJECT" >/dev/null ||
    fail "GHCR package inventory is not cryptographically closed"
  docker pull "$IMAGE@$DIGEST" >/dev/null ||
    fail "verified image digest could not be pulled"
  LIVE_IMAGE=$WORK_DIR/live-image.json
  docker image inspect "$IMAGE@$DIGEST" > "$LIVE_IMAGE" ||
    fail "live OCI image configuration inspection failed"
  jq -e \
    --arg version "$VERSION" \
    --arg source "$SOURCE_SHA" \
    --arg repository "$REPOSITORY" '
      .[0] as $image |
      ($image.Config.Labels // {}) as $labels |
      $image.Os == "linux" and
      $image.Architecture == "amd64" and
      $image.Config.User == "10001:10001" and
      $labels["org.opencontainers.image.version"] == $version and
      $labels["org.opencontainers.image.revision"] == $source and
      $labels["org.opencontainers.image.source"] ==
        ("https://github.com/" + $repository)
    ' "$LIVE_IMAGE" >/dev/null ||
    fail "live OCI image identity is inconsistent"
  docker run --rm --entrypoint sh "$IMAGE@$DIGEST" -ec \
    'test -f /app/app.jar && test -d /data/uploads && test -w /data/uploads' ||
    fail "live image filesystem or writable readiness check failed"

  PROVENANCE=false
  SBOM=false
  PLATFORM_SUBJECT=$(jq -r '
    [
      .manifests[]?
      | select(
          .mediaType == "application/vnd.oci.image.manifest.v1+json" and
          .platform.os == "linux" and
          .platform.architecture == "amd64"
        )
      | .digest
    ] | if length == 1 then .[0] else empty end
  ' "$LIVE_INDEX")
  [ -n "$PLATFORM_SUBJECT" ] ||
    fail "live OCI index does not contain exactly one linux/amd64 subject manifest"
  ATTESTATION_DIGESTS=$(jq -r --arg subject "$DIGEST" \
    --arg platform_subject "$PLATFORM_SUBJECT" '
    .manifests[]?
    | select(
        .mediaType == "application/vnd.oci.image.manifest.v1+json" and
        .annotations["vnd.docker.reference.type"] == "attestation-manifest" and
        (
          .annotations["vnd.docker.reference.digest"] == $subject or
          .annotations["vnd.docker.reference.digest"] == $platform_subject
        )
      )
    | .digest
  ' "$LIVE_INDEX" | tr -d '\r')
  [ "$(printf '%s\n' "$ATTESTATION_DIGESTS" | sed '/^$/d' | wc -l | tr -d ' ')" -ge 1 ] ||
    fail "subject-bound OCI attestation descriptors are missing"
  for attestation_digest in $ATTESTATION_DIGESTS; do
    case "$attestation_digest" in
      sha256:*) attestation_hash=${attestation_digest#sha256:} ;;
      *) fail "OCI attestation descriptor digest is invalid" ;;
    esac
    case "$attestation_hash" in
      ''|*[!0-9a-f]*) fail "OCI attestation descriptor digest is invalid" ;;
    esac
    [ "${#attestation_hash}" -eq 64 ] ||
      fail "OCI attestation descriptor digest is invalid"
    ATTESTATION_MANIFEST=$WORK_DIR/attestation-$attestation_hash.json
    docker buildx imagetools inspect --raw "$IMAGE@$attestation_digest" \
      > "$ATTESTATION_MANIFEST" ||
      fail "OCI attestation manifest lookup failed"
    jq -e '
      all(.layers[]?;
        .mediaType == "application/vnd.in-toto+json" or
        .mediaType == "application/vnd.oci.image.layer.v1.tar+gzip"
      )
    ' "$ATTESTATION_MANIFEST" >/dev/null ||
      fail "OCI attestation layer media type is invalid"
    if jq -e '
      any(.layers[]?;
        (.annotations["in-toto.io/predicate-type"] // "") |
        test("slsa[.]dev/provenance|in-toto[.]io/Statement")
      )
    ' "$ATTESTATION_MANIFEST" >/dev/null; then
      PROVENANCE=true
    fi
    if jq -e '
      any(.layers[]?;
        (.annotations["in-toto.io/predicate-type"] // "") |
        test("spdx[.]dev/Document|cyclonedx[.]org/bom")
      )
    ' "$ATTESTATION_MANIFEST" >/dev/null; then
      SBOM=true
    fi
  done
  [ "$PROVENANCE" = true ] ||
    fail "live provenance evidence is missing"
  [ "$SBOM" = true ] ||
    fail "live SBOM evidence is missing"
  gh attestation verify "oci://$IMAGE@$DIGEST" --repo "$REPOSITORY" >/dev/null ||
    fail "GitHub attestation verification failed"
fi

echo "resume_admission=verified"
