#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <immutable-image> <full-40-character-git-sha> <canonical-version>" >&2
  exit 2
fi

IMAGE=$1
REVISION=$2
VERSION=${3:-}
ENV_FILE=.env.production
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "revision must be a lowercase 40-character Git SHA" >&2
  exit 1
}
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "version must be canonical SemVer" >&2
  exit 1
}
case "$IMAGE" in
  ""|*[[:space:]]*|*:latest) echo "image must be immutable, non-blank, and must not use latest" >&2; exit 1 ;;
  *@sha256:*)
    DIGEST="${IMAGE##*@sha256:}"
    [[ "$DIGEST" =~ ^[0-9a-f]{64}$ ]] || { echo "image digest must be 64 lowercase hex characters" >&2; exit 1; }
    ;;
  *)
    [[ "$IMAGE" == *"$REVISION"* ]] || { echo "tagged image must include the full source revision" >&2; exit 1; }
    ;;
esac

test -f "$ENV_FILE" || {
  echo "$ENV_FILE is missing; upgrades must never recreate it" >&2
  exit 1
}
[ "$(grep -c '^BACKEND_IMAGE=' "$ENV_FILE")" -eq 1 ]
[ "$(grep -c '^BACKEND_VERSION=' "$ENV_FILE")" -eq 1 ]
[ "$(grep -c '^BACKEND_REVISION=' "$ENV_FILE")" -eq 1 ]

CONFIG_BEFORE=$(scripts/production-config-digest.sh "$ENV_FILE")
TMP=$(mktemp ./.env.production.release.XXXXXX)
trap 'rm -f "$TMP"' EXIT
awk -v image="$IMAGE" -v version="$VERSION" -v revision="$REVISION" '
  /^BACKEND_IMAGE=/ { print "BACKEND_IMAGE=" image; image_set=1; next }
  /^BACKEND_VERSION=/ {
    print "BACKEND_VERSION=" version; version_set=1
    next
  }
  /^BACKEND_REVISION=/ { print "BACKEND_REVISION=" revision; revision_set=1; next }
  { print }
  END {
    if (!image_set || !version_set || !revision_set) exit 1
  }
' "$ENV_FILE" > "$TMP"
chmod 600 "$TMP"
[ "$(scripts/production-config-digest.sh "$TMP")" = "$CONFIG_BEFORE" ]
mv "$TMP" "$ENV_FILE"
trap - EXIT

echo "updated only BACKEND_IMAGE, BACKEND_VERSION, and BACKEND_REVISION"
