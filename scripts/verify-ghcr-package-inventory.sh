#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --inventory-file PATH --digest sha256:... --tag vX.Y.Z --version X.Y.Z --source-sha SHA [--platform-subject sha256:...]" >&2
  exit 2
}

fail() {
  echo "GHCR package inventory verification failed: $*" >&2
  exit 1
}

INVENTORY_FILE=
DIGEST=
TAG=
VERSION=
SOURCE_SHA=
PLATFORM_SUBJECT=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --inventory-file) [ "$#" -ge 2 ] || usage; INVENTORY_FILE=$2; shift 2 ;;
    --digest) [ "$#" -ge 2 ] || usage; DIGEST=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --platform-subject) [ "$#" -ge 2 ] || usage; PLATFORM_SUBJECT=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$INVENTORY_FILE" ] || usage
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ "$TAG" = "v$VERSION" ] || usage
if [ -n "$PLATFORM_SUBJECT" ]; then
  [[ "$PLATFORM_SUBJECT" =~ ^sha256:[0-9a-f]{64}$ ]] || usage
fi

EXPECTED_TAGS=$(jq -cn --arg tag "$TAG" --arg version "$VERSION" \
  --arg source "$SOURCE_SHA" \
  '[$tag, $version, ("sha-" + $source)] | sort')
SUBJECT_MARKER="sha256-${DIGEST#sha256:}"

jq -e \
  --arg digest "$DIGEST" \
  --argjson expected "$EXPECTED_TAGS" '
    type == "object" and
    (.versions | type == "array" and length > 0) and
    (.aliases | type == "object") and
    ([.aliases | keys[]] | sort) == $expected and
    ([.aliases[]] | unique) == [$digest] and
    (.latest == null)
  ' "$INVENTORY_FILE" >/dev/null ||
  fail "inventory aliases, latest marker, or version list is malformed"

jq -e --arg digest "$DIGEST" --argjson expected "$EXPECTED_TAGS" '
  [.versions[] | select(.digest == $digest)] as $images |
  ($images | length) == 1 and
  ($images[0].tags | type == "array") and
  (($images[0].tags | sort) == $expected)
' "$INVENTORY_FILE" >/dev/null ||
  fail "expected image digest does not carry exactly the three release aliases"

jq -e \
  --arg digest "$DIGEST" \
  --arg marker "$SUBJECT_MARKER" '
  [.versions[] | select((.tags | index($marker)) != null)] as $markers |
  ($markers | length) <= 1 and
  (($markers | length) == 0 or $markers[0].digest != $digest)
' "$INVENTORY_FILE" >/dev/null ||
  fail "subject marker must not be duplicated or belong to the image version"

jq -e \
  --arg digest "$DIGEST" \
  --arg platform "${PLATFORM_SUBJECT:-$DIGEST}" \
  --arg version "$VERSION" \
  --arg source "$SOURCE_SHA" '
  all(.versions[];
    (.digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    all(.tags[];
      . != "latest" and
      (
        . == "v" + $version or
        . == $version or
        . == "sha-" + $source or
        . == "sha256-" + ($digest | sub("^sha256:"; "" ))
      )
    )
  )
' "$INVENTORY_FILE" >/dev/null ||
  fail "inventory contains an unknown or mutable tag"

jq -e \
  --arg digest "$DIGEST" \
  --arg platform "${PLATFORM_SUBJECT:-$DIGEST}" '
  all(.versions[] | select(.digest != $digest);
    (.tags | length == 0) or
    (.tags == ["sha256-" + ($digest | sub("^sha256:"; ""))])
  ) and
  all(.versions[] | select(.digest != $digest);
    (.attribution | type == "object") and
    .attribution.verified == true and
    (.attribution.subject == $digest or .attribution.subject == $platform) and
    (.attribution.kind | type == "string" and
      test("^(provenance|sbom|referrer|signature|subject)$"))
  )
' "$INVENTORY_FILE" >/dev/null ||
  fail "additional package versions are not cryptographically attributable referrers"

printf 'inventory=verified\ndigest=%s\naliases=%s\n' \
  "$DIGEST" "$EXPECTED_TAGS"
