#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <version> <source-sha> [--tag tag] [--image image] [--image-ref image-ref] [--manifest path]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
VERSION=$1
SOURCE_SHA=$2
shift 2
TAG=
IMAGE=
IMAGE_REF=
MANIFEST=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --image) [ "$#" -ge 2 ] || usage; IMAGE=$2; shift 2 ;;
    --image-ref) [ "$#" -ge 2 ] || usage; IMAGE_REF=$2; shift 2 ;;
    --manifest) [ "$#" -ge 2 ] || usage; MANIFEST=$2; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
test "$(jq -r '.version' version.json)" = "$VERSION"
./gradlew properties -q | grep -Fx "version: $VERSION"
build_info=$(find build -type f -path '*/META-INF/build-info.properties' -print -quit 2>/dev/null || true)
if [ -z "$build_info" ]; then
  ./gradlew --no-daemon bootBuildInfo >/dev/null
  build_info=$(find build -type f -path '*/META-INF/build-info.properties' -print -quit)
fi
test -n "$build_info"
grep -Fx "build.version=$VERSION" "$build_info"

if [ -n "$TAG" ]; then
  test "$TAG" = "v$VERSION"
  if git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
    test "$(git rev-list -n 1 "$TAG")" = "$SOURCE_SHA"
  fi
  test "$(git show "$SOURCE_SHA:version.json" | jq -r '.version')" = "$VERSION"
fi

if [ -n "$IMAGE" ]; then
  IMAGE_REF=${IMAGE_REF:-$IMAGE}
  image_version=$(docker image inspect "$IMAGE_REF" \
    --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
  image_revision=$(docker image inspect "$IMAGE_REF" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
  image_source=$(docker image inspect "$IMAGE_REF" \
    --format '{{index .Config.Labels "org.opencontainers.image.source"}}')
  image_platform=$(docker image inspect "$IMAGE_REF" --format '{{.Os}}/{{.Architecture}}')
  image_user=$(docker image inspect "$IMAGE_REF" --format '{{.Config.User}}')
  test "$image_version" = "$VERSION"
  test "$image_revision" = "$SOURCE_SHA"
  test "$image_source" = "https://github.com/NickolayMamonov/meet-backend-v3"
  test "$image_platform" = linux/amd64
  test "$image_user" = 10001:10001
fi

if [ -n "$MANIFEST" ]; then
  test -s "$MANIFEST"
  jq -e \
    --arg version "$VERSION" \
    --arg tag "v$VERSION" \
    --arg source "$SOURCE_SHA" \
    --arg image "$IMAGE" '
      .version == $version and
      .tag == $tag and
      .sourceSha == $source and
      .image == $image and
      .platform == "linux/amd64" and
      .publicationPolicy == "exactly-three-aliases-publish-last" and
      .provenance == true and
      .sbom == true and
      .artifactAttestation == true and
      .evidence == ["image-index.json", "image-inspect.txt"] and
      .aliases == [$tag, $version, ("sha-" + $source)] and
      (.digest | test("^sha256:[0-9a-f]{64}$"))
    ' "$MANIFEST"
fi

echo "release consistency verified: version=$VERSION source=$SOURCE_SHA"
