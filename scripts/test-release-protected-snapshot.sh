#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
cp "$ROOT_DIR/docs/evidence/MEE2-48-protected-history-v1.json" \
  "$TMP/snapshot.json"
"$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
  --snapshot "$TMP/snapshot.json"
if jq '.objects.blockedV1_1_0.release.draft = false' \
  "$TMP/snapshot.json" >"$TMP/drift.json" &&
  "$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
    --snapshot "$TMP/drift.json"; then
  echo "protected snapshot drift was incorrectly accepted" >&2
  exit 1
fi
echo "protected snapshot fixtures passed"
