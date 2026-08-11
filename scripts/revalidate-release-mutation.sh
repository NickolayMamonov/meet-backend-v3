#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ASSET_INVENTORY_HELPER=$SCRIPT_DIR/release-asset-inventory.sh

usage() {
  echo "usage: $0 --repository owner/repo --release-id ID --tag vX.Y.Z --version X.Y.Z --source-sha SHA --expected-fingerprint SHA256 [--expected-route ROUTE] [--expected-admission-fingerprint SHA256] [--release-file PATH] [--repo-dir PATH] [--dev-ref REF]" >&2
  exit 2
}

fail() {
  echo "release mutation revalidation failed: $*" >&2
  exit 1
}

REPOSITORY=${GITHUB_REPOSITORY:-}
RELEASE_ID=
TAG=
VERSION=
SOURCE_SHA=
EXPECTED_FINGERPRINT=
EXPECTED_ROUTE=
EXPECTED_ADMISSION_FINGERPRINT=
REPO_DIR=.
DEV_REF=origin/dev
RELEASE_FILE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --release-id) [ "$#" -ge 2 ] || usage; RELEASE_ID=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --expected-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINGERPRINT=$2
      shift 2
      ;;
    --expected-route)
      [ "$#" -ge 2 ] || usage
      EXPECTED_ROUTE=$2
      shift 2
      ;;
    --expected-admission-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_ADMISSION_FINGERPRINT=$2
      shift 2
      ;;
    --repo-dir) [ "$#" -ge 2 ] || usage; REPO_DIR=$2; shift 2 ;;
    --dev-ref) [ "$#" -ge 2 ] || usage; DEV_REF=$2; shift 2 ;;
    --release-file) [ "$#" -ge 2 ] || usage; RELEASE_FILE=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
if [ -n "$RELEASE_FILE" ]; then
  [ -f "$RELEASE_FILE" ] || fail "release snapshot is missing"
  jq -e 'type == "object"' "$RELEASE_FILE" >/dev/null ||
    fail "release snapshot is not a JSON object"
else
  command -v gh >/dev/null 2>&1 || fail "gh is required"
fi

[[ "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || usage
[[ "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ "$TAG" = "v$VERSION" ] || usage
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || usage

git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "repo-dir is not a Git work tree"
if [ -z "$RELEASE_FILE" ]; then
  git -C "$REPO_DIR" fetch --no-tags origin \
    '+refs/heads/dev:refs/remotes/origin/dev' >/dev/null
fi

if [ -z "$RELEASE_FILE" ]; then
  release_file=$(mktemp)
  trap 'rm -f "$release_file"' EXIT HUP INT TERM
  gh api "repos/$REPOSITORY/releases/$RELEASE_ID" >"$release_file" ||
    fail "release descriptor lookup failed"
else
  release_file=$RELEASE_FILE
fi

jq -e \
  --argjson id "$RELEASE_ID" \
  --arg tag "$TAG" \
  --arg source "$SOURCE_SHA" '
    type == "object" and
    .id == $id and
    .tag_name == $tag and
    .target_commitish == $source and
    .draft == true and
    .published_at == null and
    (.assets | type == "array")
  ' "$release_file" >/dev/null ||
  fail "release is not the expected draft descriptor"

fingerprint=$(
  "$ASSET_INVENTORY_HELPER" fingerprint --release-file "$release_file"
) || fail "release asset inventory fingerprinting failed"
[ "$fingerprint" = "$EXPECTED_FINGERPRINT" ] ||
  fail "release asset metadata fingerprint changed"

resolver_args=(
  --repo-dir "$REPO_DIR"
  --repository "$REPOSITORY"
  --dev-ref "$DEV_REF"
  --release-id "$RELEASE_ID"
  --tag "$TAG"
  --version "$VERSION"
  --source-sha "$SOURCE_SHA"
  --asset-inventory-fingerprint "$fingerprint"
)
[ -z "$EXPECTED_ROUTE" ] ||
  resolver_args+=(--expected-route "$EXPECTED_ROUTE")
[ -z "$EXPECTED_ADMISSION_FINGERPRINT" ] ||
  resolver_args+=(--expected-admission-fingerprint "$EXPECTED_ADMISSION_FINGERPRINT")
descriptor=$(
  "$(dirname "${BASH_SOURCE[0]}")/resolve-release-descriptor.sh" verify \
    "${resolver_args[@]}" \
    --release-file "$release_file"
)

value() {
  awk -F= -v key="$1" '$1 == key {
    sub(/^[^=]*=/, "")
    print
  }' <<<"$descriptor"
}

test "$(value active)" = true
test "$(value origin)" = verified
test "$(value release_id)" = "$RELEASE_ID"
test "$(value tag)" = "$TAG"
test "$(value version)" = "$VERSION"
test "$(value source_sha)" = "$SOURCE_SHA"
test "$(value target_commitish)" = "$SOURCE_SHA"
test "$(value draft)" = true
test "$(value published_at)" = null
test "$(value asset_inventory_fingerprint)" = "$fingerprint"
printf 'mutation_admission=verified\nasset_inventory_fingerprint=%s\n' "$fingerprint"
