#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CAPTURE=$ROOT_DIR/scripts/capture-test-promotion-protected-state.sh
COLLECTOR=$ROOT_DIR/scripts/collect-test-promotion-protected-state.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/valid.json
HISTORICAL_FIXTURE=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/historical-authority.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() {
  echo "test-promotion protected-state fixture failed: $*" >&2
  exit 1
}

run_capture() {
  bash "$CAPTURE" --input "$1" --output "$2" \
    --candidate-alias test-sha-1111111111111111111111111111111111111111
}

expect_failure() {
  local name=$1
  shift
  if "$@" >"$TMP/$name.stdout" 2>"$TMP/$name.stderr"; then
    fail "expected rejection was accepted: $name"
  fi
  [ ! -s "$TMP/$name.stdout" ] || fail "rejection emitted stdout: $name"
  [ -s "$TMP/$name.stderr" ] || fail "rejection omitted stderr: $name"
  ! grep -Fq 'fixture-secret-must-not-appear' "$TMP/$name.stderr" ||
    fail "rejection printed a secret: $name"
}

[ -r "$CAPTURE" ] && [ -r "$COLLECTOR" ] || fail "policy scripts are unavailable"
[ -f "$FIXTURE" ] && [ -f "$HISTORICAL_FIXTURE" ] ||
  fail "policy fixtures are unavailable"
bash -n "$CAPTURE"
bash -n "$COLLECTOR"
command -v jq >/dev/null 2>&1 || fail "jq is required"

# The immutable legacy fixture predates the floor. Normalize only its live
# protected flags; all historical release and registry bytes remain available
# to exercise exclusion and collision behavior.
jq '
  .releases |= map(
    if .tag_name == "v1.0.1" then .protected = false
    elif .tag_name == "v1.2.0" then .protected = true
    else . end
  ) |
  .registry.versions |= map(select(.id != 2003 and .id != 2004)) |
  .registry.subjects |= map(select(.releaseId != 367640510)) |
  .registry.manifests |= map(select(
    .digest != "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" and
    .digest != "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  )) |
  .registry.attestations |= map(select(
    .subjectDigest !=
      "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  ))
' "$FIXTURE" >"$TMP/floor-valid.json"

run_capture "$TMP/floor-valid.json" "$TMP/canonical.json"
run_capture "$TMP/floor-valid.json" "$TMP/repeat.json"
cmp --silent "$TMP/canonical.json" "$TMP/repeat.json" ||
  fail "canonical output is not byte deterministic"
[ "$(wc -l <"$TMP/canonical.json" | tr -d ' ')" -eq 1 ] ||
  fail "canonical output is not compact JSON"
jq -e '
  .schema == "meet-backend/test-promotion-protected-state/v1" and
  .publicRelease.id == 371012814 and .publicRelease.tag == "v1.2.0" and
  .protected.releaseIds == [371012814] and
  (any(.releases[]; .id == 367640510 and (.protected | not))) and
  (all(.protected.subjects[]; .releaseId != 367640510)) and
  (all(.protected.aliases[];
    .alias != "v1.0.1" and .alias != "1.0.1" and
    .alias != "sha-2222222222222222222222222222222222222222")) and
  .proof.sha256 ==
    "db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529"
' "$TMP/canonical.json" >/dev/null ||
  fail "v1.2.0 protected floor projection is wrong"

jq '
  .releases |= reverse | .releases[].assets |= reverse |
  .tagRefs |= reverse | .registry.versions |= reverse |
  .registry.versions[].tags |= reverse | .registry.subjects |= reverse |
  .registry.subjects[].aliases |= reverse | .registry.manifests |= reverse |
  .registry.manifests[].children |= reverse | .registry.attestations |= reverse
' "$TMP/floor-valid.json" >"$TMP/reordered.json"
run_capture "$TMP/reordered.json" "$TMP/reordered-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/reordered-output.json" ||
  fail "source ordering changed canonical bytes"

jq '.releases[0].protected = true' "$TMP/floor-valid.json" \
  >"$TMP/pre-floor-protected.json"
expect_failure pre-floor-protected \
  run_capture "$TMP/pre-floor-protected.json" "$TMP/rejected.json"

jq '.registry.versions |= map(if .id == 2005
  then .tags = ["v1.0.1"] else . end)' "$TMP/floor-valid.json" \
  >"$TMP/retired-candidate-alias.json"
expect_failure retired-candidate-alias \
  run_capture "$TMP/retired-candidate-alias.json" "$TMP/rejected.json"

jq '.registry.versions |= map(if .id == 2001
  then .tags += ["sha-2222222222222222222222222222222222222222"]
  else . end)' "$TMP/floor-valid.json" >"$TMP/retired-supported-alias.json"
expect_failure retired-supported-alias \
  run_capture "$TMP/retired-supported-alias.json" "$TMP/rejected.json"

jq '.registry.manifests |= map(if
  .digest == "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  then .children += [
    "sha256:6f8c8a92a39bdfbf47c1f95ff7ba01b55f5f767126dd77751ea67bae17b0f29a"
  ] else . end) |
  .registry.manifests += [{
    digest:"sha256:6f8c8a92a39bdfbf47c1f95ff7ba01b55f5f767126dd77751ea67bae17b0f29a",
    mediaType:"application/vnd.oci.image.manifest.v1+json",size:812,
    subjectDigest:
      "sha256:c156a8a1436b008eea2980711b233b6f800cf60a36cdbe08faf480a2c97e6570",
    artifactType:"application/vnd.dev.sigstore.bundle.v0.3+json",
    predicateTypes:["https://slsa.dev/provenance/v1"],children:[]
  }]
' "$TMP/floor-valid.json" >"$TMP/retired-closure-injection.json"
expect_failure retired-closure-injection \
  run_capture "$TMP/retired-closure-injection.json" "$TMP/rejected.json"

jq '.registry.versions |= map(if .id == 2005
  then .tags = ["v1.2.0"] else . end)' "$TMP/floor-valid.json" \
  >"$TMP/supported-collision.json"
run_capture "$TMP/supported-collision.json" "$TMP/collision-output.json"
jq -e 'any(.protected.subjectDigests[];
  . == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' \
  "$TMP/collision-output.json" >/dev/null ||
  fail "supported alias collision was not represented"

cp "$TMP/canonical.json" "$TMP/stable-output.json"
jq '.proof.sha256 = "fixture-secret-must-not-appear"' \
  "$TMP/floor-valid.json" >"$TMP/secret.json"
if run_capture "$TMP/secret.json" "$TMP/canonical.json" \
    >"$TMP/retry.stdout" 2>"$TMP/retry.stderr"; then
  fail "rejected input overwrote an existing output"
fi
cmp --silent "$TMP/stable-output.json" "$TMP/canonical.json" ||
  fail "rejected input changed an existing output"
! find "$TMP" -maxdepth 1 -name 'canonical.json.tmp.*' -print -quit |
  grep -q . || fail "rejected input left a temporary output"

! grep -Eq '(^|[[:space:]])(gh|docker|curl|git|wget|ssh)([[:space:]]|$)' \
  "$CAPTURE" || fail "capture contains a network or registry command"
mkdir "$TMP/forbidden-bin"
for forbidden in gh docker curl git wget ssh; do
  cp "$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/forbidden-command.sh" \
    "$TMP/forbidden-bin/$forbidden"
done
PATH="$TMP/forbidden-bin:$PATH" \
  run_capture "$TMP/floor-valid.json" "$TMP/shim-output.json"
cmp --silent "$TMP/stable-output.json" "$TMP/shim-output.json" ||
  fail "explicit command shims changed projection"

# shellcheck source=collect-test-promotion-protected-state.sh
source "$COLLECTOR"

for unsupported in 0.0.0 1.0.1 1.1.0 1.1.99; do
  if backend_version_at_least_floor "$unsupported"; then
    fail "pre-floor version passed: $unsupported"
  fi
done
for supported in 1.2.0 1.2.1 1.10.0 2.0.0; do
  backend_version_at_least_floor "$supported" ||
    fail "supported version failed: $supported"
done
for malformed in 1.2 v1.2.0 01.2.0 1.2.0-extra; do
  if backend_version_at_least_floor "$malformed"; then
    fail "malformed version passed: $malformed"
  fi
done

supported_rows=$(supported_authority_rows)
jq -e '
  type == "array" and length == 2 and
  (map(.id) | sort) == [371012814,377201468] and
  all(.[]; .storage == "github-api-workflow-artifact")
' <<<"$supported_rows" >/dev/null ||
  fail "supported authority rows are not the exact v1.2.0/v1.3.0 API rows"

retired_rows=$(retired_product_rows)
jq -e '
  type == "array" and length == 2 and
  ([.[].closure[]] | length) == 10 and
  any(.[].closure[];
    .id == 1123240857 and
    .digest ==
      "sha256:6f8c8a92a39bdfbf47c1f95ff7ba01b55f5f767126dd77751ea67bae17b0f29a" and
    .tags == [])
' <<<"$retired_rows" >/dev/null ||
  fail "retired full closure is incomplete"

[ "$(sha256sum "$HISTORICAL_FIXTURE" | awk '{print $1}')" = \
  021d5c4a7c20f276f26c1f7ecdf42537bd0b0c39d0588691c5aba01e5be70bd4 ] ||
  fail "historical fixture bytes changed"
jq -e '.records | length == 4' "$HISTORICAL_FIXTURE" >/dev/null ||
  fail "historical fixture no longer contains all four immutable records"

active_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
package_inventory=$(jq -cnS --argjson retired "$retired_rows" \
  --arg active "$active_digest" '
  [{id:9999999999,digest:$active,tags:["candidate"]}] +
  ([ $retired[] .closure[] ] | to_entries | map(
    .value as $item |
    {
      id:($item.id // (8000000000 + .key)),
      digest:$item.digest,
      tags:$item.tags
    }
  ))
')
filtered=$(filter_active_package_versions "$package_inventory") ||
  fail "complete retired inventory was not quarantined"
jq -e --arg digest "$active_digest" \
  '. == [{id:9999999999,digest:$digest,tags:["candidate"]}]' \
  <<<"$filtered" >/dev/null ||
  fail "retired inventory leaked into the active table"

retired_sigstore=$(jq -r '.[1].closure[] | select(.kind == "sigstore") |
  .digest' <<<"$retired_rows")
collision=$(jq -cS --arg digest "$retired_sigstore" '
  . + [{id:7000000000,digest:
    "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    tags:["v1.1.0"]}]
' <<<"$package_inventory")
if filter_active_package_versions "$collision" >/dev/null 2>&1; then
  fail "retired alias collision passed package filtering"
fi
wrong_sigstore=$(jq -cS --arg digest "$retired_sigstore" '
  map(if .digest == $digest then
    .digest =
      "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  else . end)
' <<<"$package_inventory")
if filter_active_package_versions "$wrong_sigstore" >/dev/null 2>&1; then
  fail "retired package ID accepted a foreign digest"
fi

jq -cS '
  .records |
  map(select(.release.id == 371012814 or .release.id == 377201468)) |
  .[] |
  {
    expectedId:.release.id,
    context:{
      repository:"NickolayMamonov/meet-backend-v3",
      image:"ghcr.io/nickolaymamonov/meet-backend-v3",
      release:{
        id:.release.id,tag:.release.tag,version:.release.version,
        source:.release.source,draft:.release.draft,
        prerelease:.release.prerelease,immutable:.release.immutable
      },
      package:.image.package,
      rootDigest:.image.rootDigest,
      platform:.image.platform
    }
  }
' "$HISTORICAL_FIXTURE" >"$TMP/supported-contexts.jsonl"
while IFS= read -r entry; do
  expected=$(jq -r '.expectedId' <<<"$entry")
  context=$(jq -c '.context' <<<"$entry")
  selection=$(select_supported_authority "$context") ||
    fail "supported authority context rejected: $expected"
  jq -e --argjson expected "$expected" '
    .status == "supported-authority" and .row.id == $expected
  ' <<<"$selection" >/dev/null ||
    fail "wrong supported authority selected: $expected"
  mutated=$(jq -c '.package.tags += ["v1.1.0"]' <<<"$context")
  if select_supported_authority "$mutated" >/dev/null 2>&1; then
    fail "supported authority accepted a retired/cross-row alias: $expected"
  fi
done <"$TMP/supported-contexts.jsonl"

! grep -Fq -- '--bundle-from-oci' "$COLLECTOR" ||
  fail "active collector still contains the retired OCI verification transport"
filter_line=$(grep -n 'filter_active_package_versions.*versions.json' \
  "$COLLECTOR" | head -n 1 | cut -d: -f1)
traversal_line=$(grep -n 'while IFS=.*version_id digest tags_json' \
  "$COLLECTOR" | head -n 1 | cut -d: -f1)
retired_child_line=$(grep -n '! is_retired_digest.*child_digest' \
  "$COLLECTOR" | head -n 1 | cut -d: -f1)
child_read_line=$(grep -n 'read_raw_manifest.*child_digest' \
  "$COLLECTOR" | head -n 1 | cut -d: -f1)
[ "$filter_line" -lt "$traversal_line" ] &&
  [ "$retired_child_line" -lt "$child_read_line" ] ||
  fail "retired inventory is not quarantined before manifest traversal"

synthetic_subject=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
synthetic_invocation=https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/99999999999/attempts/1
synthetic_bundle=$(jq -cnS '{fixture:"supported-authority"}')
synthetic_compact=$(jq -cS <<<"$synthetic_bundle")
synthetic_compact=${synthetic_compact%$'\r'}
synthetic_hash=$(printf '%s\n' "$synthetic_compact" | sha256sum | awk '{print $1}')
synthetic_row=$(jq -cS --arg invocation "$synthetic_invocation" \
  --arg bundle "sha256:$synthetic_hash" \
  '.[0] | .invocation = $invocation | .bundle = $bundle' \
  <<<"$supported_rows")
synthetic_selection=$(jq -cnS --argjson row "$synthetic_row" \
  '{status:"supported-authority",row:$row}')
synthetic_signer=$(jq -r '.signer' <<<"$synthetic_row")
synthetic_response=$(jq -cnS --argjson bundle "$synthetic_bundle" \
  --arg subject "${synthetic_subject#sha256:}" \
  --arg signer "$synthetic_signer" --arg invocation "$synthetic_invocation" '
  [{
    attestation:{bundle:$bundle},
    verificationResult:{
      statement:{
        predicateType:"https://slsa.dev/provenance/v1",
        subject:[{name:"image-index.json",digest:{sha256:$subject}}]
      },
      signature:{certificate:{
        sourceRepositoryURI:
          "https://github.com/NickolayMamonov/meet-backend-v3",
        sourceRepositoryDigest:$signer,
        sourceRepositoryRef:"refs/heads/dev",
        buildSignerURI:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev",
        buildSignerDigest:$signer,
        subjectAlternativeName:
          "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev",
        issuer:"https://token.actions.githubusercontent.com",
        runInvocationURI:$invocation
      }}
    }
  }]
')
validate_supported_attestation "$synthetic_response" "$synthetic_selection" \
  "$synthetic_subject" >/dev/null ||
  fail "valid supported attestation was rejected"

attestation_reject() {
  local name=$1 filter=$2 mutated
  mutated=$(jq -cS "$filter" <<<"$synthetic_response")
  if validate_supported_attestation "$mutated" "$synthetic_selection" \
      "$synthetic_subject" >"$TMP/attestation-$name.stdout" 2>/dev/null; then
    fail "supported attestation mutation passed: $name"
  fi
  [ ! -s "$TMP/attestation-$name.stdout" ] ||
    fail "rejected supported attestation emitted output: $name"
}
attestation_reject repository \
  '.[0].verificationResult.signature.certificate.sourceRepositoryURI =
    "https://evil.invalid/repository"'
attestation_reject source \
  '.[0].verificationResult.signature.certificate.sourceRepositoryDigest =
    "0000000000000000000000000000000000000000"'
attestation_reject ref \
  '.[0].verificationResult.signature.certificate.sourceRepositoryRef =
    "refs/heads/main"'
attestation_reject workflow \
  '.[0].verificationResult.signature.certificate.buildSignerURI =
    "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/other.yml@refs/heads/dev"'
attestation_reject signer \
  '.[0].verificationResult.signature.certificate.buildSignerDigest =
    "0000000000000000000000000000000000000000"'
attestation_reject identity \
  '.[0].verificationResult.signature.certificate.subjectAlternativeName =
    "https://example.invalid/identity"'
attestation_reject issuer \
  '.[0].verificationResult.signature.certificate.issuer =
    "https://example.invalid/issuer"'
attestation_reject invocation \
  '.[0].verificationResult.signature.certificate.runInvocationURI =
    "https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/1/attempts/1"'
attestation_reject predicate \
  '.[0].verificationResult.statement.predicateType =
    "https://example.invalid/predicate"'
attestation_reject subject-name \
  '.[0].verificationResult.statement.subject[0].name = "foreign-image"'
attestation_reject subject-digest \
  '.[0].verificationResult.statement.subject[0].digest.sha256 =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
attestation_reject bundle '.[0].attestation.bundle = {fixture:"changed"}'
attestation_reject duplicate-result '. += .'
attestation_reject duplicate-subject \
  '.[0].verificationResult.statement.subject +=
    [.[0].verificationResult.statement.subject[0]]'

modern_manifest="$TMP/modern.json"
jq -cnS '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.manifest.v1+json",
  artifactType:"application/vnd.docker.attestation.manifest.v1+json",
  subject:{
    mediaType:"application/vnd.oci.image.manifest.v1+json",
    digest:"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    size:1815
  },
  layers:[
    {
      mediaType:"application/vnd.in-toto+json",
      digest:"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      size:1,
      annotations:{"in-toto.io/predicate-type":"https://slsa.dev/provenance/v1"}
    },
    {
      mediaType:"application/vnd.in-toto+json",
      digest:"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      size:1,
      annotations:{"in-toto.io/predicate-type":"https://spdx.dev/Document"}
    }
  ]
}' >"$modern_manifest"
modern_subject=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
modern_selection='{"status":"supported-authority"}'
predicates=$(normalize_modern_attestation_predicates \
  "$modern_manifest" "$modern_subject" "$modern_selection") ||
  fail "valid modern attestation was rejected"
jq -e '. == [
  "https://slsa.dev/provenance/v1",
  "https://spdx.dev/Document"
]' <<<"$predicates" >/dev/null ||
  fail "modern predicates were not exact"

modern_reject() {
  local name=$1 filter=$2
  jq "$filter" "$modern_manifest" >"$TMP/modern-$name.json"
  if normalize_modern_attestation_predicates "$TMP/modern-$name.json" \
      "$modern_subject" "$modern_selection" >/dev/null 2>&1; then
    fail "modern attestation mutation passed: $name"
  fi
}
modern_reject missing-subject 'del(.subject)'
modern_reject wrong-artifact '.artifactType = "application/vnd.in-toto+json"'
modern_reject duplicate-predicate \
  '.layers[1].annotations["in-toto.io/predicate-type"] =
    "https://slsa.dev/provenance/v1"'
modern_reject missing-slsa '.layers |= map(select(
  .annotations["in-toto.io/predicate-type"] !=
    "https://slsa.dev/provenance/v1"))'
modern_reject wrong-subject \
  '.subject.digest =
    "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"'

echo "test-promotion protected-state fixtures passed: v1.2.0 floor, retired closure quarantine, supported authority, modern attestations, projector purity, and no writers"
