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

fixture_dir=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state

# The reducer is exercised through the same sourceable helpers used by the
# collector.  Raw bytes provide complete facts; contextual descriptors provide
# only positive/partial constraints.
raw_manifest="$TMP/raw-manifest.json"
raw_digest_file="$TMP/raw-manifest.digest"
raw_subject=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
raw_child=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -cnS --arg subject "$raw_subject" --arg child "$raw_child" '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.manifest.v1+json",
  subject:{digest:$subject},
  artifactType:"application/vnd.example.artifact",
  layers:[{annotations:{"in-toto.io/predicate-type":"predicate/example"}}],
  manifests:[{digest:$child}]
}' >"$raw_manifest"
raw_digest="sha256:$(sha256sum "$raw_manifest" | awk '{print $1}')"
raw_size=$(wc -c <"$raw_manifest" | tr -d ' ')
printf '%s\n' "$raw_digest" >"$raw_digest_file"
raw_observation=$(manifest_observation_from_raw \
  "$raw_manifest" "$raw_digest" \
  application/vnd.oci.image.manifest.v1+json "$raw_size") ||
  fail "raw observation construction failed"
context_observation=$(manifest_observation_from_descriptor "$(jq -cnS \
  --arg digest "$raw_digest" --arg subject "$raw_subject" --arg child "$raw_child" \
  --argjson size "$raw_size" '{
    digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json",
    size:$size,subjectDigest:$subject,artifactType:"application/vnd.example.artifact",
    predicateTypes:["predicate/example"],children:[$child]
  }')") || fail "context observation construction failed"

printf '%s\n%s\n%s\n%s\n' \
  "$context_observation" "$raw_observation" "$raw_observation" \
  "$context_observation" >"$TMP/observations-forward.jsonl"
printf '%s\n%s\n%s\n%s\n' \
  "$raw_observation" "$context_observation" "$context_observation" \
  "$raw_observation" >"$TMP/observations-reversed.jsonl"
canonicalize_manifest_observations "$TMP/observations-forward.jsonl" \
  >"$TMP/observations-forward.json" ||
  fail "forward observation reconciliation failed"
canonicalize_manifest_observations "$TMP/observations-reversed.jsonl" \
  >"$TMP/observations-reversed.json" ||
  fail "reversed observation reconciliation failed"
cmp --silent "$TMP/observations-forward.json" "$TMP/observations-reversed.json" ||
  fail "equivalent observations changed canonical bytes"
jq -e --arg digest "$raw_digest" --arg subject "$raw_subject" \
  --arg child "$raw_child" --arg raw_size "$raw_size" '
  length == 1 and .[0] == {
    digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json",
    size:($raw_size | tonumber),subjectDigest:$subject,artifactType:"application/vnd.example.artifact",
    predicateTypes:["predicate/example"],children:[$child]
  }
' "$TMP/observations-forward.json" >/dev/null ||
  fail "canonical descriptor did not retain complete raw facts"

expect_reducer_failure() {
  local name=$1 field=$2 rows=$3
  printf '%s\n' "$rows" >"$TMP/$name.jsonl"
  canonicalize_manifest_observations "$TMP/$name.jsonl" \
    >"$TMP/$name.stdout" 2>"$TMP/$name.stderr" &&
    fail "reducer accepted conflict: $name"
  [ ! -s "$TMP/$name.stdout" ] ||
    fail "reducer emitted stdout on rejection: $name"
  grep -Fq "manifest observation conflict: $raw_digest $field" \
    "$TMP/$name.stderr" ||
    fail "reducer omitted named conflict class: $name"
}

base_complete=$(jq -cnS --arg digest "$raw_digest" --argjson size "$raw_size" '{
  digest:$digest,mediaType:"application/vnd.oci.image.manifest.v1+json",size:$size,
  facts:{
    subjectDigest:{state:"complete",value:null},
    artifactType:{state:"complete",value:null},
    predicateTypes:{state:"complete",values:[]},
    children:{state:"complete",values:[]}
  }
}')
expect_reducer_failure mediaType mediaType \
  "$(printf '%s\n' "$base_complete" "$(jq '.mediaType = "application/vnd.oci.image.index.v1+json"' <<<"$base_complete")")"
expect_reducer_failure size size \
  "$(printf '%s\n' "$base_complete" "$(jq '.size += 1' <<<"$base_complete")")"
expect_reducer_failure verified-absence subjectDigest \
  "$(printf '%s\n' "$base_complete" "$(jq --arg subject "$raw_subject" \
    '.facts.subjectDigest = {state:"positive",value:$subject}' \
    <<<"$base_complete")")"
expect_reducer_failure scalar-fact artifactType \
  "$(printf '%s\n' \
    "$(jq '.facts.artifactType = {state:"complete",value:"type/a"}' \
      <<<"$base_complete")" \
    "$(jq '.facts.artifactType = {state:"positive",value:"type/b"}' \
      <<<"$base_complete")")"
expect_reducer_failure unequal-complete-set predicateTypes \
  "$(printf '%s\n' \
    "$(jq '.facts.predicateTypes.values = ["predicate/a"]' <<<"$base_complete")" \
    "$(jq '.facts.predicateTypes.values = ["predicate/b"]' <<<"$base_complete")")"
expect_reducer_failure partial-outside children \
  "$(printf '%s\n' \
    "$(jq '.facts.children.values = ["sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"]' \
      <<<"$base_complete")" \
    "$(jq '.facts.children = {state:"partial",values:["sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"]}' \
      <<<"$base_complete")")"

unresolved=$(jq '.facts.subjectDigest = {state:"unknown"}' <<<"$base_complete")
printf '%s\n' "$unresolved" >"$TMP/unresolved.jsonl"
canonicalize_manifest_observations "$TMP/unresolved.jsonl" \
  >"$TMP/unresolved.stdout" 2>"$TMP/unresolved.stderr" &&
  fail "reducer accepted unresolved facts"
[ ! -s "$TMP/unresolved.stdout" ] ||
  fail "unresolved reducer rejection emitted stdout"
grep -Fq "manifest observation unresolved: $raw_digest subjectDigest" \
  "$TMP/unresolved.stderr" ||
  fail "unresolved reducer rejection omitted its field"

malformed_positive=$(jq '.facts.subjectDigest = {state:"positive"}' <<<"$base_complete")
printf '%s\n' "$malformed_positive" >"$TMP/malformed-positive.jsonl"
canonicalize_manifest_observations "$TMP/malformed-positive.jsonl" \
  >"$TMP/malformed-positive.stdout" 2>"$TMP/malformed-positive.stderr" &&
  fail "malformed positive scalar was accepted"
[ ! -s "$TMP/malformed-positive.stdout" ] ||
  fail "malformed positive scalar emitted stdout"
grep -Fq "manifest observation positive scalar fact is malformed" \
  "$TMP/malformed-positive.stderr" ||
  fail "malformed positive scalar was not rejected at validation"

multi_conflict=$(printf '%s\n%s\n' \
  "$base_complete" \
  "$(jq -cS --arg subject "$raw_subject" \
    '.mediaType = "application/vnd.oci.image.index.v1+json" |
     .facts.subjectDigest = {state:"positive",value:$subject}' \
    <<<"$base_complete")")
printf '%s\n' "$multi_conflict" >"$TMP/multi-conflict.jsonl"
if canonicalize_manifest_observations "$TMP/multi-conflict.jsonl" \
    >"$TMP/multi-forward.stdout" 2>"$TMP/multi-forward.stderr"; then
  fail "multi-conflict reducer accepted forward order"
fi
printf '%s\n' "$(printf '%s\n' "$multi_conflict" | tail -n 1)" \
  "$(printf '%s\n' "$multi_conflict" | head -n 1)" \
  >"$TMP/multi-reversed.jsonl"
if canonicalize_manifest_observations "$TMP/multi-reversed.jsonl" \
    >"$TMP/multi-reversed.stdout" 2>"$TMP/multi-reversed.stderr"; then
  fail "multi-conflict reducer accepted reversed order"
fi
grep -Fq "manifest observation conflict: $raw_digest mediaType" \
  "$TMP/multi-forward.stderr" ||
  fail "multi-conflict forward order selected the wrong field"
grep -Fq "manifest observation conflict: $raw_digest mediaType" \
  "$TMP/multi-reversed.stderr" ||
  fail "multi-conflict reversal changed the selected field"

duplicate_set=$(jq '
  .facts.predicateTypes = {state:"complete",values:["z","a","a"]} |
  .facts.children = {state:"complete",values:["sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                                               "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}
' <<<"$base_complete")
ordered_set=$(jq '
  .facts.predicateTypes = {state:"complete",values:["a","z"]} |
  .facts.children = {state:"complete",values:["sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"]}
' <<<"$base_complete")
printf '%s\n' "$duplicate_set" >"$TMP/duplicate-set.jsonl"
printf '%s\n' "$ordered_set" >"$TMP/ordered-set.jsonl"
canonicalize_manifest_observations "$TMP/duplicate-set.jsonl" \
  >"$TMP/duplicate-set.json" || fail "duplicate sets were rejected"
canonicalize_manifest_observations "$TMP/ordered-set.jsonl" \
  >"$TMP/ordered-set.json" || fail "ordered sets were rejected"
cmp --silent "$TMP/duplicate-set.json" "$TMP/ordered-set.json" ||
  fail "duplicate/order set semantics changed canonical bytes"

# Full collector proof: only the allowlisted read stubs are available, and
# package traversal observes the same artifact as an index child and a package.
collector_fixture="$TMP/collector-fixture"
stub_bin="$TMP/collector-bin"
mkdir "$collector_fixture" "$stub_bin"
platform_raw="$collector_fixture/platform.json"
artifact_raw="$collector_fixture/artifact.json"
root_raw="$collector_fixture/root.json"
jq -cnS '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.manifest.v1+json",
  config:{digest:"sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}
}' >"$platform_raw"
platform_digest="sha256:$(sha256sum "$platform_raw" | awk '{print $1}')"
platform_size=$(wc -c <"$platform_raw" | tr -d ' ')
jq -cnS --arg subject "$platform_digest" '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.manifest.v1+json",
  artifactType:"application/vnd.example.attestation",
  subject:{digest:$subject},
  layers:[{annotations:{"in-toto.io/predicate-type":"predicate/example"}}]
}' >"$artifact_raw"
artifact_digest="sha256:$(sha256sum "$artifact_raw" | awk '{print $1}')"
artifact_size=$(wc -c <"$artifact_raw" | tr -d ' ')
jq -cnS --arg platform "$platform_digest" --arg artifact "$artifact_digest" \
  --argjson platformSize "$platform_size" --argjson artifactSize "$artifact_size" '{
  schemaVersion:2,
  mediaType:"application/vnd.oci.image.index.v1+json",
  manifests:[
    {digest:$platform,mediaType:"application/vnd.oci.image.manifest.v1+json",
     size:$platformSize,platform:{os:"linux",architecture:"amd64"}},
    {digest:$artifact,mediaType:"application/vnd.oci.image.manifest.v1+json",
     size:$artifactSize,annotations:{
       "vnd.docker.reference.type":"attestation-manifest",
       "vnd.docker.reference.digest":$platform
     }}
  ]
}' >"$root_raw"
root_digest="sha256:$(sha256sum "$root_raw" | awk '{print $1}')"
root_size=$(wc -c <"$root_raw" | tr -d ' ')
packages="$collector_fixture/packages.json"
jq -cnS --arg root "$root_digest" --arg artifact "$artifact_digest" '[[
  {id:9001,name:$root,metadata:{container:{tags:["candidate"]}}},
  {id:9002,name:$artifact,metadata:{container:{tags:["candidate"]}}}
]]' >"$packages"
cp "$fixture_dir/collector-gh-read-stub.sh" "$stub_bin/gh"
cp "$fixture_dir/collector-docker-read-stub.sh" "$stub_bin/docker"
chmod +x "$stub_bin/gh" "$stub_bin/docker"
audit="$collector_fixture/audit.log"
writer_marker="$collector_fixture/writer.marker"
collector_output="$collector_fixture/collected.json"
collector_env=(
  "PATH=$stub_bin:$PATH"
  "GH_TOKEN=fixture-token"
  "STUB_AUDIT=$audit"
  "STUB_ROOT_DIGEST=$root_digest"
  "STUB_ROOT_RAW=$root_raw"
  "STUB_PLATFORM_DIGEST=$platform_digest"
  "STUB_PLATFORM_RAW=$platform_raw"
  "STUB_ARTIFACT_DIGEST=$artifact_digest"
  "STUB_ARTIFACT_RAW=$artifact_raw"
  "STUB_WRITER_MARKER=$writer_marker"
)
env "${collector_env[@]}" STUB_PACKAGES="$packages" bash "$COLLECTOR" \
  --repository fixture/repository \
  --image ghcr.io/fixture/repository \
  --output "$collector_output" \
  --candidate-alias candidate \
  >"$collector_fixture/initial.stdout" \
  2>"$collector_fixture/initial.stderr" ||
  { cat "$collector_fixture/initial.stderr" >&2
  fail "strict read-stub collector rejected valid overlap"
  }
jq -e --arg root "$root_digest" --arg platform "$platform_digest" \
  --arg artifact "$artifact_digest" --argjson rootSize "$root_size" \
  --argjson platformSize "$platform_size" --argjson artifactSize "$artifact_size" '
  .registry.manifests == ([
    {digest:$artifact,mediaType:"application/vnd.oci.image.manifest.v1+json",
     size:$artifactSize,subjectDigest:$platform,
     artifactType:"application/vnd.example.attestation",
     predicateTypes:["predicate/example"],children:[]},
    {digest:$platform,mediaType:"application/vnd.oci.image.manifest.v1+json",
     size:$platformSize,subjectDigest:null,artifactType:null,
     predicateTypes:[],children:[]},
    {digest:$root,mediaType:"application/vnd.oci.image.index.v1+json",
     size:$rootSize,subjectDigest:null,artifactType:null,
     predicateTypes:[],children:([$artifact,$platform] | unique | sort)}
  ] | sort_by(.digest))
' "$collector_output" >/dev/null ||
  fail "collector did not publish exact canonical overlap descriptors"
[ "$(grep -c '^gh ' "$audit")" -eq 2 ] ||
  fail "collector read-stub audit omitted the two GitHub reads"
[ "$(grep -c '^docker ' "$audit")" -eq 4 ] ||
  fail "collector read-stub audit did not prove package/index overlap"
[ ! -e "$writer_marker" ] || fail "collector reached a writer marker"
grep -Fq 'releases?per_page=100' "$audit" ||
  fail "collector did not use the expected release inventory read"
grep -Fq 'versions?per_page=100' "$audit" ||
  fail "collector did not use the expected package inventory read"

 jq '.[0] |= reverse' "$packages" >"$collector_fixture/packages-reversed.json"
if ! env "${collector_env[@]}" STUB_PACKAGES="$collector_fixture/packages-reversed.json" \
  bash "$COLLECTOR" \
  --repository fixture/repository \
  --image ghcr.io/fixture/repository \
  --output "$collector_fixture/collected-reversed.json" \
  --candidate-alias candidate \
  >"$collector_fixture/reversed.stdout" \
  2>"$collector_fixture/reversed.stderr"; then
  cat "$collector_fixture/reversed.stderr" >&2
  fail "reversed strict read-stub collector rejected valid overlap"
fi
jq -cS '.registry.manifests' "$collector_output" \
  >"$collector_fixture/collected-manifests.json"
jq -cS '.registry.manifests' "$collector_fixture/collected-reversed.json" \
  >"$collector_fixture/collected-reversed-manifests.json"
cmp --silent "$collector_fixture/collected-manifests.json" \
  "$collector_fixture/collected-reversed-manifests.json" ||
  fail "collector source order changed canonical descriptor bytes"

expect_collector_rejection() {
  local name=$1 expected=$2
  shift 2
  printf 'sentinel-output\n' >"$collector_fixture/$name.output"
  if env "${collector_env[@]}" STUB_PACKAGES="$packages" "$@" bash "$COLLECTOR" \
      --repository fixture/repository \
      --image ghcr.io/fixture/repository \
      --output "$collector_fixture/$name.output" \
      --candidate-alias candidate \
      >"$collector_fixture/$name.stdout" \
      2>"$collector_fixture/$name.stderr"; then
    fail "collector accepted negative case: $name"
  fi
  [ ! -s "$collector_fixture/$name.stdout" ] ||
    fail "collector negative case emitted stdout: $name"
  grep -Fq "$expected" "$collector_fixture/$name.stderr" ||
    fail "collector negative case omitted its terminal reason: $name"
  grep -Fq 'sentinel-output' "$collector_fixture/$name.output" ||
    fail "collector negative case replaced output: $name"
  [ ! -e "$writer_marker" ] ||
    fail "collector negative case reached a writer marker: $name"
}
expect_collector_rejection read-failure 'registry manifest read failed' \
  STUB_FAIL_DIGEST="$artifact_digest"

corrupt_artifact="$collector_fixture/corrupt-artifact.json"
jq '.artifactType = "fixture-corruption"' "$artifact_raw" >"$corrupt_artifact"
expect_collector_rejection raw-hash 'registry manifest bytes do not match' \
  STUB_ARTIFACT_RAW="$corrupt_artifact"

bad_root="$collector_fixture/bad-root.json"
jq --arg artifact "$artifact_digest" \
  '.manifests |= map(if .digest == $artifact then .size += 1 else . end)' \
  "$root_raw" >"$bad_root"
bad_root_digest="sha256:$(sha256sum "$bad_root" | awk '{print $1}')"
jq -cnS --arg root "$bad_root_digest" --arg artifact "$artifact_digest" '[[
  {id:9001,name:$root,metadata:{container:{tags:["candidate"]}}},
  {id:9002,name:$artifact,metadata:{container:{tags:["candidate"]}}}
]]' >"$collector_fixture/packages-bad-root.json"
expect_collector_rejection descriptor-size 'registry descriptor size disagrees' \
  STUB_PACKAGES="$collector_fixture/packages-bad-root.json" \
  STUB_ROOT_DIGEST="$bad_root_digest" STUB_ROOT_RAW="$bad_root"

bad_subject_root="$collector_fixture/bad-subject-root.json"
jq '.manifests |= map(if .annotations? then
  .annotations["vnd.docker.reference.digest"] =
    "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  else . end)' "$root_raw" >"$bad_subject_root"
bad_subject_root_digest="sha256:$(sha256sum "$bad_subject_root" | awk '{print $1}')"
jq -cnS --arg root "$bad_subject_root_digest" --arg artifact "$artifact_digest" '[[
  {id:9001,name:$root,metadata:{container:{tags:["candidate"]}}},
  {id:9002,name:$artifact,metadata:{container:{tags:["candidate"]}}}
]]' >"$collector_fixture/packages-bad-subject.json"
expect_collector_rejection contextual-subject 'attestation subject binding disagrees' \
  STUB_PACKAGES="$collector_fixture/packages-bad-subject.json" \
  STUB_ROOT_DIGEST="$bad_subject_root_digest" STUB_ROOT_RAW="$bad_subject_root"

# Inject the exact collector descriptors into the valid protected fixture under
# an existing supported alias collision. Capture must retain the whole closure.
injected="$TMP/injected-valid.json"
jq --arg root "$root_digest" --arg platform "$platform_digest" \
  --arg artifact "$artifact_digest" --argjson rootSize "$root_size" \
  --argjson platformSize "$platform_size" --argjson artifactSize "$artifact_size" \
  --slurpfile collected "$collector_output" '
  ($collected[0].registry.manifests) as $synthetic |
  .registry.versions += [{
    id:9900000001,digest:$root,tags:["v1.2.0"]
  }] |
  .registry.manifests += $synthetic
' "$TMP/floor-valid.json" >"$injected"
run_capture "$injected" "$TMP/injected-capture.json"
jq -e --slurpfile collected "$collector_output" '
  ($collected[0].registry.manifests | map(.digest)) as $syntheticDigests |
  ([.protected.manifests[] | select(
    .digest as $digest | any($syntheticDigests[]; . == $digest)
  )]) as $retained |
  ($collected[0].registry.manifests | sort_by(.digest)) as $expected |
  ($retained | sort_by(.digest)) == $expected
' "$TMP/injected-capture.json" >/dev/null ||
  fail "capture did not retain exact injected collector descriptors"

echo "test-promotion protected-state fixtures passed: v1.2.0 floor, retired closure quarantine, supported authority, modern attestations, projector purity, and no writers"
