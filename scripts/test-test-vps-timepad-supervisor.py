#!/usr/bin/env python3
"""Focused supervisor tests; authoritative invocation requires isolated Linux.

``--portable`` explicitly selects only pure model/protocol-source tests. It is
not Linux/FD9/subreaper evidence and is never selected by the fixture CI command.
No production CLI or environment deadline override is used.
"""

from __future__ import annotations

import argparse
import ast
from contextlib import nullcontext
from copy import deepcopy
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import socket
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "test_vps_timepad_supervisor", SCRIPTS / "test_vps_timepad_supervisor.py",
)
assert SPEC is not None and SPEC.loader is not None
supervisor = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = supervisor
SPEC.loader.exec_module(supervisor)
STATE_SPEC = importlib.util.spec_from_file_location(
    "test_vps_timepad_state", SCRIPTS / "test_vps_timepad_state.py",
)
assert STATE_SPEC is not None and STATE_SPEC.loader is not None
state = importlib.util.module_from_spec(STATE_SPEC)
sys.modules[STATE_SPEC.name] = state
STATE_SPEC.loader.exec_module(state)
NS = supervisor.NS
ACK = "a" * 64


class Clock:
    def __init__(self):
        self.now = 100 * NS

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += int(seconds * NS)


def acknowledged(attempt):
    attempt.acknowledge_lease(attempt.revision, ACK)
    return attempt


class AttemptTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.attempt = supervisor.Attempt("deploy", clock=self.clock)

    def armed(self):
        self.attempt.arm()
        return acknowledged(self.attempt)

    def test_fixed_retry_refusal_keeps_first_failure_through_cleanup_terminal(self):
        attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        attempt.arm()
        acknowledged(attempt)
        attempt.cancel("RECOVERY_RETRY_RUNTIME_FAILED", 1)
        attempt.cancel("TERM", 143)
        self.assertEqual("fail-closed-worker", attempt.after_drain())
        acknowledged(attempt)
        attempt.prepare_terminal()
        acknowledged(attempt)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.terminal(0)
        attempt.terminal(1)
        self.assertIsNone(attempt.result)
        attempt.finish_childless()
        self.assertEqual((1, "RECOVERY_REQUIRED"), attempt.result)
        self.assertEqual("RECOVERY_RETRY_RUNTIME_FAILED", attempt.first_reason)
        self.assertEqual(1, attempt.first_status)
        for operation in ("deploy", "retention"):
            with self.subTest(operation=operation), self.assertRaises(supervisor.SupervisorError):
                supervisor.Attempt(operation, clock=self.clock).cancel("RECOVERY_RETRY_RUNTIME_FAILED", 1)
        interrupted = supervisor.Attempt("forward-recover", clock=self.clock)
        interrupted.cancel("TERM", 143)
        interrupted.cancel("RECOVERY_RETRY_RUNTIME_FAILED", 1)
        self.assertEqual(("TERM", 143), (interrupted.first_reason, interrupted.first_status))

    def test_worker_lease_identity_matches_state_schema(self):
        identity = supervisor.ProcessIdentity(123, 1, 456, 0)
        with mock.patch.object(supervisor, "boot_id", return_value="01234567-89ab-cdef-0123-456789abcdef"):
            lease_identity = supervisor.lease_identity(identity)
        self.assertEqual(
            {"pid": 123, "startTicks": 456, "bootId": "01234567-89ab-cdef-0123-456789abcdef"},
            lease_identity,
        )
        self.assertNotIn("parentPid", lease_identity)
        self.assertNotIn("uid", lease_identity)

    def test_fixed_production_deadlines_and_no_reset(self):
        attempt = self.armed()
        original = (attempt.nonce, attempt.t0, attempt.work_end, attempt.hard_end)
        self.assertEqual(attempt.work_end - attempt.t0, 540 * NS)
        self.assertEqual(attempt.hard_end - attempt.work_end, 60 * NS)
        self.clock.advance(5)
        attempt.arm()
        attempt.cancel("TERM", 143)
        self.clock.advance(3)
        self.assertEqual(attempt.after_drain(), "rollback-worker")
        acknowledged(attempt)
        admission = attempt.grant("rollback-admission", NS)
        attempt.complete(admission.grant_id)
        attempt.admit_rollback()
        acknowledged(attempt)
        attempt.grant("rollback-remaining-work", 600 * NS)
        self.assertEqual(original, (attempt.nonce, attempt.t0, attempt.work_end, attempt.hard_end))

    def test_forward_recovery_charges_authorization_before_any_grant(self):
        attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        original = attempt.t0
        self.assertEqual((attempt.revision, attempt.lifecycle), (0, "registered"))
        acknowledged(attempt)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.grant("provider", NS)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.prepare_terminal()
        attempt.arm()
        self.clock.advance(530)
        acknowledged(attempt)
        grant = attempt.grant("provider", 30 * NS)
        self.assertEqual(grant.end_ns, original + 540 * NS)
        attempt.cancel("EXIT", 1)
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        self.assertFalse(attempt.rollback_issued)

    def test_recovery_registration_and_arm_match_actual_state_lease_contract(self):
        instance = supervisor.Supervisor.__new__(supervisor.Supervisor)
        instance.attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        instance.identity = {
            "pid": 123, "startTicks": 456,
            "bootId": "01234567-89ab-cdef-0123-456789abcdef",
        }
        instance.worker_identity = {**instance.identity, "pid": 124}
        instance.worker_identities = [
            {"mode": "controller-worker", **instance.worker_identity},
        ]
        registered = state._execution_lease(instance._lease())
        self.assertEqual((registered["revision"], registered["lifecycle"]), (0, "registered"))
        self.assertEqual(registered["workEndNs"], self.clock.now + 540 * NS)
        self.assertEqual(registered["hardEndNs"], self.clock.now + 600 * NS)
        acknowledged(instance.attempt)
        self.clock.advance(20)
        instance.attempt.arm()
        armed = state._execution_lease(instance._lease())
        state._validate_lease_successor(registered, armed)
        self.assertEqual((armed["revision"], armed["lifecycle"]), (1, "armed"))
        for field in ("t0Ns", "workEndNs", "hardEndNs"):
            self.assertEqual(registered[field], armed[field])

    def test_registration_publication_consumes_recovery_budget(self):
        attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        self.clock.advance(539)
        publication = attempt.grant("lease-publish", 10 * NS)
        self.assertEqual(publication.end_ns, attempt.work_end)
        self.clock.advance(1)
        attempt.poll()
        self.assertEqual(attempt.first_reason, "WORK_EXHAUSTED")
        with self.assertRaises(supervisor.SupervisorError):
            attempt.complete(publication.grant_id)
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        self.assertFalse(attempt.rollback_issued)

    def test_recovery_registration_is_exclusive_bounded_and_does_not_need_a_prior_lease_ack(self):
        attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        original = (attempt.t0, attempt.work_end, attempt.hard_end, attempt.revision)
        grant = attempt.grant("recovery-registration", 600 * NS)
        self.assertEqual(grant.end_ns, self.clock.now + 30 * NS)
        self.assertEqual(grant, attempt.validate_grant(grant.grant_id, grant.end_ns))
        with self.assertRaisesRegex(supervisor.SupervisorError, "WAIT_REFUSED"):
            attempt.grant("recovery-registration", NS)
        for name in supervisor.WAIT_NAMES - {"recovery-registration"}:
            with self.subTest(name=name), self.assertRaises(supervisor.SupervisorError):
                attempt.grant(name, NS)
        attempt.complete(grant.grant_id)
        acknowledged(attempt)
        admission = attempt.grant("recovery-admission", 600 * NS)
        self.assertEqual(admission.end_ns, self.clock.now + 30 * NS)
        self.assertEqual(original, (attempt.t0, attempt.work_end, attempt.hard_end, attempt.revision))
        with self.assertRaises(supervisor.SupervisorError):
            attempt.prepare_terminal()
        attempt.cancel("TERM", 143)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.validate_grant(admission.grant_id, admission.end_ns)
        self.assertEqual("fail-closed-worker", attempt.after_drain())
        self.assertFalse(attempt.rollback_issued)

    def test_recovery_registration_grants_cannot_be_used_by_other_operations_or_roles(self):
        for operation in ("deploy", "retention", "forward-recover"):
            attempt = supervisor.Attempt(operation, clock=self.clock)
            acknowledged(attempt)
            if operation == "forward-recover":
                attempt.arm()
                acknowledged(attempt)
            for name in ("recovery-registration", "recovery-admission"):
                with self.subTest(operation=operation, name=name), self.assertRaises(
                    supervisor.SupervisorError,
                ):
                    attempt.grant(name, NS)

    def test_lease_must_be_published_before_work_and_after_arm(self):
        attempt = self.attempt
        with self.assertRaisesRegex(supervisor.SupervisorError, "LEASE_ACK_REQUIRED"):
            attempt.grant("docker", NS)
        publication = attempt.grant("lease-publish", NS)
        with self.assertRaisesRegex(supervisor.SupervisorError, "LEASE_ACK_INVALID"):
            acknowledged(attempt)
        attempt.complete(publication.grant_id)
        acknowledged(attempt)
        attempt.arm()
        with self.assertRaisesRegex(supervisor.SupervisorError, "LEASE_ACK_REQUIRED"):
            attempt.grant("docker", NS)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.acknowledge_lease(attempt.revision - 1, ACK)

    def test_wait_end_caps_local_absolute_and_health_bounds(self):
        attempt = self.armed()
        short = attempt.grant("curl", 15 * NS)
        self.assertEqual(short.end_ns, self.clock.now + 15 * NS)
        health = attempt.grant("health", 600 * NS)
        self.assertEqual(health.end_ns, self.clock.now + 180 * NS)
        handshake = attempt.grant("child-handshake", 30 * NS)
        self.assertEqual(handshake.end_ns, self.clock.now + 5 * NS)

    def test_prearm_idle_is_not_renewed_by_snapshot_or_ack(self):
        attempt = self.attempt
        for _ in range(3):
            attempt.lease()
            acknowledged(attempt)
            self.clock.advance(10)
        attempt.poll()
        self.assertEqual(attempt.first_reason, "WAIT_EXPIRED")
        self.assertTrue(attempt.draining)

    def test_prearm_local_operation_keeps_its_existing_bound(self):
        attempt = acknowledged(self.attempt)
        grant = attempt.grant("preflight", 120 * NS)
        self.assertEqual(grant.end_ns, self.clock.now + 120 * NS)
        self.clock.advance(31)
        attempt.poll()
        self.assertIsNone(attempt.first_reason)

    def test_early_cancellation_matrix_allows_one_rollback_not_second(self):
        for reason, status in (("TERM", 143), ("INT", 130), ("HUP", 129), ("EXIT", 1), ("DRILL", 86)):
            with self.subTest(reason=reason):
                clock = Clock()
                attempt = supervisor.Attempt("deploy", clock=clock)
                acknowledged(attempt)
                forward = attempt.grant("docker", 15 * NS)
                attempt.cancel(reason, status)
                self.assertTrue(attempt.draining)
                with self.assertRaises(supervisor.SupervisorError):
                    attempt.complete(forward.grant_id)
                with self.assertRaises(supervisor.SupervisorError):
                    attempt.grant("rollback-remaining-work", NS)
                original = (attempt.nonce, attempt.t0, attempt.work_end, attempt.hard_end)
                clock.advance(1)
                self.assertEqual(attempt.after_drain(), "rollback-worker")
                self.assertTrue(attempt.rollback_issued)
                with self.assertRaises(supervisor.SupervisorError):
                    attempt.grant("rollback-admission", NS)
                acknowledged(attempt)
                admission = attempt.grant("rollback-admission", NS)
                attempt.complete(admission.grant_id)
                attempt.admit_rollback()
                acknowledged(attempt)
                rollback = attempt.grant("rollback-remaining-work", 20 * NS)
                for repeated in ("TERM", "INT", "HUP"):
                    attempt.cancel(repeated, 143)
                self.assertIn(rollback.grant_id, attempt.grants)
                self.assertEqual(attempt.first_status, status)
                self.assertEqual(original, (attempt.nonce, attempt.t0, attempt.work_end, attempt.hard_end))
                attempt.complete(rollback.grant_id)
                attempt.prepare_terminal()
                acknowledged(attempt)
                attempt.terminal(86 if status == 86 else 0)
                attempt.finish_childless()
                self.assertEqual(attempt.result, (status, "ROLLED_BACK"))

    def test_local_expiry_revokes_forward_without_spending_reserve(self):
        attempt = self.armed()
        grant = attempt.grant("docker", 2 * NS)
        self.clock.advance(2)
        attempt.poll()
        self.assertEqual(attempt.first_reason, "WAIT_EXPIRED")
        self.assertNotIn(grant.grant_id, attempt.grants)
        self.assertEqual(attempt.after_drain(), "rollback-worker")

    def test_no_predecessor_start_or_provider_commit_under_reserve(self):
        attempt = self.armed()
        self.clock.advance(540)
        attempt.poll()
        self.assertTrue(attempt.draining)
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        acknowledged(attempt)
        for name in supervisor.WAIT_NAMES - {"cleanup-stop", "cleanup-publish", "lease-publish"}:
            with self.subTest(name=name), self.assertRaises(supervisor.SupervisorError):
                attempt.grant(name, NS)
        stop = attempt.grant("cleanup-stop", 600 * NS)
        self.assertEqual(stop.end_ns, self.clock.now + 40 * NS)
        self.assertLessEqual(stop.end_ns, attempt.hard_end - 10 * NS)

    def test_hard_end_revokes_every_grant_and_late_terminal(self):
        attempt = self.armed()
        attempt.cancel("EXIT")
        self.clock.advance(541)
        attempt.after_drain()
        acknowledged(attempt)
        attempt.grant("cleanup-publish", 59 * NS)
        self.clock.advance(59)
        attempt.poll()
        self.assertEqual(attempt.result, (1, "QUIESCENCE_UNCONFIRMED"))
        self.assertFalse(attempt.grants)
        for call in (
            lambda: attempt.grant("cleanup-publish", NS),
            lambda: attempt.terminal(0),
        ):
            with self.assertRaises(supervisor.SupervisorError):
                call()

    def test_rollback_failure_expiry_never_issues_second_rollback(self):
        attempt = self.armed()
        attempt.cancel("TERM", 143)
        attempt.after_drain()
        acknowledged(attempt)
        admission = attempt.grant("rollback-admission", NS)
        attempt.complete(admission.grant_id)
        attempt.admit_rollback()
        acknowledged(attempt)
        attempt.grant("rollback-remaining-work", NS)
        self.clock.advance(1)
        attempt.poll()
        self.assertTrue(attempt.draining)
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        self.assertTrue(attempt.rollback_issued)
        self.assertEqual(attempt.first_reason, "TERM")

    def test_unknown_ownership_never_issues_rollback(self):
        attempt = self.armed()
        attempt.cancel("OWNERSHIP_UNCERTAIN")
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        self.assertFalse(attempt.rollback_issued)

    def test_terminal_needs_new_lease_and_no_outstanding_operations(self):
        attempt = self.armed()
        grant = attempt.grant("runtime", NS)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.prepare_terminal()
        attempt.complete(grant.grant_id)
        attempt.prepare_terminal()
        with self.assertRaises(supervisor.SupervisorError):
            attempt.terminal(0)
        acknowledged(attempt)
        attempt.terminal(0)
        self.assertIsNone(attempt.result)
        attempt.finish_childless()
        self.assertEqual(attempt.result, (0, "COMPLETED"))

    def test_bootstrap_must_arm_before_terminal_intent(self):
        acknowledged(self.attempt)
        with self.assertRaisesRegex(supervisor.SupervisorError, "TERMINAL_REFUSED"):
            self.attempt.prepare_terminal()
        self.attempt.arm()
        acknowledged(self.attempt)
        self.attempt.prepare_terminal()
        acknowledged(self.attempt)
        self.attempt.terminal(0, "bootstrapped")
        self.assertIsNone(self.attempt.result)
        self.assertEqual(self.attempt.pending_outcome, "bootstrapped")

    def test_terminal_outcomes_are_fixed_and_operation_scoped(self):
        for operation, outcome in (
            ("deploy", "already-completed"), ("forward-recover", "bootstrapped"),
            ("deploy", "private-canary"), ("deploy", []),
        ):
            with self.subTest(operation=operation, outcome=outcome):
                attempt = supervisor.Attempt(operation, clock=self.clock)
                acknowledged(attempt)
                attempt.arm()
                acknowledged(attempt)
                attempt.prepare_terminal()
                acknowledged(attempt)
                with self.assertRaisesRegex(supervisor.SupervisorError, "TERMINAL_REFUSED"):
                    attempt.terminal(0, outcome)
                self.assertIsNone(attempt.pending_outcome)

    def test_terminal_publication_cannot_reset_or_consume_cleanup_reserve(self):
        attempt = self.armed()
        original = (attempt.t0, attempt.work_end, attempt.hard_end)
        attempt.prepare_terminal()
        acknowledged(attempt)
        attempt.terminal(0, "bootstrapped")
        self.clock.advance(539)
        attempt._change("drained")  # supervisor-owned post-ECHILD revision
        publication = attempt.grant("lease-publish", 10 * NS)
        self.assertEqual(publication.end_ns, original[1])
        self.clock.advance(1)
        attempt.poll()
        self.assertIsNone(attempt.pending_terminal)
        self.assertIsNone(attempt.pending_outcome)
        self.assertEqual((attempt.t0, attempt.work_end, attempt.hard_end), original)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.complete(publication.grant_id)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.finish_childless()

    def test_expired_publication_does_not_signal_after_passive_keeper_transition(self):
        source = (SCRIPTS / "test_vps_timepad_supervisor.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        expiry = next(
            node.test for node in ast.walk(tree) if isinstance(node, ast.If)
            and "now >= self.completion_grant.end_ns" in ast.unparse(node.test)
        )
        condition = compile(ast.Expression(expiry), "<publication-expiry>", "eval")
        instance = supervisor.Supervisor.__new__(supervisor.Supervisor)
        instance.attempt = self.attempt
        instance.completion_pid = 123
        instance.completion_grant = supervisor.Grant(
            "a" * 32, "lease-publish", 10, self.attempt.nonce, self.attempt.role,
        )
        self.assertTrue(eval(condition, {}, {"self": instance, "now": 10}))
        self.attempt.unconfirmed()
        self.assertFalse(eval(condition, {}, {"self": instance, "now": 10}))

    def test_unconfirmed_publication_cannot_start_at_or_after_hard_end(self):
        instance = supervisor.Supervisor.__new__(supervisor.Supervisor)
        instance.attempt = SimpleNamespace(hard_end=100, clock=mock.Mock(return_value=100))
        instance.lease_snapshots = {3: {"lifecycle": "quiescence-unconfirmed"}}
        instance._begin_publication = mock.Mock()
        self.assertFalse(instance._publish_unconfirmed())
        instance._begin_publication.assert_not_called()
        instance.attempt.clock.return_value = 99
        self.assertTrue(instance._publish_unconfirmed())
        instance._begin_publication.assert_called_once_with(terminal=False)

    def test_cancellation_snapshots_are_ordered_bounded_and_do_not_share_worker_lists(self):
        instance = supervisor.Supervisor.__new__(supervisor.Supervisor)
        instance.attempt = self.attempt
        instance.identity = {
            "pid": 123, "startTicks": 456,
            "bootId": "01234567-89ab-cdef-0123-456789abcdef",
        }
        instance.worker_identity = {**instance.identity, "pid": 124}
        instance.worker_identities = [{"mode": "controller-worker", **instance.worker_identity}]
        instance.lease_snapshots = {}
        self.attempt.on_change = instance._record_lease
        instance._record_lease()
        self.attempt.cancel("TERM", 143)
        self.assertEqual(list(instance.lease_snapshots), [0, 1, 2, 3])
        self.assertEqual([row["lifecycle"] for row in instance.lease_snapshots.values()],
                         ["registered", "armed", "cancel-forward", "drain-forward"])
        snapshots = list(instance.lease_snapshots.values())
        for before, after in zip(snapshots, snapshots[1:]):
            state._validate_lease_successor(before, after)
        instance.worker_identities.append({"mode": "rollback-worker", **instance.identity, "pid": 125})
        self.assertTrue(all(len(row["workers"]) == 1 for row in snapshots))
        instance._published(1)
        self.assertEqual(list(instance.lease_snapshots), [2, 3])
        self.attempt.unconfirmed()
        revision = self.attempt.revision
        self.attempt.unconfirmed()
        self.assertEqual(self.attempt.revision, revision)

    def test_post_echild_publication_is_the_only_new_execution_site(self):
        # The event-loop branch is driven by waitpid's ECHILD result. Draining
        # cannot fork a metadata writer while a prior writer is still alive.
        source = (SCRIPTS / "test_vps_timepad_supervisor.py").read_text(encoding="utf-8")
        tree = ast.parse(source)
        run = next(
            method for node in tree.body if isinstance(node, ast.ClassDef)
            and node.name == "Supervisor" for method in node.body
            if isinstance(method, ast.FunctionDef) and method.name == "run"
        )

        def publication_calls(node, guards=()):
            if isinstance(node, ast.If):
                yield from publication_calls(node.test, guards)
                for child in node.body:
                    yield from publication_calls(child, (*guards, ast.unparse(node.test)))
                for child in node.orelse:
                    yield from publication_calls(child, guards)
            else:
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and \
                        node.func.attr == "_begin_publication":
                    yield guards
                for child in ast.iter_child_nodes(node):
                    yield from publication_calls(child, guards)

        calls = list(publication_calls(run))
        self.assertTrue(calls)
        self.assertTrue(all(any("childless" in guard for guard in guards) for guards in calls))
        self.assertTrue(any(
            any("pending_terminal is not None" in guard for guard in guards)
            for guards in calls
        ))
        self.assertTrue(any(
            any("self.attempt.draining" in guard for guard in guards)
            for guards in calls
        ))

    def test_drill_86_only_after_successful_admitted_rollback(self):
        attempt = self.armed()
        attempt.prepare_terminal()
        acknowledged(attempt)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.terminal(86)

    def test_grants_and_frames_are_bounded(self):
        attempt = self.armed()
        for _ in range(supervisor.MAX_GRANTS):
            attempt.grant("docker", NS)
        with self.assertRaises(supervisor.SupervisorError):
            attempt.grant("docker", NS)
        with self.assertRaises(supervisor.SupervisorError):
            supervisor.encode({"payload": "x" * supervisor.MAX_FRAME})
        for payload in (
            b'{"kind":"hello","kind":"arm"}', b"[]", b'{"a":' + b"[" * 10000,
            b"x" * (supervisor.MAX_FRAME + 1),
        ):
            with self.subTest(size=len(payload)), self.assertRaises(supervisor.SupervisorError):
                supervisor.decode(payload)

    def test_no_arbitrary_exec_or_production_deadline_flag(self):
        parser = supervisor._cli()
        with mock.patch("sys.stderr"):
            for argv in (
                ["relay", "--root", "/tmp/x", "--operation", "shell"],
                ["relay", "--root", "/tmp/x", "--operation", "deploy", "--work-seconds", "1"],
                ["client", "--root", "/tmp/x", "exec", "sh"],
            ):
                with self.subTest(argv=argv), self.assertRaises(SystemExit):
                    parser.parse_args(argv)

    def test_integer_grants_refuse_bool_zero_negative_and_unbounded(self):
        attempt = self.armed()
        for duration in (True, 0, -1, 601 * NS, 0.5):
            with self.subTest(duration=duration), self.assertRaises(supervisor.SupervisorError):
                attempt.grant("docker", duration)

    def test_private_grant_validation_never_renews_or_revives_authority(self):
        attempt = self.armed()
        grant = attempt.grant("state-publish", 2 * NS)
        idle_end = attempt.idle_end
        for _ in range(3):
            self.assertEqual(grant, attempt.validate_grant(grant.grant_id, grant.end_ns))
            self.assertEqual(idle_end, attempt.idle_end)
        for grant_id, end in (
            ("f" * 32, grant.end_ns), (grant.grant_id, grant.end_ns + 1),
            (grant.grant_id, True),
        ):
            with self.subTest(grant_id=grant_id, end=end), self.assertRaises(supervisor.SupervisorError):
                attempt.validate_grant(grant_id, end)
        self.clock.advance(2)
        with self.assertRaisesRegex(supervisor.SupervisorError, "GRANT_REVOKED"):
            attempt.validate_grant(grant.grant_id, grant.end_ns)
        attempt.poll()
        self.assertEqual(attempt.first_reason, "WAIT_EXPIRED")
        self.assertEqual(attempt.after_drain(), "rollback-worker")
        acknowledged(attempt)
        with self.assertRaisesRegex(supervisor.SupervisorError, "GRANT_REVOKED"):
            attempt.validate_grant(grant.grant_id, grant.end_ns)

    def test_completed_or_unacknowledged_grant_cannot_admit_a_state_writer(self):
        attempt = self.armed()
        grant = attempt.grant("state-publish", NS)
        attempt.acked_revision = -1
        with self.assertRaisesRegex(supervisor.SupervisorError, "GRANT_REVOKED"):
            attempt.validate_grant(grant.grant_id, grant.end_ns)
        acknowledged(attempt)
        attempt.complete(grant.grant_id)
        with self.assertRaisesRegex(supervisor.SupervisorError, "GRANT_REVOKED"):
            attempt.validate_grant(grant.grant_id, grant.end_ns)

    def test_cleanup_failure_cannot_start_a_second_cleanup_worker(self):
        attempt = self.armed()
        attempt.cancel("EXIT")
        self.clock.advance(540)
        attempt.after_drain()
        self.assertEqual(attempt.role, "fail-closed-worker")
        self.assertIsNone(attempt.after_drain())
        self.assertEqual(attempt.result, (1, "QUIESCENCE_UNCONFIRMED"))

    def test_failed_or_unconfirmed_drill_never_returns_success_86(self):
        attempt = self.armed()
        attempt.cancel("DRILL", 86)
        attempt.unconfirmed()
        self.assertEqual(attempt.first_status, 86)
        self.assertEqual(attempt.result, (1, "QUIESCENCE_UNCONFIRMED"))


def create_fixture(attempt="b" * 32, *, role="initial", sequence=1):
    identity = {
        "pid": 321, "processGroup": 321, "startTicks": 456,
        "bootId": "01234567-89ab-cdef-0123-456789abcdef",
        "commandDigest": "a" * 64, "attemptId": "c" * 32 + ":1",
    }
    grant = supervisor.Grant("d" * 32, "create-execute", 300 * NS, attempt, "controller-worker")
    create = supervisor.CreateAttempt(role, identity["attemptId"], grant)
    create.identity = identity
    request = {
        "nonce": "e" * 32, "sequence": sequence, "executionAttempt": attempt,
        "operation": "create", "containerId": None, "imageId": "f" * 64,
        "configHash": None, "childAttemptId": identity["attemptId"],
        "lifecycle": "intent", "responseId": None, "completionDigest": None,
        "originDigest": "1" * 64, "operationEpoch": 1, "incidentId": "c" * 32,
        "operationToken": "2" * 32, "preparedProofDigest": "3" * 64,
        "modelDigest": "4" * 64, "toolingDigest": "5" * 64,
        "resourcesDigest": "6" * 64, "resourceRequestDigest": "7" * 64,
        "role": role, "priorContainerId": None if role == "initial" else "8" * 64,
        "childIdentity": identity,
    }
    return create, request, state.create_request_digest(request)


def recovery_create_fixture(origin_digest, identity, *, replacement=False):
    _, request, _ = create_fixture(role="replacement" if replacement else "initial", sequence=2 if replacement else 1)
    if replacement:
        child = dict(request["childIdentity"], attemptId=request["incidentId"] + ":2")
        request = dict(request, childIdentity=child, childAttemptId=child["attemptId"])
    request = dict(request, originDigest=origin_digest)
    image = {
        "id": "target", "domain": "new-schema", "tuple": {
            "repositoryDigest": ACK, "platformImageId": request["imageId"],
            "revision": "c" * 40, "version": "1.0.0",
            "migrationInventoryDigest": ACK, "migrationResources": ["reviewed"],
            "beforeSchema": ACK, "afterSchema": ACK, "guardEvidence": ACK,
            "dependencyPolicy": "resolved", "dependencyFloor": ACK,
            "recoveryEvidence": ACK, "retryExact": True, "unknownTransitionCovered": True,
        },
    }
    predecessor = {**image, "id": "prior"}
    approved = {
        "schema": state.CONTRACT_SCHEMA, "formatVersion": 1, "controller": state.CONTROLLER,
        "active": True, "rootId": "test-root", "initialDomain": [],
        "images": [image, predecessor], "transitions": [{
            "id": "transition", "targetId": "target", "beforeSchema": ACK, "afterSchema": ACK,
            "compatiblePredecessors": ["prior"],
        }],
    }
    prepared = state.new_prepared_state(
        state.new_ready_state(origin_digest), operation="deploy", run_id="original",
        incident_id=request["incidentId"],
        admission=state.admit(
            approved, root_id="test-root", target_id="target", predecessor_id="prior",
            transition_id="transition", target_tuple=image["tuple"], predecessor_tuple=predecessor["tuple"],
        ),
        target=image, predecessor=predecessor, predecessor_container_id="0" * 64,
        transition_id="transition", owned_run="123-5", tooling_digest=request["toolingDigest"],
        prepared_proof_digest=request["preparedProofDigest"],
        execution_attempt=request["executionAttempt"],
    )
    receipt = state._canonical({
        "schema": state.CREATE_COMPLETION_SCHEMA, "requestDigest": state.create_request_digest(request),
        "executionAttempt": request["executionAttempt"], "childIdentity": request["childIdentity"],
        "resourcesDigest": request["resourcesDigest"],
        "resourceRequestDigest": request["resourceRequestDigest"],
        "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
    })
    request = dict(request, lifecycle="normal-completed", completionDigest=hashlib.sha256(receipt).hexdigest())
    current = dict(
        prepared, phase="RECOVERY_REQUIRED", latestAttemptId=request["childAttemptId"], runtimeRequest=request,
    )
    if replacement:
        current.update(
            phase="COMMITTING", containerId=request["priorContainerId"], configHash="9" * 64,
            commitWitnessDigest="a" * 64, providerFinalizationDigest="b" * 64,
            commitSubstep="replacement-create-intent",
        )
    current = state._current(current)
    old = supervisor.Attempt("deploy", clock=Clock(), nonce=request["executionAttempt"])
    old.arm()
    old.cancel("EXIT")
    previous = state._execution_lease({
        **old.lease(), "lifecycle": "drained", "revision": 4,
        "supervisor": {**identity, "pid": 2_000_000_001}, "worker": None,
        "workerMode": "controller-worker",
        "workers": [{"mode": "controller-worker", **identity, "pid": 2_000_000_002}],
        "createCompletion": {
            **{key: value for key, value in json.loads(receipt).items() if key != "schema"},
            "receiptDigest": request["completionDigest"], "acknowledged": True,
        },
    })
    return approved, current, previous, receipt


class CreateProtocolTests(unittest.TestCase):
    """Deterministic authority, replay, wait and publisher race coverage."""

    def setUp(self):
        # Symbolic constants only: portable mocks do not create Unix sockets.
        for name, fallback in (("AF_UNIX", 1), ("SOCK_SEQPACKET", 5)):
            self.enterContext(mock.patch.object(socket, name, getattr(socket, name, fallback), create=True))

    def running(self):
        create, request, digest = create_fixture()
        create.phase = "checking-release"
        create.bind_request(request, digest, create.identity)
        create.release()
        return create

    def ready(self):
        create = self.running()
        create.observe_result({
            "kind": "create-result", "attempt": create.grant.attempt,
            "requestDigest": create.request_digest, "childIdentity": create.identity,
            "waitStatus": 0, "descendantsDrained": True,
        })
        create.wait_status = 0
        self.assertTrue(create.ready(unexpected_children=False, now=100 * NS))
        return create

    def instance(self):
        me = supervisor.ProcessIdentity(100, 1, 42, 0)
        with mock.patch.object(supervisor, "linux_preflight"), \
                mock.patch.object(supervisor, "process_identity", return_value=me), \
                mock.patch.object(supervisor, "boot_id", return_value="01234567-89ab-cdef-0123-456789abcdef"):
            instance = supervisor.Supervisor("/fixture", "deploy", [], mock.Mock())
        instance.attempt.clock = Clock()
        instance.attempt.idle_end = instance.attempt.clock() + 30 * NS
        instance.attempt.arm()
        acknowledged(instance.attempt)
        return instance

    def test_fixed_rpc_cli_accepts_only_the_four_defined_shapes(self):
        parser = supervisor._cli()
        for argv in (
            ["create-launch", "--role", "initial", "--attempt-id", "c" * 32 + ":1"],
            ["create-release", "--request-digest", ACK, "--child-identity-json", "{}"],
            ["create-result", "--request-digest", ACK],
            ["create-completion", "--request-digest", ACK, "--child-identity-json", "{}"],
        ):
            self.assertEqual(argv[0], parser.parse_args(["client", "--root", "/fixture", *argv]).call)
        with mock.patch("sys.stderr"):
            for argv in (
                ["create-launch", "--role", "rollback", "--attempt-id", "c" * 32 + ":1"],
                ["create-launch", "--role", "initial", "--attempt-id", "c" * 32 + ":1", "--", "sh"],
                ["create-release", "--request-digest", ACK, "--argv", "sh"],
                ["grant", "create-completion", "10"], ["grant", "create-execute", "240"],
            ):
                with self.subTest(argv=argv), self.assertRaises(SystemExit):
                    parser.parse_args(["client", "--root", "/fixture", *argv])

    def test_launcher_attempt_role_and_sequence_are_strict(self):
        grant = create_fixture()[0].grant
        for role, attempt in (
            ("initial", ""), ("initial", "../1"), ("initial", "c" * 32 + ":0"),
            ("initial", "c" * 32 + ":" + str(1 << 64)), ("rollback", "c" * 32 + ":1"),
            ([], "c" * 32 + ":1"), ("initial", None),
        ):
            with self.subTest(role=role, attempt=attempt), self.assertRaises(supervisor.SupervisorError):
                supervisor.CreateAttempt(role, attempt, grant)

    def test_release_binds_intent_role_nonce_sequence_resources_and_identity(self):
        for field, wrong in (
            ("executionAttempt", "0" * 32), ("role", "replacement"),
            ("sequence", 0), ("nonce", "0" * 32), ("resourcesDigest", "0" * 64),
            ("resourceRequestDigest", "0" * 64), ("lifecycle", "normal-completed"),
            ("childAttemptId", "c" * 32 + ":2"),
            ("childIdentity", {**create_fixture()[0].identity, "startTicks": 999}),
        ):
            create, request, digest = create_fixture()
            create.phase = "checking-release"
            with self.subTest(field=field), self.assertRaises(supervisor.SupervisorError):
                create.bind_request({**request, field: wrong}, digest, create.identity)
            self.assertFalse(create.released)
        create, request, digest = create_fixture()
        create.phase = "checking-release"
        with self.assertRaises(supervisor.SupervisorError):
            create.bind_request(request, digest, {**create.identity, "pid": 999})

    def test_release_and_completion_are_one_shot(self):
        create = self.running()
        with self.assertRaises(supervisor.SupervisorError):
            create.release()
        create = self.ready()
        create.begin_completion(create.request_digest, create.identity)
        with self.assertRaises(supervisor.SupervisorError):
            create.begin_completion(create.request_digest, create.identity)

    def test_launcher_result_alone_or_wait_alone_never_readies(self):
        create = self.running()
        create.observe_result({
            "kind": "create-result", "attempt": create.grant.attempt,
            "requestDigest": create.request_digest, "childIdentity": create.identity,
            "waitStatus": 0, "descendantsDrained": True,
        })
        self.assertFalse(create.ready(unexpected_children=False, now=100 * NS))
        create = self.running()
        create.wait_status = 0
        self.assertFalse(create.ready(unexpected_children=False, now=100 * NS))
        with self.assertRaises(supervisor.SupervisorError):
            create.begin_completion(create.request_digest, create.identity)

    def test_failed_wait_or_adopted_descendants_or_expiry_never_readies(self):
        for status, unexpected, now in (
            (1, False, 100 * NS), (0, True, 100 * NS), (0, False, 300 * NS),
        ):
            create = self.ready()
            create.phase = "running"
            create.wait_status = status
            with self.subTest(status=status, unexpected=unexpected, now=now), \
                    self.assertRaises(supervisor.SupervisorError):
                create.ready(unexpected_children=unexpected, now=now)
        create = self.ready()
        with self.assertRaises(supervisor.SupervisorError):
            create.ready(unexpected_children=True, now=100 * NS)

    def test_result_cannot_fabricate_wait_or_local_echild_or_replay(self):
        for changes in (
            {"attempt": "0" * 32}, {"requestDigest": "0" * 64},
            {"waitStatus": 1}, {"waitStatus": False},
            {"descendantsDrained": False}, {"descendantsDrained": 1}, {"argv": ["sh"]},
        ):
            create = self.running()
            result = {
                "kind": "create-result", "attempt": create.grant.attempt,
                "requestDigest": create.request_digest, "childIdentity": create.identity,
                "waitStatus": 0, "descendantsDrained": True,
            }
            with self.subTest(changes=changes), self.assertRaises(supervisor.SupervisorError):
                create.observe_result({**result, **changes})
        create = self.ready()
        with self.assertRaises(supervisor.SupervisorError):
            create.observe_result(create.result)

    def test_receipt_binds_both_resource_digests_and_exact_state_contract(self):
        create = self.ready()
        create.begin_completion(create.request_digest, create.identity)
        receipt = create.receipt()
        self.assertEqual(create.request["resourcesDigest"], receipt["resourcesDigest"])
        self.assertEqual(create.request["resourceRequestDigest"], receipt["resourceRequestDigest"])
        digest = hashlib.sha256(supervisor.encode(receipt)).hexdigest()
        completed = {
            "runtimeRequest": dict(create.request, lifecycle="normal-completed", completionDigest=digest),
        }
        evidence = {
            **{key: value for key, value in receipt.items() if key != "schema"},
            "receiptDigest": digest, "acknowledged": True,
        }
        state.validate_create_completion(
            completed, {"attempt": create.grant.attempt, "createCompletion": evidence},
            supervisor.encode(receipt), acknowledged=True,
        )
        for field in ("resourcesDigest", "resourceRequestDigest"):
            with self.subTest(field=field), self.assertRaises(state.GuardError):
                state.validate_create_completion(completed, {
                    "attempt": create.grant.attempt, "createCompletion": {**evidence, field: "0" * 64},
                }, supervisor.encode(receipt), acknowledged=True)

    def test_cancellation_or_role_change_refuses_every_create_rpc_before_fork(self):
        for change in ("cancel", "rollback", "expiry", "unacknowledged"):
            instance = self.instance()
            if change == "cancel":
                instance.attempt.cancel("TERM", 143)
            elif change == "rollback":
                instance.attempt.role = "rollback-worker"
            elif change == "expiry":
                instance.attempt.clock.advance(540)
            else:
                instance.attempt.acked_revision = -1
            with self.subTest(change=change), mock.patch.object(instance, "_launch_create") as launch, \
                    self.assertRaises(supervisor.SupervisorError):
                instance._create_rpc("create-launch", {
                    "createRole": "initial", "attemptId": "c" * 32 + ":1",
                }, mock.Mock(), supervisor.ProcessIdentity(200, 100, 2, 0))
            launch.assert_not_called()

    def test_signal_queued_at_release_or_ack_boundary_revokes_before_action(self):
        instance = self.instance()
        instance.pending_signals.append(signal.SIGTERM)
        with mock.patch.object(instance, "_notify_clock"), \
                self.assertRaises(supervisor.SupervisorError):
            instance._create_internal_grant("create-completion", 10 * NS)
        self.assertEqual(("TERM", 143), (instance.attempt.first_reason, instance.attempt.first_status))
        self.assertFalse(instance.attempt.grants)
        self.assertEqual([], instance.pending_signals)

    def test_completion_revokes_competing_publisher_and_cannot_park_or_publish(self):
        instance = self.instance()
        instance.create = self.ready()
        instance.create.grant = supervisor.Grant(
            "d" * 32, "create-execute", instance.attempt.work_end, instance.attempt.nonce,
            "controller-worker",
        )
        instance.attempt.grants[instance.create.grant.grant_id] = instance.create.grant
        instance.attempt.grant("state-publish", NS)
        with mock.patch.object(instance, "_create_peer_chain"), \
                mock.patch.object(instance, "_park_create_controller") as park, \
                self.assertRaisesRegex(supervisor.SupervisorError, "OWNERSHIP_UNCERTAIN"):
            instance._create_rpc("create-completion", {
                "requestDigest": instance.create.request_digest, "childIdentity": instance.create.identity,
            }, mock.Mock(), supervisor.ProcessIdentity(200, 100, 2, 0))
        park.assert_not_called()
        self.assertFalse(instance.attempt.grants)
        self.assertFalse(instance.create.completion_issued)

    def test_result_polling_never_renews_grants_or_clock(self):
        instance = self.instance()
        instance.create = self.ready()
        before = (instance.attempt.t0, instance.attempt.work_end, instance.attempt.hard_end,
                  instance.attempt.idle_end, instance.attempt.revision)
        with mock.patch.object(instance, "_create_peer_chain"):
            for _ in range(20):
                self.assertEqual({"status": "ready"}, instance._create_rpc("create-result", {
                    "requestDigest": instance.create.request_digest,
                }, mock.Mock(), supervisor.ProcessIdentity(200, 100, 2, 0)))
        self.assertEqual(before, (instance.attempt.t0, instance.attempt.work_end, instance.attempt.hard_end,
                                  instance.attempt.idle_end, instance.attempt.revision))

    def test_private_controller_ancestry_rejects_foreign_peer_and_reused_start(self):
        instance = self.instance()
        instance.worker_pid = 200
        instance.worker_identity = {
            "pid": 200, "startTicks": 123, "bootId": "01234567-89ab-cdef-0123-456789abcdef",
        }
        for peer in (
            supervisor.ProcessIdentity(201, 100, 4, 0),
            supervisor.ProcessIdentity(200, 100, 124, 0),
            supervisor.ProcessIdentity(200, 100, 123, 99),
        ):
            with self.subTest(peer=peer), mock.patch.object(
                supervisor, "boot_id", return_value=instance.worker_identity["bootId"],
            ), mock.patch.object(
                supervisor.os, "geteuid", return_value=0, create=True,
            ), mock.patch.object(
                supervisor.os, "getpid", return_value=100,
            ), self.assertRaises(supervisor.SupervisorError):
                instance._create_peer_chain(peer)

    def test_cancelled_publisher_cannot_resume_controller_or_ack_completion(self):
        instance = self.instance()
        instance.create = self.ready()
        instance.create.phase = "publishing"
        instance.create_reply = mock.Mock()
        instance.create_parked = [(supervisor.ProcessIdentity(200, 100, 2, 0), 33)]
        instance.attempt.cancel("TERM", 143)
        with mock.patch.object(instance, "_resume_create_controller") as resume:
            instance._tick_create({})
        resume.assert_called_once_with(cancel=True)
        self.assertIsNone(instance.create_reply)
        self.assertEqual("publishing", instance.create.phase)

    def test_completion_wait_and_ack_are_both_required_before_unparking(self):
        instance = self.instance()
        instance.create = self.ready()
        instance.create.phase = "publishing"
        instance.create_helper_pid = 345
        instance.create_helper_stage = "publish"
        instance.create_helper_result = {"receiptDigest": ACK, "sequence": 1}
        with mock.patch.object(instance.children, "refresh"), \
                mock.patch.object(instance, "_resume_create_controller") as resume:
            instance._tick_create({})
        resume.assert_not_called()
        instance.create_helper_status = 0
        instance.create_completion_evidence = {"receiptDigest": ACK, "acknowledged": False}
        with mock.patch.object(instance.children, "refresh"), \
                mock.patch.object(instance, "_resume_create_controller") as resume, \
                self.assertRaises(supervisor.SupervisorError):
            instance._tick_create({})
        resume.assert_not_called()

    def test_only_successful_publisher_wait_and_durable_ack_resume_then_reply_once(self):
        instance = self.instance()
        instance.create = self.ready()
        instance.create.phase = "publishing"
        instance.create_helper_pid = 345
        instance.create_helper_status = 0
        instance.create_helper_stage = "publish"
        instance.create_helper_result = {"receiptDigest": ACK, "sequence": 1}
        instance.create_completion_evidence = {"receiptDigest": ACK, "acknowledged": True}
        instance.attempt.grants[instance.create.grant.grant_id] = instance.create.grant
        events = []
        with mock.patch.object(instance.children, "refresh"), \
                mock.patch.object(instance, "_resume_create_controller",
                                  side_effect=lambda **kwargs: events.append(("resume", kwargs))), \
                mock.patch.object(instance, "_create_reply",
                                  side_effect=lambda value: events.append(("reply", value))):
            instance._tick_create({})
            instance._tick_create({})
        self.assertEqual([
            ("resume", {"cancel": False}), ("reply", {"receiptDigest": ACK, "sequence": 1}),
        ], events)
        self.assertEqual("completed", instance.create.phase)
        self.assertFalse(instance.attempt.grants)

    def test_rpc_kernel_peer_and_nonce_role_schema_are_fenced(self):
        for change in ({}, {"attempt": "0" * 32}, {"role": "rollback-worker"},
                       {"argv": ["sh"]}, {"kind": "create-publisher-ack-intent"}):
            instance = self.instance()
            instance.worker = mock.Mock()
            instance.worker_hello = True
            peer = supervisor.ProcessIdentity(200, 100, 2, 0)
            frame = {
                "kind": "create-launch", "attempt": instance.attempt.nonce,
                "role": "controller-worker", "createRole": "initial",
                "attemptId": "c" * 32 + ":1", **change,
            }
            reply = mock.Mock(family=socket.AF_UNIX, type=socket.SOCK_SEQPACKET)

            def receive(_channel, **kwargs):
                kwargs["peer"].append(peer)
                return frame, 55

            with self.subTest(change=change), \
                    mock.patch.object(supervisor, "receive_frame", side_effect=receive), \
                    mock.patch.object(supervisor.socket, "socket", return_value=reply), \
                    mock.patch.object(supervisor, "send_frame"), \
                    mock.patch.object(instance, "_create_rpc", return_value={"status": "pending"}) as create_rpc:
                instance._rpc()
            # Bare create RPCs are no longer a shell capability. Only the
            # supervisor-recorded driver on its dedicated channel may use them.
            create_rpc.assert_not_called()
            self.assertEqual("PROTOCOL_INVALID", instance.attempt.first_reason)

    def test_controller_channel_cannot_use_internal_create_grant(self):
        for kind in ("complete", "validate-grant"):
            instance = self.instance()
            instance.worker = mock.Mock()
            instance.worker_hello = True
            instance.create, _, _ = create_fixture(instance.attempt.nonce)
            frame = {
                "kind": kind, "attempt": instance.attempt.nonce, "role": "controller-worker",
                "grantId": instance.create.grant.grant_id,
            }
            if kind == "validate-grant":
                frame["endNs"] = instance.create.grant.end_ns

            def receive(_channel, **kwargs):
                kwargs["peer"].append(supervisor.ProcessIdentity(200, 100, 2, 0))
                return frame, 55

            reply = mock.Mock(family=socket.AF_UNIX, type=socket.SOCK_SEQPACKET)
            with self.subTest(kind=kind), \
                    mock.patch.object(supervisor, "receive_frame", side_effect=receive), \
                    mock.patch.object(supervisor.socket, "socket", return_value=reply), \
                    mock.patch.object(supervisor, "send_frame") as send:
                instance._rpc()
            self.assertFalse(send.call_args.args[1]["ok"])
            self.assertEqual("PROTOCOL_INVALID", instance.attempt.first_reason)

    def test_parked_controller_requires_exact_stopped_chain_and_no_other_descendants(self):
        instance = self.instance()
        instance.create = self.ready()
        instance.worker_pid = 200
        controller = supervisor.ProcessIdentity(200, 100, 2, 0)
        caller = supervisor.ProcessIdentity(201, 200, 3, 0)
        instance.create_parked = [(controller, 33), (caller, 34)]
        for status, extra, expected in ((b"T", b"", True), (b"D", b"", False),
                                         (b"T", b"202", None)):
            def proc(path, *_args, **_kwargs):
                if path.endswith("/stat"):
                    return io.BytesIO(b"200 (fixture) " + status + b" 100\n")
                return io.BytesIO((b"201 " + extra) if "/200/" in path else b"")

            with self.subTest(status=status, extra=extra), \
                    mock.patch("builtins.open", side_effect=proc), \
                    mock.patch.object(supervisor, "process_identity", side_effect=lambda pid: {
                        200: controller, 201: caller,
                    }[pid]):
                if expected is None:
                    with self.assertRaisesRegex(supervisor.SupervisorError, "OWNERSHIP_UNCERTAIN"):
                        instance._create_controller_parked()
                else:
                    self.assertIs(expected, instance._create_controller_parked())

    def test_publication_order_and_each_failure_leave_no_successful_ack(self):
        for failure in (None, "lease-unacknowledged", "current", "ack-intent", "lease-acknowledged"):
            instance = self.instance()
            instance.create = self.ready()
            instance.create.phase = "publishing"
            before = instance._lease()
            after = {**before, "revision": before["revision"] + 1}
            events = []
            client = mock.Mock()

            def request(kind, **_kwargs):
                events.append(kind)
                if failure == "ack-intent" and kind == "create-publisher-ack-intent":
                    raise supervisor.SupervisorError("GRANT_REVOKED")
                return after if kind == "create-publisher-ack-intent" else {}

            client.request.side_effect = request

            def publish_lease(_root, snapshot, **_kwargs):
                event = "lease-unacknowledged" if snapshot is before else "lease-acknowledged"
                events.append(event)
                if failure == event:
                    raise state.GuardError("STATE_READBACK_FAILED")
                return {"attempt": instance.attempt.nonce, "revision": snapshot["revision"], "digest": ACK}

            def publish_current(_root, **kwargs):
                events.append("current")
                self.assertEqual(instance.create.request_digest, kwargs["request_digest"])
                self.assertEqual(
                    instance.create.receipt(),
                    supervisor.decode(kwargs["supervisor_wait_evidence"]),
                )
                if failure == "current":
                    raise state.GuardError("STATE_READBACK_FAILED")
                return {"receiptDigest": ACK, "sequence": 1}

            with self.subTest(failure=failure), \
                    mock.patch.object(supervisor, "WorkerClient", return_value=client), \
                    mock.patch.object(state, "publish_execution_lease", side_effect=publish_lease), \
                    mock.patch.object(state, "publish_create_completion", side_effect=publish_current):
                if failure:
                    with self.assertRaises((state.GuardError, supervisor.SupervisorError)):
                        instance._publish_create(before, instance.create.grant)
                else:
                    self.assertEqual({"receiptDigest": ACK, "sequence": 1}, instance._publish_create(
                        before, instance.create.grant,
                    ))
            expected = [
                "lease-unacknowledged", "create-publisher-lease-ack", "current",
                "create-publisher-ack-intent", "lease-acknowledged", "create-publisher-lease-ack",
            ]
            boundary = "create-publisher-ack-intent" if failure == "ack-intent" else failure
            self.assertEqual(expected if boundary is None else expected[:expected.index(boundary) + 1], events)


class RecoveryCreateRegistrationTests(unittest.TestCase):
    """Portable async protocol tests; filesystem and fork ownership are mocked."""

    def setUp(self):
        for name, fallback in (("AF_UNIX", 1), ("SOCK_SEQPACKET", 5)):
            self.enterContext(mock.patch.object(socket, name, getattr(socket, name, fallback), create=True))
        me = supervisor.ProcessIdentity(100, 1, 42, 0)
        with mock.patch.object(supervisor, "linux_preflight"), \
                mock.patch.object(supervisor, "process_identity", return_value=me), \
                mock.patch.object(supervisor, "boot_id",
                                  return_value="01234567-89ab-cdef-0123-456789abcdef"):
            self.instance = supervisor.Supervisor("/fixture", "forward-recover", [], mock.Mock())
        instance = self.instance
        self.clock = Clock()
        instance.attempt = supervisor.Attempt("forward-recover", clock=self.clock, nonce="9" * 32)
        instance.attempt.on_change = instance._record_lease
        instance.lock_fd = 9
        instance.worker_pid = 101
        instance.worker_identity = {**instance.identity, "pid": 101}
        instance.worker_identities = [{"mode": "controller-worker", **instance.worker_identity}]
        instance._record_lease()
        _, self.current, self.previous, self.receipt = recovery_create_fixture("1" * 64, instance.identity)
        instance.recovery_baseline = {
            "lease": deepcopy(self.previous),
            "currentDigest": hashlib.sha256(state._canonical(self.current)).hexdigest(),
        }
        instance.children = mock.Mock(tracked={instance.worker_pid: mock.Mock()})
        self.files = {"lease": self.previous, "current": self.current}
        self.enterContext(mock.patch.object(state, "deploy_lock", return_value=nullcontext(9)))
        self.enterContext(mock.patch.object(
            state, "_read_execution_lease_locked", side_effect=lambda _root: self.files["lease"],
        ))
        self.enterContext(mock.patch.object(
            state, "_read_guard_locked", side_effect=lambda _root: ({}, self.files["current"]),
        ))
        self.exited = self.enterContext(mock.patch.object(
            state, "_execution_process_exited", return_value=True,
        ))
        self.enterContext(mock.patch.object(
            state, "_execution_process_record", return_value=(
                instance.identity["bootId"], instance.worker_identity["startTicks"],
                instance.identity["pid"],
            ),
        ))
        self.enterContext(mock.patch.object(state, "_execution_lease_supervisor_is_live", return_value=True))

        def require(_root, current, *, acknowledged):
            state.validate_create_completion(current, self.files["lease"], self.receipt,
                                             acknowledged=acknowledged)

        self.enterContext(mock.patch.object(state, "_require_create_completion_locked", side_effect=require))

    def rpc(self, kind, **fields):
        instance = self.instance
        instance.worker = mock.Mock()
        instance.worker_hello = True
        reply = mock.Mock(family=socket.AF_UNIX, type=socket.SOCK_SEQPACKET)

        def receive(_channel, **kwargs):
            kwargs["peer"].append(supervisor.ProcessIdentity(101, 100, 42, 0))
            return {
                "kind": kind, "attempt": instance.attempt.nonce, "role": "controller-worker", **fields,
            }, 55

        with mock.patch.object(supervisor, "receive_frame", side_effect=receive), \
                mock.patch.object(supervisor.socket, "socket", return_value=reply), \
                mock.patch.object(supervisor, "socket_pair", return_value=(mock.Mock(), mock.Mock())), \
                mock.patch.object(supervisor.os, "fork", return_value=555, create=True), \
                mock.patch.object(supervisor, "send_frame") as send, \
                mock.patch.object(instance, "_notify_clock"):
            instance._rpc()
        return send.call_args.args[1] if send.called else None

    def register(self):
        reply = self.rpc("grant", name="recovery-registration", localNs=30 * NS)
        self.assertTrue(reply["ok"])
        grant = self.instance.registration_grant
        self.assertIsNotNone(grant)
        self.files["lease"] = {
            **self.instance._lease(), "createCompletion": deepcopy(self.previous["createCompletion"]),
        }
        self.files["current"] = dict(self.current, executionAttempt=self.instance.attempt.nonce)
        return grant

    def acknowledge(self):
        response = self.rpc("lease-ack", revision=0,
                            digest=hashlib.sha256(state._canonical(self.files["lease"])).hexdigest())
        if response is not None:
            return response
        registration = self.instance.registration_ack
        registration.snapshot = state._read_recovery_registration_snapshot(
            self.instance.root, self.instance._lease(), registration.digest,
            self.instance.recovery_baseline, deploy_lock_fd=9,
        )
        with mock.patch.object(supervisor, "send_frame") as send:
            self.instance._tick_registration({registration.pid: 0})
        return send.call_args.args[1]

    def test_exact_state_helper_successor_is_retained_through_arm_cancellation_and_drain(self):
        grant = self.register()
        self.assertIsNone(self.instance.create_completion_evidence)
        self.assertTrue(self.rpc("complete", grantId=grant.grant_id)["ok"])
        self.assertTrue(self.instance.attempt.recovery_registration_completed)
        self.assertTrue(self.acknowledge()["ok"])
        self.assertIsNone(self.instance.registration_ack)
        instance = self.instance
        registered = instance._lease()
        self.assertEqual(self.files["lease"], registered)
        instance.attempt.arm()
        instance.attempt.cancel("TERM", 143)
        instance.attempt.after_drain()
        instance.worker_identity = None
        instance.attempt._change("drained")
        snapshots = [registered, *[instance.lease_snapshots[key] for key in sorted(instance.lease_snapshots)]]
        for previous, candidate in zip(snapshots, snapshots[1:]):
            state._validate_lease_successor(previous, candidate)
            self.assertEqual(self.previous["createCompletion"], candidate["createCompletion"])
        self.assertEqual(self.current["runtimeRequest"], self.files["current"]["runtimeRequest"])
        self.assertIsNone(self.files["current"]["containerId"])
        self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())
        with self.assertRaises(state.GuardError):
            state.require_runtime_request_completion(self.files["current"])

    def test_capture_rejects_missing_receipt_acknowledgment_drained_or_process_proof(self):
        for fault in ("missing", "receipt", "unacknowledged", "resources", "live", "undrained"):
            lease = deepcopy(self.previous)
            if fault == "missing":
                lease["createCompletion"] = None
            elif fault == "unacknowledged":
                lease["createCompletion"]["acknowledged"] = False
            elif fault == "resources":
                lease["createCompletion"]["resourcesDigest"] = "0" * 64
            elif fault == "undrained":
                lease["lifecycle"] = "draining"
            self.instance.recovery_baseline["lease"] = lease
            self.files["lease"] = {
                **self.instance._lease(), "createCompletion": lease["createCompletion"],
            }
            self.files["current"] = dict(self.current, executionAttempt=self.instance.attempt.nonce)
            self.exited.return_value = fault != "live"
            with self.subTest(fault=fault), mock.patch.object(
                self, "receipt", b"{}" if fault == "receipt" else self.receipt,
            ):
                with self.assertRaises(state.GuardError):
                    state._read_recovery_registration_snapshot(
                        self.instance.root, self.instance._lease(),
                        hashlib.sha256(state._canonical(self.files["lease"])).hexdigest(),
                        self.instance.recovery_baseline, deploy_lock_fd=9,
                    )
                self.assertIsNone(self.instance.create_completion_evidence)
                self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())

    def test_registration_ack_rejects_erasure_mutation_replay_and_missing_proof(self):
        grant = self.register()
        self.assertTrue(self.rpc("complete", grantId=grant.grant_id)["ok"])
        expected = deepcopy(self.files)
        for fault in ("erased", "resource", "current", "receipt", "old-lease", "live", "digest"):
            self.files = deepcopy(expected)
            if fault == "erased":
                self.files["lease"]["createCompletion"] = None
            elif fault == "resource":
                self.files["lease"]["createCompletion"]["resourceRequestDigest"] = "0" * 64
            elif fault == "current":
                self.files["current"]["runtimeRequest"]["nonce"] = "0" * 32
            elif fault == "old-lease":
                self.files["lease"] = self.previous
            self.exited.return_value = fault != "live"
            digest = hashlib.sha256(state._canonical(self.files["lease"])).hexdigest()
            if fault == "digest":
                digest = "0" * 64
            with self.subTest(fault=fault), mock.patch.object(
                self, "receipt", b"{}" if fault == "receipt" else self.receipt,
            ), self.assertRaises(state.GuardError):
                state._read_recovery_registration_snapshot(
                    self.instance.root, self.instance._lease(), digest,
                    self.instance.recovery_baseline, deploy_lock_fd=9,
                )
            self.assertIsNone(self.instance.create_completion_evidence)
            self.assertEqual(-1, self.instance.attempt.acked_revision)
            self.assertFalse(state._RECOVERY_CREATE_COMPLETION_PROOF.get())

    def test_ack_before_registration_completion_or_after_cancellation_cannot_import_evidence(self):
        self.register()
        self.assertFalse(self.acknowledge()["ok"])
        self.assertIsNone(self.instance.create_completion_evidence)
        self.assertEqual("PROTOCOL_INVALID", self.instance.attempt.first_reason)

    def test_readback_alone_never_imports_without_exact_zero_wait(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.assertIsNone(self.rpc(
            "lease-ack", revision=0,
            digest=hashlib.sha256(state._canonical(self.files["lease"])).hexdigest(),
        ))
        registration = self.instance.registration_ack
        registration.snapshot = deepcopy(self.files["lease"])
        self.instance._tick_registration({})
        self.assertIsNone(self.instance.create_completion_evidence)
        with self.assertRaises(supervisor.SupervisorError):
            self.instance._tick_registration({registration.pid: 1})
        self.assertEqual(-1, self.instance.attempt.acked_revision)

    def test_registration_grant_expiry_never_imports(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.clock.now = grant.end_ns
        self.assertFalse(self.acknowledge()["ok"])
        self.assertIsNone(self.instance.registration_ack)
        self.assertIsNone(self.instance.create_completion_evidence)

    def test_cancellation_while_reader_runs_cannot_import_or_ack(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.rpc("lease-ack", revision=0,
                 digest=hashlib.sha256(state._canonical(self.files["lease"])).hexdigest())
        registration = self.instance.registration_ack
        registration.snapshot = deepcopy(self.files["lease"])
        self.instance.attempt.cancel("TERM", 143)
        with mock.patch.object(supervisor, "send_frame") as send:
            self.instance._tick_registration({registration.pid: 0})
        send.assert_not_called()
        registration.reply.close.assert_called_once()
        self.assertIsNone(self.instance.registration_ack)
        self.assertIsNone(self.instance.create_completion_evidence)

    def test_queued_signal_at_readback_boundary_revokes_before_ack(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.rpc("lease-ack", revision=0,
                 digest=hashlib.sha256(state._canonical(self.files["lease"])).hexdigest())
        registration = self.instance.registration_ack
        registration.snapshot = deepcopy(self.files["lease"])
        self.instance.pending_signals.append(signal.SIGTERM)
        with mock.patch.object(supervisor, "send_frame") as send, \
                mock.patch.object(self.instance, "_notify_clock"):
            self.instance._tick_registration({registration.pid: 0})
        send.assert_not_called()
        self.assertEqual("TERM", self.instance.attempt.first_reason)
        self.assertEqual(-1, self.instance.attempt.acked_revision)
        self.assertIsNone(self.instance.create_completion_evidence)

    def test_initial_registration_ack_is_one_shot(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.assertTrue(self.acknowledge()["ok"])
        self.assertFalse(self.acknowledge()["ok"])
        self.assertIsNone(self.instance.registration_ack)

    def test_acknowledged_replacement_completion_handoff_preserves_original_witness(self):
        _, self.current, self.previous, self.receipt = recovery_create_fixture(
            "1" * 64, self.instance.identity, replacement=True,
        )
        self.files = {"lease": self.previous, "current": self.current}
        self.instance.recovery_baseline = {
            "lease": deepcopy(self.previous),
            "currentDigest": hashlib.sha256(state._canonical(self.current)).hexdigest(),
        }
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.assertTrue(self.acknowledge()["ok"])
        self.assertEqual(self.previous["createCompletion"], self.instance._lease()["createCompletion"])
        for key in ("commitWitnessDigest", "providerFinalizationDigest", "configHash", "containerId", "commitSubstep"):
            self.assertEqual(self.current[key], self.files["current"][key])

    def test_replacement_intent_or_missing_completion_cannot_be_imported(self):
        for fault in ("intent", "missing", "unacknowledged"):
            _, current, previous, receipt = recovery_create_fixture(
                "1" * 64, self.instance.identity, replacement=True,
            )
            if fault == "intent":
                current["runtimeRequest"] = dict(current["runtimeRequest"], lifecycle="intent", completionDigest=None)
            elif fault == "missing":
                previous["createCompletion"] = None
            else:
                previous["createCompletion"]["acknowledged"] = False
            self.receipt = receipt
            self.instance.recovery_baseline = {
                "lease": previous, "currentDigest": hashlib.sha256(state._canonical(current)).hexdigest(),
            }
            self.files = {
                "lease": dict(self.instance._lease(), createCompletion=previous["createCompletion"]),
                "current": dict(current, executionAttempt=self.instance.attempt.nonce),
            }
            with self.subTest(fault=fault), self.assertRaises(state.GuardError):
                state._read_recovery_registration_snapshot(
                    self.instance.root, self.instance._lease(),
                    hashlib.sha256(state._canonical(self.files["lease"])).hexdigest(),
                    self.instance.recovery_baseline, deploy_lock_fd=9,
                )
            self.assertIsNone(self.instance.create_completion_evidence)

    def test_response_rejects_unknown_schema_and_unacknowledged_old_completion(self):
        grant = self.register()
        self.rpc("complete", grantId=grant.grant_id)
        self.rpc("lease-ack", revision=0,
                 digest=hashlib.sha256(state._canonical(self.files["lease"])).hexdigest())
        for snapshot in (
            dict(self.files["lease"], extra=True),
            dict(self.files["lease"], createCompletion=dict(
                self.previous["createCompletion"], acknowledged=False,
            )),
        ):
            with self.subTest(snapshot=snapshot), mock.patch.object(
                supervisor, "receive_frame", return_value=({"lease": snapshot}, None),
            ), self.assertRaises(supervisor.SupervisorError):
                self.instance._registration_response()
        self.assertIsNone(self.instance.create_completion_evidence)


class ControllerLifecycleTests(unittest.TestCase):
    """Execute actual shell functions with private deterministic RPC boundaries."""

    def test_historical_relay_transport_loss_is_a_fixed_fail_closed_result(self):
        source = SCRIPTS / "fixtures/timepad-controller/create-controller.py"
        recovery = next(
            node for node in ast.parse(source.read_text(encoding="utf-8")).body
            if isinstance(node, ast.FunctionDef) and node.name == "recover"
        )
        case = SCRIPTS / "fixtures/timepad-controller/relay-case"

        def write_private(path, value):
            with path.open("xb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(value)

        namespace = {
            "__file__": str(case / "tools/create-controller.py"), "Path": Path,
            "json": json, "os": os, "sys": sys, "time": time,
            "require": lambda condition, reason: condition or self.fail(reason),
            "private": write_private,
            "no_socket": mock.Mock(),
        }
        exec(compile(ast.Module(body=[recovery], type_ignores=[]), str(source), "exec"), namespace)
        hello = {
            "kind": "hello", "attempt": "a" * 32, "supervisor": {"pid": 123},
            "hardEndNs": time.monotonic_ns() + 600 * NS, "watchEndNs": 1,
        }
        arguments = ["--operation", "forward-recover", "--root", str(case / "root")]
        for received in (
            [supervisor.SupervisorError("PROTOCOL_INVALID")],
            [(hello, None), OSError("private transport detail")],
        ):
            with self.subTest(after_hello=len(received) > 1), \
                    mock.patch.dict(os.environ, {"TEST_VPS_STATE_ROOT": str(case / "state")}), \
                    mock.patch.dict(sys.modules, {"forward": SimpleNamespace(ForwardTransport=mock.Mock())}), \
                    mock.patch.object(supervisor, "socket_pair", return_value=(mock.Mock(), mock.Mock())), \
                    mock.patch.object(os, "fork", return_value=123, create=True), \
                    mock.patch.object(os, "WNOHANG", 1, create=True), \
                    mock.patch.object(os, "waitpid", return_value=(0, 0), create=True) as wait, \
                    mock.patch.object(supervisor, "_wait_readable"), \
                    mock.patch.object(supervisor, "receive_frame", side_effect=received), \
                    mock.patch.object(supervisor, "send_frame"), \
                    mock.patch.object(supervisor, "process_identity"), \
                    mock.patch.object(supervisor, "lease_identity", return_value=hello["supervisor"]), \
                    mock.patch.object(sys, "stdout", new_callable=io.StringIO) as output:
                self.assertEqual(1, namespace["recover"](case, arguments))
                self.assertEqual("schema_guard=QUIESCENCE_UNCONFIRMED\n", output.getvalue())
                wait.assert_called_once_with(123, os.WNOHANG)

    def test_registered_recovery_read_only_handoff_reaches_runtime_admission(self):
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        branch = source.index('if [ "$operation" = forward-recover ]; then')
        end = source.index("  recovery_target_id=", branch)
        script = self.function("recovery_budget_arm") + r"""
state_root=$1
recovery_t0_ns=
supervisor_enabled=true
recovery_admission_only=true
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TIMEPAD_WORKER_MODE=controller-worker
timepad_helper=/fixture/state.py
operation=forward-recover
recovery_run_key=original-run
recovery_incident=dddddddddddddddddddddddddddddddd
recovery_epoch=7
recovery_binding_digest=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
supervisor_client() {
  [ "$1" = lease ] || return 90
  echo '{"attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","lifecycle":"registered","t0Ns":100,"workEndNs":540000000100,"hardEndNs":600000000100}'
}
validate_timepad_input() { return 0; }
timeout() {
  case "$4" in
    authorize-recovery) echo '{"outcome":"authorized"}' ;;
    read-state) echo '{"current":{"operation":"deploy","phase":"CUTOVER_POSSIBLE","runId":"original-run","incidentId":"dddddddddddddddddddddddddddddddd","operationEpoch":7,"evidenceDigest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","ownedRun":"original-run-final-deploy"}}' ;;
    *) return 90 ;;
  esac
}
fail() { echo "$1" >&2; exit 91; }
""" + source[branch:end] + """
  echo runtime-admission
fi
"""
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "original-run-final-deploy").mkdir()
            result = self.shell(script, Path(directory).as_posix())
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("runtime-admission\n", result.stdout)

    def function(self, name):
        import re
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        match = re.search(r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.M | re.S)
        self.assertIsNotNone(match)
        return match.group()

    def shell(self, script, *arguments):
        bash = shutil.which("bash")
        if os.name == "nt":
            bash = str(Path(os.environ["ProgramFiles"]) / "Git/bin/bash.exe")
        self.assertIsNotNone(bash)
        return subprocess.run(
            [bash, "-s", "--", *arguments],
            input="set -euo pipefail\n" + script,
            # Git Bash process startup can dominate these mocked shell tests
            # on Windows. This is a harness ceiling, never an attempt budget.
            capture_output=True, text=True, timeout=120 if os.name == "nt" else 15, check=False,
        )

    def test_terminal_handshake_ack_order_and_each_refusal(self):
        script = self.function("supervisor_complete") + r"""
supervisor_enabled=true
fail() { echo "$1" >&2; exit 91; }
supervisor_client() {
  echo "$*" >&2
  [ "$1" != "$failure" ]
}
supervisor_publish_lease() {
  echo publish-and-ack >&2
  [ "$failure" != publish ]
}
failure=$1
supervisor_complete bootstrapped
"""
        for failure, events in (
            ("none", ["prepare-terminal", "publish-and-ack", "terminal 0 --outcome bootstrapped"]),
            ("prepare-terminal", ["prepare-terminal", "EXECUTION_TERMINAL_PREPARE_FAILED"]),
            ("publish", ["prepare-terminal", "publish-and-ack", "EXECUTION_LEASE_PUBLICATION_FAILED"]),
            ("terminal", ["prepare-terminal", "publish-and-ack", "terminal 0 --outcome bootstrapped",
                          "EXECUTION_TERMINAL_ACK_FAILED"]),
        ):
            with self.subTest(failure=failure):
                result = self.shell(script, failure)
                self.assertEqual(0 if failure == "none" else 91, result.returncode, result.stderr)
                self.assertEqual(result.stderr.splitlines(), events)
                self.assertEqual(result.stdout, "")

    def test_worker_exit_notifies_before_channel_close_preserves_status_and_never_runs_cleanup(self):
        script = self.function("supervisor_cancel_exit") + r"""
supervisor_client() {
  printf '%s\n' "$*" >>"$trace"
  [ "$fault" = none ]
}
complete_owned_child() { echo unexpected-reap; }
dispatch_failure() { echo unexpected-rollback; }
trace=$1
fault=$2
supervisor_cancel_exit "$3" "$4"
"""
        for status, reason, expected in (
            (0, "EXIT", []), (1, "EXIT", ["cancel EXIT 1"]),
            (86, "EXIT", ["cancel DRILL 86"]), (143, "TERM", ["cancel TERM 143"]),
        ):
            for fault in ("none", "revoked"):
                with self.subTest(status=status, reason=reason, fault=fault), \
                        tempfile.TemporaryDirectory() as directory:
                    trace = Path(directory, "trace")
                    result = self.shell(script, trace.as_posix(), fault, str(status), reason)
                    self.assertEqual(status, result.returncode, result.stderr)
                    self.assertEqual("", result.stdout + result.stderr)
                    self.assertEqual(expected, trace.read_text().splitlines() if trace.exists() else [])

        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        private_entry = source[source.index('if [ -n "${TIMEPAD_WORKER_MODE:-}" ]; then'):]
        self.assertLess(private_entry.index("trap 'supervisor_cancel_exit"),
                        private_entry.index("supervisor_register_recovery"))
        for handler in ("on_exit", "on_recovery_exit"):
            body = source[source.index(handler + "() {"):].split("trap - EXIT", 1)[0]
            self.assertIn('supervisor_cancel_exit "$status"', body)

    def test_provider_wait_binds_only_locking_helpers_to_attempt_and_grant(self):
        script = self.function("supervisor_timeout") + r"""
provider_helper=/fixture/provider.py
timepad_helper=/fixture/state.py
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
supervisor_client() {
  case "$1" in
    grant) echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","endNs":123456789}' ;;
    complete) ;;
    *) exit 90 ;;
  esac
}
command() {
  if [ "$1" = timeout ] && [ "$2" = 3s ]; then
    echo 1s
  else
    printf '%s\n' "$@"
  fi
}
supervisor_timeout 30s python3 "$provider_helper" "$1" --deploy-lock-fd 9
"""
        for operation in (
            "live-resume", "runtime-request-proof", "finish-committed-resume",
            "check-image", "observe",
        ):
            with self.subTest(operation=operation):
                result = self.shell(script, operation)
                self.assertEqual(0, result.returncode, result.stderr)
                arguments = result.stdout.splitlines()
                self.assertEqual(arguments[:7], [
                    "timeout", "1s", "python3", "/fixture/provider.py", operation,
                    "--deploy-lock-fd", "9",
                ])
                self.assertEqual(arguments[7:], [
                    "--execution-attempt", "a" * 32, "--execution-grant", "b" * 32,
                    "--deadline-ns", "123456789",
                ] if operation in {
                    "live-resume", "runtime-request-proof", "finish-committed-resume",
                } else [])

    def test_state_mutations_carry_the_live_grant_and_cleanup_cannot_launch_writers(self):
        script = self.function("supervisor_timeout") + r"""
provider_helper=/fixture/provider.py
timepad_helper=/fixture/state.py
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TIMEPAD_WORKER_MODE=$1
supervisor_client() {
  case "$1" in
    grant)
      echo "grant:$2" >&2
      echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","endNs":123456789}' ;;
    complete) ;;
    *) exit 90 ;;
  esac
}
command() {
  if [ "$1" = timeout ] && [ "$2" = 3s ]; then echo 1s
  else printf '%s\n' "$@"; fi
}
shift
supervisor_timeout 30s "$@"
"""
        for role, argv, wait_name, permitted in (
            ("controller-worker", ["python3", "/fixture/state.py", "prepare"], "state-publish", True),
            ("controller-worker", ["python3", "/fixture/state.py", "adopt-recovery"], "state-publish", True),
            ("controller-worker", ["python3", "/fixture/state.py", "read-state"], "state-publish", True),
            ("fail-closed-worker", ["python3", "/fixture/state.py", "retain-unresolved"], "cleanup-publish", True),
            ("fail-closed-worker", ["python3", "/fixture/state.py", "read-state"], "cleanup-stop", True),
            ("fail-closed-worker", ["python3", "/fixture/state.py", "advance"], "cleanup-publish", True),
            ("fail-closed-worker", ["python3", "/fixture/provider.py", "runtime-request-proof"], "cleanup-stop", True),
            ("fail-closed-worker", ["docker", "inspect", "fixture-container"], "cleanup-stop", True),
            ("fail-closed-worker", ["docker", "update", "--restart=no", "fixture-container"], "cleanup-stop", True),
            ("fail-closed-worker", ["docker", "start", "fixture-container"], None, False),
            ("fail-closed-worker", ["docker", "update", "--restart=unless-stopped", "fixture-container"], None, False),
            ("fail-closed-worker", ["python3", "/fixture/state.py", "bootstrap"], None, False),
            ("fail-closed-worker", ["python3", "/fixture/provider.py", "finish"], None, False),
        ):
            with self.subTest(role=role, argv=argv):
                result = self.shell(script, role, *argv)
                self.assertEqual(0 if permitted else 1, result.returncode, result.stderr)
                self.assertEqual("grant:" + wait_name if permitted else "", result.stderr.strip())
                expected = ["timeout", "1s", *argv] if permitted else []
                if permitted and argv[:2] == ["python3", "/fixture/state.py"] and argv[2] in {
                    "prepare", "adopt-recovery", "retain-unresolved", "advance",
                }:
                    expected += [
                        "--execution-attempt", "a" * 32, "--execution-grant", "b" * 32,
                        "--deadline-ns", "123456789",
                    ]
                if permitted and argv[:3] == ["python3", "/fixture/provider.py", "runtime-request-proof"]:
                    expected += [
                        "--execution-attempt", "a" * 32, "--execution-grant", "b" * 32,
                        "--deadline-ns", "123456789",
                    ]
                self.assertEqual(expected, result.stdout.splitlines())

    def test_stop_only_worker_matches_exact_incident_and_never_claims_quiescence(self):
        current = {
            "executionAttempt": "a" * 32, "phase": "VERIFYING", "containerId": "b" * 64,
            "configHash": "c" * 64, "target": {"tuple": {"platformImageId": "d" * 64}},
        }
        inspection = [{
            "Id": "b" * 64, "Image": "sha256:" + "d" * 64,
            "Config": {"Labels": {
                "com.docker.compose.project": "meet-production",
                "com.docker.compose.service": "backend", "com.docker.compose.config-hash": "c" * 64,
            }},
            "State": {"Running": False}, "HostConfig": {"RestartPolicy": {"Name": "no"}},
        }]
        cases = [
            ("exact", current, inspection, ["inspect", "update", "stop", "inspect"]),
            ("foreign-attempt", {**current, "executionAttempt": "e" * 32}, inspection, []),
            ("prepared", {**current, "phase": "PREPARED"}, inspection, []),
            ("terminal", {**current, "phase": "COMMITTED"}, inspection, []),
            ("unbound", {**current, "containerId": None}, inspection, []),
            ("wrong-image", current, [{**inspection[0], "Image": "sha256:" + "e" * 64}], ["inspect"]),
            ("wrong-id", current, [{**inspection[0], "Id": "e" * 64}], ["inspect"]),
            ("extra-container", current, inspection * 2, ["inspect"]),
            ("update-failure", current, inspection, ["inspect", "update"]),
            ("stop-failure", current, inspection, ["inspect", "update", "stop"]),
            ("still-running", current, [{**inspection[0], "State": {"Running": True}}],
             ["inspect", "update", "stop", "inspect"]),
        ]
        script = self.function("fail_closed_owned_backend") + r"""
state_root=$1
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
timepad_helper=/fixture/state.py
current_json=$2
inspection_json=$3
fault=$4
timeout() { shift; "$@"; }
python3() { printf '{"current":%s}\n' "$current_json"; }
docker() {
  echo "$1" >>"$state_root/trace"
  case "$1" in
    inspect) printf '%s\n' "$inspection_json" ;;
    update)
      [ "$2" = --restart=no ] && [ "$3" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
      [ "$fault" != update-failure ] ;;
    stop)
      [ "$2:$3" = --time:10 ] && [ "$4" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]
      [ "$fault" != stop-failure ] ;;
    *) return 90 ;;
  esac
}
fail_closed_owned_backend
"""
        for fault, state_value, runtime, events in cases:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as directory:
                result = self.shell(script, Path(directory).as_posix(),
                                    json.dumps(state_value), json.dumps(runtime), fault)
                self.assertEqual(1, result.returncode, result.stderr)
                trace = Path(directory, "trace")
                self.assertEqual(events, trace.read_text().splitlines() if trace.exists() else [])
                self.assertEqual("", result.stdout)

    def test_stop_only_worker_attempts_unresolved_publication_even_when_stop_refuses(self):
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        branch = source[source.index('  if [ "$TIMEPAD_WORKER_MODE" = fail-closed-worker ]; then'):]
        branch = branch[:branch.index("\n  fi") + 5]
        script = r"""
TIMEPAD_WORKER_MODE=fail-closed-worker
fail_closed_retry_refusal() { return 1; }
fail_closed_owned_backend() { echo stop >&2; return 1; }
fail_closed_publish_unresolved() { echo retain-unresolved >&2; return 1; }
fail() { echo "$1" >&2; exit 91; }
""" + branch
        result = self.shell(script)
        self.assertEqual(91, result.returncode)
        self.assertEqual(["stop", "retain-unresolved", "QUIESCENCE_UNCONFIRMED"], result.stderr.splitlines())
        self.assertEqual("", result.stdout)

    def test_bootstrap_arm_and_normal_deploy_gate_precede_writers(self):
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text(encoding="utf-8")
        bootstrap = source[source.index('if [ "$operation" = bootstrap-guard ]; then'):]
        self.assertLess(bootstrap.index("recovery_budget_arm"), bootstrap.index("bootstrap_result="))
        self.assertIn('supervisor_complete "$(jq -er', bootstrap)
        normal_gate = source.index('fail "EXECUTION_CONTROLLER_LIFECYCLE_UNAVAILABLE"\n')
        self.assertLess(normal_gate, source.index('"$provider_helper" state-publish'))
        recovery = source[source.index("  # Intent without a daemon receipt"):]
        ordering = [
            "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED",
            "recovery_live_result=$(recovery_live_proof)",
            'if [ "$(jq -er \'.runtimeRequest.lifecycle\'',
            "recovery_admission_only=false",
            "supervisor_client arm",
            "supervisor_publish_lease",
            '"$timepad_helper" adopt-recovery',
        ]
        positions = [recovery.index(marker) for marker in ordering]
        self.assertEqual(sorted(positions), positions)
        self.assertIn('.runtimeRequest.lifecycle == "completed" or '
                      '.runtimeRequest.lifecycle == "acknowledged"', recovery)
        private_dispatch = source[source.index('    case "$worker_mode" in\n',
                                              source.index("if [[")):]
        self.assertIn("controller-worker|rollback-worker|fail-closed-worker) ;;", private_dispatch)
        self.assertIn('*) fail "PRIVATE_WORKER_MODE_UNAVAILABLE"', private_dispatch)

    def test_recovery_registration_checks_dispatch_before_publication_and_acks_once(self):
        # Registration deliberately captures helper stderr for sanitized
        # failure classification. Keep fixture tracing out of that payload.
        script = "exec 3>&2\n" + self.function("supervisor_register_recovery") + r"""
state_root=/fixture/root
timepad_helper=/fixture/state.py
timepad_contract=/fixture/contract.json
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
recovery_run_key=original-run
recovery_incident=DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD
recovery_epoch=7
recovery_binding_digest=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
image=repo@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
revision=cccccccccccccccccccccccccccccccccccccccc
version=1.4.1
fault=$1
supervisor_client() {
  echo "$*" >&2
  case "$1" in
    grant) echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","endNs":123456789}' ;;
    complete|lease-ack) [ "$1" != "$fault" ] ;;
    *) return 90 ;;
  esac
}
command() {
  echo "$*" >&3
  if [ "${5:-}" = read-state ]; then
    echo '{"current":{"executionAttempt":null,"phase":"CUTOVER_POSSIBLE"}}'
    return 0
  fi
  [ "$fault" != publication ] || return 91
  echo '{"attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":0,"digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
}
supervisor_register_recovery
"""
        for fault in ("none", "publication", "complete", "lease-ack"):
            with self.subTest(fault=fault):
                result = self.shell(script, fault)
                self.assertEqual(fault == "none", result.returncode == 0, result.stderr)
                events = result.stderr.splitlines()
                self.assertEqual(events[0], "grant recovery-registration 30")
                self.assertIn("read-state --root /fixture/root", events[1])
                self.assertIn("register-recovery --root /fixture/root", events[2])
                for value in (
                    "--run-id original-run", "--incident-id " + "d" * 32, "--epoch 7",
                    "--binding-digest " + "e" * 64, "--repository-digest " + "f" * 64,
                    "--revision " + "c" * 40, "--version 1.4.1",
                    "--execution-attempt " + "a" * 32, "--execution-grant " + "b" * 32,
                    "--deadline-ns 123456789",
                ):
                    self.assertIn(value, events[2])
                self.assertEqual(len(events), {"none": 5, "publication": 3, "complete": 4,
                                               "lease-ack": 5}[fault])

    def test_read_only_recovery_and_rollback_waits_cannot_launch_mutation(self):
        script = self.function("supervisor_timeout") + r"""
provider_helper=/fixture/provider.py
timepad_helper=/fixture/state.py
provider_pointer=/fixture/root/.provider-transaction.current
recovery_run_key=original-run
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
TIMEPAD_WORKER_MODE=$1
recovery_admission_only=$2
supervisor_client() {
  case "$1" in
    grant)
      echo "grant:$2" >&2
      echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","endNs":123456789}' ;;
    complete) ;;
    *) return 90 ;;
  esac
}
command() {
  if [ "$1:$2" = timeout:3s ]; then echo 1s
  else printf '%s\n' "$@"; fi
}
shift 2
supervisor_timeout 30s "$@"
"""
        for role, admission, argv, name in (
            ("controller-worker", "true", ["docker", "image", "inspect", "image"], "recovery-admission"),
            ("controller-worker", "true", ["python3", "/fixture/state.py", "read-state"], "recovery-admission"),
            ("controller-worker", "true", ["python3", "/fixture/provider.py", "check-image"], "recovery-admission"),
            ("controller-worker", "true", ["python3", "/fixture/provider.py", "runtime-request-proof"], "recovery-admission"),
            ("controller-worker", "true", [
                "jq", "-er", "--arg", "run", "original-run", ".phase",
                "/fixture/root/.provider-transaction.current",
            ], "recovery-admission"),
            ("controller-worker", "true", [
                "jq", "-er", "--arg", "run", "foreign-run", ".phase",
                "/fixture/root/.provider-transaction.current",
            ], None),
            ("controller-worker", "true", [
                "jq", "-er", "--arg", "run", "original-run", ".phase", "/foreign/pointer",
            ], None),
            ("controller-worker", "true", ["docker", "start", "container"], None),
            ("controller-worker", "true", ["python3", "/fixture/provider.py", "prepare"], None),
            ("controller-worker", "true", ["python3", "/fixture/state.py", "advance"], None),
            ("controller-worker", "true", ["python3", "/fixture/state.py", "adopt-recovery"], None),
            ("controller-worker", "true", ["bash", "arbitrary"], None),
            ("rollback-worker", "false", ["python3", "/fixture/state.py", "rollback-admission"], "rollback-admission"),
            ("rollback-worker", "false", ["python3", "/fixture/state.py", "claim-rollback"], None),
            ("rollback-worker", "false", ["docker", "start", "predecessor"], None),
            ("rollback-worker", "false", ["python3", "/fixture/provider.py", "finish"], None),
        ):
            with self.subTest(role=role, argv=argv):
                result = self.shell(script, role, admission, *argv)
                self.assertEqual(0 if name else 1, result.returncode, result.stderr)
                self.assertEqual("grant:" + name if name else "", result.stderr.strip())
                if not name:
                    self.assertEqual("", result.stdout)
                if name == "rollback-admission":
                    self.assertEqual(result.stdout.splitlines()[-6:], [
                        "--execution-attempt", "a" * 32, "--execution-grant", "b" * 32,
                        "--deadline-ns", "123456789",
                    ])

    def test_rollback_state_proof_never_releases_mutation_without_daemon_proof(self):
        script = self.function("rollback_worker_admission") + "\n" + self.function("rollback_worker_runtime_gate") + r"""
timepad_helper=/fixture/state.py
state_root=/fixture/root
root=/fixture/deployment
base_compose=/fixture/compose.yml
TIMEPAD_ATTEMPT=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fault=$1
timeout() {
  echo "$*" >&2
  [ "$fault" != state ] || return 1
  if [ "$4" = read-state ]; then
    echo '{"current":{"predecessorContainerId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}'
  elif [ "$fault" = proof ]; then
    echo '{"executionAttempt":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","predecessorContainerId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","proofDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
  else
    echo '{"result":"state-admitted"}'
  fi
}
recovery_backend_inventory() { echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
docker_container_inspect() { echo '[]'; }
fail() { echo "$1" >&2; exit 91; }
supervisor_client() { echo unexpected-admit-rollback; return 92; }
rollback_worker_admission
rollback_worker_runtime_gate
"""
        for fault in ("none", "state", "proof"):
            result = self.shell(script, fault)
            self.assertEqual(91, result.returncode, result.stderr)
            self.assertEqual("", result.stdout)
            expected = ["15s python3 /fixture/state.py read-state --root /fixture/root --deploy-lock-fd 9"]
            if fault != "state":
                expected.append("15s python3 /fixture/state.py rollback-admission --root /fixture/root --deploy-lock-fd 9")
            expected.append("ROLLBACK_RUNTIME_QUIESCENCE_REQUIRED" if fault == "proof" else "ROLLBACK_NOT_ADMITTED")
            self.assertEqual(expected, result.stderr.splitlines())

    def test_lease_transport_newline_is_not_published_as_durable_bytes(self):
        script = self.function("supervisor_publish_lease") + r"""
state_root=$1
timepad_helper=/fixture/state.py
TIMEPAD_ATTEMPT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
supervisor_enabled=true
snapshot_bytes='{"attempt":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","revision":0}'
supervisor_client() {
  case "$1" in
    grant) echo '{"grantId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' ;;
    lease) printf '%s\n' "$snapshot_bytes" ;;
    complete|lease-ack) echo "$*" >&2 ;;
    *) return 90 ;;
  esac
}
command() {
  [ "$1" = timeout ] && [ "$5" = publish-lease ] || return 91
  cmp -s "$9" <(printf '%s' "$snapshot_bytes") || return 92
  echo '{"revision":0,"digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
}
supervisor_publish_lease
"""
        with tempfile.TemporaryDirectory() as directory:
            result = self.shell(script, Path(directory).as_posix())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr.splitlines(), [
                "complete " + "b" * 32, "lease-ack 0 " + "c" * 64,
            ])
            self.assertEqual(list(Path(directory).iterdir()), [])


def fixture_publish(client, directory):
    snapshot = client.request("lease")
    state._execution_lease(snapshot)
    grant = client.request("grant", name="lease-publish", localNs=10 * NS)
    acknowledgment = state.publish_execution_lease(directory, snapshot, deploy_lock_fd=9)
    client.request("complete", grantId=grant["grantId"])
    client.request(
        "lease-ack", revision=acknowledgment["revision"], digest=acknowledgment["digest"],
    )


def fixture_terminal(client, directory, status):
    client.request("prepare-terminal")
    fixture_publish(client, directory)
    client.request("terminal", status=status)


class FixtureSupervisor(supervisor.Supervisor):
    """Only this test subclass replaces the fixed worker with Python fixtures."""

    def __init__(self, *args, behavior, **kwargs):
        super().__init__(*args, **kwargs)
        self.behavior = behavior

    def spawn(self):
        if self.worker is not None:
            self.worker.close()
        parent, child = supervisor.socket_pair()
        mode = self.attempt.role
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                control = os.dup(child.fileno())
                if control == 9:
                    control = os.dup(control)
                os.dup2(self.lock_fd, 9, inheritable=True)
                os.set_inheritable(control, True)
                supervisor._close_except({control, 9})
                os.environ.update({
                    "TIMEPAD_CONTROL_FD": str(control), "TIMEPAD_ATTEMPT": self.attempt.nonce,
                    "TIMEPAD_SUPERVISOR": supervisor.encode(self.identity).decode(),
                    "TIMEPAD_WORKER_MODE": mode,
                })
                client = supervisor.WorkerClient(self.root)
                client.request("hello")
                self.behavior(client, self.root, mode)
                os._exit(0)
            except BaseException:
                os._exit(2)
        child.close()
        self.worker, self.worker_pid = parent, pid
        self.worker_identity = supervisor.lease_identity(supervisor.process_identity(pid))
        self.worker_identities.append({"mode": mode, **self.worker_identity})
        self.worker_hello = False
        self.worker_handshake_end = time.monotonic_ns() + self.attempt.timing.handshake_ns
        self.attempt.idle_end = self.worker_handshake_end
        self._record_lease()


class LinuxSupervisorTests(unittest.TestCase):
    def test_create_registration_readback_child_preserves_proof_or_refuses_partial_handoff(self):
        for fault, replacement in (
            ("none", False), ("receipt", False), ("digest", False), ("erased", False), ("aborted", False),
            ("none", True), ("receipt", True),
        ):
            with self.subTest(fault=fault, replacement=replacement), tempfile.TemporaryDirectory() as directory:
                os.chmod(directory, 0o700)
                authority = {
                    "rootId": "test-root", "bootstrapId": "bootstrap-1", "initialRuntime": "a" * 64,
                    "initialConfig": "b" * 64, "initialSchema": "c" * 64,
                    "initialStartupInventory": "d" * 64, "schemaHistoryProvenance": True,
                }
                observed = {
                    "rootId": "test-root", "runtime": "a" * 64, "config": "b" * 64,
                    "schema": "c" * 64, "startupInventory": "d" * 64, "schemaHistoryProvenance": True,
                }
                state.bootstrap_guard(directory, authority=authority, observed=observed)
                origin, _ = state.read_guard(directory)
                approved, current, previous, receipt = recovery_create_fixture(
                    origin["originDigest"], {
                        "pid": 123, "startTicks": 42, "bootId": supervisor.boot_id(),
                    }, replacement=replacement,
                )
                run = Path(directory, current["ownedRun"])
                run.mkdir(mode=0o700)
                receipt_path = run / (
                    "timepad-replacement-completion.json" if replacement else "timepad-create-completion.json"
                )
                receipt_path.write_bytes(receipt)
                receipt_path.chmod(0o600)
                lease_path = Path(directory, state.EXECUTION_LEASE_NAME)
                lease_path.write_bytes(state._canonical(previous))
                lease_path.chmod(0o600)
                Path(directory, state.GUARD_DIR, "current.json").write_bytes(state._canonical(current))
                target = current["target"]
                authorization = {
                    "schema": state.RECOVERY_AUTH_SCHEMA, "rootId": "test-root",
                    "originDigest": origin["originDigest"], "originalOperation": "deploy",
                    "runId": current["runId"], "operationEpoch": current["operationEpoch"],
                    "incidentId": current["incidentId"], "evidenceDigest": current["evidenceDigest"],
                    "targetId": target["id"], "revision": target["tuple"]["revision"],
                    "version": target["tuple"]["version"],
                    "repositoryDigest": target["tuple"]["repositoryDigest"],
                    "platformImageId": target["tuple"]["platformImageId"], "action": "retry-exact-candidate",
                }
                authorization_path = Path(directory, "timepad-recovery-authorization.json")
                authorization_path.write_bytes(state._canonical(authorization))
                authorization_path.chmod(0o600)
                selectors = {key: authorization[key] for key in (
                    "runId", "incidentId", "operationEpoch", "evidenceDigest",
                    "repositoryDigest", "revision", "version",
                )}

                def behavior(client, root, mode):
                    if mode != "controller-worker":
                        fixture_publish(client, root)
                        fixture_terminal(client, root, 1)
                        return
                    grant = client.request("grant", name="recovery-registration", localNs=30 * NS)
                    # Only the external provider observation is synthetic. State
                    # authority, prior process exit, receipt, FD9, publication,
                    # readback child, wait status and subsequent revisions are real.
                    def recovery_runtime_proof(*_args, create_completion_recovery=False):
                        if create_completion_recovery is not True:
                            raise AssertionError("registration omitted create-completion proof mode")
                        return current["runtimeRequest"]

                    provider = SimpleNamespace(
                        ProviderError=RuntimeError,
                        _recovery_lease_runtime_proof=recovery_runtime_proof,
                    )
                    with mock.patch.object(
                        state.importlib.util, "spec_from_file_location",
                        return_value=SimpleNamespace(loader=mock.Mock()),
                    ), mock.patch.object(state.importlib.util, "module_from_spec", return_value=provider):
                        acknowledgment = state.register_recovery(
                            root, contract=approved, selectors=selectors, deploy_lock_fd=9,
                            execution_grant=state.ExecutionGrant(
                                grant["attempt"], grant["grantId"], grant["endNs"],
                            ), runtime_evidence=b"{}",
                        )
                    if fault == "receipt":
                        receipt_path.write_bytes(b"{}")
                    elif fault == "digest":
                        acknowledgment["digest"] = "0" * 64
                    elif fault == "erased":
                        snapshot = state._read_execution_lease_locked(root)
                        snapshot["createCompletion"] = None
                        raw = state._canonical(snapshot)
                        lease_path.write_bytes(raw)
                        acknowledgment["digest"] = hashlib.sha256(raw).hexdigest()
                    if fault != "aborted":
                        client.request("complete", grantId=grant["grantId"])
                    client.request(
                        "lease-ack", revision=acknowledgment["revision"], digest=acknowledgment["digest"],
                    )
                    if client.request("lease")["createCompletion"] != previous["createCompletion"]:
                        os._exit(6)
                    client.request("arm")
                    fixture_publish(client, root)
                    Path(root, "handoff-checked").write_bytes(b"checked")
                    client.request("cancel", reason="EXIT", status=1)
                    signal.pause()

                result, _ = self.run_fixture(
                    behavior, directory=directory, operation="forward-recover",
                    timing=supervisor.Timing(), timeout=25, expect_keeper=fault != "none",
                )
                self.assertEqual(1, result["status"])
                self.assertEqual("RECOVERY_REQUIRED" if fault == "none" else "QUIESCENCE_UNCONFIRMED", result["reason"])
                self.assertEqual(fault == "none", Path(directory, "handoff-checked").exists())
                durable = state._read_execution_lease_locked(directory)
                actual = state.read_guard(directory)[1]
                self.assertEqual(current["runtimeRequest"], actual["runtimeRequest"])
                self.assertEqual(current["phase"], actual["phase"])
                self.assertEqual(current["containerId"], actual["containerId"])
                for key in ("commitWitnessDigest", "providerFinalizationDigest", "configHash", "commitSubstep"):
                    self.assertEqual(current[key], actual[key])
                if fault == "none":
                    self.assertEqual(previous["createCompletion"], durable["createCompletion"])
                    self.assertEqual("drained", durable["lifecycle"])
                    self.assertIsNone(durable["worker"])
                    self.assertGreaterEqual(durable["revision"], 6)

    def test_failed_cleanup_terminal_publishes_childless_lease_before_fixed_refusal(self):
        def behavior(client, directory, mode):
            fixture_publish(client, directory)
            if mode == "controller-worker":
                client.request("arm")
                fixture_publish(client, directory)
                client.request("cancel", reason="RECOVERY_RETRY_RUNTIME_FAILED", status=1)
                return
            self.assertEqual("fail-closed-worker", mode)
            client.request("prepare-terminal")
            fixture_publish(client, directory)
            client.request("terminal", status=1)

        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_fixture(behavior, directory=directory, operation="forward-recover")
            self.assertEqual(1, result["status"])
            self.assertEqual("RECOVERY_REQUIRED", result["reason"])
            self.assertEqual("RECOVERY_RETRY_RUNTIME_FAILED", result["outcome"])
            lease = state._read_execution_lease_locked(directory)
            self.assertEqual("drained", lease["lifecycle"])
            self.assertIsNone(lease["worker"])
            self.assertEqual("RECOVERY_RETRY_RUNTIME_FAILED", lease["firstFailure"])
            self.assertEqual(1, lease["firstStatus"])
            self.assertEqual(["controller-worker", "fail-closed-worker"], [
                worker["mode"] for worker in lease["workers"]
            ])

    def run_fixture(
        self, behavior, *, operation="deploy", timing=None, timeout=15, disconnect=False,
        directory=None, observe=None, expect_keeper=False, expect_childless_keeper=False,
    ):
        with tempfile.TemporaryDirectory() if directory is None else nullcontext(directory) as directory:
            os.chmod(directory, 0o700)
            relay, child = supervisor.socket_pair()
            pid = os.fork()
            if pid == 0:
                try:
                    relay.close()
                    os.setsid()
                    supervisor._close_except({child.fileno()})
                    instance = FixtureSupervisor(
                        directory, operation, [], child, behavior=behavior,
                        timing=timing or supervisor.Timing(
                            work_ns=4 * NS, hard_ns=8 * NS, handshake_ns=NS,
                            idle_ns=2 * NS, drain_ns=NS, term_ns=NS // 4,
                            stop_ns=NS, publish_ns=NS,
                        ),
                    )
                    os._exit(instance.run())
                except BaseException:
                    os._exit(3)
            child.close()
            end = time.monotonic() + timeout
            result = None
            frames = []
            try:
                supervisor._wait_readable(relay, time.monotonic_ns() + 2 * NS)
                hello, _ = supervisor.receive_frame(relay)
                self.assertEqual(hello["kind"], "hello")
                self.assertEqual(hello["supervisor"]["pid"], pid)
                supervisor.send_frame(relay, {"kind": "ready", "attempt": hello["attempt"]})
                if disconnect:
                    relay.close()
                while time.monotonic() < end:
                    if observe is not None:
                        observe(directory, frames)
                    reaped, status = os.waitpid(pid, os.WNOHANG)
                    if reaped:
                        if not disconnect:
                            while True:
                                try:
                                    frame, _ = supervisor.receive_frame(relay)
                                    frames.append(frame)
                                    if frame.get("kind") == "result":
                                        result = frame
                                except (BlockingIOError, supervisor.SupervisorError):
                                    break
                        self.assertNotEqual(os.waitstatus_to_exitcode(status), 3)
                        return result, frames
                    if not disconnect:
                        try:
                            frame, _ = supervisor.receive_frame(relay)
                            frames.append(frame)
                            if frame.get("kind") == "result":
                                result = frame
                                if expect_keeper:
                                    self.assertEqual("QUIESCENCE_UNCONFIRMED", result["reason"])
                                    self.assertEqual((0, 0), os.waitpid(pid, os.WNOHANG))
                                    identity = supervisor.process_identity(pid)
                                    self.assertIsNotNone(identity)
                                    self.assertEqual(
                                        hello["supervisor"], supervisor.lease_identity(identity),
                                    )
                                    with self.assertRaisesRegex(
                                        state.GuardError, "DEPLOY_LOCK_BUSY",
                                    ), state.deploy_lock(directory):
                                        pass
                                    if expect_childless_keeper:
                                        children = Path(
                                            f"/proc/{pid}/task/{pid}/children",
                                        ).read_text().split()
                                        self.assertEqual([], children)
                                    return result, frames
                        except (BlockingIOError, supervisor.SupervisorError):
                            pass
                    time.sleep(0.01)
                self.fail("bounded supervisor fixture exceeded its deadline")
            finally:
                relay.close()
                try:
                    reaped, _ = os.waitpid(pid, os.WNOHANG)
                    if not reaped:
                        # Fixture-only final disposal, never a production lock
                        # release assertion. The isolated PID namespace remains
                        # the final safety net if this test itself fails.
                        os.killpg(pid, signal.SIGKILL)
                        os.waitpid(pid, 0)
                except (ChildProcessError, ProcessLookupError):
                    pass

    def test_terminal_success_needs_real_worker_protocol_lease_and_echild(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            grant = client.request("grant", name="runtime", localNs=NS)
            client.request("complete", grantId=grant["grantId"])
            fixture_terminal(client, directory, 0)

        result, _ = self.run_fixture(behavior)
        self.assertEqual((result["status"], result["reason"]), (0, "COMPLETED"))

    def test_live_worker_cannot_fabricate_drained_or_foreign_lease_snapshots(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            actual = client.request("lease")
            path = Path(directory, state.EXECUTION_LEASE_NAME)
            before = path.read_bytes()
            for field, value in (
                ("attempt", "f" * 32), ("revision", actual["revision"] + 1),
                ("lifecycle", "drained"), ("worker", None),
                ("workerMode", "rollback-worker"),
            ):
                try:
                    state.publish_execution_lease(
                        directory, {**actual, field: value}, deploy_lock_fd=9,
                    )
                except state.GuardError:
                    if path.read_bytes() != before:
                        os._exit(6)
                else:
                    os._exit(7)
            Path(directory, "publisher-refusals").write_bytes(b"5")
            fixture_terminal(client, directory, 0)

        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_fixture(behavior, directory=directory)
            self.assertEqual((result["status"], result["reason"]), (0, "COMPLETED"))
            self.assertEqual(Path(directory, "publisher-refusals").read_bytes(), b"5")
            self.assertIsNone(state._read_execution_lease_locked(directory)["worker"])

    def test_cancellation_during_worker_lease_fsync_revokes_publication_before_rename(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                fixture_publish(client, directory)
                os._exit(1)  # No runtime-quiescence proof; preserve refusal.
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            snapshot = client.request("lease")
            before = Path(directory, state.EXECUTION_LEASE_NAME).read_bytes()
            client.request("grant", name="lease-publish", localNs=NS)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            original_fsync = state.os.fsync

            def cancel_at_fsync(fd):
                client.request("cancel", reason="EXIT", status=1)
                original_fsync(fd)

            try:
                with mock.patch.object(state.os, "fsync", side_effect=cancel_at_fsync):
                    state.publish_execution_lease(directory, snapshot, deploy_lock_fd=9)
            except state.GuardError:
                if Path(directory, state.EXECUTION_LEASE_NAME).read_bytes() != before:
                    os._exit(6)
                if any(path.name.startswith(".tmp-") for path in Path(directory).iterdir()):
                    os._exit(7)
                Path(directory, "revoked-before-rename").write_bytes(b"checked")
                os._exit(0)
            os._exit(8)

        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_fixture(behavior, directory=directory)
            self.assertEqual((result["status"], result["reason"]), (1, "QUIESCENCE_UNCONFIRMED"))
            self.assertEqual(Path(directory, "revoked-before-rename").read_bytes(), b"checked")
            lease = state._read_execution_lease_locked(directory)
            self.assertEqual("EXIT", lease["firstFailure"])
            self.assertIsNotNone(lease["worker"])
            self.assertNotEqual("drained", lease["lifecycle"])

    def test_state_helper_bootstrap_requires_actual_live_grant_and_rejects_completed_grant(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1",
                "initialRuntime": "a" * 64, "initialConfig": "b" * 64,
                "initialSchema": "c" * 64, "initialStartupInventory": "d" * 64,
                "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": "a" * 64, "config": "b" * 64,
                "schema": "c" * 64, "startupInventory": "d" * 64,
                "schemaHistoryProvenance": True,
            }
            try:
                state.bootstrap_guard(directory, authority=authority, observed=observed, deploy_lock_fd=9)
            except state.GuardError:
                if Path(directory, "timepad-guard").exists():
                    os._exit(6)
            else:
                os._exit(7)
            granted = client.request("grant", name="state-publish", localNs=10 * NS)
            capability = state.ExecutionGrant(granted["attempt"], granted["grantId"], granted["endNs"])
            result = state.bootstrap_guard(
                directory, authority=authority, observed=observed,
                deploy_lock_fd=9, execution_grant=capability,
            )
            if result["outcome"] != "bootstrapped":
                os._exit(8)
            original = state.read_guard(directory, deploy_lock_fd=9)
            client.request("complete", grantId=granted["grantId"])
            Path(directory, "grant-checks-passed").write_bytes(
                Path(directory, "timepad-guard/current.json").read_bytes(),
            )
            try:
                state.bootstrap_guard(
                    directory, authority=authority, observed=observed,
                    deploy_lock_fd=9, execution_grant=capability,
                )
            except state.GuardError as error:
                if error.reason != "EXECUTION_GRANT_REVOKED":
                    os._exit(9)
                if state.read_guard(directory, deploy_lock_fd=9) != original:
                    os._exit(10)
            else:
                os._exit(11)
            # Rejection revokes the controller protocol; it cannot finalize or
            # obtain more work, and its durable lease remains unresolved.
            os._exit(0)

        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_fixture(
                behavior, directory=directory, timing=supervisor.Timing(
                    work_ns=12 * NS, hard_ns=18 * NS, handshake_ns=NS,
                    idle_ns=2 * NS, drain_ns=NS, term_ns=NS // 4,
                    stop_ns=NS, publish_ns=NS,
                ), timeout=25,
            )
            self.assertNotEqual(result["status"], 0)
            self.assertEqual("QUIESCENCE_UNCONFIRMED", result["reason"])
            self.assertEqual(
                Path(directory, "grant-checks-passed").read_bytes(),
                Path(directory, "timepad-guard/current.json").read_bytes(),
            )
            lease = state._read_execution_lease_locked(directory)
            self.assertEqual("PROTOCOL_INVALID", lease["firstFailure"])

    def test_completed_attempt_can_replay_only_after_final_childless_publication(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            client.request("prepare-terminal")
            fixture_publish(client, directory)
            client.request("terminal", status=0, outcome="already-initialized")

        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o700)
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1",
                "initialRuntime": "a" * 64, "initialConfig": "b" * 64,
                "initialSchema": "c" * 64, "initialStartupInventory": "d" * 64,
                "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": "a" * 64, "config": "b" * 64,
                "schema": "c" * 64, "startupInventory": "d" * 64,
                "schemaHistoryProvenance": True,
            }
            state.bootstrap_guard(directory, authority=authority, observed=observed)
            original = state.read_guard(directory)
            attempts = []
            for _ in range(2):
                result, _ = self.run_fixture(behavior, directory=directory)
                self.assertEqual((result["status"], result["reason"], result["outcome"]),
                                 (0, "COMPLETED", "already-initialized"))
                lease = state._read_execution_lease_locked(directory)
                self.assertEqual((lease["revision"], lease["lifecycle"], lease["worker"]),
                                 (3, "drained", None))
                self.assertTrue(all(state._execution_process_exited(identity) for identity in (
                    lease["supervisor"], *lease["workers"],
                )))
                attempts.append(lease["attempt"])
                self.assertEqual(state.read_guard(directory), original)
            self.assertNotEqual(attempts[0], attempts[1])

    def test_unrecorded_descendant_closing_fd9_blocks_completion_and_competing_attempt(self):
        import fcntl
        checked = []

        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)
            fixture_publish(client, directory)
            client.request("arm")
            fixture_publish(client, directory)
            descendant = os.fork()
            if descendant == 0:
                os.close(9)
                os.setsid()
                Path(directory, "descendant-ready").write_bytes(b"")
                gate = os.open(Path(directory, "release"), os.O_RDONLY)
                supervisor._close_except({gate})
                os.read(gate, 1)
                os._exit(0)
            fixture_terminal(client, directory, 0)

        def observe(directory, frames):
            if checked or not Path(directory, "descendant-ready").exists():
                return
            lease = state._read_execution_lease_locked(directory)
            if lease is None or lease["lifecycle"] != "drained" or \
                    not all(state._execution_process_exited(worker) for worker in lease["workers"]):
                return
            self.assertIsNotNone(lease["worker"], "live unrecorded descendant got a childless marker")
            self.assertFalse(any(frame.get("kind") == "result" for frame in frames))
            fd = os.open(Path(directory, ".deploy.lock"), os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with self.assertRaisesRegex(state.GuardError, "DEPLOY_LOCK_BUSY"):
                    with state.deploy_lock(directory):
                        self.fail("competing attempt acquired the keeper lock")
            finally:
                os.close(fd)
            gate = os.open(Path(directory, "release"), os.O_WRONLY | os.O_NONBLOCK)
            try:
                os.write(gate, b"x")
            finally:
                os.close(gate)
            checked.append(True)

        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o700)
            os.mkfifo(Path(directory, "release"), 0o600)
            result, _ = self.run_fixture(behavior, directory=directory, observe=observe)
            self.assertEqual(checked, [True])
            self.assertEqual((result["status"], result["reason"]), (0, "COMPLETED"))
            lease = state._read_execution_lease_locked(directory)
            self.assertIsNone(lease["worker"])

    def test_recovery_registration_arm_and_terminal_use_actual_durable_state(self):
        def behavior(client, directory, mode):
            if mode != "controller-worker":
                os._exit(5)

            def publish(expected_phase):
                snapshot = client.request("lease")
                if snapshot["lifecycle"] != expected_phase:
                    os._exit(6)
                grant = client.request("grant", name="lease-publish", localNs=NS)
                acknowledgment = state.publish_execution_lease(
                    directory, snapshot, deploy_lock_fd=9,
                )
                client.request("complete", grantId=grant["grantId"])
                client.request(
                    "lease-ack", revision=acknowledgment["revision"],
                    digest=acknowledgment["digest"],
                )
                return snapshot

            registered = publish("registered")
            client.request("arm")
            armed = publish("armed")
            for key in ("t0Ns", "workEndNs", "hardEndNs"):
                if registered[key] != armed[key]:
                    os._exit(7)
            client.request("prepare-terminal")
            publish("drained")
            client.request("terminal", status=0)

        result, _ = self.run_fixture(behavior, operation="forward-recover")
        self.assertEqual((result["status"], result["reason"]), (0, "COMPLETED"))

    def test_authorized_unleased_incident_registers_without_adopting_state_or_runtime(self):
        evidence = {
            "repositoryDigest": "a" * 64, "platformImageId": "b" * 64,
            "revision": "c" * 40, "version": "1.4.1", "migrationInventoryDigest": "d" * 64,
            "migrationResources": ["migration:synthetic"], "beforeSchema": "e" * 64,
            "afterSchema": "f" * 64, "guardEvidence": "1" * 64, "dependencyPolicy": "resolved",
            "dependencyFloor": "2" * 64, "recoveryEvidence": "3" * 64,
            "retryExact": True, "unknownTransitionCovered": True,
        }
        target = {"id": "target", "tuple": evidence, "domain": "advanced"}
        previous = {
            "id": "previous", "tuple": {**evidence, "repositoryDigest": "4" * 64,
                                       "afterSchema": "e" * 64}, "domain": "initial",
        }
        approved = {
            "schema": state.CONTRACT_SCHEMA, "formatVersion": 1, "controller": state.CONTROLLER,
            "active": True, "rootId": "test-root", "initialDomain": [],
            "images": [target, previous], "transitions": [{
                "id": "first-timepad", "targetId": "target", "beforeSchema": "e" * 64,
                "afterSchema": "f" * 64, "compatiblePredecessors": [],
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            authority = {
                "rootId": "test-root", "bootstrapId": "bootstrap-1", "initialRuntime": "a" * 64,
                "initialConfig": "b" * 64, "initialSchema": "c" * 64,
                "initialStartupInventory": "d" * 64, "schemaHistoryProvenance": True,
            }
            observed = {
                "rootId": "test-root", "runtime": "a" * 64, "config": "b" * 64,
                "schema": "c" * 64, "startupInventory": "d" * 64, "schemaHistoryProvenance": True,
            }
            state.bootstrap_guard(directory, authority=authority, observed=observed)
            origin, ready = state.read_guard(directory)
            prepared = state.new_prepared_state(
                ready, operation="deploy", run_id="original-run", incident_id="a" * 32,
                admission=state.admit(
                    approved, root_id="test-root", target_id="target", predecessor_id="previous",
                    transition_id="first-timepad", target_tuple=evidence, predecessor_tuple=previous["tuple"],
                ),
                target=target, predecessor=previous, predecessor_container_id="b" * 64,
                transition_id="first-timepad", owned_run="original-run-final-deploy",
                tooling_digest="5" * 64, prepared_proof_digest="6" * 64,
            )
            current = state.advance_state(prepared, "CUTOVER_POSSIBLE")
            state.publish_current(directory, prepared)
            state.publish_current(directory, current)
            authorization = {
                "schema": state.RECOVERY_AUTH_SCHEMA, "rootId": "test-root",
                "originDigest": origin["originDigest"], "originalOperation": "deploy",
                "runId": current["runId"], "operationEpoch": current["operationEpoch"],
                "incidentId": current["incidentId"], "evidenceDigest": current["evidenceDigest"],
                "targetId": "target", "revision": evidence["revision"], "version": evidence["version"],
                "repositoryDigest": evidence["repositoryDigest"], "platformImageId": evidence["platformImageId"],
                "action": "retry-exact-candidate",
            }
            selectors = {key: authorization[key] for key in (
                "runId", "operationEpoch", "incidentId", "evidenceDigest",
                "revision", "version", "repositoryDigest",
            )}
            path = Path(directory, "timepad-recovery-authorization.json")
            path.write_bytes(json.dumps(authorization).encode())
            path.chmod(0o600)
            before = Path(directory, "timepad-guard/current.json").read_bytes()

            def behavior(client, root, mode):
                if mode != "controller-worker":
                    fixture_publish(client, root)
                    os._exit(1)  # No invented runtime-quiescence proof.
                grant = client.request("grant", name="recovery-registration", localNs=30 * NS)
                registered = state.register_recovery(
                    root, contract=approved, selectors=selectors, deploy_lock_fd=9,
                    execution_grant=state.ExecutionGrant(grant["attempt"], grant["grantId"], grant["endNs"]),
                )
                client.request("complete", grantId=grant["grantId"])
                client.request("lease-ack", revision=registered["revision"], digest=registered["digest"])
                admission = client.request("grant", name="recovery-admission", localNs=NS)
                if state.read_guard(root, deploy_lock_fd=9)[1] != current:
                    os._exit(6)
                client.request("complete", grantId=admission["grantId"])
                Path(root, "registration-checked").write_bytes(b"checked")
                client.request("cancel", reason="EXIT", status=1)
                signal.pause()

            result, _ = self.run_fixture(
                behavior, directory=directory, operation="forward-recover", timing=supervisor.Timing(),
                timeout=25,
            )
            self.assertEqual((result["status"], result["reason"]), (1, "QUIESCENCE_UNCONFIRMED"))
            self.assertEqual(b"checked", Path(directory, "registration-checked").read_bytes())
            self.assertEqual(before, Path(directory, "timepad-guard/current.json").read_bytes())
            lease = state._read_execution_lease_locked(directory)
            self.assertFalse(lease["rollbackIssued"])
            self.assertEqual("EXIT", lease["firstFailure"])
            self.assertEqual(540 * NS, lease["workEndNs"] - lease["t0Ns"])
            self.assertEqual(60 * NS, lease["hardEndNs"] - lease["workEndNs"])
            self.assertNotIn("rollback-worker", [worker["mode"] for worker in lease["workers"]])

    def test_local_expiry_drains_forward_before_single_remaining_work_rollback(self):
        def behavior(client, directory, mode):
            fixture_publish(client, directory)
            if mode == "controller-worker":
                client.request("arm")
                fixture_publish(client, directory)
                client.request("grant", name="docker", localNs=NS // 4)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.pause()
            elif mode == "rollback-worker":
                admission = client.request("grant", name="rollback-admission", localNs=NS)
                # Fixture runtime has no daemon: prior writer is known dead by
                # the supervisor's kernel ECHILD proof before this process fork.
                client.request("complete", grantId=admission["grantId"])
                client.request("admit-rollback")
                fixture_publish(client, directory)
                rollback = client.request("grant", name="rollback-remaining-work", localNs=NS)
                client.request("complete", grantId=rollback["grantId"])
                fixture_terminal(client, directory, 0)
            else:
                fixture_terminal(client, directory, 1)

        result, frames = self.run_fixture(behavior)
        self.assertEqual((result["status"], result["reason"]), (1, "ROLLED_BACK"))
        ends = {frame["hardEndNs"] for frame in frames if frame.get("kind") == "clock" and frame["hardEndNs"]}
        self.assertEqual(len(ends), 1)

    def test_relay_eof_cancels_but_retains_stop_only_recovery(self):
        def behavior(client, directory, mode):
            fixture_publish(client, directory)
            if mode == "controller-worker":
                client.request("arm")
                fixture_publish(client, directory)
                client.request("grant", name="preflight", localNs=NS)
                signal.pause()
            else:
                fixture_terminal(client, directory, 1)

        result, _ = self.run_fixture(behavior, operation="forward-recover", disconnect=True)
        self.assertIsNone(result)

    def test_event_loop_rejects_worker_completion_after_acknowledged_cancellation(self):
        def behavior(client, directory, mode):
            if mode == "controller-worker":
                fixture_publish(client, directory)
                client.request("arm")
                fixture_publish(client, directory)
                grant = client.request("grant", name="preflight", localNs=10 * NS)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                client.request("cancel", reason="TERM", status=143)
                Path(directory, "late-completion-ready").write_bytes(b"")
                gate = os.open(Path(directory, "late-completion-gate"), os.O_RDONLY)
                try:
                    os.read(gate, 1)
                finally:
                    os.close(gate)
                try:
                    client.request("complete", grantId=grant["grantId"])
                except supervisor.SupervisorError:
                    Path(directory, "late-completion-refused").write_bytes(b"")
                else:
                    Path(directory, "late-completion-accepted").write_bytes(b"")
                return
            if mode != "rollback-worker":
                os._exit(5)
            admission = client.request("grant", name="rollback-admission", localNs=NS)
            client.request("complete", grantId=admission["grantId"])
            client.request("admit-rollback")
            fixture_publish(client, directory)
            rollback = client.request("grant", name="rollback-remaining-work", localNs=NS)
            client.request("complete", grantId=rollback["grantId"])
            fixture_terminal(client, directory, 0)

        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o700)
            os.mkfifo(Path(directory, "late-completion-gate"), 0o600)
            released = []

            def release_late_worker(root, _frames):
                if released or not Path(root, "late-completion-ready").exists():
                    return
                gate = os.open(Path(root, "late-completion-gate"), os.O_WRONLY)
                try:
                    os.write(gate, b"x")
                finally:
                    os.close(gate)
                released.append(True)

            result, _ = self.run_fixture(
                behavior, directory=directory, observe=release_late_worker,
            )
            self.assertEqual(released, [True])
            self.assertEqual((result["status"], result["reason"]), (143, "ROLLED_BACK"))
            self.assertTrue(Path(directory, "late-completion-refused").is_file())
            self.assertFalse(Path(directory, "late-completion-accepted").exists())
            lease = state._read_execution_lease_locked(directory)
            self.assertEqual("TERM", lease["firstFailure"])
            self.assertTrue(lease["rollbackIssued"])
            self.assertIn("rollback-worker", [worker["mode"] for worker in lease["workers"]])

    def test_unresolved_publication_failure_retains_childless_fd9_keeper(self):
        def behavior(client, directory, mode):
            if mode == "controller-worker":
                fixture_publish(client, directory)
                client.request("arm")
                fixture_publish(client, directory)
                Path(directory, "publication-ready").write_bytes(b"")
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                client.request("cancel", reason="EXIT", status=1)
                signal.pause()
                return
            if mode != "fail-closed-worker":
                os._exit(5)
            client.request("grant", name="cleanup-stop", localNs=10 * NS)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.pause()

        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o700)
            original_stat = []
            publications = []
            injected = []

            def fail_unresolved_publication(root, _frames):
                if not Path(root, "publication-ready").exists():
                    return
                lease = Path(root, state.EXECUTION_LEASE_NAME)
                current = lease.stat()
                if not original_stat:
                    original_stat.append((current.st_dev, current.st_ino, current.st_mtime_ns))
                    return
                identity = (current.st_dev, current.st_ino, current.st_mtime_ns)
                if identity != original_stat[0]:
                    if not publications or publications[-1] != identity:
                        publications.append(identity)
                    if not injected:
                        Path(root, ".tmp-fixture-publication-conflict").write_bytes(b"")
                        injected.append(True)

            result, _ = self.run_fixture(
                behavior, operation="forward-recover",
                timing=supervisor.Timing(
                    work_ns=2 * NS, hard_ns=8 * NS, handshake_ns=NS,
                    idle_ns=2 * NS, drain_ns=NS, term_ns=NS // 4,
                    stop_ns=NS, publish_ns=NS,
                ),
                timeout=12, observe=fail_unresolved_publication,
                expect_keeper=True, expect_childless_keeper=True,
            )
            self.assertEqual((result["status"], result["reason"]), (1, "QUIESCENCE_UNCONFIRMED"))
            self.assertEqual(injected, [True])
            self.assertEqual(len(publications), 1)
            self.assertTrue(Path(directory, ".tmp-fixture-publication-conflict").is_file())
            lease = state._read_execution_lease_locked(directory)
            self.assertEqual("cancel-forward", lease["lifecycle"])
            self.assertIsNotNone(lease["worker"])

    def test_full_real_clock_540_600_stalled_worker_deadlines(self):
        # Intentionally uses the immutable production Timing, not a shortened
        # CLI/env budget. The no-op forward worker ignores TERM; cleanup stalls
        # in its publication grant until reserve drain, yielding ~600 seconds.
        started = time.monotonic()

        def behavior(client, directory, mode):
            fixture_publish(client, directory)
            if mode == "controller-worker":
                client.request("arm")
                fixture_publish(client, directory)
                client.request("grant", name="docker", localNs=600 * NS)
            elif mode == "fail-closed-worker":
                snapshot = client.request("lease")
                remaining = snapshot["hardEndNs"] - time.monotonic_ns()
                if remaining <= 0:
                    os._exit(7)
                client.request("grant", name="cleanup-publish", localNs=600 * NS)
            else:
                os._exit(8)  # reserve must never issue predecessor rollback
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.pause()

        result, frames = self.run_fixture(
            behavior, operation="forward-recover", timing=supervisor.Timing(), timeout=610,
        )
        elapsed = time.monotonic() - started
        self.assertEqual(result["reason"], "QUIESCENCE_UNCONFIRMED")
        self.assertNotEqual(result["status"], 0)
        clocks = [frame["hardEndNs"] for frame in frames if frame.get("kind") == "clock"]
        self.assertTrue(clocks)
        self.assertEqual(len(set(clocks)), 1)
        self.assertGreaterEqual(elapsed, 598)
        self.assertLess(elapsed, 605)
        print(f"REAL_CLOCK_DEADLINE: elapsed={elapsed:.3f}s; scheduler tolerance=5s (no grant extension)")


class LinuxKernelTests(unittest.TestCase):
    """Real processes/FDs in the isolated PID/mount/network namespace only."""

    def wait_child(self, pid, seconds=5):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            result, status = os.waitpid(pid, os.WNOHANG)
            if result:
                return os.waitstatus_to_exitcode(status)
            time.sleep(0.01)
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        self.fail("fixture child exceeded bounded wait")

    def test_fixed_create_wait_requires_exact_wait_and_local_echild(self):
        import test_vps_timepad_create as create_module

        for behavior, expected in (("zero", True), ("nonzero", False), ("orphan", False)):
            pid = os.fork()
            if pid == 0:
                try:
                    supervisor.linux_preflight()
                    child = os.fork()
                    if child == 0:
                        if behavior == "orphan":
                            descendant = os.fork()
                            if descendant == 0:
                                os.setsid()
                                signal.pause()
                        time.sleep(0.05)
                        os._exit(1 if behavior == "nonzero" else 0)
                    start = create_module._process_start(child)
                    spawned = create_module.SpawnedCreate(child, os.pidfd_open(child, 0), start)
                    selection = create_module.Selection(
                        "/fixture", "/fixture/base.yml", "unused", "unused", "unused", "123-1", "deploy", "deploy",
                    )
                    context = create_module.CreateContext(
                        "/fixture", selection, time.monotonic_ns() + 2 * NS, create_module.Role.INITIAL,
                    )

                    accepted = False
                    try:
                        create_module.wait_create(spawned, context)
                        accepted = True
                    except create_module.CreateError:
                        pass
                    children = supervisor.Children()
                    end = time.monotonic_ns() + 2 * NS
                    while not children.reap():
                        if time.monotonic_ns() >= end:
                            os._exit(4)
                        children.signal_owned(signal.SIGKILL)
                        time.sleep(0.01)
                    os._exit(0 if accepted == expected else 5)
                except BaseException:
                    os._exit(6)
            with self.subTest(behavior=behavior):
                self.assertEqual(0, self.wait_child(pid))

    def test_rpc_credentials_are_kernel_bound_not_frame_assertions(self):
        sender, receiver = supervisor.socket_pair()
        reply, passed = supervisor.socket_pair()
        try:
            supervisor.send_frame(sender, {"pid": os.getpid() + 1}, passed.fileno())
            peers = []
            frame, fd = supervisor.receive_frame(receiver, accept_fd=True, peer=peers)
            self.assertEqual(os.getpid() + 1, frame["pid"])
            self.assertEqual([supervisor.process_identity(os.getpid())], peers)
            os.close(fd)
        finally:
            for endpoint in (sender, receiver, reply, passed):
                endpoint.close()

    def test_pidfd_identity_and_unknown_parent_are_not_signalled(self):
        supervisor.linux_preflight()
        identity = supervisor.process_identity(os.getpid())
        self.assertEqual(identity.pid, os.getpid())
        self.assertEqual(identity.uid, os.geteuid())
        children = supervisor.Children()
        pidfd = os.pidfd_open(os.getpid())
        children.tracked[os.getpid()] = (identity, pidfd)
        # Altered identity cannot cause a signal even though the pidfd is valid.
        children.tracked[os.getpid()] = (
            supervisor.ProcessIdentity(identity.pid, identity.parent, identity.start + 1, identity.uid),
            pidfd,
        )
        try:
            with self.assertRaisesRegex(supervisor.SupervisorError, "OWNERSHIP_UNCERTAIN"):
                children.signal_owned(signal.SIGKILL)
        finally:
            os.close(pidfd)

    def test_socketpair_fd_transfer_preserves_lock_description(self):
        import fcntl
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lock"
            fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            parent, child = supervisor.socket_pair()
            try:
                supervisor.send_frame(parent, {"kind": "lock"}, fd)
                frame, transferred = supervisor.receive_frame(child, accept_fd=True)
                self.assertEqual(frame, {"kind": "lock"})
                os.close(fd)
                fd = -1
                assert transferred is not None
                contender = os.open(path, os.O_RDWR)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    os.close(transferred)
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(contender)
            finally:
                if fd >= 0:
                    os.close(fd)
                parent.close()
                child.close()

    def test_private_reply_sockets_cannot_cross_consume(self):
        requests, server = supervisor.socket_pair()
        first, first_passed = supervisor.socket_pair()
        second, second_passed = supervisor.socket_pair()
        try:
            supervisor.send_frame(requests, {"kind": "first"}, first_passed.fileno())
            supervisor.send_frame(requests, {"kind": "second"}, second_passed.fileno())
            seen = []
            for _ in range(2):
                frame, fd = supervisor.receive_frame(server, accept_fd=True)
                assert fd is not None
                with socket.socket(fileno=fd) as response:
                    supervisor.send_frame(response, frame)
                seen.append(frame["kind"])
            self.assertEqual(seen, ["first", "second"])
            self.assertEqual(supervisor.receive_frame(second)[0], {"kind": "second"})
            self.assertEqual(supervisor.receive_frame(first)[0], {"kind": "first"})
        finally:
            for endpoint in (requests, server, first, first_passed, second, second_passed):
                endpoint.close()

    def test_oversized_packet_and_excess_descriptors_fail_closed(self):
        sender, receiver = supervisor.socket_pair()
        try:
            sender.send(b"x" * (supervisor.MAX_FRAME + 1))
            with self.assertRaises(supervisor.SupervisorError):
                supervisor.receive_frame(receiver)
            fd = os.open("/dev/null", os.O_RDONLY)
            try:
                supervisor.send_frame(sender, {"kind": "unexpected"}, fd)
                with self.assertRaises(supervisor.SupervisorError):
                    supervisor.receive_frame(receiver)
            finally:
                os.close(fd)
        finally:
            sender.close()
            receiver.close()

    def test_setsid_double_fork_intermediate_subreaper_closing_fd9_drains(self):
        # Run the subreaper in a dedicated child so it cannot adopt unrelated
        # unittest/launcher processes and prove only fixture-owned childlessness.
        result_read, result_write = os.pipe()
        pid = os.fork()
        if pid == 0:
            try:
                os.close(result_read)
                supervisor.linux_preflight()
                ready_read, ready_write = os.pipe()
                root = os.fork()
                if root == 0:
                    os.setsid()
                    supervisor.linux_preflight()  # intermediate subreaper
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    grandchild = os.fork()
                    if grandchild == 0:
                        try:
                            os.close(9)
                        except OSError:
                            pass
                        signal.signal(signal.SIGTERM, signal.SIG_IGN)
                        descendant = os.fork()
                        if descendant == 0:
                            os.setsid()
                            signal.signal(signal.SIGTERM, signal.SIG_IGN)
                            os.write(ready_write, b"ready")
                            signal.pause()
                        os._exit(0)
                    signal.pause()
                os.close(ready_write)
                supervisor._wait_readable(ready_read, time.monotonic_ns() + 2 * NS)
                if os.read(ready_read, 5) != b"ready":
                    os._exit(5)
                os.close(ready_read)
                children = supervisor.Children()
                deadline = time.monotonic() + 4
                childless = False
                while time.monotonic() < deadline:
                    childless = children.reap()
                    if childless:
                        break
                    children.signal_owned(signal.SIGKILL)
                    time.sleep(0.01)
                if not childless:
                    os._exit(2)
                try:
                    os.waitpid(-1, os.WNOHANG)
                except ChildProcessError:
                    os.write(result_write, b"ECHILD")
                    os._exit(0)
                os._exit(3)
            except BaseException:
                os._exit(4)
        os.close(result_write)
        try:
            self.assertEqual(self.wait_child(pid), 0)
            self.assertEqual(os.read(result_read, 16), b"ECHILD")
        finally:
            os.close(result_read)

    def test_stopped_term_ignoring_child_needs_pidfd_kill_then_echild(self):
        pid = os.fork()
        if pid == 0:
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.kill(os.getpid(), signal.SIGSTOP)
            signal.pause()
            os._exit(1)
        children = supervisor.Children()
        children.refresh()
        children.signal_owned(signal.SIGTERM)
        self.assertFalse(children.reap())
        children.signal_owned(signal.SIGKILL)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if children.reap():
                return
            time.sleep(0.01)
        self.fail("owned stopped child was not reaped")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", action="store_true")
    options = parser.parse_args()
    if not options.portable:
        if sys.platform != "linux" or os.geteuid() != 0:
            print("SUPERVISOR_FIXTURES_BLOCKED: isolated Linux/root required", file=sys.stderr)
            return 77
        for kind in ("MOUNT", "NETWORK", "PID"):
            parent = os.environ.get(f"TIMEPAD_FIXTURE_PARENT_{kind}_NS")
            current = os.readlink(f"/proc/self/ns/{'mnt' if kind == 'MOUNT' else 'net' if kind == 'NETWORK' else 'pid'}")
            if not parent or parent == current:
                print("SUPERVISOR_FIXTURES_BLOCKED: isolation launcher required", file=sys.stderr)
                return 77
        supervisor.linux_preflight()
    classes = [AttemptTests, CreateProtocolTests, RecoveryCreateRegistrationTests, ControllerLifecycleTests]
    if not options.portable:
        classes += [LinuxKernelTests, LinuxSupervisorTests]
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in classes)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if options.portable:
        print("PORTABLE_MODEL_ONLY: Linux supervisor acceptance not evaluated")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
