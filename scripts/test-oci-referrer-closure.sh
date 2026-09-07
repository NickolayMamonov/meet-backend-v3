#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERIFY=$ROOT_DIR/scripts/verify-oci-referrer-closure.sh
INVENTORY_VERIFY=$ROOT_DIR/scripts/verify-ghcr-package-inventory.sh
TMP=$(mktemp -d)

IMAGE=ghcr.io/example/meet-backend
ROOT=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PLATFORM=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REFERRER=sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
SIGNATURE_INDEX=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
SIGNATURE=sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
FOREIGN=sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
UNBOUND=sha256:1111111111111111111111111111111111111111111111111111111111111111
UNLISTED=sha256:2222222222222222222222222222222222222222222222222222222222222222
SOURCE=d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc
FIXTURE=$TMP/oci
mkdir "$FIXTURE"
command -v sha256sum >/dev/null 2>&1 || {
  echo "sha256sum is required" >&2
  exit 1
}
digest_of() {
  printf 'sha256:%s\n' "$(sha256sum "$1" | awk '{print $1}')"
}
size_of() {
  wc -c <"$1" | tr -d ' '
}

jq -n \
  --arg platform "$PLATFORM" \
  --arg referrer "$REFERRER" '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.index.v1+json",
    manifests: [
      {
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        digest: $platform,
        size: 100,
        platform: {os:"linux", architecture:"amd64"}
      },
      {
        mediaType: "application/vnd.oci.image.manifest.v1+json",
        digest: $referrer,
        size: 200,
        platform: {os:"unknown", architecture:"unknown"},
        annotations: {
          "vnd.docker.reference.type": "attestation-manifest",
          "vnd.docker.reference.digest": $platform
        }
      }
    ]
  }
' >"$TMP/index.json"

jq -n \
  --arg root "$ROOT" \
  --arg source "$SOURCE" \
  --arg platform "$PLATFORM" \
  --arg referrer "$REFERRER" \
  --arg signature_index "$SIGNATURE_INDEX" \
  --arg signature "$SIGNATURE" '
  {
    digest: $root,
    aliases: {
      "v1.0.1": $root,
      "1.0.1": $root,
      ("sha-" + $source): $root
    },
    latest: null,
    versions: [
      {digest:$root,tags:["v1.0.1","1.0.1",("sha-" + $source)]},
      {digest:$platform,tags:[]},
      {digest:$referrer,tags:[]},
      {digest:$signature_index,tags:[("sha256-" + ($root | sub("^sha256:";"")))]},
      {digest:$signature,tags:[]}
    ]
  }
' >"$TMP/inventory.json"

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
' >"$FIXTURE/${PLATFORM#sha256:}.json"

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
' >"$FIXTURE/${REFERRER#sha256:}.json"

jq -n --arg signature "$SIGNATURE" '
  {
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.index.v1+json",
    manifests: [{
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      digest: $signature,
      size: 300
    }]
  }
' >"$FIXTURE/${SIGNATURE_INDEX#sha256:}.json"

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
' >"$FIXTURE/${SIGNATURE#sha256:}.json"

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

BUNDLE_FIXTURE=$TMP/bundle-oci
mkdir "$BUNDLE_FIXTURE"
BUNDLE_PLATFORM_RAW=$BUNDLE_FIXTURE/platform.raw
jq -n '
  {
    schemaVersion:2,
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    config:{mediaType:"application/vnd.oci.image.config.v1+json",
      digest:"sha256:1212121212121212121212121212121212121212121212121212121212121212",
      size:1},
    layers:[{mediaType:"application/vnd.oci.image.layer.v1.tar+gzip",
      digest:"sha256:1313131313131313131313131313131313131313131313131313131313131313",
      size:1}]
  }
' >"$BUNDLE_PLATFORM_RAW"
BUNDLE_PLATFORM=$(digest_of "$BUNDLE_PLATFORM_RAW")
BUNDLE_PLATFORM_SIZE=$(size_of "$BUNDLE_PLATFORM_RAW")
cp "$BUNDLE_PLATFORM_RAW" "$BUNDLE_FIXTURE/${BUNDLE_PLATFORM#sha256:}.json"

BUNDLE_BYTES=$BUNDLE_FIXTURE/bundle.raw
jq -nS '{mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",
  dsseEnvelope:{payload:"bundle-fixture"}}' >"$BUNDLE_BYTES"
BUNDLE_LAYER=$(digest_of "$BUNDLE_BYTES")
BUNDLE_LAYER_SIZE=$(size_of "$BUNDLE_BYTES")
cp "$BUNDLE_BYTES" "$BUNDLE_FIXTURE/${BUNDLE_LAYER#sha256:}.bundle"

BUNDLE_PROVENANCE_RAW=$BUNDLE_FIXTURE/provenance.raw
jq -n --arg platform "$BUNDLE_PLATFORM" --argjson size "$BUNDLE_PLATFORM_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
   artifactType:"application/vnd.in-toto+json",
   subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",
     digest:$platform,size:$size},
   config:{mediaType:"application/vnd.oci.empty.v1+json",
     digest:"sha256:1414141414141414141414141414141414141414141414141414141414141414",
     size:1},
   layers:[{mediaType:"application/vnd.in-toto+json",
     digest:"sha256:1515151515151515151515151515151515151515151515151515151515151515",
     size:1,annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}}]}
' >"$BUNDLE_PROVENANCE_RAW"
BUNDLE_PROVENANCE=$(digest_of "$BUNDLE_PROVENANCE_RAW")
BUNDLE_PROVENANCE_SIZE=$(size_of "$BUNDLE_PROVENANCE_RAW")
cp "$BUNDLE_PROVENANCE_RAW" "$BUNDLE_FIXTURE/${BUNDLE_PROVENANCE#sha256:}.json"

BUNDLE_SBOM_RAW=$BUNDLE_FIXTURE/sbom.raw
jq -n --arg platform "$BUNDLE_PLATFORM" --argjson size "$BUNDLE_PLATFORM_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
   artifactType:"application/spdx+json",
   subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",
     digest:$platform,size:$size},
   config:{mediaType:"application/vnd.oci.empty.v1+json",
     digest:"sha256:1616161616161616161616161616161616161616161616161616161616161616",
     size:1},
   layers:[{mediaType:"application/spdx+json",
     digest:"sha256:1717171717171717171717171717171717171717171717171717171717171717",
     size:1,annotations:{"in-toto.io/predicate-type":"https://spdx.dev/Document"}}]}
' >"$BUNDLE_SBOM_RAW"
BUNDLE_SBOM=$(digest_of "$BUNDLE_SBOM_RAW")
BUNDLE_SBOM_SIZE=$(size_of "$BUNDLE_SBOM_RAW")
cp "$BUNDLE_SBOM_RAW" "$BUNDLE_FIXTURE/${BUNDLE_SBOM#sha256:}.json"

BUNDLE_SIGNATURE_RAW=$BUNDLE_FIXTURE/signature.raw
jq -n --arg platform "$BUNDLE_PLATFORM" --argjson size "$BUNDLE_PLATFORM_SIZE" \
  --arg layer "$BUNDLE_LAYER" --argjson layerSize "$BUNDLE_LAYER_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
   artifactType:"application/vnd.dev.sigstore.bundle.v0.3+json",
   subject:{mediaType:"application/vnd.oci.image.manifest.v1+json",
     digest:$platform,size:$size},
   config:{mediaType:"application/vnd.oci.empty.v1+json",
     digest:"sha256:1818181818181818181818181818181818181818181818181818181818181818",
     size:1},
   layers:[{mediaType:"application/vnd.dev.sigstore.bundle.v0.3+json",
     digest:$layer,size:$layerSize}]}
' >"$BUNDLE_SIGNATURE_RAW"
BUNDLE_SIGNATURE=$(digest_of "$BUNDLE_SIGNATURE_RAW")
BUNDLE_SIGNATURE_SIZE=$(size_of "$BUNDLE_SIGNATURE_RAW")
cp "$BUNDLE_SIGNATURE_RAW" "$BUNDLE_FIXTURE/${BUNDLE_SIGNATURE#sha256:}.json"

BUNDLE_INDEX_RAW=$BUNDLE_FIXTURE/signature-index.raw
jq -n --arg signature "$BUNDLE_SIGNATURE" --argjson size "$BUNDLE_SIGNATURE_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
   manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",
     digest:$signature,size:$size}]}
' >"$BUNDLE_INDEX_RAW"
BUNDLE_INDEX=$(digest_of "$BUNDLE_INDEX_RAW")
BUNDLE_INDEX_SIZE=$(size_of "$BUNDLE_INDEX_RAW")
cp "$BUNDLE_INDEX_RAW" "$BUNDLE_FIXTURE/${BUNDLE_INDEX#sha256:}.json"

BUNDLE_ROOT_RAW=$BUNDLE_FIXTURE/root.json
jq -n --arg platform "$BUNDLE_PLATFORM" --argjson platformSize "$BUNDLE_PLATFORM_SIZE" \
  --arg provenance "$BUNDLE_PROVENANCE" --argjson provenanceSize "$BUNDLE_PROVENANCE_SIZE" \
  --arg sbom "$BUNDLE_SBOM" --argjson sbomSize "$BUNDLE_SBOM_SIZE" \
  --arg signatureIndex "$BUNDLE_INDEX" --argjson signatureIndexSize "$BUNDLE_INDEX_SIZE" '
  {schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
   manifests:[
     {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$platform,
      size:$platformSize,platform:{os:"linux",architecture:"amd64"}},
     {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$provenance,
      size:$provenanceSize,platform:{os:"unknown",architecture:"unknown"},
      annotations:{"vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform}},
     {mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$sbom,
      size:$sbomSize,platform:{os:"unknown",architecture:"unknown"},
      annotations:{"vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform}},
     {mediaType:"application/vnd.oci.image.index.v1+json",digest:$signatureIndex,
      size:$signatureIndexSize,annotations:{"vnd.docker.reference.type":"attestation-manifest",
        "vnd.docker.reference.digest":$platform}}
   ]}
' >"$BUNDLE_ROOT_RAW"
BUNDLE_ROOT=$(digest_of "$BUNDLE_ROOT_RAW")
cp "$BUNDLE_ROOT_RAW" "$BUNDLE_FIXTURE/${BUNDLE_ROOT#sha256:}.json"
BUNDLE_INVENTORY=$TMP/bundle-inventory.json
jq -n --arg root "$BUNDLE_ROOT" --arg platform "$BUNDLE_PLATFORM" \
  --arg provenance "$BUNDLE_PROVENANCE" --arg sbom "$BUNDLE_SBOM" \
  --arg signatureIndex "$BUNDLE_INDEX" --arg signature "$BUNDLE_SIGNATURE" '
  {digest:$root,versions:[
    {digest:$root,tags:["sha256-"+($root|sub("^sha256:";""))]},
    {digest:$platform,tags:[]},{digest:$provenance,tags:[]},
    {digest:$sbom,tags:[]},{digest:$signatureIndex,tags:[]},
    {digest:$signature,tags:[]}
  ]}
' >"$BUNDLE_INVENTORY"
BUNDLE_OUTPUT=$TMP/bundle-output.json
BUNDLE_CLOSURE=$TMP/bundle-closure.json
"$VERIFY" --image "$IMAGE" --index-file "$BUNDLE_ROOT_RAW" \
  --inventory-file "$BUNDLE_INVENTORY" --subject-digest "$BUNDLE_ROOT" \
  --platform-subject "$BUNDLE_PLATFORM" --fixture-dir "$BUNDLE_FIXTURE" \
  --require-bundle --bundle-output "$BUNDLE_OUTPUT" --output "$BUNDLE_CLOSURE"
cmp --silent "$BUNDLE_BYTES" "$BUNDLE_OUTPUT" ||
  { echo "bundle bytes were not extracted byte-identically" >&2; exit 1; }
jq -e --arg root "$BUNDLE_ROOT" --arg platform "$BUNDLE_PLATFORM" \
  --arg signature "$BUNDLE_SIGNATURE" --arg layer "$BUNDLE_LAYER" \
  --argjson size "$BUNDLE_LAYER_SIZE" '
  (.bundle.signatureManifestDigest == $signature) and
  (.bundle.bundleLayerDigest == $layer) and
  (.bundle.bundleLayerSize == $size) and
  (.bundle.bundleLayerMediaType ==
    "application/vnd.dev.sigstore.bundle.v0.3+json") and
  (.bundle.bundleDigest == $layer) and
  (.versions | any(.digest == $root)) and
  (.versions | any(.digest == $platform))
' "$BUNDLE_CLOSURE" >/dev/null || {
  echo "bundle closure metadata is incomplete" >&2
  exit 1
}

expect_bundle_failure() {
  local name=$1 index_file=$2 inventory_file=$3 fixture_dir=$4
  local sentinel_bundle=$TMP/$name.bundle.sentinel expected_bundle=$TMP/$name.bundle.expected
  local sentinel_closure=$TMP/$name.closure.sentinel expected_closure=$TMP/$name.closure.expected case_tmp=$TMP/$name-tmpdir
  printf 'bundle sentinel\n' >"$sentinel_bundle"
  printf 'closure sentinel\n' >"$sentinel_closure"
  cp -- "$sentinel_bundle" "$expected_bundle"
  cp -- "$sentinel_closure" "$expected_closure"
  mkdir "$case_tmp"
  if TMPDIR="$case_tmp" "$VERIFY" --image "$IMAGE" --index-file "$index_file" \
      --inventory-file "$inventory_file" --subject-digest "$BUNDLE_ROOT" \
      --platform-subject "$BUNDLE_PLATFORM" --fixture-dir "$fixture_dir" \
      --require-bundle --bundle-output "$sentinel_bundle" \
      --output "$sentinel_closure" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    echo "expected bundle rejection: $name" >&2
    exit 1
  fi
  cmp --silent "$sentinel_bundle" "$expected_bundle" ||
    { echo "bundle sentinel changed: $name" >&2; exit 1; }
  cmp --silent "$sentinel_closure" "$expected_closure" ||
    { echo "closure sentinel changed: $name" >&2; exit 1; }
  [ -z "$(find "$case_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    { echo "temporary work directory was not cleaned: $name" >&2; exit 1; }
  [ -z "$(find "$TMP" -maxdepth 1 -name "$name.bundle.sentinel.tmp.*" -print -quit)" ] ||
    { echo "bundle staging file was not cleaned: $name" >&2; exit 1; }
  [ -z "$(find "$TMP" -maxdepth 1 -name "$name.closure.sentinel.tmp.*" -print -quit)" ] ||
    { echo "closure staging file was not cleaned: $name" >&2; exit 1; }
  rmdir "$case_tmp"
}

make_bundle_variant() {
  local name=$1 signature_filter=$2 layer_digest=${3:-$BUNDLE_LAYER}
  local layer_size=${4:-$BUNDLE_LAYER_SIZE} layer_file=${5:-$BUNDLE_BYTES}
  local variant_signature_raw variant_signature variant_signature_size
  local variant_index_raw variant_index variant_index_size
  VARIANT_FIXTURE=$TMP/$name-fixture
  mkdir "$VARIANT_FIXTURE"
  cp -R -- "$BUNDLE_FIXTURE/." "$VARIANT_FIXTURE/"
  cp -- "$layer_file" "$VARIANT_FIXTURE/${layer_digest#sha256:}.bundle"

  variant_signature_raw=$VARIANT_FIXTURE/signature.raw
  jq --arg layer "$layer_digest" --argjson layerSize "$layer_size" \
    "$signature_filter" "$BUNDLE_SIGNATURE_RAW" >"$variant_signature_raw"
  variant_signature=$(digest_of "$variant_signature_raw")
  variant_signature_size=$(size_of "$variant_signature_raw")
  cp -- "$variant_signature_raw" \
    "$VARIANT_FIXTURE/${variant_signature#sha256:}.json"

  variant_index_raw=$VARIANT_FIXTURE/signature-index.raw
  jq --arg signature "$variant_signature" \
    --argjson signatureSize "$variant_signature_size" \
    '.manifests[0].digest = $signature |
     .manifests[0].size = $signatureSize' \
    "$BUNDLE_INDEX_RAW" >"$variant_index_raw"
  variant_index=$(digest_of "$variant_index_raw")
  variant_index_size=$(size_of "$variant_index_raw")
  cp -- "$variant_index_raw" "$VARIANT_FIXTURE/${variant_index#sha256:}.json"

  VARIANT_ROOT=$TMP/$name-root.json
  jq --arg oldIndex "$BUNDLE_INDEX" --arg newIndex "$variant_index" \
    --argjson newIndexSize "$variant_index_size" \
    '.manifests |= map(
      if .digest == $oldIndex then
        .digest = $newIndex | .size = $newIndexSize
      else . end
    )' "$BUNDLE_ROOT_RAW" >"$VARIANT_ROOT"
  VARIANT_INVENTORY=$TMP/$name-inventory.json
  jq --arg oldIndex "$BUNDLE_INDEX" --arg newIndex "$variant_index" \
    --arg oldSignature "$BUNDLE_SIGNATURE" \
    --arg newSignature "$variant_signature" \
    '.versions |= map(
      if .digest == $oldIndex then .digest = $newIndex
      elif .digest == $oldSignature then .digest = $newSignature
      else . end
    )' "$BUNDLE_INVENTORY" >"$VARIANT_INVENTORY"
}

jq 'del(.manifests[-1])' "$BUNDLE_ROOT_RAW" >"$TMP/zero-manifest-index.json"
ZERO_MANIFEST_INVENTORY=$TMP/zero-manifest-inventory.json
jq --arg signatureIndex "$BUNDLE_INDEX" --arg signature "$BUNDLE_SIGNATURE" \
  '.versions |= map(
    select(.digest != $signatureIndex and .digest != $signature)
  )' "$BUNDLE_INVENTORY" >"$ZERO_MANIFEST_INVENTORY"
expect_bundle_failure zero-manifest "$TMP/zero-manifest-index.json" \
  "$ZERO_MANIFEST_INVENTORY" "$BUNDLE_FIXTURE"
jq '.manifests += [.manifests[1]]' "$BUNDLE_ROOT_RAW" \
  >"$TMP/duplicate-manifest-index.json"
expect_bundle_failure duplicate-manifest "$TMP/duplicate-manifest-index.json" \
  "$BUNDLE_INVENTORY" "$BUNDLE_FIXTURE"
jq '.manifests[1].mediaType = "application/vnd.oci.image.index.v1+json"' \
  "$BUNDLE_ROOT_RAW" >"$TMP/wrong-media-index.json"
expect_bundle_failure wrong-media "$TMP/wrong-media-index.json" \
  "$BUNDLE_INVENTORY" "$BUNDLE_FIXTURE"
jq '.manifests[3].size += 1' "$BUNDLE_ROOT_RAW" >"$TMP/descriptor-size-index.json"
expect_bundle_failure descriptor-size "$TMP/descriptor-size-index.json" \
  "$BUNDLE_INVENTORY" "$BUNDLE_FIXTURE"
jq --arg foreign "$FOREIGN" '.versions += [{digest:$foreign,tags:[]}]' \
  "$BUNDLE_INVENTORY" >"$TMP/foreign-inventory.json"
expect_bundle_failure foreign-storage "$BUNDLE_ROOT_RAW" \
  "$TMP/foreign-inventory.json" "$BUNDLE_FIXTURE"
MULTI_SIGNATURE_RAW=$TMP/multiple-signature.raw
jq --arg platform "$BUNDLE_PLATFORM" --argjson platformSize "$BUNDLE_PLATFORM_SIZE" \
  --arg layer "$BUNDLE_LAYER" --argjson layerSize "$BUNDLE_LAYER_SIZE" \
  '.config.digest = "sha256:1919191919191919191919191919191919191919191919191919191919191919" |
   .subject.digest = $platform | .subject.size = $platformSize |
   .layers[0].digest = $layer | .layers[0].size = $layerSize' \
  "$BUNDLE_SIGNATURE_RAW" >"$MULTI_SIGNATURE_RAW"
MULTI_SIGNATURE=$(digest_of "$MULTI_SIGNATURE_RAW")
MULTI_SIGNATURE_SIZE=$(size_of "$MULTI_SIGNATURE_RAW")
MULTI_FIXTURE=$TMP/multiple-signature-fixture
mkdir "$MULTI_FIXTURE"
cp -R -- "$BUNDLE_FIXTURE/." "$MULTI_FIXTURE/"
cp -- "$MULTI_SIGNATURE_RAW" "$MULTI_FIXTURE/${MULTI_SIGNATURE#sha256:}.json"
jq --arg signature "$MULTI_SIGNATURE" --arg platform "$BUNDLE_PLATFORM" \
  --argjson signatureSize "$MULTI_SIGNATURE_SIZE" \
  '.manifests += [{
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    digest:$signature,size:$signatureSize,
    platform:{os:"unknown",architecture:"unknown"},
    annotations:{"vnd.docker.reference.type":"attestation-manifest",
      "vnd.docker.reference.digest":$platform}
  }]' "$BUNDLE_ROOT_RAW" >"$TMP/multiple-signature-index.json"
jq --arg signature "$MULTI_SIGNATURE" \
  '.versions += [{digest:$signature,tags:[]}]' "$BUNDLE_INVENTORY" \
  >"$TMP/multiple-signature-inventory.json"
expect_bundle_failure multiple-signature "$TMP/multiple-signature-index.json" \
  "$TMP/multiple-signature-inventory.json" "$MULTI_FIXTURE"
make_bundle_variant zero-bundle-layer \
  '.layers = [{mediaType:"application/vnd.in-toto+json",
    digest:"sha256:1919191919191919191919191919191919191919191919191919191919191919",
    size:1,annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}}]'
expect_bundle_failure zero-bundle-layer "$VARIANT_ROOT" "$VARIANT_INVENTORY" \
  "$VARIANT_FIXTURE"
make_bundle_variant multiple-bundle-layers '.layers += [.layers[0]]'
expect_bundle_failure multiple-bundle-layers "$VARIANT_ROOT" "$VARIANT_INVENTORY" \
  "$VARIANT_FIXTURE"
MALFORMED_BUNDLE=$TMP/malformed.bundle
printf '{\n' >"$MALFORMED_BUNDLE"
MALFORMED_LAYER=$(digest_of "$MALFORMED_BUNDLE")
MALFORMED_LAYER_SIZE=$(size_of "$MALFORMED_BUNDLE")
make_bundle_variant malformed-bundle \
  '.layers[0].digest = $layer | .layers[0].size = $layerSize' \
  "$MALFORMED_LAYER" "$MALFORMED_LAYER_SIZE" "$MALFORMED_BUNDLE"
expect_bundle_failure malformed-bundle "$VARIANT_ROOT" "$VARIANT_INVENTORY" \
  "$VARIANT_FIXTURE"
cp -r -- "$BUNDLE_FIXTURE" "$TMP/changed-bundle-fixture"
printf '{\n' >"$TMP/changed-bundle-fixture/${BUNDLE_LAYER#sha256:}.bundle"
expect_bundle_failure changed-bundle "$BUNDLE_ROOT_RAW" \
  "$BUNDLE_INVENTORY" "$TMP/changed-bundle-fixture"
mkdir "$TMP/unsafe-bundle-output"
if "$VERIFY" --image "$IMAGE" --index-file "$BUNDLE_ROOT_RAW" \
    --inventory-file "$BUNDLE_INVENTORY" --subject-digest "$BUNDLE_ROOT" \
    --platform-subject "$BUNDLE_PLATFORM" --fixture-dir "$BUNDLE_FIXTURE" \
    --require-bundle --bundle-output "$TMP/unsafe-bundle-output" \
    --output "$TMP/unsafe-closure-output" >/dev/null 2>&1; then
  echo "expected unsafe bundle output rejection" >&2
  exit 1
fi

rm -r -- "$TMP"
echo "OCI referrer closure fixtures passed: legacy graph, one byte-identical bundle, cardinality, media, descriptor, digest, foreign, unsafe, and sentinel matrices"
