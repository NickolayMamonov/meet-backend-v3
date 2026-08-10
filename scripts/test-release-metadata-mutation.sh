#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MUTATOR=$ROOT_DIR/scripts/mutate-release-metadata.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

export GIT_AUTHOR_NAME='Release Metadata Fixture'
export GIT_AUTHOR_EMAIL='release-metadata@example.invalid'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

REPO=$TMP/repo
RELEASE_FILE=$TMP/release.json
MOCK_BIN=$TMP/bin
PATCH_LOG=$TMP/patches.log
mkdir "$MOCK_BIN"
git init -q "$REPO"
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.name "$GIT_AUTHOR_NAME"
git -C "$REPO" config user.email "$GIT_AUTHOR_EMAIL"
printf '{".":"1.0.0"}\n' >"$REPO/.release-please-manifest.json"
printf '{"version":"1.0.0"}\n' >"$REPO/version.json"
printf '# Changelog\n\n## [1.0.1]\n\n### Fixes\n\n* Restore canonical notes.\n\n## Changelog\n\n' \
  >"$REPO/CHANGELOG.md"
git -C "$REPO" add .
git -C "$REPO" commit -qm bootstrap
printf '{".":"1.0.1"}\n' >"$REPO/.release-please-manifest.json"
printf '{"version":"1.0.1"}\n' >"$REPO/version.json"
git -C "$REPO" add .release-please-manifest.json version.json
git -C "$REPO" commit -qm release
SOURCE_SHA=$(git -C "$REPO" rev-parse HEAD)

jq -n --arg source "$SOURCE_SHA" '{
  id: 701,
  tag_name: "untagged-0123456789abcdef0123",
  target_commitish: $source,
  name: "untagged-0123456789abcdef0123",
  body: "sanitized quarantine evidence",
  draft: true,
  prerelease: false,
  published_at: null,
  assets: [
    {name:"release-manifest.json",id:801,size:101,state:"uploaded",created_at:"2026-08-10T01:00:00Z",updated_at:"2026-08-10T01:00:00Z",url:"https://api.invalid/801"},
    {name:"image-index.json",id:802,size:102,state:"uploaded",created_at:"2026-08-10T01:00:00Z",updated_at:"2026-08-10T01:00:00Z",url:"https://api.invalid/802"},
    {name:"image-inspect.txt",id:803,size:103,state:"uploaded",created_at:"2026-08-10T01:00:00Z",updated_at:"2026-08-10T01:00:00Z",url:"https://api.invalid/803"},
    {name:"SHA256SUMS",id:804,size:104,state:"uploaded",created_at:"2026-08-10T01:00:00Z",updated_at:"2026-08-10T01:00:00Z",url:"https://api.invalid/804"}
  ]
}' >"$RELEASE_FILE"

cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=
next_input=false
method=GET
next_method=false
for argument in "$@"; do
  if [ "$next_input" = true ]; then
    input=$argument
    next_input=false
  elif [ "$next_method" = true ]; then
    method=$argument
    next_method=false
  elif [ "$argument" = --input ]; then
    next_input=true
  elif [ "$argument" = --method ]; then
    next_method=true
  fi
done
if [ "$method" != PATCH ]; then
  echo "unexpected read in mutation fixture" >&2
  exit 1
fi
jq -c . "$input" >>"$PATCH_LOG"
jq --slurpfile patch "$input" '
  . + $patch[0] |
  if .draft == false then .published_at = "2026-08-10T02:00:00Z" else . end
' "$RELEASE_FILE" >"$RELEASE_FILE.next"
mv "$RELEASE_FILE.next" "$RELEASE_FILE"
jq -c . "$RELEASE_FILE"
EOF
chmod +x "$MOCK_BIN/gh"
export RELEASE_FILE PATCH_LOG
export PATH="$MOCK_BIN:$PATH"

fingerprint=$(
  jq -c '[.assets[] | {
    name, id, size, state, created_at, updated_at, url
  }] | sort_by(.name)' "$RELEASE_FILE" |
    sha256sum | awk '{print $1}'
)

common=(
  --repository fixture/repository
  --release-id 701
  --version 1.0.1
  --tag v1.0.1
  --source-sha "$SOURCE_SHA"
  --target "$SOURCE_SHA"
  --expected-fingerprint "$fingerprint"
  --repo-dir "$REPO"
  --release-file "$RELEASE_FILE"
)

"$MUTATOR" canonicalize "${common[@]}" >/dev/null
head -n1 "$PATCH_LOG" | jq -e '
  .tag_name == "v1.0.1" and
  .target_commitish == "'"$SOURCE_SHA"'" and
  .draft == true and
  .prerelease == false and
  .make_latest == "false" and
  .generate_release_notes == false and
  (.body | contains("## [1.0.1]")) and
  (.body | contains("sanitized quarantine evidence") | not)
' >/dev/null

"$MUTATOR" publish "${common[@]}" >/dev/null
[ "$(wc -l <"$PATCH_LOG" | tr -d ' ')" -eq 2 ]
jq -e '.draft == false' "$RELEASE_FILE" >/dev/null

patch_count=$(wc -l <"$PATCH_LOG" | tr -d ' ')
jq '.target_commitish = "0000000000000000000000000000000000000000"' \
  "$RELEASE_FILE" >"$RELEASE_FILE.next"
mv "$RELEASE_FILE.next" "$RELEASE_FILE"
if "$MUTATOR" publish "${common[@]}" >/dev/null 2>&1; then
  echo "metadata drift unexpectedly mutated a release" >&2
  exit 1
fi
[ "$(wc -l <"$PATCH_LOG" | tr -d ' ')" -eq "$patch_count" ]
echo "release metadata mutation fixtures passed: full payload, notes, postconditions, zero-write drift"
