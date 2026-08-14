#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
REPO=$TMP/repo
mkdir "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name fixture
git -C "$REPO" config user.email fixture@example.invalid
jq -n '{".":"1.0.0"}' >"$REPO/.release-please-manifest.json"
jq -n '{version:"1.0.0"}' >"$REPO/version.json"
printf '%s\n' '# Changelog' >"$REPO/CHANGELOG.md"
git -C "$REPO" add .
git -C "$REPO" commit -qm bootstrap
source_sha=$(git -C "$REPO" rev-parse HEAD)
jq -n --arg source "$source_sha" '[{
  id:120,tag_name:"v1.0.0",target_commitish:$source,draft:true,prerelease:false,
  published_at:null,assets:[]
}]' >"$TMP/releases.json"
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
descriptor=$(scripts/resolve-release-descriptor.sh pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/releases.json" --refs-file "$TMP/refs.json")
grep -Fx 'route=materialize' <<<"$descriptor"
grep -Fx "release_id=120" <<<"$descriptor"
echo "release descriptor schema fixtures passed"
