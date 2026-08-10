#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --package-versions-file PATH --digest sha256:... [--output PATH]" >&2
  exit 2
}

fail() {
  echo "GHCR package inventory normalization failed: $*" >&2
  exit 1
}

PACKAGE_VERSIONS_FILE=
DIGEST=
OUTPUT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --package-versions-file)
      [ "$#" -ge 2 ] || usage
      PACKAGE_VERSIONS_FILE=$2
      shift 2
      ;;
    --digest)
      [ "$#" -ge 2 ] || usage
      DIGEST=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$PACKAGE_VERSIONS_FILE" ] || usage
[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || usage

jq -e '
  type == "array" and
  length > 0 and
  all(.[]; type == "array") and
  ([.[][]] | length > 0) and
  all(.[][];
    type == "object" and
    (.name | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
    (.metadata | type == "object") and
    (.metadata.container | type == "object") and
    (.metadata.container.tags | type == "array" and
      all(.[]; type == "string"))
  )
' "$PACKAGE_VERSIONS_FILE" >/dev/null ||
  fail "GitHub package API response is not an array of version pages"

normalized=$(jq --arg digest "$DIGEST" '
  [.[][]] as $versions |
  [$versions[] | select(.name == $digest)] as $images |
  if ($images | length) != 1 then
    error("expected exactly one package version for the image digest")
  else
    [$versions[] | select(.name == $digest) |
      .metadata.container.tags] | add as $aliases |
    {
      digest: $digest,
      aliases: (reduce ($aliases // [])[] as $alias
        ({}; .[$alias] = $digest)),
      latest: (if any($versions[]; .metadata.container.tags |
        index("latest")) then $digest else null end),
      versions: [$versions[] | {
        id: .id,
        digest: .name,
        tags: .metadata.container.tags
      }]
    }
  end
' "$PACKAGE_VERSIONS_FILE") || fail "package API response could not be normalized"

if [ -n "$OUTPUT" ]; then
  printf '%s\n' "$normalized" >"$OUTPUT"
else
  printf '%s\n' "$normalized"
fi
