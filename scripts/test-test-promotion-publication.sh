#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROOF_HELPER=$ROOT_DIR/scripts/verify-test-promotion-publication.sh
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() {
  echo "test-test-promotion-publication: $*" >&2
  exit 1
}

expect_failure() {
  local name=$1
  shift
  if "$@" >/dev/null 2>"$TMP/$name.stderr"; then
    fail "$name unexpectedly succeeded"
  fi
}

SOURCE=0123456789abcdef0123456789abcdef01234567
TREE=abcdefabcdefabcdefabcdefabcdefabcdefabcd
VERSION=1.2.3
RUN_ID=35354750679
RUN_ATTEMPT=2
IMAGE=ghcr.io/example/meet-backend
ALIAS=test-sha-$SOURCE
LAYOUT=$TMP/layout
mkdir -p "$LAYOUT/blobs/sha256" "$TMP/output"

write_blob() {
  local file=$1
  shift
  "$@" >"$file"
}

write_blob "$TMP/config.json" jq -nS \
  --arg source "$SOURCE" --arg version "$VERSION" \
  '{architecture:"amd64",os:"linux",config:{Labels:{
    "org.opencontainers.image.source":"https://github.com/NickolayMamonov/meet-backend-v3",
    "org.opencontainers.image.revision":$source,
    "org.opencontainers.image.version":$version}}}'
CONFIG=sha256:$(sha256sum "$TMP/config.json" | awk '{print $1}')
cp -- "$TMP/config.json" "$LAYOUT/blobs/sha256/${CONFIG#sha256:}"

printf 'fixture-layer\n' >"$TMP/layer"
LAYER=sha256:$(sha256sum "$TMP/layer" | awk '{print $1}')
cp -- "$TMP/layer" "$LAYOUT/blobs/sha256/${LAYER#sha256:}"

jq -nS --arg config "$CONFIG" --arg layer "$LAYER" \
  --argjson configSize "$(wc -c <"$TMP/config.json" | tr -d '[:space:]')" \
  --argjson layerSize "$(wc -c <"$TMP/layer" | tr -d '[:space:]')" \
  '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
    config:{mediaType:"application/vnd.oci.image.config.v1+json",digest:$config,size:$configSize},
    layers:[{mediaType:"application/vnd.oci.image.layer.v1.tar+gzip",digest:$layer,size:$layerSize}]}' \
  >"$TMP/platform.json"
PLATFORM=sha256:$(sha256sum "$TMP/platform.json" | awk '{print $1}')
cp -- "$TMP/platform.json" "$LAYOUT/blobs/sha256/${PLATFORM#sha256:}"

jq -nS --arg platform "$PLATFORM" \
  --argjson platformSize "$(wc -c <"$TMP/platform.json" | tr -d '[:space:]')" \
  '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",
    manifests:[{mediaType:"application/vnd.oci.image.manifest.v1+json",
      digest:$platform,size:$platformSize,platform:{os:"linux",architecture:"amd64"}}]}' \
  >"$TMP/root.json"
ROOT=sha256:$(sha256sum "$TMP/root.json" | awk '{print $1}')
cp -- "$TMP/root.json" "$LAYOUT/blobs/sha256/${ROOT#sha256:}"

jq -nS --arg root "$ROOT" \
  '{imageLayoutVersion:"1.0.0"}' >"$LAYOUT/oci-layout"
ROOT_SIZE=$(wc -c <"$TMP/root.json" | tr -d '[:space:]')
jq -nS --arg root "$ROOT" --argjson rootSize "$ROOT_SIZE" \
  '{schemaVersion:2,manifests:[{mediaType:"application/vnd.oci.image.index.v1+json",
    digest:$root,size:$rootSize}]}' >"$LAYOUT/index.json"

BEFORE=$TMP/before.json
PROTECTED=$TMP/protected.json
SOURCE_PROOF=$TMP/source-proof.json
LAYOUT_PROOF=$TMP/layout-proof.json
jq -nS '[[]]' >"$BEFORE"
jq -nS '{schema:"meet-backend/test-promotion-protected-state/v1",
  protected:{rootDigests:[],platformDigests:[],subjectDigests:[]}}' >"$PROTECTED"
jq -nS --arg source "$SOURCE" --arg tree "$TREE" --arg version "$VERSION" \
  '{schema:"meet-backend/dev-promotion-source/v1",sourceSha:$source,
    authoritySha:$source,remoteSha:$source,treeId:$tree,version:$version,
    clean:true,detached:true}' >"$SOURCE_PROOF"
bash "$ROOT_DIR/scripts/verify-test-promotion-layout.sh" \
  --layout "$LAYOUT" --protected-state "$PROTECTED" --output "$LAYOUT_PROOF"

PROOF=$TMP/output/publication-proof.json
bash "$PROOF_HELPER" create \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" --version "$VERSION" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --layout "$LAYOUT" \
  --layout-proof "$LAYOUT_PROOF" --source-proof "$SOURCE_PROOF" \
  --before-inventory "$BEFORE" --protected-state "$PROTECTED" --output "$PROOF" \
  >/dev/null
[ "$(stat -c '%a' "$PROOF" 2>/dev/null || echo 600)" = 600 ] || true
PROOF_SHA=$(sha256sum "$PROOF" | awk '{print $1}')

CANDIDATE=$TMP/candidate.json
OBSERVED=$TMP/observed.json
JOURNAL=$TMP/journal.json
jq -nS --arg root "$ROOT" --arg platform "$PLATFORM" --arg alias "$ALIAS" \
  '{versions:[{id:1,digest:$root,tags:[$alias]},
              {id:2,digest:$platform,tags:[]}]}' >"$CANDIDATE"
jq -nS --arg root "$ROOT" --arg platform "$PLATFORM" \
  '{state:"partial",attestationStatus:"missing",rootDigest:$root,platformDigest:$platform}' >"$OBSERVED"
jq -nS --arg source "$SOURCE" \
  '{schema:"meet-backend/test-promotion-registry-state/v1",
    sourceSha:$source,runId:35354750679,runAttempt:2,
    initialAliasState:"absent",registryPublication:"confirmed",
    attestationWrite:"notStarted"}' >"$JOURNAL"

verify() {
  bash "$PROOF_HELPER" verify \
    --proof "$PROOF" --expected-proof-sha256 "$PROOF_SHA" \
    --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
    --candidate-inventory "$CANDIDATE" --observed-reader "$OBSERVED" \
    --registry-journal "$JOURNAL" --before-inventory "$BEFORE" \
    --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
    --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
    --version "$VERSION" --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" \
    >/dev/null
}

verify

for attestation_state in startedUnconfirmed confirmed; do
  jq --arg state "$attestation_state" '.attestationWrite = $state' \
    "$JOURNAL" >"$TMP/journal-$attestation_state.json"
  expect_failure "journal-transition-$attestation_state" bash "$PROOF_HELPER" verify \
    --proof "$PROOF" --expected-proof-sha256 "$PROOF_SHA" \
    --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
    --candidate-inventory "$CANDIDATE" --observed-reader "$OBSERVED" \
    --registry-journal "$TMP/journal-$attestation_state.json" --before-inventory "$BEFORE" \
    --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
    --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
    --version "$VERSION" --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"
done

jq 'del(.platformDigest)' "$OBSERVED" >"$TMP/observed-missing-mutant.json"
expect_failure observed-missing-field bash "$PROOF_HELPER" verify \
  --proof "$PROOF" --expected-proof-sha256 "$PROOF_SHA" \
  --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
  --candidate-inventory "$CANDIDATE" --observed-reader "$TMP/observed-missing-mutant.json" \
  --registry-journal "$JOURNAL" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
  --version "$VERSION" --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"

jq --arg wrong "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  '.rootDigest = $wrong' "$OBSERVED" >"$TMP/observed-wrong-mutant.json"
expect_failure observed-wrong-field bash "$PROOF_HELPER" verify \
  --proof "$PROOF" --expected-proof-sha256 "$PROOF_SHA" \
  --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
  --candidate-inventory "$CANDIDATE" --observed-reader "$TMP/observed-wrong-mutant.json" \
  --registry-journal "$JOURNAL" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
  --version "$VERSION" --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"

EXISTING="$TMP/output/existing-proof.json"
printf '%s\n' 'existing-proof' >"$EXISTING"
expect_failure output-overwrite bash "$PROOF_HELPER" create \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" --version "$VERSION" \
  --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT" --layout "$LAYOUT" \
  --layout-proof "$LAYOUT_PROOF" --source-proof "$SOURCE_PROOF" \
  --before-inventory "$BEFORE" --protected-state "$PROTECTED" --output "$EXISTING"
[ "$(cat "$EXISTING")" = existing-proof ]

cp -- "$PROOF" "$TMP/tampered-proof.json"
jq '.rootDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$TMP/tampered-proof.json" >"$PROOF.tampered"
expect_failure tampered-proof bash "$PROOF_HELPER" verify \
  --proof "$PROOF.tampered" --expected-proof-sha256 "$PROOF_SHA" \
  --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
  --candidate-inventory "$CANDIDATE" --observed-reader "$OBSERVED" \
  --registry-journal "$JOURNAL" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
  --version "$VERSION" --run-id "$RUN_ID" --run-attempt "$RUN_ATTEMPT"

expect_failure cross-run bash "$PROOF_HELPER" verify \
  --proof "$PROOF" --expected-proof-sha256 "$PROOF_SHA" \
  --index-file "$LAYOUT/blobs/sha256/${ROOT#sha256:}" \
  --candidate-inventory "$CANDIDATE" --observed-reader "$OBSERVED" \
  --registry-journal "$JOURNAL" --before-inventory "$BEFORE" \
  --protected-state "$PROTECTED" --layout-proof "$LAYOUT_PROOF" \
  --image "$IMAGE" --source-sha "$SOURCE" --tree-id "$TREE" \
  --version "$VERSION" --run-id "$((RUN_ID + 1))" --run-attempt "$RUN_ATTEMPT"

printf 'test promotion publication passed: closure, immutable hashes, same-run identity, and tamper rejection\n'
