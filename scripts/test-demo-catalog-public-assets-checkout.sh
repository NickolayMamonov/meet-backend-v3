#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
ORGANIZE_SHA=3229a94a4cc9698f5ed09320a80a68ec9b9746e5661a982b872d90157cba72b6
NETWORKING_SHA=5c7baf9641ba6b602444595199dff14c0cca31125ca3f666f5fd63b9766e0900

mkdir -p "$TMP/seed/src/main/resources/static/demo-events"
cp -- "$ROOT_DIR/.gitattributes" "$TMP/seed/.gitattributes"
cp -- "$ROOT_DIR/src/main/resources/static/demo-events/organize-online" \
  "$TMP/seed/src/main/resources/static/demo-events/organize-online"
cp -- "$ROOT_DIR/src/main/resources/static/demo-events/networking-online" \
  "$TMP/seed/src/main/resources/static/demo-events/networking-online"
git -C "$TMP/seed" init -q
git -C "$TMP/seed" config user.name fixture
git -C "$TMP/seed" config user.email fixture@example.invalid
git -C "$TMP/seed" config core.autocrlf true
git -C "$TMP/seed" add .
git -C "$TMP/seed" commit -qm fixture
git clone -q --no-local "$TMP/seed" "$TMP/checkout"
git -C "$TMP/checkout" config core.autocrlf true
git -C "$TMP/checkout" checkout -q --force

for asset in organize-online networking-online; do
  path="$TMP/checkout/src/main/resources/static/demo-events/$asset"
  attr=$(git -C "$TMP/checkout" check-attr text -- \
    "src/main/resources/static/demo-events/$asset" | awk -F': ' '{print $3}')
  [ "$attr" = unset ] || { echo "asset lacks -text policy: $asset" >&2; exit 1; }
  [ -f "$path" ] && [ ! -L "$path" ] || exit 1
done
[ "$(wc -c <"$TMP/checkout/src/main/resources/static/demo-events/organize-online" | tr -d ' ')" -eq 911 ]
[ "$(wc -c <"$TMP/checkout/src/main/resources/static/demo-events/networking-online" | tr -d ' ')" -eq 870 ]
[ "$(sha256sum "$TMP/checkout/src/main/resources/static/demo-events/organize-online" | awk '{print $1}')" = "$ORGANIZE_SHA" ]
[ "$(sha256sum "$TMP/checkout/src/main/resources/static/demo-events/networking-online" | awk '{print $1}')" = "$NETWORKING_SHA" ]
git -C "$TMP/checkout" diff --quiet
echo "demo catalog public asset fresh checkout fixture passed"
