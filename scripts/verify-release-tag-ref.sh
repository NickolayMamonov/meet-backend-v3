#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 --repository owner/repo --tag vX.Y.Z --source-sha SHA [--fixture PATH]" >&2
  exit 2
}

fail() {
  echo "release tag verification failed: $*" >&2
  exit 1
}

REPOSITORY=
TAG=
SOURCE_SHA=
FIXTURE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repository) [ "$#" -ge 2 ] || usage; REPOSITORY=$2; shift 2 ;;
    --tag) [ "$#" -ge 2 ] || usage; TAG=$2; shift 2 ;;
    --source-sha) [ "$#" -ge 2 ] || usage; SOURCE_SHA=$2; shift 2 ;;
    --fixture) [ "$#" -ge 2 ] || usage; FIXTURE=$2; shift 2 ;;
    *) usage ;;
  esac
done

command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ "$REPOSITORY" =~ ^[^/]+/[^/]+$ ]] || usage
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[ -n "$FIXTURE" ] || command -v gh >/dev/null 2>&1 ||
  fail "gh is required for live tag verification"

load_ref() {
  if [ -n "$FIXTURE" ]; then
    jq -c --arg tag "$TAG" '.refs[$tag] // null' "$FIXTURE"
  else
    gh api "repos/$REPOSITORY/git/ref/tags/$TAG" |
      jq -c '.object'
  fi
}

load_tag_object() {
  local sha=$1
  if [ -n "$FIXTURE" ]; then
    jq -c --arg sha "$sha" '.tags[$sha] // null' "$FIXTURE"
  else
    gh api "repos/$REPOSITORY/git/tags/$sha" | jq -c '.object'
  fi
}

object=$(load_ref)
[ "$object" != null ] || fail "release tag ref is absent"
depth=0
while :; do
  type=$(jq -r '.type // empty' <<<"$object")
  sha=$(jq -r '.sha // empty' <<<"$object")
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "release tag object SHA is malformed"
  case "$type" in
    commit)
      [ "$sha" = "$SOURCE_SHA" ] ||
        fail "release tag does not peel to the release source"
      echo "tag_ref=verified"
      exit 0
      ;;
    tag)
      depth=$((depth + 1))
      [ "$depth" -le 16 ] || fail "annotated tag chain exceeds the verification bound"
      object=$(load_tag_object "$sha")
      [ "$object" != null ] || fail "annotated tag object is absent"
      ;;
    *) fail "release tag object type is unsupported" ;;
  esac
done
