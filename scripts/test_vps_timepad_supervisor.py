#!/usr/bin/env python3
"""Fixed Linux Timepad controller relay, private RPC, and attempt supervisor.

Public entry::

    python3 -B test_vps_timepad_supervisor.py relay --root ROOT \
        --operation deploy -- ORIGINAL_CONTROLLER_ARGUMENTS

The only executable selected by this module is the sibling controller, invoked
as ``bash SCRIPT --timepad-private-worker MODE ...``. MODE is one of the four
WORKER_MODES below. That entry must call ``client --root ROOT hello`` before
doing anything else. Environment variables bind the private socket but do not
replace it or FD9. Each shell/helper RPC uses its own SCM_RIGHTS reply socket;
concurrent command substitutions cannot consume one another's replies.

Worker contract (also exposed by WorkerClient):
* Publish/ack the initial ``registered`` lease before ``arm`` immediately
  before PREPARED. Forward-recover charges its clock at supervisor entry,
  including registration, then arms without resetting that clock.
* ``lease`` obtains the current immutable publication snapshot/revision.
  Publish it durably using the state helper under a ``lease-publish`` grant,
  complete that grant, then ``lease-ack REV DIGEST``. No other work grant is
  issued before this acknowledgement. Re-fetch after arm/lifecycle changes.
* ``grant NAME LOCAL_SECONDS`` returns an absolute monotonic endNs and opaque
  grantId. Pass that deadline through every nested helper; complete only after
  the operation/children finish. Local timeout is secondary to supervision.
* rollback-worker first publishes the one-shot rollbackIssued lease, takes a
  read-only ``rollback-admission`` grant, proves schema/provider AND daemon
  quiescence, completes it, then calls ``admit-rollback``. This message is the
  fixed worker's assertion, not an authorization available to other roles.
* ``prepare-terminal`` freezes grants and provides a drained lease snapshot.
  Publish/ack it, then ``terminal STATUS`` only after exact daemon/runtime and
  durable incident/terminal-result checks. Exit immediately. Success is not
  returned until kernel ECHILD; a worker exit alone is never success.
* ``cancel REASON STATUS`` revokes forward work. Traps never do rollback.

Lease disk publication and semantic rollback/runtime admission belong to the
fixed workers/state helper, not this event loop. This module never treats
process reap as proof that a Docker request finished. Its terminal message is
an explicit worker acknowledgement of that separate proof.

The pure Attempt class accepts a clock/Timing only in-process for tests. The
production CLI/environment has no deadline override or arbitrary exec hook.
"""

from __future__ import annotations

import argparse
import array
import ctypes
import errno
import json
import math
import os
import re
import secrets
import selectors
import signal
import socket
import stat
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

NS = 1_000_000_000
MAX_FRAME = 4096
MAX_CHILDREN = 256
MAX_GRANTS = 256
WORKER_MODES = frozenset({
    "controller-worker", "rollback-worker", "fail-closed-worker", "retention-worker",
})
OPERATIONS = frozenset({"deploy", "forward-recover", "retention"})
WAIT_NAMES = frozenset({
    "preflight", "state-publish", "provider", "runtime", "docker", "curl",
    "health", "child-handshake", "rollback-admission", "rollback-remaining-work",
    "cleanup-stop", "cleanup-publish", "lease-publish", "terminal-verify",
})
FAILURES = frozenset({
    "TERM", "INT", "HUP", "EXIT", "DRILL", "WAIT_EXPIRED", "WORK_EXHAUSTED",
    "HARD_DEADLINE", "TRANSPORT_LOST", "PROTOCOL_INVALID", "OWNERSHIP_UNCERTAIN",
    "DESCENDANT_OVERFLOW", "ROLLBACK_REFUSED", "ROLLBACK_FAILED",
})
NONCE = re.compile(r"^[a-f0-9]{32}$")
DIGEST = re.compile(r"^[a-f0-9]{64}$")


class SupervisorError(Exception):
    """Fixed sanitized error: no OS exception or private input is printed."""


def reject(reason: str = "PROTOCOL_INVALID") -> None:
    raise SupervisorError(reason)


def _pairs(items: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in items:
        if key in result:
            reject()
        result[key] = value
    return result


def encode(frame: dict[str, Any]) -> bytes:
    data = json.dumps(frame, separators=(",", ":"), sort_keys=True, allow_nan=False).encode()
    if len(data) > MAX_FRAME:
        reject()
    return data


def decode(data: bytes) -> dict[str, Any]:
    if not data or len(data) > MAX_FRAME:
        reject()
    try:
        value = json.loads(data, object_pairs_hook=_pairs)
    except (ValueError, UnicodeError, RecursionError):
        reject()
    if not isinstance(value, dict) or len(value) > 16:
        reject()
    # Protocol is deliberately flat except the bounded lease snapshot response.
    return value


def _integer(value: Any, minimum: int = 0, maximum: int = (1 << 63) - 1) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        reject()
    return value


def _nonce(value: Any) -> str:
    if not isinstance(value, str) or NONCE.fullmatch(value) is None:
        reject()
    return value


def _seconds(value: str) -> int:
    try:
        seconds = float(value)
    except ValueError:
        reject()
    if not math.isfinite(seconds) or not 0 < seconds <= 600:
        reject()
    return max(1, int(seconds * NS))


@dataclass(frozen=True)
class Timing:
    work_ns: int = 540 * NS
    hard_ns: int = 600 * NS
    handshake_ns: int = 5 * NS
    idle_ns: int = 30 * NS
    drain_ns: int = 10 * NS
    term_ns: int = 5 * NS
    stop_ns: int = 40 * NS
    publish_ns: int = 10 * NS

    def __post_init__(self) -> None:
        if any(type(value) is not int or value <= 0 for value in vars(self).values()):
            raise ValueError("invalid timing")
        if self.work_ns >= self.hard_ns or self.term_ns > self.drain_ns:
            raise ValueError("invalid timing")


@dataclass(frozen=True)
class Grant:
    grant_id: str
    name: str
    end_ns: int
    attempt: str
    role: str

    def frame(self) -> dict[str, Any]:
        return {
            "grantId": self.grant_id, "name": self.name, "endNs": self.end_ns,
            "attempt": self.attempt, "role": self.role,
        }


class Attempt:
    """Single source of authority for clocks, cancellation and grant issuance."""

    def __init__(
        self, operation: str, *, clock: Callable[[], int] = time.monotonic_ns,
        timing: Timing = Timing(), nonce: str | None = None,
    ):
        if not isinstance(operation, str) or operation not in OPERATIONS:
            reject()
        self.operation = operation
        self.clock = clock
        self.timing = timing
        self.nonce = _nonce(nonce) if nonce is not None else secrets.token_hex(16)
        self.t0: int | None = None
        self.work_end: int | None = None
        self.hard_end: int | None = None
        self.lifecycle = "registered"
        self.revision = 0
        self.acked_revision = -1
        self.lease_digest: str | None = None
        self.first_reason: str | None = None
        self.first_status: int | None = None
        self.rollback_issued = False
        self.rollback_admitted = False
        self.grants: dict[str, Grant] = {}
        self.idle_end = self.clock() + timing.idle_ns
        self.drain_end: int | None = None
        self.term_end: int | None = None
        self.cleanup_stop_end: int | None = None
        self.role = "retention-worker" if operation == "retention" else "controller-worker"
        self.pending_terminal: int | None = None
        self.result: tuple[int, str] | None = None
        if operation == "forward-recover":
            self._start_clock()

    def _change(self, lifecycle: str) -> None:
        self.lifecycle = lifecycle
        self.revision += 1
        self.acked_revision = -1
        self.lease_digest = None

    def _start_clock(self) -> None:
        if self.t0 is not None:
            return
        self.t0 = self.clock()
        self.work_end = self.t0 + self.timing.work_ns
        self.hard_end = self.t0 + self.timing.hard_ns

    def arm(self) -> None:
        if self.lifecycle != "registered":
            return
        self._start_clock()
        self._change("armed")

    def cancel(self, reason: str, status: int = 1) -> None:
        if not isinstance(reason, str) or reason not in FAILURES:
            reject()
        _integer(status, 1, 255)
        # Repeated signals do not revoke a separately issued rollback grant.
        if self.first_reason is not None:
            return
        self.first_reason, self.first_status = reason, status
        self.arm()
        self.grants.clear()
        self.pending_terminal = None
        self._change("drain-forward")
        self.begin_drain()

    def begin_drain(self) -> None:
        now = self.clock()
        end = self.hard_end if self.role == "fail-closed-worker" or \
            (self.work_end is not None and now >= self.work_end) else self.work_end
        assert end is not None
        self.drain_end = min(now + self.timing.drain_ns, end)
        # Leave one event-loop tick for pidfd KILL before the absolute end.
        margin = min(100_000_000, self.timing.term_ns // 10)
        self.term_end = max(now, min(now + self.timing.term_ns, self.drain_end - margin))

    def lease(self) -> dict[str, Any]:
        return {
            "format": 1, "attempt": self.nonce, "operation": self.operation,
            "t0Ns": self.t0, "workEndNs": self.work_end, "hardEndNs": self.hard_end,
            "firstFailure": self.first_reason, "firstStatus": self.first_status,
            "rollbackIssued": self.rollback_issued, "lifecycle": self.lifecycle,
            "revision": self.revision,
        }

    @property
    def draining(self) -> bool:
        return self.drain_end is not None and self.lifecycle in {"drain-forward", "draining"}

    def acknowledge_lease(self, revision: int, digest: str) -> None:
        if revision != self.revision or not isinstance(digest, str) or \
                DIGEST.fullmatch(digest) is None:
            reject("LEASE_ACK_INVALID")
        if any(g.name == "lease-publish" for g in self.grants.values()):
            reject("LEASE_ACK_INVALID")
        self.acked_revision, self.lease_digest = revision, digest

    def grant(self, name: str, local_ns: int) -> Grant:
        now = self.clock()
        _integer(local_ns, 1, 600 * NS)
        if not isinstance(name, str) or name not in WAIT_NAMES or len(self.grants) >= MAX_GRANTS:
            reject("WAIT_REFUSED")
        if self.hard_end is not None and now >= self.hard_end:
            reject("WAIT_REFUSED")
        if self.draining or self.lifecycle == "quiescence-unconfirmed":
            reject("WAIT_REFUSED")
        if name != "lease-publish" and self.acked_revision != self.revision:
            reject("LEASE_ACK_REQUIRED")
        if self.operation == "forward-recover" and self.lifecycle == "registered" \
                and name != "lease-publish":
            reject("WAIT_REFUSED")
        if self.lifecycle == "drained" and name != "lease-publish":
            reject("WAIT_REFUSED")
        if self.role == "fail-closed-worker":
            if name not in {"cleanup-stop", "cleanup-publish", "lease-publish"}:
                reject("WAIT_REFUSED")
            assert self.hard_end is not None and self.cleanup_stop_end is not None
            end = self.cleanup_stop_end if name == "cleanup-stop" else \
                self.hard_end - self.timing.term_ns
        else:
            if self.first_reason is not None and self.role != "rollback-worker":
                reject("WAIT_REFUSED")
            if self.role == "rollback-worker" and not self.rollback_admitted and \
                    name not in {"rollback-admission", "lease-publish"}:
                reject("WAIT_REFUSED")
            if self.role != "rollback-worker" and name.startswith("rollback-"):
                reject("WAIT_REFUSED")
            if name.startswith("cleanup-"):
                reject("WAIT_REFUSED")
            end = self.work_end if self.work_end is not None else now + local_ns
        if name == "health":
            local_ns = min(local_ns, 180 * NS)
        if name == "child-handshake":
            local_ns = min(local_ns, self.timing.handshake_ns)
        end = min(end, now + local_ns)
        if end <= now:
            reject("WAIT_REFUSED")
        grant = Grant(secrets.token_hex(16), name, end, self.nonce, self.role)
        self.grants[grant.grant_id] = grant
        self.idle_end = now + self.timing.idle_ns
        return grant

    def complete(self, grant_id: str) -> None:
        grant = self.grants.get(_nonce(grant_id))
        if grant is None or self.clock() >= grant.end_ns:
            reject("GRANT_REVOKED")
        del self.grants[grant_id]
        self.idle_end = self.clock() + self.timing.idle_ns

    def after_drain(self) -> str | None:
        """Called only after kernel ECHILD; never merely after worker exit."""
        self.grants.clear()
        self.pending_terminal = None
        now = self.clock()
        assert self.work_end is not None and self.hard_end is not None
        if now >= self.hard_end:
            self.unconfirmed()
            return None
        if self.role == "fail-closed-worker":
            self.unconfirmed()
            return None
        if self.role == "controller-worker" and self.operation == "deploy" and \
                not self.rollback_issued and now < self.work_end and \
                self.first_reason not in {"OWNERSHIP_UNCERTAIN", "DESCENDANT_OVERFLOW"}:
            self.rollback_issued = True
            self.role = "rollback-worker"
            self._change("rollback-admission")
        else:
            self.role = "fail-closed-worker"
            self.cleanup_stop_end = min(now + self.timing.stop_ns, self.hard_end - self.timing.publish_ns)
            self._change("draining")
        self.idle_end = min(now + self.timing.handshake_ns, self.hard_end)
        self.drain_end = self.term_end = None
        return self.role

    def admit_rollback(self) -> None:
        if self.role != "rollback-worker" or self.lifecycle != "rollback-admission" or \
                self.acked_revision != self.revision or self.grants or \
                self.work_end is None or self.clock() >= self.work_end:
            reject("ROLLBACK_REFUSED")
        self.rollback_admitted = True
        self._change("rolling-back")

    def prepare_terminal(self) -> None:
        if self.grants or self.acked_revision != self.revision:
            reject("TERMINAL_REFUSED")
        if self.operation == "forward-recover" and self.lifecycle == "registered":
            reject("TERMINAL_REFUSED")
        if self.role == "rollback-worker" and not self.rollback_admitted:
            reject("TERMINAL_REFUSED")
        if self.lifecycle == "drained":
            return
        self._change("drained")

    def terminal(self, status: int) -> None:
        _integer(status, 0, 255)
        if self.lifecycle != "drained" or self.acked_revision != self.revision or self.grants:
            reject("TERMINAL_REFUSED")
        end = self.hard_end if self.role == "fail-closed-worker" else self.work_end
        if end is not None and self.clock() >= end:
            reject("TERMINAL_REFUSED")
        if self.role == "fail-closed-worker" and status == 0:
            reject("TERMINAL_REFUSED")
        if self.role in {"controller-worker", "retention-worker"} and status != 0:
            reject("TERMINAL_REFUSED")
        if self.role == "rollback-worker" and status not in {0, 86}:
            reject("TERMINAL_REFUSED")
        if status == 86 and (self.role != "rollback-worker" or self.first_status != 86):
            reject("TERMINAL_REFUSED")
        if self.first_reason is not None and self.role == "controller-worker":
            reject("TERMINAL_REFUSED")
        self.pending_terminal = status

    def finish_childless(self) -> None:
        if self.pending_terminal is None:
            reject("TERMINAL_REFUSED")
        if self.role == "rollback-worker":
            status = 86 if self.first_status == 86 else self.first_status or 1
            self.result = (status, "ROLLED_BACK")
        elif self.role == "fail-closed-worker":
            self.result = (self.failure_status, "RECOVERY_REQUIRED")
        else:
            self.result = (self.pending_terminal, "COMPLETED" if self.pending_terminal == 0 else "FAILED")

    def unconfirmed(self) -> None:
        self.grants.clear()
        self.pending_terminal = None
        self._change("quiescence-unconfirmed")
        self.result = (self.failure_status, "QUIESCENCE_UNCONFIRMED")

    @property
    def failure_status(self) -> int:
        # 86 has a public success meaning only after verified drill rollback.
        return self.first_status if self.first_status not in {None, 86} else 1

    def poll(self) -> None:
        now = self.clock()
        if self.hard_end is not None and now >= self.hard_end:
            self.unconfirmed()
            return
        if self.work_end is not None and now >= self.work_end and self.draining and \
                self.drain_end == self.work_end:
            assert self.hard_end is not None
            self.drain_end = min(self.work_end + self.timing.drain_ns, self.hard_end)
        if self.work_end is not None and now >= self.work_end and \
                self.role != "fail-closed-worker" and self.lifecycle not in {
                    "drain-forward", "draining", "quiescence-unconfirmed",
                }:
            self.cancel("WORK_EXHAUSTED")
            self.grants.clear()
            self.pending_terminal = None
            self._change("draining")
            self.begin_drain()
        if any(now >= grant.end_ns for grant in self.grants.values()):
            if self.first_reason is None:
                self.cancel("WAIT_EXPIRED")
            else:
                self.grants.clear()
                self.pending_terminal = None
                self._change("draining")
                self.begin_drain()
        if not self.grants and self.pending_terminal is None and now >= self.idle_end and \
                not self.draining and self.lifecycle != "quiescence-unconfirmed":
            if self.first_reason is None:
                self.cancel("WAIT_EXPIRED")
            else:
                self._change("draining")
                self.begin_drain()


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    parent: int
    start: int
    uid: int

    def frame(self) -> dict[str, int]:
        return {"pid": self.pid, "parentPid": self.parent, "startTicks": self.start, "uid": self.uid}


def process_identity(pid: int) -> ProcessIdentity:
    """Read only bounded kernel-generated proc records, never process names."""
    _integer(pid, 1)
    with open(f"/proc/{pid}/stat", "rb", buffering=0) as source:
        data = source.read(4097)
    if len(data) > 4096:
        reject("OWNERSHIP_UNCERTAIN")
    fields = data.rsplit(b")", 1)[1].split()
    info = os.stat(f"/proc/{pid}")
    return ProcessIdentity(pid, int(fields[1]), int(fields[19]), info.st_uid)


def boot_id() -> str:
    with open("/proc/sys/kernel/random/boot_id", "rt", encoding="ascii") as source:
        value = source.read(65).strip()
    if re.fullmatch(r"[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}", value) is None:
        reject("LINUX_PREREQUISITE_REQUIRED")
    return value


def lease_identity(identity: ProcessIdentity) -> dict[str, Any]:
    """Project proc identity onto the strict durable lease schema."""
    return {
        "pid": identity.pid,
        "startTicks": identity.start,
        "bootId": boot_id(),
    }


def linux_preflight() -> None:
    if sys.platform != "linux" or not hasattr(os, "pidfd_open") or \
            not hasattr(signal, "pidfd_send_signal"):
        reject("LINUX_PREREQUISITE_REQUIRED")
    # prctl is a checked fixed binding, not an arbitrary libc command surface.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    libc.prctl.restype = ctypes.c_int
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        reject("LINUX_PREREQUISITE_REQUIRED")
    pidfd = os.pidfd_open(os.getpid(), 0)
    try:
        signal.pidfd_send_signal(pidfd, 0)
    finally:
        os.close(pidfd)


def socket_pair() -> tuple[socket.socket, socket.socket]:
    pair = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    for endpoint in pair:
        endpoint.setblocking(False)
    return pair


def send_frame(channel: socket.socket, frame: dict[str, Any], fd: int | None = None) -> None:
    data = encode(frame)
    ancillary = [] if fd is None else [
        (socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd])),
    ]
    if channel.sendmsg([data], ancillary) != len(data):
        reject()


def receive_frame(channel: socket.socket, *, accept_fd: bool = False) -> tuple[dict[str, Any], int | None]:
    data, ancillary, flags, _ = channel.recvmsg(MAX_FRAME + 1, socket.CMSG_SPACE(4 * 4))
    descriptors: list[int] = []
    try:
        for level, kind, raw in ancillary:
            if level != socket.SOL_SOCKET or kind != socket.SCM_RIGHTS:
                reject()
            values = array.array("i")
            values.frombytes(raw[:len(raw) - len(raw) % values.itemsize])
            descriptors.extend(values)
        if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) or len(data) > MAX_FRAME or \
                len(descriptors) != (1 if accept_fd else 0):
            reject()
        frame = decode(data)
        fd = descriptors.pop() if descriptors else None
        if fd is not None:
            os.set_inheritable(fd, False)
        return frame, fd
    finally:
        for descriptor in descriptors:
            os.close(descriptor)


def _wait_readable(channel: socket.socket, end_ns: int) -> None:
    with selectors.DefaultSelector() as selector:
        selector.register(channel, selectors.EVENT_READ)
        while True:
            remaining = end_ns - time.monotonic_ns()
            if remaining <= 0:
                reject("PROTOCOL_TIMEOUT")
            if selector.select(min(remaining / NS, 0.1)):
                return


def _close_except(keep: set[int]) -> None:
    # This is a fork child before the event loop, not an unbounded scan of FDs.
    for name in os.listdir("/proc/self/fd"):
        fd = int(name)
        if fd > 2 and fd not in keep:
            try:
                os.close(fd)
            except OSError as error:
                if error.errno != errno.EBADF:
                    raise


class Children:
    """Pidfd ownership plus ECHILD proof; a process-group snapshot is insufficient."""

    def __init__(self):
        self.tracked: dict[int, tuple[ProcessIdentity, int]] = {}
        self.statuses: dict[int, int] = {}

    def refresh(self) -> None:
        with open(f"/proc/self/task/{os.getpid()}/children", "rb", buffering=0) as source:
            data = source.read(8193)
        if len(data) > 8192:
            reject("DESCENDANT_OVERFLOW")
        pids = data.split()
        if len(pids) > MAX_CHILDREN:
            reject("DESCENDANT_OVERFLOW")
        for raw_pid in pids:
            pid = int(raw_pid)
            if pid in self.tracked:
                continue
            try:
                identity = process_identity(pid)
                if identity.parent != os.getpid() or identity.uid != os.geteuid():
                    reject("OWNERSHIP_UNCERTAIN")
                pidfd = os.pidfd_open(pid, 0)
                try:
                    if process_identity(pid) != identity:
                        reject("OWNERSHIP_UNCERTAIN")
                except BaseException:
                    os.close(pidfd)
                    raise
                self.tracked[pid] = (identity, pidfd)
            except (FileNotFoundError, ProcessLookupError):
                continue
        if len(self.tracked) > MAX_CHILDREN:
            reject("DESCENDANT_OVERFLOW")

    def reap(self) -> bool:
        self.statuses.clear()
        # At most 256 per tick; ECHILD, not the dictionary, proves childlessness.
        for _ in range(MAX_CHILDREN + 1):
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                for _, pidfd in self.tracked.values():
                    os.close(pidfd)
                self.tracked.clear()
                return True
            if pid == 0:
                return False
            self.statuses[pid] = os.waitstatus_to_exitcode(status)
            tracked = self.tracked.pop(pid, None)
            if tracked is not None:
                os.close(tracked[1])
        return False

    def signal_owned(self, number: int) -> None:
        self.refresh()
        for identity, pidfd in tuple(self.tracked.values()):
            try:
                # Validate proc ancestry/start again before using the pidfd.
                if process_identity(identity.pid) != identity:
                    reject("OWNERSHIP_UNCERTAIN")
                signal.pidfd_send_signal(pidfd, number)
            except (FileNotFoundError, ProcessLookupError):
                continue


class WorkerClient:
    """Private descriptor-capability RPC, usable by shell and Python helpers."""

    def __init__(self, root: str):
        from test_vps_timepad_state import GuardError, deploy_lock

        self.channel: socket.socket | None = None
        try:
            fd = int(os.environ["TIMEPAD_CONTROL_FD"])
            self.attempt = _nonce(os.environ["TIMEPAD_ATTEMPT"])
            self.supervisor = decode(os.environ["TIMEPAD_SUPERVISOR"].encode())
            self.role = os.environ["TIMEPAD_WORKER_MODE"]
            if self.role not in WORKER_MODES:
                reject()
            self.channel = socket.socket(fileno=os.dup(fd))
            if self.channel.family != socket.AF_UNIX or self.channel.type != socket.SOCK_SEQPACKET:
                reject()
            self.channel.setblocking(False)
            # Context deliberately never LOCK_UNs the inherited description.
            with deploy_lock(root, 9):
                pass
            expected = self.supervisor
            current = process_identity(_integer(expected["pid"], 1))
            if current.start != expected["startTicks"] or expected["bootId"] != boot_id():
                reject()
            peer_pid, _, peer_uid = struct.unpack(
                "3i", self.channel.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12),
            )
            if peer_pid != current.pid or peer_uid != os.geteuid():
                reject()
        except (KeyError, ValueError, OSError, GuardError, SupervisorError):
            if self.channel is not None:
                self.channel.close()
            reject("PRIVATE_WORKER_REQUIRED")

    def request(self, kind: str, **fields: Any) -> dict[str, Any]:
        reply, passed = socket_pair()
        try:
            assert self.channel is not None
            send_frame(self.channel, {
                "kind": kind, "attempt": self.attempt, "role": self.role, **fields,
            }, passed.fileno())
            passed.close()
            _wait_readable(reply, time.monotonic_ns() + 5 * NS)
            response, _ = receive_frame(reply)
            if response.get("attempt") != self.attempt or response.get("supervisor") != self.supervisor:
                reject()
            if response.get("ok") is not True:
                reject("PRIVATE_REQUEST_REFUSED")
            return response["value"]
        finally:
            reply.close()
            passed.close()

    def close(self) -> None:
        if self.channel is not None:
            self.channel.close()


class Supervisor:
    def __init__(
        self, root: str, operation: str, arguments: list[str], relay: socket.socket,
        *, timing: Timing = Timing(),
    ):
        linux_preflight()
        self.attempt = Attempt(operation, timing=timing)
        self.root, self.arguments, self.relay = root, arguments, relay
        me = process_identity(os.getpid())
        self.identity = {"pid": me.pid, "startTicks": me.start, "bootId": boot_id()}
        self.children = Children()
        self.lock_fd: int | None = None
        self.worker_pid: int | None = None
        self.worker: socket.socket | None = None
        self.worker_identity: dict[str, Any] | None = None
        self.worker_identities: list[dict[str, Any]] = []
        self.worker_hello = False
        self.worker_handshake_end: int | None = None
        self.relay_alive = True
        self.reported = False
        self.pending_signals: list[int] = []
        self.last_clock: tuple[int | None, int] | None = None

    def _signal(self, number: int, _frame: Any) -> None:
        if not self.pending_signals:
            self.pending_signals.append(number)

    def _lease(self) -> dict[str, Any]:
        return {
            **self.attempt.lease(), "supervisor": self.identity,
            "worker": self.worker_identity, "workerMode": self.attempt.role,
            "workers": self.worker_identities,
        }

    def acquire_lock(self) -> None:
        parent, child = socket_pair()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                _close_except({child.fileno()})
                from test_vps_timepad_state import deploy_lock
                context = deploy_lock(self.root)
                fd = context.__enter__()
                # Do not invoke __exit__: LOCK_UN would unlock the transferred OFD.
                send_frame(child, {"kind": "lock", "attempt": self.attempt.nonce}, fd)
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        try:
            end = time.monotonic_ns() + self.attempt.timing.handshake_ns
            if self.attempt.hard_end is not None:
                end = min(end, self.attempt.hard_end)
            _wait_readable(parent, end)
            frame, fd = receive_frame(parent, accept_fd=True)
            if frame != {"kind": "lock", "attempt": self.attempt.nonce}:
                if fd is not None:
                    os.close(fd)
                reject()
            assert fd is not None
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
                os.close(fd)
                reject("DEPLOY_LOCK_INVALID")
            self.lock_fd = fd
            # The lock worker is part of owned children until WNOHANG proves exit.
            while not self.children.reap():
                if time.monotonic_ns() >= end:
                    reject("PROTOCOL_TIMEOUT")
                time.sleep(0.01)
        finally:
            parent.close()

    def spawn(self) -> None:
        if self.worker is not None:
            self.worker.close()
        parent, child = socket_pair()
        assert self.lock_fd is not None
        mode = self.attempt.role
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                # Reserve FD9 before allocating the inheritable control FD.
                control_fd = os.dup(child.fileno())
                if control_fd == 9:
                    control_fd = os.dup(control_fd)
                os.dup2(self.lock_fd, 9, inheritable=True)
                os.set_inheritable(control_fd, True)
                _close_except({9, control_fd})
                environment = dict(os.environ)
                environment.update({
                    "TIMEPAD_CONTROL_FD": str(control_fd),
                    "TIMEPAD_ATTEMPT": self.attempt.nonce,
                    "TIMEPAD_SUPERVISOR": encode(self.identity).decode(),
                    "TIMEPAD_WORKER_MODE": mode,
                })
                controller = str(Path(__file__).resolve().with_name("deploy-test-vps-provider-release.sh"))
                os.execvpe("bash", [
                    "bash", controller, "--timepad-private-worker", mode, *self.arguments,
                ], environment)
            except BaseException:
                os._exit(1)
        child.close()
        self.worker, self.worker_pid = parent, pid
        try:
            self.worker_identity = lease_identity(process_identity(pid))
        except (FileNotFoundError, ProcessLookupError):
            self.worker_identity = None
        if self.worker_identity is not None:
            self.worker_identities.append({"mode": mode, **self.worker_identity})
        if len(self.worker_identities) > 3:
            reject("OWNERSHIP_UNCERTAIN")
        self.worker_hello = False
        end = time.monotonic_ns() + self.attempt.timing.handshake_ns
        if self.attempt.hard_end is not None:
            end = min(end, self.attempt.hard_end)
        self.worker_handshake_end = end
        self.attempt.idle_end = end

    def _rpc(self) -> None:
        assert self.worker is not None
        frame, passed = receive_frame(self.worker, accept_fd=True)
        assert passed is not None
        try:
            reply = socket.socket(fileno=passed)
        except OSError:
            os.close(passed)
            reject()
        reply.setblocking(False)
        try:
            if reply.family != socket.AF_UNIX or reply.type != socket.SOCK_SEQPACKET:
                reject()
            if frame.get("attempt") != self.attempt.nonce or \
                    frame.get("role") != self.attempt.role:
                reject()
            kind = frame.get("kind")
            schemas = {
                "hello": set(), "arm": set(), "lease": set(),
                "lease-ack": {"revision", "digest"}, "grant": {"name", "localNs"},
                "complete": {"grantId"}, "cancel": {"reason", "status"},
                "admit-rollback": set(), "prepare-terminal": set(), "terminal": {"status"},
            }
            if not isinstance(kind, str) or kind not in schemas or \
                    set(frame) != {"kind", "attempt", "role"} | schemas[kind]:
                reject()
            if self.attempt.draining or self.attempt.lifecycle == "quiescence-unconfirmed":
                reject("GRANT_REVOKED")
            value: dict[str, Any] = {}
            if not self.worker_hello and kind != "hello":
                reject("PRIVATE_WORKER_REQUIRED")
            if kind == "hello":
                if self.worker_hello:
                    reject()
                self.worker_hello = True
                self.worker_handshake_end = None
                self.attempt.idle_end = time.monotonic_ns() + self.attempt.timing.idle_ns
                value = self._lease()
            elif kind == "arm":
                if self.attempt.role not in {"controller-worker", "retention-worker"}:
                    reject()
                if self.attempt.acked_revision != self.attempt.revision:
                    reject("LEASE_ACK_REQUIRED")
                self.attempt.arm()
                value = self._lease()
                self._notify_clock()
            elif kind == "lease":
                value = self._lease()
            elif kind == "lease-ack":
                self.attempt.acknowledge_lease(_integer(frame["revision"]), frame["digest"])
            elif kind == "grant":
                value = self.attempt.grant(frame["name"], _integer(frame["localNs"], 1)).frame()
            elif kind == "complete":
                self.attempt.complete(frame["grantId"])
            elif kind == "cancel":
                self.attempt.cancel(frame["reason"], _integer(frame["status"], 1, 255))
                self._notify_clock()
            elif kind == "admit-rollback":
                self.attempt.admit_rollback()
                value = self._lease()
            elif kind == "prepare-terminal":
                self.attempt.prepare_terminal()
                value = self._lease()
            elif kind == "terminal":
                self.attempt.terminal(_integer(frame["status"], 0, 255))
            send_frame(reply, {
                "ok": True, "attempt": self.attempt.nonce,
                "supervisor": self.identity, "value": value,
            })
            self._notify_clock()
        except SupervisorError as error:
            try:
                send_frame(reply, {
                    "ok": False, "attempt": self.attempt.nonce,
                    "supervisor": self.identity, "reason": str(error),
                })
            except (OSError, SupervisorError):
                pass
            # Invalid/revoked messages cannot buy another grant or reset time.
            if self.attempt.first_reason is None:
                self.attempt.cancel("PROTOCOL_INVALID")
        finally:
            reply.close()

    def _notify_clock(self) -> None:
        watch_end = max(
            (grant.end_ns for grant in self.attempt.grants.values()),
            default=self.attempt.idle_end,
        )
        clock = (self.attempt.hard_end, watch_end)
        if clock == self.last_clock:
            return
        self.last_clock = clock
        if self.relay_alive:
            try:
                send_frame(self.relay, {
                    "kind": "clock", "attempt": self.attempt.nonce,
                    "hardEndNs": self.attempt.hard_end, "watchEndNs": watch_end,
                })
            except OSError:
                self.relay_alive = False
                self.attempt.cancel("TRANSPORT_LOST")

    def _relay_message(self) -> None:
        frame, _ = receive_frame(self.relay)
        if set(frame) != {"kind", "attempt", "signal"} or frame["kind"] != "cancel" or \
                frame["attempt"] != self.attempt.nonce or not isinstance(frame["signal"], str) or \
                frame["signal"] not in {"TERM", "INT", "HUP"}:
            reject()
        number = {"TERM": signal.SIGTERM, "INT": signal.SIGINT, "HUP": signal.SIGHUP}[frame["signal"]]
        self.attempt.cancel(frame["signal"], 128 + number)
        self._notify_clock()

    def _report(self) -> None:
        if self.reported or self.attempt.result is None:
            return
        self.reported = True
        if self.relay_alive:
            try:
                status, reason = self.attempt.result
                send_frame(self.relay, {
                    "kind": "result", "attempt": self.attempt.nonce,
                    "status": status, "reason": reason,
                })
            except OSError:
                self.relay_alive = False

    def run(self) -> int:
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, self._signal)
        send_frame(self.relay, {
            "kind": "hello", "attempt": self.attempt.nonce, "supervisor": self.identity,
            "hardEndNs": self.attempt.hard_end, "watchEndNs": self.attempt.idle_end,
        })
        _wait_readable(self.relay, time.monotonic_ns() + self.attempt.timing.handshake_ns)
        ready, _ = receive_frame(self.relay)
        if ready != {"kind": "ready", "attempt": self.attempt.nonce}:
            reject()
        self.acquire_lock()
        self.spawn()
        while True:
            now = time.monotonic_ns()
            try:
                if self.pending_signals:
                    number = self.pending_signals.pop()
                    self.attempt.cancel(signal.Signals(number).name.removeprefix("SIG"), 128 + number)
                    self._notify_clock()
                self.attempt.poll()
                childless = self.children.reap()
                statuses = self.children.statuses
                if self.worker_pid in statuses:
                    status = statuses[self.worker_pid]
                    if self.worker is not None:
                        self.worker.close()
                        self.worker = None
                    self.worker_pid = None
                    if self.attempt.pending_terminal is None or status != 0:
                        if self.attempt.first_reason is None:
                            self.attempt.cancel("DRILL" if status == 86 else "EXIT", status if 0 < status <= 255 else 1)
                            self._notify_clock()
                        elif not self.attempt.draining and self.attempt.lifecycle != "quiescence-unconfirmed":
                            self.attempt.grants.clear()
                            self.attempt.pending_terminal = None
                            self.attempt._change("draining")
                            self.attempt.begin_drain()
                if childless and self.attempt.pending_terminal is not None:
                    self.attempt.finish_childless()
                    self._report()
                    return self.attempt.result[0]  # type: ignore[index]
                if self.attempt.lifecycle == "quiescence-unconfirmed":
                    self._report()
                    if childless:
                        return 1
                    # Passive keeper: no more signals, commands, state writers,
                    # fsync or Docker calls, and no postdeadline finalization.
                    time.sleep(1)
                    continue
                if self.attempt.draining:
                    if childless:
                        if self.attempt.after_drain() is not None:
                            self.spawn()
                            self._notify_clock()
                    else:
                        self.children.signal_owned(
                            signal.SIGKILL if self.attempt.term_end is not None and now >= self.attempt.term_end
                            else signal.SIGTERM
                        )
                        if self.attempt.drain_end is not None and now >= self.attempt.drain_end:
                            self.attempt.unconfirmed()
                if self.worker_handshake_end is not None and now >= self.worker_handshake_end:
                    self.attempt.cancel("WAIT_EXPIRED")
                with selectors.DefaultSelector() as selector:
                    if self.relay_alive:
                        selector.register(self.relay, selectors.EVENT_READ, "relay")
                    if self.worker is not None:
                        selector.register(self.worker, selectors.EVENT_READ, "worker")
                    for event, _ in selector.select(0.1):
                        try:
                            if event.data == "relay":
                                self._relay_message()
                            else:
                                self._rpc()
                        except (OSError, SupervisorError):
                            if event.data == "relay":
                                self.relay_alive = False
                                self.attempt.cancel("TRANSPORT_LOST")
                                self._notify_clock()
                            elif self.attempt.pending_terminal is None:
                                if self.worker is not None:
                                    self.worker.close()
                                    self.worker = None
                                self.attempt.cancel("PROTOCOL_INVALID")
            except (OSError, SupervisorError):
                self.attempt.cancel("OWNERSHIP_UNCERTAIN")
                self.attempt.unconfirmed()


def relay(root: str, operation: str, arguments: list[str]) -> int:
    if sys.platform != "linux" or os.geteuid() != 0:
        reject("LINUX_ROOT_REQUIRED")
    parent, child = socket_pair()
    pid = os.fork()
    if pid == 0:
        try:
            parent.close()
            os.setsid()
            _close_except({child.fileno()})
            # The passive keeper must not retain SSH/caller output channels.
            null = os.open("/dev/null", os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(null, fd)
            if null > 2:
                os.close(null)
            supervisor = Supervisor(root, operation, arguments, child)
            result = supervisor.run()
            os._exit(result)
        except BaseException:
            os._exit(1)
    child.close()
    # Never retain a caller's inherited deploy-lock description in the relay.
    try:
        os.close(9)
    except OSError as error:
        if error.errno != errno.EBADF:
            raise
    first_signal: list[int] = []

    def initiating(number: int, _frame: Any) -> None:
        if not first_signal:
            first_signal.append(number)

    previous = {number: signal.signal(number, initiating) for number in (
        signal.SIGTERM, signal.SIGINT, signal.SIGHUP,
    )}
    try:
        _wait_readable(parent, time.monotonic_ns() + 5 * NS)
        hello, _ = receive_frame(parent)
        if set(hello) != {"kind", "attempt", "supervisor", "hardEndNs", "watchEndNs"} or hello["kind"] != "hello":
            reject()
        attempt = _nonce(hello["attempt"])
        identity = hello["supervisor"]
        actual = process_identity(pid)
        if identity != {"pid": pid, "startTicks": actual.start, "bootId": boot_id()}:
            reject()
        hard_end = hello["hardEndNs"]
        watch_end = _integer(hello["watchEndNs"], 1)
        send_frame(parent, {"kind": "ready", "attempt": attempt})
        forwarded = False
        while True:
            if first_signal and not forwarded:
                forwarded = True
                send_frame(parent, {
                    "kind": "cancel", "attempt": attempt,
                    "signal": signal.Signals(first_signal[0]).name.removeprefix("SIG"),
                })
            deadline = hard_end if hard_end is not None else watch_end
            if time.monotonic_ns() >= deadline:
                print("schema_guard=QUIESCENCE_UNCONFIRMED", flush=True)
                return 1
            with selectors.DefaultSelector() as selector:
                selector.register(parent, selectors.EVENT_READ)
                events = selector.select(0.1)
            if not events:
                continue
            frame, _ = receive_frame(parent)
            if frame.get("attempt") != attempt:
                reject()
            if frame.get("kind") == "clock" and set(frame) == {"kind", "attempt", "hardEndNs", "watchEndNs"}:
                end = frame["hardEndNs"]
                if end is not None:
                    end = _integer(end, 1)
                if hard_end is not None and end != hard_end:
                    reject()
                hard_end = end
                watch_end = _integer(frame["watchEndNs"], 1)
            elif frame.get("kind") == "result" and set(frame) == {"kind", "attempt", "status", "reason"}:
                if frame["reason"] not in {
                    "COMPLETED", "FAILED", "ROLLED_BACK", "RECOVERY_REQUIRED", "QUIESCENCE_UNCONFIRMED",
                }:
                    reject()
                status = _integer(frame["status"], 0, 255)
                if status == 0 and frame["reason"] != "COMPLETED":
                    reject()
                if status == 86 and frame["reason"] != "ROLLED_BACK":
                    reject()
                print("schema_guard=" + frame["reason"], flush=True)
                return status
            else:
                reject()
    except (OSError, SupervisorError):
        print("schema_guard=QUIESCENCE_UNCONFIRMED", flush=True)
        return 1
    finally:
        parent.close()  # EOF cancels the supervisor, not a false lock-release proof.
        for number, handler in previous.items():
            signal.signal(number, handler)
        os.waitpid(pid, os.WNOHANG)


def _cli() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    entry = commands.add_parser("relay")
    entry.add_argument("--root", required=True)
    entry.add_argument("--operation", choices=sorted(OPERATIONS), required=True)
    entry.add_argument("arguments", nargs=argparse.REMAINDER)
    client = commands.add_parser("client")
    client.add_argument("--root", required=True)
    calls = client.add_subparsers(dest="call", required=True)
    for name in ("hello", "arm", "lease", "admit-rollback", "prepare-terminal"):
        calls.add_parser(name)
    grant = calls.add_parser("grant")
    grant.add_argument("name", choices=sorted(WAIT_NAMES))
    grant.add_argument("seconds")
    complete = calls.add_parser("complete")
    complete.add_argument("grant_id")
    ack = calls.add_parser("lease-ack")
    ack.add_argument("revision", type=int)
    ack.add_argument("digest")
    cancel = calls.add_parser("cancel")
    cancel.add_argument("reason", choices=sorted(FAILURES))
    cancel.add_argument("status", type=int)
    terminal = calls.add_parser("terminal")
    terminal.add_argument("status", type=int)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _cli().parse_args(argv)
    try:
        if args.command == "relay":
            arguments = args.arguments
            if not arguments or arguments[0] != "--":
                reject("CONTROLLER_ARGUMENTS_REQUIRED")
            return relay(args.root, args.operation, arguments[1:])
        client = WorkerClient(args.root)
        try:
            fields: dict[str, Any] = {}
            if args.call == "grant":
                fields = {"name": args.name, "localNs": _seconds(args.seconds)}
            elif args.call == "complete":
                fields = {"grantId": _nonce(args.grant_id)}
            elif args.call == "lease-ack":
                fields = {"revision": args.revision, "digest": args.digest}
            elif args.call == "cancel":
                fields = {"reason": args.reason, "status": args.status}
            elif args.call == "terminal":
                fields = {"status": args.status}
            print(json.dumps(client.request(args.call, **fields), separators=(",", ":"), sort_keys=True))
            return 0
        finally:
            client.close()
    except (SupervisorError, OSError) as error:
        reason = str(error) if isinstance(error, SupervisorError) else "SUPERVISOR_UNAVAILABLE"
        print("schema_guard=" + reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
