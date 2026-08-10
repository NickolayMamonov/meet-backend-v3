#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: release-asset-inventory.sh canonical-json|fingerprint [--allow-empty] [--release-file PATH]" >&2
  exit 2
}

fail() {
  echo "release asset inventory failed: $1" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage
MODE=$1
shift
case "$MODE" in
  canonical-json|fingerprint) ;;
  *) usage ;;
esac

ALLOW_EMPTY=false
RELEASE_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-empty)
      [ "$ALLOW_EMPTY" = false ] || usage
      ALLOW_EMPTY=true
      shift
      ;;
    --release-file)
      [ "$#" -ge 2 ] || usage
      case "$2" in --*) usage ;; esac
      [ -z "$RELEASE_FILE" ] || usage
      RELEASE_FILE=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
if [ "$MODE" = fingerprint ]; then
  command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
fi

WORK_DIR=$(mktemp -d 2>/dev/null) || fail "temporary workspace is unavailable"
trap 'rm -r -- "$WORK_DIR"' EXIT HUP INT TERM
INPUT=$WORK_DIR/release.json
CANONICAL=$WORK_DIR/canonical.json

if [ -n "$RELEASE_FILE" ]; then
  [ -f "$RELEASE_FILE" ] ||
    fail "release file is missing, non-regular, or unreadable"
  cat "$RELEASE_FILE" >"$INPUT" 2>/dev/null ||
    fail "release file is missing, non-regular, or unreadable"
else
  cat >"$INPUT" 2>/dev/null ||
    fail "release JSON could not be read"
fi

EXPECTED='["SHA256SUMS","image-index.json","image-inspect.txt","release-manifest.json"]'
jq -e -s \
  --argjson expected "$EXPECTED" \
  --argjson allow_empty "$ALLOW_EMPTY" '
    length == 1 and
    (.[0] |
      type == "object" and
      (.assets | type == "array") and
      (.assets as $assets |
        (
          (($assets | length) == 0 and $allow_empty) or
          (
            ($assets | length) == 4 and
            all($assets[];
              type == "object" and
              (.name | (type == "string" and length > 0)) and
              (.id | (type == "number" and floor == . and . > 0)) and
              (.size | (type == "number" and floor == . and . > 0)) and
              (.state == "uploaded") and
              (.created_at | (type == "string" and length > 0)) and
              (.updated_at | (type == "string" and length > 0)) and
              (.url | (type == "string" and length > 0))
            ) and
            ([$assets[].name] | sort) == $expected and
            ([$assets[].name] | unique | length) == 4 and
            ([$assets[].id] | unique | length) == 4
          )
        )
      )
    )
  ' "$INPUT" >/dev/null 2>&1 ||
  fail "release asset inventory is malformed or incomplete"

jq -e -c -j -s '
  .[0].assets |
  map({
    name,
    id,
    size,
    state,
    created_at,
    updated_at,
    url
  }) |
  sort_by(.name)
' "$INPUT" >"$CANONICAL" 2>/dev/null ||
  fail "release asset inventory canonicalization failed"

if [ "$MODE" = canonical-json ]; then
  cat "$CANONICAL" 2>/dev/null || fail "release asset inventory output failed"
  exit 0
fi

DIGEST=$(
  printf '%s' "$(cat "$CANONICAL")" |
    sha256sum 2>/dev/null |
    awk '{print $1}'
) || fail "release asset inventory fingerprinting failed"
[[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] ||
  fail "release asset inventory fingerprinting failed"
printf '%s\n' "$DIGEST"
