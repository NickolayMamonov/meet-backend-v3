#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT_DIR/scripts/resolve-release-descriptor.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
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
SOURCE=$(git -C "$REPO" rev-parse HEAD)
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
jq -n '[]' >"$TMP/empty.json"
assert_output() {
  local expected=$1
  shift
  local output_file="$TMP/assert.out"
  "$RESOLVER" "$@" >"$output_file"
  grep -Fx "$expected" "$output_file"
}
assert_output 'route=action' pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/empty.json" --refs-file "$TMP/refs.json"
jq -n --arg source "$SOURCE" '[{
  id:120,tag_name:"v1.0.0",target_commitish:$source,draft:true,prerelease:false,
  published_at:null,assets:[]
}]' >"$TMP/draft.json"
if "$RESOLVER" pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/draft.json" --refs-file "$TMP/refs.json" \
  >"$TMP/stale.out" 2>"$TMP/stale.err"; then
  echo "stale pre-existing draft was incorrectly materialized" >&2
  exit 1
fi
jq -n --arg source "$SOURCE" '[{
  id:120,tag_name:"v1.0.0",target_commitish:$source,draft:false,prerelease:false,
  published_at:"2026-08-14T00:00:00Z",assets:[]
}]' >"$TMP/published.json"
assert_output 'route=completed' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --allow-completed --releases-file "$TMP/published.json" --refs-file "$TMP/refs.json"

jq -n --arg source "$SOURCE" '[{
  id:121,tag_name:"v1.0.0",target_commitish:$source,draft:true,prerelease:false,
  published_at:null,assets:[]
}]' >"$TMP/fresh-after.json"
jq -n '[]' >"$TMP/fresh-before.json"
assert_output 'route=materialize' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --before-releases-file "$TMP/fresh-before.json" \
  --after-releases-file "$TMP/fresh-after.json" --release-created true
assert_output 'release_id=121' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --before-releases-file "$TMP/fresh-before.json" \
  --after-releases-file "$TMP/fresh-after.json" --release-created true

jq -n --arg source "$SOURCE" '[{
  id:122,tag_name:"v1.0.0",target_commitish:$source,draft:false,prerelease:false,
  published_at:"2026-08-14T00:00:00Z",assets:[]
}]' >"$TMP/published-before.json"
cp "$TMP/published-before.json" "$TMP/published-after.json"
assert_output 'route=completed' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --allow-completed --before-releases-file "$TMP/published-before.json" \
  --after-releases-file "$TMP/published-after.json" --release-created false

jq -n '[]' >"$TMP/noop-before.json"
cp "$TMP/noop-before.json" "$TMP/noop-after.json"
assert_output 'route=action' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --allow-completed --before-releases-file "$TMP/noop-before.json" \
  --after-releases-file "$TMP/noop-after.json" --release-created false

if "$RESOLVER" post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --before-releases-file "$TMP/fresh-before.json" \
  --after-releases-file "$TMP/fresh-after.json" --release-created false \
  >/dev/null 2>&1; then
  echo "release_created=false unexpectedly admitted a fresh release" >&2
  exit 1
fi

echo "future-only pre-action routing fixtures passed"
