#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
SHA=0123456789abcdef0123456789abcdef01234567
jq -n --arg sha "$SHA" '{
  id:120,tag_name:"v1.2.0",target_commitish:$sha,immutable:true,draft:false,
  prerelease:false,assets:[{id:1},{id:2},{id:3},{id:4}]
}' >"$TMP/release.json"
"$ROOT_DIR/scripts/verify-release-evidence.sh" \
  --release-file "$TMP/release.json" --tag v1.2.0 --release-id 120 \
  --source-sha "$SHA" >/dev/null
echo "release evidence fixtures passed"
