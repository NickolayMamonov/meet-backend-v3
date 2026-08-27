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
  id:120,name:"v1.0.0",tag_name:"v1.0.0",target_commitish:$source,draft:true,immutable:false,prerelease:false,
  published_at:null,assets:[]
}]' >"$TMP/draft.json"
if "$RESOLVER" pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/draft.json" --refs-file "$TMP/refs.json" \
  >"$TMP/stale.out" 2>"$TMP/stale.err"; then
  echo "stale pre-existing draft was incorrectly materialized" >&2
  exit 1
fi
jq -n --arg source "$SOURCE" '[{
  id:120,name:"v1.0.0",tag_name:"v1.0.0",target_commitish:$source,draft:false,immutable:true,prerelease:false,
  published_at:"2026-08-14T00:00:00Z",assets:[]
}]' >"$TMP/published.json"
assert_output 'route=completed' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --allow-completed --releases-file "$TMP/published.json" --refs-file "$TMP/refs.json"

OLD_SOURCE=abcdefabcdefabcdefabcdefabcdefabcdefabcd
jq -n --arg old_source "$OLD_SOURCE" '[{
  id:123,name:"v1.0.0",tag_name:"v1.0.0",target_commitish:$old_source,draft:false,immutable:true,prerelease:false,
  published_at:"2026-08-14T00:00:00Z",assets:[]
}]' >"$TMP/published-old-source.json"
assert_output 'route=action' pre-action --repo-dir "$REPO" \
  --dev-ref HEAD --releases-file "$TMP/published-old-source.json" \
  --refs-file "$TMP/refs.json"
assert_output 'route=completed' post-action --repo-dir "$REPO" \
  --dev-ref HEAD --tag v1.0.0 --version 1.0.0 --source-sha "$SOURCE" \
  --allow-completed --release-created false \
  --releases-file "$TMP/published-old-source.json" --refs-file "$TMP/refs.json"

jq -n --arg source "$SOURCE" '[{
  id:121,name:"v1.0.0",tag_name:"v1.0.0",target_commitish:$source,draft:true,immutable:false,prerelease:false,
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
  id:122,name:"v1.0.0",tag_name:"v1.0.0",target_commitish:$source,draft:false,immutable:true,prerelease:false,
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

assert_output 'asset_inventory_kind=empty' verify --repo-dir "$REPO" \
  --dev-ref HEAD --release-id 121 --tag v1.0.0 --version 1.0.0 \
  --source-sha "$SOURCE" --phase empty --releases-file "$TMP/fresh-after.json"
if "$RESOLVER" verify --repo-dir "$REPO" \
  --dev-ref HEAD --release-id 120 --tag v1.0.0 --version 1.0.0 \
  --source-sha "$SOURCE" --phase empty --releases-file "$TMP/published.json" \
  >/dev/null 2>&1; then
  echo "valid published release passed verification" >&2
  exit 1
fi
jq '.[0].assets=[{},{},{},{}]' "$TMP/fresh-after.json" >"$TMP/complete.json"
assert_output 'asset_inventory_kind=complete' verify --repo-dir "$REPO" \
  --dev-ref HEAD --release-id 121 --tag v1.0.0 --version 1.0.0 \
  --source-sha "$SOURCE" --phase complete --releases-file "$TMP/complete.json"
jq '.[0].assets=[{}]' "$TMP/fresh-after.json" >"$TMP/partial.json"
if "$RESOLVER" verify --repo-dir "$REPO" \
  --dev-ref HEAD --release-id 121 --tag v1.0.0 --version 1.0.0 \
  --source-sha "$SOURCE" --phase empty --releases-file "$TMP/partial.json" \
  >/dev/null 2>&1; then
  echo "partial asset inventory passed empty-phase verification" >&2
  exit 1
fi

for publication_mutation in \
  '.[0].published_at=false' \
  'del(.[0].published_at)' \
  '.[0].draft=false' \
  '.[0].immutable=true' \
  '.[0].published_at=""' \
  '.[0].published_at="2026-08-14T00:00:00Z"' \
  '.[0].published_at="2026-08-14T00:00:00Z" | .[0].draft=false | .[0].immutable=true | .[0].target_commitish="main"' \
  '.[0].target_commitish="abcdefabcdefabcdefabcdefabcdefabcdefabcd"'; do
  jq "$publication_mutation" "$TMP/fresh-after.json" >"$TMP/invalid-publication.json"
  if "$RESOLVER" verify --repo-dir "$REPO" \
    --dev-ref HEAD --release-id 121 --tag v1.0.0 --version 1.0.0 \
    --source-sha "$SOURCE" --phase empty \
    --releases-file "$TMP/invalid-publication.json" >/dev/null 2>&1; then
    echo "invalid published_at state passed verification: $publication_mutation" >&2
    exit 1
  fi
done

for publication_mutation in \
  '.[0].draft=true' \
  '.[0].immutable=false' \
  '.[0].published_at=null'; do
  jq "$publication_mutation" "$TMP/published.json" >"$TMP/invalid-publication.json"
  if "$RESOLVER" verify --repo-dir "$REPO" \
    --dev-ref HEAD --release-id 120 --tag v1.0.0 --version 1.0.0 \
    --source-sha "$SOURCE" --phase empty \
    --releases-file "$TMP/invalid-publication.json" >/dev/null 2>&1; then
    echo "invalid published release state passed verification: $publication_mutation" >&2
    exit 1
  fi
done

jq '.[1] = (.[0] | .id = 124)' "$TMP/fresh-after.json" >"$TMP/ambiguous.json"
if "$RESOLVER" verify --repo-dir "$REPO" \
  --dev-ref HEAD --release-id 121 --tag v1.0.0 --version 1.0.0 \
  --source-sha "$SOURCE" --phase empty --releases-file "$TMP/ambiguous.json" \
  >/dev/null 2>&1; then
  echo "second current release with a different ID passed verification" >&2
  exit 1
fi

echo "future-only pre-action routing fixtures passed"
