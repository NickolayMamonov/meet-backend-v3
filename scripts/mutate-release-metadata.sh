#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 canonicalize|publish --repository owner/repo --release-id ID --version X.Y.Z --tag vX.Y.Z --source-sha SHA --target SHA --expected-fingerprint SHA256 --repo-dir PATH [--observed-tag untagged-XXXXXXXXXXXXXXXXXXXX] [--release-file PATH]" >&2
  exit 2
}

fail() {
  echo "release metadata mutation failed: $*" >&2
  exit 1
}

[ "$#" -ge 1 ] || usage
OP=$1
shift
case "$OP" in canonicalize|publish) ;; *) usage ;; esac

REPOSITORY=${GITHUB_REPOSITORY:-}
RELEASE_ID=
VERSION=
TAG=
SOURCE_SHA=
TARGET=
EXPECTED_FINGERPRINT=
REPO_DIR=.
RELEASE_FILE=
OBSERVED_TAG=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --release-id) [ "$#" -ge 2 ] || usage; RELEASE_ID=$2; shift 2 ;;
    --version) [ "$#" -ge 2 ] || usage; VERSION=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --target) [ "$#" -ge 2 ] || usage; TARGET=$2; shift 2 ;;
    --expected-fingerprint)
      [ "$#" -ge 2 ] || usage
      EXPECTED_FINGERPRINT=$2
      shift 2
      ;;
    --repo-dir) [ "$#" -ge 2 ] || usage; REPO_DIR=$2; shift 2 ;;
    --release-file) [ "$#" -ge 2 ] || usage; RELEASE_FILE=$2; shift 2 ;;
    --observed-tag) [ "$#" -ge 2 ] || usage; OBSERVED_TAG=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"
command -v gh >/dev/null 2>&1 || fail "gh is required"
[[ "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || usage
[[ "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ "$TAG" = "v$VERSION" ] || usage
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[ "$TARGET" = "$SOURCE_SHA" ] || usage
[[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] || usage
if [ "$OP" = canonicalize ]; then
  [[ "$OBSERVED_TAG" =~ ^untagged-[0-9a-f]{20}$ ]] || usage
fi
git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "repo-dir is not a Git work tree"

tmp=$(mktemp -d)
trap 'rm -r -- "$tmp"' EXIT HUP INT TERM
notes=$tmp/notes

git -C "$REPO_DIR" show "$SOURCE_SHA:CHANGELOG.md" >"$tmp/changelog" 2>/dev/null ||
  fail "canonical changelog is unavailable at the release source"
awk -v version="$VERSION" '
  index($0, "## [" version "]") == 1 ||
  index($0, "## " version) == 1 {
    if (found) { exit 2 }
    found=1
  }
  found && $0 ~ /^## / &&
    index($0, "## [" version "]") != 1 &&
    index($0, "## " version) != 1 {
    exit
  }
  found { print }
  END {
    if (!found) exit 3
  }
' "$tmp/changelog" >"$notes" ||
  fail "canonical changelog must contain exactly one release section"
[ -s "$notes" ] || fail "canonical changelog section is empty"

load_release() {
  if [ -n "$RELEASE_FILE" ]; then
    jq -c . "$RELEASE_FILE"
  else
    gh api "repos/$REPOSITORY/releases/$RELEASE_ID"
  fi
}

fingerprint() {
  jq -c '[.assets[] | {
    name, id, size, state, created_at, updated_at, url
  }] | sort_by(.name)' <<<"$1" |
    sha256sum | awk '{print $1}'
}

if [ -z "$RELEASE_FILE" ]; then
  git -C "$REPO_DIR" fetch --no-tags origin \
    '+refs/heads/dev:refs/remotes/origin/dev' >/dev/null ||
    fail "authoritative origin/dev fetch failed"
fi
if [ -z "$RELEASE_FILE" ]; then
  resolver="$(dirname "${BASH_SOURCE[0]}")/resolve-release-descriptor.sh"
  if [ "$OP" = canonicalize ]; then
    authority=$(
      "$resolver" pre-action \
        --repo-dir "$REPO_DIR" \
        --repository "$REPOSITORY" \
        --dev-ref origin/dev
    ) || fail "current authority could not be revalidated"
    value() {
      awk -F= -v key="$1" '$1 == key {
        sub(/^[^=]*=/, "")
        print
      }' <<<"$authority"
    }
    [ "$(value route)" = recovery ] &&
      [ "$(value observed_state)" = generated_placeholder ] &&
      [ "$(value release_id)" = "$RELEASE_ID" ] &&
      [ "$(value observed_tag)" = "$OBSERVED_TAG" ] ||
      fail "generated placeholder authority changed before canonicalization"
  else
    "$resolver" verify \
      --repo-dir "$REPO_DIR" \
      --repository "$REPOSITORY" \
      --dev-ref origin/dev \
      --release-id "$RELEASE_ID" \
      --tag "$TAG" \
      --version "$VERSION" \
      --source-sha "$SOURCE_SHA" \
      --asset-inventory-fingerprint "$EXPECTED_FINGERPRINT" >/dev/null ||
      fail "canonical draft authority changed before publication"
  fi
fi

before=$(load_release) || fail "release descriptor lookup failed"
before_fingerprint=$(fingerprint "$before")
jq -e \
  --argjson id "$RELEASE_ID" \
  --arg version "$VERSION" \
  --arg tag "$TAG" \
  --arg target "$TARGET" \
  --arg fingerprint "$EXPECTED_FINGERPRINT" \
  --arg observed_tag "$OBSERVED_TAG" \
  --arg op "$OP" '
    type == "object" and
    .id == $id and
    (($op == "canonicalize" and .tag_name == $observed_tag) or
     ($op == "publish" and .tag_name == $tag)) and
    .target_commitish == $target and
    .draft == true and
    .prerelease == false and
    .published_at == null and
    ($fingerprint | length == 64) and
    (($op == "canonicalize" and ($observed_tag | test("^untagged-[0-9a-f]{20}$"))) or
     ($op == "publish"))
  ' <<<"$before" >/dev/null ||
  fail "release precondition is not the expected same-ID state"
if [ "$before_fingerprint" != "$EXPECTED_FINGERPRINT" ]; then
  fail "release asset fingerprint changed before mutation"
fi

payload=$tmp/payload.json
draft=true
[ "$OP" = publish ] && draft=false
jq -n \
  --arg tag "$TAG" \
  --arg target "$TARGET" \
  --arg name "$TAG" \
  --rawfile body "$notes" \
  --argjson draft "$draft" \
  '{
    tag_name: $tag,
    target_commitish: $target,
    name: $name,
    body: $body,
    draft: $draft,
    prerelease: false,
    make_latest: "false",
    generate_release_notes: false
  }' >"$payload"

gh api --method PATCH \
    "repos/$REPOSITORY/releases/$RELEASE_ID" \
    --input "$payload" >/dev/null ||
  fail "release metadata PATCH failed"

after=$(load_release) || fail "release descriptor re-fetch failed"
after_fingerprint=$(fingerprint "$after")
jq -e \
  --argjson id "$RELEASE_ID" \
  --arg tag "$TAG" \
  --arg target "$TARGET" \
  --argjson draft "$draft" \
  --rawfile body "$notes" \
  --arg op "$OP" '
    type == "object" and
    .id == $id and
    .tag_name == $tag and
    .target_commitish == $target and
    .name == $tag and
    .body == $body and
    .draft == $draft and
    .prerelease == false and
    (($op == "canonicalize" and .published_at == null) or
     ($op == "publish" and (.published_at | type == "string" and length > 0)))
  ' <<<"$after" >/dev/null ||
  fail "release metadata postcondition failed"
[ "$after_fingerprint" = "$EXPECTED_FINGERPRINT" ] ||
  fail "release assets changed during metadata mutation"

printf 'mutation=verified\noperation=%s\nrelease_id=%s\nasset_inventory_fingerprint=%s\n' \
  "$OP" "$RELEASE_ID" "$after_fingerprint"
