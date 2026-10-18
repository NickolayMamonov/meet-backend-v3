#!/usr/bin/env python3
"""Portable parser/admission tests plus Linux guard-state and flock tests."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("test_vps_timepad_state", ROOT / "test_vps_timepad_state.py")
assert SPEC is not None and SPEC.loader is not None
state = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = state
SPEC.loader.exec_module(state)


def digest(ch: str) -> str:
    return ch * 64


def tuple_evidence(*, after: str = "b", retry: bool = True, unknown: bool = True) -> dict:
    return {
        "repositoryDigest": digest("a"), "platformImageId": digest("b"),
        "revision": "c" * 40, "version": "1.0.0",
        "migrationInventoryDigest": digest("c"), "migrationResources": ["migration:reviewed"],
        "beforeSchema": digest("d"), "afterSchema": digest(after), "guardEvidence": digest("e"),
        "dependencyPolicy": "resolved", "dependencyFloor": digest("f"),
        "recoveryEvidence": digest("1"), "retryExact": retry,
        "unknownTransitionCovered": unknown,
    }


def contract(active: bool = True) -> dict:
    base = {
        "schema": state.CONTRACT_SCHEMA, "formatVersion": 1, "controller": state.CONTROLLER,
        "active": active, "rootId": "test-root" if active else None,
        "initialDomain": [], "transitions": [], "images": [],
    }
    if active:
        base["images"] = [
            {"id": "target", "tuple": tuple_evidence(), "domain": "new-schema"},
            {"id": "old", "tuple": tuple_evidence(after="d"), "domain": "initial-schema"},
            {"id": "safe-old", "tuple": tuple_evidence(), "domain": "new-schema"},
        ]
        base["transitions"] = [{
            "id": "first-timepad", "targetId": "target", "beforeSchema": digest("d"),
            "afterSchema": digest("b"), "compatiblePredecessors": ["safe-old"],
        }]
    return base


def prepared_state() -> dict:
    approved = contract()
    admission = state.admit(
        approved, root_id="test-root", target_id="target", predecessor_id="safe-old",
        transition_id="first-timepad", target_tuple=tuple_evidence(),
        predecessor_tuple=tuple_evidence(),
    )
    return state.new_prepared_state(
        state.new_ready_state(digest("a")), operation="deploy", run_id="child-run",
        incident_id="a" * 32, admission=admission, target=approved["images"][0],
        predecessor=approved["images"][2], predecessor_container_id="f" * 64,
        transition_id="first-timepad",
        owned_run="123-5", tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
    )


def owned_child(*, sequence: int = 1, lifecycle: str = "waiting", pid: int = 101) -> dict:
    return {
        "pid": pid, "processGroup": pid,
        "bootId": "01234567-89ab-cdef-0123-456789abcdef",
        "startTicks": 123456, "commandDigest": digest("3"),
        "attemptId": "a" * 32 + f":{sequence}", "lifecycle": lifecycle,
    }


def execution_lease(
    *, attempt: str = "a" * 32, revision: int = 0, lifecycle: str = "registered",
    operation: str = "deploy", rollback_issued: bool = False,
) -> dict:
    started = lifecycle != "registered"
    supervisor = {
        "pid": 101, "startTicks": 456,
        "bootId": "01234567-89ab-cdef-0123-456789abcdef",
    }
    if os.name == "posix":
        pid = os.getpid()
        with open(f"/proc/{pid}/stat", "rb") as stream:
            fields = stream.read(4097).rsplit(b")", 1)[1].split()
        with open("/proc/sys/kernel/random/boot_id", "rt", encoding="ascii") as stream:
            boot_id = stream.read(129).strip()
        supervisor = {"pid": pid, "startTicks": int(fields[19]), "bootId": boot_id}
    return {
        "format": 1, "attempt": attempt, "operation": operation,
        "t0Ns": 1_000 if started else None,
        "workEndNs": 540_000_001_000 if started else None,
        "hardEndNs": 600_000_001_000 if started else None,
        "firstFailure": None, "firstStatus": None,
        "rollbackIssued": rollback_issued, "lifecycle": lifecycle, "revision": revision,
        "supervisor": supervisor,
        "worker": None, "workerMode": "controller-worker", "workers": [],
    }


def controller_function(name: str) -> str:
    source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)
    assert match is not None, name
    return match.group()


class ControllerRecoveryContractTests(unittest.TestCase):
    """Execute controller functions with private, deterministic shell boundaries.

    These portable contracts are not Linux process-group, Docker, filesystem,
    or full-controller acceptance evidence.
    """

    def run_shell(self, script: str, *arguments: str) -> subprocess.CompletedProcess:
        bash = shutil.which("bash")
        if os.name == "nt":
            bash = str(pathlib.Path(os.environ["ProgramFiles"]) / "Git" / "bin" / "bash.exe")
        if bash is None:
            self.fail("Bash is required for controller source contracts")
        return subprocess.run(
            [bash, "-c", "set -euo pipefail\n" + script, "_", *arguments],
            text=True, capture_output=True, check=False, timeout=20,
        )

    def test_ordinary_runtime_wrapper_passes_exactly_six_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as parent:
            runtime = pathlib.Path(parent) / "runtime.sh"
            runtime.write_text(
                'verify_runtime_invariants() { [ "$#" -eq 6 ]; printf "%s\\n" "$@"; }\n',
                encoding="utf-8",
            )
            result = self.run_shell(
                controller_function("runtime_invariants_bounded") + """
timeout() { shift; "$@"; }
runtime_helper=$1
root=fixture-root
compose_script=fixture-compose
runtime_invariants_bounded fixture-image fixture-revision fixture-version fixture-hash
""", runtime.as_posix(),
            )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["fixture-root", "fixture-compose", "fixture-image", "fixture-revision",
             "fixture-version", "fixture-hash"], result.stdout.splitlines(),
        )

    def test_absence_creation_requires_proof_and_consumes_budget_before_owned_create(self) -> None:
        for fault in ("proof", "inventory", "none"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as parent:
                path = pathlib.Path(parent)
                for name in (
                    "candidate-active-compose.identity", "candidate-active-runtime.identity",
                ):
                    (path / name).write_text("fixture-identity", encoding="utf-8")
                (path / "authority.json").write_text("{}", encoding="utf-8")
                result = self.run_shell(
                    controller_function("recovery_absent_candidate") + r"""
fail() { echo "$1" >&2; exit 1; }
timeout() { shift; "$@"; }
validate_configuration_boundary() { :; }
validate_timepad_input() { :; }
active_file_identity() { echo fixture-identity; }
cmp() { return 0; }
env() { echo '{"services":{"backend":{}}}'; }
recovery_backend_inventory() {
  if [ "$fault" = inventory ]; then echo foreign; return; fi
  [ ! -e "$state/created" ] || printf 'b%.0s' {1..64}
}
docker() {
  case "$1:$2" in
    image:inspect) echo '[{"Config":{"Env":[]}}]' ;;
    inspect:*)
      if [ "$#" -gt 2 ]; then echo no; else
        jq -cn --arg id "$(printf 'b%.0s' {1..64})" --arg image "$recovery_target_id" \
          --arg hash "$recovery_hash" \
          '[{Id:$id,Image:$image,State:{Running:false},
             Config:{Labels:{"com.docker.compose.project":"meet-production",
             "com.docker.compose.service":"backend","com.docker.compose.config-hash":$hash}}}]'
      fi ;;
    update:*) echo update >>"$state/trace" ;;
    *) return 90 ;;
  esac
}
python3() {
  case "$2" in
    absence-resume)
      echo proof >>"$state/trace"
      [ "$fault" != proof ] ;;
    read-state) echo '{"current":{"phase":"FORWARD_RECOVERING"}}' ;;
    *) return 90 ;;
  esac
}
timepad_advance() { echo "state:$1:${7:-}" >>"$state/trace"; }
run_owned_child() {
  echo "owned:$1" >>"$state/trace"
  : >"$state/created"
}
complete_owned_child() { :; }
fault=$2
state=$1
root=$1
active_compose=$1/active-compose
active_runtime=$1/active-runtime
image=fixture-image
version=1.2.3
revision=fixture-revision
recovery_authorization=$1/authority.json
provider_helper=fixture-provider
timepad_helper=fixture-state
runtime_helper=fixture-runtime
compose_script=fixture-compose
state_root=$1
recovery_run_key=fixture-run
recovery_state_suffix=final-deploy
recovery_container=$(printf 'f%.0s' {1..64})
recovery_target_id=fixture-target
recovery_hash=$(printf 'a%.0s' {1..64})
recovery_absent_candidate
echo "bound:$recovery_container"
""", path.as_posix(), fault,
                )
                trace = (path / "trace").read_text().splitlines() if (path / "trace").exists() else []
                if fault == "none":
                    self.assertEqual(0, result.returncode, f"{result.stderr}; trace={trace!r}")
                    self.assertEqual([
                        "proof", "state:FORWARD_RECOVERING:",
                        "state:FORWARD_RECOVERING:replacement-create-intent",
                        "owned:FORWARD_RECOVERING", "update",
                        "state:FORWARD_RECOVERING:replacement-container-authorized",
                    ], trace)
                    self.assertEqual("bound:" + "b" * 64, result.stdout.strip())
                else:
                    self.assertEqual(1, result.returncode, result.stderr)
                    self.assertEqual(["proof"] if fault == "proof" else [], trace)
                    self.assertFalse((path / "created").exists())

    def test_post_barrier_failure_checks_actual_inspection_array_before_quiescing(self) -> None:
        for lost_state in (False, True):
            with self.subTest(lost_state=lost_state), tempfile.TemporaryDirectory() as parent:
                path = pathlib.Path(parent)
                result = self.run_shell(controller_function("dispatch_failure") + r"""
recovery_budget_arm() { :; }
recovery_work_check() { return 0; }
timeout() { shift; "$@"; }
python3() {
  [ "$lost_state" = false ] || return 1
  jq -cn --arg id "$candidate_container" \
    '{current:{phase:"VERIFYING",predecessorDisposition:"pre-barrier-only",containerId:$id}}'
}
docker_container_inspect() {
  jq -cn --arg image "$target_id" --arg hash "$target_hash" \
    '[{Image:$image,Config:{Labels:{"com.docker.compose.project":"meet-production",
      "com.docker.compose.service":"backend","com.docker.compose.config-hash":$hash}}}]'
}
docker() { echo "$1" >>"$trace"; }
timepad_advance() { echo "$1" >>"$trace"; }
failure_dispatch_active=false
failure_signal=
unsafe_cutover_latch=true
candidate_container=$(printf 'f%.0s' {1..64})
target_id=fixture-image
target_hash=$(printf 'a%.0s' {1..64})
rollback_complete=false
timepad_helper=fixture-state
state_root=$1
trace=$1/trace
lost_state=$2
dispatch_failure
""", path.as_posix(), str(lost_state).lower())
                self.assertEqual(1, result.returncode, result.stderr)
                self.assertEqual(
                    ["update", "stop"] + ([] if lost_state else ["RECOVERY_REQUIRED"]),
                    (path / "trace").read_text().splitlines(),
                )

    def test_exit_signal_and_local_expiry_preserve_failure_after_safe_rollback(self) -> None:
        function_sources = controller_function("dispatch_failure") + "\n"
        for phase, disposition, trigger, expected_status in (
            ("PREPARED", "pre-barrier-only", "exit-74", 74),
            ("CUTOVER_POSSIBLE", "post-barrier-compatible", "exit-86", 86),
            ("VERIFYING", "post-barrier-compatible", "TERM", 143),
            ("PREPARED", "pre-barrier-only", "INT", 143),
            ("VERIFYING", "post-barrier-compatible", "HUP", 143),
            ("PREPARED", "pre-barrier-only", "grant-expiry", 124),
        ):
            with self.subTest(phase=phase, trigger=trigger), tempfile.TemporaryDirectory() as parent:
                trace = pathlib.Path(parent) / "trace"
                result = self.run_shell(function_sources + r"""
trace=$1
fixture_phase=$2
fixture_disposition=$3
trigger=$4
failure_dispatch_active=false
failure_signal=
unsafe_cutover_latch=$([ "$fixture_phase" = PREPARED ] && echo false || echo true)
mutation_started=true
prepared_timepad=true
rollback_complete=false
credential_prepared=false
owned_child_pid=101
owned_child_fifo=
owned_child_phase=$fixture_phase
owned_child_attempt=fixture-incident:1
timepad_helper=fixture-helper
state_root=/fixture
candidate_container=$(printf 'f%.0s' {1..64})
target_id=fixture-image
target_hash=$(printf 'a%.0s' {1..64})
attempt_nonce=fixture-attempt
t0_ns=1000
work_end_ns=2000
hard_end_ns=3000
recovery_budget_arm() { :; }
recovery_work_check() { return 0; }
timeout() { shift; "$@"; }
python3() {
  printf '{"current":{"phase":"%s","predecessorDisposition":"%s","ownedChild":null}}\n' \
    "$fixture_phase" "$fixture_disposition"
}
timepad_advance() { echo "state:$1:$2" >>"$trace"; }
complete_owned_child() {
  echo drain-forward >>"$trace"
}
timepad_claim_rollback() {
  [ "$attempt_nonce:$t0_ns:$work_end_ns:$hard_end_ns" = \
    fixture-attempt:1000:2000:3000 ] || return 91
  echo rollback-remaining-work >>"$trace"
}
rollback() {
  timepad_claim_rollback || return
  echo rollback-start >>"$trace"
  rollback_complete=true
}
verify_predecessor_for_cleanup() { return 0; }
provider_finish() { echo fixture-receipt; }
case "$trigger" in
  TERM|INT|HUP) failure_signal=$trigger; failure_status=143 ;;
  exit-74) failure_status=74 ;;
  exit-86) failure_status=86 ;;
  grant-expiry) failure_status=124 ;;
  *) exit 90 ;;
esac
complete_owned_child true
dispatch_failure || exit 1
exit "$failure_status"
""", trace.as_posix(), phase, disposition, trigger)
                lines = trace.read_text(encoding="utf-8").splitlines() if trace.exists() else []
                self.assertEqual(expected_status, result.returncode, result.stderr)
                self.assertEqual(
                    ["drain-forward", "rollback-remaining-work", "rollback-start"],
                    lines,
                )

    def test_normal_completion_waits_then_proves_group_absence_before_reap_and_clear(self) -> None:
        child = owned_child(lifecycle="released")
        result = self.run_shell(controller_function("complete_owned_child") + r"""
timeout() { shift; "$@"; }
python3() {
  case "$2" in
    read-state) printf '%s\n' "$fixture_state_json" ;;
    stop-owned-child) echo group-absence >>"$trace" ;;
    *) return 90 ;;
  esac
}
wait() { echo wait-child >>"$trace"; return 23; }
timepad_advance() {
  if [ "$9" = null ]; then
    echo clear >>"$trace"
  else
    [ "$(jq -er '.lifecycle' <<<"$9")" = reaped ]
    echo reaped >>"$trace"
  fi
}
owned_child_pid=101
owned_child_fifo=
owned_child_phase=VERIFYING
owned_child_attempt=$2
state_root=fixture-state
timepad_helper=fixture-helper
trace=$(mktemp)
trap 'rm -f -- "$trace"' EXIT
fixture_state_json=$1
complete_owned_child
[ "$owned_child_wait_status" -eq 23 ]
[ -z "$owned_child_pid" ]
while IFS= read -r line; do echo "$line"; done <"$trace"
""", json.dumps({"current": {"ownedChild": child}}), child["attemptId"])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["wait-child", "group-absence", "reaped", "clear"], result.stdout.splitlines())

    def test_unknown_child_group_refuses_without_discarding_ownership(self) -> None:
        child = owned_child(lifecycle="released")
        result = self.run_shell(controller_function("complete_owned_child") + r"""
timeout() { shift; "$@"; }
python3() {
  case "$2" in
    read-state) printf '%s\n' "$fixture_state_json" ;;
    stop-owned-child) return 2 ;;
    *) return 90 ;;
  esac
}
wait() { return 0; }
timepad_advance() { echo unexpected-state-write; return 91; }
owned_child_pid=101
owned_child_fifo=
owned_child_phase=VERIFYING
owned_child_attempt=$2
state_root=fixture-state
timepad_helper=fixture-helper
fixture_state_json=$1
if complete_owned_child; then exit 92; fi
[ "$owned_child_pid" = 101 ]
""", json.dumps({"current": {"ownedChild": child}}), child["attemptId"])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)

    def test_foreign_durable_child_refuses_before_signal_or_state_write(self) -> None:
        child = owned_child(lifecycle="released", pid=102)
        result = self.run_shell(controller_function("complete_owned_child") + r"""
timeout() { shift; "$@"; }
python3() {
  [ "$2" = read-state ] || { echo unexpected-signal; return 90; }
  printf '%s\n' "$fixture_state_json"
}
wait() { echo unexpected-wait; return 91; }
timepad_advance() { echo unexpected-state-write; return 92; }
owned_child_pid=101
owned_child_phase=VERIFYING
owned_child_attempt=$2
state_root=fixture-state
timepad_helper=fixture-helper
fixture_state_json=$1
if complete_owned_child true; then exit 93; fi
[ "$owned_child_pid" = 101 ]
""", json.dumps({"current": {"ownedChild": child}}), child["attemptId"])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)

    def test_recovery_false_boolean_is_not_a_jq_failure(self) -> None:
        source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        begin = source.index("  recovery_running=$(jq ")
        end = source.index("\n  recovery_health=", begin)
        body = source[begin:end]
        for running in (False, True):
            result = self.run_shell(r"""
recovery_inspect=$1
fail() { echo "$1" >&2; exit 99; }
""" + body + '\necho "$recovery_running"\n',
                json.dumps([{"State": {"Running": running}}]))
            with self.subTest(running=running):
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(str(running).lower(), result.stdout.strip())

    def test_waiting_handshake_preserves_lock_fd_and_executable_argv(self) -> None:
        source = controller_function("run_owned_child")
        self.assertNotIn("exec 9", source)
        self.assertIn('exec {gate_fd}<>"$1"', source)
        self.assertIn('read -r -t 10 gate', source)
        self.assertLess(source.index('timepad_advance "$phase"'),
                        source.index('printf \'%s\\n\' "$token"'))
        # The phase is metadata; the command executable remains in argv.
        self.assertIn("\n  shift\n", source)
        self.assertNotIn("\n  shift 2\n", source)
        self.assertIn('exec "$@"', source)

    def test_healthy_unresolved_phases_normalize_before_verification_without_runtime_mutation(self) -> None:
        source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        begin = source.index('  if [ "$recovery_retry_needed" = false ]; then')
        end = source.index('  if [ "$recovery_retry_needed" = true ]; then', begin)
        body = source[begin:end]
        for phase in ("RECOVERY_REQUIRED", "FORWARD_RECOVERING"):
            for proof in ("live", "receipt"):
                result = self.run_shell(r"""
recovery_retry_needed=false
recovery_phase=$1
recovery_finalization_digest=
[ "$2" = live ] || recovery_finalization_digest=fixture-digest
recovery_state='{"operationEpoch":1}'
recovery_restart=no
recovery_target_id=fixture-image
revision=fixture-revision
version=fixture-version
recovery_hash=fixture-hash
recovery_container=fixture-container
public_url=
fail() { echo "FAIL:$1" >&2; exit 99; }
timepad_advance() { echo "advance:$1"; fixture_phase=$1; }
runtime_guarded_invariants_bounded() {
  [ "$fixture_phase" = "$recovery_phase" ]
  [ "$fixture_phase" = VERIFYING ] || [ "$fixture_phase" = COMMITTING ]
  [ "$5" = fixture-container ] && [ "$6" -eq 1 ]
}
runtime_environment_bounded() { return 0; }
verify_public_contract() { return 0; }
docker() { fail unexpected-runtime-mutation; }
""" + body + '\necho "result:$recovery_phase"\n', phase, proof)
                with self.subTest(phase=phase, proof=proof):
                    self.assertEqual(0, result.returncode, result.stderr)
                    expected = "VERIFYING" if proof == "live" else "COMMITTING"
                    self.assertEqual(
                        ["advance:FORWARD_RECOVERING", "advance:" + expected, "result:" + expected],
                        result.stdout.splitlines(),
                    )

    def test_policy_cleanup_restores_same_container_after_durable_intent(self) -> None:
        source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        begin = source.index('  if [ "$recovery_replacement" = true ]; then\n    case')
        end = source.index('  echo "schema_guard=committed"', begin)
        body = source[begin:end]
        for substep in ("provider-cleanup", "terminal-policy-intent", "policy-restored"):
            for restart in ("no", "unless-stopped"):
                if substep == "provider-cleanup" and restart == "unless-stopped":
                    continue
                result = self.run_shell(r"""
recovery_replacement=false
recovery_substep=$1
recovery_restart=$2
fixture_policy=$recovery_restart
fixture_updates=0
candidate_container=fixture-container
recovery_receipt=fixture-receipt
runtime_helper=fixture-helper
root=fixture-root
compose_script=fixture-compose
target_id=fixture-image
revision=fixture-revision
version=fixture-version
target_hash=fixture-hash
public_url=
fail() { echo "FAIL:$1" >&2; exit 99; }
timepad_advance() { echo "advance:$1:${7:-}"; }
timeout() {
  shift
  case "$1:$2" in
    docker:update)
      [ "$3" = --restart=unless-stopped ] && [ "$4" = "$candidate_container" ]
      fixture_policy=unless-stopped
      fixture_updates=$((fixture_updates + 1)) ;;
    docker:inspect) echo "$fixture_policy" ;;
    bash:-c) echo "$candidate_container" ;;
    *) fail unexpected-runtime-mutation ;;
  esac
}
runtime_invariants_bounded() { return 0; }
runtime_environment_bounded() { return 0; }
verify_public_contract() { return 0; }
""" + body + '\necho "updates:$fixture_updates"\n', substep, restart)
                with self.subTest(substep=substep, restart=restart):
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn("advance:COMMITTED:policy-restored", result.stdout)
                    self.assertIn(
                        "updates:" + ("1" if restart == "no" else "0"), result.stdout,
                    )
                    if substep == "provider-cleanup":
                        self.assertIn("advance:COMMITTING:terminal-policy-intent", result.stdout)
        refused = self.run_shell(r"""
recovery_replacement=false
recovery_substep=unknown
fail() { echo "$1" >&2; exit 99; }
timeout() { echo unexpected-runtime-mutation; return 98; }
timepad_advance() { echo unexpected-state-write; return 97; }
""" + body)
        self.assertEqual(99, refused.returncode)
        self.assertEqual("", refused.stdout)
        self.assertIn("RECOVERY_SUBSTEP_INVALID", refused.stderr)


class OwnedChildStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.prepared = prepared_state()
        self.barrier = state.advance_state(self.prepared, "CUTOVER_POSSIBLE")
        self.child = owned_child()
        self.waiting = state.advance_state(
            self.barrier, "CUTOVER_POSSIBLE",
            ownedChild=self.child, latestAttemptId=self.child["attemptId"],
        )

    def assert_rejected(self, current: dict, phase: str, **changes: object) -> None:
        with self.assertRaises(state.GuardError):
            state.advance_state(current, phase, **changes)

    def reap_and_clear(self, current: dict) -> dict:
        reaped = state.advance_state(
            current, current["phase"],
            ownedChild={**current["ownedChild"], "lifecycle": "reaped"},
        )
        return state.advance_state(reaped, reaped["phase"], ownedChild=None)

    def test_handshake_release_reap_clear_and_next_attempt(self) -> None:
        released = state.advance_state(
            self.waiting, "CUTOVER_POSSIBLE",
            ownedChild={**self.child, "lifecycle": "released"},
        )
        cleared = self.reap_and_clear(released)
        self.assertIsNone(cleared["ownedChild"])
        self.assertEqual(self.child["attemptId"], cleared["latestAttemptId"])
        second = owned_child(sequence=2, pid=102)
        waiting = state.advance_state(
            cleared, "CUTOVER_POSSIBLE",
            ownedChild=second, latestAttemptId=second["attemptId"],
        )
        self.assertEqual(2, state._child_attempt_sequence(waiting["latestAttemptId"]))
        self.assertEqual(1, waiting["operationEpoch"])
        self.assertEqual(self.waiting["incidentId"], waiting["incidentId"])
        self.assertEqual("waiting", self.waiting["ownedChild"]["lifecycle"])

    def test_rollback_latch_is_one_shot_and_cannot_be_cleared_or_claimed_after_commit(self) -> None:
        for source in (
            self.prepared,
            state.advance_state(self.prepared, "CUTOVER_POSSIBLE"),
        ):
            if source["phase"] == "CUTOVER_POSSIBLE":
                source = state.advance_state(
                    source, source["phase"],
                    reason=None,
                )
            claimed = state.advance_state(
                source, "ROLLING_BACK",
                reason="ROLLBACK_ADMITTED",
                rollbackIssued=True,
            )
            self.assertTrue(claimed["rollbackIssued"])
            self.assertEqual(
                claimed,
                state.advance_state(claimed, "ROLLING_BACK"),
            )
            with self.assertRaises(state.GuardError):
                state.advance_state(
                    claimed, "RECOVERY_REQUIRED",
                    rollbackIssued=False,
                )
        incompatible_admission = state.admit(
            contract(), root_id="test-root", target_id="target",
            predecessor_id="old", transition_id="first-timepad",
            target_tuple=tuple_evidence(), predecessor_tuple=tuple_evidence(after="d"),
        )
        incompatible = state.new_prepared_state(
            state.new_ready_state(digest("a")), operation="deploy", run_id="child-run",
            incident_id="a" * 32, admission=incompatible_admission,
            target=contract()["images"][0], predecessor=contract()["images"][1],
            predecessor_container_id="f" * 64, transition_id="first-timepad",
            owned_run="123-5", tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
        )
        incompatible = state.advance_state(incompatible, "CUTOVER_POSSIBLE")
        with self.assertRaises(state.GuardError):
            state.advance_state(incompatible, "ROLLING_BACK", rollbackIssued=True)

    def test_cancelled_handshake_can_reap_and_identical_lifecycle_replays_are_idempotent(self) -> None:
        self.assertEqual(
            self.waiting, state.advance_state(self.waiting, "CUTOVER_POSSIBLE", ownedChild=self.child),
        )
        reaped = state.advance_state(
            self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": "reaped"},
        )
        self.assertEqual(reaped, state.advance_state(reaped, reaped["phase"]))
        cleared = state.advance_state(reaped, reaped["phase"], ownedChild=None)
        self.assertEqual(cleared, state.advance_state(cleared, cleared["phase"], ownedChild=None))

    def test_child_schema_rejects_missing_extra_and_malformed_values(self) -> None:
        for key in self.child:
            with self.subTest(missing=key):
                child = dict(self.child)
                child.pop(key)
                with self.assertRaises(state.GuardError):
                    state._current({**self.waiting, "ownedChild": child})
        invalid_fields = {
            "pid": [None, True, False, 0, 1, -1, 1 << 31, 101.0, "101"],
            "processGroup": [None, True, 0, 1, -1, 102, 1 << 31, "101"],
            "startTicks": [None, True, 0, -1, 1 << 64, 1.5, "123456"],
            "bootId": [None, True, "", "boot", "A" * 36,
                       "01234567-89ab-cdef-0123-456789abcdef\n",
                       "0" * 129, "../../boot-id"],
            "commandDigest": [None, True, "", "a" * 63, "A" * 64, "x" * 64],
            "attemptId": [None, True, "", "random", "a" * 32 + ":0",
                          "a" * 32 + ":01", "a" * 32 + ":+1",
                          "a" * 32 + ":18446744073709551616",
                          "b" * 32 + ":1", "a" * 32 + ":1\n"],
            "lifecycle": [None, True, 1, "", "running", "REAPED", [], {}],
        }
        for key, values in invalid_fields.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(state.GuardError):
                    state._current({**self.waiting, "ownedChild": {**self.child, key: value}})
        for value in ([], "child", 1, True, {**self.child, "extra": "canary-private-payload"}):
            with self.subTest(value=value), self.assertRaises(state.GuardError) as error:
                state._current({**self.waiting, "ownedChild": value})
            self.assertNotIn("canary-private-payload", str(error.exception))
        valid_boundary = {
            **self.child, "pid": (1 << 31) - 1, "processGroup": (1 << 31) - 1,
            "startTicks": state.MAX_U64, "attemptId": "a" * 32 + f":{state.MAX_U64}",
        }
        state._current({
            **self.waiting, "ownedChild": valid_boundary,
            "latestAttemptId": valid_boundary["attemptId"],
        })

    def test_child_json_rejects_duplicate_keys_depth_and_canary_without_echo(self) -> None:
        raw = json.dumps(self.waiting, separators=(",", ":")).encode()
        malformed = [
            raw.replace(b'"pid":101', b'"pid":101,"pid":102'),
            raw.replace(b'"lifecycle":"waiting"', b'"lifecycle":"waiting","lifecycle":"reaped"'),
            raw.replace(b'"lifecycle":"waiting"', b'"lifecycle":"canary-private-payload"'),
            raw.replace(b'"lifecycle":"waiting"', b'"lifecycle":' + b"[" * 12 + b"0" + b"]" * 12),
        ]
        for value in malformed:
            with self.subTest(value=value), self.assertRaises(state.GuardError) as error:
                state._current(state.parse_json(value, state.MAX_CURRENT_BYTES))
            self.assertNotIn("canary-private-payload", str(error.exception))

    def test_child_identity_is_immutable_for_every_lifecycle(self) -> None:
        mutations = {
            "pid": 102, "processGroup": 102,
            "bootId": "11234567-89ab-cdef-0123-456789abcdef",
            "startTicks": 123457, "commandDigest": digest("4"), "attemptId": "a" * 32 + ":2",
        }
        for lifecycle in ("waiting", "released", "reaped"):
            current = state.advance_state(
                self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": lifecycle},
            )
            for key, value in mutations.items():
                with self.subTest(lifecycle=lifecycle, field=key):
                    replacement = {**current["ownedChild"], key: value}
                    self.assert_rejected(
                        current, current["phase"], ownedChild=replacement,
                        latestAttemptId=replacement["attemptId"],
                    )
            self.assert_rejected(
                current, current["phase"], ownedChild=owned_child(sequence=2, pid=102),
                latestAttemptId="a" * 32 + ":2",
            )

    def test_lifecycle_cannot_skip_handshake_reverse_or_clear_active_child(self) -> None:
        for lifecycle in ("released", "reaped"):
            self.assert_rejected(
                self.barrier, "CUTOVER_POSSIBLE",
                ownedChild={**self.child, "lifecycle": lifecycle},
                latestAttemptId=self.child["attemptId"],
            )
        for lifecycle in ("waiting", "released"):
            current = state.advance_state(
                self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": lifecycle},
            )
            self.assert_rejected(current, current["phase"], ownedChild=None)
        for old, new in (("released", "waiting"), ("reaped", "waiting"), ("reaped", "released")):
            current = state.advance_state(
                self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": old},
            )
            self.assert_rejected(
                current, current["phase"], ownedChild={**self.child, "lifecycle": new},
            )

    def test_attempt_allocation_requires_matching_waiting_child_and_exact_increment(self) -> None:
        self.assert_rejected(self.barrier, "CUTOVER_POSSIBLE", ownedChild=self.child)
        self.assert_rejected(
            self.barrier, "CUTOVER_POSSIBLE", latestAttemptId=self.child["attemptId"],
        )
        self.assert_rejected(self.waiting, "CUTOVER_POSSIBLE", latestAttemptId=None)
        for sequence in (2, 3, state.MAX_U64):
            child = owned_child(sequence=sequence)
            self.assert_rejected(
                self.barrier, "CUTOVER_POSSIBLE", ownedChild=child, latestAttemptId=child["attemptId"],
            )
        cleared = self.reap_and_clear(self.waiting)
        self.assert_rejected(cleared, cleared["phase"], latestAttemptId=None)
        for sequence in (1, 3):
            child = owned_child(sequence=sequence)
            self.assert_rejected(
                cleared, cleared["phase"], ownedChild=child, latestAttemptId=child["attemptId"],
            )
        foreign = {**owned_child(), "attemptId": "b" * 32 + ":2"}
        self.assert_rejected(
            cleared, cleared["phase"], ownedChild=foreign, latestAttemptId=foreign["attemptId"],
        )

    def test_stale_historical_attempt_and_overflow_cannot_replay_after_clear(self) -> None:
        cleared = self.reap_and_clear(self.waiting)
        second = owned_child(sequence=2, pid=102)
        second_waiting = state.advance_state(
            cleared, cleared["phase"], ownedChild=second, latestAttemptId=second["attemptId"],
        )
        cleared_again = self.reap_and_clear(second_waiting)
        for child in (self.child, second):
            self.assert_rejected(
                cleared_again, cleared_again["phase"],
                ownedChild=child, latestAttemptId=child["attemptId"],
            )
        maximum = {**cleared_again, "latestAttemptId": "a" * 32 + f":{state.MAX_U64}"}
        state._current(maximum)
        for sequence in (1, state.MAX_U64, state.MAX_U64 + 1):
            child = owned_child(sequence=sequence)
            self.assert_rejected(
                maximum, maximum["phase"], ownedChild=child, latestAttemptId=child["attemptId"],
            )

    def test_active_child_phase_compatibility_and_recovery_carry(self) -> None:
        for phase in state.CHILD_ACTIVE_PHASES:
            current = state.advance_state(self.barrier, phase)
            child_state = state.advance_state(
                current, phase, ownedChild=self.child, latestAttemptId=self.child["attemptId"],
            )
            self.assertEqual(phase, child_state["phase"])
        self.assert_rejected(
            self.prepared, "PREPARED", ownedChild=self.child, latestAttemptId=self.child["attemptId"],
        )
        self.assert_rejected(
            self.prepared, "CUTOVER_POSSIBLE",
            ownedChild=self.child, latestAttemptId=self.child["attemptId"],
        )
        for lifecycle in ("waiting", "released"):
            current = state.advance_state(
                self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": lifecycle},
            )
            recovery = state.advance_state(current, "RECOVERY_REQUIRED")
            self.assertEqual(current["ownedChild"], recovery["ownedChild"])
            for phase in ("READY", "PREPARED", "COMMITTING", "COMMITTED", "ROLLED_BACK"):
                with self.subTest(lifecycle=lifecycle, phase=phase), self.assertRaises(state.GuardError):
                    state._current({**current, "phase": phase})
            state._current({**current, "phase": "VERIFYING"})
        self.assert_rejected(
            self.waiting, "RECOVERY_REQUIRED",
            ownedChild={**self.child, "lifecycle": "released"},
        )
        reaped = state.advance_state(
            self.waiting, "CUTOVER_POSSIBLE", ownedChild={**self.child, "lifecycle": "reaped"},
        )
        verifying = state.advance_state(reaped, "VERIFYING", containerId=digest("a"), configHash=digest("b"))
        committing = state.advance_state(
            verifying, "COMMITTING", commitWitnessDigest=digest("c"),
            providerFinalizationDigest=digest("d"), commitSubstep="provider-cleanup",
        )
        self.assertEqual("reaped", committing["ownedChild"]["lifecycle"])
        cleared_for_retry = state.advance_state(committing, "COMMITTING", ownedChild=None)
        with self.assertRaises(state.GuardError):
            state.advance_state(
                cleared_for_retry, "COMMITTING", containerId="e" * 64,
                commitSubstep="replacement-container-authorized",
            )
        intent = state.advance_state(
            cleared_for_retry, "COMMITTING", commitSubstep="replacement-create-intent",
        )
        self.assertEqual(
            intent, state.advance_state(intent, "COMMITTING", commitSubstep="replacement-create-intent"),
        )
        for changes in (
            {"commitSubstep": "provider-cleanup"},
            {"commitSubstep": "replacement-container-authorized"},
            {"containerId": "e" * 64},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                state.advance_state(intent, "COMMITTING", **changes)
        replacement = state.advance_state(
            intent, "COMMITTING", containerId="e" * 64,
            commitSubstep="replacement-container-authorized",
        )
        self.assertEqual("e" * 64, replacement["containerId"])
        with self.assertRaises(state.GuardError):
            state.advance_state(
                replacement, "COMMITTING", containerId="f" * 64,
                commitSubstep="replacement-container-authorized",
            )
        with self.assertRaises(state.GuardError):
            state.advance_state(
                replacement, "COMMITTING", containerId="f" * 64,
                commitSubstep="provider-cleanup",
            )
        replacement_cleanup = state.advance_state(
            replacement, "COMMITTING",
            commitSubstep="replacement-provider-cleanup",
        )
        replacement_policy_intent = state.advance_state(
            replacement_cleanup, "COMMITTING",
            commitSubstep="replacement-terminal-policy-intent",
        )
        replacement_policy_restored = state.advance_state(
            replacement_policy_intent, "COMMITTING",
            commitSubstep="replacement-policy-restored",
        )
        for invalid_substep in (
            "replacement-container-authorized",
            "replacement-provider-cleanup",
            "terminal-policy-intent",
            "policy-restored",
        ):
            with self.subTest(invalid_substep=invalid_substep), self.assertRaises(state.GuardError):
                state.advance_state(
                    replacement_policy_restored, "COMMITTING",
                    commitSubstep=invalid_substep,
                )
        replacement_committed = state.advance_state(
            replacement_policy_restored, "COMMITTED",
            terminalReceipt=digest("f"),
        )
        self.assertEqual(
            replacement_committed,
            state.advance_state(replacement_committed, "COMMITTED"),
        )
        self.assert_rejected(
            committing, "COMMITTED", terminalReceipt=digest("e"), commitSubstep="policy-restored",
        )
        cleared = state.advance_state(cleared_for_retry, "COMMITTING", ownedChild=None)
        committed = state.advance_state(
            cleared, "COMMITTED", terminalReceipt=digest("e"), commitSubstep="policy-restored",
        )
        self.assertEqual(committed, state.advance_state(committed, "COMMITTED"))

    def test_new_incident_clears_attempt_but_rejects_old_child_identity(self) -> None:
        cleared = self.reap_and_clear(self.waiting)
        rolling_back = state.advance_state(cleared, "ROLLING_BACK")
        terminal = state.advance_state(rolling_back, "ROLLED_BACK", terminalReceipt=digest("e"))
        approved = contract()
        admission = state.admit(
            approved, root_id="test-root", target_id="target", predecessor_id="safe-old",
            transition_id="first-timepad", target_tuple=tuple_evidence(),
            predecessor_tuple=tuple_evidence(),
        )
        prepared = state.new_prepared_state(
            terminal, operation="deploy", run_id="next-run", incident_id="b" * 32,
            admission=admission, target=approved["images"][0], predecessor=approved["images"][2],
            predecessor_container_id="f" * 64,
            transition_id="first-timepad", owned_run="123-6", tooling_digest=digest("2"),
            prepared_proof_digest=digest("9"),
        )
        state.validate_state_transition(terminal, prepared)
        self.assertIsNone(prepared["latestAttemptId"])
        self.assertIsNone(prepared["ownedChild"])
        self.assertEqual(2, prepared["operationEpoch"])
        barrier = state.advance_state(prepared, "CUTOVER_POSSIBLE")
        self.assert_rejected(
            barrier, barrier["phase"], ownedChild=self.child, latestAttemptId=self.child["attemptId"],
        )
        child = {**owned_child(), "attemptId": "b" * 32 + ":1"}
        state.advance_state(barrier, barrier["phase"], ownedChild=child, latestAttemptId=child["attemptId"])

    def test_capture_emits_validated_waiting_identity(self) -> None:
        with mock.patch.object(state, "_proc_start_ticks", return_value=(101, 123456)), \
                mock.patch("builtins.open", mock.mock_open(read_data=self.child["bootId"] + "\n")):
            self.assertEqual(
                self.child,
                state.capture_owned_child(
                    101, command_digest=self.child["commandDigest"], attempt_id=self.child["attemptId"],
                ),
            )
        with mock.patch.object(state, "_proc_start_ticks", return_value=(101, 123456)), \
                mock.patch("builtins.open", mock.mock_open(read_data="malformed\n")), \
                self.assertRaises(state.GuardError):
            state.capture_owned_child(
                101, command_digest=self.child["commandDigest"], attempt_id=self.child["attemptId"],
            )

    def test_process_verification_uses_the_same_strict_schema(self) -> None:
        for function in (state.owned_child_is_same_process, state.require_child_group_quiescent):
            with self.subTest(function=function.__name__), self.assertRaises(state.GuardError):
                function({**self.child, "processGroup": -1})
        with mock.patch.object(state, "_proc_start_ticks", return_value=(101, 123456)), \
                mock.patch("builtins.open", mock.mock_open(read_data=self.child["bootId"] + "\n")):
            self.assertTrue(state.owned_child_is_same_process(self.child))
        with mock.patch.object(state, "_proc_start_ticks", return_value=(101, 123457)), \
                mock.patch("builtins.open", mock.mock_open(read_data=self.child["bootId"] + "\n")):
            self.assertFalse(state.owned_child_is_same_process(self.child))
        with mock.patch.object(state, "_proc_start_ticks") as proc, \
                mock.patch("builtins.open", mock.mock_open(
                    read_data="11234567-89ab-cdef-0123-456789abcdef\n",
                )):
            self.assertFalse(state.owned_child_is_same_process(self.child))
            proc.assert_not_called()

    def test_quiescence_boundary_rejects_live_or_unknown_group(self) -> None:
        for effect, expected in (
            (None, "OWNED_CHILD_STILL_RUNNING"),
            (PermissionError(), "OWNED_CHILD_UNVERIFIABLE"),
        ):
            with self.subTest(reason=expected), \
                    mock.patch.object(state.os, "name", "posix"), \
                    mock.patch.object(state.os, "killpg", create=True, side_effect=effect) as killpg:
                with self.assertRaises(state.GuardError) as error:
                    state.require_child_group_quiescent(self.child)
                self.assertEqual(expected, error.exception.reason)
                killpg.assert_called_once_with(self.child["processGroup"], 0)
        with mock.patch.object(state.os, "name", "posix"), \
                mock.patch.object(state.os, "killpg", create=True, side_effect=ProcessLookupError()):
            state.require_child_group_quiescent(self.child)
        with mock.patch.object(state.os, "name", "nt"), self.assertRaises(state.GuardError) as error:
            state.require_child_group_quiescent(self.child)
        self.assertEqual("LINUX_REQUIRED", error.exception.reason)

    def test_durable_publication_requires_group_disappearance_before_reap_and_clear(self) -> None:
        if not sys.platform.startswith("linux") or os.geteuid() != 0:
            self.skipTest("real owned-process and durable filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1",
                "initialRuntime": digest("a"), "initialConfig": digest("b"),
                "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                "schema": digest("c"), "startupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            state.bootstrap_guard(root, authority=authority, observed=observed)
            origin, _ = state.read_guard(root)
            prepared = {**self.prepared, "originDigest": origin["originDigest"]}
            state.publish_current(root, prepared)
            barrier = state.advance_state(prepared, "CUTOVER_POSSIBLE")
            state.publish_current(root, barrier)
            process = subprocess.Popen(
                [sys.executable, "-B", "-c", "import sys; sys.stdin.buffer.read(1)"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            try:
                child = state.capture_owned_child(
                    process.pid, command_digest=digest("3"), attempt_id=self.child["attemptId"],
                )
                waiting = state.advance_state(
                    barrier, barrier["phase"], ownedChild=child, latestAttemptId=child["attemptId"],
                )
                state.publish_current(root, waiting)
                released = state.advance_state(
                    waiting, waiting["phase"], ownedChild={**child, "lifecycle": "released"},
                )
                state.publish_current(root, released)
                reaped = state.advance_state(
                    released, released["phase"], ownedChild={**child, "lifecycle": "reaped"},
                )
                with self.assertRaises(state.GuardError) as error:
                    state.publish_current(root, reaped)
                self.assertEqual("OWNED_CHILD_STILL_RUNNING", error.exception.reason)
                self.assertEqual(released, state.read_guard(root)[1])
                # A direct publish cannot bypass the lifecycle by clearing the
                # identity instead of going through the advance CLI.
                with self.assertRaises(state.GuardError) as error:
                    state.publish_current(root, {**released, "ownedChild": None})
                self.assertEqual("STATE_CHILD_NOT_REAPED", error.exception.reason)
                process.communicate(input=b"x", timeout=5)
                self.assertEqual(0, process.returncode)
                state.publish_current(root, reaped)
                cleared = state.advance_state(reaped, reaped["phase"], ownedChild=None)
                with mock.patch.object(
                    state, "require_child_group_quiescent",
                    side_effect=state.GuardError("OWNED_CHILD_STILL_RUNNING"),
                ), self.assertRaises(state.GuardError):
                    state.publish_current(root, cleared)
                self.assertEqual(reaped, state.read_guard(root)[1])
                state.publish_current(root, cleared)
                self.assertEqual(cleared, state.read_guard(root)[1])
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=5)

    @unittest.skipUnless(
        sys.platform.startswith("linux") and hasattr(os, "geteuid") and os.geteuid() == 0,
        "real controller handshake, inherited flock and process lifecycle require Linux root",
    )
    def test_controller_owned_child_completes_under_inherited_lock_and_preserves_exit_status(self) -> None:
        for executable in ("bash", "python3", "jq", "setsid", "flock", "timeout", "mkfifo"):
            self.assertIsNotNone(shutil.which(executable), executable)
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            run = root / "fixture-run"
            run.mkdir(mode=0o700)
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1",
                "initialRuntime": digest("a"), "initialConfig": digest("b"),
                "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                "schema": digest("c"), "startupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            state.bootstrap_guard(root, authority=authority, observed=observed)
            origin, _ = state.read_guard(root)
            prepared = {**self.prepared, "originDigest": origin["originDigest"]}
            state.publish_current(root, prepared)
            state.publish_current(root, state.advance_state(prepared, "CUTOVER_POSSIBLE"))
            functions = "\n".join(controller_function(name) for name in (
                "timepad_advance", "next_owned_child_attempt", "complete_owned_child", "run_owned_child",
            ))
            script = r"""
set -euo pipefail
state_root=$1
state=$2
timepad_helper=$3
owned_child_pid=
owned_child_fifo=
owned_child_phase=
owned_child_attempt=
owned_child_wait_status=0
fail() { echo "$1" >&2; exit 99; }
exec 9>>"$state_root/.deploy.lock"
flock -n 9
""" + functions + r"""
status=0
run_owned_child CUTOVER_POSSIBLE timeout --kill-after=2s 5s python3 -B -c '
import os
import sys
import fcntl
lock = os.stat(sys.argv[1] + "/.deploy.lock")
inherited = os.fstat(9)
assert (lock.st_dev, lock.st_ino) == (inherited.st_dev, inherited.st_ino)
fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("CHILD_COMPLETED", flush=True)
raise SystemExit(23)
' "$state_root" || status=$?
[ "$status" -eq 23 ]
[ -z "$owned_child_pid" ]
# Child completion must not unlock the shared open-file description.
if python3 -B "$timepad_helper" lock-check --root "$state_root" 2>/dev/null; then
  fail LOCK_RELEASED
fi
"""
            result = subprocess.run(
                ["bash", "-c", script, "_", str(root), str(run),
                 str(ROOT / "test_vps_timepad_state.py")],
                capture_output=True, text=True, check=False, timeout=30,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual("CHILD_COMPLETED\n", result.stdout)
            current = state.read_guard(root)[1]
            self.assertIsNone(current["ownedChild"])
            self.assertEqual(prepared["incidentId"] + ":1", current["latestAttemptId"])
            self.assertEqual("CUTOVER_POSSIBLE", current["phase"])
            self.assertEqual([], list(run.iterdir()))


class TimepadStateTests(unittest.TestCase):
    def test_execution_lease_parser_is_exact_bounded_and_sanitized(self) -> None:
        lease = execution_lease()
        state._execution_lease(lease)
        invalid = (
            {**lease, "extra": "private"},
            {**lease, "attempt": "not-a-nonce"},
            {**lease, "revision": True},
            {**lease, "supervisor": {**lease["supervisor"], "pid": 1}},
            {**lease, "t0Ns": 5, "workEndNs": 4, "hardEndNs": 6},
            {**lease, "workers": [{}]},
        )
        for candidate in invalid:
            with self.subTest(candidate=candidate), self.assertRaises(state.GuardError):
                state._execution_lease(candidate)
        with self.assertRaises(state.GuardError):
            state.parse_json(b" " * (state.MAX_EXECUTION_LEASE_BYTES + 1),
                             state.MAX_EXECUTION_LEASE_BYTES)

    def test_execution_lease_lifecycle_and_rollback_latches_are_monotonic(self) -> None:
        armed = execution_lease(revision=1, lifecycle="armed")
        cancelled = execution_lease(revision=2, lifecycle="cancel-forward")
        state._validate_lease_successor(armed, cancelled)
        rollback = execution_lease(
            revision=3, lifecycle="rollback-admission", rollback_issued=True,
        )
        state._validate_lease_successor(cancelled, rollback)
        for candidate in (
            execution_lease(revision=4, lifecycle="rolling-back", rollback_issued=False),
            execution_lease(revision=3, lifecycle="rolling-back", rollback_issued=True),
            execution_lease(revision=4, lifecycle="armed", rollback_issued=True),
        ):
            with self.subTest(candidate=candidate), self.assertRaises(state.GuardError):
                state._validate_lease_successor(rollback, candidate)

    def test_execution_lease_publication_is_durable_sequenced_and_non_replayable(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned lease filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            first = execution_lease()
            with mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True):
                with state.deploy_lock(root) as lock_fd:
                    os.set_inheritable(lock_fd, True)
                    lease_path = pathlib.Path(parent) / "lease.json"
                    lease_path.write_text(
                        json.dumps(first, sort_keys=True, separators=(",", ":")), encoding="ascii",
                    )
                    published = subprocess.run(
                        [sys.executable, str(ROOT / "test_vps_timepad_state.py"),
                         "publish-lease", "--root", str(root), "--lease", str(lease_path),
                         "--deploy-lock-fd", str(lock_fd)],
                        capture_output=True, text=True, check=False, pass_fds=(lock_fd,),
                    )
                    self.assertEqual(0, published.returncode, published.stderr)
                    ack = json.loads(published.stdout)
                    raw = (root / state.EXECUTION_LEASE_NAME).read_bytes()
                    self.assertEqual(0o600, (root / state.EXECUTION_LEASE_NAME).stat().st_mode & 0o777)
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), ack["digest"])
                    self.assertEqual((first["attempt"], first["revision"]),
                                     (ack["attempt"], ack["revision"]))
                    armed = execution_lease(revision=1, lifecycle="armed")
                    ack = state.publish_execution_lease(
                        root, armed, deploy_lock_fd=lock_fd,
                    )
                    self.assertEqual(1, ack["revision"])
                    self.assertEqual(
                        {"attempt": first["attempt"], "revision": 1, "outcome": "matched"},
                        state.check_execution_lease(
                            root, attempt=first["attempt"], deploy_lock_fd=lock_fd,
                        ),
                    )
                    with self.assertRaises(state.GuardError) as error:
                        state.publish_execution_lease(
                            root, execution_lease(revision=3, lifecycle="armed"),
                            deploy_lock_fd=lock_fd,
                        )
                    self.assertEqual("EXECUTION_LEASE_REVISION_CONFLICT", error.exception.reason)
                    with self.assertRaises(state.GuardError) as error:
                        state.publish_execution_lease(
                            root, execution_lease(attempt="b" * 32, revision=2, lifecycle="armed"),
                            deploy_lock_fd=lock_fd,
                        )
                    self.assertEqual("EXECUTION_LEASE_CONFLICT", error.exception.reason)
                    with self.assertRaises(state.GuardError) as error:
                        state.check_execution_lease(
                            root, attempt="b" * 32, deploy_lock_fd=lock_fd,
                        )
                    self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)

    def test_execution_lease_interlocks_state_writes_but_keeps_bootstrap_independent(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned lease filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            lease = execution_lease()
            with mock.patch.object(
                state, "_execution_lease_supervisor_is_live", return_value=True,
            ), state.deploy_lock(root) as lock_fd:
                os.set_inheritable(lock_fd, True)
                state.publish_execution_lease(root, lease, deploy_lock_fd=lock_fd)
                authority = {
                    "rootId": "test-root", "bootstrapId": "bootstrap-1",
                    "initialRuntime": digest("a"), "initialConfig": digest("b"),
                    "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                    "schemaHistoryProvenance": True,
                }
                observed = {
                    "rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                    "schema": digest("c"), "startupInventory": digest("d"),
                    "schemaHistoryProvenance": True,
                }
                state.bootstrap_guard(root, authority=authority, observed=observed, deploy_lock_fd=lock_fd)
                with self.assertRaises(state.GuardError) as error:
                    state.publish_current(root, prepared_state(), deploy_lock_fd=lock_fd)
                self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)
                admission = state.admit(
                    contract(), root_id="test-root", target_id="target", predecessor_id="old",
                    transition_id="first-timepad", target_tuple=tuple_evidence(),
                    predecessor_tuple=tuple_evidence(after="d"),
                )
                prepared = state.new_prepared_state(
                    state.read_guard(root, deploy_lock_fd=lock_fd)[1],
                    operation="deploy", run_id="lease-bound-run", incident_id="3" * 32,
                    admission=admission, target=contract()["images"][0],
                    predecessor=contract()["images"][1], predecessor_container_id="f" * 64,
                    transition_id="first-timepad", owned_run="123-lease",
                    tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
                    execution_attempt=lease["attempt"],
                )
                state.publish_current(root, prepared, deploy_lock_fd=lock_fd)
                armed = execution_lease(revision=1, lifecycle="armed")
                state.publish_execution_lease(root, armed, deploy_lock_fd=lock_fd)
                advanced = state.advance_state(prepared, "CUTOVER_POSSIBLE")
                self.assertEqual(lease["attempt"], advanced["executionAttempt"])
                self.assertEqual(advanced, state.publish_current(root, advanced, deploy_lock_fd=lock_fd))
                unresolved = execution_lease(revision=2, lifecycle="quiescence-unconfirmed")
                state.publish_execution_lease(root, unresolved, deploy_lock_fd=lock_fd)
                with self.assertRaises(state.GuardError) as error:
                    state.publish_current(
                        root, state.advance_state(advanced, "VERIFYING"), deploy_lock_fd=lock_fd,
                    )
                self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)
                with self.assertRaises(state.GuardError) as error:
                    state.check_execution_lease(root, attempt=lease["attempt"], deploy_lock_fd=lock_fd)
                self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)

    def test_unheld_or_stale_lease_blocks_writer_and_retention_interlock(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned lease filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            lease = execution_lease()
            with mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True):
                with state.deploy_lock(root) as lock_fd:
                    os.set_inheritable(lock_fd, True)
                    state.publish_execution_lease(root, lease, deploy_lock_fd=lock_fd)
            with self.assertRaises(state.GuardError) as error:
                state.check_execution_lease(root, attempt=lease["attempt"])
            self.assertEqual("EXECUTION_LEASE_FD_REQUIRED", error.exception.reason)
            with state.deploy_lock(root) as reacquired_fd:
                os.set_inheritable(reacquired_fd, True)
                with mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=False):
                    with self.assertRaises(state.GuardError) as error:
                        state.check_execution_lease(
                            root, attempt=lease["attempt"], deploy_lock_fd=reacquired_fd,
                        )
                    self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)
                    with self.assertRaises(state.GuardError) as error:
                        state.publish_current(root, prepared_state(), deploy_lock_fd=reacquired_fd)
                    self.assertEqual("EXECUTION_LEASE_UNRESOLVED", error.exception.reason)

    def test_execution_lease_read_detects_descriptor_replacement_race(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned lease filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent)
            path = root / state.EXECUTION_LEASE_NAME
            path.write_text("{}", encoding="ascii")
            path.chmod(0o600)
            os.chown(path, 0, 0)
            root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with mock.patch.object(state.os, "fstat", return_value=object()):
                    with self.assertRaises(state.GuardError) as error:
                        state._read_at(root_fd, state.EXECUTION_LEASE_NAME,
                                       state.MAX_EXECUTION_LEASE_BYTES)
                self.assertEqual("STATE_RACE", error.exception.reason)
            finally:
                os.close(root_fd)

    def test_contract_cli_emits_only_fixed_validation_summary(self) -> None:
        result = subprocess.run(
            [sys.executable, str(ROOT / "test_vps_timepad_state.py"), "check-contract",
             "--contract", str(ROOT / "test-vps-timepad-release-contracts.json")],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(0, result.returncode)
        self.assertEqual('{"active":false,"outcome":"valid"}\n', result.stdout)
        self.assertEqual("", result.stderr)

    def test_inactive_contract_is_valid_but_cannot_admit(self) -> None:
        parsed = state.parse_contract((ROOT / "test-vps-timepad-release-contracts.json").read_bytes())
        self.assertFalse(parsed["active"])
        result = state.admit(
            parsed, root_id="test-root", target_id="x", predecessor_id="y",
            transition_id=None, target_tuple=None, predecessor_tuple=None,
        )
        self.assertEqual(("refuse", "CONTRACT_INACTIVE_OR_WRONG_ROOT"), (result.disposition, result.reason))

    def test_strict_contract_rejects_duplicates_unknown_keys_and_incomplete_authority(self) -> None:
        valid = contract()
        state.parse_contract(valid)
        for raw in (
            b'{"schema":"x","schema":"y"}',
            json.dumps({**valid, "mystery": True}).encode(),
            json.dumps({**valid, "active": True, "images": []}).encode(),
            json.dumps({**valid, "formatVersion": True}).encode(),
            json.dumps({**valid, "images": valid["images"] * 3}).encode(),
        ):
            with self.assertRaises(state.GuardError):
                state.parse_contract(raw)
        too_deep = b'{"x":' * (state.MAX_JSON_DEPTH + 2) + b'0' + b'}' * (state.MAX_JSON_DEPTH + 2)
        with self.assertRaises(state.GuardError):
            state.parse_json(too_deep, state.MAX_CONTRACT_BYTES)
        with self.assertRaises(state.GuardError):
            state.parse_json(b"[" + b"0" * (state.MAX_CONTRACT_BYTES + 1) + b"]",
                             state.MAX_CONTRACT_BYTES)

    def test_admission_has_three_explicit_outcomes_and_fail_closed_unknowns(self) -> None:
        approved = contract()
        self.assertEqual(
            "post-barrier-compatible",
            state.admit(approved, root_id="test-root", target_id="target",
                        predecessor_id="safe-old", transition_id="first-timepad",
                        target_tuple=tuple_evidence(), predecessor_tuple=tuple_evidence()).disposition,
        )
        self.assertEqual(
            "pre-barrier-only",
            state.admit(approved, root_id="test-root", target_id="target",
                        predecessor_id="old", transition_id="first-timepad",
                        target_tuple=tuple_evidence(), predecessor_tuple=tuple_evidence(after="d")).disposition,
        )
        approved["initialDomain"] = [
            {"id": "initial-target", "tuple": tuple_evidence(after="d")},
            {"id": "initial-old", "tuple": tuple_evidence(after="d")},
        ]
        result = state.admit(approved, root_id="test-root", target_id="initial-target",
                             predecessor_id="initial-old", transition_id=None,
                             target_tuple=tuple_evidence(after="d"),
                             predecessor_tuple=tuple_evidence(after="d"))
        self.assertEqual("legacy-no-transition", result.disposition)
        for result in (
            state.admit(approved, root_id="wrong", target_id="target", predecessor_id="old",
                        transition_id="first-timepad", target_tuple=tuple_evidence(),
                        predecessor_tuple=tuple_evidence(after="d")),
            state.admit(approved, root_id="test-root", target_id="missing", predecessor_id="old",
                        transition_id="first-timepad", target_tuple=tuple_evidence(),
                        predecessor_tuple=tuple_evidence(after="d")),
            state.admit(approved, root_id="test-root", target_id="target", predecessor_id="old",
                        transition_id="unknown", target_tuple=tuple_evidence(),
                        predecessor_tuple=tuple_evidence(after="d")),
        ):
            self.assertEqual("refuse", result.disposition)
        drift = state.admit(
            approved, root_id="test-root", target_id="target", predecessor_id="old",
            transition_id="first-timepad", target_tuple=tuple_evidence(after="d"),
            predecessor_tuple=tuple_evidence(after="d"),
        )
        self.assertEqual("OBSERVED_IMAGE_MISMATCH", drift.reason)

    def test_prepared_increments_epoch_once_and_refuses_overflow_or_unapproved_admission(self) -> None:
        ready = state.new_ready_state(digest("a"))
        admission = state.admit(contract(), root_id="test-root", target_id="target",
                                predecessor_id="old", transition_id="first-timepad",
                                target_tuple=tuple_evidence(),
                                predecessor_tuple=tuple_evidence(after="d"))
        prepared = state.new_prepared_state(
            ready, operation="deploy", run_id="run-1", incident_id="1" * 32,
            admission=admission, target=contract()["images"][0],
            predecessor=contract()["images"][1], predecessor_container_id="f" * 64,
            transition_id="first-timepad",
            owned_run="123-1", tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
        )
        self.assertEqual((1, "PREPARED"), (prepared["operationEpoch"], prepared["phase"]))
        with self.assertRaises(state.GuardError):
            state.advance_state(
                prepared, "PREPARED", preparedProofDigest=digest("8"),
            )
        with self.assertRaises(state.GuardError) as error:
            state.advance_state(prepared, "VERIFYING")
        self.assertEqual("CUTOVER_BARRIER_REQUIRED", error.exception.reason)
        cutover = state.advance_state(prepared, "CUTOVER_POSSIBLE", reason="CUTOVER_ACKNOWLEDGED")
        self.assertEqual(1, cutover["operationEpoch"])
        with self.assertRaises(state.GuardError) as error:
            state.advance_state(cutover, "ROLLING_BACK")
        self.assertEqual("ROLLBACK_UNSAFE", error.exception.reason)
        with self.assertRaises(state.GuardError):
            state.advance_state(cutover, "COMMITTED")
        auth = {
            "schema": state.RECOVERY_AUTH_SCHEMA, "rootId": "test-root",
            "originDigest": prepared["originDigest"],
            "originalOperation": "deploy", "runId": "run-1", "operationEpoch": 1,
            "incidentId": "1" * 32, "evidenceDigest": admission.contract_digest,
            "targetId": "target", "revision": "c" * 40, "version": "1.0.0",
            "repositoryDigest": digest("a"), "platformImageId": digest("b"),
            "action": "retry-exact-candidate",
        }
        self.assertEqual(
            "authorized", state.authorize_recovery(auth, root_id="test-root", current=cutover)["outcome"]
        )
        with self.assertRaises(state.GuardError):
            state.authorize_recovery({**auth, "operationEpoch": 0}, root_id="test-root", current=cutover)
        with self.assertRaises(state.GuardError):
            state.new_prepared_state(ready, operation="deploy", run_id="r", incident_id="1" * 32,
                                     admission=state.Admission("refuse", "x", "", None, None),
                                     target=contract()["images"][0], predecessor=contract()["images"][1],
                                     predecessor_container_id="f" * 64,
                                     transition_id="first-timepad", owned_run="123-1", tooling_digest=digest("2"),
                                     prepared_proof_digest=digest("9"))
        with self.assertRaises(state.GuardError) as error:
            state.new_prepared_state(
                ready, operation="rollback-drill", run_id="drill-1", incident_id="2" * 32,
                admission=admission, target=contract()["images"][0],
                predecessor=contract()["images"][1], predecessor_container_id="f" * 64,
                transition_id="first-timepad",
                owned_run="123-2", tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
            )
        self.assertEqual("ROLLBACK_DRILL_UNSAFE", error.exception.reason)
        ready["operationEpoch"] = state.MAX_U64
        with self.assertRaises(state.GuardError):
            state.new_prepared_state(ready, operation="deploy", run_id="r", incident_id="1" * 32,
                                     admission=admission, target=contract()["images"][0],
                                     predecessor=contract()["images"][1], transition_id="first-timepad",
                                     predecessor_container_id="f" * 64,
                                     owned_run="123-1", tooling_digest=digest("2"),
                                     prepared_proof_digest=digest("9"))

    def test_committing_requires_an_immutable_provider_finalization_digest(self) -> None:
        admission = state.admit(
            contract(),
            root_id="test-root",
            target_id="target",
            predecessor_id="old",
            transition_id="first-timepad",
            target_tuple=tuple_evidence(),
            predecessor_tuple=tuple_evidence(after="d"),
        )
        prepared = state.new_prepared_state(
            state.new_ready_state(digest("a")),
            operation="deploy",
            run_id="commit-run",
            incident_id="a" * 32,
            admission=admission,
            target=contract()["images"][0],
            predecessor=contract()["images"][1],
            predecessor_container_id="f" * 64,
            transition_id="first-timepad",
            owned_run="123-4-final-deploy",
            tooling_digest=digest("2"),
            prepared_proof_digest=digest("9"),
        )
        barrier = state.advance_state(
            prepared,
            "CUTOVER_POSSIBLE",
            reason="CUTOVER_ACKNOWLEDGED",
        )
        verifying = state.advance_state(
            barrier,
            "VERIFYING",
            containerId="a" * 64,
            configHash=digest("3"),
        )
        commit_witness = digest("4")
        provider_witness = digest("5")
        committing = state.advance_state(
            verifying,
            "COMMITTING",
            commitWitnessDigest=commit_witness,
            providerFinalizationDigest=provider_witness,
            commitSubstep="provider-cleanup",
        )
        self.assertEqual(provider_witness, committing["providerFinalizationDigest"])
        with self.assertRaises(state.GuardError):
            state.advance_state(
                verifying,
                "COMMITTING",
                commitWitnessDigest=commit_witness,
                commitSubstep="provider-cleanup",
            )
        with self.assertRaises(state.GuardError) as error:
            state.advance_state(
                committing,
                "COMMITTING",
                providerFinalizationDigest=digest("6"),
            )
        self.assertEqual("STATE_FINALIZATION_WITNESS_CONFLICT", error.exception.reason)
        with self.assertRaises(state.GuardError):
            state.advance_state(
                verifying,
                "RECOVERY_REQUIRED",
                providerFinalizationDigest=provider_witness,
            )
        with self.assertRaises(state.GuardError):
            state.advance_state(
                verifying,
                "RECOVERY_REQUIRED",
                commitWitnessDigest=commit_witness,
            )

    def test_bootstrap_requires_matching_explicit_initial_evidence_and_is_idempotent(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.skipTest("root-owned durable filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1",
                "initialRuntime": digest("a"), "initialConfig": digest("b"),
                "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                "schema": digest("c"), "startupInventory": digest("d"),
                "schemaHistoryProvenance": True,
            }
            first = state.bootstrap_guard(root, authority=authority, observed=observed)
            again = state.bootstrap_guard(root, authority=authority, observed=observed)
            self.assertEqual(("bootstrapped", "already-initialized"), (first["outcome"], again["outcome"]))
            origin, current = state.read_guard(root)
            self.assertEqual(origin["originDigest"], current["originDigest"])
            self.assertEqual((0, "READY"), (current["operationEpoch"], current["phase"]))
            admission = state.admit(
                contract(), root_id="test-root", target_id="target", predecessor_id="old",
                transition_id="first-timepad", target_tuple=tuple_evidence(),
                predecessor_tuple=tuple_evidence(after="d"),
            )
            prepared = state.new_prepared_state(
                current, operation="deploy", run_id="run-1", incident_id="1" * 32,
                admission=admission, target=contract()["images"][0],
                predecessor=contract()["images"][1], predecessor_container_id="f" * 64,
                transition_id="first-timepad",
                owned_run="123-1", tooling_digest=digest("2"), prepared_proof_digest=digest("9"),
            )
            self.assertEqual(prepared, state.publish_current(root, prepared))
            with self.assertRaises(state.GuardError):
                state.publish_current(root, current)
            _, published = state.read_guard(root)
            self.assertEqual((1, "PREPARED"), (published["operationEpoch"], published["phase"]))
            with self.assertRaises(state.GuardError):
                state.bootstrap_guard(root, authority=authority, observed={**observed, "schema": digest("d")})

    def test_existing_origin_without_current_is_lost_state_not_bootstrap(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.skipTest("root-owned durable filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            authority = {"rootId": "test-root", "bootstrapId": "bootstrap-1",
                         "initialRuntime": digest("a"), "initialConfig": digest("b"),
                         "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                         "schemaHistoryProvenance": True}
            observed = {"rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                        "schema": digest("c"), "startupInventory": digest("d"),
                        "schemaHistoryProvenance": True}
            state.bootstrap_guard(root, authority=authority, observed=observed)
            os.unlink(root / state.GUARD_DIR / "current.json")
            with self.assertRaises(state.GuardError):
                state.read_guard(root)
            with self.assertRaises(state.GuardError):
                state.bootstrap_guard(root, authority=authority, observed=observed)

    def test_prepare_and_advance_cli_publish_only_validated_transitions(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.skipTest("root-owned durable filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            base = pathlib.Path(parent)
            root = base / "deploy"
            root.mkdir(mode=0o700)
            authority = {"rootId": "test-root", "bootstrapId": "bootstrap-1",
                         "initialRuntime": digest("a"), "initialConfig": digest("b"),
                         "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
                         "schemaHistoryProvenance": True}
            observed = {"rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
                        "schema": digest("c"), "startupInventory": digest("d"),
                        "schemaHistoryProvenance": True}
            state.bootstrap_guard(root, authority=authority, observed=observed)
            contract_path = base / "contract.json"
            contract_path.write_text(json.dumps(contract()), encoding="utf-8")
            evidence = {
                "rootId": "test-root", "targetId": "target", "predecessorId": "old",
                "predecessorContainerId": "f" * 64,
                "transitionId": "first-timepad", "target": tuple_evidence(),
                "predecessor": tuple_evidence(after="d"), "operation": "deploy",
                "runId": "cli-run", "incidentId": "3" * 32, "ownedRun": "123-3",
                "toolingDigest": digest("2"), "preparedProofDigest": digest("9"),
            }
            evidence_path = base / "evidence.json"
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            command = [sys.executable, str(ROOT / "test_vps_timepad_state.py"),
                       "prepare", "--root", str(root), "--contract", str(contract_path),
                       "--evidence", str(evidence_path)]
            prepared = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(0, prepared.returncode, prepared.stderr)
            self.assertEqual({"admission": "pre-barrier-only", "epoch": 1,
                              "incidentId": "3" * 32, "result": "PREPARED"},
                             json.loads(prepared.stdout))

            changes_path = base / "changes.json"
            changes_path.write_text(json.dumps({"changes": {"reason": "CUTOVER_ACKNOWLEDGED"}}),
                                    encoding="utf-8")
            advanced = subprocess.run(
                [sys.executable, str(ROOT / "test_vps_timepad_state.py"), "advance",
                 "--root", str(root), "--phase", "CUTOVER_POSSIBLE",
                 "--changes", str(changes_path)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(0, advanced.returncode, advanced.stderr)
            self.assertEqual({"epoch": 1, "incidentId": "3" * 32,
                              "result": "CUTOVER_POSSIBLE"}, json.loads(advanced.stdout))
            _, current = state.read_guard(root)
            self.assertEqual("CUTOVER_ACKNOWLEDGED", current["reason"])

            changes_path.write_text(json.dumps({"changes": {
                "operationEpoch": 99, "phase": "VERIFYING",
            }}), encoding="utf-8")
            refused = subprocess.run(
                [sys.executable, str(ROOT / "test_vps_timepad_state.py"), "advance",
                 "--root", str(root), "--phase", "VERIFYING", "--changes", str(changes_path)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(2, refused.returncode)
            self.assertIn("STATE_CHANGE_UNSUPPORTED", refused.stderr)
            self.assertEqual("CUTOVER_POSSIBLE", state.read_guard(root)[1]["phase"])

            evidence_path.write_text(json.dumps({**evidence, "unplanned": "ignored?"}),
                                     encoding="utf-8")
            refused = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(2, refused.returncode)
            self.assertIn("INVALID_INPUT", refused.stderr)

    def test_guard_state_rejects_hardlink_symlink_and_permission_drift(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0:
            self.skipTest("root-owned durable filesystem checks require Linux root")
        authority = {
            "rootId": "test-root", "bootstrapId": "bootstrap-1",
            "initialRuntime": digest("a"), "initialConfig": digest("b"),
            "initialSchema": digest("c"), "initialStartupInventory": digest("d"),
            "schemaHistoryProvenance": True,
        }
        observed = {
            "rootId": "test-root", "runtime": digest("a"), "config": digest("b"),
            "schema": digest("c"), "startupInventory": digest("d"),
            "schemaHistoryProvenance": True,
        }
        for corruption in ("hardlink", "symlink", "mode"):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory() as parent:
                root = pathlib.Path(parent) / "deploy"
                root.mkdir(mode=0o700)
                state.bootstrap_guard(root, authority=authority, observed=observed)
                current = root / state.GUARD_DIR / "current.json"
                if corruption == "hardlink":
                    os.link(current, root / "extra-link")
                elif corruption == "symlink":
                    current.unlink()
                    current.symlink_to("origin.json")
                else:
                    current.chmod(0o640)
                with self.assertRaises(state.GuardError):
                    state.read_guard(root)

    def test_lock_rejects_bad_descriptors_and_contends_nonblocking(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned flock checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent)
            lock = root / state.LOCK_NAME
            lock.touch(mode=0o600)
            os.chown(lock, 0, 0)
            with state.deploy_lock(root) as inherited_fd:
                separate_fd = os.open(lock, os.O_RDWR)
                try:
                    os.set_inheritable(separate_fd, True)
                    with self.assertRaises(state.GuardError) as error:
                        with state.deploy_lock(root, separate_fd):
                            self.fail("a separate open description must contend")
                    self.assertEqual("DEPLOY_LOCK_BUSY", error.exception.reason)
                    with self.assertRaises(state.GuardError) as error:
                        with state.deploy_lock(root, 1_000_000):
                            self.fail("a closed descriptor must fail")
                    self.assertEqual("DEPLOY_LOCK_INVALID", error.exception.reason)
                    inherited = subprocess.run(
                        [sys.executable, str(ROOT / "test_vps_timepad_state.py"),
                         "lock-check", "--root", str(root), "--deploy-lock-fd", str(inherited_fd)],
                        capture_output=True, text=True, check=False, pass_fds=(inherited_fd,),
                    )
                finally:
                    os.close(separate_fd)
                result = subprocess.run(
                    [sys.executable, str(ROOT / "test_vps_timepad_state.py"),
                     "lock-check", "--root", str(root)],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(0, inherited.returncode)
                self.assertIn('"outcome":"locked"', inherited.stdout)
                self.assertEqual(2, result.returncode)
                self.assertIn("DEPLOY_LOCK_BUSY", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
