#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM
cp "$ROOT_DIR/docs/evidence/MEE2-48-protected-history-v1.json" \
  "$TMP/snapshot.json"
"$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
  --snapshot "$TMP/snapshot.json"
if jq '.objects.blockedV1_1_0.release.draft = false' \
  "$TMP/snapshot.json" >"$TMP/drift.json" &&
  "$ROOT_DIR/scripts/verify-protected-release-snapshot.sh" \
    --snapshot "$TMP/drift.json"; then
  echo "protected snapshot drift was incorrectly accepted" >&2
  exit 1
fi

drift_filters=(
  '.objects.blockedV1_1_0.release.immutable = true'
  '.objects.blockedV1_1_0.release.bodySha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.assets[0].label = "drift"'
  '.objects.blockedV1_1_0.assets[0].apiDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.gitRef.state = "present"'
  '.objects.blockedV1_1_0.registry.protectedAliasBindings.latest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.registry.subjectDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
  '.objects.blockedV1_1_0.registry.versions = [{id:1,digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",tags:["v1.1.0"]}]'
  '.objects.blockedV1_1_0.registry.referrers = [{digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",mediaType:"application/json",size:1,subjectDigest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",artifactType:null,predicateTypes:[],rawManifestSha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
  '.objects.blockedV1_1_0.githubAttestations = [{predicateType:"fixture",bundleDigest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
)
for filter in "${drift_filters[@]}"; do
  jq "$filter" "$TMP/snapshot.json" >"$TMP/drift.json"
  if cmp --silent "$TMP/snapshot.json" "$TMP/drift.json"; then
    echo "protected snapshot drift matrix failed to change bytes: $filter" >&2
    exit 1
  fi
done
echo "protected snapshot fixtures passed"
