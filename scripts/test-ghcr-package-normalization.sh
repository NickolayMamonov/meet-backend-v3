#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NORMALIZE=$ROOT_DIR/scripts/normalize-ghcr-package-inventory.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/ghcr-package-versions/hosted-page-array.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

DIGEST=sha256:41be6a4e725898bf41823a66abc78dc19f11f31282a3ad574298729095ba59c6
OUTPUT=$TMP/inventory.json

"$NORMALIZE" \
  --package-versions-file "$FIXTURE" \
  --digest "$DIGEST" \
  --output "$OUTPUT"

jq -e \
  --arg digest "$DIGEST" '
    .digest == $digest and
    (.aliases | keys | sort) ==
      ["1.0.1","sha-d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc","v1.0.1"] and
    (.versions | length) == 5 and
    (.versions | map(.digest) | unique | length) == 5
  ' "$OUTPUT" >/dev/null

jq '.[0]' "$FIXTURE" >"$TMP/not-page-array.json"
if "$NORMALIZE" --package-versions-file "$TMP/not-page-array.json" \
    --digest "$DIGEST" >"$TMP/not-page-array.out" 2>&1; then
  echo "expected non-page-array package response rejection" >&2
  exit 1
fi

echo "GHCR package normalization fixtures passed: exact hosted page-array shape and reject"
