#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(pwd -P)
cd "$ROOT_DIR"

fail() {
  echo "ASSERTION_FAIL: $*" >&2
  exit 1
}

assert_empty_directory() {
  local entry
  entry=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit) || return 1
  [ -z "$entry" ]
}

assert_tmpfs() {
  local target
  target=$(readlink -f "$1") || return 1
  awk -v path="$target" '
    $5 == path {
      found = 1
      for (i = 7; i <= NF; i++) {
        if ($i == "-") {
          filesystem = $(i + 1)
          break
        }
      }
    }
    END { exit !(found && filesystem == "tmpfs") }
  ' /proc/self/mountinfo
}

for path in /var/lib /tmp /run /var/run; do
  assert_tmpfs "$path" || {
    echo "fixture did not receive a fresh $path tmpfs" >&2
    exit 1
  }
  assert_empty_directory "$path" || {
    echo "fixture $path is not fresh" >&2
    exit 1
  }
done
[ -z "${DOCKER_HOST:-}" ] || {
  echo "fixture must not use a Docker host" >&2
  exit 1
}
[ ! -S /run/docker.sock ] && [ ! -S /var/run/docker.sock ] || {
  echo "fixture can see a Docker socket" >&2
  exit 1
}
awk 'NR > 1 { exit 1 }' /proc/net/route &&
  awk 'NF { if (NF != 10 || $10 != "lo") bad = 1 } END { exit bad }' /proc/net/ipv6_route || {
  echo "fixture network namespace has a route" >&2
  exit 1
}

controller=scripts/deploy-test-vps-provider-release.sh
[ -f "$controller" ] && [ ! -L "$controller" ] || {
  echo "actual deployment controller is unavailable" >&2
  exit 1
}
bash_path=$(command -v bash)
safe_path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fixture_bin=$ROOT_DIR/scripts/fixtures/timepad-controller
runtime_bin=/var/lib/timepad-fixture/bin
state_root=/var/lib/timepad-fixture/state
root=/var/lib/timepad-fixture/root
base_compose=/var/lib/timepad-fixture/compose.yml
docker_log=/var/lib/timepad-fixture/docker.log
install -d -m 700 "$root" "$state_root"
install -m 600 "$fixture_bin/root-env" "$root/.env.production"
install -m 600 "$fixture_bin/compose.yml" "$root/docker-compose.production.yml"
install -m 600 "$root/docker-compose.production.yml" "$base_compose"
install -d -m 700 "$runtime_bin"
install -m 700 "$fixture_bin/docker" "$fixture_bin/curl" "$runtime_bin"
export DOCKER_HOST=
export TIMEPAD_FIXTURE_DOCKER_LOG=$docker_log
export TEST_VPS_STATE_ROOT=$state_root
export TIMEPAD_FIXTURE_ADAPTER_DIR=$fixture_bin
export PATH="$runtime_bin:$safe_path"
export PYTHONDONTWRITEBYTECODE=1
controller_create_contracts() {
  # Portable function contracts complement, never replace, the actual isolated
  # controller/supervisor rows below. Only external proof/runtime calls are fake.
  python3 -B - "$controller" <<'PY'
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
def function(name):
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)
    if match is None:
        raise AssertionError(name)
    return match.group()

class CreateControllerContracts(unittest.TestCase):
    def bash(self):
        if os.name == "nt":
            return str(pathlib.Path(os.environ["ProgramFiles"]) / "Git/bin/bash.exe")
        return shutil.which("bash")

    def test_binding_delegates_to_fixed_authenticated_driver_action(self):
        script = r"""
set -euo pipefail
timepad_create_action() {
  [ "$*" = "reconcile-bound initial" ] || return 90
  jq -cn '{containerId:("c" * 64),configHash:("d" * 64)}'
}
"""
        script += function("timepad_request_bind_create")
        script += r"""
timepad_request_bind_create
jq -en --arg id "$candidate_container" --arg hash "$target_hash" \
  '$id == ("c" * 64) and $hash == ("d" * 64)' >/dev/null
"""
        result = subprocess.run([self.bash(), "-s"], input=script, text=True, capture_output=True, timeout=60)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)
        self.assertEqual("", result.stderr)

    def test_binding_and_child_intent_are_single_state_publications(self):
        for role in ("initial", "replacement"):
            for lifecycle in ("intent", "bound"):
                request = {
                    "operation": "create", "role": role, "lifecycle": lifecycle,
                    "childAttemptId": "a" * 32 + ":1", "containerId": "b" * 64,
                    "configHash": "c" * 64,
                }
                child = {"attemptId": request["childAttemptId"], "lifecycle": "waiting"}
                with self.subTest(role=role, lifecycle=lifecycle), tempfile.TemporaryDirectory() as temporary:
                    result = subprocess.run([self.bash(), "-s", "--",
                        pathlib.Path(temporary).as_posix(), json.dumps(request), json.dumps(child)],
                        input=r"""
set -euo pipefail
state=$1
state_root=fixture-root
timepad_helper=fixture-state
timeout() {
  case "$4" in
    read-state) echo '{"current":{"phase":"FORWARD_RECOVERING"}}' ;;
    advance) jq -c . "$state/.timepad-request-changes.json" >&2 ;;
    *) return 90 ;;
  esac
}
""" + function("timepad_request_publish") + '\ntimepad_request_publish "$2" "$3"\n',
                        text=True, capture_output=True, timeout=60)
                    self.assertEqual(0, result.returncode, result.stderr)
                    changes = json.loads(result.stderr)["changes"]
                    self.assertEqual(request, changes["runtimeRequest"])
                    if lifecycle == "intent":
                        self.assertEqual(child, changes["ownedChild"])
                        self.assertEqual(request["childAttemptId"], changes["latestAttemptId"])
                        self.assertNotIn("containerId", changes)
                    else:
                        self.assertEqual(request["containerId"], changes["containerId"])
                        self.assertEqual(request["configHash"], changes["configHash"])
                        self.assertNotIn("ownedChild", changes)
                        if role == "replacement":
                            self.assertEqual("replacement-container-authorized", changes["commitSubstep"])
                        else:
                            self.assertNotIn("commitSubstep", changes)

unittest.main(argv=[sys.argv[0]])
PY
}
controller_create_contracts
timeout --kill-after=5s 120s python3 -B scripts/test-test-vps-timepad-create.py
timeout --kill-after=5s 600s python3 -B "$fixture_bin/resource-matrix.py"
timeout --kill-after=5s 600s python3 -B "$fixture_bin/admission-cancellation.py" bootstrap
timeout --kill-after=5s 360s python3 -B "$fixture_bin/admission-cancellation.py" cancellation
common_args=(
  --root "$root"
  --base-compose "$base_compose"
  --image "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$(printf '%064d' 0)"
  --revision 0000000000000000000000000000000000000000
  --version 1.4.1
  --run-key fixture-run-1
)

assert_refusal() {
  local reason=$1
  shift
  local output status before
  before=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  if output=$(timeout 30s "$bash_path" "$controller" \
    "${common_args[@]}" "$@" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  local after
  after=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  [ "$status" -eq 1 ] &&
    { [ "$output" = "test VPS deployment failed: $reason" ] ||
      [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ]; } &&
    [ "$after" = "$before" ] || {
    fail "controller refusal contract expected=$reason status=$status"
  }
}

assert_usage_refusal() {
  local expected=$1
  shift
  local output status before after
  before=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  if output=$(timeout 30s "$bash_path" "$controller" \
    "${common_args[@]}" "$@" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  after=$(if [ -f "$docker_log" ]; then sha256sum "$docker_log" | awk '{print $1}'; fi)
  { [ "$status" -eq 2 ] && [ "$output" = "$expected" ] ||
    [ "$status" -eq 1 ] && [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ]; } &&
    [ "$after" = "$before" ] || {
    fail "controller argument refusal expected=$expected status=$status"
  }
}

assert_refusal ROLLBACK_DRILL_UNSAFE \
  --mode rollback-drill --operation deploy \
  --rollout-domain timepad-first-transition --initial-proof-id fixture-proof
assert_refusal BOOTSTRAP_AUTHORITY_REQUIRED \
  --mode deploy --operation bootstrap-guard \
  --initial-proof-id fixture-proof --bootstrap-id fixture-bootstrap
assert_refusal RECOVERY_AUTHORIZATION_REQUIRED \
  --mode deploy --operation forward-recover \
  --recovery-run-key fixture-run-0 \
  --recovery-incident 0123456789abcdef \
  --recovery-epoch 1 \
  --recovery-binding-digest "$(printf '%064d' 0)" \
  --recovery-action retry-exact-candidate
assert_usage_refusal \
  "usage: $controller --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--operation deploy|bootstrap-guard|forward-recover --rollout-domain initial-domain|timepad-first-transition --initial-proof-id ID --bootstrap-id ID --recovery-run-key KEY --recovery-incident ID --recovery-epoch N --recovery-binding-digest SHA256 --recovery-action retry-exact-candidate] [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" \
  --mode deploy --operation forward-recover \
  --recovery-run-key fixture-run-0 \
  --recovery-incident 0123456789abcdef \
  --recovery-epoch 1 \
  --recovery-binding-digest "$(printf '%064d' 0)" \
  --recovery-action retry-exact-candidate --bootstrap-id conflicting-bootstrap
assert_usage_refusal \
  "usage: $controller --root PATH --base-compose PATH --image IMAGE@sha256:DIGEST --revision SHA --version VERSION --run-key KEY --mode deploy|rollback-drill [--operation deploy|bootstrap-guard|forward-recover --rollout-domain initial-domain|timepad-first-transition --initial-proof-id ID --bootstrap-id ID --recovery-run-key KEY --recovery-incident ID --recovery-epoch N --recovery-binding-digest SHA256 --recovery-action retry-exact-candidate] [--closed-beta-safety --state-mode empty-closed|closed-beta-demo] [--public-url https://HOST]" \
  --mode deploy --operation deploy

[ ! -e "$docker_log" ] || fail "controller attempted to use the Docker boundary during refusal cases"
echo "CONTROLLER_REFUSAL_PASS: unsafe drill, missing bootstrap authority, missing recovery authorization"

echo "CONTROLLER_ARGUMENT_PASS: mixed recovery selectors and missing rollout domain"

recovery_case_number=0
assert_bound_recovery() {
  local phase=$1 fault=$2 expected=$3 starts=$4 proof=${5:-legacy}
  local case_dir output status before after allowed_start refusal_before=
  recovery_case_number=$((recovery_case_number + 1))
  case_dir=/var/lib/timepad-fixture/case-$recovery_case_number
  timeout 30s python3 -B "$fixture_bin/recovery.py" setup "$case_dir" "$phase" "$fault" "$proof"
  before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
  if { [ "$phase" = CUTOVER_POSSIBLE ] &&
    { [ "$fault" = foreign ] || [ "$fault" = foreign-provider ] ||
      [ "$fault" = missing ] || [ "$fault" = missing-request-proof ]; }; } ||
    { [ "$phase" = ROLLING_BACK ] &&
      { [ "$fault" = foreign ] || [ "$fault" = missing ] || [ "$fault" = missing-input ]; }; } ||
    { [ "$phase" = COMMITTING ] &&
      { [ "$fault" = unknown-inventory ] || [ "$fault" = create-intent ]; }; }; then
    refusal_before=$(timeout 10s python3 -B "$fixture_bin/recovery.py" refusal-snapshot "$case_dir")
  fi
  if [ "$fault" = foreign-provider ]; then
    # The helper owns the specific private diagnostic. The public relay keeps
    # its separate fixed, sanitized unconfirmed-quiescence contract.
    timeout 15s python3 -B "$fixture_bin/recovery.py" assert-foreign-provider "$case_dir"
  fi
  if [ "$phase" = CUTOVER_POSSIBLE ] &&
    { [ "$fault" = missing ] || [ "$fault" = missing-request-proof ]; }; then
    timeout 15s python3 -B "$fixture_bin/recovery.py" assert-missing "$case_dir"
  fi
  if [ "$proof" = request-proof ]; then
    timeout 10s python3 -B "$fixture_bin/recovery.py" assert-historical-request "$case_dir"
  fi
  if [ "$fault" = foreign ] || [ "$fault" = missing-input ]; then
    timeout 15s python3 -B "$fixture_bin/recovery.py" assert-bound-refusal "$case_dir"
  fi
  if [ "$fault" = unknown-inventory ]; then
    timeout 15s python3 -B "$fixture_bin/recovery.py" assert-unknown-inventory "$case_dir"
  fi
  export TIMEPAD_FIXTURE_CASE=$case_dir
  export TIMEPAD_FIXTURE_DOCKER_LOG=$case_dir/docker.log
  export TEST_VPS_STATE_ROOT=$case_dir/state
  local -a launch=("$bash_path")
  case "$fault" in
    active-child*)
      launch=(python3 -B "$fixture_bin/recovery.py" run-active "$case_dir" "$bash_path")
      ;;
  esac
  local -a recovery_command=("${launch[@]}" \
    "$case_dir/tools/deploy-test-vps-provider-release.sh" \
    --root "$case_dir/root" --base-compose "$case_dir/compose.yml" \
    --image "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:$(printf '1%.0s' {1..64})" \
    --revision "$(printf '3%.0s' {1..40})" --version 1.2.3 \
    --run-key fixture-dispatch --mode deploy --operation forward-recover \
    --recovery-run-key 31885558214-1 \
    --recovery-incident "$(printf 'd%.0s' {1..32})" --recovery-epoch 1 \
    --recovery-binding-digest "$(<"$case_dir/binding")" \
    --recovery-action retry-exact-candidate)
  if output=$(timeout --kill-after=5s 130s "${recovery_command[@]}" 2>&1)
  then
    status=0
  else
    status=$?
  fi
  # Always check the incompatible/different-image start invariant, including
  # when another assertion fails. No case can authorize a predecessor start.
  allowed_start=$(printf 'f%.0s' {1..64})
  [ "$fault" != replace ] || allowed_start=$(printf 'b%.0s' {1..64})
  if [ -f "$case_dir/docker.log" ]; then
    ! grep '^start-id:' "$case_dir/docker.log" |
      grep -v "^start-id:$allowed_start$" ||
      fail "recovery attempted a foreign/predecessor start"
  fi
  if [ -n "$refusal_before" ]; then
    ! grep -Eq '^((update|stop|start|rm|volume):|compose:(up|create|start|stop|update|rm)$)' \
      "$case_dir/docker.log" || fail "ownership refusal attempted runtime mutation"
    if [ "$fault" = foreign ] || [ "$fault" = missing-request-proof ]; then
      [ "$(<"$case_dir/docker.log")" = "inspect:$allowed_start" ] ||
        fail "runtime refusal passed exact ownership admission"
    fi
    if [ "$fault" = missing ]; then
      # Registration is control-plane evidence. Validate its unresolved,
      # exited-owner shape before excluding only that newly created lease.
      after=$(timeout 10s python3 -B "$fixture_bin/recovery.py" unresolved-registration-snapshot "$case_dir")
    else
      after=$(timeout 10s python3 -B "$fixture_bin/recovery.py" refusal-snapshot "$case_dir")
    fi
    [ "$refusal_before" = "$after" ] ||
      fail "recovery phase=$phase fault=$fault changed incident/provider/lease/configuration/runtime"
  fi
  [ "$status" -eq 1 ] && {
    if [ "$expected" = QUIESCENCE_UNCONFIRMED ]; then
      [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ]
    else
      [[ "$output" == *"test VPS deployment failed: $expected"* ]] ||
        { [ "$expected" = RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED ] &&
          [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ]; }
    fi
  } || fail "recovery phase=$phase fault=$fault status=$status expected=$expected output=$output"
  [ "$(grep -c '^start-id:' "$case_dir/docker.log" || true)" -eq "$starts" ] ||
    fail "recovery start count phase=$phase fault=$fault"
  if [ "$fault" = create-fails ]; then
    jq -e '.phase == "FORWARD_RECOVERING" and
      .commitSubstep == "replacement-create-intent" and .ownedChild == null' \
      "$case_dir/state/timepad-guard/current.json" >/dev/null ||
      fail "failed create lost durable one-use intent"
    before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
    if output=$(timeout 30s "${recovery_command[@]}" 2>&1); then
      fail "unbound create-intent allowed another create"
    fi
    [[ "$output" == *RECOVERY_REPLACEMENT_CREATE_UNRESOLVED* ]] ||
      fail "unbound create-intent did not refuse explicitly"
    [ "$before" = "$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')" ] ||
      fail "unbound create-intent replay changed state"
    [ "$(grep -c '^compose:up$' "$case_dir/docker.log")" -eq 1 ] ||
      fail "unbound create-intent replay attempted another create"
  elif [ "$starts" -eq 0 ]; then
    after=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
    if [[ "$fault" == active-child* ]]; then
      cmp -s "$case_dir/active-before" "$case_dir/state/timepad-guard/current.json" ||
        fail "refusal changed durable owned-child state"
      echo "CONTROLLER_RECOVERY_LIVE_REFUSAL_PASS: child_still_live=1 incident_provider_config_runtime_unchanged=1 fixture_only_teardown=1"
    else
      [ "$before" = "$after" ] || fail "refusal changed durable incident state"
    fi
    ! grep -Eq '^((update|stop|start):|compose:(up|create)$)' "$case_dir/docker.log" ||
      fail "refusal mutated runtime"
    if [ "$phase" = CUTOVER_POSSIBLE ] && [ "$fault" = missing ]; then
      local replay_before replay_log
      replay_before=$(timeout 10s python3 -B "$fixture_bin/recovery.py" refusal-snapshot "$case_dir")
      replay_log=$(sha256sum "$case_dir/docker.log" | awk '{print $1}')
      if output=$(timeout --kill-after=5s 130s "${recovery_command[@]}" 2>&1); then
        status=0
      else
        status=$?
      fi
      [ "$status" -eq 1 ] && [ "$output" = "schema_guard=QUIESCENCE_UNCONFIRMED" ] ||
        fail "unresolved registration replay did not refuse with the sanitized contract"
      [ "$replay_before" = "$(timeout 10s python3 -B "$fixture_bin/recovery.py" refusal-snapshot "$case_dir")" ] &&
        [ "$replay_log" = "$(sha256sum "$case_dir/docker.log" | awk '{print $1}')" ] &&
        [ "$refusal_before" = "$(timeout 10s python3 -B "$fixture_bin/recovery.py" unresolved-registration-snapshot "$case_dir")" ] ||
        fail "unresolved registration replay changed lease/incident/provider/configuration/runtime"
      echo "CONTROLLER_RECOVERY_UNRESOLVED_PASS: missing-legacy replay_refused=1 lease_unchanged=1 live_writers=0 target_starts=0"
    fi
  else
    jq -e --arg phase "$phase" '.current // . |
      .phase == (if $phase == "COMMITTING" then "COMMITTING" else "VERIFYING" end) and .ownedChild == null
      and .operationEpoch == 1' "$case_dir/state/timepad-guard/current.json" >/dev/null ||
      fail "retry lost incident/phase/child proof"
    jq -e '.State.Running == false and .HostConfig.RestartPolicy.Name == "no"' \
      "$case_dir/runtime.json" >/dev/null || fail "failed retry was not quiesced"
    if [ "$proof" = request-proof ]; then
      local request_sequence=3
      [ "$fault" != reaped-child ] || request_sequence=4
      jq -e --argjson sequence "$request_sequence" \
        --arg phase "$phase" --slurpfile historical "$case_dir/historical-before" \
        --slurpfile lease "$case_dir/state/.timepad-execution.json" '
        $historical[0].phase == $phase and
        .incidentId == $historical[0].incidentId and
        .operationEpoch == $historical[0].operationEpoch and
        .evidenceDigest == $historical[0].evidenceDigest and
        .containerId == $historical[0].containerId and .configHash == $historical[0].configHash and
        .target == $historical[0].target and .executionAttempt != $historical[0].executionAttempt and
        .runtimeRequest.operation == "stop" and .runtimeRequest.lifecycle == "completed" and
        .runtimeRequest.sequence == $sequence and .runtimeRequest.responseId == .containerId and
        .runtimeRequest.executionAttempt == .executionAttempt and
        .executionAttempt == $lease[0].attempt and $lease[0].lifecycle == "drained" and
        $lease[0].worker == null and $lease[0].firstFailure == "RECOVERY_RETRY_RUNTIME_FAILED" and
        $lease[0].firstStatus == 1
      ' "$case_dir/state/timepad-guard/current.json" >/dev/null ||
        fail "retry refusal lost completed stop or final childless lease"
    fi
    if [ "$fault" = reaped-child ]; then
      [ -f "$case_dir/cleared-before-retry" ] &&
        jq -e '.latestAttemptId == (.incidentId + ":2") and .ownedChild == null' \
          "$case_dir/state/timepad-guard/current.json" >/dev/null ||
        fail "retry did not clear and replace the positively reaped historical child"
      echo "CONTROLLER_RECOVERY_REAPED_PASS: historical_start_ack=1 prior_echild=1 child_cleared_before_retry=1 exact_retry_starts=1"
    fi
    if [ "$fault" = replace ]; then
      timeout 30s python3 -B "$fixture_bin/recovery.py" lose-replacement "$case_dir"
      before=$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')
      if output=$(timeout 30s "${recovery_command[@]}" 2>&1); then
        fail "missing bound replacement allowed a second replacement"
      fi
      [[ "$output" == *RECOVERY_PROVIDER_ABSENCE_PROOF_REQUIRED* ]] ||
        fail "second replacement did not refuse at absence admission"
      [ "$before" = "$(sha256sum "$case_dir/state/timepad-guard/current.json" | awk '{print $1}')" ] ||
        fail "second replacement refusal changed state"
      [ "$(grep -c '^compose:up$' "$case_dir/docker.log")" -eq 1 ] &&
        [ "$(grep -c '^start-id:' "$case_dir/docker.log")" -eq 1 ] ||
        fail "second replacement refusal mutated runtime"
    fi
  fi
  echo "CONTROLLER_RECOVERY_PASS: phase=$phase fault=$fault target_starts=$starts predecessor_starts=0"
}

# These synthetic legacy snapshots have no durable daemon acknowledgment.
# Matching runtime inventories must not authorize adoption or any mutation.
for phase in CUTOVER_POSSIBLE ROLLING_BACK VERIFYING COMMITTING; do
  assert_bound_recovery "$phase" intact RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED 0
done

# The historical fixture really executes/acknowledges the exact daemon start,
# reaps its child and proves ECHILD before recording a drained old lease.
# Recovery clears that stale child record before a new exact retry; this does
# not prove recovery can drain a still-live child from an earlier attempt.
assert_bound_recovery CUTOVER_POSSIBLE reaped-child RECOVERY_RETRY_RUNTIME_FAILED 1 request-proof

# Intact retries in both phases and foreign/missing-proof cutover cases have
# completed historical daemon requests and dead-owner leases. Others are legacy.
for phase in CUTOVER_POSSIBLE ROLLING_BACK; do
  assert_bound_recovery "$phase" intact RECOVERY_RETRY_RUNTIME_FAILED 1 request-proof
  if [ "$phase" = ROLLING_BACK ]; then
    assert_bound_recovery "$phase" foreign QUIESCENCE_UNCONFIRMED 0 request-proof
  else
    assert_bound_recovery "$phase" foreign QUIESCENCE_UNCONFIRMED 0
    assert_bound_recovery "$phase" foreign-provider QUIESCENCE_UNCONFIRMED 0
  fi
  if [ "$phase" = CUTOVER_POSSIBLE ]; then
    assert_bound_recovery "$phase" missing-request-proof QUIESCENCE_UNCONFIRMED 0
    assert_bound_recovery "$phase" missing QUIESCENCE_UNCONFIRMED 0
  else
    assert_bound_recovery "$phase" missing QUIESCENCE_UNCONFIRMED 0
  fi
  # This legacy orphan snapshot has no correlated request or execution lease.
  # Recovery must refuse its released-child record before runtime mutation.
  assert_bound_recovery "$phase" orphan-child QUIESCENCE_UNCONFIRMED 0
  assert_bound_recovery "$phase" active-child QUIESCENCE_UNCONFIRMED 0
done
assert_bound_recovery ROLLING_BACK missing-input QUIESCENCE_UNCONFIRMED 0 request-proof
assert_bound_recovery ROLLING_BACK active-child-missing-input QUIESCENCE_UNCONFIRMED 0
assert_bound_recovery COMMITTING unknown-inventory QUIESCENCE_UNCONFIRMED 0 request-proof
# These required replacement rows remain assertions of the planned behavior.
# Current exact-container-only registration cannot reach creation/replacement;
# a sanitized early refusal is not a passing replacement acceptance result.
assert_bound_recovery COMMITTING create-intent RECOVERY_REPLACEMENT_CREATE_UNRESOLVED 0 request-proof
assert_bound_recovery COMMITTING create-fails RECOVERY_REPLACEMENT_CREATE_FAILED 0 request-proof
assert_bound_recovery COMMITTING replace RECOVERY_RETRY_RUNTIME_FAILED 1 request-proof
unset TIMEPAD_FIXTURE_CASE

# These cases cover dispatch refusals and positively bound live recovery
# failure paths, not successful commit/replacement or the full fault matrix.
# Keep the suite non-green until every required matrix row is executable.
echo "CONTROLLER_MATRIX_BLOCKED: A1-A5 runtime acceptance is not established" >&2
echo "CONTROLLER_MATRIX_BLOCKED: PREPARED/unbound recovery, replacement, deadline and full fault matrix remain" >&2
exit 77
