#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <canonical-version> <full-40-character-git-sha>" >&2
  exit 2
fi

VERSION=$1
REVISION=$2
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
  echo "invalid canonical version" >&2
  exit 2
}
[[ "$REVISION" =~ ^[0-9a-f]{40}$ ]] || {
  echo "invalid source revision" >&2
  exit 2
}
test "$(git rev-parse HEAD)" = "$REVISION" || {
  echo "lease source revision does not match checkout" >&2
  exit 1
}

# Git ref creation is the admission lease for cooperating publication runs.
# The push is intentionally non-forced: exactly one writer can create this
# ref, and the ref is retained as an audit/quarantine marker.
LEASE_TAG="release-lease-v${VERSION}-${REVISION}"
LEASE_REF="refs/tags/$LEASE_TAG"
if git ls-remote --exit-code origin "$LEASE_REF" >/dev/null 2>&1; then
  echo "publication lease already exists; refusing a second registry writer" >&2
  exit 75
fi

if git push --no-verify origin "$REVISION:$LEASE_REF" >/dev/null 2>&1; then
  printf 'publication_lease=%s\n' "$LEASE_TAG"
  exit 0
fi

echo "publication lease was claimed by another writer; refusing registry publication" >&2
exit 75
