#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-release-checksums.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/assets"

for name in release-manifest.json image-index.json image-inspect.txt; do
  printf 'fixture %s\n' "$name" >"$TMP/assets/$name"
done
(
  cd "$TMP/assets"
  for name in release-manifest.json image-index.json image-inspect.txt; do
    digest=$(sha256sum "$name" | awk '{print $1}')
    printf '%s  %s\n' "$digest" "$name"
  done >SHA256SUMS
)

"$VERIFY" --release-id 371012814 --assets-dir "$TMP/assets" |
  grep -Fx 'checksums=verified format=canonical release_id=371012814'

sed 's/  //' "$TMP/assets/SHA256SUMS" >"$TMP/compact"
cp "$TMP/compact" "$TMP/assets/SHA256SUMS"
"$VERIFY" --release-id 371012814 --assets-dir "$TMP/assets" \
  --allow-immutable-v1.2.0-compact |
  grep -Fx 'checksums=verified format=compact-exception release_id=371012814'

expect_failure() {
  local marker=$1
  shift
  if "$@" >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "expected checksum rejection: $marker" >&2
    exit 1
  fi
  [ ! -s "$TMP/stdout" ]
  [ -s "$TMP/stderr" ]
}

expect_failure compact-without-exception \
  "$VERIFY" --release-id 371012814 --assets-dir "$TMP/assets"
expect_failure compact-other-release \
  "$VERIFY" --release-id 371012815 --assets-dir "$TMP/assets" \
  --allow-immutable-v1.2.0-compact

cp "$TMP/compact" "$TMP/assets/SHA256SUMS"
sed -n '1p' "$TMP/compact" >>"$TMP/assets/SHA256SUMS"
expect_failure duplicate-record \
  "$VERIFY" --release-id 371012814 --assets-dir "$TMP/assets" \
  --allow-immutable-v1.2.0-compact

cp "$TMP/compact" "$TMP/assets/SHA256SUMS"
printf 'tampered\n' >>"$TMP/assets/image-index.json"
expect_failure digest-mismatch \
  "$VERIFY" --release-id 371012814 --assets-dir "$TMP/assets" \
  --allow-immutable-v1.2.0-compact

echo "release checksum fixtures passed: canonical format and exact immutable v1.2.0 compact exception"
