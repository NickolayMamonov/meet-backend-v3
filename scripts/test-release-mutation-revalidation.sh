#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RESOLVER=$ROOT_DIR/scripts/resolve-release-descriptor.sh
REVALIDATOR=$ROOT_DIR/scripts/revalidate-release-mutation.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

export GIT_AUTHOR_NAME='Mutation Revalidation Fixture'
export GIT_AUTHOR_EMAIL='mutation-revalidation@example.invalid'
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME
export GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL

REMOTE=$TMP/origin.git
REPO=$TMP/repo
git init -q --bare "$REMOTE"
git init -q "$REPO"
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.name "$GIT_AUTHOR_NAME"
git -C "$REPO" config user.email "$GIT_AUTHOR_EMAIL"

printf '{".":"1.0.0"}\n' >"$REPO/.release-please-manifest.json"
printf '{"version":"1.0.0"}\n' >"$REPO/version.json"
git -C "$REPO" add .release-please-manifest.json version.json
git -C "$REPO" commit -qm bootstrap

printf '{".":"1.0.1"}\n' >"$REPO/.release-please-manifest.json"
printf '{"version":"1.0.1"}\n' >"$REPO/version.json"
git -C "$REPO" add .release-please-manifest.json version.json
git -C "$REPO" commit -qm release
SOURCE_SHA=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q origin HEAD:dev
git -C "$REPO" fetch -q origin \
  '+refs/heads/dev:refs/remotes/origin/dev'

RELEASE_FILE=$TMP/release.json
jq -n --arg source "$SOURCE_SHA" '{
  id: 123,
  tag_name: "v1.0.1",
  target_commitish: $source,
  draft: true,
  prerelease: false,
  published_at: null,
  assets: [
    {
      name: "release-manifest.json",
      id: 201,
      size: 101,
      state: "uploaded",
      created_at: "2026-08-10T01:00:00Z",
      updated_at: "2026-08-10T01:00:00Z",
      url: "https://api.github.test/releases/assets/201"
    },
    {
      name: "image-index.json",
      id: 202,
      size: 102,
      state: "uploaded",
      created_at: "2026-08-10T01:00:00Z",
      updated_at: "2026-08-10T01:00:00Z",
      url: "https://api.github.test/releases/assets/202"
    },
    {
      name: "image-inspect.txt",
      id: 203,
      size: 103,
      state: "uploaded",
      created_at: "2026-08-10T01:00:00Z",
      updated_at: "2026-08-10T01:00:00Z",
      url: "https://api.github.test/releases/assets/203"
    },
    {
      name: "SHA256SUMS",
      id: 204,
      size: 104,
      state: "uploaded",
      created_at: "2026-08-10T01:00:00Z",
      updated_at: "2026-08-10T01:00:00Z",
      url: "https://api.github.test/releases/assets/204"
    }
  ]
}' >"$RELEASE_FILE"

printf '{"refs":{},"tags":{}}\n' >"$TMP/refs.json"
descriptor=$(
  "$RESOLVER" created \
    --repo-dir "$REPO" \
    --dev-ref origin/dev \
    --repository fixture/repo \
    --release-id 123 \
    --tag v1.0.1 \
    --version 1.0.1 \
    --source-sha "$SOURCE_SHA" \
    --release-file "$RELEASE_FILE" \
    --refs-file "$TMP/refs.json"
)
fingerprint=$(awk -F= '$1 == "asset_inventory_fingerprint" {print $2}' \
  <<<"$descriptor")

mkdir "$TMP/bin"
{
  echo '#!/bin/sh'
  echo 'set -eu'
  echo 'case "$*" in'
  echo '*releases/123*) echo "unexpected supplied-mode release lookup" >&2; exit 1 ;;'
  echo '*git/ref/tags/v1.0.1*)'
  echo '  echo "gh: Not Found (HTTP 404)" >&2'
  echo '  exit 1'
  echo '  ;;'
  echo '*) echo "unexpected supplied-mode gh call: $*" >&2; exit 1 ;;'
  echo 'esac'
} >"$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

output=$(
  PATH="$TMP/bin:$PATH" \
    "$REVALIDATOR" \
    --repository fixture/repo \
    --release-id 123 \
    --tag v1.0.1 \
    --version 1.0.1 \
    --source-sha "$SOURCE_SHA" \
    --expected-fingerprint "$fingerprint" \
    --release-file "$RELEASE_FILE" \
    --repo-dir "$REPO" \
    --dev-ref origin/dev
)

grep -Fx 'mutation_admission=verified' <<<"$output"
grep -Fx "asset_inventory_fingerprint=$fingerprint" <<<"$output"

cp "$RELEASE_FILE" "$TMP/release-snapshot-original.json"
jq '.target_commitish = "0000000000000000000000000000000000000000"' \
  "$RELEASE_FILE" >"$RELEASE_FILE.next"
mv "$RELEASE_FILE.next" "$RELEASE_FILE"
if PATH="$TMP/bin:$PATH" "$REVALIDATOR" \
    --repository fixture/repo \
    --release-id 123 \
    --tag v1.0.1 \
    --version 1.0.1 \
    --source-sha "$SOURCE_SHA" \
    --expected-fingerprint "$fingerprint" \
    --release-file "$RELEASE_FILE" \
    --repo-dir "$REPO" \
    --dev-ref origin/dev >/dev/null 2>&1; then
  echo "stale supplied release snapshot unexpectedly passed" >&2
  exit 1
fi
mv "$TMP/release-snapshot-original.json" "$RELEASE_FILE"
echo "release mutation revalidation fingerprint regression passed"
