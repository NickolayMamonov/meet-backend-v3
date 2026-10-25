#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
WORKFLOW=$ROOT_DIR/.github/workflows/configure-test-vps-timepad-token.yml
TMP=$(mktemp -d)
trap 'rm -r -- "$TMP"' EXIT
workflow=$(sed 's/\r$//' "$WORKFLOW")

fail() {
  echo "LocationIQ workflow fixture failed: $*" >&2
  exit 1
}

require_text() {
  local expected=$1 source=$2
  grep -Fq -- "$expected" <<<"$source" || fail "missing workflow contract: $expected"
}

reject_text() {
  local unexpected=$1 source=$2
  if grep -Fq -- "$unexpected" <<<"$source"; then
    fail "forbidden workflow contract present: $unexpected"
  fi
}

step_block() {
  local name=$1
  awk -v marker="      - name: $name" '
    $0 == marker { in_step=1 }
    in_step && /^      - name: / && $0 != marker { exit }
    in_step { print }
  ' "$WORKFLOW"
}

step_run() {
  awk '
    /^        run: \|$/ { in_run=1; next }
    in_run && /^        [^ ]/ { exit }
    in_run {
      sub(/^          /, "")
      print
    }
  ' <<<"$1"
}

require_text 'workflow_dispatch:' "$workflow"
require_text 'type: choice' "$workflow"
require_text 'default: timepad-token' "$workflow"
require_text '- timepad-token' "$workflow"
require_text '- locationiq-diagnostic' "$workflow"
require_text '- locationiq-delivery-off' "$workflow"
require_text "if: github.ref == 'refs/heads/dev'" "$workflow"
require_text 'name: test-vps' "$workflow"
require_text 'test-vps-deploy-${{ github.repository }}' "$workflow"
require_text 'cancel-in-progress: false' "$workflow"
require_text 'timeout-minutes: 5' "$workflow"
require_text 'ref: ${{ github.sha }}' "$workflow"
require_text 'StrictHostKeyChecking yes' "$workflow"

validation=$(step_block 'Validate requested operation')
ssh_trust=$(step_block 'Establish strict SSH host trust')
stage=$(step_block 'Stage selected reviewed helper and shared trust module')
timepad=$(step_block 'Probe credential and configure only the token')
diagnostic=$(step_block 'Run LocationIQ fixture diagnostic only')
delivery=$(step_block 'Configure LocationIQ delivery OFF')
cleanup=$(step_block 'Remove exact staged tooling')
runner_cleanup=$(step_block 'Remove runner SSH material')
for name in validation ssh_trust stage timepad diagnostic delivery cleanup runner_cleanup; do
  [ -n "${!name}" ] || fail "missing workflow step: $name"
done

line_of() {
  grep -n -m1 -F -- "$1" "$WORKFLOW" | cut -d: -f1
}
validation_line=$(line_of 'name: Validate requested operation')
ssh_line=$(line_of 'name: Establish strict SSH host trust')
stage_line=$(line_of 'name: Stage selected reviewed helper and shared trust module')
timepad_line=$(line_of 'name: Probe credential and configure only the token')
diagnostic_line=$(line_of 'name: Run LocationIQ fixture diagnostic only')
delivery_line=$(line_of 'name: Configure LocationIQ delivery OFF')
[ "$validation_line" -lt "$ssh_line" ] &&
  [ "$validation_line" -lt "$stage_line" ] &&
  [ "$validation_line" -lt "$timepad_line" ] &&
  [ "$validation_line" -lt "$diagnostic_line" ] &&
  [ "$validation_line" -lt "$delivery_line" ] ||
  fail "mode validation must precede SSH setup, staging, and secret-bearing steps"

validation_run=$(step_run "$validation")
printf '%s\n' "$validation_run" >"$TMP/validate-mode.sh"
for mode in '' timepad-token locationiq-diagnostic locationiq-delivery-off; do
  output=$TMP/mode-output
  : >"$output"
  GITHUB_OUTPUT=$output REQUESTED_MODE=$mode bash "$TMP/validate-mode.sh"
  grep -Fxq "mode=${mode:-timepad-token}" "$output" || fail "mode was not accepted: $mode"
done
output=$TMP/mode-output
: >"$output"
if GITHUB_OUTPUT=$output REQUESTED_MODE=unexpected bash "$TMP/validate-mode.sh" \
  >"$TMP/invalid.stdout" 2>"$TMP/invalid.stderr"; then
  fail "unknown operation mode was accepted"
fi
[ ! -s "$output" ] || fail "invalid mode emitted a selected mode"
grep -Fq 'unsupported operation mode' "$TMP/invalid.stderr" ||
  fail "invalid mode rejection is not explicit"
require_text 'mode=${REQUESTED_MODE:-timepad-token}' "$validation_run"
require_text 'timepad-token|locationiq-diagnostic|locationiq-delivery-off' "$validation_run"
reject_text '${{ inputs.mode }}' "$validation_run"

for mode in timepad-token locationiq-diagnostic locationiq-delivery-off; do
  case "$mode" in
    timepad-token) guarded_step=$timepad ;;
    locationiq-diagnostic) guarded_step=$diagnostic ;;
    locationiq-delivery-off) guarded_step=$delivery ;;
  esac
  require_text "if: steps.operation.outputs.mode == '$mode'" "$guarded_step"
done
require_text 'TIMEPAD_TOKEN: ${{ secrets.TIMEPAD_TOKEN }}' "$timepad"
require_text 'LOCATIONIQ_KEY: ${{ secrets.LOCATIONIQ_KEY }}' "$diagnostic"
require_text "if: steps.operation.outputs.mode == 'locationiq-delivery-off'" "$delivery"
require_text 'LOCATIONIQ_KEY: ${{ secrets.LOCATIONIQ_KEY }}' "$delivery"
reject_text 'LOCATIONIQ_KEY' "$timepad"
reject_text 'TIMEPAD_TOKEN' "$diagnostic"
reject_text 'TIMEPAD_TOKEN' "$delivery"
[ "$(grep -Fc '${{ secrets.TIMEPAD_TOKEN }}' <<<"$workflow")" -eq 1 ] ||
  fail "Timepad secret must be referenced only in its guarded mode"
[ "$(grep -Fc '${{ secrets.LOCATIONIQ_KEY }}' <<<"$workflow")" -eq 2 ] ||
  fail "LocationIQ secret must appear only in the two selected modes"
require_text 'secrets.LOCATIONIQ_KEY' "$diagnostic"
require_text 'secrets.LOCATIONIQ_KEY' "$delivery"
reject_text 'TIMEPAD_TOKEN' "$stage"
reject_text 'LOCATIONIQ_KEY' "$stage"

stage_run=$(step_run "$stage")
require_text 'timepad-token)' "$stage_run"
require_text 'locationiq-diagnostic)' "$stage_run"
require_text 'locationiq-delivery-off)' "$stage_run"
require_text 'scripts/configure-test-vps-timepad-token.py' "$stage_run"
require_text 'scripts/diagnose-test-vps-locationiq.py' "$stage_run"
require_text 'scripts/configure-test-vps-locationiq.py' "$stage_run"
require_text 'stage_file scripts/test_vps_file_trust.py test_vps_file_trust.py' "$stage_run"
require_text 'checksum=$(sha256sum "$source" | awk' "$stage_run"
require_text 'sha256sum --status -c -' "$stage_run"
require_text 'timeout 20s scp' "$stage_run"
require_text 'timeout 20s ssh' "$stage_run"
require_text 'test-vps-deploy-${{ github.repository }}' "$workflow"

timepad_run=$(step_run "$timepad")
require_text 'printf '\''%s'\'' "$TIMEPAD_TOKEN" | timeout 60s ssh' "$timepad_run"
require_text 'PYTHONDONTWRITEBYTECODE=1 timeout 50s python3' "$timepad_run"
require_text 'configure-test-vps-timepad-token.py' "$timepad_run"
reject_text 'LOCATIONIQ' "$timepad_run"

diagnostic_run=$(step_run "$diagnostic")
require_text '[ -n "$LOCATIONIQ_KEY" ]' "$diagnostic_run"
require_text 'printf '\''%s'\'' "$LOCATIONIQ_KEY" |' "$diagnostic_run"
require_text 'timeout --signal=TERM --kill-after=2s 48s ssh' "$diagnostic_run"
require_text 'ulimit -c 0' "$diagnostic_run"
require_text 'PYTHONDONTWRITEBYTECODE=1 timeout --signal=TERM --kill-after=2s 45s python3' \
  "$diagnostic_run"
require_text 'diagnose-test-vps-locationiq.py' "$diagnostic_run"
reject_text 'TIMEPAD_TOKEN' "$diagnostic_run"
reject_text 'GITHUB_ENV' "$diagnostic_run"
reject_text 'GITHUB_OUTPUT' "$diagnostic_run"
reject_text 'GITHUB_STEP_SUMMARY' "$diagnostic_run"
reject_text 'upload-artifact' "$workflow"
require_text 'set +x' "$(step_run "$ssh_trust")"
require_text 'set +x' "$(step_run "$timepad")"
require_text 'set +x' "$(step_run "$diagnostic")"
reject_text 'docker compose' "$diagnostic_run"
reject_text 'timepad.ru' "$diagnostic_run"

delivery_run=$(step_run "$delivery")
require_text '[ -n "$LOCATIONIQ_KEY" ]' "$delivery_run"
require_text 'printf '\''%s'\'' "$LOCATIONIQ_KEY" |' "$delivery_run"
require_text 'timeout --signal=TERM --kill-after=2s 48s ssh' "$delivery_run"
require_text 'ulimit -c 0' "$delivery_run"
require_text 'PYTHONDONTWRITEBYTECODE=1 timeout --signal=TERM --kill-after=2s 45s python3' \
  "$delivery_run"
require_text 'configure-test-vps-locationiq.py' "$delivery_run"
reject_text 'TIMEPAD_TOKEN' "$delivery_run"
reject_text 'docker compose' "$delivery_run"
reject_text 'timepad.ru' "$delivery_run"
reject_text 'GITHUB_ENV' "$delivery_run"
reject_text 'GITHUB_OUTPUT' "$delivery_run"
reject_text 'GITHUB_STEP_SUMMARY' "$delivery_run"
require_text 'set +x' "$delivery_run"

cleanup_run=$(step_run "$cleanup")
require_text 'always()' "$cleanup"
require_text 'HELPER: ${{ steps.stage.outputs.helper }}' "$cleanup"
require_text 'STAGE: ${{ steps.stage.outputs.stage }}' "$cleanup"
require_text 'configure-test-vps-timepad-token.py|diagnose-test-vps-locationiq.py|configure-test-vps-locationiq.py' \
  "$cleanup_run"
require_text "\$STAGE/\$HELPER" "$cleanup_run"
require_text "\$STAGE/test_vps_file_trust.py" "$cleanup_run"
require_text 'rmdir --' "$cleanup_run"
require_text 'timeout 20s ssh' "$cleanup_run"
reject_text 'rm -rf' "$cleanup_run"
require_text 'if: always()' "$runner_cleanup"

printf '%s\n' "$stage_run" >"$TMP/stage.sh"
printf '%s\n' "$timepad_run" >"$TMP/timepad.sh"
printf '%s\n' "$diagnostic_run" >"$TMP/diagnostic.sh"
printf '%s\n' "$delivery_run" >"$TMP/delivery.sh"
printf '%s\n' "$cleanup_run" >"$TMP/cleanup.sh"

# Execute the actual run blocks with local SSH/SCP doubles. No remote command,
# helper, provider or credential is used; only this fixture's mktemp tree changes.
ssh() {
  local command=${!#}
  if [[ "$*" == *'test-vps python3 -' ]]; then
    command cat >/dev/null
    mkdir "$MOCK_REMOTE"
    printf '%s\n' "$FIXTURE_STAGE"
    echo stage >>"$MOCK_LOG"
  elif [[ "$command" == *'sha256sum --status -c -'* ]]; then
    [ "$MOCK_FAIL" != checksum ] || return 42
    echo checksum >>"$MOCK_LOG"
    command=${command//"$FIXTURE_STAGE"/"$MOCK_REMOTE"}
    bash -c "$command"
  elif [[ "$command" == 'rm -f -- '* ]]; then
    echo cleanup >>"$MOCK_LOG"
    [ "$MOCK_FAIL" != cleanup ] || return 43
    command=${command//"$FIXTURE_STAGE"/"$MOCK_REMOTE"}
    bash -c "$command"
  elif [[ "$command" == *'python3 '* ]]; then
    local key
    key=$(command cat)
    [ "$key" = "$FIXTURE_KEY" ] || return 44
    [[ "$command" != *"$FIXTURE_KEY"* ]] || return 45
    if grep -RqF "$FIXTURE_KEY" "$MOCK_REMOTE"; then return 46; fi
    echo helper >>"$MOCK_LOG"
    case "$MOCK_FAIL" in helper) return 47 ;; timeout) return 124 ;; esac
    printf '%s\n' '{"mock":"helper_completed"}'
  else
    echo "unexpected mocked SSH command" >&2
    return 48
  fi
}
scp() {
  local source_index=$(($# - 1)) source target=${!#}
  source=${!source_index}
  [ "$MOCK_FAIL" != transfer ] || return 49
  if [ "$MOCK_FAIL" = module-transfer ] && [[ "$source" == *test_vps_file_trust.py ]]; then
    return 49
  fi
  cp "$source" "$MOCK_REMOTE/${target##*/}"
  echo transfer >>"$MOCK_LOG"
}
timeout() {
  while [[ "$1" == --* ]]; do shift; done
  shift
  "$@"
}
export -f ssh scp timeout
export FIXTURE_STAGE=/opt/meet-backend/.timepad-token-config.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export FIXTURE_KEY=MOCK-KEY-NOT-A-REAL-SECRET-123
export SSH_CONFIG="$TMP/mock-ssh-config"
touch "$SSH_CONFIG"

for mode in timepad-token locationiq-diagnostic locationiq-delivery-off; do
  for failure in none transfer module-transfer checksum helper timeout cleanup; do
    case_dir="$TMP/$mode-$failure"
    mkdir "$case_dir"
    export MOCK_REMOTE="$case_dir/stage" MOCK_LOG="$case_dir/log" MOCK_FAIL=$failure
    export GITHUB_OUTPUT="$case_dir/output" MODE=$mode
    : >"$GITHUB_OUTPUT"
    : >"$MOCK_LOG"
    stage_status=0
    (cd "$ROOT_DIR"; bash "$TMP/stage.sh") >"$case_dir/stage.stdout" 2>"$case_dir/stage.stderr" ||
      stage_status=$?
    export HELPER STAGE
    HELPER=$(sed -n 's/^helper=//p' "$GITHUB_OUTPUT")
    STAGE=$(sed -n 's/^stage=//p' "$GITHUB_OUTPUT")
    [ "$STAGE" = "$FIXTURE_STAGE" ] || fail "stage must be known before transfers"
    case "$mode" in
      timepad-token) [ "$HELPER" = configure-test-vps-timepad-token.py ] ;;
      locationiq-diagnostic) [ "$HELPER" = diagnose-test-vps-locationiq.py ] ;;
      locationiq-delivery-off) [ "$HELPER" = configure-test-vps-locationiq.py ] ;;
    esac || fail "selected mode staged the wrong helper"
    if [ "$stage_status" -eq 0 ]; then
      [ "$(grep -c '^checksum$' "$MOCK_LOG")" -eq 2 ] ||
        fail "helper and module must both be checksum verified"
      expected_files=$(printf '%s\n' "$HELPER" test_vps_file_trust.py | sort)
      staged_files=$(find "$MOCK_REMOTE" -maxdepth 1 -type f -printf '%f\n' | sort)
      [ "$staged_files" = "$expected_files" ] ||
        fail "only the selected helper and shared trust module may be staged"
      if [ "$mode" = timepad-token ]; then
        operation="$TMP/timepad.sh"
      elif [ "$mode" = locationiq-delivery-off ]; then
        operation="$TMP/delivery.sh"
      else
        operation="$TMP/diagnostic.sh"
      fi
      operation_status=0
      if [ "$mode" = timepad-token ]; then
        TIMEPAD_TOKEN=$FIXTURE_KEY bash "$operation" \
          >"$case_dir/helper.stdout" 2>"$case_dir/helper.stderr" || operation_status=$?
      else
        LOCATIONIQ_KEY=$FIXTURE_KEY bash "$operation" \
          >"$case_dir/helper.stdout" 2>"$case_dir/helper.stderr" || operation_status=$?
      fi
      case "$failure" in
        helper|timeout) [ "$operation_status" -ne 0 ] || fail "helper failure was hidden" ;;
        *) [ "$operation_status" -eq 0 ] || fail "mock operation unexpectedly failed" ;;
      esac
    else
      case "$failure" in transfer|module-transfer|checksum) ;; *)
        fail "unexpected staging failure" ;;
      esac
      reject_text helper "$(<"$MOCK_LOG")"
    fi
    cleanup_status=0
    bash "$TMP/cleanup.sh" >"$case_dir/cleanup.stdout" 2>"$case_dir/cleanup.stderr" ||
      cleanup_status=$?
    if [ "$failure" = cleanup ]; then
      [ "$cleanup_status" -ne 0 ] && [ -d "$MOCK_REMOTE" ] ||
        fail "cleanup failure must remain visible"
    else
      [ "$cleanup_status" -eq 0 ] && [ ! -e "$MOCK_REMOTE" ] ||
        fail "exact staged helper and module were not cleaned"
    fi
    if grep -RqF "$FIXTURE_KEY" "$case_dir"; then
      fail "mock credential persisted in staging or output"
    fi
  done
done

echo "LocationIQ diagnostic workflow fixture passed"
