#!/usr/bin/env python3
"""Fixed Linux Timepad controller relay, private RPC, and attempt supervisor.

Public entry::

    python3 -B test_vps_timepad_supervisor.py relay --root ROOT \
        --operation deploy -- ORIGINAL_CONTROLLER_ARGUMENTS

The shell executable selected by this module is the sibling controller's four
fixed ``--timepad-private-worker MODE`` entries. Guarded create stages call the
fixed private Python module directly after fork. No RPC supplies argv.
The worker entry must call ``client --root ROOT hello`` before
doing anything else. Environment variables bind the private socket but do not
replace it or FD9. Each shell/helper RPC uses its own SCM_RIGHTS reply socket;
concurrent command substitutions cannot consume one another's replies.

Worker contract (also exposed by WorkerClient):
* Publish/ack the initial ``registered`` lease before ``arm`` immediately
  before PREPARED. Forward-recover charges its clock at supervisor entry,
  including registration, then arms without resetting that clock.
  Its exclusive <=30-second ``recovery-registration`` grant lets the state
  helper validate protected authority/selectors before publishing the initial
  lease. After ack, ``recovery-admission`` grants permit only fixed read-only
  controller calls while registered; neither grant authorizes runtime mutation
  or unresolved old-lease replacement.
  Initial registration ACK reads back the exact successor in a bounded
  read-only child, retaining only its proved acknowledged create completion.
  The event loop imports no caller-supplied completion fields.
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
  returned until kernel ECHILD and a final supervisor-owned durable drained
  revision with worker=null. A worker exit alone is never success.
  A fail-closed worker acknowledges a proved stop with ``terminal 1`` and
  exits zero to indicate cleanup completion; the operation retains its first
  nonzero status. Only a fixed refusal code may cross the public relay, and
  only after the final childless publication, never on unconfirmed cleanup.
* ``cancel REASON STATUS`` revokes forward work. Traps never do rollback.
* ``create-launch`` returns the kernel-observed waiting launcher identity.
  ``create-release`` admits the durable request and resource baseline through
  a fixed read-only helper, then opens its gate once. ``create-result`` never
  renews authority: ready requires the launcher's authenticated local ECHILD
  result and the supervisor's independent exact zero wait, without adopted
  descendants. ``create-completion`` parks only the authenticated controller
  caller chain and refuses surviving publishers/other grants. The sole private
  publisher validates supervisor wait evidence, clears ownedChild and publishes
  receipt/current/lease readbacks before the chain resumes and ACK returns.

Disk publication and semantic rollback/runtime admission belong to the fixed
workers/state helper or sole completion publisher, not this event loop. This module never treats
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
import hashlib
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

from test_vps_timepad_create import (
    Action, CreateContext, CreateDriver, CreateError, RealTransport, Role, Selection,
    Transport, canonical as create_canonical, read_evidence, wait_create, write_evidence,
)

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
    "recovery-registration", "recovery-admission",
})
FAILURES = frozenset({
    "TERM", "INT", "HUP", "EXIT", "DRILL", "WAIT_EXPIRED", "WORK_EXHAUSTED",
    "HARD_DEADLINE", "TRANSPORT_LOST", "PROTOCOL_INVALID", "OWNERSHIP_UNCERTAIN",
    "DESCENDANT_OVERFLOW", "ROLLBACK_REFUSED", "ROLLBACK_FAILED",
    "RECOVERY_RETRY_RUNTIME_FAILED",
})
NONCE = re.compile(r"^[a-f0-9]{32}$")
DIGEST = re.compile(r"^[a-f0-9]{64}$")
SUCCESS_OUTCOMES = {
    "bootstrapped": ("deploy", "ready"),
    "already-initialized": ("deploy", "ready"),
    "already-completed": ("forward-recover", "committed"),
}
REFUSAL_OUTCOMES = {"RECOVERY_RETRY_RUNTIME_FAILED": "forward-recover"}
CREATE_STAGES = frozenset({"release-admission", "execute", "completion-admission"})
CREATE_ATTEMPT = re.compile(r"^[a-f0-9]{32}:[1-9][0-9]{0,19}$")


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


@dataclass
class RecoveryRegistrationAck:
    """One bounded read-only child, not worker-supplied completion evidence."""

    pid: int
    reply: socket.socket
    channel: socket.socket | None
    digest: str
    end_ns: int
    status: int | None = None
    snapshot: dict[str, Any] | None = None


class CreateAttempt:
    """One fixed launcher and one completion; caller assertions never supply waits."""

    def __init__(self, role: str, attempt_id: str, grant: Grant):
        if not isinstance(role, str) or role not in {"initial", "replacement"} or \
                not isinstance(attempt_id, str) or \
                CREATE_ATTEMPT.fullmatch(attempt_id) is None or \
                int(attempt_id.split(":")[1]) >= 1 << 64:
            reject()
        self.role, self.attempt_id, self.grant = role, attempt_id, grant
        self.identity: dict[str, Any] | None = None
        self.request: dict[str, Any] | None = None
        self.request_digest: str | None = None
        self.phase = "waiting"
        self.released = False
        self.result: dict[str, Any] | None = None
        self.wait_status: int | None = None
        self.completion_issued = False

    def bind_request(self, request: dict[str, Any], digest: str, identity: Any) -> None:
        from test_vps_timepad_state import GuardError, create_request_digest, runtime_request

        try:
            request = runtime_request(request)
            if self.phase != "checking-release" or self.released or \
                    request["operation"] != "create" or request["lifecycle"] != "intent" or \
                    request["role"] != self.role or request["executionAttempt"] != self.grant.attempt or \
                    request["childAttemptId"] != self.attempt_id or \
                    request["childIdentity"] != self.identity or identity != self.identity or \
                    create_request_digest(request) != digest:
                reject()
        except GuardError:
            reject()
        self.request, self.request_digest = request, digest

    def release(self) -> None:
        if self.phase != "checking-release" or self.released or self.request is None:
            reject()
        self.released, self.phase = True, "running"

    def observe_result(self, result: dict[str, Any]) -> None:
        if self.phase != "running" or self.result is not None or \
                type(result.get("waitStatus")) is not int or \
                result.get("descendantsDrained") is not True or result != {
            "kind": "create-result", "attempt": self.grant.attempt,
            "requestDigest": self.request_digest, "childIdentity": self.identity,
            "waitStatus": 0, "descendantsDrained": True,
        }:
            reject("OWNERSHIP_UNCERTAIN")
        self.result = result

    def ready(self, *, unexpected_children: bool, now: int) -> bool:
        if self.phase == "ready":
            if unexpected_children or now >= self.grant.end_ns:
                reject("OWNERSHIP_UNCERTAIN")
            return True
        if self.phase != "running" or self.result is None or self.wait_status is None:
            return False
        if self.wait_status != 0 or unexpected_children or now >= self.grant.end_ns:
            reject("OWNERSHIP_UNCERTAIN")
        self.phase = "ready"
        return True

    def begin_completion(self, digest: str, identity: Any) -> None:
        if self.phase != "ready" or self.completion_issued or \
                digest != self.request_digest or identity != self.identity:
            reject()
        self.completion_issued, self.phase = True, "checking-completion"

    def receipt(self) -> dict[str, Any]:
        if self.phase not in {"checking-completion", "publishing", "completed"} or \
                self.wait_status != 0 or self.result is None or self.request is None:
            reject("OWNERSHIP_UNCERTAIN")
        from test_vps_timepad_state import CREATE_COMPLETION_SCHEMA

        return {
            "schema": CREATE_COMPLETION_SCHEMA, "requestDigest": self.request_digest,
            "executionAttempt": self.grant.attempt, "childIdentity": self.identity,
            "resourcesDigest": self.request["resourcesDigest"],
            "resourceRequestDigest": self.request["resourceRequestDigest"],
            "waitStatus": 0, "uncancelled": True, "descendantsDrained": True,
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
        self.rollback_admission_completed = False
        self.recovery_registration_completed = False
        self.grants: dict[str, Grant] = {}
        self.idle_end = self.clock() + timing.idle_ns
        self.drain_end: int | None = None
        self.term_end: int | None = None
        self.cleanup_stop_end: int | None = None
        self.role = "retention-worker" if operation == "retention" else "controller-worker"
        self.pending_terminal: int | None = None
        self.pending_outcome: str | None = None
        self.result: tuple[int, str] | None = None
        self.on_change: Callable[[], None] | None = None
        if operation == "forward-recover":
            self._start_clock()

    def _change(self, lifecycle: str) -> None:
        self.lifecycle = lifecycle
        self.revision += 1
        self.acked_revision = -1
        self.lease_digest = None
        if os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1":
            failure = self.first_reason if self.first_reason in FAILURES else "NONE"
            print(
                f"fixture_timepad_supervisor=attempt_transition lifecycle={lifecycle} "
                f"failure={failure}",
                file=sys.stderr, flush=True,
            )
        if self.on_change is not None:
            self.on_change()

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
        if reason in REFUSAL_OUTCOMES and (
            self.operation != REFUSAL_OUTCOMES[reason]
            or self.role != "controller-worker" or status != 1
        ):
            reject()
        # Repeated signals do not revoke a separately issued rollback grant.
        if self.first_reason is not None:
            return
        if os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1":
            print(
                f"fixture_timepad_supervisor=attempt_cancel reason={reason} "
                f"status={status} lifecycle={self.lifecycle}",
                file=sys.stderr, flush=True,
            )
        self.first_reason, self.first_status = reason, status
        self.arm()
        self.grants.clear()
        self.pending_terminal = None
        self.pending_outcome = None
        self._change("cancel-forward")
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
        if any(grant.name == "recovery-registration" for grant in self.grants.values()):
            reject("WAIT_REFUSED")
        registration = name == "recovery-registration"
        admission = name == "recovery-admission"
        if registration or admission:
            if self.operation != "forward-recover" or self.role != "controller-worker" or \
                    self.lifecycle != "registered" or self.first_reason is not None or \
                    registration and (
                        self.revision != 0 or self.grants or self.recovery_registration_completed
                    ):
                reject("WAIT_REFUSED")
            local_ns = min(local_ns, 30 * NS)
        if name not in {"lease-publish", "recovery-registration"} and \
                self.acked_revision != self.revision:
            reject("LEASE_ACK_REQUIRED")
        if self.operation == "forward-recover" and self.lifecycle == "registered" \
                and name not in {"lease-publish", "recovery-registration", "recovery-admission"}:
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
        if grant.name == "rollback-admission":
            self.rollback_admission_completed = True
        if grant.name == "recovery-registration":
            self.recovery_registration_completed = True
        self.idle_end = self.clock() + self.timing.idle_ns

    def validate_grant(self, grant_id: str, end_ns: int) -> Grant:
        """Read-only helper admission; never renew or recreate a wait."""
        grant = self.grants.get(_nonce(grant_id))
        _integer(end_ns, 1)
        if grant is None or grant.end_ns != end_ns or self.clock() >= end_ns or \
                self.draining or self.lifecycle == "quiescence-unconfirmed" or \
                self.pending_terminal is not None:
            reject("GRANT_REVOKED")
        if grant.name not in {"lease-publish", "recovery-registration"} and \
                self.acked_revision != self.revision:
            reject("GRANT_REVOKED")
        return grant

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
                not self.rollback_admission_completed or \
                self.work_end is None or self.clock() >= self.work_end:
            reject("ROLLBACK_REFUSED")
        self.rollback_admitted = True
        self._change("rolling-back")

    def prepare_terminal(self) -> None:
        if self.grants or self.acked_revision != self.revision:
            reject("TERMINAL_REFUSED")
        if self.lifecycle == "registered":
            reject("TERMINAL_REFUSED")
        if self.role == "rollback-worker" and not self.rollback_admitted:
            reject("TERMINAL_REFUSED")
        if self.lifecycle == "drained":
            return
        self._change("drained")

    def terminal(self, status: int, outcome: str | None = None) -> None:
        _integer(status, 0, 255)
        if outcome is not None and (
            not isinstance(outcome, str) or outcome not in SUCCESS_OUTCOMES
            or SUCCESS_OUTCOMES[outcome][0] != self.operation or status != 0
            or self.role != "controller-worker"
        ):
            reject("TERMINAL_REFUSED")
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
        self.pending_outcome = outcome

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
        if self.lifecycle == "quiescence-unconfirmed":
            self.result = (self.failure_status, "QUIESCENCE_UNCONFIRMED")
            return
        self.grants.clear()
        self.pending_terminal = None
        self.pending_outcome = None
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
    if len(data) > 4096 or not data.endswith(b"\n") or b")" not in data:
        reject("OWNERSHIP_UNCERTAIN")
    try:
        fields = data.rsplit(b")", 1)[1].split()
        parent, start = int(fields[1]), int(fields[19])
        if not 0 <= parent < 1 << 31 or start <= 0:
            reject("OWNERSHIP_UNCERTAIN")
        info = os.stat(f"/proc/{pid}")
        return ProcessIdentity(pid, parent, start, info.st_uid)
    except (IndexError, ValueError):
        reject("OWNERSHIP_UNCERTAIN")


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
        if hasattr(socket, "SO_PASSCRED"):
            endpoint.setsockopt(socket.SOL_SOCKET, socket.SO_PASSCRED, 1)
    return pair


def send_frame(channel: socket.socket, frame: dict[str, Any], fd: int | None = None) -> None:
    data = encode(frame)
    ancillary = [] if fd is None else [
        (socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd])),
    ]
    if channel.sendmsg([data], ancillary) != len(data):
        reject()


def receive_frame(
    channel: socket.socket, *, accept_fd: bool = False,
    peer: list[ProcessIdentity] | None = None,
) -> tuple[dict[str, Any], int | None]:
    data, ancillary, flags, _ = channel.recvmsg(
        MAX_FRAME + 1, socket.CMSG_SPACE(4 * 4) + socket.CMSG_SPACE(12),
    )
    descriptors: list[int] = []
    credentials = None
    try:
        for level, kind, raw in ancillary:
            if level == socket.SOL_SOCKET and kind == getattr(socket, "SCM_CREDENTIALS", -1):
                if credentials is not None or len(raw) != 12:
                    reject()
                credentials = struct.unpack("3i", raw)
                continue
            if level != socket.SOL_SOCKET or kind != socket.SCM_RIGHTS:
                reject()
            values = array.array("i")
            values.frombytes(raw[:len(raw) - len(raw) % values.itemsize])
            descriptors.extend(values)
        if flags & (socket.MSG_TRUNC | socket.MSG_CTRUNC) or len(data) > MAX_FRAME or \
                len(descriptors) != (1 if accept_fd else 0):
            reject()
        frame = decode(data)
        if peer is not None:
            if credentials is None or credentials[2] != os.geteuid():
                reject("PRIVATE_WORKER_REQUIRED")
            actual = process_identity(_integer(credentials[0], 1))
            if actual.uid != credentials[2]:
                reject("PRIVATE_WORKER_REQUIRED")
            peer.append(actual)
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

    def __init__(self, root: str, *, end_ns: int | None = None):
        from test_vps_timepad_state import GuardError, deploy_lock

        self.channel: socket.socket | None = None
        self.end_ns = end_ns
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
            # Fixed read-only admission and completion include their existing
            # bounded helper waits. Polling never changes the attempt clock.
            wait = 45 if kind == "create-completion" else 35 if kind == "create-release" else 5
            end = time.monotonic_ns() + wait * NS
            if kind == "create-driver":
                if self.end_ns is None:
                    reject("PRIVATE_WORKER_REQUIRED")
                end = self.end_ns
            elif self.end_ns is not None:
                end = min(end, self.end_ns)
            _wait_readable(reply, end)
            response, _ = receive_frame(reply)
            if response.get("attempt") != self.attempt or response.get("supervisor") != self.supervisor:
                reject()
            if response.get("ok") is not True:
                reject("PRIVATE_REQUEST_REFUSED")
            return response["value"]
        finally:
            reply.close()
            passed.close()

    def recovery_evidence(self, root: str, arguments: list[str]) -> bytes:
        """Read the single inherited pipe, not an unbounded RPC response."""
        from test_vps_timepad_create import recovery_binding

        if self.end_ns is None:
            reject()
        reply, passed = socket_pair()
        evidence_fd = None
        try:
            assert self.channel is not None
            peer = process_identity(os.getpid())
            send_frame(self.channel, {
                "kind": "recovery-evidence", "attempt": self.attempt, "role": self.role,
            }, passed.fileno())
            passed.close()
            _wait_readable(reply, min(self.end_ns, time.monotonic_ns() + 5 * NS))
            response, evidence_fd = receive_frame(reply, accept_fd=True)
            if response != {
                "ok": True, "attempt": self.attempt, "supervisor": self.supervisor,
                "value": {"evidence": "private-pipe"},
            } or evidence_fd is None:
                reject()
            context = CreateContext(root, Selection.from_arguments(arguments), self.end_ns, Role.INITIAL)
            expected = recovery_binding(context, self.attempt)
            expected["peer"] = peer.frame()
            evidence = read_evidence(evidence_fd, expected, self.end_ns)
            # Cancellation revocation, selectors and frozen input revalidation
            # precede the registered worker's existing state/provider validators.
            if recovery_binding(context, self.attempt) != {key: value for key, value in expected.items() if key != "peer"}:
                reject("GRANT_REVOKED")
            grant = decode(os.environ["TIMEPAD_RECOVERY_EVIDENCE_GRANT"].encode())
            if self.request("validate-grant", grantId=grant["grantId"], endNs=grant["endNs"]) != grant:
                reject("GRANT_REVOKED")
            return evidence
        finally:
            if evidence_fd is not None:
                os.close(evidence_fd)
            reply.close()
            passed.close()

    def close(self) -> None:
        if self.channel is not None:
            self.channel.close()


def _create_environment(
    control: int, attempt: str, identity: dict[str, Any], grant: Grant,
    request_digest: str | None,
) -> dict[str, str]:
    environment = dict(os.environ)
    environment.update({
        "TIMEPAD_CONTROL_FD": str(control), "TIMEPAD_ATTEMPT": attempt,
        "TIMEPAD_SUPERVISOR": encode(identity).decode(),
        "TIMEPAD_WORKER_MODE": "controller-worker",
        "TIMEPAD_CREATE_GRANT": encode(grant.frame()).decode(),
        "TIMEPAD_CREATE_REQUEST_DIGEST": request_digest or "",
    })
    return environment


def _fixed_create_stage(
    stage: str, context: CreateContext, transport: Transport,
    environment: dict[str, str],
) -> dict[str, Any]:
    """Read-only fixed module call; constructor transport survives every fork."""
    if stage not in CREATE_STAGES:
        reject()
    linux_preflight()
    os.environ.update(environment)
    client = WorkerClient(context.state_root, end_ns=context.end_ns)
    try:
        driver = CreateDriver(context, transport, client)
        result = driver.check_stage(
            stage, decode(environment["TIMEPAD_CREATE_GRANT"].encode()),
            environment["TIMEPAD_CREATE_REQUEST_DIGEST"],
        )
        if stage == "execute":
            wait_create(transport.spawn_create(driver.context, (9,)), driver.context)
            return {}
        return result
    except CreateError:
        reject("OWNERSHIP_UNCERTAIN")
    finally:
        client.close()


def _create_launcher(
    channel: socket.socket, identity: dict[str, Any], attempt: str,
    grant: Grant, context: CreateContext, transport: Transport,
    environment: dict[str, str],
) -> None:
    linux_preflight()
    os.setsid()
    observed = process_identity(os.getpid())
    identity = {
        **identity, "pid": observed.pid, "processGroup": observed.pid,
        "startTicks": observed.start, "bootId": boot_id(),
    }
    send_frame(channel, {
        "kind": "create-hello", "attempt": attempt, "childIdentity": identity,
    })
    _wait_readable(channel, grant.end_ns)
    release, _ = receive_frame(channel)
    if set(release) != {"kind", "attempt", "requestDigest", "childIdentity"} or \
            release["kind"] != "create-release" or release["attempt"] != attempt or \
            release["childIdentity"] != identity or \
            not isinstance(release["requestDigest"], str) or \
            DIGEST.fullmatch(release["requestDigest"]) is None:
        reject()
    environment["TIMEPAD_CREATE_REQUEST_DIGEST"] = release["requestDigest"]
    _fixed_create_stage("execute", context, transport, environment)
    # wait_create requires the exact transport child status and kernel ECHILD.
    send_frame(channel, {
        "kind": "create-result", "attempt": attempt,
        "requestDigest": release["requestDigest"], "childIdentity": identity,
        "waitStatus": 0, "descendantsDrained": True,
    })


class Supervisor:
    def __init__(
        self, root: str, operation: str, arguments: list[str], relay: socket.socket,
        *, timing: Timing = Timing(), create_transport: Transport | None = None,
    ):
        linux_preflight()
        self.attempt = Attempt(operation, timing=timing)
        self.root, self.arguments, self.relay = root, arguments, relay
        self.create_transport = RealTransport() if create_transport is None else create_transport
        self.driver_pid: int | None = None
        self.driver_identity: ProcessIdentity | None = None
        self.driver_channel: socket.socket | None = None
        self.driver_rpc: socket.socket | None = None
        self.driver_reply: socket.socket | None = None
        self.driver_result: dict[str, Any] | None = None
        self.driver_status: int | None = None
        self.driver_action: Action | None = None
        self.driver_end: int | None = None
        self.evidence_pid: int | None = None
        self.evidence_used = False
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
        self.completing = False
        self.lease_snapshots: dict[int, dict[str, Any]] = {}
        self.completion_channel: socket.socket | None = None
        self.completion_pid: int | None = None
        self.completion_status: int | None = None
        self.completion_ack: dict[str, Any] | None = None
        self.completion_grant: Grant | None = None
        self.completion_snapshot: dict[str, Any] | None = None
        self.create: CreateAttempt | None = None
        self.create_channel: socket.socket | None = None
        self.create_launcher_rpc: socket.socket | None = None
        self.create_pid: int | None = None
        self.create_pidfd: int | None = None
        self.create_reply: socket.socket | None = None
        self.create_caller: ProcessIdentity | None = None
        self.create_handshake_end: int | None = None
        self.create_helper_pid: int | None = None
        self.create_helper_channel: socket.socket | None = None
        self.create_helper_rpc: socket.socket | None = None
        self.create_helper_identity: ProcessIdentity | None = None
        self.create_helper_status: int | None = None
        self.create_helper_result: dict[str, Any] | None = None
        self.create_helper_stage: str | None = None
        self.create_completion_evidence: dict[str, Any] | None = None
        self.recovery_baseline: dict[str, Any] | None = None
        self.registration_grant: Grant | None = None
        self.registration_ack: RecoveryRegistrationAck | None = None
        self.create_parked: list[tuple[ProcessIdentity, int]] = []
        self.create_park_end: int | None = None
        self.last_create_sequence = 0
        self.attempt.on_change = self._record_lease

    def _signal(self, number: int, _frame: Any) -> None:
        if not self.pending_signals:
            self.pending_signals.append(number)

    def _fixture_diagnostic(self, label: str, **fields: int | bool | str) -> None:
        if os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") != "1":
            return
        allowed = {
            "registration_ack_children",
            "registration_ack_reject",
            "rpc_reject",
        }
        if label not in allowed:
            reject("PROTOCOL_INVALID")
        values = " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
        print(f"fixture_timepad_supervisor={label} {values}".rstrip(), file=sys.stderr, flush=True)

    def _lease(self) -> dict[str, Any]:
        return {
            **self.attempt.lease(), "supervisor": self.identity,
            "worker": self.worker_identity, "workerMode": self.attempt.role,
            "workers": list(self.worker_identities),
            "createCompletion": getattr(self, "create_completion_evidence", None),
        }

    def _record_lease(self) -> None:
        if len(self.lease_snapshots) >= 16 and self.attempt.revision not in self.lease_snapshots:
            reject("PROTOCOL_INVALID")
        self.lease_snapshots[self.attempt.revision] = self._lease()

    def _published(self, revision: int) -> None:
        self.lease_snapshots = {
            key: snapshot for key, snapshot in self.lease_snapshots.items() if key > revision
        }

    def _begin_registration_ack(self, revision: int, digest: str, reply: socket.socket) -> None:
        if (
            revision != 0 or self.attempt.revision != 0
            or self.attempt.lifecycle != "registered" or self.attempt.operation != "forward-recover"
            or not self.attempt.recovery_registration_completed
            or self.attempt.acked_revision != -1 or self.attempt.grants
            or self.registration_ack is not None or self.create_completion_evidence is not None
            or self.recovery_baseline is None
            or self.registration_grant is None
            or not isinstance(digest, str) or DIGEST.fullmatch(digest) is None
        ):
            reject("LEASE_ACK_INVALID")
        assert self.lock_fd is not None and self.attempt.work_end is not None
        end = min(
            self.attempt.clock() + self.attempt.timing.handshake_ns, self.attempt.work_end,
            self.registration_grant.end_ns,
        )
        if self.attempt.clock() >= end:
            reject("LEASE_ACK_INVALID")
        expected = self._lease()
        parent, child = socket_pair()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                response = os.dup(child.fileno())
                if response == 9:
                    response = os.dup(response)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, response})
                from test_vps_timepad_state import _read_recovery_registration_snapshot

                snapshot = _read_recovery_registration_snapshot(
                    self.root, expected, digest, self.recovery_baseline, deploy_lock_fd=9,
                )
                with socket.socket(fileno=response) as channel:
                    send_frame(channel, {"lease": snapshot})
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        self.registration_ack = RecoveryRegistrationAck(pid, reply, parent, digest, end)

    def _registration_response(self) -> None:
        from test_vps_timepad_state import GuardError, _execution_lease

        registration = self.registration_ack
        assert registration is not None and registration.channel is not None
        response, _ = receive_frame(registration.channel)
        if set(response) != {"lease"} or not isinstance(response["lease"], dict):
            reject("LEASE_ACK_INVALID")
        try:
            registration.snapshot = _execution_lease(response["lease"])
        except GuardError:
            reject("LEASE_ACK_INVALID")
        registration.channel.close()
        registration.channel = None

    def _tick_registration(self, statuses: dict[int, int]) -> None:
        registration = self.registration_ack
        if registration is None:
            return
        if self.pending_signals:
            number = self.pending_signals.pop()
            self.attempt.cancel(signal.Signals(number).name.removeprefix("SIG"), 128 + number)
            self._notify_clock()
        if registration.pid in statuses:
            registration.status = statuses[registration.pid]
        if self.attempt.first_reason is not None or self.attempt.lifecycle != "registered":
            if registration.channel is not None:
                registration.channel.close()
            registration.reply.close()
            self.registration_ack = None
            return  # Cancellation drains the read-only child with the worker.
        if registration.status not in (None, 0) or self.attempt.clock() >= registration.end_ns:
            reject("LEASE_ACK_INVALID")
        if registration.status is None or registration.snapshot is None:
            return
        snapshot = registration.snapshot
        expected = self._lease()
        if (
            self.attempt.grants or self.attempt.acked_revision != -1
            or set(snapshot) != set(expected)
            or any(snapshot[key] != expected[key] for key in expected if key != "createCompletion")
            or hashlib.sha256(encode(snapshot)).hexdigest() != registration.digest
        ):
            reject("LEASE_ACK_INVALID")
        self.children.refresh()
        if any(pid != self.worker_pid for pid in self.children.tracked):
            self._fixture_diagnostic(
                "registration_ack_children",
                extra_count=sum(pid != self.worker_pid for pid in self.children.tracked),
                evidence_tracked=self.evidence_pid in self.children.tracked,
                evidence_status_known=self.evidence_pid in self.children.statuses,
                create_tracked=self.create_pid in self.children.tracked,
                helper_tracked=self.create_helper_pid in self.children.tracked,
            )
            reject("OWNERSHIP_UNCERTAIN")
        self.create_completion_evidence = snapshot["createCompletion"]
        self._record_lease()
        self.attempt.acknowledge_lease(0, registration.digest)
        self._published(0)
        send_frame(registration.reply, {
            "ok": True, "attempt": self.attempt.nonce,
            "supervisor": self.identity, "value": {},
        })
        registration.reply.close()
        self.registration_ack = None

    def acquire_lock(self) -> None:
        parent, child = socket_pair()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                _close_except({child.fileno()})
                from test_vps_timepad_state import (
                    _canonical, _read_execution_lease_locked, _read_guard_locked, deploy_lock,
                )
                context = deploy_lock(self.root)
                fd = context.__enter__()
                frame: dict[str, Any] = {"kind": "lock", "attempt": self.attempt.nonce}
                if self.attempt.operation == "forward-recover":
                    previous = _read_execution_lease_locked(self.root)
                    frame["recoveryBaseline"] = {
                        "lease": previous,
                        "currentDigest": (
                            hashlib.sha256(_canonical(_read_guard_locked(self.root)[1])).hexdigest()
                            if previous is not None else None
                        ),
                    }
                # Do not invoke __exit__: LOCK_UN would unlock the transferred OFD.
                send_frame(child, frame, fd)
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
            expected = {"kind", "attempt"}
            if self.attempt.operation == "forward-recover":
                expected.add("recoveryBaseline")
            if set(frame) != expected or frame["kind"] != "lock" or frame["attempt"] != self.attempt.nonce:
                if fd is not None:
                    os.close(fd)
                reject()
            assert fd is not None
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
                os.close(fd)
                reject("DEPLOY_LOCK_INVALID")
            self.lock_fd = fd
            if self.attempt.operation == "forward-recover":
                self.recovery_baseline = frame["recoveryBaseline"]
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
        self._record_lease()

    def _create_authority(self, *, pending_lease: bool = False) -> None:
        if self.pending_signals:
            number = self.pending_signals.pop()
            self.attempt.cancel(signal.Signals(number).name.removeprefix("SIG"), 128 + number)
            self._notify_clock()
        if self.attempt.role != "controller-worker" or self.attempt.lifecycle != "armed" or \
                self.attempt.first_reason is not None or \
                (not pending_lease and self.attempt.acked_revision != self.attempt.revision) or \
                self.attempt.work_end is None or self.attempt.clock() >= self.attempt.work_end:
            reject("GRANT_REVOKED")

    def _create_peer_chain(self, peer: ProcessIdentity) -> list[ProcessIdentity]:
        """Authenticate the sender's kernel ancestry, not frame-supplied PIDs."""
        if self.worker_identity is None or self.worker_pid is None:
            reject("PRIVATE_WORKER_REQUIRED")
        chain = []
        for _ in range(MAX_CHILDREN):
            chain.append(peer)
            if peer.uid != os.geteuid():
                reject("PRIVATE_WORKER_REQUIRED")
            if self.driver_pid is not None and peer.pid == self.driver_pid:
                if peer != self.driver_identity:
                    reject("PRIVATE_WORKER_REQUIRED")
                return chain
            if peer.pid == self.worker_pid:
                if lease_identity(peer) != self.worker_identity:
                    reject("PRIVATE_WORKER_REQUIRED")
                return chain
            if peer.parent <= 1 or peer.parent == os.getpid():
                break
            peer = process_identity(peer.parent)
        reject("PRIVATE_WORKER_REQUIRED")

    def _create_internal_grant(self, name: str, bound_ns: int) -> Grant:
        self._create_authority()
        now = self.attempt.clock()
        assert self.attempt.work_end is not None
        end = min(now + bound_ns, self.attempt.work_end)
        grant = Grant(secrets.token_hex(16), name, end, self.attempt.nonce, self.attempt.role)
        if end <= now or len(self.attempt.grants) >= MAX_GRANTS:
            reject("WAIT_REFUSED")
        self.attempt.grants[grant.grant_id] = grant
        return grant

    def _create_reply(self, value: dict[str, Any]) -> None:
        if self.create_reply is None:
            reject()
        try:
            send_frame(self.create_reply, {
                "ok": True, "attempt": self.attempt.nonce,
                "supervisor": self.identity, "value": value,
            })
        finally:
            self.create_reply.close()
            self.create_reply = None

    def _driver_context(self, role: Role, end: int) -> CreateContext:
        return CreateContext(self.root, Selection.from_arguments(self.arguments), end, role)

    def _launch_driver(self, action: str, role: str, reply: socket.socket, peer: ProcessIdentity) -> None:
        if self.pending_signals:
            number = self.pending_signals.pop()
            self.attempt.cancel(signal.Signals(number).name.removeprefix("SIG"), 128 + number)
            self._notify_clock()
        try:
            selected, selected_role = Action(action), Role(role)
        except ValueError:
            reject()
        self._create_peer_chain(peer)
        if self.driver_pid is not None or self.evidence_pid is not None or self.attempt.grants or \
                self.attempt.role != "controller-worker" or self.attempt.first_reason is not None or \
                self.attempt.acked_revision != self.attempt.revision or \
                self.create is not None and self.create.phase != "completed":
            reject("WAIT_REFUSED")
        if selected in {Action.CREATE, Action.RECONCILE_BOUND, Action.PUBLISH_PREPARED}:
            self._create_authority()
        elif self.attempt.lifecycle not in {"registered", "armed"}:
            reject("GRANT_REVOKED")
        if selected == Action.ADMIT_TARGET and self.attempt.operation != "deploy" or \
                selected == Action.PUBLISH_PREPARED and self.attempt.operation != "deploy":
            reject()
        now = self.attempt.clock()
        end = self.attempt.work_end if selected in {Action.CREATE, Action.RECONCILE_BOUND} else now + 30 * NS
        if self.attempt.work_end is not None:
            end = min(end, self.attempt.work_end)
        if end is None or end <= now:
            reject("WAIT_EXPIRED")
        context = self._driver_context(selected_role, end)
        parent, child = socket_pair()
        rpc, control = socket_pair()
        assert self.lock_fd is not None
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                rpc.close()
                control_fd = os.dup(control.fileno())
                if control_fd == 9:
                    control_fd = os.dup(control_fd)
                response = os.dup(child.fileno())
                if response == 9:
                    response = os.dup(response)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, control_fd, response})
                linux_preflight()
                os.environ.update({
                    "TIMEPAD_CONTROL_FD": str(control_fd), "TIMEPAD_ATTEMPT": self.attempt.nonce,
                    "TIMEPAD_SUPERVISOR": encode(self.identity).decode(), "TIMEPAD_WORKER_MODE": "controller-worker",
                })
                client = WorkerClient(self.root, end_ns=end)
                try:
                    result = CreateDriver(context, self.create_transport, client).run(selected).frame()
                finally:
                    client.close()
                with socket.socket(fileno=response) as channel:
                    send_frame(channel, result)
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        control.close()
        self.driver_pid, self.driver_identity = pid, process_identity(pid)
        self.driver_channel, self.driver_rpc, self.driver_reply = parent, rpc, reply
        self.driver_action, self.driver_end = selected, end
        self.driver_status = self.driver_result = None
        self._notify_clock()

    def _driver_response(self) -> None:
        assert self.driver_channel is not None and self.driver_action is not None
        if self.driver_result is not None:
            reject()
        result, _ = receive_frame(self.driver_channel)
        if result.get("action") != self.driver_action.value or \
                not {"action", "modelDigest", "toolingDigest"} <= result.keys() or \
                result.keys() - {"action", "modelDigest", "toolingDigest", "containerId", "configHash", "preparedProofDigest"} or \
                any(not isinstance(value, str) or DIGEST.fullmatch(value) is None
                    for key, value in result.items() if key != "action"):
            reject()
        self.driver_result = result
        self.driver_channel.close()
        self.driver_channel = None

    def _tick_driver(self, statuses: dict[int, int]) -> None:
        if self.evidence_pid in statuses:
            if statuses[self.evidence_pid] != 0:
                reject("OWNERSHIP_UNCERTAIN")
            self.evidence_pid = None
        if self.driver_pid is None:
            return
        if self.driver_pid in statuses:
            self.driver_status = statuses[self.driver_pid]
        if self.attempt.first_reason is not None:
            if self.driver_reply is not None:
                self.driver_reply.close()
                self.driver_reply = None
            if self.driver_status is not None:
                for channel in (self.driver_rpc, self.driver_channel):
                    if channel is not None:
                        channel.close()
                self.driver_pid = self.driver_identity = self.driver_rpc = self.driver_channel = None
                self.driver_action = self.driver_end = self.driver_status = self.driver_result = None
            return
        if self.driver_status not in (None, 0) or self.driver_end is None or self.attempt.clock() >= self.driver_end:
            reject("OWNERSHIP_UNCERTAIN")
        if self.driver_status is None or self.driver_result is None:
            return
        if self.attempt.grants or self.create is not None and self.create.phase != "completed":
            reject("OWNERSHIP_UNCERTAIN")
        self.children.refresh()
        if any(pid != self.worker_pid for pid in self.children.tracked):
            reject("OWNERSHIP_UNCERTAIN")
        assert self.driver_reply is not None
        send_frame(self.driver_reply, {
            "ok": True, "attempt": self.attempt.nonce, "supervisor": self.identity, "value": self.driver_result,
        })
        self.driver_reply.close()
        if self.driver_rpc is not None:
            self.driver_rpc.close()
        self.driver_pid = self.driver_identity = self.driver_reply = self.driver_rpc = None
        self.driver_action = self.driver_end = self.driver_status = self.driver_result = None

    def _launch_recovery_evidence(self, reply: socket.socket, peer: ProcessIdentity) -> None:
        if self.pending_signals:
            number = self.pending_signals.pop()
            self.attempt.cancel(signal.Signals(number).name.removeprefix("SIG"), 128 + number)
            self._notify_clock()
        self._create_peer_chain(peer)
        grant = self.registration_grant
        if self.evidence_used or self.evidence_pid is not None or self.driver_pid is not None or \
                self.attempt.operation != "forward-recover" or self.attempt.lifecycle != "registered" or \
                self.attempt.first_reason is not None or grant is None or \
                set(self.attempt.grants) != {grant.grant_id}:
            reject("GRANT_REVOKED")
        self.attempt.validate_grant(grant.grant_id, grant.end_ns)
        context = self._driver_context(Role.INITIAL, grant.end_ns)
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC | os.O_NONBLOCK)
        assert self.lock_fd is not None
        pid = os.fork()
        if pid == 0:
            try:
                os.close(read_fd)
                output = os.dup(write_fd)
                if output == 9:
                    output = os.dup(output)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, output})
                linux_preflight()
                # Evidence collection has no authenticated mutation channel.
                # The bound peer consumes it using the existing registration
                # grant and existing state/provider validators.
                class EvidenceClient:
                    attempt = self.attempt.nonce
                binding, evidence = CreateDriver(context, self.create_transport, EvidenceClient()).recovery_evidence()
                binding["peer"] = peer.frame()
                write_evidence(output, binding, evidence, context)
                os.close(output)
                os._exit(0)
            except BaseException:
                os._exit(1)
        os.close(write_fd)
        self.evidence_pid, self.evidence_used = pid, True
        try:
            send_frame(reply, {
                "ok": True, "attempt": self.attempt.nonce, "supervisor": self.identity,
                "value": {"evidence": "private-pipe"},
            }, read_fd)
        finally:
            os.close(read_fd)

    def _launch_create(self, role: str, attempt_id: str) -> None:
        if (self.create is not None and self.create.phase != "completed") or self.attempt.grants:
            reject("WAIT_REFUSED")
        grant = self._create_internal_grant("create-execute", 240 * NS)
        create = CreateAttempt(role, attempt_id, grant)
        if self.create is not None and (
            self.create.role != "initial" or role != "replacement"
            or int(attempt_id.split(":")[1]) <= int(self.create.attempt_id.split(":")[1])
        ):
            reject()
        self.create = create
        parent, child = socket_pair()
        rpc, control = socket_pair()
        assert self.lock_fd is not None
        seed = {
            "attemptId": attempt_id,
            "commandDigest": hashlib.sha256(encode({
                "module": "test_vps_timepad_create", "action": "fixed-no-start-create", "role": role,
            })).hexdigest(),
        }
        context = self._driver_context(Role(role), grant.end_ns)
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                rpc.close()
                control_fd = os.dup(control.fileno())
                if control_fd == 9:
                    control_fd = os.dup(control_fd)
                result_fd = os.dup(child.fileno())
                if result_fd == 9:
                    result_fd = os.dup(result_fd)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, result_fd, control_fd})
                environment = _create_environment(
                    control_fd, self.attempt.nonce, self.identity, grant, None,
                )
                with socket.socket(fileno=result_fd) as channel:
                    _create_launcher(
                        channel, seed, self.attempt.nonce, grant, context, self.create_transport, environment,
                    )
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        control.close()
        self.create_channel, self.create_launcher_rpc = parent, rpc
        self.create_pid = pid
        observed = process_identity(pid)
        self.create_pidfd = os.pidfd_open(pid, 0)
        if process_identity(pid) != observed or observed.parent != os.getpid():
            reject("OWNERSHIP_UNCERTAIN")
        create.identity = {
            **seed, "pid": pid, "processGroup": pid,
            "bootId": boot_id(), "startTicks": observed.start,
        }
        self.create_handshake_end = min(
            self.attempt.clock() + self.attempt.timing.handshake_ns, grant.end_ns,
        )

    def _create_message(self) -> None:
        assert self.create_channel is not None and self.create is not None
        frame, _ = receive_frame(self.create_channel)
        create = self.create
        if self.create_handshake_end is not None:
            if frame != {
                "kind": "create-hello", "attempt": self.attempt.nonce,
                "childIdentity": create.identity,
            } or self.attempt.clock() >= self.create_handshake_end or \
                    os.getpgid(self.create_pid) != self.create_pid:
                reject("OWNERSHIP_UNCERTAIN")
            self.create_handshake_end = None
            self._create_reply({"childIdentity": create.identity})
        else:
            create.observe_result(frame)
            self.create_channel.close()
            self.create_channel = None

    def _spawn_create_helper(self, stage: str) -> None:
        assert self.create is not None and self.lock_fd is not None
        if self.create_helper_pid is not None:
            reject("OWNERSHIP_UNCERTAIN")
        parent, child = socket_pair()
        rpc, control = socket_pair()
        create = self.create
        grant = create.grant
        snapshot = self._lease()
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                rpc.close()
                control_fd = os.dup(control.fileno())
                if control_fd == 9:
                    control_fd = os.dup(control_fd)
                result_fd = os.dup(child.fileno())
                if result_fd == 9:
                    result_fd = os.dup(result_fd)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, control_fd, result_fd})
                environment = _create_environment(
                    control_fd, self.attempt.nonce, self.identity, grant, create.request_digest,
                )
                os.environ.update(environment)
                if stage == "publish":
                    result = self._publish_create(snapshot, grant)
                else:
                    result = _fixed_create_stage(
                        stage, self._driver_context(Role(create.role), min(grant.end_ns, time.monotonic_ns() + 30 * NS)),
                        self.create_transport, environment,
                    )
                with socket.socket(fileno=result_fd) as channel:
                    send_frame(channel, result)
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        control.close()
        self.create_helper_pid = pid
        self.create_helper_identity = process_identity(pid)
        self.create_helper_stage = stage
        self.create_helper_status = self.create_helper_result = None
        self.create_helper_channel, self.create_helper_rpc = parent, rpc

    def _publish_create(self, snapshot: dict[str, Any], grant: Grant) -> dict[str, Any]:
        """Only this authenticated fork publishes child clear/receipt/current/ACK."""
        from test_vps_timepad_state import (
            ExecutionGrant, publish_create_completion, publish_execution_lease,
        )

        assert self.create is not None
        receipt = self.create.receipt()
        encoded = encode(receipt)
        acknowledgment = publish_execution_lease(self.root, snapshot, deploy_lock_fd=9)
        # Advance the supervisor's authoritative snapshot only after readback.
        client = WorkerClient(self.root)
        try:
            client.request("create-publisher-lease-ack", **acknowledgment)
            result = publish_create_completion(
                self.root, request_digest=self.create.request_digest,
                supervisor_wait_evidence=encoded,
                deploy_lock_fd=9,
                execution_grant=ExecutionGrant(grant.attempt, grant.grant_id, grant.end_ns),
            )
            next_snapshot = client.request("create-publisher-ack-intent")
            acknowledgment = publish_execution_lease(self.root, next_snapshot, deploy_lock_fd=9)
            client.request("create-publisher-lease-ack", **acknowledgment)
            return result
        finally:
            client.close()

    def _create_helper_response(self) -> None:
        assert self.create_helper_channel is not None
        if self.create_helper_result is not None:
            reject()
        self.create_helper_result, _ = receive_frame(self.create_helper_channel)
        self.create_helper_channel.close()
        self.create_helper_channel = None

    def _create_private_rpc(self, channel: socket.socket, *, publisher: bool) -> None:
        peers: list[ProcessIdentity] = []
        frame, fd = receive_frame(channel, accept_fd=True, peer=peers)
        assert fd is not None and self.create is not None
        with socket.socket(fileno=fd) as reply:
            reply.setblocking(False)
            if reply.family != socket.AF_UNIX or reply.type != socket.SOCK_SEQPACKET or \
                    frame.get("attempt") != self.attempt.nonce or \
                    frame.get("role") != "controller-worker":
                reject()
            self._create_authority(pending_lease=publisher and self.create_helper_stage == "publish")
            if self.attempt.clock() >= self.create.grant.end_ns or \
                    self.attempt.grants.get(self.create.grant.grant_id) != self.create.grant:
                reject("GRANT_REVOKED")
            peer = peers[0]
            if publisher and self.create_helper_stage == "publish" and \
                    peer != self.create_helper_identity:
                reject("PRIVATE_WORKER_REQUIRED")
            root_pid = self.create_helper_pid if publisher else self.create_pid
            for _ in range(MAX_CHILDREN):
                if peer.pid == root_pid:
                    break
                if peer.parent == os.getpid() or peer.parent <= 1:
                    reject("PRIVATE_WORKER_REQUIRED")
                peer = process_identity(peer.parent)
            else:
                reject("PRIVATE_WORKER_REQUIRED")
            if publisher and self.create_helper_identity != peer or not publisher and (
                self.create.identity is None or peer.start != self.create.identity["startTicks"]
            ):
                reject("PRIVATE_WORKER_REQUIRED")
            kind = frame.get("kind")
            base = {"kind", "attempt", "role"}
            value: dict[str, Any] = {}
            if kind == "hello" and set(frame) == base:
                value = self._lease()
            elif kind == "lease" and set(frame) == base:
                value = self._lease()
            elif kind == "validate-grant" and set(frame) == base | {"grantId", "endNs"}:
                grant = self.create.grant
                if frame["grantId"] != grant.grant_id or frame["endNs"] != grant.end_ns or \
                        self.attempt.clock() >= grant.end_ns or \
                        self.attempt.grants.get(grant.grant_id) != grant:
                    reject("GRANT_REVOKED")
                value = grant.frame()
            elif publisher and self.create_helper_stage == "publish" and \
                    kind == "create-publisher-lease-ack" and \
                    set(frame) == base | {"revision", "digest"}:
                revision = _integer(frame["revision"])
                self.attempt.acknowledge_lease(revision, frame["digest"])
                self._published(revision)
            elif publisher and self.create_helper_stage == "publish" and \
                    kind == "create-publisher-ack-intent" and set(frame) == base:
                if self.create_completion_evidence is None or \
                        self.create_completion_evidence["acknowledged"] or \
                        self.attempt.acked_revision != self.attempt.revision:
                    reject()
                self.create_completion_evidence = dict(self.create_completion_evidence, acknowledged=True)
                self.attempt._change("armed")
                value = self._lease()
            else:
                reject()
            send_frame(reply, {
                "ok": True, "attempt": self.attempt.nonce,
                "supervisor": self.identity, "value": value,
            })

    def _park_create_controller(self, peer: ProcessIdentity) -> None:
        """Park just the authenticated caller chain; any other writer refuses."""
        assert self.create is not None
        chain = self._create_peer_chain(peer)
        self.create_park_end = min(
            self.attempt.clock() + self.attempt.timing.handshake_ns, self.create.grant.end_ns,
        )
        for identity in reversed(chain):
            pidfd = os.pidfd_open(identity.pid, 0)
            try:
                if process_identity(identity.pid) != identity:
                    reject("OWNERSHIP_UNCERTAIN")
                signal.pidfd_send_signal(pidfd, signal.SIGSTOP)
            except BaseException:
                os.close(pidfd)
                raise
            self.create_parked.append((identity, pidfd))

    def _create_controller_parked(self) -> bool:
        assert self.create is not None and self.worker_pid is not None
        allowed = {identity.pid for identity, _ in self.create_parked}
        for identity, _ in self.create_parked:
            if process_identity(identity.pid) != identity:
                reject("OWNERSHIP_UNCERTAIN")
            with open(f"/proc/{identity.pid}/stat", "rb", buffering=0) as source:
                data = source.read(4097)
            if len(data) > 4096 or b")" not in data:
                reject("OWNERSHIP_UNCERTAIN")
            if data.rsplit(b")", 1)[1].split()[0] != b"T":
                return False
            with open(f"/proc/{identity.pid}/task/{identity.pid}/children", "rb", buffering=0) as source:
                raw = source.read(8193)
            if len(raw) > 8192:
                reject("DESCENDANT_OVERFLOW")
            descendants = {int(value) for value in raw.split()}
            if not descendants <= allowed:
                # An old publisher still exists, or the controller has an
                # unaccounted descendant. No filesystem publisher may overlap.
                reject("OWNERSHIP_UNCERTAIN")
        return True

    def _resume_create_controller(self, *, cancel: bool) -> None:
        for identity, pidfd in self.create_parked:
            try:
                if process_identity(identity.pid) != identity:
                    reject("OWNERSHIP_UNCERTAIN")
                signal.pidfd_send_signal(pidfd, signal.SIGKILL if cancel else signal.SIGCONT)
            except (FileNotFoundError, ProcessLookupError):
                pass
            finally:
                os.close(pidfd)
        self.create_parked.clear()
        self.create_park_end = None

    def _create_rpc(
        self, kind: str, frame: dict[str, Any], reply: socket.socket, peer: ProcessIdentity,
    ) -> dict[str, Any] | None:
        self._create_authority()
        self._create_peer_chain(peer)
        if self.create_reply is not None:
            reject()
        if kind == "create-launch":
            self._launch_create(frame["createRole"], frame["attemptId"])
            self.create_reply = reply
            return None
        create = self.create
        if create is None or not isinstance(frame["requestDigest"], str) or \
                DIGEST.fullmatch(frame["requestDigest"]) is None:
            reject()
        if kind == "create-release":
            if create.phase != "waiting" or self.create_handshake_end is not None or \
                    frame["childIdentity"] != create.identity or \
                    set(self.attempt.grants) != {create.grant.grant_id}:
                reject()
            create.request_digest = frame["requestDigest"]
            create.phase = "checking-release"
            self.create_reply = reply
            self._spawn_create_helper("release-admission")
            return None
        if frame["requestDigest"] != create.request_digest:
            reject()
        if kind == "create-result":
            if create.phase not in {"running", "ready"}:
                reject()
            return {"status": "ready" if create.phase == "ready" else "pending"}
        if kind == "create-completion":
            if set(self.attempt.grants) != {create.grant.grant_id}:
                # Revoke rather than overlap a competing grant/publisher.
                self.attempt.grants.clear()
                reject("OWNERSHIP_UNCERTAIN")
            create.begin_completion(frame["requestDigest"], frame["childIdentity"])
            self.create_reply = reply
            self._park_create_controller(peer)
            return None
        reject()

    def _tick_create(self, statuses: dict[int, int]) -> None:
        create = self.create
        if create is None:
            return
        if self.create_pid in statuses:
            create.wait_status = statuses[self.create_pid]
            if self.create_pidfd is not None:
                os.close(self.create_pidfd)
                self.create_pidfd = None
            if self.create_launcher_rpc is not None:
                self.create_launcher_rpc.close()
                self.create_launcher_rpc = None
            if create.wait_status != 0:
                reject("OWNERSHIP_UNCERTAIN")
        if self.create_helper_pid in statuses:
            self.create_helper_status = statuses[self.create_helper_pid]
            if self.create_helper_rpc is not None:
                self.create_helper_rpc.close()
                self.create_helper_rpc = None
            if self.create_helper_status != 0:
                reject("OWNERSHIP_UNCERTAIN")
        if self.attempt.first_reason is not None or self.attempt.lifecycle != "armed":
            if self.create_parked:
                self._resume_create_controller(cancel=True)
            if self.create_reply is not None:
                self.create_reply.close()
                self.create_reply = None
            for name in ("create_channel", "create_launcher_rpc", "create_helper_rpc",
                         "create_helper_channel"):
                channel = getattr(self, name)
                if channel is not None:
                    channel.close()
                    setattr(self, name, None)
            return
        if create.phase == "completed":
            return
        now = self.attempt.clock()
        if self.create_handshake_end is not None and now >= self.create_handshake_end:
            reject("OWNERSHIP_UNCERTAIN")
        self.children.refresh()
        expected = {self.worker_pid}
        if self.driver_pid is not None:
            expected.add(self.driver_pid)
        if create.wait_status is None:
            expected.add(self.create_pid)
        if self.create_helper_pid is not None and self.create_helper_status is None:
            expected.add(self.create_helper_pid)
        unexpected = any(pid not in expected for pid in self.children.tracked)
        if unexpected:
            reject("OWNERSHIP_UNCERTAIN")
        create.ready(unexpected_children=unexpected, now=now)
        if self.create_park_end is not None:
            if now >= self.create_park_end:
                reject("OWNERSHIP_UNCERTAIN")
            if self._create_controller_parked():
                self.create_park_end = None
                self._spawn_create_helper("completion-admission")
        if self.create_helper_pid is None or self.create_helper_status is None or \
                self.create_helper_result is None:
            return
        stage, result = self.create_helper_stage, self.create_helper_result
        self.create_helper_pid = self.create_helper_identity = None
        if self.create_helper_rpc is not None:
            self.create_helper_rpc.close()
            self.create_helper_rpc = None
        if stage in {"release-admission", "completion-admission"}:
            self._create_authority()
            self.attempt.validate_grant(create.grant.grant_id, create.grant.end_ns)
            if set(result) != {"request"}:
                reject()
            if stage == "release-admission":
                create.bind_request(result["request"], create.request_digest, create.identity)
                assert create.request is not None
                if create.request["sequence"] <= self.last_create_sequence:
                    reject()
                self.last_create_sequence = create.request["sequence"]
                create.release()
                assert self.create_channel is not None
                send_frame(self.create_channel, {
                    "kind": "create-release", "attempt": self.attempt.nonce,
                    "requestDigest": create.request_digest, "childIdentity": create.identity,
                })
                self._create_reply({})
            else:
                if result["request"] != create.request or not self._create_controller_parked():
                    reject("OWNERSHIP_UNCERTAIN")
                del self.attempt.grants[create.grant.grant_id]
                create.grant = self._create_internal_grant("create-completion", 10 * NS)
                create.phase = "publishing"
                receipt = create.receipt()
                self.create_completion_evidence = {
                    **{key: value for key, value in receipt.items() if key != "schema"},
                    "receiptDigest": hashlib.sha256(encode(receipt)).hexdigest(),
                    "acknowledged": False,
                }
                self.attempt._change("armed")
                self._spawn_create_helper("publish")
        elif stage == "publish":
            self._create_authority()
            if self.create_completion_evidence is None or \
                    self.create_completion_evidence["acknowledged"] is not True or \
                    self.attempt.acked_revision != self.attempt.revision or result != {
                        "receiptDigest": self.create_completion_evidence["receiptDigest"],
                        "sequence": create.request["sequence"],
                    }:
                reject()
            self.attempt.complete(create.grant.grant_id)
            create.phase = "completed"
            self._resume_create_controller(cancel=False)
            self._create_reply(result)
        else:
            reject()

    def _rpc(self, channel: socket.socket | None = None, *, driver: bool = False) -> None:
        channel = self.worker if channel is None else channel
        assert channel is not None
        peers: list[ProcessIdentity] = []
        frame, passed = receive_frame(channel, accept_fd=True, peer=peers)
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
                "validate-grant": {"grantId", "endNs"},
                "admit-rollback": set(), "prepare-terminal": set(), "terminal": {"status"},
                "create-launch": {"createRole", "attemptId"},
                "create-release": {"requestDigest", "childIdentity"},
                "create-result": {"requestDigest"},
                "create-completion": {"requestDigest", "childIdentity"},
                "create-driver": {"action", "createRole"},
                "recovery-evidence": set(),
            }
            if kind == "terminal" and "outcome" in frame:
                schemas["terminal"] = {"status", "outcome"}
            if not isinstance(kind, str) or kind not in schemas or \
                    set(frame) != {"kind", "attempt", "role"} | schemas[kind]:
                reject()
            if self.attempt.draining or self.attempt.lifecycle == "quiescence-unconfirmed":
                reject("GRANT_REVOKED")
            if self.attempt.pending_terminal is not None:
                reject("TERMINAL_REFUSED")
            if self.create_parked:
                reject("GRANT_REVOKED")
            if self.registration_ack is not None:
                reject("LEASE_ACK_INVALID")
            if driver:
                chain = self._create_peer_chain(peers[0])
                if self.driver_pid is None or chain[-1] != self.driver_identity or \
                        kind not in {
                            "lease", "grant", "complete", "validate-grant",
                            "create-launch", "create-release", "create-result", "create-completion",
                        }:
                    reject("PRIVATE_WORKER_REQUIRED")
            elif self.driver_pid is not None and kind != "cancel":
                reject("GRANT_REVOKED")
            if kind in {"create-launch", "create-release", "create-result", "create-completion"} and (
                not driver or self.driver_action != Action.CREATE
            ):
                reject("PRIVATE_WORKER_REQUIRED")
            value: dict[str, Any] = {}
            if not self.worker_hello and kind != "hello":
                reject("PRIVATE_WORKER_REQUIRED")
            if kind == "create-driver":
                if driver:
                    reject()
                self._launch_driver(frame["action"], frame["createRole"], reply, peers[0])
                return
            elif kind == "recovery-evidence":
                if driver:
                    reject()
                self._launch_recovery_evidence(reply, peers[0])
                return
            elif kind.startswith("create-"):
                value = self._create_rpc(kind, frame, reply, peers[0])
                if value is None:
                    return
            elif kind == "hello":
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
                if self.attempt.grants:
                    reject("WAIT_REFUSED")
                self.attempt.arm()
                value = self._lease()
                self._notify_clock()
            elif kind == "lease":
                value = self._lease()
            elif kind == "lease-ack":
                revision = _integer(frame["revision"])
                if self.registration_grant is not None and self.attempt.revision == 0:
                    self._begin_registration_ack(revision, frame["digest"], reply)
                    return
                self.attempt.acknowledge_lease(revision, frame["digest"])
                self._published(revision)
            elif kind == "grant":
                local = _integer(frame["localNs"], 1)
                if driver:
                    if self.driver_end is None:
                        reject()
                    local = min(local, self.driver_end - self.attempt.clock())
                grant = self.attempt.grant(frame["name"], local)
                if grant.name == "recovery-registration":
                    self.registration_grant = grant
                value = grant.frame()
            elif kind == "complete":
                if self.create is not None and frame["grantId"] == self.create.grant.grant_id:
                    reject("GRANT_REVOKED")
                self.attempt.complete(frame["grantId"])
            elif kind == "validate-grant":
                if self.create is not None and frame["grantId"] == self.create.grant.grant_id:
                    reject("GRANT_REVOKED")
                value = self.attempt.validate_grant(frame["grantId"], frame["endNs"]).frame()
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
                self.attempt.terminal(_integer(frame["status"], 0, 255), frame.get("outcome"))
            send_frame(reply, {
                "ok": True, "attempt": self.attempt.nonce,
                "supervisor": self.identity, "value": value,
            })
            self._notify_clock()
        except SupervisorError as error:
            self._fixture_diagnostic(
                "rpc_reject",
                kind=kind if isinstance(kind, str) and kind in schemas else "unknown",
                reason=str(error) if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", str(error)) else "OTHER",
                cancel_reason=(
                    frame["reason"] if kind == "cancel" and frame.get("reason") in FAILURES else "OTHER"
                ),
                existing_failure=(
                    self.attempt.first_reason
                    if self.attempt.first_reason in FAILURES else "NONE"
                ),
                lifecycle=self.attempt.lifecycle,
                registration_pending=self.registration_ack is not None,
            )
            try:
                send_frame(reply, {
                    "ok": False, "attempt": self.attempt.nonce,
                    "supervisor": self.identity, "reason": str(error),
                })
            except (OSError, SupervisorError):
                pass
            # Invalid/revoked messages cannot buy another grant or reset time.
            if self.attempt.first_reason is None:
                self.attempt.cancel("OWNERSHIP_UNCERTAIN" if str(error) == "OWNERSHIP_UNCERTAIN"
                                    else "PROTOCOL_INVALID")
        finally:
            if self.create_reply is not reply and self.driver_reply is not reply and (
                self.registration_ack is None or self.registration_ack.reply is not reply
            ):
                reply.close()

    def _notify_clock(self) -> None:
        watch_end = max(
            (grant.end_ns for grant in self.attempt.grants.values()),
            default=self.attempt.idle_end,
        )
        if self.driver_end is not None:
            watch_end = max(watch_end, self.driver_end)
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
                    "outcome": (
                        self.attempt.pending_outcome if reason == "COMPLETED"
                        else self.attempt.first_reason if reason == "RECOVERY_REQUIRED"
                        and self.attempt.first_reason in REFUSAL_OUTCOMES else None
                    ),
                })
            except OSError:
                self.relay_alive = False

    def _begin_publication(self, *, terminal: bool) -> None:
        """Fork one bounded filesystem helper only after kernel ECHILD.

        Cancellation revisions wait in memory until old writers drain, then
        publish in order before a replacement worker can receive any grant.
        """
        if terminal:
            self.completing = True
            self.worker_identity = None
            self.attempt._change("drained")
            self.completion_grant = self.attempt.grant("lease-publish", 10 * NS)
        else:
            now = time.monotonic_ns()
            assert self.attempt.hard_end is not None
            end = min(now + 10 * NS, self.attempt.hard_end)
            if end <= now:
                reject("WAIT_REFUSED")
            self.completion_grant = Grant(
                secrets.token_hex(16), "lease-publish", end, self.attempt.nonce, self.attempt.role,
            )
        snapshot = self.lease_snapshots[min(self.lease_snapshots)]
        self.completion_snapshot = snapshot
        self.completion_ack = None
        self.completion_status = None
        parent, child = socket_pair()
        assert self.lock_fd is not None
        pid = os.fork()
        if pid == 0:
            try:
                parent.close()
                response = os.dup(child.fileno())
                if response == 9:
                    response = os.dup(response)
                os.dup2(self.lock_fd, 9, inheritable=True)
                _close_except({9, response})
                from test_vps_timepad_state import publish_execution_lease
                acknowledgment = publish_execution_lease(self.root, snapshot, deploy_lock_fd=9)
                with socket.socket(fileno=response) as channel:
                    send_frame(channel, acknowledgment)
                os._exit(0)
            except BaseException:
                os._exit(1)
        child.close()
        self.completion_channel, self.completion_pid = parent, pid
        self._notify_clock()

    def _completion_response(self) -> None:
        assert self.completion_channel is not None
        acknowledgment, _ = receive_frame(self.completion_channel)
        assert self.completion_snapshot is not None
        if set(acknowledgment) != {"attempt", "revision", "digest"} or \
                acknowledgment["attempt"] != self.attempt.nonce or \
                acknowledgment["revision"] != self.completion_snapshot["revision"] or \
                not isinstance(acknowledgment["digest"], str) or \
                DIGEST.fullmatch(acknowledgment["digest"]) is None:
            reject()
        self.completion_ack = acknowledgment
        self.completion_channel.close()
        self.completion_channel = None

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
                self._tick_driver(statuses)
                self._tick_create(statuses)
                self._tick_registration(statuses)
                if self.completion_pid in statuses:
                    self.completion_status = statuses[self.completion_pid]
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
                if self.completion_pid is not None and self.completion_grant is not None and \
                        now >= self.completion_grant.end_ns and \
                        self.attempt.lifecycle != "quiescence-unconfirmed":
                    self.children.signal_owned(signal.SIGKILL)
                    self.attempt.unconfirmed()
                if childless and self.completion_pid is not None:
                    if self.completion_status != 0 or (
                        self.completing and self.attempt.pending_terminal is None
                    ):
                        self.attempt.unconfirmed()
                    elif self.completion_ack is not None:
                        assert self.completion_grant is not None
                        revision = self.completion_ack["revision"]
                        self._published(revision)
                        if self.completing:
                            self.attempt.complete(self.completion_grant.grant_id)
                            self.attempt.acknowledge_lease(revision, self.completion_ack["digest"])
                            self.attempt.finish_childless()
                            self._report()
                            return self.attempt.result[0]  # type: ignore[index]
                        self.completion_pid = None
                        self.completion_grant = None
                elif childless and self.attempt.pending_terminal is not None:
                    self._begin_publication(terminal=True)
                    childless = False
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
                        if self.completion_pid is not None:
                            pass  # A completed helper's acknowledgment is still queued.
                        elif self.lease_snapshots:
                            self._begin_publication(terminal=False)
                        elif self.attempt.after_drain() is not None:
                            self.spawn()
                            self._notify_clock()
                    elif self.completion_pid is None or self.completing:
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
                    if self.completion_channel is not None:
                        selector.register(self.completion_channel, selectors.EVENT_READ, "completion")
                    if self.registration_ack is not None and self.registration_ack.channel is not None:
                        selector.register(self.registration_ack.channel, selectors.EVENT_READ, "registration")
                    if self.create_channel is not None:
                        selector.register(self.create_channel, selectors.EVENT_READ, "create")
                    if self.create_launcher_rpc is not None:
                        selector.register(self.create_launcher_rpc, selectors.EVENT_READ, "create-launcher-rpc")
                    if self.create_helper_channel is not None:
                        selector.register(self.create_helper_channel, selectors.EVENT_READ, "create-helper")
                    if self.create_helper_rpc is not None:
                        selector.register(self.create_helper_rpc, selectors.EVENT_READ, "create-helper-rpc")
                    if self.driver_channel is not None:
                        selector.register(self.driver_channel, selectors.EVENT_READ, "create-driver-result")
                    if self.driver_rpc is not None:
                        selector.register(self.driver_rpc, selectors.EVENT_READ, "create-driver-rpc")
                    for event, _ in selector.select(0.1):
                        try:
                            if event.data == "relay":
                                self._relay_message()
                            elif event.data == "completion":
                                self._completion_response()
                            elif event.data == "registration":
                                self._registration_response()
                            elif event.data == "create":
                                self._create_message()
                            elif event.data == "create-helper":
                                self._create_helper_response()
                            elif event.data == "create-driver-result":
                                self._driver_response()
                            elif event.data == "create-driver-rpc":
                                self._rpc(event.fileobj, driver=True)
                            elif event.data in {"create-launcher-rpc", "create-helper-rpc"}:
                                self._create_private_rpc(
                                    event.fileobj, publisher=event.data == "create-helper-rpc",
                                )
                            else:
                                self._rpc()
                        except (OSError, SupervisorError):
                            if event.data == "relay":
                                self.relay_alive = False
                                self.attempt.cancel("TRANSPORT_LOST")
                                self._notify_clock()
                            elif event.data in {"completion", "registration"}:
                                self.attempt.unconfirmed()
                            elif event.data.startswith("create"):
                                self.attempt.cancel("OWNERSHIP_UNCERTAIN")
                                if self.create_parked:
                                    self._resume_create_controller(cancel=True)
                            elif self.attempt.pending_terminal is None:
                                if self.worker is not None:
                                    self.worker.close()
                                    self.worker = None
                                self.attempt.cancel("PROTOCOL_INVALID")
            except (OSError, SupervisorError):
                self.attempt.cancel("OWNERSHIP_UNCERTAIN")
                if self.create_parked:
                    self._resume_create_controller(cancel=True)
                self.attempt.unconfirmed()


def production_supervisor(root: str, operation: str, arguments: list[str], channel: socket.socket) -> Supervisor:
    """The public entry has no transport selector, even indirectly."""
    return Supervisor(root, operation, arguments, channel, create_transport=RealTransport())


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
            supervisor = production_supervisor(root, operation, arguments, child)
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
    supervisor_reaped = False
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
            elif frame.get("kind") == "result" and set(frame) == {
                "kind", "attempt", "status", "reason", "outcome",
            }:
                if frame["reason"] not in {
                    "COMPLETED", "FAILED", "ROLLED_BACK", "RECOVERY_REQUIRED", "QUIESCENCE_UNCONFIRMED",
                }:
                    reject()
                status = _integer(frame["status"], 0, 255)
                if status == 0 and frame["reason"] != "COMPLETED":
                    reject()
                if status == 86 and frame["reason"] != "ROLLED_BACK":
                    reject()
                if frame["reason"] in {"COMPLETED", "ROLLED_BACK", "RECOVERY_REQUIRED"}:
                    # A subsequent replay must not race the retiring keeper's
                    # live identity or FD9. No blocking waitpid is used.
                    end = time.monotonic_ns() + 5 * NS
                    if hard_end is not None:
                        end = min(end, hard_end)
                    while True:
                        reaped, child_status = os.waitpid(pid, os.WNOHANG)
                        if reaped:
                            supervisor_reaped = True
                            if os.waitstatus_to_exitcode(child_status) != status:
                                reject()
                            break
                        if time.monotonic_ns() >= end:
                            reject("PROTOCOL_TIMEOUT")
                        time.sleep(0.01)
                outcome = frame["outcome"]
                if outcome is not None:
                    if isinstance(outcome, str) and outcome in REFUSAL_OUTCOMES:
                        if REFUSAL_OUTCOMES[outcome] != operation or status != 1 or \
                                frame["reason"] != "RECOVERY_REQUIRED":
                            reject()
                        print("test VPS deployment failed: " + outcome, file=sys.stderr, flush=True)
                        print("schema_guard=RECOVERY_REQUIRED", flush=True)
                        return status
                    if not isinstance(outcome, str) or outcome not in SUCCESS_OUTCOMES or \
                            SUCCESS_OUTCOMES[outcome][0] != operation or \
                            status != 0 or frame["reason"] != "COMPLETED":
                        reject()
                    print("schema_guard=" + SUCCESS_OUTCOMES[outcome][1], flush=True)
                    print("operation_outcome=" + outcome, flush=True)
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
        if not supervisor_reaped:
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
    validate = calls.add_parser("validate-grant")
    validate.add_argument("grant_id")
    validate.add_argument("end_ns", type=int)
    ack = calls.add_parser("lease-ack")
    ack.add_argument("revision", type=int)
    ack.add_argument("digest")
    cancel = calls.add_parser("cancel")
    cancel.add_argument("reason", choices=sorted(FAILURES))
    cancel.add_argument("status", type=int)
    terminal = calls.add_parser("terminal")
    terminal.add_argument("status", type=int)
    terminal.add_argument("--outcome", choices=sorted(SUCCESS_OUTCOMES))
    launch = calls.add_parser("create-launch")
    launch.add_argument("--role", choices=("initial", "replacement"), required=True)
    launch.add_argument("--attempt-id", required=True)
    action = calls.add_parser("create-driver")
    action.add_argument("--action", choices=[item.value for item in Action], required=True)
    action.add_argument("--role", choices=[item.value for item in Role], required=True)
    action.add_argument("--end-ns", type=int, required=True)
    evidence = calls.add_parser("recovery-evidence")
    evidence.add_argument("--end-ns", type=int, required=True)
    evidence.add_argument("arguments", nargs=argparse.REMAINDER)
    for name in ("create-release", "create-result", "create-completion"):
        call = calls.add_parser(name)
        call.add_argument("--request-digest", required=True)
        if name != "create-result":
            call.add_argument("--child-identity-json", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _cli().parse_args(argv)
    try:
        if args.command == "relay":
            arguments = args.arguments
            if not arguments or arguments[0] != "--":
                reject("CONTROLLER_ARGUMENTS_REQUIRED")
            return relay(args.root, args.operation, arguments[1:])
        end = args.end_ns if args.call in {"create-driver", "recovery-evidence"} else None
        if end is not None:
            _integer(end, 1)
            if time.monotonic_ns() >= end:
                reject("WAIT_EXPIRED")
        client = WorkerClient(args.root, end_ns=end)
        try:
            fields: dict[str, Any] = {}
            if args.call == "grant":
                fields = {"name": args.name, "localNs": _seconds(args.seconds)}
            elif args.call == "complete":
                fields = {"grantId": _nonce(args.grant_id)}
            elif args.call == "validate-grant":
                fields = {"grantId": _nonce(args.grant_id), "endNs": args.end_ns}
            elif args.call == "lease-ack":
                fields = {"revision": args.revision, "digest": args.digest}
            elif args.call == "cancel":
                fields = {"reason": args.reason, "status": args.status}
            elif args.call == "terminal":
                fields = {"status": args.status, "outcome": args.outcome}
            elif args.call == "create-launch":
                fields = {"createRole": args.role, "attemptId": args.attempt_id}
            elif args.call == "create-driver":
                fields = {"action": args.action, "createRole": args.role}
            elif args.call == "recovery-evidence":
                if not args.arguments or args.arguments[0] != "--":
                    reject()
                sys.stdout.buffer.write(client.recovery_evidence(args.root, args.arguments[1:]))
                return 0
            elif args.call in {"create-release", "create-result", "create-completion"}:
                if DIGEST.fullmatch(args.request_digest) is None:
                    reject()
                fields = {"requestDigest": args.request_digest}
                if args.call != "create-result":
                    fields["childIdentity"] = decode(args.child_identity_json.encode())
            print(json.dumps(client.request(args.call, **fields), separators=(",", ":"), sort_keys=True))
            return 0
        finally:
            client.close()
    except (SupervisorError, CreateError, OSError) as error:
        reason = str(error) if isinstance(error, SupervisorError) else "SUPERVISOR_UNAVAILABLE"
        print("schema_guard=" + reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
