#!/usr/bin/env python3
"""Focused supervisor tests; authoritative invocation requires isolated Linux.

``--portable`` explicitly selects only pure model/protocol-source tests. It is
not Linux/FD9/subreaper evidence and is never selected by the fixture CI command.
No production CLI or environment deadline override is used.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import sys
import tempfile
import time
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
        attempt.admit_rollback()
        acknowledged(attempt)
        attempt.grant("rollback-remaining-work", 600 * NS)
        self.assertEqual(original, (attempt.nonce, attempt.t0, attempt.work_end, attempt.hard_end))

    def test_forward_recovery_charges_authorization_before_any_grant(self):
        attempt = supervisor.Attempt("forward-recover", clock=self.clock)
        original = attempt.t0
        self.clock.advance(530)
        acknowledged(attempt)
        grant = attempt.grant("provider", 30 * NS)
        self.assertEqual(grant.end_ns, original + 540 * NS)
        attempt.cancel("EXIT", 1)
        self.assertEqual(attempt.after_drain(), "fail-closed-worker")
        self.assertFalse(attempt.rollback_issued)

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


def fixture_publish(client, directory):
    snapshot = client.request("lease")
    grant = client.request("grant", name="lease-publish", localNs=10 * NS)
    data = supervisor.encode(snapshot)
    target = Path(directory) / "fixture-execution.json"
    temporary = Path(directory) / "fixture-execution.tmp"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, target)
    parent = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)
    client.request("complete", grantId=grant["grantId"])
    client.request(
        "lease-ack", revision=snapshot["revision"], digest=hashlib.sha256(data).hexdigest(),
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
        self.worker_identity = supervisor.process_identity(pid).frame()
        self.worker_identities.append({"mode": mode, **self.worker_identity})
        self.worker_hello = False
        self.worker_handshake_end = time.monotonic_ns() + self.attempt.timing.handshake_ns
        self.attempt.idle_end = self.worker_handshake_end


class LinuxSupervisorTests(unittest.TestCase):
    def run_fixture(self, behavior, *, operation="deploy", timing=None, timeout=15, disconnect=False):
        with tempfile.TemporaryDirectory() as directory:
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
            client.request("arm")
            fixture_publish(client, directory)
            grant = client.request("grant", name="runtime", localNs=NS)
            client.request("complete", grantId=grant["grantId"])
            fixture_terminal(client, directory, 0)

        result, _ = self.run_fixture(behavior)
        self.assertEqual((result["status"], result["reason"]), (0, "COMPLETED"))

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
                client.request("grant", name="preflight", localNs=NS)
                signal.pause()
            else:
                fixture_terminal(client, directory, 1)

        result, _ = self.run_fixture(behavior, operation="forward-recover", disconnect=True)
        self.assertIsNone(result)

    def test_full_real_clock_540_600_stalled_worker_deadlines(self):
        # Intentionally uses the immutable production Timing, not a shortened
        # CLI/env budget. The no-op forward worker ignores TERM; cleanup stalls
        # in its publication grant until reserve drain, yielding ~600 seconds.
        started = time.monotonic()

        def behavior(client, directory, mode):
            fixture_publish(client, directory)
            if mode == "controller-worker":
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
    classes = [AttemptTests] if options.portable else [AttemptTests, LinuxKernelTests, LinuxSupervisorTests]
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in classes)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if options.portable:
        print("PORTABLE_MODEL_ONLY: Linux supervisor acceptance not evaluated")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
