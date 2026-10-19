#!/usr/bin/env python3
"""Portable parser/admission tests plus Linux guard-state and flock tests."""

from __future__ import annotations

import importlib.util
import argparse
import ast
from contextlib import ExitStack, nullcontext, redirect_stdout
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import stat
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("test_vps_timepad_state", ROOT / "test_vps_timepad_state.py")
assert SPEC is not None and SPEC.loader is not None
state = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = state
SPEC.loader.exec_module(state)
import test_vps_timepad_supervisor as supervisor

LEASE_START_NS = time.monotonic_ns()


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


def create_request(current: dict, child: dict, *, replacement: bool = False) -> dict:
    old = current["runtimeRequest"]
    return {
        "nonce": "9" * 32 if old is None else "8" * 32,
        "sequence": old["sequence"] + 1 if old else 1,
        "executionAttempt": current["executionAttempt"], "operation": "create",
        "containerId": None, "imageId": current["target"]["tuple"]["platformImageId"],
        "configHash": None, "childAttemptId": child["attemptId"], "lifecycle": "intent",
        "responseId": None, "completionDigest": None,
        "originDigest": current["originDigest"], "operationEpoch": current["operationEpoch"],
        "incidentId": current["incidentId"], "operationToken": "7" * 32,
        "preparedProofDigest": current["preparedProofDigest"], "modelDigest": digest("6"),
        "toolingDigest": current["toolingDigest"],
        "resourcesDigest": digest("4"), "resourceRequestDigest": digest("0"),
        "role": "replacement" if replacement else "initial",
        "priorContainerId": current["containerId"] if replacement else None,
        "childIdentity": {key: child[key] for key in state.CHILD_IDENTITY_FIELDS},
    }


def bind_created_state(current: dict, container: str, config_hash: str, *, replacement=False) -> dict:
    """Synthetic acknowledged history for tests of later, unrelated transitions."""
    if current["ownedChild"] is not None:
        if current["ownedChild"]["lifecycle"] != "reaped":
            current = state.advance_state(
                current, current["phase"], ownedChild=dict(current["ownedChild"], lifecycle="reaped"),
            )
        if current["runtimeRequest"] is not None and \
                current["runtimeRequest"]["operation"] == "create" and \
                current["runtimeRequest"]["lifecycle"] == "intent":
            token = state._CREATE_COMPLETION_PUBLICATION.set(True)
            try:
                current = state.advance_state(current, current["phase"], ownedChild=None)
            finally:
                state._CREATE_COMPLETION_PUBLICATION.reset(token)
        else:
            current = state.advance_state(current, current["phase"], ownedChild=None)
    if current["executionAttempt"] is None:
        current = state.advance_state(current, current["phase"], executionAttempt="8" * 32)
    sequence = int(current["latestAttemptId"].split(":")[1]) + 1 if current["latestAttemptId"] else 1
    child = dict(owned_child(sequence=sequence), attemptId=current["incidentId"] + f":{sequence}")
    request = create_request(current, child, replacement=replacement)
    current = state.advance_state(
        current, current["phase"], ownedChild=child, latestAttemptId=child["attemptId"],
        runtimeRequest=request,
    )
    for lifecycle in ("released", "reaped"):
        current = state.advance_state(
            current, current["phase"], ownedChild=dict(child, lifecycle=lifecycle),
        )
    token = state._CREATE_COMPLETION_PUBLICATION.set(True)
    try:
        current = state.advance_state(
            current, current["phase"], ownedChild=None,
            runtimeRequest=dict(request, lifecycle="normal-completed", completionDigest=digest("5")),
        )
    finally:
        state._CREATE_COMPLETION_PUBLICATION.reset(token)
    changes = {
        "containerId": container, "configHash": config_hash,
        "runtimeRequest": dict(current["runtimeRequest"], lifecycle="bound", containerId=container,
                              configHash=config_hash, responseId=container),
    }
    if replacement:
        changes["commitSubstep"] = "replacement-container-authorized"
    return state.advance_state(current, current["phase"], **changes)


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
        "t0Ns": LEASE_START_NS if started else None,
        "workEndNs": LEASE_START_NS + 540_000_000_000 if started else None,
        "hardEndNs": LEASE_START_NS + 600_000_000_000 if started else None,
        "firstFailure": None, "firstStatus": None,
        "rollbackIssued": rollback_issued, "lifecycle": lifecycle, "revision": revision,
        "supervisor": supervisor,
        "worker": None, "workerMode": "controller-worker", "workers": [],
        "createCompletion": None,
    }


def controller_function(name: str) -> str:
    source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
    match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)
    assert match is not None, name
    return match.group()


class ExecutionGrantTests(unittest.TestCase):
    """Portable private-RPC admission tests, not Linux durability evidence."""

    def setUp(self):
        self.lease = execution_lease(revision=1, lifecycle="armed")
        self.grant = state.ExecutionGrant("a" * 32, "b" * 32, LEASE_START_NS + 10_000_000_000)
        self.client = mock.Mock(
            attempt=self.grant.attempt, role="controller-worker", supervisor=self.lease["supervisor"],
        )
        self.client.request.return_value = {
            "attempt": self.grant.attempt, "grantId": self.grant.grant_id,
            "endNs": self.grant.end_ns, "role": "controller-worker", "name": "state-publish",
        }
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(
            state, "_read_execution_lease_locked", return_value=self.lease,
        ))
        self.stack.enter_context(mock.patch.object(
            state, "_execution_lease_supervisor_is_live", return_value=True,
        ))
        self.stack.enter_context(mock.patch.object(
            state.time, "monotonic_ns", return_value=LEASE_START_NS + 1,
        ))
        self.factory = self.stack.enter_context(mock.patch.object(
            supervisor, "WorkerClient", return_value=self.client,
        ))

    def test_live_grant_is_rechecked_and_context_is_cleared_without_renewal(self):
        with state._execution_mutation("/fixture", 9, self.grant):
            state._execution_check()
        self.assertIsNone(state._EXECUTION_CHECK.get())
        self.assertEqual(3, self.client.request.call_count)
        self.client.request.assert_called_with(
            "validate-grant", grantId=self.grant.grant_id, endNs=self.grant.end_ns,
        )
        self.client.close.assert_called_once()

    def test_create_completion_requires_direct_supervisor_parent_and_its_exclusive_live_grant(self):
        with mock.patch.object(state.os, "getppid", return_value=self.lease["supervisor"]["pid"]):
            with self.assertRaises(state.GuardError):
                with state._execution_mutation("/fixture", 9, self.grant, create_completion_only=True):
                    self.fail("ordinary state-publish grant authorized a completion")
            self.client.request.return_value["name"] = "create-completion"
            with state._execution_mutation("/fixture", 9, self.grant, create_completion_only=True):
                state._execution_check()
            with self.assertRaises(state.GuardError):
                with state._execution_mutation("/fixture", 9, self.grant):
                    self.fail("create completion grant authorized generic state mutation")
        with mock.patch.object(state.os, "getppid", return_value=self.lease["supervisor"]["pid"] + 1):
            with self.assertRaises(state.GuardError):
                with state._execution_mutation("/fixture", 9, self.grant, create_completion_only=True):
                    self.fail("controller child impersonated supervisor publisher")
        self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_missing_incomplete_or_unbound_authority_refuses_before_rpc(self):
        for fd, grant in (
            (None, self.grant), (9, None),
            (9, state.ExecutionGrant("c" * 32, "b" * 32, self.grant.end_ns)),
            (9, state.ExecutionGrant("a" * 32, "b" * 32, self.lease["workEndNs"] + 1)),
        ):
            with self.subTest(fd=fd, grant=grant), self.assertRaises(state.GuardError):
                with state._execution_mutation("/fixture", fd, grant):
                    self.fail("unbound writer admitted")
        self.factory.assert_not_called()

    def test_nonce_fd_or_durable_lease_does_not_override_a_revoked_private_grant(self):
        self.client.request.side_effect = supervisor.SupervisorError("GRANT_REVOKED")
        with self.assertRaisesRegex(state.GuardError, "EXECUTION_GRANT_REVOKED"):
            with state._execution_mutation("/fixture", 9, self.grant):
                self.fail("revoked writer admitted")
        self.assertIsNone(state._EXECUTION_CHECK.get())
        self.client.close.assert_called_once()

    def test_response_identity_deadline_role_name_and_shape_must_match(self):
        original = self.client.request.return_value
        for key, value in (
            ("attempt", "c" * 32), ("grantId", "c" * 32),
            ("endNs", self.grant.end_ns + 1), ("role", "rollback-worker"),
            ("name", "provider"), ("extra", "private-canary"),
        ):
            self.client.request.return_value = {**original, key: value}
            with self.subTest(key=key), self.assertRaisesRegex(
                state.GuardError, "EXECUTION_GRANT_INVALID",
            ) as error:
                with state._execution_mutation("/fixture", 9, self.grant):
                    self.fail("different grant admitted")
            self.assertNotIn("private-canary", str(error.exception))

    def test_cancelled_unarmed_or_terminal_lease_cannot_admit_state_writer(self):
        for lifecycle in (
            "registered", "cancel-forward", "drain-forward", "draining",
            "rollback-admission", "quiescence-unconfirmed", "drained",
        ):
            self.lease["lifecycle"] = lifecycle
            with self.subTest(lifecycle=lifecycle), self.assertRaises(state.GuardError):
                with state._execution_mutation("/fixture", 9, self.grant):
                    self.fail("cancelled writer admitted")
        self.factory.assert_not_called()

    def test_local_deadline_is_checked_before_and_after_private_response(self):
        for times, requests in (
            ([self.grant.end_ns], 0),
            ([LEASE_START_NS + 1, self.grant.end_ns], 1),
        ):
            self.client.reset_mock()
            with mock.patch.object(state.time, "monotonic_ns", side_effect=times), \
                    self.assertRaisesRegex(state.GuardError, "EXECUTION_GRANT_EXPIRED"):
                with state._execution_mutation("/fixture", 9, self.grant):
                    self.fail("expired writer admitted")
            self.assertEqual(requests, self.client.request.call_count)

    def test_cleanup_reserve_uses_only_cleanup_publication_and_hard_end(self):
        self.lease.update(workerMode="fail-closed-worker", lifecycle="draining",
                          firstFailure="WORK_EXHAUSTED", firstStatus=1)
        self.client.role = "fail-closed-worker"
        self.client.request.return_value = {
            **self.client.request.return_value, "role": "fail-closed-worker",
            "name": "cleanup-publish",
        }
        grant = state.ExecutionGrant(
            self.grant.attempt, self.grant.grant_id, self.lease["hardEndNs"] - 1,
        )
        self.client.request.return_value["endNs"] = grant.end_ns
        with state._execution_mutation("/fixture", 9, grant, cleanup_only=True):
            state._execution_check()
        self.assertEqual(3, self.client.request.call_count)
        self.client.request.return_value["name"] = "cleanup-stop"
        with self.assertRaisesRegex(state.GuardError, "EXECUTION_GRANT_INVALID"):
            with state._execution_mutation("/fixture", 9, grant, cleanup_only=True):
                self.fail("stop grant used to write schema")
        with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_STOP_ONLY"):
            with state._execution_mutation("/fixture", 9, grant):
                self.fail("cleanup worker admitted to an ordinary writer")

    def test_state_cleanup_cannot_clear_ownership_or_publish_success(self):
        current = {**prepared_state(), "executionAttempt": self.grant.attempt}
        self.lease.update(workerMode="fail-closed-worker", lifecycle="draining")
        unresolved = state.advance_state(current, "RECOVERY_REQUIRED", reason="QUIESCENCE_UNCONFIRMED")
        state._validate_execution_state_write(self.lease, current, unresolved, LEASE_START_NS + 1)
        child = owned_child()
        active = {
            **state.advance_state(current, "CUTOVER_POSSIBLE"), "ownedChild": child,
            "latestAttemptId": child["attemptId"],
        }
        unresolved = state.advance_state(active, "RECOVERY_REQUIRED", reason="QUIESCENCE_UNCONFIRMED")
        for candidate in (
            {**unresolved, "ownedChild": None},
            {**unresolved, "containerId": digest("f")},
            {**unresolved, "rollbackIssued": True},
            {**unresolved, "phase": "COMMITTED"},
        ):
            with self.subTest(candidate=candidate), self.assertRaisesRegex(
                state.GuardError, "EXECUTION_LEASE_STOP_ONLY",
            ):
                state._validate_execution_state_write(self.lease, active, candidate, LEASE_START_NS + 1)
        committing = {
            **unresolved, "phase": "COMMITTING", "commitWitnessDigest": digest("c"),
            "providerFinalizationDigest": digest("d"), "commitSubstep": "provider-cleanup",
        }
        state._validate_execution_state_write(
            self.lease, committing, {**committing, "reason": "QUIESCENCE_UNCONFIRMED"},
            LEASE_START_NS + 1,
        )
        with self.assertRaises(state.GuardError):
            state._validate_execution_state_write(
                self.lease, committing, {**committing, "phase": "RECOVERY_REQUIRED"}, LEASE_START_NS + 1,
            )

    def test_revocation_at_each_atomic_write_boundary_never_acknowledges_publication(self):
        info = SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1)
        # create/write/file-fsync/replace/directory-fsync checks surround every
        # durability boundary. Failure after replace is uncertain, never an ack.
        for point in range(1, 8):
            check = mock.Mock(side_effect=[None] * (point - 1) + [
                state.GuardError("EXECUTION_GRANT_REVOKED"),
            ])
            token = state._EXECUTION_CHECK.set(check)
            try:
                with self.subTest(point=point), ExitStack() as stack:
                    for name, value in (
                        ("listdir", []), ("open", 99), ("fchmod", None), ("fstat", info),
                        ("write", 1), ("close", None), ("unlink", None), ("stat", info),
                    ):
                        stack.enter_context(mock.patch.object(state.os, name, return_value=value, create=True))
                    stack.enter_context(mock.patch.object(state.os, "O_NOFOLLOW", 0, create=True))
                    stack.enter_context(mock.patch.object(state, "_require_no_acl"))
                    fsync = stack.enter_context(mock.patch.object(state.os, "fsync", create=True))
                    replace = stack.enter_context(mock.patch.object(state.os, "replace"))
                    with self.assertRaisesRegex(state.GuardError, "EXECUTION_GRANT_REVOKED"):
                        state._atomic_write(20, "current.json", b"x", 4096, replace=True)
                    self.assertEqual(point, check.call_count)
                    self.assertEqual(1 if point >= 6 else 0, replace.call_count)
                    self.assertEqual((1 if point >= 4 else 0) + (1 if point >= 7 else 0),
                                     fsync.call_count)
            finally:
                state._EXECUTION_CHECK.reset(token)

    def test_cli_requires_all_three_fixed_capability_fields(self):
        parser = state._cli()
        for command in ("bootstrap", "publish-state", "prepare", "advance",
                        "claim-rollback", "stop-owned-child", "retain-unresolved"):
            subparser = next(action for action in parser._actions
                             if isinstance(action, argparse._SubParsersAction)).choices[command]
            flags = {flag for action in subparser._actions for flag in action.option_strings}
            self.assertTrue({"--execution-attempt", "--execution-grant", "--deadline-ns"} <= flags)
        from argparse import Namespace
        self.assertIsNone(state._cli_execution_grant(Namespace()))
        for fields in (
            {"execution_attempt": self.grant.attempt},
            {"execution_grant": self.grant.grant_id, "deadline_ns": self.grant.end_ns},
            {"execution_attempt": self.grant.attempt, "execution_grant": "secret-canary",
             "deadline_ns": self.grant.end_ns},
        ):
            with self.subTest(fields=fields), self.assertRaises(state.GuardError):
                state._cli_execution_grant(Namespace(**fields))

    def test_retain_unresolved_is_fixed_and_preserves_committing_proof_and_owned_child(self):
        self.lease.update(workerMode="fail-closed-worker", lifecycle="draining")
        self.client.role = "fail-closed-worker"
        self.client.request.return_value.update(role="fail-closed-worker", name="cleanup-publish")
        current = {**prepared_state(), "executionAttempt": self.grant.attempt}
        barrier = state.advance_state(current, "CUTOVER_POSSIBLE")
        child = owned_child()
        waiting = state.advance_state(
            barrier, "CUTOVER_POSSIBLE", ownedChild=child, latestAttemptId=child["attemptId"],
        )
        verifying = state.advance_state(bind_created_state(barrier, digest("c"), digest("d")), "VERIFYING")
        committing = state.advance_state(
            verifying, "COMMITTING", commitWitnessDigest=digest("e"),
            providerFinalizationDigest=digest("f"), commitSubstep="provider-cleanup",
        )
        for previous in (current, waiting, committing):
            def publish(_root, candidate):
                state._validate_execution_state_write(self.lease, previous, candidate, LEASE_START_NS + 1)
                state.validate_state_transition(previous, candidate)
                return candidate

            with self.subTest(phase=previous["phase"]), mock.patch.object(
                state, "deploy_lock", return_value=nullcontext(9),
            ), mock.patch.object(state, "_read_guard_locked", return_value=({}, previous)), \
                    mock.patch.object(state, "_publish_current_locked", side_effect=publish) as writer, \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as output:
                status = state.main([
                    "retain-unresolved", "--root", "/fixture", "--deploy-lock-fd", "9",
                    "--execution-attempt", self.grant.attempt,
                    "--execution-grant", self.grant.grant_id, "--deadline-ns", str(self.grant.end_ns),
                ])
                self.assertEqual(0, status)
                candidate = writer.call_args.args[1]
                self.assertEqual(
                    {**previous, "phase": "COMMITTING" if previous is committing else "RECOVERY_REQUIRED",
                     "reason": "QUIESCENCE_UNCONFIRMED"},
                    candidate,
                )
                self.assertEqual("QUIESCENCE_UNCONFIRMED", json.loads(output.getvalue())["result"])


class LeasePublicationAuthorityTests(unittest.TestCase):
    """A live supervisor PID/FD9 is not a lease-publication capability."""

    def setUp(self):
        self.lease = execution_lease()
        self.lease["worker"] = {**self.lease["supervisor"], "pid": 102}
        self.lease["workers"] = [{"mode": "controller-worker", **self.lease["worker"]}]
        self.client = mock.Mock(
            attempt=self.lease["attempt"], role="controller-worker",
            supervisor=self.lease["supervisor"],
        )
        self.client.request.return_value = self.lease
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(
            state.os, "getppid", return_value=self.lease["supervisor"]["pid"] + 1,
        ))
        self.stack.enter_context(mock.patch.object(
            state, "_execution_lease_supervisor_is_live", return_value=True,
        ))
        self.client_factory = self.stack.enter_context(mock.patch.object(
            supervisor, "WorkerClient", return_value=self.client,
        ))

    def test_private_snapshot_is_rechecked_at_each_write_boundary_and_context_is_cleared(self):
        with state._execution_lease_publication("/fixture", self.lease):
            for _ in range(3):
                state._execution_check()
        self.assertEqual(5, self.client.request.call_count)
        self.assertTrue(all(call == mock.call("lease") for call in self.client.request.call_args_list))
        self.client.close.assert_called_once()
        self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_fabricated_snapshot_role_identity_and_worker_null_are_not_publication_authority(self):
        for field, value in (
            ("attempt", "f" * 32), ("supervisor", {**self.lease["supervisor"], "startTicks": 999}),
            ("workerMode", "rollback-worker"), ("worker", None),
            ("lifecycle", "drained"), ("revision", 5),
        ):
            candidate = {**self.lease, field: value}
            with self.subTest(field=field), self.assertRaises(state.GuardError), \
                    state._execution_lease_publication("/fixture", candidate):
                self.fail("fabricated lease gained publication authority")
            self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_revocation_or_snapshot_drift_during_publication_cannot_acknowledge_success(self):
        for response in (
            {**self.lease, "lifecycle": "drain-forward"},
            supervisor.SupervisorError("PRIVATE_REQUEST_REFUSED"),
        ):
            self.client.request.side_effect = [self.lease, response]
            with self.subTest(response=response), self.assertRaises(state.GuardError):
                with state._execution_lease_publication("/fixture", self.lease):
                    state._execution_check()
            self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_no_private_channel_refuses_before_any_filesystem_publication(self):
        self.client_factory.side_effect = supervisor.SupervisorError("PRIVATE_WORKER_REQUIRED")
        with mock.patch.object(state, "deploy_lock", return_value=nullcontext(9)), \
                mock.patch.object(state, "_publish_execution_lease_locked") as publish, \
                self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_PUBLISHER_REQUIRED"):
            state.publish_execution_lease("/fixture", self.lease, deploy_lock_fd=9)
        publish.assert_not_called()
        self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_supervisor_filesystem_child_requires_all_workers_exited_and_sole_child_at_each_boundary(self):
        self.lease.update(lifecycle="drain-forward", revision=3)
        with mock.patch.object(
            state.os, "getppid", return_value=self.lease["supervisor"]["pid"],
        ), mock.patch.object(state.os, "getpid", return_value=300), \
                mock.patch.object(state, "_execution_process_exited", return_value=True), \
                mock.patch("builtins.open", side_effect=lambda *args: io.BytesIO(b"300 ")):
            with state._execution_lease_publication("/fixture", self.lease):
                state._execution_check()
                self.client_factory.assert_not_called()
                with mock.patch("builtins.open", return_value=io.BytesIO(b"300 999 ")), \
                        self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_PUBLISHER_REQUIRED"):
                    state._execution_check()
        self.assertIsNone(state._EXECUTION_CHECK.get())


class RecoveryRegistrationTests(unittest.TestCase):
    """Portable authorization/protocol checks, not Linux lease/fsync evidence."""

    def setUp(self):
        self.current = prepared_state()
        self.origin = {"rootId": "test-root", "originDigest": self.current["originDigest"]}
        target = self.current["target"]
        self.authority = {
            "schema": state.RECOVERY_AUTH_SCHEMA, "rootId": "test-root",
            "originDigest": self.current["originDigest"], "originalOperation": "deploy",
            "runId": self.current["runId"], "operationEpoch": self.current["operationEpoch"],
            "incidentId": self.current["incidentId"], "evidenceDigest": self.current["evidenceDigest"],
            "targetId": target["id"], "revision": target["tuple"]["revision"],
            "version": target["tuple"]["version"], "repositoryDigest": target["tuple"]["repositoryDigest"],
            "platformImageId": target["tuple"]["platformImageId"], "action": "retry-exact-candidate",
        }
        self.selectors = {key: self.authority[key] for key in (
            "runId", "incidentId", "operationEpoch", "evidenceDigest", "repositoryDigest",
            "revision", "version",
        )}
        self.lease = execution_lease(operation="forward-recover")
        self.lease.update(
            t0Ns=LEASE_START_NS, workEndNs=LEASE_START_NS + 540_000_000_000,
            hardEndNs=LEASE_START_NS + 600_000_000_000,
        )
        self.lease["worker"] = {**self.lease["supervisor"], "pid": 102}
        self.lease["workers"] = [{"mode": "controller-worker", **self.lease["worker"]}]
        self.grant = state.ExecutionGrant(
            self.lease["attempt"], "b" * 32, LEASE_START_NS + 10_000_000_000,
        )
        self.client = mock.Mock(
            attempt=self.grant.attempt, role="controller-worker", supervisor=self.lease["supervisor"],
        )
        self.response = {
            "attempt": self.grant.attempt, "grantId": self.grant.grant_id,
            "endNs": self.grant.end_ns, "role": "controller-worker", "name": "recovery-registration",
        }
        self.client.request.side_effect = (
            lambda kind, **fields: self.lease if kind == "lease" else self.response
        )
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(state, "deploy_lock", return_value=nullcontext(9)))
        self.stack.enter_context(mock.patch.object(supervisor, "WorkerClient", return_value=self.client))
        self.stack.enter_context(mock.patch.object(
            state, "_read_guard_locked", return_value=(self.origin, self.current),
        ))
        self.stack.enter_context(mock.patch.object(
            state, "_read_execution_lease_locked", return_value=None,
        ))
        self.stack.enter_context(mock.patch.object(state, "_open_root", return_value=55))
        self.stack.enter_context(mock.patch.object(state.os, "close"))
        self.reader = self.stack.enter_context(mock.patch.object(
            state, "_read_at", side_effect=lambda *args: json.dumps(self.authority).encode(),
        ))
        self.stack.enter_context(mock.patch.object(
            state.time, "monotonic_ns", return_value=LEASE_START_NS + 1,
        ))
        self.real_publisher = state._publish_execution_lease_locked
        self.publisher = self.stack.enter_context(mock.patch.object(
            state, "_publish_execution_lease_locked",
            side_effect=lambda *args, **kwargs: {
                "attempt": self.lease["attempt"], "revision": 0, "digest": digest("c"),
            },
        ))

    def register(self):
        return state.register_recovery(
            "/fixture", contract=contract(), selectors=self.selectors,
            deploy_lock_fd=9, execution_grant=self.grant,
        )

    def test_exact_authority_registers_only_execution_ownership_with_live_rechecks(self):
        before = json.dumps(self.current, sort_keys=True)
        result = self.register()
        self.assertEqual({"attempt": self.grant.attempt, "revision": 0, "digest": digest("c")}, result)
        self.publisher.assert_called_once_with(
            "/fixture", self.lease, state._canonical(self.lease), recovery_registration=True,
        )
        self.reader.assert_called_once_with(
            55, "timepad-recovery-authorization.json", state.MAX_AUTHORIZATION_BYTES,
        )
        self.assertEqual(before, json.dumps(self.current, sort_keys=True))
        self.assertIsNone(state._EXECUTION_CHECK.get())
        self.assertEqual(4, self.client.request.call_count)
        self.client.close.assert_called_once()

    def test_each_dispatch_selector_must_match_before_lease_publication(self):
        for key, original in list(self.selectors.items()):
            for wrong in (True if type(original) is int else "private-canary", None):
                self.selectors[key] = wrong
                with self.subTest(key=key, wrong=wrong), self.assertRaisesRegex(
                    state.GuardError, "RECOVERY_SELECTOR_MISMATCH",
                ) as error:
                    self.register()
                self.assertNotIn("private-canary", str(error.exception))
                self.publisher.assert_not_called()
            self.selectors[key] = original

    def test_wrong_authority_stale_epoch_and_contract_drift_never_publish(self):
        for key, wrong in (
            ("schema", "unsupported"), ("rootId", "other-root"),
            ("originDigest", digest("9")), ("originalOperation", "rollback-drill"),
            ("operationEpoch", 2), ("incidentId", "f" * 32),
            ("platformImageId", digest("9")), ("action", "restore-predecessor"),
        ):
            original = self.authority[key]
            self.authority[key] = wrong
            with self.subTest(key=key), self.assertRaises(state.GuardError):
                self.register()
            self.publisher.assert_not_called()
            self.authority[key] = original
        changed = contract()
        changed["transitions"][0]["compatiblePredecessors"] = []
        with self.assertRaisesRegex(state.GuardError, "RECOVERY_EVIDENCE_CHANGED"):
            state._recovery_registration_authority(
                self.origin, self.current, changed, json.dumps(self.authority).encode(), self.selectors,
            )
        self.publisher.assert_not_called()

    def test_registration_rejects_wrong_role_attempt_lifecycle_and_clock(self):
        for key, wrong in (
            ("operation", "deploy"), ("workerMode", "rollback-worker"),
            ("lifecycle", "armed"), ("revision", 1), ("attempt", "f" * 32),
            ("worker", None), ("workers", []),
            ("workEndNs", self.lease["workEndNs"] + 1),
            ("hardEndNs", self.lease["hardEndNs"] + 1),
        ):
            original = self.lease[key]
            self.lease[key] = wrong
            with self.subTest(key=key), self.assertRaises(state.GuardError):
                self.register()
            self.publisher.assert_not_called()
            self.lease[key] = original

    def test_missing_authorization_and_revocation_do_not_publish_or_leak_context(self):
        self.reader.side_effect = FileNotFoundError()
        with self.assertRaises(FileNotFoundError):
            self.register()
        self.publisher.assert_not_called()
        self.assertIsNone(state._EXECUTION_CHECK.get())
        self.reader.side_effect = lambda *args: json.dumps(self.authority).encode()
        for position in (1, 2, 3):
            checks = 0

            def response(kind, **fields):
                nonlocal checks
                if kind == "lease":
                    return self.lease
                checks += 1
                if checks == position:
                    raise supervisor.SupervisorError("GRANT_REVOKED")
                return self.response

            self.client.request.side_effect = response
            with self.subTest(position=position), self.assertRaisesRegex(
                state.GuardError, "EXECUTION_GRANT_REVOKED",
            ):
                self.register()
            self.assertEqual(1 if position == 3 else 0, self.publisher.call_count)
            self.publisher.reset_mock()
            self.assertIsNone(state._EXECUTION_CHECK.get())

    def test_registration_does_not_reconcile_an_existing_unresolved_lease(self):
        for lifecycle in (
            "registered", "armed", "cancel-forward", "drain-forward",
            "rollback-admission", "rolling-back", "draining", "quiescence-unconfirmed", "drained",
        ):
            previous = execution_lease(attempt="f" * 32, revision=2, lifecycle=lifecycle)
            previous.update(firstFailure="TERM", firstStatus=143)
            previous["workers"] = [{"mode": "controller-worker", **previous["supervisor"]}]
            with self.subTest(lifecycle=lifecycle), mock.patch.object(
                state, "_read_execution_lease_locked", return_value=previous,
            ), mock.patch.object(state, "_execution_process_exited", return_value=True), \
                    mock.patch.object(state, "_atomic_write") as writer, \
                    self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                self.real_publisher(
                    "/fixture", self.lease, state._canonical(self.lease), recovery_registration=True,
                )
            writer.assert_not_called()

    def test_old_kernel_childlessness_does_not_authorize_nonterminal_incident_succession(self):
        previous = execution_lease(attempt="f" * 32, revision=3, lifecycle="drained")
        previous["workers"] = [{"mode": "controller-worker", **previous["supervisor"]}]
        worker = self.lease["worker"]
        cutover = state.advance_state(self.current, "CUTOVER_POSSIBLE")
        verifying = state.advance_state(bind_created_state(cutover, digest("d"), digest("e")), "VERIFYING")
        committing = state.advance_state(
            verifying, "COMMITTING", commitWitnessDigest=digest("b"),
            providerFinalizationDigest=digest("c"), commitSubstep="provider-cleanup",
        )
        states = [
            self.current, cutover, verifying, committing,
            state.advance_state(cutover, "ROLLING_BACK"),
            state.advance_state(cutover, "RECOVERY_REQUIRED"),
            state.advance_state(cutover, "FORWARD_RECOVERING"),
        ]
        for current in states:
            with self.subTest(phase=current["phase"]), mock.patch.object(
                state, "_read_execution_lease_locked", return_value=previous,
            ), mock.patch.object(state, "_execution_process_exited", return_value=True), \
                    mock.patch.object(state, "_execution_process_record", return_value=(
                        worker["bootId"], worker["startTicks"], self.lease["supervisor"]["pid"],
                    )), mock.patch.object(state, "_read_guard_locked", return_value=(self.origin, current)), \
                    mock.patch.object(state, "_atomic_write") as writer, \
                    self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                self.real_publisher(
                    "/fixture", self.lease, state._canonical(self.lease), recovery_registration=True,
                )
            writer.assert_not_called()

    def test_registration_cannot_reconstruct_a_missing_owned_execution_lease(self):
        for attempt in (self.lease["attempt"], "f" * 32):
            with self.subTest(attempt=attempt), mock.patch.object(
                state, "_read_execution_lease_locked", return_value=None,
            ), mock.patch.object(
                state, "_read_guard_locked",
                return_value=(self.origin, {**self.current, "executionAttempt": attempt}),
            ), mock.patch.object(state, "_atomic_write") as writer, \
                    self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                self.real_publisher(
                    "/fixture", self.lease, state._canonical(self.lease), recovery_registration=True,
                )
            writer.assert_not_called()

    def test_rollback_state_admission_is_not_provider_or_daemon_proof(self):
        current = {**self.current, "executionAttempt": self.lease["attempt"]}
        lease = execution_lease(
            revision=4, lifecycle="rollback-admission", rollback_issued=True,
        )
        lease["workerMode"] = "rollback-worker"
        state.rollback_state_admission(current, lease)
        barrier = state.advance_state(current, "CUTOVER_POSSIBLE")
        state.rollback_state_admission(barrier, lease)
        verifying = state.advance_state(bind_created_state(barrier, digest("d"), digest("e")), "VERIFYING")
        waiting = state.advance_state(
            verifying, "VERIFYING", ownedChild=owned_child(sequence=2),
            latestAttemptId=owned_child(sequence=2)["attemptId"],
        )
        for invalid in (
            {**current, "executionAttempt": "f" * 32},
            {**current, "rollbackIssued": True},
            {**barrier, "predecessorDisposition": "pre-barrier-only"},
            {**barrier, "phase": "RECOVERY_REQUIRED"},
            {**barrier, "phase": "FORWARD_RECOVERING"},
            waiting,
        ):
            with self.subTest(phase=invalid["phase"]), self.assertRaises(state.GuardError):
                state.rollback_state_admission(invalid, lease)
        for field, wrong in (
            ("operation", "forward-recover"), ("lifecycle", "rolling-back"),
            ("rollbackIssued", False), ("workerMode", "controller-worker"),
        ):
            with self.subTest(field=field), self.assertRaises(state.GuardError):
                state.rollback_state_admission(current, {**lease, field: wrong})

    def test_rollback_cli_validates_live_capability_and_never_publishes_state(self):
        self.lease.update(
            operation="deploy", workerMode="rollback-worker",
            lifecycle="rollback-admission", rollbackIssued=True,
        )
        self.current["executionAttempt"] = self.grant.attempt
        self.client.role = "rollback-worker"
        self.response.update(role="rollback-worker", name="rollback-admission")
        argv = [
            "rollback-admission", "--root", "/fixture", "--deploy-lock-fd", "9",
            "--execution-attempt", self.grant.attempt, "--execution-grant", self.grant.grant_id,
            "--deadline-ns", str(self.grant.end_ns),
        ]
        before = json.dumps(self.current, sort_keys=True)
        with mock.patch.object(
            state, "_read_execution_lease_locked", return_value=self.lease,
        ), mock.patch.object(state, "rollback_runtime_admission", return_value={
            "proofDigest": "a" * 64,
        }), mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(0, state.main(argv))
        self.assertEqual({"proofDigest": "a" * 64}, json.loads(output.getvalue()))
        self.assertEqual(before, json.dumps(self.current, sort_keys=True))
        self.assertEqual(2, self.client.request.call_count)
        self.publisher.assert_not_called()
        for position in (1, 2):
            self.client.request.side_effect = (
                [supervisor.SupervisorError("GRANT_REVOKED")]
                if position == 1 else [self.response, supervisor.SupervisorError("GRANT_REVOKED")]
            )
            with self.subTest(position=position), mock.patch.object(
                state, "_read_execution_lease_locked", return_value=self.lease,
            ), mock.patch.object(
                state, "rollback_runtime_admission", return_value={"proofDigest": "a" * 64},
            ), mock.patch("sys.stderr", new_callable=io.StringIO) as error:
                self.assertEqual(2, state.main(argv))
            self.assertEqual("EXECUTION_GRANT_REVOKED", error.getvalue().strip())
            self.publisher.assert_not_called()
            self.assertEqual(before, json.dumps(self.current, sort_keys=True))


class RollbackRuntimeAdmissionTests(unittest.TestCase):
    """Read-only reconstruction adapter; no worker admission or mutation authority."""

    def test_fixed_provider_receives_original_deadline_and_rechecks_durable_binding(self):
        for fault in ("none", "provider", "current", "lease", "revoked-before", "revoked-after"):
            with self.subTest(fault=fault), ExitStack() as stack:
                current = prepared_state()
                current["executionAttempt"] = "b" * 32
                lease = {
                    "attempt": "b" * 32, "operation": "deploy", "workerMode": "rollback-worker",
                    "lifecycle": "rollback-admission", "rollbackIssued": True, "revision": 7,
                }
                grant = state.ExecutionGrant("b" * 32, "c" * 32, time.monotonic_ns() + 10**9)
                proof = {"proofDigest": "d" * 64}

                class ProviderError(Exception):
                    pass

                provider = SimpleNamespace(
                    ProviderError=ProviderError,
                    _operation_deadline=mock.Mock(return_value=nullcontext()),
                    _bounded_stdin=mock.Mock(return_value=b"evidence"),
                    _rollback_runtime_proof=mock.Mock(
                        return_value=proof,
                        side_effect=ProviderError() if fault == "provider" else None,
                    ),
                )
                spec = SimpleNamespace(loader=mock.Mock())
                find = stack.enter_context(mock.patch.object(
                    state.importlib.util, "spec_from_file_location", return_value=spec,
                ))
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "module_from_spec", return_value=provider,
                ))
                stack.enter_context(mock.patch.object(
                    state, "_read_execution_lease_locked",
                    return_value=dict(lease, revision=8) if fault == "lease" else lease,
                ))
                stack.enter_context(mock.patch.object(
                    state, "_read_guard_locked",
                    return_value=({}, dict(current, reason="CHANGED") if fault == "current" else current),
                ))
                writer = stack.enter_context(mock.patch.object(state, "_atomic_write"))
                check = mock.Mock(side_effect=(
                    state.GuardError("EXECUTION_GRANT_REVOKED") if fault == "revoked-before"
                    else [None, None, state.GuardError("EXECUTION_GRANT_REVOKED")]
                    if fault == "revoked-after" else None
                ))
                if fault == "none":
                    self.assertIs(proof, state.rollback_runtime_admission("/state", current, lease, grant, check))
                    provider._operation_deadline.assert_called_once_with(grant.end_ns)
                    provider._bounded_stdin.assert_called_once_with(state.MAX_RECOVERY_RUNTIME_BYTES)
                    provider._rollback_runtime_proof.assert_called_once_with(
                        "/state", current, lease, b"evidence", check, claim=False,
                    )
                    self.assertEqual(
                        ROOT / "test-vps-provider-credential.py", find.call_args.args[1],
                    )
                    self.assertEqual(3, check.call_count)
                else:
                    with self.assertRaises(state.GuardError):
                        state.rollback_runtime_admission("/state", current, lease, grant, check)
                    if fault == "revoked-before":
                        provider._bounded_stdin.assert_not_called()
                        provider._rollback_runtime_proof.assert_not_called()
                writer.assert_not_called()

    def test_claim_reconstructs_again_and_requires_exact_admission_and_successor_lease(self):
        for fault in ("none", "current", "attempt", "revision", "predecessor", "digest"):
            with self.subTest(fault=fault), ExitStack() as stack:
                current = prepared_state()
                current["executionAttempt"] = "b" * 32
                lease = {
                    "attempt": "b" * 32, "operation": "deploy", "workerMode": "rollback-worker",
                    "lifecycle": "rolling-back", "rollbackIssued": True, "revision": 8,
                }
                original = {
                    "leaseRevision": 7, "currentDigest": hashlib.sha256(state._canonical(current)).hexdigest(),
                    "executionAttempt": "b" * 32, "predecessor": current["predecessor"],
                }
                admitted = dict(original, proofDigest=hashlib.sha256(state._canonical(original)).hexdigest())
                proof = dict(original, leaseRevision=8)
                proof["proofDigest"] = hashlib.sha256(state._canonical(proof)).hexdigest()
                key, wrong = {
                    "current": ("currentDigest", "e" * 64),
                    "attempt": ("executionAttempt", "e" * 32),
                    "revision": ("leaseRevision", 6),
                    "predecessor": ("predecessor", current["target"]),
                    "digest": ("proofDigest", "e" * 64),
                }.get(fault, ("unused", None))
                if fault != "none":
                    admitted[key] = wrong
                provider = SimpleNamespace(
                    ProviderError=RuntimeError, _operation_deadline=lambda end: nullcontext(),
                    _bounded_stdin=mock.Mock(return_value=state._canonical({
                        "admission": admitted, "runtime": {"inspection": []},
                    })),
                    _rollback_runtime_proof=mock.Mock(return_value=proof),
                )
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "spec_from_file_location",
                    return_value=SimpleNamespace(loader=mock.Mock()),
                ))
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "module_from_spec", return_value=provider,
                ))
                stack.enter_context(mock.patch.object(state, "_read_execution_lease_locked", return_value=lease))
                stack.enter_context(mock.patch.object(state, "_read_guard_locked", return_value=({}, current)))
                writer = stack.enter_context(mock.patch.object(state, "_atomic_write"))
                grant = state.ExecutionGrant("b" * 32, "c" * 32, time.monotonic_ns() + 10**9)
                if fault == "none":
                    self.assertEqual(proof, state.rollback_runtime_admission(
                        "/state", current, lease, grant, mock.Mock(), claim=True,
                    ))
                else:
                    with self.assertRaisesRegex(state.GuardError, "ROLLBACK_NOT_ADMITTED"):
                        state.rollback_runtime_admission(
                            "/state", current, lease, grant, mock.Mock(), claim=True,
                        )
                writer.assert_not_called()


class ControllerRecoveryContractTests(unittest.TestCase):
    """Execute controller functions with private, deterministic shell boundaries.

    These portable contracts are not Linux process-group, Docker, filesystem,
    or full-controller acceptance evidence.
    """

    def test_fixed_rollback_continuation_reuses_owned_run_and_one_remaining_work_grant(self):
        current = prepared_state()
        proof = {
            "runId": "123", "ownedRun": "123-final-deploy", "previousImage": "captured-reference",
            "predecessor": current["predecessor"], "previousConfigHash": "d" * 64,
            "providerEnabled": False, "durableDisposition": "none", "installedEnvironment": "target",
        }
        for fault, expected in (
            ("none", ["admit-rollback", "lease", "budget", "grant", "rollback", "complete",
                      "prepare-terminal", "lease", "terminal"]),
            ("admit", ["admit-rollback"]),
            ("grant", ["admit-rollback", "lease", "budget", "grant"]),
            ("rollback", ["admit-rollback", "lease", "budget", "grant", "rollback"]),
        ):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                log = pathlib.Path(temporary) / "events"
                result = self.run_shell(controller_function("rollback_worker_continue") + r'''
rollback_admission_proof=$1
fault=$2
log=$3
state_root=/owned
TIMEPAD_WORKER_MODE=rollback-worker
fail() { exit 1; }
supervisor_client() {
  case "$1" in
    admit-rollback)
      echo admit-rollback >>"$log"
      [ "$fault" != admit ] ;;
    grant)
      echo grant >>"$log"
      [ "$2" = rollback-remaining-work ] && [ "$3" = 540 ]
      [ "$fault" != grant ] || return 1
      echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' ;;
    complete) echo complete >>"$log" ;;
    prepare-terminal) echo prepare-terminal >>"$log" ;;
    terminal) [ "$2" = 0 ]; echo terminal >>"$log" ;;
    *) exit 9 ;;
  esac
}
supervisor_publish_lease() { echo lease >>"$log"; }
recovery_budget_arm() { echo budget >>"$log"; }
rollback() {
  echo rollback >>"$log"
  [ "$state" = /owned/123-final-deploy ] && [ "$state_suffix" = final-deploy ]
  [ "$previous_image" = captured-reference ] && [ "$provider_enabled" = false ]
  [ "$prepared_timepad" = true ] && [ "$updater_completed" = true ]
  [ "$updater_started" = false ] && [ "$rollback_worker_admitted" = true ]
  [ "$fault" != rollback ]
}
rollback_worker_continue
''', json.dumps(proof), fault, str(log))
                self.assertEqual(0 if fault == "none" else 1, result.returncode, result.stderr)
                self.assertEqual(expected, log.read_text().splitlines())

    def run_shell(self, script: str, *arguments: str) -> subprocess.CompletedProcess:
        bash = shutil.which("bash")
        if os.name == "nt":
            bash = str(pathlib.Path(os.environ["ProgramFiles"]) / "Git" / "bin" / "bash.exe")
        if bash is None:
            self.fail("Bash is required for controller source contracts")
        return subprocess.run(
            [bash, "-s", "--", *arguments], input="set -euo pipefail\n" + script,
            text=True, capture_output=True, check=False, timeout=60 if os.name == "nt" else 20,
        )

    def test_runtime_mutation_requires_intent_exact_receipt_and_completion(self) -> None:
        function = controller_function("timepad_runtime_mutate")
        for fault, expected in (
            ("none", ["intent:stop", "docker:stop", "acknowledged", "completed"]),
            ("outstanding", ["intent:stop"]),
            ("timeout", ["intent:stop", "docker:stop"]),
            ("wrong-response", ["intent:stop", "docker:stop"]),
            ("unknown-proof", ["intent:stop", "docker:stop", "acknowledged", "completed"]),
        ):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as temporary:
                log = pathlib.Path(temporary) / "events"
                result = self.run_shell(r"""
log=$1
fault=$2
container=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
timepad_request_begin() {
  echo "intent:$1" >>"$log"
  [ "$fault" != outstanding ]
}
timepad_request_preflight() { :; } # Candidate path has no predecessor reconstruction.
timeout() {
  [ "$*" = "30s docker stop --time 10 $container" ] || return 99
  echo docker:stop >>"$log"
  [ "$fault" != timeout ] || return 124
  if [ "$fault" = wrong-response ]; then echo unknown; else echo "$container"; fi
}
timepad_request_acknowledge() {
  [ "$1" = "$container" ] || return 98
  echo acknowledged >>"$log"
}
timepad_request_complete() {
  echo completed >>"$log"
  [ "$fault" != unknown-proof ]
}
""" + function + r"""
status=0
timepad_runtime_mutate stop "$container" || status=$?
if [ "$fault" = none ]; then [ "$status" -eq 0 ]; else [ "$status" -ne 0 ]; fi
""", str(log), fault)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(expected, log.read_text().splitlines())

    def test_effective_timeout_dispatches_to_supervisor_without_shadowing(self) -> None:
        source = (ROOT / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        self.assertEqual(1, len(re.findall(r"^timeout\(\) \{", source, re.M)))
        local_timeout = "" if os.name == "nt" else r"""
supervisor_enabled=false
recovery_t0_ns=
if timeout 5s bash -c 'exit 23'; then exit 90; else [ "$?" -eq 23 ]; fi
"""
        result = self.run_shell(controller_function("timeout") + r"""
private_create_stage=
supervisor_enabled=true
supervisor_timeout() { printf '%s\n' "$@"; }
timeout --kill-after=5s 30s fixture-command
""" + local_timeout)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["--kill-after=5s", "30s", "fixture-command"], result.stdout.splitlines(),
        )
        self.assertIn('command timeout "${options[@]}" "$local_duration" "$@"', controller_function("timeout"))

    def test_local_timeout_dispatch_preserves_options_and_status(self) -> None:
        result = self.run_shell(controller_function("timeout") + r"""
private_create_stage=
supervisor_enabled=false
recovery_t0_ns=
supervisor_timeout() { return 99; }
command() { printf '%s\n' "$@"; return 23; }
if timeout --kill-after=5s 30s fixture-command; then exit 90; else [ "$?" -eq 23 ]; fi
""")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            ["timeout", "--kill-after=5s", "30s", "fixture-command"],
            result.stdout.splitlines(),
        )

    def test_private_create_stage_reuses_original_context_and_authenticated_grant(self) -> None:
        # The shell stage was removed by §5e. These source contracts complement
        # the actual isolated wait/grant tests; they are not runtime evidence.
        tree = ast.parse((ROOT / "test_vps_timepad_supervisor.py").read_text())
        stage = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name == "_fixed_create_stage")
        source = ast.unparse(stage)
        self.assertIn("end_ns=context.end_ns", source)
        self.assertIn("CreateDriver(context, transport, client)", source)
        self.assertIn('decode(environment[\'TIMEPAD_CREATE_GRANT\'].encode())', source)
        self.assertIn("environment['TIMEPAD_CREATE_REQUEST_DIGEST']", source)
        self.assertIn("driver.check_stage(", source)
        self.assertIn("wait_create(transport.spawn_create(driver.context, (9,)), driver.context)", source)
        self.assertLess(source.index("driver.check_stage("), source.index("transport.spawn_create("))
        self.assertNotIn("execvpe", source)
        self.assertNotIn("supervisor_timeout", source)
        self.assertNotIn("timepad_private_create_grant", controller_function("timeout"))

    def test_supervised_wait_completes_failed_commands_and_refuses_revoked_success(self) -> None:
        for fault, expected_status, expected_trace in (
            ("command", 23, ["grant:provider:30", "run:--kill-after=5s:0.5s", "complete"]),
            ("revoked", 1, ["grant:provider:30", "run:--kill-after=5s:0.5s", "complete"]),
            ("refused", 124, ["grant:provider:30"]),
        ):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as parent:
                path = pathlib.Path(parent)
                result = self.run_shell(controller_function("supervisor_timeout") + r"""
trace=$1/trace
fault=$2
TIMEPAD_ATTEMPT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
provider_helper=/fixture/provider.py
timepad_helper=/fixture/state.py
supervisor_client() {
  case "$1" in
    grant)
      echo "grant:$2:$3" >>"$trace"
      [ "$fault" != refused ] || return 1
      echo '{"grantId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","endNs":1000000000}' ;;
    complete)
      echo complete >>"$trace"
      [ "$fault" != revoked ] ;;
    *) return 90 ;;
  esac
}
jq() {
  case "$*" in
    *grantId*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
    *endNs*) echo 1000000000 ;;
    *) return 91 ;;
  esac
}
command() {
  [ "$1" = timeout ] || return 92
  shift
  if [ "$1" = 3s ]; then
    [ "$2" = python3 ] || return 93
    echo 0.5s
  else
    echo "run:$1:$2" >>"$trace"
    [ "$1" = --kill-after=5s ] && [ "$2" = 0.5s ] &&
      [ "$3" = python3 ] && [ "$4" = "$provider_helper" ] &&
      [ "$5" = verify ] && [ "$6" = --execution-attempt ] &&
      [ "$7" = "$TIMEPAD_ATTEMPT" ] && [ "$8" = --execution-grant ] &&
      [ "$9" = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ] && [ "${10}" = --deadline-ns ] &&
      [ "${11}" = 1000000000 ] && [ "$#" -eq 11 ] || return 94
    [ "$fault" != command ] || return 23
  fi
}
supervisor_timeout --kill-after=5s 30s python3 "$provider_helper" verify
echo unexpected-success
""", path.as_posix(), fault)
                self.assertEqual(expected_status, result.returncode, result.stderr)
                self.assertEqual(expected_trace, (path / "trace").read_text().splitlines())
                self.assertNotIn("unexpected-success", result.stdout)

    def test_budget_cache_uses_supervisor_clock_and_does_not_rearm_recovery(self) -> None:
        for lifecycle in ("registered", "armed"):
            with self.subTest(lifecycle=lifecycle):
                result = self.run_shell(controller_function("recovery_budget_arm") + r"""
supervisor_enabled=true
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
recovery_t0_ns=
recovery_work_end_ns=
recovery_hard_end_ns=
fixture_lifecycle=$1
supervisor_client() {
  case "$1" in
    lease) echo '{"attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
    arm) fixture_lifecycle=armed; echo arm ;;
    *) return 90 ;;
  esac
}
supervisor_publish_lease() { echo publish; }
fail() { echo "$1" >&2; exit 91; }
jq() {
  case "$*" in
    *lifecycle*) echo "$fixture_lifecycle" ;;
    *--arg*) return 0 ;;
    *.t0Ns*) echo 1000 ;;
    *.workEndNs*) echo 540000001000 ;;
    *.hardEndNs*) echo 600000001000 ;;
    *) return 92 ;;
  esac
}
recovery_budget_arm
recovery_budget_arm
echo "$recovery_t0_ns:$recovery_work_end_ns:$recovery_hard_end_ns"
""", lifecycle)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual(
                    (["publish"] if lifecycle == "registered" else []) +
                    ["1000:540000001000:600000001000"],
                    result.stdout.splitlines(),
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
timepad_create_action() {
  [ "$*" = "verify-target replacement" ] || return 92
  echo proof >>"$state/trace"
  [ "$fault" != proof ]
}
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
    read-state) echo '{"current":{"phase":"FORWARD_RECOVERING"}}' ;;
    *) return 90 ;;
  esac
}
timepad_advance() { echo "state:$1:${7:-}" >>"$state/trace"; }
run_owned_child() {
  [ "$*" = "FORWARD_RECOVERING create replacement" ] || return 91
  echo "owned:$1" >>"$state/trace"
  # This contract isolates absence admission and fixed delegation; the
  # delegated create/bind/suppress protocol has separate controller tests.
  candidate_container=$(printf 'b%.0s' {1..64})
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
                        "owned:FORWARD_RECOVERING",
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
        self.assertIn('read -r -t 5 gate', source)
        self.assertLess(source.index('timepad_advance "$phase"'),
                        source.index('printf \'%s\\n\' "$token"'))
        # The phase is metadata; the command executable remains in argv.
        self.assertIn("\n  shift\n", source)
        self.assertNotIn("\n  shift 2\n", source)
        self.assertIn('"$@" | python3', source)
        self.assertLess(source.index('timepad_request_begin start'),
                        source.index('printf \'%s\\n\' "$token"'))
        self.assertIn('supervisor_client grant child-handshake 5', source)
        self.assertIn('supervisor_client grant docker 30', source)

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
timepad_runtime_mutate() {
  [ "$1" = restore-policy ] && [ "$2" = "$candidate_container" ] || return 96
  timeout 15s docker update --restart=unless-stopped "$2"
}
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
        verifying = state.advance_state(bind_created_state(reaped, digest("b"), digest("b")), "VERIFYING")
        committing = state.advance_state(
            verifying, "COMMITTING", commitWitnessDigest=digest("c"),
            providerFinalizationDigest=digest("d"), commitSubstep="provider-cleanup",
        )
        self.assertIsNone(committing["ownedChild"])
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
        replacement = bind_created_state(intent, "e" * 64, intent["configHash"], replacement=True)
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
            dict(committing, ownedChild=owned_child(sequence=2, lifecycle="reaped")),
            "COMMITTED", terminalReceipt=digest("e"), commitSubstep="policy-restored",
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
            docker = run / "docker"
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import fcntl, os, sys\n"
                f"lock = os.stat({str(root / '.deploy.lock')!r})\n"
                "inherited = os.fstat(9)\n"
                "assert (lock.st_dev, lock.st_ino) == (inherited.st_dev, inherited.st_ino)\n"
                "assert sys.argv[1:] == ['start', 'f' * 64]\n"
                "fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                "raise SystemExit(23)\n",
                encoding="utf-8",
            )
            docker.chmod(0o700)
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
owned_child_response=
owned_child_grant=
fail() { echo "$1" >&2; exit 99; }
exec 9>>"$state_root/.deploy.lock"
flock -n 9
export PATH="$state:$PATH"
supervisor_client() {
  case "$1" in
    grant) echo '{"grantId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
    complete) : ;;
    *) return 98 ;;
  esac
}
# This fixture isolates child topology/FD9/exit propagation. Request state and
# adapter proof have separate focused tests; the full controller matrix is blocked.
timepad_request_begin() {
  [ "$1" = start ] && [[ "$2" = *:1 ]] && [[ "$3" = f* ]]
}
""" + functions + r"""
status=0
run_owned_child CUTOVER_POSSIBLE timeout --kill-after=5s 30s docker start \
  "$(printf 'f%.0s' {1..64})" || status=$?
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
            self.assertEqual("", result.stdout)
            current = state.read_guard(root)[1]
            self.assertIsNone(current["ownedChild"])
            self.assertEqual(prepared["incidentId"] + ":1", current["latestAttemptId"])
            self.assertEqual("CUTOVER_POSSIBLE", current["phase"])
            self.assertEqual([docker], list(run.iterdir()))


class CleanupRequestTests(unittest.TestCase):
    def setUp(self):
        self.lease = execution_lease(operation="forward-recover", revision=5, lifecycle="draining")
        self.lease.update(
            workerMode="fail-closed-worker", firstFailure="RECOVERY_RETRY_RUNTIME_FAILED", firstStatus=1,
        )
        current = prepared_state()
        current = state.advance_state(current, "CUTOVER_POSSIBLE")
        current = bind_created_state(current, digest("4"), digest("5"))
        current = state.advance_state(current, "VERIFYING")
        self.current = dict(current, executionAttempt=self.lease["attempt"], runtimeRequest={
            "nonce": "6" * 32, "sequence": 1, "executionAttempt": self.lease["attempt"],
            "operation": "start", "containerId": current["containerId"],
            "imageId": current["target"]["tuple"]["platformImageId"], "configHash": current["configHash"],
            "childAttemptId": None, "lifecycle": "completed",
            "responseId": current["containerId"], "completionDigest": digest("7"),
        })

    def test_cleanup_can_publish_only_correlated_stop_intent_acknowledgment_and_completion(self):
        previous = self.current
        request = dict(
            previous["runtimeRequest"], nonce="8" * 32, sequence=2, operation="stop",
            lifecycle="intent", responseId=None, completionDigest=None,
        )
        for lifecycle in ("intent", "acknowledged", "completed"):
            if lifecycle != "intent":
                request = dict(request, lifecycle=lifecycle, responseId=previous["containerId"],
                               completionDigest=digest("9") if lifecycle == "completed" else None)
            candidate = state.advance_state(previous, previous["phase"], runtimeRequest=request)
            state._validate_execution_state_write(self.lease, previous, candidate, LEASE_START_NS + 1)
            previous = candidate
        self.assertEqual("VERIFYING", previous["phase"])
        self.assertEqual("stop", previous["runtimeRequest"]["operation"])

    def test_cleanup_never_changes_incident_phase_child_or_other_request_operations(self):
        request = dict(
            self.current["runtimeRequest"], nonce="8" * 32, sequence=2, operation="stop",
            lifecycle="intent", responseId=None, completionDigest=None,
        )
        candidate = dict(self.current, runtimeRequest=request)
        for change in (
            {"phase": "COMMITTED"}, {"operationEpoch": 2}, {"containerId": digest("a")},
            {"ownedChild": owned_child()}, {"reason": "unreviewed"},
            {"runtimeRequest": dict(request, operation="start")},
            {"runtimeRequest": dict(request, operation="restore-policy")},
            {"runtimeRequest": dict(request, operation="suppress")},
        ):
            with self.subTest(change=change), self.assertRaises(state.GuardError):
                state._validate_execution_state_write(
                    self.lease, self.current, dict(candidate, **change), LEASE_START_NS + 1,
                )
        for change in (
            {"firstFailure": "TERM"}, {"firstStatus": 143}, {"operation": "deploy"},
            {"lifecycle": "armed"}, {"attempt": "b" * 32},
        ):
            with self.subTest(change=change), self.assertRaises(state.GuardError):
                state._validate_execution_state_write(
                    dict(self.lease, **change), self.current, candidate, LEASE_START_NS + 1,
                )
        with self.assertRaises(state.GuardError):
            state._validate_execution_state_write(
                self.lease, self.current, candidate, self.lease["hardEndNs"],
            )


class PredecessorRuntimeRequestTests(unittest.TestCase):
    def setUp(self):
        self.current = dict(prepared_state(), executionAttempt="8" * 32)
        self.request = {
            "nonce": "9" * 32, "sequence": 1, "executionAttempt": "8" * 32,
            "operation": "suppress", "containerId": self.current["predecessorContainerId"],
            "imageId": self.current["predecessor"]["tuple"]["platformImageId"],
            "configHash": digest("d"), "childAttemptId": None, "lifecycle": "intent",
            "responseId": None, "completionDigest": None, "role": "predecessor",
            **{key: self.current[key] for key in (
                "originDigest", "incidentId", "operationEpoch", "preparedProofDigest", "evidenceDigest",
            )},
        }

    def finish(self, current):
        request = dict(current["runtimeRequest"], lifecycle="acknowledged",
                       responseId=current["predecessorContainerId"])
        acknowledged = state.advance_state(current, "PREPARED", runtimeRequest=request)
        return state.advance_state(acknowledged, "PREPARED", runtimeRequest=dict(
            request, lifecycle="completed", completionDigest=digest("c"),
        ))

    def test_verified_rollback_retains_completed_predecessor_history_not_unresolved_request(self):
        suppress = self.finish(state.advance_state(self.current, "PREPARED", runtimeRequest=self.request))
        stop = dict(self.request, nonce="7" * 32, sequence=2, operation="stop")
        stopped = self.finish(state.advance_state(suppress, "PREPARED", runtimeRequest=stop))
        for source in (suppress, stopped, state.advance_state(stopped, "CUTOVER_POSSIBLE")):
            rolling = state.advance_state(
                source, "ROLLING_BACK", reason="ROLLBACK_ADMITTED", rollbackIssued=True,
            )
            terminal = state.advance_state(
                rolling, "ROLLED_BACK", reason="ROLLBACK_VERIFIED", terminalReceipt=digest("e"),
            )
            self.assertEqual(source["runtimeRequest"], terminal["runtimeRequest"])
            self.assertEqual("completed", state.require_runtime_request_completion(terminal)["lifecycle"])
            for lifecycle in ("intent", "acknowledged"):
                request = dict(terminal["runtimeRequest"], lifecycle=lifecycle, completionDigest=None)
                if lifecycle == "intent":
                    request["responseId"] = None
                with self.subTest(lifecycle=lifecycle), self.assertRaises(state.GuardError):
                    state._current(dict(terminal, runtimeRequest=request))

    def test_suppression_then_stop_requires_durable_response_and_completion_before_barrier(self):
        suppress = state.advance_state(self.current, "PREPARED", runtimeRequest=self.request)
        for current in (suppress, self.finish(suppress)):
            with self.assertRaises(state.GuardError):
                state.advance_state(current, "CUTOVER_POSSIBLE")
        completed = self.finish(suppress)
        stop = dict(self.request, nonce="7" * 32, sequence=2, operation="stop")
        stopped = self.finish(state.advance_state(completed, "PREPARED", runtimeRequest=stop))
        barrier = state.advance_state(stopped, "CUTOVER_POSSIBLE")
        self.assertEqual("stop", state.require_runtime_request_completion(barrier)["operation"])
        self.assertIsNone(barrier["containerId"])
        self.assertIsNone(barrier["configHash"])

    def test_wrong_identity_authority_operation_or_order_never_creates_request(self):
        for key, value in (
            ("containerId", digest("e")), ("imageId", digest("f")),
            ("executionAttempt", "f" * 32), ("originDigest", digest("f")),
            ("incidentId", "f" * 32), ("operationEpoch", 2),
            ("preparedProofDigest", digest("f")), ("evidenceDigest", digest("f")),
            ("operation", "start"), ("operation", "restore-policy"), ("operation", "stop"),
            ("childAttemptId", "f" * 32 + ":1"), ("role", "candidate"),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(state.GuardError):
                state.advance_state(self.current, "PREPARED", runtimeRequest=dict(self.request, **{key: value}))
        with self.assertRaises(state.GuardError):
            state.advance_state(self.current, "PREPARED", reason="UNRELATED")


class RuntimeRequestTests(unittest.TestCase):
    """Request completion is separate from child reap and inventory observations."""

    def setUp(self):
        self.current = state.advance_state(prepared_state(), "CUTOVER_POSSIBLE")
        self.current = bind_created_state(self.current, digest("c"), digest("d"))
        # Existing-ID tests begin after the independent create/binding protocol.
        self.current = dict(self.current, runtimeRequest=None)
        self.request = {
            "nonce": "9" * 32, "sequence": 1, "executionAttempt": "8" * 32,
            "operation": "stop", "containerId": digest("c"), "imageId": digest("b"),
            "configHash": digest("d"), "childAttemptId": None, "lifecycle": "intent",
            "responseId": None, "completionDigest": None,
        }

    def change(self, current, request):
        return state.advance_state(current, current["phase"], runtimeRequest=request)

    def completed(self):
        intent = self.change(self.current, self.request)
        acknowledged = self.change(intent, dict(
            self.request, lifecycle="acknowledged", responseId=digest("c"),
        ))
        return self.change(acknowledged, dict(
            acknowledged["runtimeRequest"], lifecycle="completed", completionDigest=digest("e"),
        ))

    def test_intent_acknowledgment_revalidation_and_sequence_are_distinct(self):
        intent = self.change(self.current, self.request)
        with self.assertRaises(state.GuardError):
            self.change(intent, dict(
                self.request, lifecycle="completed", responseId=digest("c"), completionDigest=digest("e"),
            ))
        completed = self.completed()
        self.assertEqual(completed["runtimeRequest"], state.require_runtime_request_completion(completed))
        self.assertEqual(completed, self.change(completed, completed["runtimeRequest"]))
        next_request = dict(self.request, nonce="7" * 32, sequence=2)
        second = self.change(completed, next_request)
        with self.assertRaises(state.GuardError):
            self.change(second, completed["runtimeRequest"])

    def test_unknown_timeout_and_client_reap_cannot_clear_or_replace_a_request(self):
        intent = self.change(self.current, self.request)
        acknowledged = self.change(intent, dict(
            self.request, lifecycle="acknowledged", responseId=digest("c"),
        ))
        for current in (self.current, intent, acknowledged):
            with self.subTest(lifecycle=current["runtimeRequest"]), self.assertRaisesRegex(
                state.GuardError, "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED",
            ), mock.patch.object(state, "require_child_group_quiescent"):
                state.require_runtime_request_completion(current)
        for current in (intent, acknowledged):
            for request in (None, dict(self.request, nonce="7" * 32, sequence=2)):
                with self.subTest(request=request), self.assertRaises(state.GuardError):
                    self.change(current, request)
            self.assertEqual(
                current["runtimeRequest"],
                state.advance_state(current, "RECOVERY_REQUIRED")["runtimeRequest"],
            )

    def test_request_identity_response_binding_types_and_completion_replay_are_strict(self):
        intent = self.change(self.current, self.request)
        for field, value in (
            ("containerId", digest("f")), ("imageId", digest("f")),
            ("configHash", digest("f")), ("executionAttempt", "7" * 32),
            ("sequence", 2), ("sequence", True), ("sequence", 1 << 64),
            ("nonce", "private-canary"), ("operation", []), ("lifecycle", []),
            ("childAttemptId", "b" * 32 + ":1"),
        ):
            with self.subTest(field=field), self.assertRaises(state.GuardError) as error:
                self.change(self.current, dict(self.request, **{field: value}))
            self.assertNotIn("private-canary", str(error.exception))
        with self.assertRaises(state.GuardError):
            self.change(intent, dict(
                self.request, lifecycle="acknowledged", responseId=digest("f"),
            ))
        completed = self.completed()
        with self.assertRaises(state.GuardError):
            self.change(completed, dict(completed["runtimeRequest"], completionDigest=digest("f")))
        with self.assertRaises(state.GuardError):
            self.change(completed, self.request)

    def test_recovery_adoption_requires_completion_and_never_replaces_old_execution_ownership(self):
        lease = execution_lease(attempt="6" * 32, lifecycle="armed", operation="forward-recover")
        current = dict(self.completed(), executionAttempt=None)
        adopted = state.adopt_recovery_state(current, lease)
        self.assertEqual(lease["attempt"], adopted["executionAttempt"])
        self.assertEqual(current["runtimeRequest"], adopted["runtimeRequest"])
        self.assertEqual(adopted, state.adopt_recovery_state(adopted, lease))
        for bad in (
            dict(current, executionAttempt="5" * 32),
            dict(current, runtimeRequest=None),
            dict(current, runtimeRequest=self.request),
        ):
            with self.subTest(current=bad), self.assertRaises(state.GuardError):
                state.adopt_recovery_state(bad, lease)
        for field, value in (
            ("operation", "deploy"), ("workerMode", "rollback-worker"),
            ("lifecycle", "registered"), ("firstFailure", "TERM"),
        ):
            with self.subTest(field=field), self.assertRaises(state.GuardError):
                state.adopt_recovery_state(current, dict(lease, **{field: value}))

    def test_acknowledged_request_reconciliation_is_nonce_bound_not_an_intent_override(self):
        lease = execution_lease(attempt="6" * 32, lifecycle="armed", operation="forward-recover")
        intent = self.change(self.current, self.request)
        acknowledged = self.change(intent, dict(
            self.request, lifecycle="acknowledged", responseId=digest("c"),
        ))
        proof = {"requestNonce": self.request["nonce"], "completionDigest": digest("e")}
        current = dict(acknowledged, executionAttempt=None)
        adopted = state.adopt_recovery_state(current, lease, request_proof=proof)
        self.assertEqual("completed", adopted["runtimeRequest"]["lifecycle"])
        for bad_current, bad_proof in (
            (dict(intent, executionAttempt=None), proof),
            (current, dict(proof, requestNonce="7" * 32)),
            (current, dict(proof, completionDigest=None)),
        ):
            with self.subTest(proof=bad_proof), self.assertRaises(state.GuardError):
                state.adopt_recovery_state(bad_current, lease, request_proof=bad_proof)


class CreateRequestTests(unittest.TestCase):
    def setUp(self):
        self.barrier = state.advance_state(
            prepared_state(), "CUTOVER_POSSIBLE", executionAttempt="8" * 32,
        )
        self.child = owned_child()
        self.request = create_request(self.barrier, self.child)
        self.intent = state.advance_state(
            self.barrier, self.barrier["phase"], ownedChild=self.child,
            latestAttemptId=self.child["attemptId"], runtimeRequest=self.request,
        )

    def drained(self):
        current = self.intent
        for lifecycle in ("released", "reaped"):
            current = state.advance_state(
                current, current["phase"], ownedChild=dict(self.child, lifecycle=lifecycle),
            )
        return current

    def normal_completed(self):
        current = self.intent
        token = state._CREATE_COMPLETION_PUBLICATION.set(True)
        try:
            return state.advance_state(
                current, current["phase"], ownedChild=None, runtimeRequest=dict(
                    self.request, lifecycle="normal-completed", completionDigest=digest("5"),
                ),
            )
        finally:
            state._CREATE_COMPLETION_PUBLICATION.reset(token)

    def test_create_has_two_strict_edges_and_binds_only_after_normal_completion(self):
        completed = self.normal_completed()
        bound = bind_created_state(self.barrier, digest("c"), digest("d"))
        self.assertEqual("bound", bound["runtimeRequest"]["lifecycle"])
        self.assertEqual(bound["runtimeRequest"], state.require_runtime_request_completion(bound))
        self.assertEqual(completed["runtimeRequest"], state.require_create_normal_completion(completed))
        self.assertEqual(bound, state.advance_state(bound, bound["phase"]))
        self.assertLess(len(state._canonical(bound)), state.MAX_CURRENT_BYTES)
        self.assertLess(len(state._canonical({"changes": {"runtimeRequest": self.request}})),
                        state.MAX_CHANGES_BYTES)
        for current in (self.intent, self.drained(), completed):
            with self.subTest(lifecycle=current["runtimeRequest"]["lifecycle"]), self.assertRaises(state.GuardError):
                state.require_runtime_request_completion(current)
        with self.assertRaises(state.GuardError):
            state.require_create_normal_completion(self.intent)
        with self.assertRaises(state.GuardError):
            state.advance_state(
                self.drained(), self.barrier["phase"], containerId=digest("c"), configHash=digest("d"),
                runtimeRequest=dict(self.request, lifecycle="bound", containerId=digest("c"),
                                    configHash=digest("d"), responseId=digest("c"), completionDigest=digest("5")),
            )

    def test_every_create_identity_is_immutable_and_must_match_the_incident(self):
        completed = self.normal_completed()
        for key, value in (
            ("nonce", "6" * 32), ("sequence", 2), ("executionAttempt", "7" * 32),
            ("originDigest", digest("f")), ("operationEpoch", 2), ("incidentId", "f" * 32),
            ("operationToken", "6" * 32), ("modelDigest", digest("8")),
            ("preparedProofDigest", digest("8")), ("toolingDigest", digest("8")),
            ("resourcesDigest", digest("8")), ("resourceRequestDigest", digest("8")),
            ("role", "replacement"), ("priorContainerId", digest("c")),
            ("childAttemptId", self.child["attemptId"].replace(":1", ":2")),
            ("childIdentity", dict(self.request["childIdentity"], startTicks=999)),
            ("imageId", digest("c")), ("operation", "start"), ("extra", True),
        ):
            request = dict(completed["runtimeRequest"], **{key: value})
            with self.subTest(key=key), self.assertRaises(state.GuardError):
                state.advance_state(completed, completed["phase"], runtimeRequest=request)
        for key in self.request:
            request = dict(self.request)
            request.pop(key)
            with self.subTest(missing=key), self.assertRaises(state.GuardError):
                state.runtime_request(request)

    def test_resource_digests_are_required_lowercase_sha256_at_every_create_lifecycle(self):
        completed = self.normal_completed()
        bound = bind_created_state(self.barrier, digest("c"), digest("d"))
        invalid = (None, True, 1, "", "a" * 63, "a" * 65, "A" * 64,
                   "x" * 64, "a" * 64 + "\n", [], {}, "private-canary")
        for current in (self.intent, completed, bound):
            request = current["runtimeRequest"]
            self.assertEqual(request, state.runtime_request(request))
            for key in ("resourcesDigest", "resourceRequestDigest"):
                missing = dict(request)
                missing.pop(key)
                with self.subTest(lifecycle=request["lifecycle"], missing=key), \
                        self.assertRaises(state.GuardError):
                    state.runtime_request(missing)
                for value in invalid:
                    with self.subTest(lifecycle=request["lifecycle"], key=key, value=value), \
                            self.assertRaises(state.GuardError) as error:
                        state.runtime_request(dict(request, **{key: value}))
                    self.assertNotIn("private-canary", str(error.exception))

    def test_resource_digests_are_immutable_across_completion_binding_and_replay(self):
        drained = self.drained()
        completed = self.normal_completed()
        bound = bind_created_state(self.barrier, digest("c"), digest("d"))
        for previous, candidate in (
            (drained, completed), (completed, bound), (bound, bound),
        ):
            for key in ("resourcesDigest", "resourceRequestDigest"):
                request = dict(candidate["runtimeRequest"], **{key: digest("f")})
                with self.subTest(edge=(previous["runtimeRequest"]["lifecycle"],
                                       candidate["runtimeRequest"]["lifecycle"]), key=key), \
                        self.assertRaisesRegex(state.GuardError, "RUNTIME_REQUEST_CONFLICT"):
                    state.advance_state(
                        previous, candidate["phase"], runtimeRequest=request,
                        containerId=candidate["containerId"], configHash=candidate["configHash"],
                    )
        for previous, candidate in ((completed, self.intent), (bound, completed)):
            with self.subTest(replay=candidate["runtimeRequest"]["lifecycle"]), \
                    self.assertRaises(state.GuardError):
                state.advance_state(previous, previous["phase"], runtimeRequest=candidate["runtimeRequest"])

    def test_create_request_digest_binds_both_opaque_resource_digests(self):
        # State accepts the digest of private canonical membership bytes; its
        # schema and Docker semantics belong to the provider comparator.
        baseline = state._canonical({"members": ["postgres"], "endpoint": "fixture"})
        request = dict(self.request, resourceRequestDigest=hashlib.sha256(baseline).hexdigest())
        expected = hashlib.sha256(state._canonical(request)).hexdigest()
        self.assertEqual(expected, state.create_request_digest(request))
        completed = dict(request, lifecycle="normal-completed", completionDigest=digest("5"))
        bound = dict(completed, lifecycle="bound", containerId=digest("c"),
                     configHash=digest("d"), responseId=digest("c"))
        for value in (completed, bound):
            self.assertEqual(expected, state.create_request_digest(value))
        for key in ("resourcesDigest", "resourceRequestDigest"):
            self.assertNotEqual(
                expected, state.create_request_digest(dict(request, **{key: digest("f")})),
            )

    def test_non_create_request_schema_does_not_accept_resource_binding_fields(self):
        for operation in ("start", "stop", "suppress", "restore-policy"):
            request = {
                "nonce": "9" * 32, "sequence": 1, "executionAttempt": "8" * 32,
                "operation": operation, "containerId": digest("c"), "imageId": digest("b"),
                "configHash": digest("d"), "childAttemptId": None, "lifecycle": "intent",
                "responseId": None, "completionDigest": None,
            }
            self.assertEqual(request, state.runtime_request(request))
            for key in ("resourcesDigest", "resourceRequestDigest"):
                with self.subTest(operation=operation, key=key), self.assertRaises(state.GuardError):
                    state.runtime_request(dict(request, **{key: digest("f")}))

    def test_same_nonce_cannot_change_request_schema_and_malformed_target_is_fixed_error(self):
        old = self.normal_completed()
        request = {
            key: value for key, value in old["runtimeRequest"].items()
            if key not in state.CREATE_REQUEST_FIELDS
        }
        request.update(operation="stop", lifecycle="intent", childAttemptId=None,
                       containerId=digest("c"), configHash=digest("d"), completionDigest=None)
        candidate = dict(old, runtimeRequest=request, containerId=digest("c"), configHash=digest("d"))
        with self.assertRaises(state.GuardError):
            state._validate_runtime_request_transition(old, candidate)
        for target in ({}, {"tuple": {}}, [], "invalid"):
            with self.subTest(target=target), self.assertRaises(state.GuardError):
                state._current(dict(self.intent, target=target))

    def test_unknown_cancelled_missing_or_late_acknowledgment_cannot_start_or_replace(self):
        for current in (self.intent, self.drained(), self.normal_completed()):
            for phase in ("VERIFYING", "ROLLING_BACK", "FORWARD_RECOVERING"):
                with self.subTest(phase=phase), self.assertRaises(state.GuardError):
                    state.advance_state(current, phase)
            recovery = state.advance_state(current, "RECOVERY_REQUIRED")
            self.assertEqual(current["runtimeRequest"], recovery["runtimeRequest"])
            for request in (
                None, dict(self.request, nonce="5" * 32, sequence=2),
                dict(self.request, operation="stop", childAttemptId=None),
            ):
                with self.subTest(request=request), self.assertRaises(state.GuardError):
                    state.advance_state(current, current["phase"], runtimeRequest=request)
            with self.assertRaises(state.GuardError):
                state.advance_state(current, current["phase"], containerId=digest("c"), configHash=digest("d"))
        for lifecycle in ("acknowledged", "completed", "cancelled", "timeout", "late", None):
            with self.subTest(lifecycle=lifecycle), self.assertRaises(state.GuardError):
                state.runtime_request(dict(self.request, lifecycle=lifecycle))
        with self.assertRaises(state.GuardError):
            state.advance_state(self.intent, self.intent["phase"], runtimeRequest=dict(
                self.request, lifecycle="normal-completed", completionDigest=digest("5"),
            ))
        completed = self.normal_completed()
        with self.assertRaises(state.GuardError):
            state.advance_state(completed, completed["phase"], runtimeRequest=dict(
                completed["runtimeRequest"], completionDigest=digest("6"),
            ))

    def test_only_supervisor_completion_clears_the_matching_waiting_create_child(self):
        waiting = self.intent
        with self.assertRaisesRegex(state.GuardError, "CREATE_COMPLETION_SUPERVISOR_REQUIRED"):
            state.advance_state(waiting, waiting["phase"], ownedChild=None)
        with self.assertRaisesRegex(state.GuardError, "CREATE_COMPLETION_SUPERVISOR_REQUIRED"):
            state.advance_state(
                waiting, waiting["phase"], ownedChild=None,
                runtimeRequest=dict(
                    self.request, lifecycle="normal-completed", completionDigest=digest("5"),
                ),
            )
        matching = state._require_matching_create_child(waiting)
        self.assertEqual("waiting", matching["lifecycle"])
        self.assertEqual(
            self.request["childIdentity"],
            {key: matching[key] for key in state.CHILD_IDENTITY_FIELDS},
        )
        mismatched = dict(waiting, runtimeRequest=dict(
            self.request,
            childIdentity=dict(self.request["childIdentity"], startTicks=self.child["startTicks"] + 1),
        ))
        with self.assertRaises(state.GuardError):
            state._require_matching_create_child(mismatched)
        released = dict(waiting, ownedChild=dict(self.child, lifecycle="released"))
        self.assertEqual("released", state._require_matching_create_child(released)["lifecycle"])
        token = state._CREATE_COMPLETION_PUBLICATION.set(True)
        try:
            completed = state.advance_state(
                waiting, waiting["phase"], ownedChild=None, runtimeRequest=dict(
                    self.request, lifecycle="normal-completed", completionDigest=digest("5"),
                ),
            )
        finally:
            state._CREATE_COMPLETION_PUBLICATION.reset(token)
        self.assertIsNone(completed["ownedChild"])
        self.assertEqual("normal-completed", completed["runtimeRequest"]["lifecycle"])

    def test_binding_must_keep_completion_and_reject_predecessor_response_and_hash_mismatch(self):
        completed = self.normal_completed()
        request = dict(completed["runtimeRequest"], lifecycle="bound", containerId=digest("c"),
                       configHash=digest("d"), responseId=digest("c"))
        for changes in (
            {"containerId": digest("e")}, {"configHash": digest("e")},
            {"completionDigest": digest("e")}, {"responseId": digest("e")},
            {"containerId": self.barrier["predecessorContainerId"],
             "responseId": self.barrier["predecessorContainerId"]},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                state.advance_state(
                    completed, completed["phase"], containerId=digest("c"), configHash=digest("d"),
                    runtimeRequest=dict(request, **changes),
                )

    def test_replacement_authorization_requires_bound_publication_and_never_rewrites_witness(self):
        current = bind_created_state(self.barrier, digest("c"), digest("d"))
        current = state.advance_state(current, "VERIFYING")
        current = state.advance_state(
            current, "COMMITTING", commitWitnessDigest=digest("e"),
            providerFinalizationDigest=digest("f"), commitSubstep="provider-cleanup",
        )
        current = state.advance_state(current, "COMMITTING", commitSubstep="replacement-create-intent")
        with self.assertRaises(state.GuardError):
            state.advance_state(current, current["phase"], containerId=digest("b"),
                                commitSubstep="replacement-container-authorized")
        replacement = bind_created_state(current, digest("b"), current["configHash"], replacement=True)
        self.assertEqual("bound", replacement["runtimeRequest"]["lifecycle"])
        self.assertEqual(current["commitWitnessDigest"], replacement["commitWitnessDigest"])
        self.assertEqual(current["providerFinalizationDigest"], replacement["providerFinalizationDigest"])
        self.assertEqual(current["configHash"], replacement["configHash"])
        for key in ("operationToken", "modelDigest", "toolingDigest", "preparedProofDigest"):
            self.assertEqual(current["runtimeRequest"][key], replacement["runtimeRequest"][key])
        with self.assertRaises(state.GuardError):
            bind_created_state(replacement, digest("e"), current["configHash"], replacement=True)

    def test_completion_requires_canonical_receipt_exact_lease_evidence_and_final_acknowledgment(self):
        current = self.normal_completed()
        request = current["runtimeRequest"]
        receipt = {
            "schema": state.CREATE_COMPLETION_SCHEMA,
            "requestDigest": state.create_request_digest(request),
            "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
            "resourcesDigest": request["resourcesDigest"],
            "resourceRequestDigest": request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
        }
        raw = state._canonical(receipt)
        request = dict(request, completionDigest=hashlib.sha256(raw).hexdigest())
        current = dict(current, runtimeRequest=request)
        lease = execution_lease(attempt=request["executionAttempt"], lifecycle="armed")
        evidence = {
            **{key: value for key, value in receipt.items() if key != "schema"},
            "receiptDigest": request["completionDigest"], "acknowledged": False,
        }
        lease["createCompletion"] = evidence
        state._execution_lease(lease)
        state.validate_create_completion(current, lease, raw, acknowledged=False)
        with self.assertRaises(state.GuardError):
            state.validate_create_completion(current, lease, raw, acknowledged=True)
        lease["createCompletion"] = dict(evidence, acknowledged=True)
        state.validate_create_completion(current, lease, raw, acknowledged=True)
        for changed_raw in (b"", b"{}", raw + b" ", raw.replace(b'"waitStatus":0', b'"waitStatus":1')):
            with self.subTest(receipt=changed_raw), self.assertRaises(state.GuardError):
                state.validate_create_completion(current, lease, changed_raw, acknowledged=True)
        for field, value in (
            ("receiptDigest", digest("0")), ("requestDigest", digest("0")),
            ("resourcesDigest", digest("f")), ("resourceRequestDigest", digest("f")),
            ("executionAttempt", "0" * 32), ("childIdentity", dict(request["childIdentity"], startTicks=1)),
            ("waitStatus", True), ("waitStatus", 1), ("uncancelled", False),
            ("descendantsDrained", False), ("acknowledged", False), ("extra", True),
        ):
            with self.subTest(field=field), self.assertRaises(state.GuardError):
                state.validate_create_completion(
                    current, dict(lease, createCompletion=dict(lease["createCompletion"], **{field: value})),
                    raw, acknowledged=True,
                )
        with self.assertRaises(state.GuardError):
            state.validate_create_completion(current, dict(lease, createCompletion=None), raw, acknowledged=True)
        for changed in (
            dict(lease["createCompletion"], acknowledged=False), None,
            dict(lease["createCompletion"], receiptDigest=digest("0")),
        ):
            candidate = dict(lease, revision=lease["revision"] + 1, createCompletion=changed)
            with self.subTest(evidence=changed), self.assertRaises(state.GuardError):
                state._validate_lease_successor(lease, candidate)

    def test_completion_receipt_and_lease_cannot_substitute_resource_bindings(self):
        current = self.normal_completed()
        request = current["runtimeRequest"]
        receipt = {
            "schema": state.CREATE_COMPLETION_SCHEMA,
            "requestDigest": state.create_request_digest(request),
            "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
            "resourcesDigest": request["resourcesDigest"],
            "resourceRequestDigest": request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
        }

        def completion_context(value, *, acknowledged=True):
            raw = state._canonical(value)
            completed = dict(current, runtimeRequest=dict(
                request, completionDigest=hashlib.sha256(raw).hexdigest(),
            ))
            evidence = {
                **{key: item for key, item in value.items() if key != "schema"},
                "receiptDigest": completed["runtimeRequest"]["completionDigest"],
                "acknowledged": acknowledged,
            }
            lease = execution_lease(attempt=request["executionAttempt"], lifecycle="armed")
            return completed, dict(lease, createCompletion=evidence), raw

        completed, lease, raw = completion_context(receipt)
        state.validate_create_completion(completed, lease, raw, acknowledged=True)
        for key in ("resourcesDigest", "resourceRequestDigest"):
            for value in (None, True, "", "a" * 63, "A" * 64, "x" * 64):
                bad_evidence = dict(lease["createCompletion"], **{key: value})
                with self.subTest(key=key, value=value), self.assertRaises(state.GuardError):
                    state._execution_lease(dict(lease, createCompletion=bad_evidence))
            missing_evidence = dict(lease["createCompletion"])
            missing_evidence.pop(key)
            with self.subTest(missing=key), self.assertRaises(state.GuardError):
                state._execution_lease(dict(lease, createCompletion=missing_evidence))
            for wrong in (dict(receipt, **{key: digest("f")}),
                          {name: value for name, value in receipt.items() if name != key}):
                # Even internally consistent receipt/current/lease hashes cannot
                # acknowledge resource evidence from a different request.
                changed_current, changed_lease, changed_raw = completion_context(wrong)
                with self.subTest(receipt=wrong, key=key), self.assertRaises(state.GuardError):
                    state.validate_create_completion(
                        changed_current, changed_lease, changed_raw, acknowledged=True,
                    )
            replayed_current = dict(completed, runtimeRequest=dict(
                completed["runtimeRequest"], **{key: digest("f")},
            ))
            with self.subTest(replayed_request=key), self.assertRaises(state.GuardError):
                state.validate_create_completion(replayed_current, lease, raw, acknowledged=True)
            _, pending, _ = completion_context(receipt, acknowledged=False)
            acknowledged = dict(pending, revision=pending["revision"] + 1, createCompletion=dict(
                pending["createCompletion"], acknowledged=True,
            ))
            state._validate_lease_successor(pending, acknowledged)
            for previous, candidate in ((pending, acknowledged), (lease, dict(
                lease, revision=lease["revision"] + 1,
            ))):
                changed = dict(candidate, createCompletion=dict(
                    candidate["createCompletion"], **{key: digest("f")},
                ))
                with self.subTest(lease_mutation=key, acknowledged=previous["createCompletion"]["acknowledged"]), \
                        self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_COMPLETION_CONFLICT"):
                    state._validate_lease_successor(previous, changed)

    def test_supervisor_publication_stages_receipt_before_current_and_never_repairs_fragments(self):
        for fault in (
            "none", "existing", "wrong-evidence", "receipt-write", "receipt-readback", "state-write",
        ):
            current = self.intent
            request = current["runtimeRequest"]
            receipt = {
                "schema": state.CREATE_COMPLETION_SCHEMA,
                "requestDigest": state.create_request_digest(request),
                "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
                "resourcesDigest": request["resourcesDigest"],
                "resourceRequestDigest": request["resourceRequestDigest"],
                "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
            }
            raw = state._canonical(receipt)
            receipt_digest = hashlib.sha256(raw).hexdigest()
            lease = execution_lease(attempt=request["executionAttempt"], lifecycle="armed")
            lease["createCompletion"] = {
                **{key: value for key, value in receipt.items() if key != "schema"},
                "receiptDigest": receipt_digest, "acknowledged": False,
            }
            if fault == "wrong-evidence":
                lease["createCompletion"]["resourceRequestDigest"] = digest("f")
            events = []
            persisted = [current]

            def write(*args, **kwargs):
                events.append("receipt-write")
                if fault == "receipt-write":
                    raise OSError("synthetic")

            def publish(root, candidate):
                self.assertTrue(state._CREATE_COMPLETION_PUBLICATION.get())
                self.assertIsNone(candidate["ownedChild"])
                self.assertEqual("normal-completed", candidate["runtimeRequest"]["lifecycle"])
                events.append("state-write")
                if fault == "state-write":
                    raise OSError("synthetic")
                persisted[0] = candidate
                return candidate

            with self.subTest(fault=fault), ExitStack() as stack:
                stack.enter_context(mock.patch.object(state, "deploy_lock", return_value=nullcontext(9)))
                authority = stack.enter_context(mock.patch.object(
                    state, "_execution_mutation", return_value=nullcontext(),
                ))
                stack.enter_context(mock.patch.object(state, "_read_guard_locked",
                                                      side_effect=lambda root: ({}, persisted[0])))
                stack.enter_context(mock.patch.object(state, "_read_execution_lease_locked", return_value=lease))
                stack.enter_context(mock.patch.object(state, "_open_root", return_value=11))
                stack.enter_context(mock.patch.multiple(
                    state.os, O_DIRECTORY=getattr(os, "O_DIRECTORY", 0),
                    O_NOFOLLOW=getattr(os, "O_NOFOLLOW", 0), create=True,
                ))
                stack.enter_context(mock.patch.object(state.os, "open", return_value=12))
                stack.enter_context(mock.patch.object(state.os, "close"))
                stack.enter_context(mock.patch.object(state.os, "fstat", return_value=SimpleNamespace(
                    st_uid=0, st_mode=stat.S_IFDIR | 0o700,
                )))
                stack.enter_context(mock.patch.object(
                    state.os, "stat", **({"return_value": mock.Mock()} if fault == "existing"
                                        else {"side_effect": FileNotFoundError}),
                ))
                stack.enter_context(mock.patch.object(state, "_require_no_acl"))
                stack.enter_context(mock.patch.object(state, "_atomic_write", side_effect=write))
                stack.enter_context(mock.patch.object(state, "_read_at",
                                                      return_value=b"bad" if fault == "receipt-readback" else raw))
                stack.enter_context(mock.patch.object(state, "_publish_current_locked", side_effect=publish))
                stack.enter_context(mock.patch.object(state, "_require_create_completion_locked"))
                grant = state.ExecutionGrant(request["executionAttempt"], "1" * 32, 200)
                if fault == "none":
                    self.assertEqual({"receiptDigest": receipt_digest, "sequence": 1}, state.publish_create_completion(
                        "/state", request_digest=receipt["requestDigest"],
                        supervisor_wait_evidence=raw,
                        deploy_lock_fd=9, execution_grant=grant,
                    ))
                    self.assertEqual(["receipt-write", "state-write"], events)
                else:
                    with self.assertRaises((state.GuardError, OSError)):
                        state.publish_create_completion(
                            "/state", request_digest=receipt["requestDigest"],
                            supervisor_wait_evidence=raw,
                            deploy_lock_fd=9, execution_grant=grant,
                        )
                    if fault == "wrong-evidence":
                        self.assertEqual([], events)
                authority.assert_called_once_with("/state", 9, grant, create_completion_only=True)
                self.assertFalse(state._CREATE_COMPLETION_PUBLICATION.get())

    def test_private_cli_refuses_incomplete_capability_before_reading_receipt(self):
        args = ["publish-create-completion", "--root", "/state", "--deploy-lock-fd", "9",
                "--request-digest", digest("1")]
        for extra in ([], ["--execution-attempt", "1" * 32]):
            with (
                mock.patch.object(state, "publish_create_completion") as publish,
                mock.patch.object(state.sys, "stdin") as stdin,
                mock.patch.object(state.sys, "stderr", io.StringIO()),
            ):
                self.assertEqual(2, state.main(args + extra))
            publish.assert_not_called()
            stdin.buffer.read.assert_not_called()


class StaleRecoveryLeaseTests(unittest.TestCase):
    change = RuntimeRequestTests.change
    completed = RuntimeRequestTests.completed

    def setUp(self):
        RuntimeRequestTests.setUp(self)
        self.previous = execution_lease(attempt="8" * 32, lifecycle="drained", revision=4)
        self.previous.update(firstFailure="EXIT", firstStatus=1)
        self.previous["workers"] = [{
            "mode": "controller-worker", **self.previous["supervisor"], "pid": 102,
        }]
        self.candidate = execution_lease(attempt="6" * 32, operation="forward-recover")
        self.candidate["supervisor"] = {**self.previous["supervisor"], "pid": 201}
        self.candidate["worker"] = {**self.candidate["supervisor"], "pid": 202}
        self.candidate["workers"] = [{"mode": "controller-worker", **self.candidate["worker"]}]
        self.current = self.completed()
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.exited = self.stack.enter_context(mock.patch.object(
            state, "_execution_process_exited", return_value=True,
        ))
        worker = self.candidate["worker"]
        self.process = self.stack.enter_context(mock.patch.object(
            state, "_execution_process_record", return_value=(
                worker["bootId"], worker["startTicks"], self.candidate["supervisor"]["pid"],
            ),
        ))
        self.live = self.stack.enter_context(mock.patch.object(
            state, "_execution_lease_supervisor_is_live", return_value=True,
        ))

    def validate(self, previous=None, candidate=None, current=None):
        state._validate_recovery_lease_successor(
            self.previous if previous is None else previous,
            self.candidate if candidate is None else candidate,
            self.current if current is None else current,
        )

    def test_complete_kernel_request_and_same_incident_proofs_pass_without_mutation(self):
        before = json.dumps((self.previous, self.candidate, self.current), sort_keys=True)
        self.validate()
        self.assertEqual(before, json.dumps((self.previous, self.candidate, self.current), sort_keys=True))
        self.assertEqual(
            [mock.call(identity) for identity in (
                self.previous["supervisor"], *self.previous["workers"],
            )], self.exited.call_args_list,
        )

    def test_acknowledged_create_reconciliation_keeps_proof_through_validation_only(self):
        fixture = CreateRequestTests()
        fixture.setUp()
        completed = fixture.normal_completed()
        request = completed["runtimeRequest"]
        receipt = {
            "schema": state.CREATE_COMPLETION_SCHEMA,
            "requestDigest": state.create_request_digest(request),
            "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
            "resourcesDigest": request["resourcesDigest"],
            "resourceRequestDigest": request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
        }
        raw = state._canonical(receipt)
        completed = dict(completed, runtimeRequest=dict(
            request, completionDigest=hashlib.sha256(raw).hexdigest(),
        ))
        previous = dict(self.previous, createCompletion={
            **{key: value for key, value in receipt.items() if key != "schema"},
            "receiptDigest": completed["runtimeRequest"]["completionDigest"], "acknowledged": True,
        })
        for fault in (
            "none", "receipt", "unacknowledged", "erased", "changed-request", "provider",
            "missing-runtime", "before-current", "before-lease", "successor-validation",
        ):
            with self.subTest(fault=fault), ExitStack() as stack:
                for name in ("O_DIRECTORY", "O_NOFOLLOW"):
                    stack.enter_context(mock.patch.object(
                        state.os, name, getattr(state.os, name, 0), create=True,
                    ))
                lease = dict(previous)
                if fault == "unacknowledged":
                    lease["createCompletion"] = dict(lease["createCompletion"], acknowledged=False)
                elif fault == "erased":
                    lease["createCompletion"] = None
                files = {"lease": lease, "current": completed}
                writes = []
                stack.enter_context(mock.patch.object(
                    state, "_read_execution_lease_locked", side_effect=lambda _root: files["lease"],
                ))
                stack.enter_context(mock.patch.object(
                    state, "_read_guard_locked", side_effect=lambda _root: ({}, files["current"]),
                ))

                def require(_root, current, *, acknowledged):
                    state.validate_create_completion(
                        current, files["lease"], b"{}" if fault == "receipt" else raw,
                        acknowledged=acknowledged,
                    )

                stack.enter_context(mock.patch.object(
                    state, "_require_create_completion_locked", side_effect=require,
                ))
                provider = SimpleNamespace(ProviderError=RuntimeError)

                def proof(*args, **kwargs):
                    self.assertTrue(kwargs.get("create_completion_recovery"))
                    self.assertTrue(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
                    if fault == "provider":
                        raise provider.ProviderError("private proof refused")
                    if fault == "changed-request":
                        return dict(completed["runtimeRequest"], resourcesDigest=digest("f"))
                    return completed["runtimeRequest"]

                provider._recovery_lease_runtime_proof = mock.Mock(side_effect=proof)
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "spec_from_file_location",
                    return_value=SimpleNamespace(loader=mock.Mock()),
                ))
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "module_from_spec", return_value=provider,
                ))
                if fault == "successor-validation":
                    stack.enter_context(mock.patch.object(
                        state, "_validate_recovery_lease_successor",
                        side_effect=state.GuardError("EXECUTION_LEASE_UNRESOLVED"),
                    ))
                stack.enter_context(mock.patch.object(state, "_open_root", return_value=10))
                stack.enter_context(mock.patch.object(state.os, "open", return_value=11))
                stack.enter_context(mock.patch.object(state.os, "close"))

                def write(_fd, name, data, _limit, **_kwargs):
                    self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
                    key = "current" if name == "current.json" else "lease"
                    if fault == "before-" + key:
                        raise OSError("synthetic write failure")
                    files[key] = json.loads(data)
                    writes.append(key)

                stack.enter_context(mock.patch.object(state, "_atomic_write", side_effect=write))
                stack.enter_context(mock.patch.object(
                    state, "_read_at", side_effect=lambda _fd, name, _limit: state._canonical(
                        files["current" if name == "current.json" else "lease"],
                    ),
                ))
                check = mock.Mock()
                args = ("/fixture", lease, self.candidate, completed, b"{}", (
                    None if fault == "missing-runtime" else b"{}"
                ), 9, check)
                if fault == "none":
                    result = state._reconcile_recovery_lease_locked(*args)
                    self.assertEqual(["current", "lease"], writes)
                    self.assertEqual(self.candidate["attempt"], files["current"]["executionAttempt"])
                    self.assertEqual(completed["runtimeRequest"], files["current"]["runtimeRequest"])
                    self.assertIsNone(files["current"]["containerId"])
                    self.assertEqual(previous["createCompletion"], files["lease"]["createCompletion"])
                    self.assertEqual(hashlib.sha256(state._canonical(files["lease"])).hexdigest(),
                                     result["digest"])
                    state.validate_create_completion(
                        files["current"], files["lease"], raw, acknowledged=True,
                    )
                    with self.assertRaises(state.GuardError):
                        # A successful handoff cannot be replayed as old ownership.
                        state._reconcile_recovery_lease_locked(*args)
                else:
                    with self.assertRaises(state.GuardError):
                        state._reconcile_recovery_lease_locked(*args)
                    self.assertEqual(["current"] if fault == "before-lease" else [], writes)
                self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
                with self.assertRaises(state.GuardError):
                    state.require_runtime_request_completion(completed)

    def test_missing_childlessness_overflow_and_unbound_descendants_never_admit(self):
        for lifecycle in (
            "registered", "armed", "cancel-forward", "drain-forward",
            "rollback-admission", "rolling-back", "draining", "quiescence-unconfirmed",
        ):
            with self.subTest(lifecycle=lifecycle), self.assertRaises(state.GuardError):
                self.validate(previous=dict(self.previous, lifecycle=lifecycle))
        for changes in (
            {"worker": self.previous["supervisor"]}, {"workers": []},
            {"firstFailure": "DESCENDANT_OVERFLOW"}, {"firstFailure": "OWNERSHIP_UNCERTAIN"},
            {"operation": "retention"},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                self.validate(previous=dict(self.previous, **changes))

    def test_every_recorded_process_must_have_definitively_exited(self):
        for identity in (self.previous["supervisor"], *self.previous["workers"]):
            self.exited.side_effect = lambda row: row != identity
            with self.subTest(identity=identity), self.assertRaises(state.GuardError):
                self.validate()
        self.exited.side_effect = state.GuardError("EXECUTION_LEASE_UNRESOLVED")
        with self.assertRaises(state.GuardError):
            self.validate()

    def test_new_worker_parent_supervisor_and_attempt_must_be_bound(self):
        for record in (None, ("different-boot", 1, 201), (
            self.candidate["worker"]["bootId"], self.candidate["worker"]["startTicks"], 999,
        )):
            self.process.return_value = record
            with self.subTest(record=record), self.assertRaises(state.GuardError):
                self.validate()
        for changes in (
            {"attempt": self.previous["attempt"]}, {"operation": "deploy"},
            {"lifecycle": "armed"}, {"revision": 1}, {"worker": None},
            {"workers": []}, {"workerMode": "rollback-worker"}, {"rollbackIssued": True},
            {"firstFailure": "TERM", "firstStatus": 143},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                self.validate(candidate=dict(self.candidate, **changes))
        worker = self.candidate["worker"]
        self.process.return_value = (
            worker["bootId"], worker["startTicks"], self.candidate["supervisor"]["pid"],
        )
        self.live.return_value = False
        with self.assertRaises(state.GuardError):
            self.validate()

    def test_owned_child_requires_matching_request_exit_and_empty_process_group(self):
        child = owned_child(lifecycle="released")
        current = dict(
            self.current, ownedChild=child, latestAttemptId=child["attemptId"],
            runtimeRequest=dict(
                self.current["runtimeRequest"], operation="start", childAttemptId=child["attemptId"],
            ),
        )
        with mock.patch.object(state, "require_child_group_quiescent") as group:
            self.validate(current=current)
            group.assert_called_once_with(child)
            for changes in (
                {"operation": "stop"}, {"childAttemptId": None},
                {"childAttemptId": current["incidentId"] + ":2"},
            ):
                with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                    self.validate(current=dict(
                        current, runtimeRequest=dict(current["runtimeRequest"], **changes),
                    ))
            self.exited.side_effect = lambda row: row != child
            with self.assertRaises(state.GuardError):
                self.validate(current=current)
            self.exited.side_effect = None
            group.side_effect = state.GuardError("OWNED_CHILD_STILL_RUNNING")
            with self.assertRaises(state.GuardError):
                self.validate(current=current)

    def test_missing_intent_acknowledged_and_foreign_attempt_requests_refuse(self):
        for request in (
            None, self.request,
            dict(self.request, lifecycle="acknowledged", responseId=digest("c")),
            dict(self.current["runtimeRequest"], executionAttempt="7" * 32),
        ):
            with self.subTest(request=request), self.assertRaises(state.GuardError):
                self.validate(current=dict(self.current, runtimeRequest=request))
        for changes in (
            {"executionAttempt": None}, {"executionAttempt": "7" * 32},
            {"phase": "PREPARED"}, {"phase": "COMMITTED"},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                self.validate(current=dict(self.current, **changes))

    @unittest.skipUnless(
        sys.platform == "linux" and hasattr(os, "geteuid") and os.geteuid() == 0,
        "durable reconciliation requires isolated Linux root",
    )
    def test_durable_adoption_failures_never_unlock_a_partial_pair_or_issue_runtime_work(self):
        authority = dict(
            rootId="test-root", bootstrapId="reconcile-bootstrap",
            initialRuntime=digest("a"), initialConfig=digest("b"),
            initialSchema=digest("c"), initialStartupInventory=digest("d"),
            schemaHistoryProvenance=True,
        )
        observed = dict(
            rootId="test-root", runtime=digest("a"), config=digest("b"),
            schema=digest("c"), startupInventory=digest("d"), schemaHistoryProvenance=True,
        )
        for fault in (
            "none", "before-current", "after-current", "before-lease", "after-lease",
            "current-file-fsync", "current-dir-fsync", "lease-file-fsync", "lease-dir-fsync",
        ):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as parent, ExitStack() as stack:
                root = pathlib.Path(parent) / "deploy"
                root.mkdir(mode=0o700)
                state.bootstrap_guard(root, authority=authority, observed=observed)
                origin, _ = state.read_guard(root)
                current = dict(self.current, originDigest=origin["originDigest"])
                current_path = root / state.GUARD_DIR / "current.json"
                lease_path = root / state.EXECUTION_LEASE_NAME
                current_path.write_bytes(state._canonical(current))
                lease_path.write_bytes(state._canonical(self.previous))
                lease_path.chmod(0o600)
                provider = SimpleNamespace(
                    ProviderError=RuntimeError,
                    _recovery_lease_runtime_proof=mock.Mock(return_value=current["runtimeRequest"]),
                )
                spec = SimpleNamespace(loader=mock.Mock())
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "spec_from_file_location", return_value=spec,
                ))
                stack.enter_context(mock.patch.object(
                    state.importlib.util, "module_from_spec", return_value=provider,
                ))
                runtime = stack.enter_context(mock.patch.object(subprocess, "run"))
                real_write = state._atomic_write
                real_fsync = state.os.fsync
                syncs = 0

                def sync(fd):
                    nonlocal syncs
                    syncs += 1
                    boundary = {
                        "current-file-fsync": 1, "current-dir-fsync": 2,
                        "lease-file-fsync": 3, "lease-dir-fsync": 4,
                    }.get(fault)
                    if syncs == boundary:
                        raise OSError("synthetic durability fault")
                    real_fsync(fd)

                def write(fd, name, data, limit, *, replace):
                    boundary = "current" if name == "current.json" else "lease"
                    if fault == "before-" + boundary:
                        raise OSError("synthetic publication fault")
                    real_write(fd, name, data, limit, replace=replace)
                    if fault == "after-" + boundary:
                        raise OSError("synthetic publication fault")

                stack.enter_context(mock.patch.object(state, "_atomic_write", side_effect=write))
                stack.enter_context(mock.patch.object(state.os, "fsync", side_effect=sync))
                check = mock.Mock()
                token = state._EXECUTION_CHECK.set(check)
                try:
                    with state.deploy_lock(root) as fd:
                        os.set_inheritable(fd, True)
                        def reconcile():
                            return state._reconcile_recovery_lease_locked(
                                root, self.previous, self.candidate, current, b"{}",
                                b"{}", fd, check,
                            )

                        if fault == "none":
                            result = reconcile()
                            self.assertEqual(self.candidate["attempt"], result["attempt"])
                        else:
                            with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                                reconcile()
                        actual = state._read_guard_locked(root)[1]
                        lease = state._read_execution_lease_locked(root)
                        self.assertEqual(1, actual["operationEpoch"])
                        self.assertEqual(current["incidentId"], actual["incidentId"])
                        self.assertEqual(current["phase"], actual["phase"])
                        if actual["executionAttempt"] != lease["attempt"]:
                            with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                                state.check_execution_lease(root, attempt=lease["attempt"], deploy_lock_fd=fd)
                            with self.assertRaises(state.GuardError):
                                reconcile()
                        elif lease == self.previous:
                            self.assertEqual(current, actual)
                        else:
                            self.assertEqual(self.candidate["attempt"], actual["executionAttempt"])
                            self.assertEqual(self.candidate, lease)
                        with self.assertRaises(state.GuardError):
                            # Public retention/writers never inherit this
                            # private registration grant, even after success.
                            state.check_execution_lease(root)
                        runtime.assert_not_called()
                finally:
                    state._EXECUTION_CHECK.reset(token)


class RecoveryCreateRegistrationTests(unittest.TestCase):
    """Registration handoff uses durable old proof and never repairs fragments."""

    def setUp(self):
        fixture = CreateRequestTests()
        fixture.setUp()
        self.current = fixture.normal_completed()
        request = self.current["runtimeRequest"]
        receipt = {
            "schema": state.CREATE_COMPLETION_SCHEMA,
            "requestDigest": state.create_request_digest(request),
            "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
            "resourcesDigest": request["resourcesDigest"],
            "resourceRequestDigest": request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
        }
        self.receipt = state._canonical(receipt)
        self.current["runtimeRequest"] = dict(
            request, completionDigest=hashlib.sha256(self.receipt).hexdigest(),
        )
        self.previous = execution_lease(attempt="8" * 32, lifecycle="drained", revision=4)
        self.previous.update(firstFailure="EXIT", firstStatus=1)
        self.previous["workers"] = [{"mode": "controller-worker", **self.previous["supervisor"], "pid": 102}]
        self.previous["createCompletion"] = {
            **{key: value for key, value in receipt.items() if key != "schema"},
            "receiptDigest": self.current["runtimeRequest"]["completionDigest"], "acknowledged": True,
        }
        self.candidate = execution_lease(attempt="6" * 32, operation="forward-recover")
        self.candidate.update(t0Ns=1, workEndNs=540_000_000_001, hardEndNs=600_000_000_001)
        self.candidate["supervisor"] = {**self.previous["supervisor"], "pid": 201}
        self.candidate["worker"] = {**self.candidate["supervisor"], "pid": 202}
        self.candidate["workers"] = [{"mode": "controller-worker", **self.candidate["worker"]}]
        self.successor = dict(self.candidate, createCompletion=self.previous["createCompletion"])
        self.adopted = dict(self.current, executionAttempt=self.candidate["attempt"])
        self.baseline = {
            "lease": self.previous,
            "currentDigest": hashlib.sha256(state._canonical(self.current)).hexdigest(),
        }
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        if not hasattr(state.os, "O_DIRECTORY"):
            self.stack.enter_context(mock.patch.object(state.os, "O_DIRECTORY", 0x10000, create=True))
        if not hasattr(state.os, "O_NOFOLLOW"):
            self.stack.enter_context(mock.patch.object(state.os, "O_NOFOLLOW", 0x20000, create=True))
        self.stack.enter_context(mock.patch.object(state, "deploy_lock", return_value=nullcontext(9)))
        self.stack.enter_context(mock.patch.object(state, "_open_root", return_value=55))
        self.stack.enter_context(mock.patch.object(state.os, "open", return_value=56))
        self.stack.enter_context(mock.patch.object(state.os, "close"))
        self.stack.enter_context(mock.patch.object(state.os, "fstat", return_value=SimpleNamespace(
            st_uid=0, st_mode=stat.S_IFDIR | 0o700,
        )))
        self.stack.enter_context(mock.patch.object(state, "_require_no_acl"))
        self.lease_reader = self.stack.enter_context(mock.patch.object(
            state, "_read_execution_lease_locked", return_value=self.successor,
        ))
        self.current_reader = self.stack.enter_context(mock.patch.object(
            state, "_read_guard_locked", return_value=({}, self.adopted),
        ))
        self.receipt_reader = self.stack.enter_context(mock.patch.object(
            state, "_read_at", return_value=self.receipt,
        ))
        self.exited = self.stack.enter_context(mock.patch.object(
            state, "_execution_process_exited", return_value=True,
        ))
        worker = self.candidate["worker"]
        self.stack.enter_context(mock.patch.object(state, "_execution_process_record", return_value=(
            worker["bootId"], worker["startTicks"], self.candidate["supervisor"]["pid"],
        )))
        self.stack.enter_context(mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True))

    def read(self, *, digest_value=None):
        return state._read_recovery_registration_snapshot(
            "/fixture", self.candidate,
            hashlib.sha256(state._canonical(self.successor)).hexdigest() if digest_value is None else digest_value,
            self.baseline, deploy_lock_fd=9,
        )

    def test_exact_normal_completed_and_bound_snapshots_pass_without_mutation_or_context_leak(self):
        for bound in (False, True):
            if bound:
                request = dict(self.current["runtimeRequest"], lifecycle="bound", containerId=digest("c"),
                               configHash=digest("d"), responseId=digest("c"))
                self.current = dict(self.current, runtimeRequest=request, containerId=digest("c"), configHash=digest("d"))
                self.adopted = dict(self.current, executionAttempt=self.candidate["attempt"])
                self.current_reader.return_value = ({}, self.adopted)
                self.baseline["currentDigest"] = hashlib.sha256(state._canonical(self.current)).hexdigest()
            before = state._canonical(self.successor)
            with self.subTest(bound=bound):
                self.assertEqual(self.successor, self.read())
                self.assertEqual(before, state._canonical(self.successor))
                self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
                if not bound:
                    with self.assertRaises(state.GuardError):
                        state.require_runtime_request_completion(self.adopted)

    def test_missing_mutated_or_unacknowledged_completion_never_imports(self):
        evidence = self.successor["createCompletion"]
        for changed in (
            None, dict(evidence, acknowledged=False), dict(evidence, requestDigest=digest("f")),
            dict(evidence, receiptDigest=digest("f")), dict(evidence, resourcesDigest=digest("f")),
            dict(evidence, childIdentity=dict(evidence["childIdentity"], startTicks=999)),
            dict(evidence, executionAttempt="7" * 32),
        ):
            self.successor = dict(self.successor, createCompletion=changed)
            self.lease_reader.return_value = self.successor
            with self.subTest(completion=changed), self.assertRaises(state.GuardError):
                self.read()
            self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())

    def test_wrong_digest_receipt_old_process_proof_and_incident_refuse(self):
        with self.assertRaisesRegex(state.GuardError, "SNAPSHOT_CONFLICT"):
            self.read(digest_value=digest("f"))
        for raw in (b"", b"{}", self.receipt + b"\n", self.receipt.replace(b'"waitStatus":0', b'"waitStatus":1')):
            self.receipt_reader.return_value = raw
            with self.subTest(receipt=raw), self.assertRaises(state.GuardError):
                self.read()
        self.receipt_reader.return_value = self.receipt
        for identity in (self.previous["supervisor"], *self.previous["workers"]):
            self.exited.side_effect = lambda row: row != identity
            with self.subTest(identity=identity), self.assertRaises(state.GuardError):
                self.read()
        self.exited.side_effect = None
        for changed in (
            dict(self.adopted, executionAttempt="7" * 32), dict(self.adopted, reason="DRIFT"),
            dict(self.adopted, runtimeRequest=dict(self.adopted["runtimeRequest"], nonce="1" * 32)),
        ):
            self.current_reader.return_value = ({}, changed)
            with self.subTest(current=changed), self.assertRaises(state.GuardError):
                self.read()
        self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())

    def test_replayed_foreign_or_changed_registration_snapshot_refuses(self):
        original = self.successor
        for key, value in (
            ("attempt", "7" * 32), ("revision", 1), ("lifecycle", "armed"),
            ("supervisor", dict(original["supervisor"], startTicks=999)),
            ("workers", []), ("workEndNs", original["workEndNs"] + 1),
        ):
            self.successor = dict(original, **{key: value})
            self.lease_reader.return_value = self.successor
            with self.subTest(field=key), self.assertRaises(state.GuardError):
                self.read()
        self.successor = original
        self.lease_reader.return_value = None
        with self.assertRaises(state.GuardError):
            self.read()

    def test_readback_races_and_later_erasure_refuse(self):
        self.lease_reader.side_effect = [self.successor, self.successor, dict(self.successor, createCompletion=None)]
        with self.assertRaises(state.GuardError):
            self.read()
        self.lease_reader.side_effect = None
        self.current_reader.side_effect = [({}, self.adopted), ({}, dict(self.adopted, reason="DRIFT"))]
        with self.assertRaises(state.GuardError):
            self.read()
        for completion in (None, dict(self.successor["createCompletion"], receiptDigest=digest("f"))):
            with self.subTest(completion=completion), self.assertRaisesRegex(state.GuardError, "COMPLETION_CONFLICT"):
                state._validate_lease_successor(
                    self.successor, dict(self.successor, revision=1, lifecycle="armed", createCompletion=completion),
                )

    def test_non_create_registration_imports_nothing(self):
        legacy = RuntimeRequestTests()
        legacy.setUp()
        self.adopted = dict(legacy.completed(), executionAttempt=self.candidate["attempt"])
        self.current_reader.return_value = ({}, self.adopted)
        self.successor = dict(self.candidate)
        self.lease_reader.return_value = self.successor
        self.assertEqual(self.candidate, self.read())
        self.receipt_reader.assert_not_called()

    def test_replacement_create_registration_requires_exact_acknowledged_receipt(self):
        current = state.advance_state(prepared_state(), "CUTOVER_POSSIBLE")
        current = bind_created_state(current, digest("c"), digest("d"))
        current = state.advance_state(current, "VERIFYING")
        current = state.advance_state(
            current, "COMMITTING", commitWitnessDigest=digest("e"),
            providerFinalizationDigest=digest("f"), commitSubstep="provider-cleanup",
        )
        current = state.advance_state(
            current, "COMMITTING", commitSubstep="replacement-create-intent",
        )
        sequence = int(current["latestAttemptId"].split(":")[1]) + 1
        child = dict(owned_child(sequence=sequence), attemptId=current["incidentId"] + f":{sequence}")
        request = create_request(current, child, replacement=True)
        current = state.advance_state(
            current, "COMMITTING", ownedChild=child, latestAttemptId=child["attemptId"],
            runtimeRequest=request,
        )
        intent = current
        for lifecycle in ("released", "reaped"):
            current = state.advance_state(
                current, "COMMITTING", ownedChild=dict(child, lifecycle=lifecycle),
            )
        receipt = {
            "schema": state.CREATE_COMPLETION_SCHEMA,
            "requestDigest": state.create_request_digest(request),
            "executionAttempt": request["executionAttempt"],
            "childIdentity": request["childIdentity"],
            "resourcesDigest": request["resourcesDigest"],
            "resourceRequestDigest": request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
        }
        raw = state._canonical(receipt)
        token = state._CREATE_COMPLETION_PUBLICATION.set(True)
        try:
            completed = state.advance_state(
                current, "COMMITTING", ownedChild=None,
                runtimeRequest=dict(
                    request, lifecycle="normal-completed",
                    completionDigest=hashlib.sha256(raw).hexdigest(),
                ),
            )
        finally:
            state._CREATE_COMPLETION_PUBLICATION.reset(token)
        completion = {
            **{key: value for key, value in receipt.items() if key != "schema"},
            "receiptDigest": completed["runtimeRequest"]["completionDigest"],
            "acknowledged": True,
        }
        previous = dict(self.previous, createCompletion=completion)
        candidate = dict(self.candidate)
        successor = dict(candidate, createCompletion=completion)
        adopted = dict(completed, executionAttempt=candidate["attempt"])
        self.previous, self.candidate = previous, candidate
        self.successor, self.adopted = successor, adopted
        self.baseline = {
            "lease": previous,
            "currentDigest": hashlib.sha256(state._canonical(completed)).hexdigest(),
        }
        self.current_reader.return_value = ({}, adopted)
        self.lease_reader.return_value = successor
        self.receipt_reader.return_value = raw

        with mock.patch.object(state, "_execution_process_record", return_value=(
            candidate["worker"]["bootId"], candidate["worker"]["startTicks"],
            candidate["supervisor"]["pid"],
        )), mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True):
            self.assertEqual(successor, self.read())

            for fault, changed in (
                ("intent", dict(successor, createCompletion=None)),
                ("missing", successor | {"createCompletion": None}),
                ("receipt", successor | {"createCompletion": dict(completion, receiptDigest=digest("f"))}),
                ("acknowledgment", successor | {
                    "createCompletion": dict(completion, acknowledged=False),
                }),
            ):
                with self.subTest(fault=fault):
                    self.lease_reader.return_value = changed
                    self.current_reader.return_value = (
                        ({}, dict(intent, executionAttempt=candidate["attempt"]))
                        if fault == "intent" else ({}, adopted)
                    )
                    with self.assertRaises(state.GuardError):
                        self.read()
                    self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())

    def test_reconcile_keeps_completion_exception_through_validation_only(self):
        provider = SimpleNamespace(
            ProviderError=RuntimeError,
            _recovery_lease_runtime_proof=mock.Mock(return_value=self.current["runtimeRequest"]),
        )
        self.lease_reader.return_value = self.previous
        self.current_reader.return_value = ({}, self.current)
        spec = SimpleNamespace(loader=mock.Mock())
        written = {}

        def write(_fd, name, raw, _limit, *, replace):
            self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
            written[name] = raw

        def read(_fd, name, _limit):
            return written.get(name, self.receipt)

        with mock.patch.object(state.importlib.util, "spec_from_file_location", return_value=spec), \
                mock.patch.object(state.importlib.util, "module_from_spec", return_value=provider), \
                mock.patch.object(state, "_atomic_write", side_effect=write), \
                mock.patch.object(state, "_read_at", side_effect=read):
            result = state._reconcile_recovery_lease_locked(
                "/fixture", self.previous, self.candidate, self.current, b"{}", b"{}", 9, mock.Mock(),
            )
        self.assertEqual(hashlib.sha256(written[state.EXECUTION_LEASE_NAME]).hexdigest(), result["digest"])
        self.assertEqual(self.successor, json.loads(written[state.EXECUTION_LEASE_NAME]))
        self.assertEqual(self.adopted, json.loads(written["current.json"]))
        self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())


class HistoricalRecoveryFixtureTests(unittest.TestCase):
    def test_historical_binding_is_schema_validated_not_a_create_transition(self):
        spec = importlib.util.spec_from_file_location(
            "historical_recovery_fixture", ROOT / "fixtures/timepad-controller/recovery.py",
        )
        assert spec is not None and spec.loader is not None
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        prepared = prepared_state()
        before = state._canonical(prepared)
        current = adapter.historical_cutover_state(
            state, prepared, container_id=digest("1"), config_hash=digest("2"),
        )
        self.assertEqual(before, state._canonical(prepared))
        self.assertEqual("CUTOVER_POSSIBLE", current["phase"])
        self.assertEqual(digest("1"), current["containerId"])
        self.assertEqual(digest("2"), current["configHash"])
        self.assertIsNone(current["runtimeRequest"])
        self.assertIsNone(current["executionAttempt"])
        self.assertIsNone(current["ownedChild"])
        with self.assertRaises(state.GuardError) as error:
            state.validate_state_transition(prepared, current)
        self.assertEqual("RUNTIME_REQUEST_BINDING_CONFLICT", error.exception.reason)
        for changes in (
            {"container_id": "invalid", "config_hash": digest("2")},
            {"container_id": digest("1"), "config_hash": "invalid"},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                adapter.historical_cutover_state(state, prepared, **changes)
        for phase in (
            "ROLLING_BACK", "VERIFYING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
        ):
            with self.subTest(phase=phase):
                successor = state.advance_state(current, phase)
                self.assertEqual(phase, successor["phase"])
                self.assertIsNone(successor["runtimeRequest"])


@unittest.skipUnless(
    sys.platform == "linux" and hasattr(os, "geteuid") and os.geteuid() == 0
    and os.environ.get("TIMEPAD_FIXTURE_PARENT_MOUNT_NS"),
    "actual stale-recovery controller requires the isolated Linux fixture",
)
class StaleRecoveryControllerTests(unittest.TestCase):
    def test_retry_refusal_requires_completed_stop_and_reentry_keeps_same_incident(self):
        spec = importlib.util.spec_from_file_location(
            "retry_refusal_fixture", ROOT / "fixtures/timepad-controller/recovery.py",
        )
        assert spec is not None and spec.loader is not None
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        fixture_root = pathlib.Path("/var/lib/timepad-fixture")
        fixture_root.mkdir(mode=0o700, exist_ok=True)
        for fault in ("none", "stop-fails"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(
                prefix="case-refusal-", dir=fixture_root,
            ) as temporary:
                case = pathlib.Path(temporary) / "fixture"
                with redirect_stdout(io.StringIO()):
                    adapter.setup(case, "CUTOVER_POSSIBLE", "intact", request_proof=True)
                state_root = case / "state"
                _, original = state.read_guard(state_root)
                bin_path = case / "bin"
                bin_path.mkdir(mode=0o700)
                for name in ("docker", "curl"):
                    shutil.copy2(ROOT / "fixtures/timepad-controller" / name, bin_path / name)
                environment = dict(os.environ, **{
                    "PATH": str(bin_path) + ":" + os.environ["PATH"],
                    "DOCKER_HOST": "", "PYTHONDONTWRITEBYTECODE": "1",
                    "TIMEPAD_FIXTURE_CASE": str(case),
                    "TIMEPAD_FIXTURE_ADAPTER_DIR": str(ROOT / "fixtures/timepad-controller"),
                    "TIMEPAD_FIXTURE_DOCKER_LOG": str(case / "docker.log"),
                    "TIMEPAD_FIXTURE_DIAGNOSTICS": "1",
                    "TEST_VPS_STATE_ROOT": str(state_root),
                })
                if fault == "stop-fails":
                    environment["TIMEPAD_FIXTURE_FAIL_AT"] = "stop:--time"
                command = [
                    "bash", str(case / "tools/deploy-test-vps-provider-release.sh"),
                    "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
                    "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64,
                    "--revision", "3" * 40, "--version", "1.2.3",
                    "--run-key", "fixture-dispatch", "--mode", "deploy", "--operation", "forward-recover",
                    "--recovery-run-key", original["runId"], "--recovery-incident", original["incidentId"],
                    "--recovery-epoch", "1", "--recovery-binding-digest", original["evidenceDigest"],
                    "--recovery-action", "retry-exact-candidate",
                ]
                attempts = []
                for dispatch in range(1, 3):
                    result = subprocess.run(
                        command, env=environment, capture_output=True, text=True, timeout=130, check=False,
                    )
                    self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                    _, after = state.read_guard(state_root)
                    lease = state._read_execution_lease_locked(state_root)
                    self.assertEqual(original["incidentId"], after["incidentId"])
                    self.assertEqual(1, after["operationEpoch"])
                    self.assertIsNone(after["ownedChild"])
                    self.assertEqual(after["executionAttempt"], lease["attempt"])
                    self.assertEqual("RECOVERY_RETRY_RUNTIME_FAILED", lease["firstFailure"])
                    self.assertEqual(1, lease["firstStatus"])
                    request = after["runtimeRequest"]
                    self.assertEqual("stop", request["operation"])
                    self.assertEqual(original["containerId"], request["containerId"])
                    log = (case / "docker.log").read_text().splitlines()
                    starts = [line for line in log if line.startswith("start-id:")]
                    self.assertEqual(
                        ["start-id:" + original["containerId"]] * (dispatch if fault == "none" else 1),
                        starts,
                    )
                    if fault == "none":
                        self.assertIn("test VPS deployment failed: RECOVERY_RETRY_RUNTIME_FAILED", result.stderr)
                        self.assertEqual("schema_guard=RECOVERY_REQUIRED\n", result.stdout)
                        self.assertEqual("VERIFYING", after["phase"])
                        self.assertEqual("completed", request["lifecycle"])
                        self.assertEqual(request["containerId"], request["responseId"])
                        self.assertEqual(after["executionAttempt"], request["executionAttempt"])
                        self.assertEqual(2 * dispatch + 1, request["sequence"])
                        self.assertEqual(after["incidentId"] + f":{dispatch}", after["latestAttemptId"])
                        self.assertEqual("drained", lease["lifecycle"])
                        self.assertIsNone(lease["worker"])
                        self.assertNotIn(lease["attempt"], attempts)
                        attempts.append(lease["attempt"])
                        runtime = json.loads((case / "runtime.json").read_bytes())
                        self.assertFalse(runtime["State"]["Running"])
                        self.assertEqual("no", runtime["HostConfig"]["RestartPolicy"]["Name"])
                    else:
                        self.assertEqual("schema_guard=QUIESCENCE_UNCONFIRMED\n", result.stdout)
                        self.assertNotIn("RECOVERY_RETRY_RUNTIME_FAILED", result.stderr)
                        self.assertEqual("intent", request["lifecycle"])
                        self.assertIsNone(request["responseId"])
                        self.assertIsNone(request["completionDigest"])
                        snapshots = (
                            (state_root / state.GUARD_DIR / "current.json").read_bytes(),
                            (state_root / state.EXECUTION_LEASE_NAME).read_bytes(),
                        )
                        if dispatch == 1:
                            before_reentry = snapshots
                        else:
                            self.assertEqual(before_reentry, snapshots)

    def test_only_complete_stale_lease_and_daemon_proofs_release_exact_container_retry(self):
        spec = importlib.util.spec_from_file_location(
            "stale_recovery_fixture", ROOT / "fixtures/timepad-controller/recovery.py",
        )
        assert spec is not None and spec.loader is not None
        adapter = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(adapter)
        fixture_root = pathlib.Path("/var/lib/timepad-fixture")
        fixture_root.mkdir(mode=0o700, exist_ok=True)
        for phase, fault in (
            ("CUTOVER_POSSIBLE", "none"), ("ROLLING_BACK", "none"),
            ("VERIFYING", "none"), ("COMMITTING", "none"),
            ("RECOVERY_REQUIRED", "none"), ("FORWARD_RECOVERING", "none"),
            ("CUTOVER_POSSIBLE", "acknowledged"),
            ("CUTOVER_POSSIBLE", "live-worker"), ("CUTOVER_POSSIBLE", "live-supervisor"),
            ("CUTOVER_POSSIBLE", "unbound"),
            ("CUTOVER_POSSIBLE", "overflow"), ("CUTOVER_POSSIBLE", "intent"),
            ("CUTOVER_POSSIBLE", "missing-request"), ("CUTOVER_POSSIBLE", "malformed"),
            ("CUTOVER_POSSIBLE", "stale-epoch"), ("CUTOVER_POSSIBLE", "missing-config"),
            ("CUTOVER_POSSIBLE", "foreign-inventory"),
            ("CUTOVER_POSSIBLE", "partial-pair"),
            ("VERIFYING", "wrong-marker"),
        ):
            with self.subTest(phase=phase, fault=fault), tempfile.TemporaryDirectory(
                prefix="case-stale-", dir=fixture_root,
            ) as temporary, ExitStack() as stack:
                case = pathlib.Path(temporary) / "fixture"
                with redirect_stdout(io.StringIO()):
                    adapter.setup(case, phase, "intact")
                state_root = case / "state"
                _, current = state.read_guard(state_root)
                old = execution_lease(attempt="8" * 32, revision=4, lifecycle="drained")
                old.update(firstFailure="EXIT", firstStatus=1)
                identities = []
                for _ in range(2):
                    process = subprocess.Popen(
                        [sys.executable, "-B", "-c", "import sys; sys.stdin.buffer.read()"],
                        stdin=subprocess.PIPE, start_new_session=True,
                    )
                    stack.callback(lambda process=process: process.poll() is not None or process.kill())
                    identity = supervisor.lease_identity(supervisor.process_identity(process.pid))
                    identities.append(identity)
                    keep_live = fault == "live-worker" and len(identities) == 2 or \
                        fault == "live-supervisor" and len(identities) == 1
                    if not keep_live:
                        process.communicate(timeout=5)
                    else:
                        stack.callback(process.communicate, timeout=5)
                old["supervisor"] = identities[0]
                old["workers"] = [{"mode": "controller-worker", **identities[1]}]
                request = {
                    "nonce": "9" * 32, "sequence": 1, "executionAttempt": old["attempt"],
                    "operation": "stop", "containerId": current["containerId"],
                    "imageId": current["target"]["tuple"]["platformImageId"],
                    "configHash": current["configHash"], "childAttemptId": None,
                    "lifecycle": "completed", "responseId": current["containerId"],
                    "completionDigest": "a" * 64,
                }
                current.update(executionAttempt=old["attempt"], runtimeRequest=request)
                if fault == "acknowledged":
                    request.update(lifecycle="acknowledged", completionDigest=None)
                elif fault == "intent":
                    request.update(lifecycle="intent", responseId=None, completionDigest=None)
                elif fault == "missing-request":
                    current["runtimeRequest"] = None
                elif fault == "unbound":
                    old.update(lifecycle="armed", worker=identities[1])
                elif fault == "overflow":
                    old["firstFailure"] = "DESCENDANT_OVERFLOW"
                elif fault == "partial-pair":
                    current["executionAttempt"] = "7" * 32
                current_path = state_root / state.GUARD_DIR / "current.json"
                current_path.write_bytes(state._canonical(current))
                lease_path = state_root / state.EXECUTION_LEASE_NAME
                lease_path.write_bytes(b"{}" if fault == "malformed" else state._canonical(old))
                lease_path.chmod(0o600)
                if fault == "missing-config":
                    (state_root / current["ownedRun"] / "config.env.target").unlink()
                if fault == "foreign-inventory":
                    runtime_path = case / "runtime.json"
                    runtime = json.loads(runtime_path.read_bytes())
                    runtime["Id"] = "e" * 64
                    runtime_path.write_text(json.dumps(runtime))
                if fault == "wrong-marker":
                    marker_path = state_root / ".provider-transaction.current"
                    marker = json.loads(marker_path.read_bytes())
                    marker["phase"] = "applying"
                    marker_path.write_text(json.dumps(marker))
                bin_path = case / "bin"
                bin_path.mkdir(mode=0o700)
                for name in ("docker", "curl"):
                    shutil.copy2(ROOT / "fixtures/timepad-controller" / name, bin_path / name)
                environment = dict(os.environ, **{
                    "PATH": str(bin_path) + ":" + os.environ["PATH"],
                    "DOCKER_HOST": "", "PYTHONDONTWRITEBYTECODE": "1",
                    "TIMEPAD_FIXTURE_CASE": str(case),
                    "TIMEPAD_FIXTURE_ADAPTER_DIR": str(ROOT / "fixtures/timepad-controller"),
                    "TIMEPAD_FIXTURE_DOCKER_LOG": str(case / "docker.log"),
                    "TIMEPAD_FIXTURE_DIAGNOSTICS": "1",
                    "TEST_VPS_STATE_ROOT": str(state_root),
                })
                before = (current_path.read_bytes(), lease_path.read_bytes())
                result = subprocess.run([
                    "bash", str(case / "tools/deploy-test-vps-provider-release.sh"),
                    "--root", str(case / "root"), "--base-compose", str(case / "compose.yml"),
                    "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64,
                    "--revision", "3" * 40, "--version", "1.2.3",
                    "--run-key", "fixture-dispatch", "--mode", "deploy",
                    "--operation", "forward-recover", "--recovery-run-key", current["runId"],
                    "--recovery-incident", current["incidentId"],
                    "--recovery-epoch", "2" if fault == "stale-epoch" else "1",
                    "--recovery-binding-digest", current["evidenceDigest"],
                    "--recovery-action", "retry-exact-candidate",
                ], env=environment, capture_output=True, text=True, timeout=130, check=False)
                log_path = case / "docker.log"
                log = log_path.read_text().splitlines() if log_path.exists() else []
                starts = [line for line in log if line.startswith("start-id:")]
                self.assertTrue(all(line == "start-id:" + current["containerId"] for line in starts))
                self.assertEqual(1, result.returncode, result.stdout + result.stderr)
                if fault in {"none", "acknowledged"}:
                    after = state._read_guard_locked(state_root)[1]
                    lease_after = state._read_execution_lease_locked(state_root)
                    diagnostic = {
                        "status": result.returncode,
                        "stdout": result.stdout,
                        "stderr": result.stderr,
                        "phase": after["phase"],
                        "executionAttempt": after["executionAttempt"],
                        "requestOperation": (
                            after["runtimeRequest"]["operation"]
                            if after["runtimeRequest"] is not None else None
                        ),
                        "requestLifecycle": (
                            after["runtimeRequest"]["lifecycle"]
                            if after["runtimeRequest"] is not None else None
                        ),
                        "leaseLifecycle": (
                            lease_after["lifecycle"] if lease_after is not None else None
                        ),
                        "leaseWorkerMode": (
                            lease_after["workerMode"] if lease_after is not None else None
                        ),
                        "leaseFailure": (
                            lease_after["firstFailure"] if lease_after is not None else None
                        ),
                        "dockerOperations": log,
                    }
                    self.assertEqual(1, len(starts), json.dumps(diagnostic, sort_keys=True))
                    self.assertEqual(current["incidentId"], after["incidentId"])
                    self.assertEqual(1, after["operationEpoch"])
                    self.assertNotEqual(old["attempt"], after["executionAttempt"])
                    self.assertEqual(after["executionAttempt"], state._read_execution_lease_locked(state_root)["attempt"])
                else:
                    self.assertEqual([], starts)
                    self.assertEqual(before, (current_path.read_bytes(), lease_path.read_bytes()))
                    self.assertFalse(any(
                        line.startswith(("start:", "stop:", "update:", "compose:up", "compose:create"))
                        for line in log
                    ))


class TimepadStateTests(unittest.TestCase):
    def terminal_lease_pair(self):
        previous = execution_lease(revision=3, lifecycle="drained")
        previous["workers"] = [{"mode": "controller-worker", **previous["supervisor"], "pid": 102}]
        candidate = execution_lease(attempt="b" * 32)
        candidate["supervisor"] = {**previous["supervisor"], "pid": 201}
        candidate["worker"] = {**candidate["supervisor"], "pid": 202}
        candidate["workers"] = [{"mode": "controller-worker", **candidate["worker"]}]
        return previous, candidate

    def test_terminal_lease_succession_refuses_worker_intent_and_failed_attempts(self):
        previous, candidate = self.terminal_lease_pair()
        for invalid in (
            {**previous, "lifecycle": "armed"},
            {**previous, "worker": previous["supervisor"]},
            {**previous, "workers": []},
            {**previous, "firstFailure": "TERM", "firstStatus": 143},
        ):
            with self.subTest(previous=invalid), self.assertRaisesRegex(
                state.GuardError, "EXECUTION_LEASE_UNRESOLVED",
            ):
                state._validate_terminal_lease_successor("/fixture", invalid, candidate)

    def test_terminal_lease_succession_requires_all_old_identities_exited(self):
        previous, candidate = self.terminal_lease_pair()
        for live in (previous["supervisor"], *previous["workers"]):
            with self.subTest(live=live), mock.patch.object(
                state, "_execution_process_exited", side_effect=lambda identity: identity != live,
            ), self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                state._validate_terminal_lease_successor("/fixture", previous, candidate)

    def test_terminal_lease_succession_requires_bound_worker_and_terminal_guard(self):
        previous, candidate = self.terminal_lease_pair()
        worker = candidate["worker"]
        with mock.patch.object(state, "_execution_process_exited", return_value=True), \
                mock.patch.object(state, "_execution_process_record") as process, \
                mock.patch.object(state, "_read_guard_locked") as guard, \
                mock.patch.object(state, "_open_root", return_value=55), \
                mock.patch.object(state.os, "listdir", return_value=[]) as names, \
                mock.patch.object(state.os, "close"):
            process.return_value = (
                worker["bootId"], worker["startTicks"], candidate["supervisor"]["pid"],
            )
            guard.return_value = ({}, state.new_ready_state(digest("a")))
            state._validate_terminal_lease_successor("/fixture", previous, candidate)
            for bad_parent in (None, (worker["bootId"], worker["startTicks"], 999)):
                process.return_value = bad_parent
                with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                    state._validate_terminal_lease_successor("/fixture", previous, candidate)
            process.return_value = (
                worker["bootId"], worker["startTicks"], candidate["supervisor"]["pid"],
            )
            guard.return_value = ({}, prepared_state())
            with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                state._validate_terminal_lease_successor("/fixture", previous, candidate)
            guard.side_effect = state.GuardError("GUARD_STATE_LOST")
            with self.assertRaisesRegex(state.GuardError, "GUARD_STATE_LOST"):
                state._validate_terminal_lease_successor("/fixture", previous, candidate)
            guard.side_effect = None
            guard.return_value = ({}, state.new_ready_state(digest("a")))
            for entry in (".provider-transaction.current", ".smtp-transaction.current",
                          ".timepad-bootstrap-incomplete"):
                names.return_value = [entry]
                with self.subTest(entry=entry), self.assertRaisesRegex(
                    state.GuardError, "EXECUTION_LEASE_UNRESOLVED",
                ):
                    state._validate_terminal_lease_successor("/fixture", previous, candidate)

    def test_recorded_process_absence_is_distinct_from_unreadable_or_malformed_proc(self):
        identity = execution_lease()["supervisor"]
        for raw in (b"", b"invalid\n", b"1 (name) S 1\n", b"x" * 4097):
            with self.subTest(raw=raw[:20]), mock.patch(
                "builtins.open", side_effect=[
                    io.StringIO(identity["bootId"] + "\n"), io.BytesIO(raw),
                ],
            ), self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                state._execution_process_exited(identity)
        for error in (PermissionError(), OSError()):
            with self.subTest(error=type(error)), mock.patch(
                "builtins.open", side_effect=[
                    io.StringIO(identity["bootId"] + "\n"), error,
                ],
            ), self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                state._execution_process_exited(identity)
        with mock.patch("builtins.open", side_effect=[
            io.StringIO(identity["bootId"] + "\n"), FileNotFoundError(),
        ]):
            self.assertTrue(state._execution_process_exited(identity))
        for record, exited in (
            ((identity["bootId"], identity["startTicks"], 1), False),
            ((identity["bootId"], identity["startTicks"] + 1, 1), True),
            (("12345678-89ab-cdef-0123-456789abcdef", identity["startTicks"], 1), True),
        ):
            with self.subTest(record=record), mock.patch.object(
                state, "_execution_process_record", return_value=record,
            ):
                self.assertEqual(exited, state._execution_process_exited(identity))

    def test_childless_marker_requires_sole_helper_and_no_surviving_worker(self):
        previous, _ = self.terminal_lease_pair()
        with mock.patch.object(state.os, "getppid", return_value=previous["supervisor"]["pid"]), \
                mock.patch.object(state.os, "getpid", return_value=300), \
                mock.patch.object(state, "_execution_process_exited", return_value=True) as exited:
            for children in (b"300 ", b"300 999 ", b""):
                with self.subTest(children=children), mock.patch(
                    "builtins.open", return_value=io.BytesIO(children),
                ):
                    if children == b"300 ":
                        state._validate_childless_lease_publication(previous)
                    else:
                        with self.assertRaisesRegex(
                            state.GuardError, "EXECUTION_LEASE_CHILDLESS_REQUIRED",
                        ):
                            state._validate_childless_lease_publication(previous)
            exited.return_value = False
            with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_CHILDLESS_REQUIRED"):
                state._validate_childless_lease_publication(previous)

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
            # Exercise filesystem sequencing independently of private publisher
            # authentication, covered by LeasePublicationAuthorityTests and the
            # actual Linux supervisor/worker fixtures.
            with mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True), \
                    mock.patch.object(state, "_execution_lease_publication", return_value=nullcontext()):
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
                    self.assertEqual(2, published.returncode, published.stderr)
                    self.assertEqual("EXECUTION_LEASE_PUBLISHER_REQUIRED", published.stderr.strip())
                    self.assertFalse((root / state.EXECUTION_LEASE_NAME).exists())
                    ack = state.publish_execution_lease(root, first, deploy_lock_fd=lock_fd)
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
                    # A lost acknowledgment can be retried only with the
                    # identical current snapshot, not a stale or skipped one.
                    self.assertEqual(ack, state.publish_execution_lease(
                        root, armed, deploy_lock_fd=lock_fd,
                    ))
                    with self.assertRaisesRegex(
                        state.GuardError, "EXECUTION_LEASE_REVISION_CONFLICT",
                    ):
                        state.publish_execution_lease(root, first, deploy_lock_fd=lock_fd)
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

    def test_execution_lease_interlocks_bootstrap_and_state_writes(self) -> None:
        if not hasattr(os, "geteuid") or os.geteuid() != 0 or os.name != "posix":
            self.skipTest("root-owned lease filesystem checks require Linux root")
        with tempfile.TemporaryDirectory() as parent:
            root = pathlib.Path(parent) / "deploy"
            root.mkdir(mode=0o700)
            lease = execution_lease()
            with mock.patch.object(
                state, "_execution_lease_supervisor_is_live", return_value=True,
            ), mock.patch.object(
                state, "_execution_lease_publication", return_value=nullcontext(),
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
                with self.assertRaisesRegex(state.GuardError, "EXECUTION_LEASE_UNRESOLVED"):
                    state.bootstrap_guard(root, authority=authority, observed=observed, deploy_lock_fd=lock_fd)
                self.assertFalse((root / state.GUARD_DIR).exists())
                armed = execution_lease(revision=1, lifecycle="armed")
                state.publish_execution_lease(root, armed, deploy_lock_fd=lock_fd)
                grant = state.ExecutionGrant(lease["attempt"], "b" * 32, armed["workEndNs"] - 1)
                client = mock.Mock(
                    attempt=grant.attempt, role=armed["workerMode"], supervisor=armed["supervisor"],
                )
                client.request.return_value = {
                    "attempt": grant.attempt, "grantId": grant.grant_id, "endNs": grant.end_ns,
                    "role": "controller-worker", "name": "state-publish",
                }
                with mock.patch.object(supervisor, "WorkerClient", return_value=client):
                    state.bootstrap_guard(
                        root, authority=authority, observed=observed,
                        deploy_lock_fd=lock_fd, execution_grant=grant,
                    )
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
                advanced = state.advance_state(prepared, "CUTOVER_POSSIBLE")
                self.assertEqual(lease["attempt"], advanced["executionAttempt"])
                with mock.patch.object(supervisor, "WorkerClient", return_value=client):
                    state.publish_current(root, prepared, deploy_lock_fd=lock_fd, execution_grant=grant)
                    self.assertEqual(advanced, state.publish_current(
                        root, advanced, deploy_lock_fd=lock_fd, execution_grant=grant,
                    ))
                unresolved = execution_lease(revision=2, lifecycle="quiescence-unconfirmed")
                state.publish_execution_lease(root, unresolved, deploy_lock_fd=lock_fd)
                with self.assertRaises(state.GuardError) as error:
                    state.publish_current(
                        root, state.advance_state(advanced, "VERIFYING"), deploy_lock_fd=lock_fd,
                        execution_grant=grant,
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
            with mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True), \
                    mock.patch.object(state, "_execution_lease_publication", return_value=nullcontext()):
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

    def test_optional_tooling_schema_is_bounded_pinned_and_not_authority(self) -> None:
        tooling = {
            "dockerCliVersion": "28.3.3", "composeVersion": "2.39.4",
            "composeCommit": "a32dc3da722e6b2e4fbfc72e40b1a697c4686460",
            "dockerCliPath": "/opt/pinned/docker", "composePluginPath": "/opt/pinned/docker-compose",
            "dockerCliSha256": "a" * 64, "composePluginSha256": "b" * 64,
            "platform": "linux/amd64", "provenanceRef": "fixture-only-not-production-approval",
        }
        for active in (False, True):
            approved = {**contract(active), "tooling": tooling}
            self.assertEqual(approved, state.parse_contract(json.dumps(approved).encode()))
        approved = {**contract(False), "tooling": tooling}
        result = state.admit(
            approved, root_id="test-root", target_id="x", predecessor_id="y",
            transition_id=None, target_tuple=None, predecessor_tuple=None,
        )
        self.assertEqual("refuse", result.disposition)
        for key in tooling:
            with self.subTest(missing=key), self.assertRaises(state.GuardError):
                state.parse_contract({**approved, "tooling": {k: v for k, v in tooling.items() if k != key}})
        invalid = [None, {}, {**tooling, "unknown": "x"}]
        invalid.extend({**tooling, key: value} for key, value in (
            ("dockerCliVersion", "29.0.0"), ("composeVersion", "2.40.0"),
            ("composeCommit", "f" * 40), ("dockerCliPath", "relative/docker"),
            ("dockerCliPath", "/opt/../docker"), ("dockerCliPath", "/opt//docker"),
            ("dockerCliPath", "/opt/docker/"), ("dockerCliPath", "/opt/not-docker"),
            ("composePluginPath", "/opt/./docker-compose"),
            ("dockerCliSha256", "A" * 64), ("composePluginSha256", "a" * 63),
            ("platform", "linux/386"), ("provenanceRef", ""), ("provenanceRef", "x" * 513),
            ("provenanceRef", "private\x00value"), ("dockerCliSha256", True),
        ))
        for value in invalid:
            with self.subTest(invalid=value), self.assertRaises(state.GuardError):
                state.parse_contract({**approved, "tooling": value})

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

    def test_prepared_never_contains_target_runtime_or_bypasses_acknowledged_barrier(self) -> None:
        prepared = prepared_state()
        self.assertIsNotNone(prepared["preparedProofDigest"])
        for changes in (
            {"containerId": digest("a")}, {"configHash": digest("b")},
            {"commitSubstep": "provider-cleanup"}, {"terminalReceipt": digest("c")},
            {"ownedChild": owned_child(), "latestAttemptId": owned_child()["attemptId"]},
        ):
            with self.subTest(changes=changes), self.assertRaises(state.GuardError):
                state._current({**prepared, **changes})
        for phase in ("VERIFYING", "FORWARD_RECOVERING"):
            self.assertNotIn(phase, state.PHASE_EDGES["PREPARED"])
            with self.subTest(phase=phase), self.assertRaisesRegex(
                state.GuardError, "CUTOVER_BARRIER_REQUIRED",
            ):
                state.advance_state(prepared, phase)
        bound = {**prepared, "executionAttempt": "a" * 32}
        with self.assertRaisesRegex(state.GuardError, "STATE_EXECUTION_ATTEMPT_CONFLICT"):
            state.advance_state(bound, "CUTOVER_POSSIBLE", executionAttempt="b" * 32)
        barrier = state.advance_state(bound, "CUTOVER_POSSIBLE")
        self.assertEqual(bound["preparedProofDigest"], barrier["preparedProofDigest"])
        self.assertEqual(bound["operationEpoch"], barrier["operationEpoch"])

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
            bind_created_state(barrier, "b" * 64, digest("3")),
            "VERIFYING",
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
