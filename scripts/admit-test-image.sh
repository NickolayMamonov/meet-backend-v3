#!/usr/bin/env bash
set -euo pipefail

IMAGE='ghcr.io/nickolaymamonov/meet-backend-v3'
SOURCE_REPOSITORY='https://github.com/NickolayMamonov/meet-backend-v3'
INDEX_MEDIA_TYPE='application/vnd.oci.image.index.v1+json'
MANIFEST_MEDIA_TYPE='application/vnd.oci.image.manifest.v1+json'
LABEL_SOURCE='org.opencontainers.image.source'
LABEL_REVISION='org.opencontainers.image.revision'
LABEL_VERSION='org.opencontainers.image.version'

usage() {
  cat >&2 <<'EOF'
usage:
  admit-test-image.sh inspect --source SHA --version X.Y.Z
      (--input PATH | --input-command PATH) [--alias ALIAS] [--output PATH]
  admit-test-image.sh verify --source SHA --version X.Y.Z
      (--input PATH | --input-command PATH) [--alias ALIAS] [--output PATH]

The input is a read-only registry snapshot with a top-level "bindings" array.
An input command is an explicit offline shim. It receives:
  IMAGE ALIAS SOURCE VERSION
and writes the snapshot JSON to stdout. Its stderr is never forwarded.
EOF
  exit 2
}

fail_usage() {
  echo "test image admission: invalid arguments" >&2
  usage
}

command -v jq >/dev/null 2>&1 || {
  echo "test image admission: jq is required" >&2
  exit 2
}

is_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

alias_kind() {
  local value=$1
  if [ "$value" = latest ] ||
    [[ "$value" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    is_semver "$value" ||
    [[ "$value" == sha-* ]]; then
    printf '%s\n' protected
  else
    printf '%s\n' unknown
  fi
}

MODE=
SOURCE=
VERSION=
INPUT=
INPUT_COMMAND=
REQUESTED_ALIAS=
OUTPUT=
OUTPUT_DIR=
TEMP_INPUT=
TEMP_OUTPUT=

[ "$#" -ge 1 ] || fail_usage
MODE=$1
shift
case "$MODE" in
  inspect|verify) ;;
  *) fail_usage ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || fail_usage
      SOURCE=$2
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || fail_usage
      VERSION=$2
      shift 2
      ;;
    --input)
      [ "$#" -ge 2 ] || fail_usage
      INPUT=$2
      shift 2
      ;;
    --input-command)
      [ "$#" -ge 2 ] || fail_usage
      INPUT_COMMAND=$2
      shift 2
      ;;
    --alias)
      [ "$#" -ge 2 ] || fail_usage
      REQUESTED_ALIAS=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || fail_usage
      OUTPUT=$2
      shift 2
      ;;
    --help|-h) usage ;;
    *) fail_usage ;;
  esac
done

[[ "$SOURCE" =~ ^[0-9a-f]{40}$ ]] || fail_usage
is_semver "$VERSION" || fail_usage
[ -n "$INPUT" ] || [ -n "$INPUT_COMMAND" ] || fail_usage
[ -z "$INPUT" ] || [ -z "$INPUT_COMMAND" ] || fail_usage

if [ -n "$OUTPUT" ]; then
  OUTPUT_DIR=$(dirname -- "$OUTPUT")
  [ -d "$OUTPUT_DIR" ] || fail_usage
  [ ! -L "$OUTPUT_DIR" ] || fail_usage
  [ ! -L "$OUTPUT" ] || fail_usage
  [ ! -e "$OUTPUT" ] || [ -f "$OUTPUT" ] || fail_usage
fi

EXPECTED_ALIAS="test-sha-$SOURCE"
ALIAS=${REQUESTED_ALIAS:-$EXPECTED_ALIAS}

cleanup() {
  [ -z "$TEMP_INPUT" ] || rm -f -- "$TEMP_INPUT"
  [ -z "$TEMP_OUTPUT" ] || rm -f -- "$TEMP_OUTPUT"
}
trap cleanup EXIT HUP INT TERM

write_output() {
  local result=$1
  [ -z "$OUTPUT" ] && return
  [ ! -L "$OUTPUT_DIR" ] || {
    echo "test image admission: output directory is a symlink" >&2
    exit 2
  }
  [ ! -L "$OUTPUT" ] || {
    echo "test image admission: output path is a symlink" >&2
    exit 2
  }
  [ ! -e "$OUTPUT" ] || [ -f "$OUTPUT" ] || {
    echo "test image admission: output path is not a regular file" >&2
    exit 2
  }
  TEMP_OUTPUT=$(mktemp "$OUTPUT_DIR/.admit-test-image.XXXXXX") || {
    echo "test image admission: cannot create output temporary file" >&2
    exit 2
  }
  if ! printf '%s\n' "$result" >"$TEMP_OUTPUT"; then
    echo "test image admission: cannot write output" >&2
    exit 2
  fi
  chmod 600 "$TEMP_OUTPUT" || {
    echo "test image admission: cannot protect output" >&2
    exit 2
  }
  [ ! -L "$OUTPUT" ] || {
    echo "test image admission: output path became a symlink" >&2
    exit 2
  }
  mv -f -- "$TEMP_OUTPUT" "$OUTPUT" || {
    echo "test image admission: cannot atomically replace output" >&2
    exit 2
  }
  TEMP_OUTPUT=
}

emit() {
  local state=$1
  local reason=$2
  local result
  result=$(jq -cnS \
    --arg alias "$ALIAS" \
    --arg image "$IMAGE" \
    --arg reason "$reason" \
    --arg source "$SOURCE" \
    --arg state "$state" \
    '{
      alias: $alias,
      image: $image,
      reason: $reason,
      source: $source,
      state: $state
    }')
  write_output "$result"
  printf '%s\n' "$result"
}

if [ "$ALIAS" != "$EXPECTED_ALIAS" ]; then
  case "$(alias_kind "$ALIAS")" in
    protected) emit rejected protected-alias ;;
    unknown) emit rejected unknown-alias ;;
  esac
  exit 1
fi

if [ -n "$INPUT_COMMAND" ]; then
  TEMP_INPUT=$(mktemp)
  if ! bash "$INPUT_COMMAND" "$IMAGE" "$ALIAS" "$SOURCE" "$VERSION" \
      >"$TEMP_INPUT" 2>/dev/null; then
    emit rejected input-command-failed
    exit 1
  fi
  INPUT=$TEMP_INPUT
fi

if [ ! -f "$INPUT" ] || [ ! -r "$INPUT" ] ||
  ! jq -e '
    type == "object" and
    (.bindings | type == "array") and
    all(.bindings[];
      type == "object" and
      (.alias | type == "string")
    )
  ' "$INPUT" >/dev/null 2>&1; then
  emit rejected malformed-input
  exit 1
fi

mapfile -t ALL_ALIASES < <(jq -r '.bindings[].alias' "$INPUT")
for binding_alias in "${ALL_ALIASES[@]}"; do
  binding_alias=${binding_alias%$'\r'}
  [ "$binding_alias" = "$ALIAS" ] && continue
  case "$(alias_kind "$binding_alias")" in
    protected)
      emit rejected protected-alias
      exit 1
      ;;
    unknown)
      emit rejected unknown-alias
      exit 1
      ;;
  esac
done

BINDING_COUNT=$(jq --arg alias "$ALIAS" \
  '[.bindings[] | select(.alias == $alias)] | length' "$INPUT")
if [ "$BINDING_COUNT" -eq 0 ]; then
  [ "${#ALL_ALIASES[@]}" -eq 0 ] || {
    emit rejected unknown-alias
    exit 1
  }
  emit absent no-binding
  [ "$MODE" = inspect ] && exit 0
  exit 1
fi
[ "$BINDING_COUNT" -eq 1 ] || {
  emit rejected duplicate-binding
  exit 1
}

BINDING=$(jq -c --arg alias "$ALIAS" \
  '[.bindings[] | select(.alias == $alias)][0]' "$INPUT")

if ! jq -e \
  --arg index_media_type "$INDEX_MEDIA_TYPE" \
  --arg manifest_media_type "$MANIFEST_MEDIA_TYPE" \
  --arg label_source "$LABEL_SOURCE" \
  --arg label_revision "$LABEL_REVISION" \
  --arg label_version "$LABEL_VERSION" \
  --arg source_repository "$SOURCE_REPOSITORY" \
  --arg source "$SOURCE" \
  --arg version "$VERSION" '
    type == "object" and
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.root | type == "object") and
    (.platform | type == "object") and
    (.referrers | type == "array") and
    (.githubAttestations | type == "array") and
    (.root.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.platform.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.digest == .root.digest) and
    (.root.digest != .platform.digest) and
    (.root.mediaType == $index_media_type) and
    (.platform.mediaType == $manifest_media_type) and
    (.root.manifests | type == "array" and length == 1) and
    (.root.manifests[0].digest == .platform.digest) and
    (.root.manifests[0].mediaType == $manifest_media_type) and
    (.root.manifests[0].platform.os == "linux") and
    (.root.manifests[0].platform.architecture == "amd64") and
    (. as $binding | all([$label_revision,$label_source,$label_version][]; $binding.root.labels[.] | type == "string")) and
    (. as $binding | all([$label_revision,$label_source,$label_version][]; $binding.platform.labels[.] | type == "string")) and
    (.root.labels[$label_source] == $source_repository) and
    (.platform.labels[$label_source] == $source_repository) and
    (.root.labels[$label_revision] == $source) and
    (.platform.labels[$label_revision] == $source) and
    (.root.labels[$label_version] == $version) and
    (.platform.labels[$label_version] == $version)
  ' <<<"$BINDING" >/dev/null; then
  emit rejected partial-binding
  exit 1
fi

ROOT_DIGEST=$(jq -r '.root.digest' <<<"$BINDING")
PLATFORM_DIGEST=$(jq -r '.platform.digest' <<<"$BINDING")

if ! jq -e \
  --arg root "$ROOT_DIGEST" \
  --arg platform "$PLATFORM_DIGEST" '
    (.referrers | length == 2) and
    ([.referrers[] | .kind] | sort) == ["provenance", "sbom"] and
    ([.referrers[] | .digest] |
      all(.[]; type == "string" and test("^sha256:[0-9a-f]{64}$"))) and
    ([.referrers[] | .digest] | unique | length) == 2 and
    (all(.referrers[];
      (.subject == $root or .subject == $platform) and
      (.artifactType | type == "string" and length > 0)
    )) and
    ([
      .referrers[] |
      select(.kind == "provenance") |
      select(.artifactType == "application/vnd.in-toto+json") |
      select(.predicateType | type == "string" and
        startswith("https://slsa.dev/provenance/"))
    ] | length) == 1 and
    ([
      .referrers[] |
      select(.kind == "sbom") |
      select(
        .artifactType == "application/spdx+json" or
        .artifactType == "application/vnd.cyclonedx+json"
      ) |
      select(.predicateType | type == "string" and
        (. == "https://spdx.dev/Document" or
         . == "http://cyclonedx.org/schema"))
    ] | length) == 1
  ' <<<"$BINDING" >/dev/null; then
  emit rejected referrer-closure
  exit 1
fi

if ! jq -e \
  --arg root "$ROOT_DIGEST" \
  --arg platform "$PLATFORM_DIGEST" \
  --arg source "$SOURCE" \
  --arg version "$VERSION" \
  --arg source_repository "$SOURCE_REPOSITORY" '
    (.githubAttestations | length == 1) and
    (.githubAttestations[0].subject == $root or
     .githubAttestations[0].subject == $platform) and
    (.githubAttestations[0].repository == $source_repository) and
    (.githubAttestations[0].source == $source) and
    (.githubAttestations[0].revision == $source) and
    (.githubAttestations[0].version == $version) and
    (.githubAttestations[0].workflow | type == "string" and
      startswith($source_repository + "/.github/workflows/") and
      contains("@refs/"))
  ' <<<"$BINDING" >/dev/null; then
  emit rejected missing-github-attestation
  exit 1
fi

emit reusable complete
exit 0
