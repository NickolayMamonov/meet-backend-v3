#!/usr/bin/env bash
set -euo pipefail

fail() { echo "release evidence verification failed: $*" >&2; exit 1; }
release_file=
expected_tag=
expected_id=
expected_source=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --release-file) release_file=${2:?}; shift 2 ;;
    --tag) expected_tag=${2:?}; shift 2 ;;
    --release-id) expected_id=${2:?}; shift 2 ;;
    --source-sha) expected_source=${2:?}; shift 2 ;;
    *) fail "unknown option: $1" ;;
  esac
done
[ -f "$release_file" ] || fail "release evidence is missing"
jq -e --arg tag "$expected_tag" --argjson id "$expected_id" --arg source "$expected_source" '
  type == "object" and .id == $id and .tag_name == $tag and
  .target_commitish == $source and .immutable == true and .draft == false and
  .prerelease == false and (.assets | type == "array" and length == 4)
' "$release_file" >/dev/null || fail "release evidence is not bound to the immutable release"
echo "evidence=verified"
