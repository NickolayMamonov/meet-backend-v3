#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/promote-dev-digest-to-test-vps.yml
CI=$ROOT_DIR/.github/workflows/ci.yml
FIXTURES=$ROOT_DIR/scripts/fixtures/promote-dev-digest-workflow
AUTHORIZER=$ROOT_DIR/scripts/authorize-dev-promotion.sh
PROBE=$ROOT_DIR/scripts/probe-test-vps-zero-state.sh
PROBE_FIXTURE=$FIXTURES/probe-contract.sh
FILTER=$ROOT_DIR/scripts/build-test-promotion-input.jq

usage() {
  echo "usage: $0 [--oras-runtime-smoke]" >&2
  exit 2
}

smoke=false
case "${1:-}" in
  "") ;;
  --oras-runtime-smoke) smoke=true ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

if [ "$smoke" = true ] &&
  { [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != x86_64 ]; }; then
  echo "ORAS runtime smoke requires Linux amd64" >&2
  exit 2
fi

[ -f "$WORKFLOW" ] && [ -f "$FIXTURES/authorized-run.json" ] || exit 1
[ -f "$FILTER" ]

# Existing promotion/source/protected-state/evidence contracts.
grep -Fq -- '-f scripts/build-test-promotion-input.jq' "$WORKFLOW"
grep -Fq "workflow_dispatch:" "$WORKFLOW"
grep -Fq 'scripts/authorize-dev-promotion.sh' "$WORKFLOW"
! grep -Fq 'version.json' "$WORKFLOW"
! grep -Eq '^[[:space:]]+(push|pull_request|schedule):' "$WORKFLOW"
for guard in "github.event_name == 'workflow_dispatch'" "github.ref == 'refs/heads/dev'" "github.sha == inputs.source_sha"; do
  [ "$(grep -Fc "$guard" "$WORKFLOW")" -ge 4 ] || { echo "missing direct guard: $guard" >&2; exit 1; }
done
grep -Fq "needs.authorize.outputs.authorized == 'true'" "$WORKFLOW"
grep -Fq 'environment: closed-beta-promotion' "$WORKFLOW"
grep -Fq 'environment: test-vps' "$WORKFLOW"
grep -Fq 'group: backend-release-${{ github.repository }}' "$WORKFLOW"
! grep -Fq 'group: test-vps-promotion-${{ github.repository }}' "$WORKFLOW"
grep -Fq 'cancel-in-progress: false' "$WORKFLOW"
! grep -Fq 'actions/checkout@v4' "$WORKFLOW"
grep -Fq 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$WORKFLOW"
grep -Fq 'capture-test-promotion-protected-state.sh' "$WORKFLOW"
grep -Fq 'collect-test-promotion-protected-state.sh' "$WORKFLOW"
grep -Fq 'verify-oci-referrer-closure.sh' "$WORKFLOW"
grep -Fq 'published OCI subject differs from admitted OCI layout' "$WORKFLOW"
grep -Fq 'oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"' "$WORKFLOW"
grep -Fq 'Run pinned ORAS local layout smoke' "$CI"
grep -Fq 'timeout-minutes: 10' "$CI"
grep -Fq 'timeout 600s bash "$TOOLING_SCRIPTS/test-promote-dev-digest-workflow.sh" --oras-runtime-smoke' "$CI"
grep -Fq 'same-image redeploy requires explicit allow_same_digest_redeploy=true' "$WORKFLOW"
grep -Fq 'if: always()' "$WORKFLOW"
grep -Fq 'build-test-promotion-evidence.sh incident' "$WORKFLOW"
grep -Fq 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' "$WORKFLOW"
grep -Fq 'verify-test-vps-assets.sh' "$WORKFLOW"
grep -Fq 'validate-test-vps-phase-file.sh' "$WORKFLOW"
grep -Fq 'verify-test-promotion-layout.sh' "$WORKFLOW"
grep -Fq 'verify-test-promotion-required-checks.sh' "$AUTHORIZER"
grep -Fq 'actions/attest-build-provenance@0f67c3f4856b2e3261c31976d6725780e5e4c373' "$WORKFLOW"
grep -Fq 'id-token: write' "$WORKFLOW"
grep -Fq 'push-to-registry: true' "$WORKFLOW"
grep -Fq 'bootstrap-predecessor.json' "$WORKFLOW"
grep -Fq 'bootstrap-rollback.json' "$WORKFLOW"
grep -Fq 'PUBLIC_V1_2_0_BOOTSTRAP_INTRODUCTION_SHA: a8aa869dafc7b23178c6c505ef07faa720a8b923' "$WORKFLOW"
grep -Fq 'git merge-base --is-ancestor "$previous_revision"' "$WORKFLOW"
grep -Fq 'sha256sum -- "$1"' "$WORKFLOW"
grep -Fq 'local_sha=$(sha256sum "$local_file"' "$WORKFLOW"
grep -Fq 'rollback-predecessor.json' "$WORKFLOW"
grep -Fq 'download_phase "$rollback_state_dir" predecessor' "$WORKFLOW"
grep -Fq '"$rollback_state_dir" "$final_state_dir" "$rollback_required"' "$WORKFLOW"
grep -Fq 'if [ "$rollback_required" = true ]; then' "$WORKFLOW"
grep -Fq 'then $final[0].zeroStateProbe.http.meetingsCount == 0' "$FILTER"
grep -Fq '$admissionContract[0].populated.roots.meetings' "$FILTER"
grep -Fq 'identity($rollbackPredecessor' "$FILTER"
grep -Fq 'def rollback_identity' "$ROOT_DIR/scripts/build-test-promotion-evidence.sh"
grep -Fq '.phase == $expectedPhase' "$FILTER"
grep -Fq 'actionlint_version=1.7.7' "$CI"
grep -Fq 'promote-dev-digest-to-test-vps.yml' "$CI"
grep -Fq 'populated_meetings=$(jq -er' "$PROBE"
grep -Fq '[ "$meetings_count" -eq "$populated_meetings" ]' "$PROBE"
! grep -Fq '[ "$meetings_count" -eq 6 ]' "$PROBE"
[ -x "$PROBE_FIXTURE" ]
grep -Fq -- '--test-admission-contract "$contract"' "$PROBE_FIXTURE"
grep -Fq 'TEST_VPS_PROBE_FIXTURE=true' "$PROBE_FIXTURE"
grep -Fq '.populated.roots.meetings = 7' "$PROBE_FIXTURE"
grep -Fq '.zeroState == "unknown"' "$PROBE_FIXTURE"
"$PROBE_FIXTURE"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/promote-dev-digest.XXXXXX")
cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
! grep -Fq 'find /var/lib/meet-test-vps-deploy' "$WORKFLOW"
grep -Fq 'deployment-branch-policies?per_page=100' "$AUTHORIZER"
! grep -Fq '/deployment-branch-policy"' "$WORKFLOW"
[ "$(grep -Fc 'verify-test-promotion-environment-policy.sh --input' "$AUTHORIZER")" -eq 2 ]
[ "$(grep -Fc 'deployment-branch-policies?per_page=100' "$AUTHORIZER")" -eq 2 ]
[ "$(grep -Fc 'check_environment closed-beta-promotion' "$AUTHORIZER")" -eq 1 ]
[ "$(grep -Fc 'check_environment test-vps' "$AUTHORIZER")" -eq 1 ]
grep -Fq 'dev-promotion-source-final-deploy.json' "$WORKFLOW"
grep -Fq 'mutation_started' "$WORKFLOW"
grep -Fq 'printf '\''root_digest=%s\n'\'' "$root_digest" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
grep -Fq 'printf '\''platform_digest=%s\n'\'' "$platform_digest" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
grep -Fq 'printf '\''admission_mode=%s\n'\'' "$mode" >> "$GITHUB_OUTPUT"' "$WORKFLOW"
! grep -Eiq 'gh[[:space:]]+release|docker[[:space:]]+push|git[[:space:]]+push|refs/tags|--method[[:space:]]+DELETE' "$WORKFLOW" "$FILTER"
command -v jq >/dev/null
jq -e '(.event_name == "workflow_dispatch") and (.ref == "refs/heads/dev") and (.head_sha | test("^[0-9a-f]{40}$")) and (.authorized == true)' \
  "$FIXTURES/authorized-run.json" >/dev/null
jq -e '(.head_sha | test("^[0-9a-f]{40}$")) and (.conclusion == "success") and (.workflow == "ci.yml")' \
  "$FIXTURES/authorized-ci-runs.json" >/dev/null
jq -e '(.closed_beta_promotion_branches == ["dev"]) and (.test_vps_branches == ["dev"])' \
  "$FIXTURES/dev-only-environment.json" >/dev/null
extract_step_metadata() {
  local workflow=$1
  awk '
    function finish() {
      if (active) {
        print active_id "\t" active_name "\t" active_shell "\t" active_timeout "\t" active_if "\t" active_continue
      }
    }
    /^  admit-image:$/ {
      in_admit=1
      next
    }
    in_admit && /^  [A-Za-z0-9_-]+:$/ {
      finish()
      active=0
      in_admit=0
      next
    }
    in_admit && /^      - / {
      finish()
      active=1
      active_id=""
      active_name=""
      active_shell=""
      active_timeout=""
      active_if=""
      active_continue=""
      if ($0 ~ /^      - id: /) active_id=substr($0, index($0, ":") + 2)
      if ($0 ~ /^      - name: /) active_name=substr($0, index($0, ":") + 2)
      next
    }
    in_admit && active {
      if ($0 ~ /^        id: /) active_id=substr($0, index($0, ":") + 2)
      if ($0 ~ /^        name: /) active_name=substr($0, index($0, ":") + 2)
      if ($0 ~ /^        shell: /) active_shell=substr($0, index($0, ":") + 2)
      if ($0 ~ /^        timeout-minutes: /) active_timeout=substr($0, index($0, ":") + 2)
      if ($0 ~ /^        if: /) active_if=substr($0, index($0, ":") + 2)
      if ($0 ~ /^        continue-on-error: /) active_continue=substr($0, index($0, ":") + 2)
    }
    END {
      if (in_admit) finish()
    }
  ' "$workflow"
}

extract_run_block() {
  local workflow=$1
  local marker=$2
  local output=$3
  awk -v marker="$marker" '
    $0 == marker {
      found++
      in_step=1
      next
    }
    in_step && /^      - / {
      in_step=0
      in_run=0
    }
    in_step && /^        run: \|$/ {
      in_run=1
      next
    }
    in_run {
      if ($0 ~ /^          /) {
        sub(/^          /, "")
        print
      } else {
        in_run=0
      }
    }
    END {
      if (found != 1) exit 1
    }
  ' "$workflow" >"$output"
  [ -s "$output" ]
}

assert_step_token_binding() {
  local workflow=$1 marker=$2 expected=$3
  local binding
  binding=$(awk -v marker="$marker" '
    $0 == marker {
      in_step=1
      next
    }
    in_step && /^      - / {
      exit
    }
    in_step && /^          GH_TOKEN: / {
      print
      found++
    }
    END {
      if (found > 1) exit 2
    }
  ' "$workflow")
  if [ "$expected" = true ]; then
    [ "$binding" = '          GH_TOKEN: ${{ github.token }}' ] || {
      echo "credential contract: $marker is missing the explicit github.token binding" >&2
      return 1
    }
  else
    [ -z "$binding" ] || {
      echo "credential mutant: $marker retained the github.token binding" >&2
      return 1
    }
  fi
}

remove_identity_token_binding() {
  local source=$1 output=$2
  awk '
    $0 == "      - name: Verify signed OCI attestation identity" {
      in_identity=1
    }
    in_identity && /^      - / && $0 != "      - name: Verify signed OCI attestation identity" {
      in_identity=0
    }
    in_identity && $0 == "          GH_TOKEN: ${{ github.token }}" {
      next
    }
    { print }
  ' "$source" >"$output"
}

make_credential_fixture() {
  local root=$1
  mkdir -p "$root/bin" "$root/home" "$root/gh-config" "$root/runner-temp" \
    "$root/workspace/scripts"
  cat >"$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${GH_TOKEN:-}" = fixture-token ] || {
  printf '%s\n' gh-token-rejected >>"${CREDENTIAL_EVENTS:?}"
  exit 91
}
[ "$#" -eq 7 ] || exit 92
[ "$1" = attestation ] && [ "$2" = verify ] || exit 93
case "$3" in
  oci://example/meet-backend@sha256:*) ;;
  *) exit 94 ;;
esac
[ "$4" = --repo ] && [ "$5" = example/meet-backend ] || exit 95
[ "$6" = --source-digest ] && [ "$7" = 0123456789abcdef0123456789abcdef01234567 ] || exit 96
printf 'identity-%s\n' "${ADMISSION_MODE:?}" >>"${CREDENTIAL_EVENTS:?}"
EOF
  chmod 755 "$root/bin/gh"
  cat >"$root/workspace/scripts/admit-test-image.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = verify ] || exit 90
printf 'admission-%s\n' "${ADMISSION_MODE:?}" >>"${CREDENTIAL_EVENTS:?}"
EOF
  chmod 755 "$root/workspace/scripts/admit-test-image.sh"
  cat >"$root/workspace/scripts/collect-test-promotion-protected-state.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ]
printf '%s\n' '{"fixture":"protected"}' >"$output"
EOF
  chmod 755 "$root/workspace/scripts/collect-test-promotion-protected-state.sh"
  cat >"$root/workspace/scripts/capture-test-promotion-protected-state.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --input) input=$2; shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -f "$input" ] && [ -n "$output" ]
cp -- "$input" "$output"
printf 'protected-%s\n' "${ADMISSION_MODE:?}" >>"${CREDENTIAL_EVENTS:?}"
EOF
  chmod 755 "$root/workspace/scripts/capture-test-promotion-protected-state.sh"
  printf '%s\n' '{"fixture":"protected"}' >"$root/runner-temp/protected-before.json"
  printf '%s\n' publication-confirmed >"$root/journal-facts"
}

run_credential_identity_step() {
  local workflow=$1 root=$2 block=$3 mode=$4
  local status
  local -a token_env=()
  extract_run_block "$workflow" \
    '      - name: Verify signed OCI attestation identity' "$block"
  if awk '
    $0 == "      - name: Verify signed OCI attestation identity" {
      in_step=1
      next
    }
    in_step && /^      - / { exit }
    in_step && $0 == "          GH_TOKEN: ${{ github.token }}" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$workflow"; then
    token_env=(GH_TOKEN=fixture-token)
  fi
  set +e
  (
    cd "$root/workspace"
    env -i \
      HOME="$root/home" GH_CONFIG_DIR="$root/gh-config" \
      PATH="$root/bin:$REAL_PATH" \
      IMAGE=example/meet-backend \
      ROOT_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111 \
      SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
      GITHUB_REPOSITORY=example/meet-backend \
      "${token_env[@]}" \
      ADMISSION_MODE="$mode" CREDENTIAL_EVENTS="$root/events" \
      "$BASH" "$block"
  )
  status=$?
  set -e
  return "$status"
}

run_credential_post_identity_steps() {
  local workflow=$1 root=$2 final_block=$3 protected_block=$4 mode=$5
  extract_run_block "$workflow" '      - name: Read-only image admission' "$final_block"
  extract_run_block "$workflow" \
    '      - name: Capture protected registry state after admission' "$protected_block"
  (
    cd "$root/workspace"
    env -i \
      HOME="$root/home" GH_CONFIG_DIR="$root/gh-config" \
      PATH="$root/bin:$REAL_PATH" \
      IMAGE=example/meet-backend \
      ROOT_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111 \
      PLATFORM_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222 \
      SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
      VERSION=1.4.0 GITHUB_REPOSITORY=example/meet-backend \
      GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF=refs/heads/dev \
      GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
      RUNNER_TEMP="$root/runner-temp" GH_TOKEN=fixture-token \
      ADMISSION_MODE="$mode" CREDENTIAL_EVENTS="$root/events" \
      "$BASH" "$final_block"
  )
  (
    cd "$root/workspace"
    env -i \
      HOME="$root/home" GH_CONFIG_DIR="$root/gh-config" \
      PATH="$root/bin:$REAL_PATH" \
      IMAGE=example/meet-backend \
      SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
      GITHUB_REPOSITORY=example/meet-backend \
      RUNNER_TEMP="$root/runner-temp" GH_TOKEN=fixture-token \
      ADMISSION_MODE="$mode" CREDENTIAL_EVENTS="$root/events" \
      "$BASH" "$protected_block"
  )
}

credential_step_contract() {
  local workflow=$1 root=$2 mode=$3 identity_block=$4 final_block=$5 protected_block=$6
  : >"$root/events"
  if ! run_credential_identity_step "$workflow" "$root" "$identity_block" "$mode"; then
    echo "credential fixture: signed identity failed on $mode positive path" >&2
    return 1
  fi
  run_credential_post_identity_steps "$workflow" "$root" "$final_block" \
    "$protected_block" "$mode"
  grep -Fxq "identity-$mode" "$root/events"
  grep -Fxq "admission-$mode" "$root/events"
  grep -Fxq "protected-$mode" "$root/events"
  ! grep -Eq '^(build|copy|sign|deploy)$' "$root/events"
}

workflow_contract() {
  local workflow=$1
  local block=$2
  local metadata=$3
  local publish_block="$metadata.publish"
  extract_step_metadata "$workflow" >"$metadata"
  [ "$(awk -F '\t' '$1 == "provision-oras" { count++ } END { print count + 0 }' "$metadata")" -eq 1 ] ||
    { echo "workflow contract: expected exactly one provision-oras step" >&2; return 1; }
  local record id name shell timeout condition continue_on_error
  record=$(awk -F '\t' '$1 == "provision-oras" { print; exit }' "$metadata")
  IFS=$'\t' read -r id name shell timeout condition continue_on_error <<<"$record"
  [ "$id" = provision-oras ] || { echo "workflow contract: provision id mismatch" >&2; return 1; }
  [ "$name" = "Provision verified ORAS" ] || { echo "workflow contract: provision name mismatch" >&2; return 1; }
  [ "$shell" = bash ] || { echo "workflow contract: provision shell is not bash" >&2; return 1; }
  [ "$timeout" = 5 ] || { echo "workflow contract: provision deadline is not five minutes" >&2; return 1; }
  [ -z "$condition" ] || { echo "workflow contract: provision has a conditional bypass" >&2; return 1; }
  [ -z "$continue_on_error" ] || { echo "workflow contract: provision has continue-on-error" >&2; return 1; }
  if [ "${4:-}" != block-only ]; then
    extract_run_block "$workflow" '      - id: provision-oras' "$block" ||
      { echo "workflow contract: provision run block is missing or ambiguous" >&2; return 1; }
  fi
  extract_run_block "$workflow" '      - id: publish' "$publish_block" ||
    { echo "workflow contract: publish run block is missing or ambiguous" >&2; return 1; }

  local copy_count copy_command root_selection platform_selection source_verify layout_verify copy
  local root_guard platform_guard
  copy_count=$(grep -Fc 'oras cp --from-oci-layout' "$publish_block")
  [ "$copy_count" -eq 1 ] ||
    { echo "workflow contract: expected exactly one OCI copy command" >&2; return 1; }
  grep -Fxq 'alias="test-sha-$SOURCE_SHA"' "$publish_block" ||
    { echo "workflow contract: source-derived alias changed" >&2; return 1; }
  grep -Fxq 'ref="$IMAGE:$alias"' "$publish_block" ||
    { echo "workflow contract: source-derived alias changed" >&2; return 1; }
  copy_command=$(grep -F 'oras cp --from-oci-layout' "$publish_block" | sed 's/^[[:space:]]*//')
  [ "$copy_command" = 'oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"' ] ||
    { echo "workflow contract: copy source must select admitted root digest" >&2; return 1; }
  root_selection=$(grep -nF 'local_root_digest=$(jq -er' "$publish_block" | cut -d: -f1)
  platform_selection=$(grep -nF 'local_platform_digest=$(jq -er' "$publish_block" | cut -d: -f1)
  source_verify=$(grep -nF 'scripts/verify-dev-promotion-source.sh' "$publish_block" | cut -d: -f1)
  layout_verify=$(grep -nF 'scripts/verify-test-promotion-layout.sh' "$publish_block" | cut -d: -f1)
  copy=$(grep -nF 'oras cp --from-oci-layout' "$publish_block" | cut -d: -f1)
  root_guard=$(grep -nF 'test "$local_root_digest" = "$root_digest"' "$publish_block" | cut -d: -f1)
  platform_guard=$(grep -nF 'test "$local_platform_digest" = "$platform_digest"' "$publish_block" | cut -d: -f1)
  [ "$(grep -Fc 'local_root_digest=$(jq -er' "$publish_block")" -eq 1 ] &&
    [ "$(grep -Fc 'local_platform_digest=$(jq -er' "$publish_block")" -eq 1 ] &&
    [ -n "$root_selection" ] && [ -n "$platform_selection" ] &&
    [ -n "$source_verify" ] && [ -n "$layout_verify" ] &&
    [ -n "$copy" ] && [ -n "$root_guard" ] && [ -n "$platform_guard" ] ||
    { echo "workflow contract: root/platform admission or equality guard missing" >&2; return 1; }
  [ "$root_selection" -lt "$source_verify" ] &&
    [ "$platform_selection" -lt "$source_verify" ] &&
    [ "$source_verify" -lt "$layout_verify" ] &&
    [ "$layout_verify" -lt "$copy" ] &&
    [ "$copy" -lt "$root_guard" ] &&
    [ "$root_guard" -lt "$platform_guard" ] || {
      if [ "$copy" -lt "$layout_verify" ]; then
        echo "workflow contract: copy precedes layout verification" >&2
      else
        echo "workflow contract: admission or equality ordering changed" >&2
      fi
      return 1
    }
  grep -Fq 'if length == 1 then .[0] else error("OCI layout root is not unique") end' "$publish_block" ||
    { echo "workflow contract: root uniqueness guard changed" >&2; return 1; }
  grep -Fq 'if length == 1 then .[0] else error("OCI layout platform is not unique") end' "$publish_block" ||
    { echo "workflow contract: platform uniqueness guard changed" >&2; return 1; }

  local direct_line provision_line protected_line publish_line attestation_line copy_line
  direct_line=$(grep -nF -- '- name: Recheck direct writer guards' "$workflow" | cut -d: -f1)
  provision_line=$(grep -nF -- '- id: provision-oras' "$workflow" | cut -d: -f1)
  protected_line=$(grep -nF -- 'name: Capture protected registry state before any writer' "$workflow" | cut -d: -f1)
  publish_line=$(grep -nF -- '- id: publish' "$workflow" | cut -d: -f1)
  attestation_line=$(grep -nF -- 'name: Create signed OCI attestation for a first-time alias' "$workflow" | cut -d: -f1)
  copy_line=$(grep -nF -- 'oras cp --from-oci-layout' "$workflow" | cut -d: -f1)
  if [ "$provision_line" -gt "$attestation_line" ]; then
    echo "workflow contract: provision step is after attestation" >&2
    return 1
  fi
  if [ "$provision_line" -gt "$publish_line" ]; then
    echo "workflow contract: provision step is after publish" >&2
    return 1
  fi
  [ "$direct_line" -lt "$provision_line" ] &&
    [ "$provision_line" -lt "$protected_line" ] &&
    [ "$protected_line" -lt "$publish_line" ] &&
    [ "$publish_line" -lt "$copy_line" ] &&
    [ "$copy_line" -lt "$attestation_line" ] ||
    { echo "workflow contract: admission ordering is invalid" >&2; return 1; }
  [ "$(grep -nF -- 'docker login ghcr.io' "$workflow" | head -1 | cut -d: -f1)" -gt "$provision_line" ] ||
    { echo "workflow contract: login precedes ORAS readiness" >&2; return 1; }
  [ "$(grep -nF -- 'docker buildx build' "$workflow" | head -1 | cut -d: -f1)" -gt "$provision_line" ] ||
    { echo "workflow contract: build precedes ORAS readiness" >&2; return 1; }
  grep -Fq "needs: [authorize, admit-image]" "$workflow" ||
    { echo "workflow contract: deploy admission dependency changed" >&2; return 1; }
  grep -Fq "needs.incident.result == 'skipped'" "$workflow" ||
    { echo "workflow contract: retention success gate changed" >&2; return 1; }

  local checksum_line extraction_line version_line path_line
  checksum_line=$(grep -nF -- 'sha256sum --check --strict' "$block" | cut -d: -f1)
  extraction_line=$(grep -nF -- 'tar -xzf' "$block" | cut -d: -f1)
  version_line=$(grep -nF -- '"$bin/oras" version' "$block" | cut -d: -f1)
  path_line=$(grep -nF -- 'GITHUB_PATH' "$block" | cut -d: -f1 | tail -1)
  [ -n "$checksum_line" ] && [ -n "$extraction_line" ] && [ -n "$version_line" ] && [ -n "$path_line" ] ||
    { echo "provision contract: checksum, extraction, version or path publication is missing" >&2; return 1; }
  [ "$checksum_line" -lt "$extraction_line" ] &&
    [ "$extraction_line" -lt "$version_line" ] &&
    [ "$version_line" -lt "$path_line" ] ||
    { echo "provision contract: verification order is invalid" >&2; return 1; }
  grep -Fq 'oras_version=1.3.4' "$block" ||
    { echo "provision contract: ORAS version pin changed" >&2; return 1; }
  grep -Fq 'oras_sha256=f27adb935022d94df8dc77719c322dda592c78a0d57a6f7dcdd8d900b248c454' "$block" ||
    { echo "provision contract: ORAS checksum pin changed" >&2; return 1; }
  grep -Fq 'https://github.com/oras-project/oras/releases/download/v${oras_version}/oras_${oras_version}_linux_amd64.tar.gz' "$block" ||
    { echo "provision contract: ORAS URL pin changed" >&2; return 1; }
  for bound in \
    "--proto '=https'" "--proto-redir '=https'" "--connect-timeout 10" \
    "--max-time 60" "--retry 2" "--retry-delay 2" "--retry-max-time 180"; do
    grep -Fq -- "$bound" "$block" ||
      { echo "provision contract: missing curl bound $bound" >&2; return 1; }
  done
  grep -Fq 'mktemp -d "$runner_temp_real/oras.XXXXXX"' "$block" ||
    { echo "provision contract: private runner temp root changed" >&2; return 1; }
  grep -Fq 'runner temp must be outside checkout' "$block" ||
    { echo "provision contract: checkout containment guard missing" >&2; return 1; }
  local first_copy
  first_copy=$(grep -nE '(^|[[:space:]])oras[[:space:]]+cp([[:space:]]|$)' "$block" | head -1 | cut -d: -f1 || true)
  [ -z "$first_copy" ] || [ "$version_line" -lt "$first_copy" ] ||
    { echo "provision contract: ORAS first use precedes readiness" >&2; return 1; }
}

assert_event_order() {
  local events=$1
  local expected=$2
  local previous=0
  local event line
  while IFS= read -r event; do
    line=$(grep -nFx -- "$event" "$events" | head -1 | cut -d: -f1 || true)
    [ -n "$line" ] || { echo "event oracle: missing $event" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { echo "event oracle: order violation at $event" >&2; return 1; }
    previous=$line
  done <"$expected"
}

assert_no_writer_events() {
  local events=$1
  ! grep -Eq '^(protected-capture|login|build|copy|attestation|deploy)$' "$events"
}

make_fixture() {
  local root=$1
  mkdir -p "$root/archive-root" "$root/ambient/bin" "$root/spies" "$root/home"
  cat >"$root/archive-root/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = version ]; then
  printf '%s\n' version-probe >>"${ORAS_EVENTS:?}"
  test ! -s "${GITHUB_PATH:?}"
  case "${ORAS_VERSION_MODE:-good}" in
    good) printf 'Version: 1.3.4\n' ;;
    wrong) printf 'Version: 1.3.3\n' ;;
    suffixed) printf 'Version: 1.3.4+unexpected\n' ;;
    missing) printf 'oras version output without a Version field\n' ;;
    duplicate) printf 'Version: 1.3.4\nVersion: 1.3.4\n' ;;
    *) exit 97 ;;
  esac
  exit 0
fi
if [ "${1:-}" = cp ]; then
  printf '%s\n' copy >>"${ORAS_EVENTS:?}"
fi
EOF
  chmod 755 "$root/archive-root/oras"
  tar -C "$root/archive-root" -czf "$root/oras_1.3.4_linux_amd64.tar.gz" oras
  sha256sum "$root/oras_1.3.4_linux_amd64.tar.gz" | awk '{print $1}' >"$root/archive.sha256"

  cat >"$root/ambient/bin/oras" <<'EOF'
#!/usr/bin/env bash
echo "ambient ORAS was selected" >&2
exit 91
EOF
  chmod 755 "$root/ambient/bin/oras"

  cat >"$root/spies/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
url=
connect=
overall=
retry=
retry_delay=
retry_max=
proto=
proto_redir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output=$2; shift 2 ;;
    --proto) proto=$2; shift 2 ;;
    --proto-redir) proto_redir=$2; shift 2 ;;
    --connect-timeout) connect=$2; shift 2 ;;
    --max-time) overall=$2; shift 2 ;;
    --retry) retry=$2; shift 2 ;;
    --retry-delay) retry_delay=$2; shift 2 ;;
    --retry-max-time) retry_max=$2; shift 2 ;;
    --fail|--silent|--show-error|--location) shift ;;
    https://*) url=$1; shift ;;
    *) echo "curl spy: unexpected argument $1" >&2; exit 92 ;;
  esac
done
if ! { [ "$proto" = '=https' ] && [ "$proto_redir" = '=https' ]; }; then
  echo "curl spy: HTTPS redirect policy changed" >&2
  exit 94
fi
if ! { [ "$connect" = 10 ] && [ "$overall" = 60 ] && [ "$retry" = 2 ] &&
  [ "$retry_delay" = 2 ] && [ "$retry_max" = 180 ]; }; then
  echo "curl spy: finite bound changed" >&2
  exit 95
fi
[ "$url" = "https://github.com/oras-project/oras/releases/download/v1.3.4/oras_1.3.4_linux_amd64.tar.gz" ]
runner_temp_real=$(cd -- "$RUNNER_TEMP" && pwd -P)
case "$output" in
  "$runner_temp_real"/oras.*/oras.tar.gz) ;;
  *) echo "curl spy: output escaped private temp: $output (runner temp $RUNNER_TEMP)" >&2; exit 93 ;;
esac
printf '%s\n' download >>"${ORAS_EVENTS:?}"
[ "${ORAS_CURL_MODE:-copy}" != timeout ] || exit 28
cp -- "${ORAS_FIXTURE_ARCHIVE:?}" "$output"
EOF
  chmod 755 "$root/spies/curl"

  cat >"$root/spies/sha256sum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"${REAL_SHA256SUM:?}" "$@"
status=$?
if [ "$status" -eq 0 ]; then
  printf '%s\n' checksum-success >>"${ORAS_EVENTS:?}"
fi
exit "$status"
EOF
  chmod 755 "$root/spies/sha256sum"

  cat >"$root/spies/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' extraction-start >>"${ORAS_EVENTS:?}"
"${REAL_TAR:?}" "$@"
status=$?
if [ "$status" -eq 0 ]; then
  printf '%s\n' extraction-success >>"${ORAS_EVENTS:?}"
  if [ "${ORAS_TAR_MODE:-normal}" = remove ]; then
    for candidate in "$RUNNER_TEMP"/oras.*/bin/oras; do
      [ -e "$candidate" ] && rm -f -- "$candidate"
    done
  fi
fi
exit "$status"
EOF
  chmod 755 "$root/spies/tar"
}

run_provision() {
  local block=$1
  local root=$2
  local workspace=$3
  local temp=$4
  : >"$root/events"
  : >"$root/github-path"
  : >"$root/github-output"
  set +e
  env -i \
    HOME="$root/home" \
    PATH="$root/ambient/bin:$root/spies:$REAL_PATH" \
    RUNNER_TEMP="$temp" \
    GITHUB_WORKSPACE="$workspace" \
    GITHUB_PATH="$root/github-path" \
    GITHUB_OUTPUT="$root/github-output" \
    ORAS_EVENTS="$root/events" \
    ORAS_FIXTURE_ARCHIVE="$root/oras_1.3.4_linux_amd64.tar.gz" \
    REAL_SHA256SUM="$REAL_SHA256SUM" \
    REAL_TAR="$REAL_TAR" \
    ORAS_VERSION_MODE="${ORAS_VERSION_MODE:-good}" \
    ORAS_CURL_MODE="${ORAS_CURL_MODE:-copy}" \
    ORAS_TAR_MODE="${ORAS_TAR_MODE:-normal}" \
    "$BASH" "$block"
  local status=$?
  set -e
  return "$status"
}

assert_provision_failure() {
  local label=$1
  local block=$2
  local root=$3
  local workspace=$4
  local temp=$5
  if run_provision "$block" "$root" "$workspace" "$temp"; then
    echo "$label: expected provisioning failure" >&2
    return 1
  fi
  [ ! -s "$root/github-path" ] || { echo "$label: published an unverified path" >&2; return 1; }
  assert_no_writer_events "$root/events" || { echo "$label: writer ran after failure" >&2; return 1; }
}

run_incident_contract() {
  local block=$1
  local root=$2
  local workspace="$root/workspace"
  local temp="$root/temp"
  mkdir -p "$workspace/scripts" "$temp"
  cp -- "$ROOT_DIR/scripts/build-test-promotion-evidence.sh" "$workspace/scripts/"
  cp -- "$ROOT_DIR/scripts/test-vps-admission-contract.json" "$workspace/scripts/"
  : >"$root/github-path"
  (
    cd "$workspace"
    env -i HOME="$root/home" PATH="$REAL_PATH" RUNNER_TEMP="$temp" \
      GITHUB_WORKSPACE="$workspace" GITHUB_PATH="$root/github-path" \
      "$BASH" "$block"
  )
  jq -e '
    .schema == "meet-backend/test-promotion-incident/v3" and
    .kind == "incident" and .stage == "admission" and
    .failureClass == "internalFailure" and
    .mutationStarted == false and .deploymentMutationStarted == false and
    .registryPublication == "unknown" and
    .attestationWrite == "unknown" and
    .initialAliasState == "unknown" and
    .rollbackAttempted == false and
    .rollbackVerified == false and .evidenceSanitized == true and
    .retentionAuthorized == false
  ' "$temp/promotion-incident.json" >/dev/null
  if "$ROOT_DIR/scripts/build-test-promotion-evidence.sh" authorize-retention \
    --evidence "$temp/promotion-incident.json" \
    --artifact-uploaded true --output "$temp/retention.json"; then
    echo "incident contract: retention unexpectedly authorized" >&2
    return 1
  fi
  [ ! -e "$temp/retention.json" ]
  [ ! -e "$temp/protected-before.json" ]
  [ ! -e "$temp/candidate.json" ]
}

REAL_PATH=$PATH
REAL_SHA256SUM=$(command -v sha256sum)
REAL_TAR=$(command -v tar)
make_fixture "$TEST_ROOT/fixture"
FIXTURE="$TEST_ROOT/fixture"
mkdir -p "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"

provision_block="$TEST_ROOT/provision.sh"
workflow_metadata="$TEST_ROOT/steps.tsv"
workflow_contract "$WORKFLOW" "$provision_block" "$workflow_metadata"

for token_step in \
  '      - id: protected-before' \
  '      - id: publish' \
  '      - id: fresh-inventory' \
  '      - id: observed' \
  '      - id: final-inventory' \
  '      - id: final-observed' \
  '      - name: Verify signed OCI attestation identity' \
  '      - name: Read-only image admission' \
  '      - name: Capture protected registry state after admission'; do
  assert_step_token_binding "$WORKFLOW" "$token_step" true
done

credential_root="$TEST_ROOT/credential-fixture"
make_credential_fixture "$credential_root"
credential_identity="$TEST_ROOT/credential-identity.sh"
credential_final="$TEST_ROOT/credential-final.sh"
credential_protected="$TEST_ROOT/credential-protected.sh"
extract_run_block "$WORKFLOW" \
  '      - name: Verify signed OCI attestation identity' "$credential_identity"
extract_run_block "$WORKFLOW" \
  '      - name: Read-only image admission' "$credential_final"
extract_run_block "$WORKFLOW" \
  '      - name: Capture protected registry state after admission' \
  "$credential_protected"
for credential_mode in published reused; do
  credential_step_contract "$WORKFLOW" "$credential_root" "$credential_mode" \
    "$credential_identity" "$credential_final" "$credential_protected"
done

identity_token_mutant="$TEST_ROOT/workflow-without-identity-token.yml"
remove_identity_token_binding "$WORKFLOW" "$identity_token_mutant"
assert_step_token_binding "$identity_token_mutant" \
  '      - name: Verify signed OCI attestation identity' false
for credential_mode in published reused; do
  : >"$credential_root/events"
  journal_hash=$(sha256sum "$credential_root/journal-facts" | awk '{print $1}')
  if run_credential_identity_step "$identity_token_mutant" "$credential_root" \
    "$credential_identity" "$credential_mode"; then
    echo "credential mutant: missing identity token unexpectedly passed" >&2
    exit 1
  fi
  grep -Fxq gh-token-rejected "$credential_root/events"
  ! grep -Eq '^(identity|admission|protected)-' "$credential_root/events"
  ! grep -Fq fixture-token "$credential_root/events"
  [ "$(sha256sum "$credential_root/journal-facts" | awk '{print $1}')" = "$journal_hash" ]
done
echo "credential fixtures passed: published/reused identity admission and removed-binding rejection"

fixture_sha=$(awk '{print $1}' "$TEST_ROOT/fixture/archive.sha256")
fixture_block="$TEST_ROOT/provision-fixture.sh"
sed "s/^oras_sha256=.*/oras_sha256=$fixture_sha/" "$provision_block" >"$fixture_block"

if [ "$smoke" = true ]; then
  smoke_root="$TEST_ROOT/smoke"
  mkdir -p "$smoke_root/home" "$smoke_root/runner-temp"
  : >"$smoke_root/github-path"
  timeout 300s env -i HOME="$smoke_root/home" PATH="$REAL_PATH" \
    RUNNER_TEMP="$smoke_root/runner-temp" GITHUB_WORKSPACE="$ROOT_DIR" \
    GITHUB_PATH="$smoke_root/github-path" GITHUB_OUTPUT="$smoke_root/github-output" \
    "$BASH" "$provision_block"
  selected_bin=$(head -1 "$smoke_root/github-path")
  case "$selected_bin" in
    "$smoke_root"/runner-temp/oras.*/bin) ;;
    *) echo "smoke: selected binary is not private" >&2; exit 1 ;;
  esac
  selected="$selected_bin/oras"
  [ -x "$selected" ]
  selected_command=$(PATH="$selected_bin:$REAL_PATH" command -v oras)
  [ "$selected_command" = "$selected" ]
  version_output=$("$selected" version)
  version=$(printf '%s\n' "$version_output" | awk '
    $1 == "Version:" {
      count++
      if (NF != 2) exit 2
      value=$2
    }
    END {
      if (count != 1 || value != "1.3.4") exit 3
      print value
    }
  ')
  [ "$version" = "1.3.4" ]
  bash "$ROOT_DIR/scripts/test-test-promotion-layout.sh" --oras-bin "$selected"
  echo "ORAS runtime smoke passed: pinned 1.3.4 private executable selected"
  exit 0
fi

expected_events="$TEST_ROOT/expected-events"
cat >"$expected_events" <<'EOF'
download
checksum-success
extraction-success
version-probe
path-published
protected-capture
login
build
copy
attestation
deploy
EOF

ORAS_VERSION_MODE=good ORAS_CURL_MODE=copy ORAS_TAR_MODE=normal \
  run_provision "$fixture_block" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"
selected_bin=$(head -1 "$FIXTURE/github-path")
[ -x "$selected_bin/oras" ]
selected_command=$(PATH="$selected_bin:$FIXTURE/ambient/bin:$REAL_PATH" command -v oras)
[ "$selected_command" = "$selected_bin/oras" ]
printf '%s\n' path-published protected-capture login build copy attestation deploy >>"$FIXTURE/events"
assert_event_order "$FIXTURE/events" "$expected_events"

for mode in wrong suffixed missing duplicate; do
  mutant="$TEST_ROOT/version-$mode.sh"
  cp -- "$fixture_block" "$mutant"
  ORAS_VERSION_MODE=$mode ORAS_CURL_MODE=copy ORAS_TAR_MODE=normal \
    assert_provision_failure "version-$mode" "$mutant" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"
done

tar_mutant="$TEST_ROOT/tar-remove.sh"
cp -- "$fixture_block" "$tar_mutant"
ORAS_VERSION_MODE=good ORAS_CURL_MODE=copy ORAS_TAR_MODE=remove \
  assert_provision_failure "missing-selected-executable" "$tar_mutant" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"

corrupt="$TEST_ROOT/corrupt.sh"
cp -- "$fixture_block" "$corrupt"
printf '%s\n' corrupt >>"$FIXTURE/oras_1.3.4_linux_amd64.tar.gz"
ORAS_VERSION_MODE=good ORAS_CURL_MODE=copy ORAS_TAR_MODE=normal \
  assert_provision_failure "checksum-corruption" "$corrupt" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"
! grep -Fq extraction-start "$FIXTURE/events"
tar -C "$FIXTURE/archive-root" -czf "$FIXTURE/oras_1.3.4_linux_amd64.tar.gz" oras

no_checksum="$TEST_ROOT/no-checksum.sh"
sed '/sha256sum --check --strict/d' "$provision_block" >"$no_checksum"
if workflow_contract "$WORKFLOW" "$no_checksum" "$workflow_metadata" block-only; then
  echo "missing-checksum: structural oracle accepted mutation" >&2
  exit 1
fi

no_version="$TEST_ROOT/no-version.sh"
sed '/version_output=/,/test "$version" = "$oras_version"/d' "$provision_block" >"$no_version"
if workflow_contract "$WORKFLOW" "$no_version" "$workflow_metadata" block-only; then
  echo "missing-version: structural oracle accepted mutation" >&2
  exit 1
fi

copy_before="$TEST_ROOT/copy-before.sh"
{
  echo 'oras cp --from-oci-layout "$RUNNER_TEMP/layout" "$IMAGE:tag"'
  sed '/sha256sum --check --strict/i first-use-sentinel' "$provision_block"
} >"$copy_before"
if workflow_contract "$WORKFLOW" "$copy_before" "$workflow_metadata" block-only; then
  echo "first-use ordering oracle accepted pre-readiness ORAS use" >&2
  exit 1
fi

for bound in '--connect-timeout 10' '--max-time 60' '--retry 2' '--retry-delay 2' '--retry-max-time 180'; do
  bound_mutant="$TEST_ROOT/bound-${bound//[^[:alnum:]]/_}.sh"
  case "$bound" in
    '--connect-timeout 10') replacement='--connect-timeout 0' ;;
    '--max-time 60') replacement='--max-time 0' ;;
    '--retry 2') replacement='--retry 3' ;;
    '--retry-delay 2') replacement='--retry-delay 3' ;;
    '--retry-max-time 180') replacement='--retry-max-time 0' ;;
  esac
  sed "s/$bound/$replacement/" "$fixture_block" >"$bound_mutant"
  if run_provision "$bound_mutant" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"; then
    echo "bounds: removed $bound was not rejected" >&2
    exit 1
  fi
  assert_no_writer_events "$FIXTURE/events"
done

echo "ORAS bound mutants passed"
timeout_mutant="$TEST_ROOT/exhausted-read.sh"
cp -- "$fixture_block" "$timeout_mutant"
ORAS_CURL_MODE=timeout ORAS_VERSION_MODE=good ORAS_TAR_MODE=normal \
  assert_provision_failure "exhausted-read" "$timeout_mutant" "$FIXTURE" "$TEST_ROOT/workspace" "$TEST_ROOT/runner-temp"
! grep -Eq '^(checksum-success|extraction-start|version-probe)$' "$FIXTURE/events"

echo "ORAS exhausted-read mutant passed"
inside_workspace="$fixture_block"
mkdir -p "$TEST_ROOT/workspace/runner-temp"
containment_stderr="$TEST_ROOT/containment.stderr"
if run_provision "$inside_workspace" "$FIXTURE" "$TEST_ROOT/workspace" \
  "$TEST_ROOT/workspace/runner-temp" 2>"$containment_stderr"; then
  echo "workspace containment: runner temp inside checkout was accepted" >&2
  exit 1
fi
grep -Fxq 'runner temp must be outside checkout' "$containment_stderr" || {
  echo "workspace containment: rejection did not come from the containment guard" >&2
  exit 1
}
! grep -Fq download "$FIXTURE/events"

echo "ORAS workspace containment mutant passed"

move_provision_after() {
  local source=$1
  local target_marker=$2
  local output=$3
  local provision_block="$TEST_ROOT/provision-step.yml"
  local without_provision="$TEST_ROOT/workflow-without-provision.yml"
  awk '
    $0 == "      - id: provision-oras" { in_step=1 }
    in_step && $0 == "      - id: protected-before" { exit }
    in_step { print }
  ' "$source" >"$provision_block"
  awk '
    $0 == "      - id: provision-oras" { in_step=1; next }
    in_step && $0 == "      - id: protected-before" { in_step=0 }
    !in_step { print }
  ' "$source" >"$without_provision"
  awk -v marker="$target_marker" -v block="$provision_block" '
    BEGIN {
      while ((getline line < block) > 0) {
        provision_lines[++count] = line
      }
      close(block)
    }
    $0 == marker {
      print
      in_target=1
      next
    }
    in_target && $0 ~ /^      - / {
      for (i = 1; i <= count; i++) print provision_lines[i]
      in_target=0
    }
    { print }
    END {
      if (in_target) {
        for (i = 1; i <= count; i++) print provision_lines[i]
      }
    }
  ' "$without_provision" >"$output"
}

for mutation in duplicate missing bypass after-publish after-attestation; do
  workflow_mutant="$TEST_ROOT/workflow-$mutation.yml"
  cp -- "$WORKFLOW" "$workflow_mutant"
  case "$mutation" in
    duplicate) sed '/^      - id: provision-oras$/a\      - id: provision-oras' "$workflow_mutant" >"$workflow_mutant.tmp" ;;
    missing) sed '/^      - id: provision-oras$/,/^      - id: protected-before$/d' "$workflow_mutant" >"$workflow_mutant.tmp" ;;
    bypass) sed '/^        timeout-minutes: 5$/a\        continue-on-error: true' "$workflow_mutant" >"$workflow_mutant.tmp" ;;
    after-publish)
      move_provision_after "$workflow_mutant" '      - id: publish' "$workflow_mutant.tmp"
      ;;
    after-attestation)
      move_provision_after "$workflow_mutant" \
        '        name: Create signed OCI attestation for a first-time alias' \
        "$workflow_mutant.tmp"
      ;;
  esac
  mv -- "$workflow_mutant.tmp" "$workflow_mutant"
  mutation_stderr="$TEST_ROOT/$mutation.stderr"
  if workflow_contract "$workflow_mutant" "$TEST_ROOT/mutant-block" "$workflow_metadata" \
    2>"$mutation_stderr"; then
    echo "$mutation: structural oracle accepted mutation" >&2
    exit 1
  fi
  case "$mutation" in
    after-publish)
      grep -Fxq 'workflow contract: provision step is after publish' "$mutation_stderr" || {
        echo "after-publish: missing reason-specific rejection" >&2
        exit 1
      }
      ;;
    after-attestation)
      grep -Fxq 'workflow contract: provision step is after attestation' "$mutation_stderr" || {
        echo "after-attestation: missing reason-specific rejection" >&2
        exit 1
      }
      ;;
  esac
done

for mutation in bare empty wrong platform guessed-tag extra-source; do
  workflow_mutant="$TEST_ROOT/workflow-selector-$mutation.yml"
  cp -- "$WORKFLOW" "$workflow_mutant"
  case "$mutation" in
    bare)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
    empty)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout@" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
    wrong)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
    platform)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout@$local_platform_digest" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
    guessed-tag)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout:test" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
    extra-source)
      sed 's#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref"#oras cp --from-oci-layout "$layout@$local_root_digest" "$ref" "$ref"#' \
        "$workflow_mutant" >"$workflow_mutant.tmp"
      ;;
  esac
  mv -- "$workflow_mutant.tmp" "$workflow_mutant"
  mutation_stderr="$TEST_ROOT/selector-$mutation.stderr"
  if workflow_contract "$workflow_mutant" "$TEST_ROOT/mutant-block" "$workflow_metadata" \
    2>"$mutation_stderr"; then
    echo "$mutation: selector structural oracle accepted mutation" >&2
    exit 1
  fi
  grep -Fxq 'workflow contract: copy source must select admitted root digest' "$mutation_stderr" || {
    echo "$mutation: missing reason-specific selector rejection" >&2
    exit 1
  }
done

alias_mutant="$TEST_ROOT/workflow-selector-alias.yml"
sed 's#ref="$IMAGE:$alias"#ref="$IMAGE:guessed-tag"#' "$WORKFLOW" >"$alias_mutant"
if workflow_contract "$alias_mutant" "$TEST_ROOT/mutant-block" "$workflow_metadata" \
  >"$TEST_ROOT/alias.stdout" 2>"$TEST_ROOT/alias.stderr"; then
  echo "changed-alias: structural oracle accepted mutation" >&2
  exit 1
fi
grep -Fxq 'workflow contract: source-derived alias changed' "$TEST_ROOT/alias.stderr"

copy_before_layout="$TEST_ROOT/workflow-selector-copy-before-layout.yml"
awk '
  /^            oras cp --from-oci-layout "\$layout@\$local_root_digest" "\$ref"$/ { next }
  /^            scripts\/verify-test-promotion-layout\.sh/ {
    print "            oras cp --from-oci-layout \"$layout@$local_root_digest\" \"$ref\""
  }
  { print }
' "$WORKFLOW" >"$copy_before_layout"
if workflow_contract "$copy_before_layout" "$TEST_ROOT/mutant-block" "$workflow_metadata" \
  >"$TEST_ROOT/copy-before-layout.stdout" 2>"$TEST_ROOT/copy-before-layout.stderr"; then
  echo "copy-before-layout: structural oracle accepted mutation" >&2
  exit 1
fi
grep -Fxq 'workflow contract: copy precedes layout verification' "$TEST_ROOT/copy-before-layout.stderr"
echo "selector mutants passed: bare empty wrong platform guessed-tag extra-source; alias and copy-order rejection preserved"

incident_block="$TEST_ROOT/incident.sh"
extract_run_block "$WORKFLOW" '      - name: Build sanitized incident document' "$incident_block"
sed -i \
  -e 's/\${{ needs\.authorize\.result }}/success/g' \
  -e 's/\${{ needs\.admit-image\.result }}/failure/g' \
  -e 's/\${{ needs\.admit-image\.outputs\.registry_publication }}/unknown/g' \
  -e 's/\${{ needs\.admit-image\.outputs\.attestation_write }}/unknown/g' \
  -e 's/\${{ needs\.admit-image\.outputs\.initial_alias_state }}/unknown/g' \
  -e 's/\${{ needs\.deploy\.result }}/skipped/g' \
  -e 's/\${{ needs\.deploy\.outputs\.mutation_started }}/false/g' \
  -e 's/\${{ needs\.deploy\.outputs\.rollback_attempted }}/false/g' \
  -e 's/\${{ needs\.deploy\.outputs\.rollback_verified }}/false/g' \
  "$incident_block"
run_incident_contract "$incident_block" "$TEST_ROOT/incident"

bash "$ROOT_DIR/scripts/test-test-promotion-input.sh"
echo "dev promotion workflow fixture passed: ORAS readiness, ordering, bounds, incident and retention contracts"
