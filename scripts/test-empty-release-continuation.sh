#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ADMIT=$ROOT_DIR/scripts/admit-empty-release-continuation.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
REPO=$TMP/repo
mkdir "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name fixture
git -C "$REPO" config user.email fixture@example.invalid
jq -n '{".":"1.2.0"}' >"$REPO/.release-please-manifest.json"
jq -n '{version:"1.2.0"}' >"$REPO/version.json"
git -C "$REPO" add .
git -C "$REPO" commit -qm release
SOURCE=$(git -C "$REPO" rev-parse HEAD)
printf '%s\n' tooling >"$REPO/tooling.txt"
git -C "$REPO" add tooling.txt
git -C "$REPO" commit -qm tooling

jq -n --arg source "$SOURCE" '[{
  id:371012814,tag_name:"v1.2.0",target_commitish:$source,draft:true,
  prerelease:false,published_at:null,assets:[]
}]' >"$TMP/releases.json"
jq -n '{refs:{},tags:{}}' >"$TMP/refs.json"
printf '%s\n' \
  'v1.2.0 absent' \
  '1.2.0 absent' \
  "sha-$SOURCE absent" \
  'latest=absent' \
  'state=empty' >"$TMP/registry.txt"

run_admission() {
  "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref HEAD \
    --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
    --source-sha "$SOURCE" --releases-file "$TMP/releases.json" \
    --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json"
}

run_admission | grep -Fx 'route=materialize'

cp "$TMP/registry.txt" "$TMP/registry-ok.txt"
sed 's/^v1.2.0 absent$/v1.2.0 sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$TMP/registry-ok.txt" >"$TMP/registry.txt"
if run_admission >/dev/null 2>&1; then
  echo "non-empty candidate registry was admitted" >&2
  exit 1
fi
mv "$TMP/registry-ok.txt" "$TMP/registry.txt"

jq '.refs["v1.2.0"]={type:"commit",sha:"'"$SOURCE"'"}' \
  "$TMP/refs.json" >"$TMP/refs-present.json"
if "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref HEAD \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source-sha "$SOURCE" --releases-file "$TMP/releases.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs-present.json" \
  >/dev/null 2>&1; then
  echo "existing release tag was admitted" >&2
  exit 1
fi

jq '.[0].assets=[{name:"partial"}]' "$TMP/releases.json" >"$TMP/partial.json"
if "$ADMIT" --repository owner/repo --repo-dir "$REPO" --dev-ref HEAD \
  --release-id 371012814 --tag v1.2.0 --version 1.2.0 \
  --source-sha "$SOURCE" --releases-file "$TMP/partial.json" \
  --registry-state-file "$TMP/registry.txt" --refs-file "$TMP/refs.json" \
  >/dev/null 2>&1; then
  echo "partial release assets were admitted" >&2
  exit 1
fi

echo "empty release continuation fixtures passed"
