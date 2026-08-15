#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "Release Please action output normalization failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: normalize-release-please-action-output.sh
  --release-created VALUE --tag TAG --version VERSION --source-sha SHA
EOF
  exit 2
}

release_created=
tag=
version=
source_sha=
release_created_seen=false
tag_seen=false
version_seen=false
source_sha_seen=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-created)
      if [ "$release_created_seen" != false ] || [ "$#" -lt 2 ]; then usage; fi
      release_created=$2
      release_created_seen=true
      shift 2
      ;;
    --tag)
      if [ "$tag_seen" != false ] || [ "$#" -lt 2 ]; then usage; fi
      tag=$2
      tag_seen=true
      shift 2
      ;;
    --version)
      if [ "$version_seen" != false ] || [ "$#" -lt 2 ]; then usage; fi
      version=$2
      version_seen=true
      shift 2
      ;;
    --source-sha)
      if [ "$source_sha_seen" != false ] || [ "$#" -lt 2 ]; then usage; fi
      source_sha=$2
      source_sha_seen=true
      shift 2
      ;;
    *) usage ;;
  esac
done
if [ "$release_created_seen" != true ] ||
   [ "$tag_seen" != true ] ||
   [ "$version_seen" != true ] ||
   [ "$source_sha_seen" != true ]; then
  usage
fi

tuple_count=0
for value in "$tag" "$version" "$source_sha"; do
  [ -z "$value" ] || tuple_count=$((tuple_count + 1))
done

case "$release_created" in
  true)
    [ "$tuple_count" -eq 3 ] ||
      fail "release_created=true requires the complete release tuple"
    printf '%s\n' true
    ;;
  false)
    [ "$tuple_count" -eq 0 ] ||
      fail "release_created=false requires an empty release tuple"
    printf '%s\n' false
    ;;
  '')
    [ "$tuple_count" -eq 0 ] ||
      fail "unset release_created requires an empty release tuple"
    printf '%s\n' false
    ;;
  *)
    fail "release_created must be true, false, or unset with an empty release tuple"
    ;;
esac
