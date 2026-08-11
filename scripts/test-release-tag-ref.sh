#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-release-tag-ref.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
TAG_OBJECT=1111111111111111111111111111111111111111
WRONG_OBJECT=2222222222222222222222222222222222222222

jq -n --arg source "$SOURCE" --arg tag_object "$TAG_OBJECT" '
  {
    refs: {"v1.0.1": {type:"tag",sha:$tag_object}},
    tags: {($tag_object): {type:"commit",sha:$source}}
  }
' >"$TMP/annotated.json"
"$VERIFY" --repository fixture/repo --tag v1.0.1 \
  --source-sha "$SOURCE" --fixture "$TMP/annotated.json" |
  grep -Fx 'tag_ref=verified'

jq --arg wrong "$WRONG_OBJECT" '
  .refs["v1.0.1"].sha = $wrong
' "$TMP/annotated.json" >"$TMP/missing-object.json"
if "$VERIFY" --repository fixture/repo --tag v1.0.1 \
    --source-sha "$SOURCE" --fixture "$TMP/missing-object.json" \
    >"$TMP/missing-object.out" 2>&1; then
  echo "expected missing annotated tag object rejection" >&2
  exit 1
fi

jq --arg source "$SOURCE" '
  .refs["v1.0.1"] = {type:"commit",sha:$source}
' "$TMP/annotated.json" >"$TMP/lightweight.json"
"$VERIFY" --repository fixture/repo --tag v1.0.1 \
  --source-sha "$SOURCE" --fixture "$TMP/lightweight.json" |
  grep -Fx 'tag_ref=verified'

jq -n '{refs:{},tags:{}}' >"$TMP/generated-placeholder-before-publish.json"
if "$VERIFY" --repository fixture/repo --tag v1.0.1 \
    --source-sha "$SOURCE" \
    --fixture "$TMP/generated-placeholder-before-publish.json" \
    >"$TMP/absent.out" 2>&1; then
  echo "expected canonical tag absence rejection before publication" >&2
  exit 1
fi

echo "release tag ref fixtures passed: generated-placeholder absence, annotated peel, missing object, lightweight tag"
