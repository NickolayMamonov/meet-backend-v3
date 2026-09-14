#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CAPTURE=$ROOT_DIR/scripts/capture-test-promotion-protected-state.sh
FIXTURE=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/valid.json
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

fail() { echo "test-promotion protected-state fixture failed: $*" >&2; exit 1; }
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
expect_byte_change() {
  local name=$1
  local filter=$2
  jq "$filter" "$FIXTURE" >"$TMP/$name.json"
  run_capture "$TMP/$name.json" "$TMP/$name-output.json"
  if cmp --silent "$TMP/canonical.json" "$TMP/$name-output.json"; then
    fail "protected drift did not change canonical bytes: $name"
  fi
}

[ -r "$CAPTURE" ] || fail "capture script is unavailable"
[ -f "$FIXTURE" ] || fail "fixture is missing"
bash -n "$CAPTURE"
command -v jq >/dev/null 2>&1 || fail "jq is required"

run_capture "$FIXTURE" "$TMP/canonical.json"
run_capture "$FIXTURE" "$TMP/repeat.json"
cmp --silent "$TMP/canonical.json" "$TMP/repeat.json" ||
  fail "canonical output is not byte deterministic"
[ "$(wc -l <"$TMP/canonical.json" | tr -d ' ')" -eq 1 ] ||
  fail "canonical output is not compact JSON"
jq -e '
  .schema == "meet-backend/test-promotion-protected-state/v1" and
  .publicRelease.id == 371012814 and .publicRelease.tag == "v1.2.0" and
  .protected.releaseIds == [367640510,371012814] and
  (any(.protected.aliases[]; .alias == "test-sha-1111111111111111111111111111111111111111")) and
  (any(.protected.aliases[]; .alias == "v1.2.0" and (.digests | length) == 2)) and
  (any(.protected.versions[]; .digest == "sha256:9999999999999999999999999999999999999999999999999999999999999999")) and
  (all(.protected.versions[]; .digest != "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")) and
  (any(.protected.referrerClosure[]; .digest == "sha256:7777777777777777777777777777777777777777777777777777777777777777")) and
  (all(.protected.githubAttestations[]; .subjectDigest != "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")) and
  .proof.sha256 == "db5659e40c0b882e17d5e4f8e0218232e500134a86ecf49e6de714808de5c529"
' "$TMP/canonical.json" >/dev/null || fail "protected closure projection is wrong"

jq '
  .releases |= reverse | .releases[].assets |= reverse |
  .tagRefs |= reverse | .registry.versions |= reverse |
  .registry.versions[].tags |= reverse | .registry.subjects |= reverse |
  .registry.subjects[].aliases |= reverse | .registry.manifests |= reverse |
  .registry.manifests[].children |= reverse | .registry.attestations |= reverse
' "$FIXTURE" >"$TMP/reordered.json"
run_capture "$TMP/reordered.json" "$TMP/reordered-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/reordered-output.json" ||
  fail "source ordering changed canonical bytes"

jq '
  .registry.versions |= map(if .id == 2005 then
    .digest = "sha256:abababababababababababababababababababababababababababababababab" |
    .tags = ["test-sha-candidate-changed"] else . end) |
  .registry.manifests |= map(if .digest == "sha256:8888888888888888888888888888888888888888888888888888888888888888"
    then .size = 999 else . end)
' "$FIXTURE" >"$TMP/candidate-only.json"
run_capture "$TMP/candidate-only.json" "$TMP/candidate-only-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/candidate-only-output.json" ||
  fail "candidate-only state changed projection"

jq '.registry.versions |= map(if .id == 2005 then .tags = ["v1.2.0"] else . end)' \
  "$FIXTURE" >"$TMP/collision.json"
run_capture "$TMP/collision.json" "$TMP/collision-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/collision-output.json" &&
  fail "protected collision was discarded"
jq -e 'any(.protected.subjectDigests[]; . == "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")' \
  "$TMP/collision-output.json" >/dev/null || fail "collision digest was not represented"

jq '.registry.versions[0].digest = "not-a-digest"' "$FIXTURE" >"$TMP/malformed.json"
expect_failure malformed run_capture "$TMP/malformed.json" "$TMP/rejected.json"
jq '.releases += [.releases[1]]' "$FIXTURE" >"$TMP/ambiguous.json"
expect_failure ambiguous run_capture "$TMP/ambiguous.json" "$TMP/rejected.json"
jq '.registry.attestations[0].signerWorkflow = "https://evil.invalid/workflow"' \
  "$FIXTURE" >"$TMP/malformed-attestation.json"
expect_failure malformed-attestation \
  run_capture "$TMP/malformed-attestation.json" "$TMP/rejected.json"
jq '.proof.sha256 = "fixture-secret-must-not-appear"' "$FIXTURE" >"$TMP/secret.json"
expect_failure secret-proof run_capture "$TMP/secret.json" "$TMP/rejected.json"
printf '{not-json\n' >"$TMP/not-json"
expect_failure malformed-json run_capture "$TMP/not-json" "$TMP/rejected.json"

jq '.releases[1].draft = true' "$FIXTURE" >"$TMP/release-draft.json"
expect_failure release-draft \
  run_capture "$TMP/release-draft.json" "$TMP/rejected.json"
expect_byte_change release-asset '.releases[1].assets[0].sha256 = "abababababababababababababababababababababababababababababababab"'
expect_byte_change protected-alias \
  '.registry.versions[0].tags += ["protected-drift"]'
expect_byte_change protected-manifest \
  '.registry.manifests[4].size = 301'
expect_byte_change protected-attestation \
  '.registry.attestations[0].sourceDigest = "4444444444444444444444444444444444444444"'

jq '.tagRefs[1].peeledCommitSha = "3333333333333333333333333333333333333333"' \
  "$FIXTURE" >"$TMP/tag-ref-drift.json"
expect_failure tag-ref-drift \
  run_capture "$TMP/tag-ref-drift.json" "$TMP/rejected.json"
jq '.registry.subjects[0].platformDigest = "sha256:9999999999999999999999999999999999999999999999999999999999999999"' \
  "$FIXTURE" >"$TMP/platform-drift.json"
expect_failure platform-drift \
  run_capture "$TMP/platform-drift.json" "$TMP/rejected.json"

cp "$TMP/canonical.json" "$TMP/stable-output.json"
jq '.proof.sha256 = "fixture-secret-must-not-appear"' "$FIXTURE" >"$TMP/rejected-input.json"
if run_capture "$TMP/rejected-input.json" "$TMP/canonical.json" \
    >"$TMP/rejected-retry.stdout" 2>"$TMP/rejected-retry.stderr"; then
  fail "rejected input overwrote an existing output"
fi
cmp --silent "$TMP/stable-output.json" "$TMP/canonical.json" ||
  fail "rejected input changed an existing output"
if find "$TMP" -maxdepth 1 -name 'canonical.json.tmp.*' -print -quit | grep -q .; then
  fail "rejected input left a temporary output"
fi

# The projector has an explicit input shim and no live-state or writer command.
! grep -Eq '(^|[[:space:]])(gh|docker|curl|git|wget|ssh)([[:space:]]|$)' "$CAPTURE" ||
  fail "capture contains a network or registry command"
! grep -Eq '(docker (push|tag|rm)|gh (api|release|attestation)|curl .*https?)' "$CAPTURE" ||
  fail "capture contains a writer/network operation"
mkdir "$TMP/forbidden-bin"
for forbidden in gh docker curl git wget ssh; do
  cp "$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/forbidden-command.sh" \
    "$TMP/forbidden-bin/$forbidden"
done
PATH="$TMP/forbidden-bin:$PATH" \
  run_capture "$FIXTURE" "$TMP/shim-output.json"
cmp --silent "$TMP/canonical.json" "$TMP/shim-output.json" ||
  fail "explicit command shims changed the projection"
COLLECTOR=$ROOT_DIR/scripts/collect-test-promotion-protected-state.sh
HISTORICAL_FIXTURE=$ROOT_DIR/scripts/fixtures/test-promotion-protected-state/historical-authority.json
[ -r "$COLLECTOR" ] || fail "collector is unavailable for policy tests"
[ -r "$HISTORICAL_FIXTURE" ] || fail "historical authority fixture is missing"

# shellcheck source=collect-test-promotion-protected-state.sh
source "$COLLECTOR"

policy_fail() {
  echo "test-promotion protected-state collector policy failed: $*" >&2
  exit 1
}

historical_rows=$(historical_authority_rows) ||
  policy_fail "historical authority rows could not be collected"
jq -e 'type == "array" and length == 4' <<<"$historical_rows" >/dev/null ||
  policy_fail "historical authority rows are not a four-row array"
# Keep the exact production policy bytes for every matrix case without paying
# for repeated JSON construction on the Windows runner.
historical_authority_rows() { printf '%s\n' "$historical_rows"; }
jq -e '
  type == "array" and
  length == 4 and
  length == (unique | length) and
  ([.[] | [.id, .source, .root]] | length) ==
    ([.[] | [.id, .source, .root]] | unique | length)
' <<<"$historical_rows" >/dev/null ||
  policy_fail "historical authority rows are not four unique rows"

jq -e '
  type == "object" and
  (.records | type == "array" and length == 4) and
  all(.records[];
    (.release.id | type == "number") and
    (.release.source | type == "string") and
    (.image.rootDigest | type == "string") and
    (.image.package | type == "object") and
    (.attestation.signerDigest | type == "string")
  )
' "$HISTORICAL_FIXTURE" >/dev/null ||
  policy_fail "historical authority fixture is malformed"

jq -cS '
  .records
  | map({
      triple: [.release.id, .release.source, .image.rootDigest],
      expectedId: .release.id,
      expectedSigner: .attestation.signerDigest,
      context: {
        repository: "NickolayMamonov/meet-backend-v3",
        image: "ghcr.io/nickolaymamonov/meet-backend-v3",
        release: {
          id: .release.id,
          tag: .release.tag,
          version: .release.version,
          source: .release.source,
          draft: .release.draft,
          prerelease: .release.prerelease,
          immutable: .release.immutable
        },
        package: .image.package,
        rootDigest: .image.rootDigest,
        platform: .image.platform
      }
    })
  | sort_by(.triple)
  | .[]
' "$HISTORICAL_FIXTURE" >"$TMP/historical-policy-contexts.jsonl" ||
  policy_fail "historical authority contexts could not be mapped"

policy_expect_rejection() {
  local name=$1
  local context=$2
  if select_historical_authority "$context" \
      >"$TMP/policy-$name.stdout" 2>"$TMP/policy-$name.stderr"; then
    policy_fail "selector accepted mutated context: $name"
  fi
  [ ! -s "$TMP/policy-$name.stdout" ] ||
    policy_fail "selector emitted stdout for rejected context: $name"
  [ -s "$TMP/policy-$name.stderr" ] ||
    policy_fail "selector omitted stderr for rejected context: $name"
}

policy_expect_mutation_rejection() {
  local name=$1
  local context=$2
  local filter=$3
  local mutated
  mutated=$(jq -cS "$filter" <<<"$context") ||
    policy_fail "could not construct mutated context: $name"
  policy_expect_rejection "$name" "$mutated"
}

: >"$TMP/historical-policy-selections.jsonl"
while IFS= read -r entry; do
  triple=$(jq -c '.triple' <<<"$entry") ||
    policy_fail "historical context triple could not be read"
  expected_id=$(jq -r '.expectedId' <<<"$entry") ||
    policy_fail "historical context ID could not be read"
  expected_signer=$(jq -r '.expectedSigner' <<<"$entry") ||
    policy_fail "historical context signer could not be read"
  context=$(jq -c '.context' <<<"$entry") ||
    policy_fail "historical product context could not be read"

  selection=$(select_historical_authority "$context") ||
    policy_fail "historical product context was rejected: $expected_id"
  jq -e --argjson expectedId "$expected_id" --arg expectedSigner "$expected_signer" '
    .status == "historical" and
    .row.id == $expectedId and
    .row.signer == $expectedSigner
  ' <<<"$selection" >/dev/null ||
    policy_fail "historical selection has the wrong ID or signer: $expected_id"
  jq -cnS --argjson triple "$triple" --argjson selection "$selection" '
    {
      triple: $triple,
      status: $selection.status,
      rowId: $selection.row.id,
      signer: $selection.row.signer
    }
  ' >>"$TMP/historical-policy-selections.jsonl" ||
    policy_fail "historical selection could not be recorded: $expected_id"

  reordered_context=$(jq -cS '.package.tags |= reverse' <<<"$context") ||
    policy_fail "historical aliases could not be reordered: $expected_id"
  reordered_selection=$(select_historical_authority "$reordered_context") ||
    policy_fail "reordered historical aliases were rejected: $expected_id"
  printf '%s\n' "$selection" >"$TMP/policy-$expected_id.selection"
  printf '%s\n' "$reordered_selection" >"$TMP/policy-$expected_id.reordered-selection"
  cmp --silent "$TMP/policy-$expected_id.selection" \
    "$TMP/policy-$expected_id.reordered-selection" ||
    policy_fail "alias order changed historical selection: $expected_id"

  policy_expect_mutation_rejection "$expected_id-repository" "$context" \
    '.repository = "other-owner/other-repository"'
  policy_expect_mutation_rejection "$expected_id-source" "$context" \
    '.release.source = "0000000000000000000000000000000000000000"'
  policy_expect_mutation_rejection "$expected_id-package-id" "$context" \
    '.package.id = 0'
  policy_expect_mutation_rejection "$expected_id-root" "$context" \
    '.rootDigest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
  policy_expect_mutation_rejection "$expected_id-platform" "$context" \
    '.platform.digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
  policy_expect_mutation_rejection "$expected_id-draft" "$context" \
    '.release.draft |= not'
  policy_expect_mutation_rejection "$expected_id-prerelease" "$context" \
    '.release.prerelease |= not'
  policy_expect_mutation_rejection "$expected_id-immutable" "$context" \
    '.release.immutable |= not'
  policy_expect_mutation_rejection "$expected_id-alias-content" "$context" \
    '.package.tags |= ["alias-mismatch"] + .[1:]'
  policy_expect_mutation_rejection "$expected_id-alias-cardinality" "$context" \
    '.package.tags |= .[0:2]'
done <"$TMP/historical-policy-contexts.jsonl"

observed_signer_workflow="https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/release-please.yml@refs/heads/dev"
synthetic_subject="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
synthetic_invocation="https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/99999999999/attempts/1"
synthetic_bundle=$(jq -cnS '{synthetic:"accepted-shape"}')
synthetic_response=$(jq -cnS --argjson bundle "$synthetic_bundle" --arg subject "${synthetic_subject#sha256:}" --arg signer "4bff2902511e8e739d7604bf120b121429e60aeb" --arg invocation "$synthetic_invocation" --arg subjectName "ghcr.io/nickolaymamonov/meet-backend-v3" --arg signerWorkflow "$observed_signer_workflow" --arg certificateIdentity "$observed_signer_workflow" '[{attestation:{bundle:$bundle},verificationResult:{statement:{predicateType:"https://slsa.dev/provenance/v1",subject:[{digest:{sha256:$subject},name:$subjectName}]},signature:{certificate:{sourceRepositoryURI:"https://github.com/NickolayMamonov/meet-backend-v3",sourceRepositoryDigest:$signer,sourceRepositoryRef:"refs/heads/dev",buildSignerURI:$signerWorkflow,buildSignerDigest:$signer,subjectAlternativeName:$certificateIdentity,issuer:"https://token.actions.githubusercontent.com",runInvocationURI:$invocation}}}}]')
synthetic_hash=$(jq -cS '.[0].attestation.bundle' <<<"$synthetic_response" | sha256sum | awk '{print $1}')
synthetic_selection=$(jq -cnS --arg signer "4bff2902511e8e739d7604bf120b121429e60aeb" --arg invocation "$synthetic_invocation" --arg subject "ghcr.io/nickolaymamonov/meet-backend-v3" --arg bundle "sha256:$synthetic_hash" \
  '{row:{signer:$signer,invocation:$invocation,subject:$subject,bundle:$bundle}}')
synthetic_output=$(validate_historical_attestation "$synthetic_response" "$synthetic_selection" "$synthetic_subject") || policy_fail "accepted synthetic attestation shape was rejected"
jq -e --arg expected "$observed_signer_workflow" '.signerWorkflow == $expected' <<<"$synthetic_output" >/dev/null || policy_fail "normalized signer workflow was not the parsed observed value"

policy_expect_attestation_rejection() {
  local name=$1
  local filter=$2
  local mutated
  mutated=$(jq -cS "$filter" <<<"$synthetic_response") ||
    policy_fail "could not construct mutated attestation: $name"
  if validate_historical_attestation "$mutated" "$synthetic_selection" "$synthetic_subject" \
      >"$TMP/attestation-$name.stdout" 2>"$TMP/attestation-$name.stderr"; then
    policy_fail "attestation mutation was accepted: $name"
  fi
  [ ! -s "$TMP/attestation-$name.stdout" ] ||
    policy_fail "rejected attestation emitted normalized output: $name"
}

policy_expect_attestation_rejection source-repository \
  '.[0].verificationResult.signature.certificate.sourceRepositoryURI = "https://evil.invalid/repository"'
policy_expect_attestation_rejection source-digest \
  '.[0].verificationResult.signature.certificate.sourceRepositoryDigest = "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc"'
policy_expect_attestation_rejection source-ref \
  '.[0].verificationResult.signature.certificate.sourceRepositoryRef = "refs/heads/main"'
policy_expect_attestation_rejection signer-workflow \
  '.[0].verificationResult.signature.certificate.buildSignerURI = "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/other.yml@refs/heads/dev"'
policy_expect_attestation_rejection signer-digest \
  '.[0].verificationResult.signature.certificate.buildSignerDigest = "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc"'
policy_expect_attestation_rejection certificate-identity \
  '.[0].verificationResult.signature.certificate.subjectAlternativeName = "https://github.com/NickolayMamonov/meet-backend-v3/.github/workflows/other.yml@refs/heads/dev"'
policy_expect_attestation_rejection issuer \
  '.[0].verificationResult.signature.certificate.issuer = "https://evil.invalid/issuer"'
policy_expect_attestation_rejection invocation \
  '.[0].verificationResult.signature.certificate.runInvocationURI = "https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/1/attempts/1"'
policy_expect_attestation_rejection predicate \
  '.[0].verificationResult.statement.predicateType = "https://example.invalid/predicate"'
policy_expect_attestation_rejection subject-name \
  '.[0].verificationResult.statement.subject[0].name = "evil.invalid/image"'
policy_expect_attestation_rejection subject-digest \
  '.[0].verificationResult.statement.subject[0].digest.sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
policy_expect_attestation_rejection product-as-signer \
  '.[0].verificationResult.signature.certificate.sourceRepositoryDigest = "d4102f3c1e4aa12488bd7e0396dfcbdb50ed85fc"'
policy_expect_attestation_rejection bundle \
  '.[0].attestation.bundle = {synthetic:"changed"}'
policy_expect_attestation_rejection duplicate-result \
  '. += .'
policy_expect_attestation_rejection duplicate-subject \
  '.[0].verificationResult.statement.subject |= . + [.[0]]'

# shellcheck disable=SC2034
transport_case() {
  local name=$1 release_id=$2 storage=$3 subject_name=$4
  local transport_tmp="$TMP/transport-$name"
  local artifact_content="workflow-artifact-$name"
  local artifact_digest bundle bundle_hash invocation signer subject selection
  local args_file
  mkdir "$transport_tmp"
  artifact_digest=$(printf '%s' "$artifact_content" | sha256sum | awk '{print $1}')
  subject="sha256:$artifact_digest"
  signer="1111111111111111111111111111111111111111"
  invocation="https://github.com/NickolayMamonov/meet-backend-v3/actions/runs/99999999999/attempts/1"
  bundle=$(jq -cnS --arg storage "$storage" '{transport:$storage}')
  bundle_hash=$(jq -cS <<<"$bundle" | sha256sum | awk '{print $1}')
  selection=$(jq -cnS --argjson id "$release_id" --arg signer "$signer" \
    --arg invocation "$invocation" --arg subject "$subject_name" \
    --arg storage "$storage" --arg bundle "sha256:$bundle_hash" \
    '{status:"historical",row:{id:$id,signer:$signer,invocation:$invocation,
      subject:$subject,storage:$storage,bundle:$bundle}}')
  jq -cnS --argjson id "$release_id" --arg digest "$artifact_digest" \
    --argjson size "${#artifact_content}" \
    '[{id:$id,assets:[{id:123,name:"image-index.json",sha256:$digest,size:$size}]}]' \
    >"$transport_tmp/releases-normalized.json"
  : >"$transport_tmp/attestations.jsonl"
  TRANSPORT_LOG="$transport_tmp/gh-args.log"
  TRANSPORT_ARTIFACT="$artifact_content"
  TRANSPORT_RESPONSE=$(jq -cnS --argjson bundle "$bundle" --arg subject "${subject#sha256:}" \
    --arg signer "$signer" --arg invocation "$invocation" --arg subjectName "$subject_name" \
    --arg signerWorkflow "$observed_signer_workflow" \
    '[{attestation:{bundle:$bundle},verificationResult:{statement:{
      predicateType:"https://slsa.dev/provenance/v1",
      subject:[{digest:{sha256:$subject},name:$subjectName}]},signature:{certificate:{
      sourceRepositoryURI:"https://github.com/NickolayMamonov/meet-backend-v3",
      sourceRepositoryDigest:$signer,sourceRepositoryRef:"refs/heads/dev",
      buildSignerURI:$signerWorkflow,buildSignerDigest:$signer,
      subjectAlternativeName:$signerWorkflow,
      issuer:"https://token.actions.githubusercontent.com",
      runInvocationURI:$invocation}}}}]')
  gh() {
    printf '%s\0' "$@" >>"$TRANSPORT_LOG"
    case "$1" in
      api) printf '%s' "$TRANSPORT_ARTIFACT" ;;
      attestation) printf '%s' "$TRANSPORT_RESPONSE" ;;
      *) return 1 ;;
    esac
  }
  tmp="$transport_tmp"
  repository="NickolayMamonov/meet-backend-v3"
  image="ghcr.io/nickolaymamonov/meet-backend-v3"
  collect_verified_attestations "$subject" "0000000000000000000000000000000000000000" "$selection" ||
    policy_fail "transport adapter rejected its valid $name response"
  unset -f gh
  args_file="$transport_tmp/gh-args.txt"
  tr '\0' '\n' <"$TRANSPORT_LOG" >"$args_file"
  if [ "$storage" = github-api-workflow-artifact ]; then
    grep -Fxq "repos/NickolayMamonov/meet-backend-v3/releases/assets/123" "$args_file" ||
      policy_fail "API workflow-artifact transport did not read the release asset: $name"
    grep -Fxq "$transport_tmp/workflow-artifact-${subject#sha256:}.json" "$args_file" ||
      policy_fail "API workflow-artifact transport did not verify the downloaded artifact: $name"
    ! grep -Fxq -- "--bundle-from-oci" "$args_file" ||
      policy_fail "API workflow-artifact transport fell back to OCI: $name"
  else
    grep -Fxq "oci://ghcr.io/nickolaymamonov/meet-backend-v3@$subject" "$args_file" ||
      policy_fail "OCI transport did not verify the OCI subject: $name"
    grep -Fxq -- "--bundle-from-oci" "$args_file" ||
      policy_fail "OCI transport omitted its explicit bundle transport: $name"
    ! grep -Fxq "repos/NickolayMamonov/meet-backend-v3/releases/assets/123" "$args_file" ||
      policy_fail "OCI transport unexpectedly read a GitHub release asset: $name"
  fi
}

jq -e '
  map(select(.id == 371012814 or .id == 377201468))
  | length == 2 and all(.[]; .storage == "github-api-workflow-artifact")
' <<<"$historical_rows" >/dev/null ||
  policy_fail "v1.2.0 and v1.3.0 do not select the API workflow-artifact transport"
transport_case api-v1.2 371012814 github-api-workflow-artifact image-index.json
transport_case api-v1.3 377201468 github-api-workflow-artifact image-index.json
transport_case oci-v1.0 367640510 oci-registry-bundle ghcr.io/nickolaymamonov/meet-backend-v3

expected_policy_selections=$(jq -cS '
  [.records[] |
    {
      triple: [.release.id, .release.source, .image.rootDigest],
      status: "historical",
      rowId: .release.id,
      signer: .attestation.signerDigest
    }
  ] | sort_by(.triple)
' "$HISTORICAL_FIXTURE") ||
  policy_fail "expected historical selections could not be built"
jq -s -e --argjson expected "$expected_policy_selections" '
  length == 4 and
  (map(.triple) | unique | length) == 4 and
  (sort_by(.triple) == $expected)
' "$TMP/historical-policy-selections.jsonl" >/dev/null ||
  policy_fail "historical authority selections are not bijective"

unrelated_context=$(jq -cnS '{
  repository: "unrelated-owner/unrelated-repository",
  image: "ghcr.io/unrelated-owner/unrelated-image",
  release: {
    id: 999999999,
    tag: "v9.9.9",
    version: "9.9.9",
    source: "ffffffffffffffffffffffffffffffffffffffff",
    draft: false,
    prerelease: false,
    immutable: true
  },
  package: {
    id: 9999999999,
    digest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    tags: [
      "sha-ffffffffffffffffffffffffffffffffffffffff",
      "9.9.9",
      "v9.9.9"
    ]
  },
  rootDigest: "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  platform: {
    digest: "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    mediaType: "application/vnd.oci.image.manifest.v1+json",
    size: 1815,
    platform: {architecture: "amd64", os: "linux"}
  }
}') || policy_fail "unrelated context could not be built"
unrelated_selection=$(select_historical_authority "$unrelated_context") ||
  policy_fail "unrelated product context was rejected"
jq -e '. == {status: "unrelated"}' <<<"$unrelated_selection" >/dev/null ||
  policy_fail "unrelated product context was not classified as unrelated"


echo "test-promotion protected-state fixtures passed: canonical order, drift matrix, candidate exclusion, collision inclusion, malformed input, and no writers/network"
