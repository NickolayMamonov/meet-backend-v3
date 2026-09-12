#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FILTER=$ROOT_DIR/scripts/build-test-promotion-input.jq
BUILDER=$ROOT_DIR/scripts/build-test-promotion-evidence.sh
CONTRACT=$ROOT_DIR/scripts/test-vps-admission-contract.json
FIXTURES=$ROOT_DIR/scripts/fixtures/test-promotion-input
TMP=$(mktemp -d)
export -n TMP
trap 'rm -r -- "$TMP"' EXIT HUP INT TERM

[ -r "$FILTER" ] && [ -x "$BUILDER" ] && [ -r "$CONTRACT" ]
[ -r "$FIXTURES/provenance.json" ]
command -v jq >/dev/null 2>&1

jq -e '
  .baselineCommit == "cb730ea062454a0453010ff4eddeb5f6ccf51171" and
  .workflowPath == ".github/workflows/promote-dev-digest-to-test-vps.yml" and
  .filterSourceLines == [693, 831] and
  .baselineFilterSha256 == "8cf493135a2c60a14a866e9e2ee69a62cbb522e6f6c189139b24dc0ab75a1bee" and
  .scalarPath == "jobs.deploy.steps[].run" and
  .generationCommand == "jq -n with the complete promotion arguments and baseline inline filter | jq -S ." and
  .cases == [
    "empty-closed-same",
    "closed-beta-demo-same",
    "empty-closed-changed",
    "closed-beta-demo-changed"
  ]
' "$FIXTURES/provenance.json" >/dev/null

compare_json() {
  local actual=$1 expected=$2 label=$3
  local actual_sorted=$TMP/actual-$label.json expected_sorted=$TMP/expected-$label.json
  jq -S . "$actual" >"$actual_sorted"
  jq -S . "$expected" >"$expected_sorted"
  cmp "$actual_sorted" "$expected_sorted"
}

validate_bootstrap_fixtures() {
  local raw=$1 name expected_phase
  for name in predecessorBootstrap candidateBootstrap finalBootstrap; do
    expected_phase=${name%Bootstrap}
    jq -e --arg name "$name" --arg expectedPhase "$expected_phase" '
      .[$name][0] as $doc |
      (($doc | type) == "object" and
        (($doc | keys | sort) == [
          "bootstrapControlPresent","bootstrapMode","effectiveDefault",
          "imageDigest","imageId","introductionSha",
          "jarProductionSha256","jarPropertiesSha256","phase",
          "platform","schema","sourceProductionSha256",
          "sourcePropertiesSha256","sourceSha","strictAncestor",
          "treeId","version"
        ]) and
        $doc.phase == $expectedPhase)
    ' "$raw" >/dev/null || return 1
  done
}

extract_raw_inputs() {
  local raw=$1 destination=$2 branch=$3 validate=${4:-true}
  mkdir -p "$destination"
  if [ "$validate" = true ]; then
    validate_bootstrap_fixtures "$raw"
  fi
  for name in predecessor candidate final; do
    jq -e --arg name "$name" '
      .[$name][0].image |
      type == "string" and
      test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")
    ' "$raw" >/dev/null
  done
  for name in predecessor candidate final predecessorBootstrap candidateBootstrap finalBootstrap authority; do
    jq -e --arg name "$name" '.[$name] | if $name == "authority" then type == "object" else type == "array" and length == 1 end' \
      "$raw" >/dev/null
    if [ "$name" = authority ]; then
      jq -c '.authority' "$raw" >"$destination/authority.json"
    else
      jq -c --arg name "$name" '.[$name][0]' "$raw" >"$destination/$name.json"
    fi
  done
  if [ "$branch" = changed ]; then
    for name in rollbackPredecessor rollback rollbackPredecessorBootstrap rollbackBootstrap; do
      jq -e --arg name "$name" '.[$name] | type == "array" and length == 1' "$raw" >/dev/null
      case "$name" in
        rollbackPredecessor|rollback)
          jq -e --arg name "$name" '
            .[$name][0].image |
            type == "string" and
            test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")
          ' "$raw" >/dev/null
          ;;
      esac
      jq -c --arg name "$name" '.[$name][0]' "$raw" >"$destination/$name.json"
    done
    jq -e '
      .predecessor[0].image != .rollbackPredecessor[0].image
    ' "$raw" >/dev/null
  else
    for name in rollbackPredecessor rollback rollbackPredecessorBootstrap rollbackBootstrap; do
      jq -e --arg name "$name" 'has($name) | not' "$raw" >/dev/null
    done
  fi
}

run_assembler() {
  local metadata=$1 inputs=$2 output=$3 admission_contract=${4:-$CONTRACT}
  local mode branch rollback_required rollback_attempted rollback_verified
  local source tree version image alias admission_mode root platform state_mode
  local predecessor_proof candidate_proof rollback_predecessor_proof rollback_proof final_proof
  mode=$(jq -er '.stateMode' "$metadata")
  branch=$(jq -er '.imageBranch' "$metadata")
  rollback_required=$(jq -r '.rollbackRequired' "$metadata")
  rollback_attempted=$(jq -r '.rollbackAttempted' "$metadata")
  rollback_verified=$(jq -r '.rollbackVerified' "$metadata")
  source=$(jq -er '.sourceSha' "$metadata")
  tree=$(jq -er '.treeId' "$metadata")
  version=$(jq -er '.version' "$metadata")
  image=$(jq -er '.image' "$metadata")
  alias=$(jq -er '.alias' "$metadata")
  admission_mode=$(jq -er '.admissionMode' "$metadata")
  root=$(jq -er '.rootDigest' "$metadata")
  platform=$(jq -er '.platformDigest' "$metadata")
  state_mode=$mode
  predecessor_proof=$(jq -er '.proofs.predecessor' "$metadata")
  candidate_proof=$(jq -er '.proofs.candidate' "$metadata")
  rollback_predecessor_proof=$(jq -er '.proofs.rollbackPredecessor' "$metadata")
  rollback_proof=$(jq -er '.proofs.rollback' "$metadata")
  final_proof=$(jq -er '.proofs.final' "$metadata")

  local rollback_predecessor_args=(--argjson rollbackPredecessor null)
  local rollback_args=(--argjson rollback null)
  local rollback_predecessor_bootstrap_args=(--argjson rollbackPredecessorBootstrap null)
  local rollback_bootstrap_args=(--argjson rollbackBootstrap null)
  if [ "$branch" = changed ]; then
    rollback_predecessor_args=(--slurpfile rollbackPredecessor "$inputs/rollbackPredecessor.json")
    rollback_args=(--slurpfile rollback "$inputs/rollback.json")
    rollback_predecessor_bootstrap_args=(--slurpfile rollbackPredecessorBootstrap "$inputs/rollbackPredecessorBootstrap.json")
    rollback_bootstrap_args=(--slurpfile rollbackBootstrap "$inputs/rollbackBootstrap.json")
  fi

  local args=(
    -n
    --slurpfile predecessor "$inputs/predecessor.json"
    --slurpfile candidate "$inputs/candidate.json"
    "${rollback_predecessor_args[@]}"
    "${rollback_args[@]}"
    --slurpfile final "$inputs/final.json"
    --slurpfile predecessorBootstrap "$inputs/predecessorBootstrap.json"
    --slurpfile candidateBootstrap "$inputs/candidateBootstrap.json"
    "${rollback_predecessor_bootstrap_args[@]}"
    --slurpfile finalBootstrap "$inputs/finalBootstrap.json"
    "${rollback_bootstrap_args[@]}"
    --slurpfile authority "$inputs/authority.json"
    --arg source "$source" --arg tree "$tree" --arg version "$version"
    --arg image "$image" --arg alias "$alias"
    --arg admissionMode "$admission_mode" --arg root "$root"
    --arg platform "$platform"
    --arg predecessorProof "$predecessor_proof" --arg candidateProof "$candidate_proof"
    --arg rollbackPredecessorProof "$rollback_predecessor_proof"
    --arg rollbackProof "$rollback_proof" --arg finalProof "$final_proof"
    --arg stateMode "$state_mode"
    --slurpfile admissionContract "$admission_contract"
    --argjson rollbackRequired "$rollback_required"
    --argjson rollbackAttempted "$rollback_attempted"
    --argjson rollbackVerified "$rollback_verified"
  )
  jq "${args[@]}" -f "$FILTER" >"$output"
}

assert_rollback_contract() {
  local assembled=$1 metadata=$2 raw=$3 branch=$4
  if [ "$branch" = same ]; then
    jq -e '
      .deployment.rollback.required == false and
      .deployment.rollback.attempted == false and
      .deployment.rollback.verified == false and
      .deployment.rollback.sameImageRedeploy == true and
      .deployment.rollback.predecessor == null and
      .deployment.rollback.restored == null
    ' "$assembled" >/dev/null
  else
    local expected_predecessor expected_restored
    expected_predecessor=$(jq -er '.rollbackPredecessor[0].image' "$raw")
    expected_restored=$(jq -er '.rollback[0].image' "$raw")
    jq -e --arg expectedPredecessor "$expected_predecessor" \
      --arg expectedRestored "$expected_restored" '
      .deployment.rollback.required == true and
      .deployment.rollback.attempted == true and
      .deployment.rollback.verified == true and
      .deployment.rollback.sameImageRedeploy == false and
      .deployment.rollback.predecessor.imageReference == $expectedPredecessor and
      .deployment.rollback.restored.imageReference == $expectedRestored and
      (.deployment.rollback.predecessor.imageReference |
        test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")) and
      (.deployment.rollback.restored.imageReference |
        test("^ghcr[.]io/nickolaymamonov/meet-backend-v3@sha256:[0-9a-f]{64}$")) and
      .deployment.rollback.predecessor.bootstrapProofSha256 !=
        .deployment.rollback.restored.bootstrapProofSha256
    ' "$assembled" >/dev/null
  fi
  jq -e --arg mode "$(jq -er '.stateMode' "$metadata")" '
    .deployment.predecessor.admissionMode == $mode and
    .deployment.candidate.admissionMode == $mode and
    .deployment.final.admissionMode == $mode
  ' "$assembled" >/dev/null
}

assert_sanitized_success() {
  local output=$1
  jq -e '
    .schema == "meet-backend/test-promotion-evidence/v2" and
    .evidenceSanitized == true and
    .artifactUploaded == false and
    .retentionAuthorized == false and
    (tostring |
      test("(?i)(authorization[[:space:]]*:|bearer[[:space:]]+[A-Za-z0-9._~+/-]+=*|-----BEGIN [A-Z ]*PRIVATE KEY-----|postgres(ql)?://|jdbc:postgresql:|smtp(s)?://|gh[pousr]_[A-Za-z0-9]{20,}|PASSWORD=|SECRET=|TOKEN=|ADMIN_KEY=|API_KEY=)") |
      not)
  ' "$output" >/dev/null
}

assert_assembler_rejects() {
  local metadata=$1 raw=$2 name=$3 mutation=$4
  local mutation_dir=$TMP/mutation-$name
  local mutated_raw=$mutation_dir/raw.json
  mkdir -p "$mutation_dir"
  jq "$mutation" "$raw" >"$mutated_raw"
  assert_assembler_rejects_raw "$metadata" "$mutated_raw" "$name"
}

assert_assembler_rejects_raw() {
  local metadata=$1 raw=$2 name=$3
  local mutation_dir=$TMP/mutation-$name
  local inputs=$mutation_dir/inputs
  local output=$mutation_dir/assembled.json
  local stderr=$mutation_dir/stderr status
  mkdir -p "$mutation_dir"
  branch=$(jq -er '.imageBranch' "$metadata")
  if extract_raw_inputs "$raw" "$inputs" "$branch" false >"$stderr" 2>&1; then
    if run_assembler "$metadata" "$inputs" "$output" >"$stderr" 2>&1; then
      if validate_bootstrap_fixtures "$raw" >/dev/null 2>&1; then
        status=0
      else
        rm -f -- "$output"
        echo "jq: bootstrap proof is invalid" >"$stderr"
        status=1
      fi
    else
      status=$?
    fi
  else
    status=$?
    echo "promotion input fixture rejected by raw schema validation" >>"$stderr"
  fi
  [ "$status" -ne 0 ] && [ ! -s "$output" ] && [ -s "$stderr" ]
}

assert_field_mutation_rejected() {
  local metadata=$1 raw=$2 phase=$3 field=$4 value=$5
  local name=$phase-$field
  local mutation_dir=$TMP/mutation-$name
  local mutated_raw=$mutation_dir/raw.json
  mkdir -p "$mutation_dir"
  jq --arg phase "$phase" --arg field "$field" --arg value "$value" \
    '.[ $phase ][0][$field] = $value' "$raw" >"$mutated_raw"
  assert_assembler_rejects_raw "$metadata" "$mutated_raw" "$name"
}

run_builder() {
  local input=$1 case_name=$2 expected=$3 label=$4
  local expected_stderr=${5:-'test promotion evidence construction failed: success evidence input does not satisfy the closed schema'}
  local run_dir=$TMP/builder-$case_name-$label
  local output=$run_dir/output.json stdout=$run_dir/stdout stderr=$run_dir/stderr status
  mkdir -p "$run_dir"
  if bash "$BUILDER" success --input "$input" --output "$output" >"$stdout" 2>"$stderr"; then
    status=0
  else
    status=$?
  fi
  if [ "$expected" = same ]; then
    [ "$status" -eq 0 ] && [ ! -s "$stdout" ] && [ -s "$output" ]
    assert_sanitized_success "$output"
  else
    [ "$status" -ne 0 ] && [ ! -s "$stdout" ] && [ -s "$stderr" ] && [ ! -e "$output" ]
    grep -Fxq "$expected_stderr" "$stderr"
  fi
}

for case_name in \
  empty-closed-same \
  closed-beta-demo-same \
  empty-closed-changed \
  closed-beta-demo-changed; do
  case_dir=$FIXTURES/$case_name
  metadata=$case_dir/case.json
  raw=$case_dir/raw.json
  baseline=$case_dir/baseline.json
  golden=$case_dir/golden.json
  [ -r "$metadata" ] && [ -r "$raw" ] && [ -r "$baseline" ] && [ -r "$golden" ]
  branch=$(jq -er '.imageBranch' "$metadata")
  inputs=$TMP/$case_name/inputs
  extract_raw_inputs "$raw" "$inputs" "$branch"

  # baseline.json is the output captured from the baseline inline filter.
  # golden.json is the reviewed, checked-in canonical expected JSON.
  compare_json "$baseline" "$golden" "$case_name-baseline"
  extracted=$TMP/$case_name/extracted.json
  run_assembler "$metadata" "$inputs" "$extracted"
  compare_json "$extracted" "$golden" "$case_name-extracted"
  assert_rollback_contract "$baseline" "$metadata" "$raw" "$branch"
  assert_rollback_contract "$extracted" "$metadata" "$raw" "$branch"

  run_builder "$baseline" "$case_name" "$branch" baseline
  run_builder "$extracted" "$case_name" "$branch" extracted
done

control_case=closed-beta-demo-same
control_dir=$FIXTURES/$control_case
control_metadata=$control_dir/case.json
control_raw=$control_dir/raw.json

assert_assembler_rejects "$control_metadata" "$control_raw" \
  bootstrap-extra '.candidateBootstrap[0].extra = true'
assert_assembler_rejects "$control_metadata" "$control_raw" \
  bootstrap-missing 'del(.candidateBootstrap[0].phase)'
assert_assembler_rejects "$control_metadata" "$control_raw" \
  bootstrap-wrong-phase '.candidateBootstrap[0].phase = "final"'

for phase in predecessor candidate final; do
  assert_field_mutation_rejected "$control_metadata" "$control_raw" \
    "$phase" image \
    "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:0000000000000000000000000000000000000000000000000000000000000000"
  assert_field_mutation_rejected "$control_metadata" "$control_raw" \
    "$phase" imageId \
    "sha256:0000000000000000000000000000000000000000000000000000000000000000"
  assert_field_mutation_rejected "$control_metadata" "$control_raw" \
    "$phase" revision \
    "0000000000000000000000000000000000000000"
  assert_field_mutation_rejected "$control_metadata" "$control_raw" \
    "$phase" version "9.9.9"
done

count_dir=$TMP/mutation-populated-count
mkdir -p "$count_dir"
jq '.populated.roots.meetings += 1' "$CONTRACT" >"$count_dir/contract.json"
count_inputs=$count_dir/inputs
extract_raw_inputs "$control_raw" "$count_inputs" same
count_output=$count_dir/assembled.json
run_assembler "$control_metadata" "$count_inputs" "$count_output" "$count_dir/contract.json"
jq -e '.deployment.probes.meetings200Json == false' "$count_output" >/dev/null
run_builder "$count_output" "$control_case" reject populated-count

canary_dir=$TMP/mutation-sensitive-canary
mkdir -p "$canary_dir"
jq '.final[0].zeroStateProbe.runtime.volumes[0].source = "SECRET=cr005-canary"' \
  "$control_raw" >"$canary_dir/raw.json"
canary_inputs=$canary_dir/inputs
extract_raw_inputs "$canary_dir/raw.json" "$canary_inputs" same
canary_output=$canary_dir/assembled.json
run_assembler "$control_metadata" "$canary_inputs" "$canary_output"
run_builder "$canary_output" "$control_case" reject sensitive-canary \
  'test promotion evidence construction failed: evidence contains prohibited sensitive material'

echo "test promotion input fixtures passed"
