#!/usr/bin/env bash
set -euo pipefail
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
  id:120,tag_name:"v1.0.0",name:"v1.0.0",target_commitish:$source,draft:true,prerelease:false,
  immutable:false,published_at:null,assets:[]
}]' >"$TMP/releases.json"
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
if scripts/resolve-release-descriptor.sh pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/releases.json" --refs-file "$TMP/refs.json" \
  >"$TMP/stale.out" 2>"$TMP/stale.err"; then
  echo "pre-existing draft was incorrectly materialized" >&2
  exit 1
fi
jq -n --arg source "$source_sha" '[{
  id:121,tag_name:"v1.0.0",name:"v1.0.0",target_commitish:$source,draft:true,prerelease:false,
  immutable:false,published_at:null,assets:[]
}]' >"$TMP/fresh-after.json"
jq -n '[]' >"$TMP/fresh-before.json"
descriptor=$(scripts/resolve-release-descriptor.sh post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$source_sha" \
  --before-releases-file "$TMP/fresh-before.json" \
  --after-releases-file "$TMP/fresh-after.json" --release-created true)
grep -Fx 'route=materialize' <<<"$descriptor"
grep -Fx 'active=true' <<<"$descriptor"
grep -Fx 'origin=post_action' <<<"$descriptor"
grep -Fx "release_id=121" <<<"$descriptor"
grep -Fx 'tag=v1.0.0' <<<"$descriptor"
grep -Fx 'version=1.0.0' <<<"$descriptor"
grep -Fx "source_sha=$source_sha" <<<"$descriptor"
grep -Fx "target_commitish=$source_sha" <<<"$descriptor"
grep -Fx 'draft=true' <<<"$descriptor"
grep -Fx 'prerelease=false' <<<"$descriptor"
grep -Fx 'published_at=null' <<<"$descriptor"
grep -Fx 'asset_inventory_kind=empty' <<<"$descriptor"
echo "release descriptor schema fixtures passed"
