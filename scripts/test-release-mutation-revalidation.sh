#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
SHA=0123456789abcdef0123456789abcdef01234567
jq -n --arg sha "$SHA" '{
  id:120,tag_name:"v1.2.0",target_commitish:$sha,draft:true,prerelease:false,
  published_at:null,assets:[{id:1},{id:2},{id:3},{id:4}]
}' >"$TMP/release.json"
"$ROOT_DIR/scripts/revalidate-release-mutation.sh" \
  --repository FixtureOwner/repo --release-id 120 --tag v1.2.0 \
  --version 1.2.0 --source-sha "$SHA" --release-file "$TMP/release.json" \
  --expected-route materialize >/dev/null
echo "release mutation revalidation fixtures passed"
