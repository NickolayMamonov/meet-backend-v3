#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-oci-referrer-closure.sh
INVENTORY_VERIFY=$ROOT_DIR/scripts/verify-ghcr-package-inventory.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

IMAGE=ghcr.io/example/meet-backend
ROOT=
PLATFORM=
REFERRER=
SIGNATURE_INDEX=
SIGNATURE=
FOREIGN=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
UNBOUND=sha256:1111111111111111111111111111111111111111111111111111111111111111
UNLISTED=sha256:2222222222222222222222222222222222222222222222222222222222222222
SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
FIXTURE=$TMP/oci
mkdir "$FIXTURE"

jq -n '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {
      mediaType: "application/vnd.oci.image.config.v1+json",
      digest: "sha256:1212121212121212121212121212121212121212121212121212121212121212",
      size: 1
    },
    layers: [{
      mediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
      digest: "sha256:1313131313131313131313131313131313131313131313131313131313131313",
      size: 1
    }]
  }
' >"$FIXTURE/platform-placeholder.json"
PLATFORM=sha256:$(sha256sum "$FIXTURE/platform-placeholder.json" | awk '{print $1}')
mv "$FIXTURE/platform-placeholder.json" "$FIXTURE/${PLATFORM#sha256:}.json"

jq -n '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {
      mediaType: "application/vnd.oci.empty.v1+json",
      digest: "sha256:1414141414141414141414141414141414141414141414141414141414141414",
      size: 2
    },
    layers: [
      {
        mediaType: "application/vnd.in-toto+json",
        digest: "sha256:1515151515151515151515151515151515151515151515151515151515151515",
        size: 10,
        annotations: {"in-toto.io/predicate-type":"https://spdx.dev/Document"}
      },
      {
        mediaType: "application/vnd.in-toto+json",
        digest: "sha256:1616161616161616161616161616161616161616161616161616161616161616",
        size: 10,
        annotations: {"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}
      }
    ]
  }
' >"$FIXTURE/referrer-placeholder.json"
REFERRER=sha256:$(sha256sum "$FIXTURE/referrer-placeholder.json" | awk '{print $1}')
mv "$FIXTURE/referrer-placeholder.json" "$FIXTURE/${REFERRER#sha256:}.json"

jq -n --arg platform "$PLATFORM" --arg referrer "$REFERRER" \
  --argjson platformSize "$(wc -c <"$FIXTURE/${PLATFORM#sha256:}.json" | tr -d '[:space:]')" \
  --argjson referrerSize "$(wc -c <"$FIXTURE/${REFERRER#sha256:}.json" | tr -d '[:space:]')" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
   manifests:[
     {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,
      size:$platformSize,platform:{os:"linux",architecture:"amd64"}},
     {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$referrer,
      size:$referrerSize,platform:{os:"unknown",architecture:"unknown"},
      annotations:{"vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform}}
   ]}
' >"$TMP/index.json"
ROOT=sha256:$(sha256sum "$TMP/index.json" | awk '{print $1}')

jq -n --arg root "$ROOT" '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    artifactType: "application/vnd.dev.sigstore.bundle.v0.3+json",
    config: {
      mediaType: "application/vnd.oci.empty.v1+json",
      digest: "sha256:1717171717171717171717171717171717171717171717171717171717171717",
      size: 2
    },
    layers: [{
      mediaType: "application/vnd.dev.sigstore.bundle.v0.3+json",
      digest: "sha256:1818181818181818181818181818181818181818181818181818181818181818",
      size: 10
    }],
    subject: {
      mediaType: "application/vnd.oci.image.index.v1+json",
      digest: $root,
      size: 400
    }
  }
' >"$FIXTURE/signature-placeholder.json"
SIGNATURE=sha256:$(sha256sum "$FIXTURE/signature-placeholder.json" | awk '{print $1}')
mv "$FIXTURE/signature-placeholder.json" "$FIXTURE/${SIGNATURE#sha256:}.json"

jq -n --arg signature "$SIGNATURE" \
  --argjson signatureSize "$(wc -c <"$FIXTURE/${SIGNATURE#sha256:}.json" | tr -d '[:space:]')" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
   manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",
     digest:$signature,size:$signatureSize}]}
' >"$FIXTURE/signature-index-placeholder.json"
SIGNATURE_INDEX=sha256:$(sha256sum "$FIXTURE/signature-index-placeholder.json" | awk '{print $1}')
mv "$FIXTURE/signature-index-placeholder.json" "$FIXTURE/${SIGNATURE_INDEX#sha256:}.json"

jq -n --arg root "$ROOT" '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    config: {
      mediaType: "application/vnd.oci.empty.v1+json",
      digest: "sha256:1919191919191919191919191919191919191919191919191919191919191919",
      size: 2
    },
    layers: [{
      mediaType: "application/vnd.in-toto+json",
      digest: "sha256:2020202020202020202020202020202020202020202020202020202020202020",
      size: 10,
      annotations: {"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}
    }],
    subject: {
      mediaType: "application/vnd.oci.image.index.v1+json",
      digest: $root,
      size: 400
    }
  }
' >"$FIXTURE/${UNLISTED#sha256:}.json"

jq -n \
  --arg root "$ROOT" --arg source "$SOURCE" --arg platform "$PLATFORM" \
  --arg referrer "$REFERRER" --arg signature_index "$SIGNATURE_INDEX" \
  --arg signature "$SIGNATURE" '
  {
    digest:$root,
    aliases:{"v1.0.1":$root,"1.0.1":$root,("sha-" + $source):$root},
    latest:null,
    versions:[
      {digest:$root,tags:["v1.0.1","1.0.1",("sha-" + $source)]},
      {digest:$platform,tags:[]},
      {digest:$referrer,tags:[]},
      {digest:$signature_index,tags:[("sha256-" + ($root|sub("^sha256:";"")))]},
      {digest:$signature,tags:[]}
    ]
  }
' >"$TMP/inventory.json"

run_valid() {
  local inventory=$1 output=$2
  "$VERIFY" \
    --image "$IMAGE" \
    --index-file "$TMP/index.json" \
    --inventory-file "$inventory" \
    --subject-digest "$ROOT" \
    --platform-subject "$PLATFORM" \
    --fixture-dir "$FIXTURE" \
    --output "$output"
}

run_valid "$TMP/inventory.json" "$TMP/attributed.json"
"$INVENTORY_VERIFY" \
  --inventory-file "$TMP/attributed.json" \
  --digest "$ROOT" \
  --platform-subject "$PLATFORM" \
  --tag v1.0.1 \
  --version 1.0.1 \
  --source-sha "$SOURCE" >/dev/null

NO_SIGNATURE_INDEX=$TMP/no-signature-index.json
jq --arg signature_index "$SIGNATURE_INDEX" '
  .manifests |= map(select(.digest != $signature_index))
' "$TMP/index.json" >"$NO_SIGNATURE_INDEX"
NO_SIGNATURE_ROOT=sha256:$(sha256sum "$NO_SIGNATURE_INDEX" | awk '{print $1}')
NO_SIGNATURE_INVENTORY=$TMP/no-signature-inventory.json
jq --arg old_root "$ROOT" --arg new_root "$NO_SIGNATURE_ROOT" \
  --arg signature_index "$SIGNATURE_INDEX" --arg signature "$SIGNATURE" '
  .versions |= map(
    select(.digest != $signature_index and .digest != $signature) |
    if .digest == $old_root then .digest = $new_root else . end
  )
' "$TMP/inventory.json" >"$NO_SIGNATURE_INVENTORY"
if "$VERIFY" \
    --image "$IMAGE" \
    --index-file "$NO_SIGNATURE_INDEX" \
    --inventory-file "$NO_SIGNATURE_INVENTORY" \
    --subject-digest "$NO_SIGNATURE_ROOT" \
    --platform-subject "$PLATFORM" \
    --fixture-dir "$FIXTURE" \
    --require-signature true \
    >"$TMP/no-signature.out" 2>&1; then
  echo "expected OCI closure rejection: missing subject-bound signature" >&2
  exit 1
fi

expect_failure() {
  local name=$1
  shift
  jq "$@" "$TMP/inventory.json" >"$TMP/$name.json"
  if run_valid "$TMP/$name.json" "$TMP/$name-attributed.json" \
      >"$TMP/$name.out" 2>&1; then
    echo "expected OCI closure rejection: $name" >&2
    exit 1
  fi
}

expect_failure foreign-version \
  --arg digest "$FOREIGN" \
  '.versions += [{digest:$digest,tags:[]}]'
expect_failure unbound-version \
  --arg digest "$UNBOUND" \
  '.versions += [{digest:$digest,tags:[]}]'
cp "$FIXTURE/${REFERRER#sha256:}.json" "$FIXTURE/${UNBOUND#sha256:}.json"
expect_failure unbound-version-shape \
  --arg digest "$UNBOUND" \
  '.versions += [{digest:$digest,tags:[]}]'
rm "$FIXTURE/${UNBOUND#sha256:}.json"
expect_failure unlisted-direct-subject \
  --arg digest "$UNLISTED" \
  '.versions += [{digest:$digest,tags:[]}]'

jq --arg referrer "$REFERRER" '
  .manifests |= map(
    if .digest == $referrer then
      .annotations["vnd.docker.reference.digest"] =
        "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    else . end
  )
' "$TMP/index.json" >"$TMP/wrong-subject-index.json"
if "$VERIFY" --image "$IMAGE" --index-file "$TMP/wrong-subject-index.json" \
    --inventory-file "$TMP/inventory.json" --subject-digest "$ROOT" \
    --platform-subject "$PLATFORM" --fixture-dir "$FIXTURE" \
    >"$TMP/wrong-subject.out" 2>&1; then
  echo "expected OCI closure rejection: wrong-subject" >&2
  exit 1
fi

jq --arg signature "$SIGNATURE" '
  .manifests[0].digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
' "$FIXTURE/${SIGNATURE_INDEX#sha256:}.json" >"$FIXTURE/${SIGNATURE_INDEX#sha256:}.bad.json"
mv "$FIXTURE/${SIGNATURE_INDEX#sha256:}.bad.json" \
  "$FIXTURE/${SIGNATURE_INDEX#sha256:}.json"
if run_valid "$TMP/inventory.json" "$TMP/bad-child.json" \
    >"$TMP/bad-child.out" 2>&1; then
  echo "expected OCI closure rejection: bad-child" >&2
  exit 1
fi

echo "OCI referrer closure fixtures passed: valid graph and seven rejects"
