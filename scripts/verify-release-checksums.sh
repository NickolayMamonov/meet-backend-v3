#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --release-id ID --assets-dir PATH [--allow-immutable-v1.2.0-compact]" >&2
  exit 2
}

fail() {
  echo "release checksum verification failed: $1" >&2
  exit 1
}

release_id=
assets_dir=
allow_compact=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-id)
      [ "$#" -ge 2 ] && [ -z "$release_id" ] || usage
      release_id=$2
      shift 2
      ;;
    --assets-dir)
      [ "$#" -ge 2 ] && [ -z "$assets_dir" ] || usage
      assets_dir=$2
      shift 2
      ;;
    --allow-immutable-v1.2.0-compact)
      [ "$allow_compact" = false ] || usage
      allow_compact=true
      shift
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || usage
[ -d "$assets_dir" ] || fail "assets directory is unavailable"
if [ "$allow_compact" = true ] && [ "$release_id" != 371012814 ]; then
  fail "compact checksum exception is restricted to immutable release 371012814"
fi

command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

expected=(
  release-manifest.json
  image-index.json
  image-inspect.txt
)
checksums=$assets_dir/SHA256SUMS
[ -f "$checksums" ] && [ ! -L "$checksums" ] && [ -r "$checksums" ] ||
  fail "SHA256SUMS is missing or unsafe"

declare -A seen=()
format=
records=0
while IFS= read -r line || [ -n "$line" ]; do
  digest=
  name=
  line=${line%$'\r'}
  if [[ "$line" =~ ^([0-9a-f]{64})\ \ (release-manifest\.json|image-index\.json|image-inspect\.txt)$ ]]; then
    digest=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    record_format=canonical
  elif [ "$allow_compact" = true ] &&
    [[ "$line" =~ ^([0-9a-f]{64})(release-manifest\.json|image-index\.json|image-inspect\.txt)$ ]]; then
    digest=${BASH_REMATCH[1]}
    name=${BASH_REMATCH[2]}
    record_format=compact-exception
  else
    fail "SHA256SUMS contains a malformed or unauthorized record"
  fi
  [ -z "$format" ] || [ "$format" = "$record_format" ] ||
    fail "SHA256SUMS mixes checksum formats"
  format=$record_format
  [ -z "${seen[$name]:-}" ] || fail "SHA256SUMS contains a duplicate filename"
  seen[$name]=$digest
  records=$((records + 1))
done <"$checksums"

[ "$records" -eq 3 ] || fail "SHA256SUMS must contain exactly three records"
for name in "${expected[@]}"; do
  [ -n "${seen[$name]:-}" ] || fail "SHA256SUMS omits an expected asset"
  file=$assets_dir/$name
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] ||
    fail "a checksummed asset is missing or unsafe"
  actual=$(sha256sum "$file" | awk '{print $1}')
  [ "$actual" = "${seen[$name]}" ] ||
    fail "an asset digest does not match SHA256SUMS"
done

printf 'checksums=verified format=%s release_id=%s\n' "$format" "$release_id"
