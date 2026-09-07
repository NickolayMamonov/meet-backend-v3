#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-test-promotion-layout.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

LAYOUT=$TMP/layout
mkdir -p "$LAYOUT/blobs/sha256"
jq -n '{imageLayoutVersion:"1.0.0"}' >"$LAYOUT/oci-layout"

PLATFORM=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REFERRER=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
jq -n --arg platform "sha256:$PLATFORM" --arg referrer "sha256:$REFERRER" '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[
      {
        digest:$platform,size:1,
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        platform:{os:"linux",architecture:"amd64"}
      },
      {
        digest:$referrer,size:1,
        mediaType:"application/vnd.oci.image.manifest.v1+json",
        platform:{os:"unknown",architecture:"unknown"},
        annotations:{
          "vnd.docker.reference.type":"attestation-manifest",
          "vnd.docker.reference.digest":$platform
        }
      }
    ]
  }
' >"$TMP/root.json"
jq -n '{}' >"$LAYOUT/blobs/sha256/$PLATFORM"
jq -n '{}' >"$LAYOUT/blobs/sha256/$REFERRER"
ROOT_DIGEST=$(sha256sum "$TMP/root.json" | awk '{print $1}')
cp -- "$TMP/root.json" "$LAYOUT/blobs/sha256/${ROOT_DIGEST#sha256:}"
jq -n --arg digest "sha256:$ROOT_DIGEST" '
  {
    schemaVersion:2,
    manifests:[{
      digest:$digest,size:1,
      mediaType:"application/vnd.oci.image.index.v1+json"
    }]
  }
' >"$LAYOUT/index.json"
jq -n '
  {
    schema:"meet-backend/test-promotion-protected-state/v2",
    protected:{subjectDigests:[
      "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    ]}
  }
' >"$TMP/protected.json"
bash "$VERIFY" --layout "$LAYOUT" --protected-state "$TMP/protected.json" \
  --output "$TMP/proof.json"
jq -e '.protectedSubjectsExcluded == true and .rootDigest == ("sha256:" + $root)' \
  --arg root "$ROOT_DIGEST" "$TMP/proof.json" >/dev/null

jq -n --arg root "sha256:$ROOT_DIGEST" '
  {
    schema:"meet-backend/test-promotion-protected-state/v2",
    protected:{subjectDigests:[$root]}
  }
' >"$TMP/collision.json"
if bash "$VERIFY" --layout "$LAYOUT" --protected-state "$TMP/collision.json" \
  --output "$TMP/rejected.json" >"$TMP/rejected.stdout" 2>"$TMP/rejected.stderr"; then
  exit 1
fi
[ ! -e "$TMP/rejected.json" ] && [ ! -s "$TMP/rejected.stdout" ] &&
  [ -s "$TMP/rejected.stderr" ]
echo "test promotion OCI layout fixtures passed"
