#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
deploy=scripts/deploy-test-vps-provider-release.sh
tmp=$(mktemp -d)
cleanup() {
  local status=$?
  trap - EXIT
  rm -r -- "$tmp"
  exit "$status"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

reject_manual_drill_before_mutation() {
  local output status
  set +e
  output=$(
    bash "$deploy" \
      --root /tmp \
      --base-compose /tmp/compose.yml \
      --image "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$(printf 'a%.0s' {1..64})" \
      --revision "$(printf 'b%.0s' {1..40})" \
      --version 1.2.0 \
      --run-key manual-stop-fixture \
      --mode rollback-drill \
      --failure-policy manual-stop 2>&1
  )
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "manual-stop rollback drill unexpectedly succeeded"
  [[ "$output" == *"manual-stop failure policy does not permit rollback-drill"* ]] ||
    fail "manual-stop rollback drill was not rejected by preflight"
  ! grep -Eq 'manual_intervention_required|backend_stop=' <<<"$output" ||
    fail "rollback drill rejection happened after mutation handling"
}

run_exit_case() {
  local name=$1 policy=$2 fail_kind=$3 stop_fails=$4 signal_name=${5:-}
  local log="$tmp/$name.log" output status
  : >"$log"
  set +e
  local shell_case='
    source "$1"
    failure_policy=${2:-automatic-rollback}
    mutation_started=true
    rollback_complete=false
    credential_prepared=false
    compose() {
      printf "compose %s\n" "$*" >>"$CASE_LOG"
      [ "${STOP_FAILS:-false}" != true ]
    }
    rollback() {
      printf "rollback called\n" >>"$CASE_LOG"
      return 0
    }
    trap provider_release_on_exit EXIT
    trap "exit 143" TERM INT HUP
    case "$3" in
      startup) exit 21 ;;
      health) exit 22 ;;
      signal) while :; do sleep 1; done ;;
    esac
  '
  if [ -n "$signal_name" ]; then
    CASE_LOG="$log" STOP_FAILS="$stop_fails" python3 - \
      "$signal_name" "$deploy" "$policy" "$fail_kind" "$shell_case" \
      >"$tmp/$name.stdout" 2>"$tmp/$name.stderr" <<'PY'
import os
import signal
import subprocess
import sys
import time

signal_name, deploy, policy, failure_kind, shell_case = sys.argv[1:]
signal_number = getattr(signal, f"SIG{signal_name}")

def restore_signals():
    for candidate in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(candidate, signal.SIG_DFL)

process = subprocess.Popen(
    ["bash", "-c", shell_case, "_", deploy, policy, failure_kind],
    env=os.environ.copy(),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    preexec_fn=restore_signals,
)
time.sleep(0.2)
os.kill(process.pid, signal_number)
stdout, stderr = process.communicate(timeout=10)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
sys.exit(process.returncode)
PY
    status=$?
  else
    CASE_LOG="$log" STOP_FAILS="$stop_fails" bash -c "$shell_case" \
      _ "$deploy" "$policy" "$fail_kind" \
      >"$tmp/$name.stdout" 2>"$tmp/$name.stderr"
    status=$?
  fi
  set -e
  output=$(<"$tmp/$name.stderr")

  [ "$status" -ne 0 ] || fail "$name unexpectedly returned success"
  if [ "$policy" = manual-stop ]; then
    grep -Fxq 'compose stop backend' "$log" ||
      fail "$name did not stop the backend through Compose"
    ! grep -Fxq 'rollback called' "$log" ||
      fail "$name invoked automatic rollback"
    [[ "$output" == *"manual_intervention_required=true"* ]] ||
      fail "$name omitted manual intervention status"
    ! grep -Eq 'rollback=completed|rollback completed|previous_image_id=' \
      <<<"$output" ||
      fail "$name claimed predecessor restoration"
    if [ "$stop_fails" = true ]; then
      [[ "$output" == *"backend_stop=failed"* ]] ||
        fail "$name hid failed backend stop"
      [ "$status" -eq 1 ] ||
        fail "$name did not fail after failed backend stop"
    else
      [[ "$output" == *"backend_stop=completed"* ]] ||
        fail "$name did not report completed backend stop"
    fi
  else
    grep -Fxq 'rollback called' "$log" ||
      fail "$name did not preserve legacy automatic rollback"
    ! grep -q '^compose ' "$log" ||
      fail "$name unexpectedly used manual-stop handling"
  fi
}

reject_manual_drill_before_mutation
run_exit_case manual-startup-failure manual-stop startup false
run_exit_case manual-health-failure manual-stop health false
run_exit_case manual-stop-failure manual-stop startup true
grep -Fq 'failure_policy=automatic-rollback' "$deploy" ||
  fail "provider script no longer defaults to automatic rollback"
run_exit_case legacy-default '' startup false
if [ "$(uname -s)" = Linux ]; then
  for signal_name in TERM INT HUP; do
    run_exit_case "manual-signal-$signal_name" manual-stop signal false "$signal_name"
  done
else
  echo "timepad_manual_stop_signals=environment-blocked (Linux-only signal lifecycle proof)"
fi

echo "timepad_manual_stop=passed"
