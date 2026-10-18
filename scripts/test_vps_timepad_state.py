#!/usr/bin/env python3
"""Fail-closed admission, durable guard state, and shared deploy-lock helpers.

This module has no runtime, network, shell, or credential side effects. Its
filesystem operations are deliberately Linux-only; parsing and admission are
portable and independently testable.

CLI mutation schemas:
* ``publish-lease --lease`` accepts the fixed supervisor lease snapshot only,
  publishes it atomically under inherited FD9, and returns its exact revision
  and SHA-256 only after fsync and readback. A lease is never auto-cleared.
* ``check-lease --attempt`` is the read-only interlock for provider and
  retention callers; callers must pass their already-held FD9.
* ``prepare --evidence`` accepts exactly ``rootId``, ``targetId``,
  ``predecessorId``, ``predecessorContainerId``, ``transitionId``, ``target``, ``predecessor``,
  ``operation``, ``runId``, ``incidentId``, ``ownedRun`` and ``toolingDigest``.
  The two image values are the complete reviewed tuples; this command derives
  their domains from the active contract and emits only admission, epoch,
  incident ID and resulting phase.
* ``advance --changes`` accepts exactly ``{"changes": {...}}``. The inner
  object may contain only ``reason``, ``containerId``, ``configHash``,
  ``ownedChild``, ``commitWitnessDigest``, ``providerFinalizationDigest``,
  ``commitSubstep``, ``terminalReceipt`` or ``latestAttemptId``. Values remain subject to the
  strict current-state schema and transition invariants; phase is a required
  fixed CLI choice, never a changes-file field.

``ownedChild`` records one immutable process-group identity and the lifecycle
``waiting`` → ``released`` → ``reaped`` (a cancelled waiter may go directly to
``reaped``). Publish the waiting identity and ``latestAttemptId`` together, then
publish released intent before releasing the handshake. Attempt IDs are
``<incidentId>:<uint64 sequence>`` beginning at 1; clearing a reaped child retains
the counter. Durable reap/clear publication verifies group disappearance; the
controller remains responsible for waiting on its own child.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import secrets
import stat
import sys
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, Mapping

try:
    import fcntl
except ImportError:  # Parsing/admission remain portable; filesystem operations require Linux.
    fcntl = None

CONTRACT_SCHEMA = "meet-backend/test-vps-timepad-release-contracts/v1"
STATE_SCHEMA = "meet-backend/test-vps-timepad-state/v3"
ORIGIN_SCHEMA = "meet-backend/test-vps-timepad-origin/v1"
CONTROLLER = "timepad-cutover-v1"
MAX_CONTRACT_BYTES = 64 * 1024
MAX_AUTHORIZATION_BYTES = 32 * 1024
MAX_ORIGIN_BYTES = 4 * 1024
MAX_CURRENT_BYTES = 16 * 1024
MAX_CHANGES_BYTES = 4 * 1024
MAX_EXECUTION_LEASE_BYTES = 4 * 1024
MAX_JSON_DEPTH = 8
MAX_IMAGES = 8
MAX_STR = 128
MAX_LIST_ITEMS = 64
MAX_KEY = 64
MAX_U64 = (1 << 64) - 1
GUARD_DIR = "timepad-guard"
LOCK_NAME = ".deploy.lock"
EXECUTION_LEASE_NAME = ".timepad-execution.json"
RENAME_NOREPLACE = 1
HEX_256 = re.compile(r"^[a-f0-9]{64}$")
REVISION = re.compile(r"^(?:[a-f0-9]{40}|[a-f0-9]{64})$")
VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$")
IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
ROOT_KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
BOOT_ID = re.compile(r"^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$")
LEASE_NONCE = re.compile(r"^[a-f0-9]{32}$")
CHILD_ATTEMPT_ID = re.compile(r"^([a-f0-9]{32}):([1-9][0-9]{0,19})$")
CHILD_LIFECYCLES = frozenset({"waiting", "released", "reaped"})
CHILD_ACTIVE_PHASES = frozenset({
    "CUTOVER_POSSIBLE", "VERIFYING", "FORWARD_RECOVERING", "ROLLING_BACK",
    "RECOVERY_REQUIRED",
})
CHILD_IDENTITY_FIELDS = frozenset({
    "pid", "processGroup", "bootId", "startTicks", "commandDigest", "attemptId",
})


class GuardError(Exception):
    """A fixed, sanitized failure safe to return through the CLI."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _reject(reason: str = "INVALID_INPUT") -> None:
    raise GuardError(reason)


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            _reject()
        value[key] = item
    return value


def _check_depth(value: Any, depth: int = 0) -> None:
    if depth > MAX_JSON_DEPTH:
        _reject("INPUT_TOO_DEEP")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or len(key) > MAX_KEY:
                _reject()
            _check_depth(item, depth + 1)
    elif isinstance(value, list):
        if len(value) > MAX_LIST_ITEMS:
            _reject()
        for item in value:
            _check_depth(item, depth + 1)
    elif isinstance(value, str):
        if len(value) > MAX_STR or "\x00" in value:
            _reject("INPUT_TOO_LARGE")
    elif value is None or type(value) in (bool, int, float):
        if isinstance(value, float):
            _reject()
        if type(value) is int and not -(1 << 63) <= value <= MAX_U64:
            _reject()
    else:
        _reject()


def parse_json(data: bytes, limit: int) -> Any:
    if not isinstance(data, bytes) or len(data) > limit:
        _reject("INPUT_TOO_LARGE")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError):
        _reject()
    _check_depth(value)
    return value


def _object(value: Any, keys: set[str], *, exact: bool = True) -> dict[str, Any]:
    if not isinstance(value, dict) or (exact and value.keys() != keys) or not keys <= value.keys():
        _reject()
    return value


def _text(value: Any, *, pattern: re.Pattern[str] | None = None, maximum: int = MAX_STR) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum or "\x00" in value:
        _reject()
    if pattern is not None and pattern.fullmatch(value) is None:
        _reject()
    return value


def _digest(value: Any) -> str:
    return _text(value, pattern=HEX_256, maximum=64)


def _execution_lease(value: Any) -> dict[str, Any]:
    """Validate one bounded snapshot emitted by the fixed execution supervisor."""
    fields = {
        "format", "attempt", "operation", "t0Ns", "workEndNs", "hardEndNs",
        "firstFailure", "firstStatus", "rollbackIssued", "lifecycle", "revision",
        "supervisor", "worker", "workerMode", "workers",
    }
    lease = _object(value, fields)
    if type(lease["format"]) is not int or lease["format"] != 1:
        _reject("EXECUTION_LEASE_INVALID")
    _text(lease["attempt"], pattern=LEASE_NONCE, maximum=32)
    _text(lease["operation"], pattern=re.compile(r"^(?:deploy|forward-recover|retention)$"), maximum=32)
    _text(lease["lifecycle"], pattern=re.compile(
        r"^(?:registered|armed|cancel-forward|drain-forward|rollback-admission|rolling-back|"
        r"draining|quiescence-unconfirmed|drained)$"
    ), maximum=32)
    _uint(lease["revision"])
    _bool(lease["rollbackIssued"])
    deadlines = tuple(lease[key] for key in ("t0Ns", "workEndNs", "hardEndNs"))
    if any(item is None for item in deadlines):
        if not all(item is None for item in deadlines):
            _reject("EXECUTION_LEASE_INVALID")
    else:
        start, work_end, hard_end = (_uint(item) for item in deadlines)
        if not start <= work_end <= hard_end:
            _reject("EXECUTION_LEASE_INVALID")
    if lease["firstFailure"] is not None:
        _text(lease["firstFailure"], pattern=re.compile(r"^[A-Z][A-Z0-9_]{0,63}$"))
    if lease["firstStatus"] is not None and (
        type(lease["firstStatus"]) is not int or not 1 <= lease["firstStatus"] <= 255
    ):
        _reject("EXECUTION_LEASE_INVALID")
    if (lease["firstFailure"] is None) != (lease["firstStatus"] is None):
        _reject("EXECUTION_LEASE_INVALID")
    _text(lease["workerMode"], pattern=re.compile(
        r"^(?:controller-worker|rollback-worker|fail-closed-worker|retention-worker)$"
    ), maximum=32)

    def identity(raw: Any, *, nullable: bool = False) -> dict[str, Any] | None:
        if nullable and raw is None:
            return None
        row = _object(raw, {"pid", "startTicks", "bootId"})
        if type(row["pid"]) is not int or not 1 < row["pid"] <= (1 << 31) - 1:
            _reject("EXECUTION_LEASE_INVALID")
        if type(row["startTicks"]) is not int or not 0 < row["startTicks"] <= MAX_U64:
            _reject("EXECUTION_LEASE_INVALID")
        _text(row["bootId"], pattern=BOOT_ID, maximum=36)
        return row

    identity(lease["supervisor"])
    identity(lease["worker"], nullable=True)
    if not isinstance(lease["workers"], list) or len(lease["workers"]) > 3:
        _reject("EXECUTION_LEASE_INVALID")
    for worker in lease["workers"]:
        worker = _object(worker, {"mode", "pid", "startTicks", "bootId"})
        _text(worker["mode"], pattern=re.compile(
            r"^(?:controller-worker|rollback-worker|fail-closed-worker|retention-worker)$"
        ), maximum=32)
        identity({key: worker[key] for key in ("pid", "startTicks", "bootId")})
    if lease["rollbackIssued"] and lease["operation"] == "retention":
        _reject("EXECUTION_LEASE_INVALID")
    return lease


def _bool(value: Any) -> bool:
    if type(value) is not bool:
        _reject()
    return value


def _uint(value: Any) -> int:
    if type(value) is not int or not 0 <= value <= MAX_U64:
        _reject()
    return value


def _tuple(value: Any) -> dict[str, Any]:
    obj = _object(
        value,
        {
            "repositoryDigest",
            "platformImageId",
            "revision",
            "version",
            "migrationInventoryDigest",
            "migrationResources",
            "beforeSchema",
            "afterSchema",
            "guardEvidence",
            "dependencyPolicy",
            "dependencyFloor",
            "recoveryEvidence",
            "retryExact",
            "unknownTransitionCovered",
        },
    )
    for key in ("repositoryDigest", "platformImageId", "migrationInventoryDigest",
                "beforeSchema", "afterSchema", "guardEvidence", "dependencyFloor",
                "recoveryEvidence"):
        _digest(obj[key])
    _text(obj["revision"], pattern=REVISION, maximum=64)
    _text(obj["version"], pattern=VERSION, maximum=64)
    _text(obj["dependencyPolicy"], pattern=re.compile(r"^(?:resolved|not-applicable)$"), maximum=32)
    if not isinstance(obj["migrationResources"], list) or len(obj["migrationResources"]) > 64:
        _reject()
    resources = [_text(item, pattern=IDENTIFIER) for item in obj["migrationResources"]]
    if len(resources) != len(set(resources)):
        _reject()
    _bool(obj["retryExact"])
    _bool(obj["unknownTransitionCovered"])
    return obj


def _binding(value: Any) -> dict[str, Any]:
    obj = _object(value, {"id", "tuple", "domain"})
    _text(obj["id"], pattern=IDENTIFIER)
    _tuple(obj["tuple"])
    _text(obj["domain"], pattern=IDENTIFIER)
    return obj


def parse_contract(data: bytes | Mapping[str, Any]) -> dict[str, Any]:
    value = parse_json(data, MAX_CONTRACT_BYTES) if isinstance(data, bytes) else data
    obj = _object(
        value,
        {"schema", "formatVersion", "controller", "active", "rootId",
         "initialDomain", "transitions", "images"},
    )
    if obj["schema"] != CONTRACT_SCHEMA or type(obj["formatVersion"]) is not int or obj["formatVersion"] != 1:
        _reject("CONTRACT_UNSUPPORTED")
    if obj["controller"] != CONTROLLER:
        _reject("CONTRACT_UNSUPPORTED")
    _bool(obj["active"])
    if obj["rootId"] is not None:
        _text(obj["rootId"], pattern=ROOT_KEY)
    if not all(isinstance(obj[name], list) for name in ("initialDomain", "transitions", "images")):
        _reject()
    if len(obj["images"]) > MAX_IMAGES or len(obj["initialDomain"]) > MAX_IMAGES or len(obj["transitions"]) > MAX_IMAGES:
        _reject("INPUT_TOO_LARGE")
    ids: set[str] = set()
    for item in obj["images"]:
        parsed = _binding(item)
        if parsed["id"] in ids:
            _reject()
        ids.add(parsed["id"])
    for item in obj["initialDomain"]:
        row = _object(item, {"id", "tuple"})
        _text(row["id"], pattern=IDENTIFIER)
        if row["id"] in ids:
            _reject()
        ids.add(row["id"])
        _tuple(row["tuple"])
    transition_ids: set[str] = set()
    for item in obj["transitions"]:
        row = _object(item, {"id", "targetId", "beforeSchema", "afterSchema", "compatiblePredecessors"})
        transition_id = _text(row["id"], pattern=IDENTIFIER)
        if transition_id in transition_ids:
            _reject("CONTRACT_DUPLICATE_TRANSITION")
        transition_ids.add(transition_id)
        _text(row["targetId"], pattern=IDENTIFIER)
        _digest(row["beforeSchema"])
        _digest(row["afterSchema"])
        if not isinstance(row["compatiblePredecessors"], list) or len(row["compatiblePredecessors"]) > MAX_IMAGES:
            _reject()
        refs = [_text(ref, pattern=IDENTIFIER) for ref in row["compatiblePredecessors"]]
        if len(refs) != len(set(refs)):
            _reject()
        if any(ref not in ids for ref in refs):
            _reject("CONTRACT_REFERENCE_UNKNOWN")
        target = next((item for item in obj["images"] if item["id"] == row["targetId"]), None)
        if target is None:
            _reject()
        target_tuple = target["tuple"]
        if (target_tuple["beforeSchema"], target_tuple["afterSchema"]) != (
            row["beforeSchema"], row["afterSchema"],
        ):
            _reject("CONTRACT_TRANSITION_MISMATCH")
        if target_tuple["dependencyPolicy"] != "resolved" or \
                not target_tuple["retryExact"] or not target_tuple["unknownTransitionCovered"]:
            _reject("CONTRACT_TARGET_RECOVERY_UNPROVEN")
        for ref in refs:
            predecessor = next((item for item in obj["images"] if item["id"] == ref), None)
            if predecessor is None:
                _reject("CONTRACT_REFERENCE_UNKNOWN")
            tuple_value = predecessor["tuple"]
            if tuple_value["afterSchema"] != row["afterSchema"] or \
                    tuple_value["dependencyPolicy"] != "resolved" or \
                    not tuple_value["retryExact"] or not tuple_value["unknownTransitionCovered"]:
                _reject("CONTRACT_COMPATIBILITY_UNPROVEN")
    if obj["active"] and (obj["rootId"] is None or not obj["images"]):
        _reject("CONTRACT_INCOMPLETE")
    if not obj["active"] and (obj["rootId"] is not None or obj["initialDomain"] or obj["transitions"] or obj["images"]):
        _reject("INACTIVE_CONTRACT_HAS_AUTHORITY")
    return obj


@dataclass(frozen=True)
class Admission:
    disposition: str
    reason: str
    contract_digest: str
    target_id: str | None
    predecessor_id: str | None
    transition_id: str | None = None

    def as_dict(self) -> dict[str, Any]:
        return {
            "disposition": self.disposition,
            "reason": self.reason,
            "contractDigest": self.contract_digest,
            "targetId": self.target_id,
            "predecessorId": self.predecessor_id,
            "transitionId": self.transition_id,
        }


def admit(
    contract: Mapping[str, Any] | bytes,
    *,
    root_id: str,
    target_id: str,
    predecessor_id: str,
    transition_id: str | None,
    target_tuple: Mapping[str, Any] | None,
    predecessor_tuple: Mapping[str, Any] | None,
) -> Admission:
    try:
        parsed = parse_contract(contract)
        _text(root_id, pattern=ROOT_KEY)
        target = _text(target_id, pattern=IDENTIFIER)
        predecessor = _text(predecessor_id, pattern=IDENTIFIER)
        if not parsed["active"] or parsed["rootId"] != root_id:
            _reject("CONTRACT_INACTIVE_OR_WRONG_ROOT")
        target_binding = next((x for x in parsed["images"] if x["id"] == target), None)
        pred_binding = next((x for x in parsed["images"] if x["id"] == predecessor), None)
        initial = {x["id"]: x["tuple"] for x in parsed["initialDomain"]}
        target_evidence = target_binding["tuple"] if target_binding else initial.get(target)
        predecessor_evidence = pred_binding["tuple"] if pred_binding else initial.get(predecessor)
        if target_evidence is None or predecessor_evidence is None or \
                target_tuple is None or predecessor_tuple is None:
            _reject("IMAGE_NOT_REVIEWED")
        if _tuple(target_tuple) != target_evidence or _tuple(predecessor_tuple) != predecessor_evidence:
            _reject("OBSERVED_IMAGE_MISMATCH")
        if transition_id is None:
            if target not in initial or predecessor not in initial:
                _reject("IMAGE_NOT_REVIEWED")
            target_schema = target_evidence["afterSchema"]
            predecessor_schema = predecessor_evidence["afterSchema"]
            if target_evidence["beforeSchema"] != target_schema or \
                    predecessor_evidence["beforeSchema"] != predecessor_schema or \
                    target_schema != predecessor_schema:
                _reject("INITIAL_DOMAIN_PROOF_MISMATCH")
            disposition, reason = "legacy-no-transition", "UNCHANGED_DOMAIN_REVIEWED"
        else:
            if target_binding is None:
                _reject("TRANSITION_TARGET_UNBOUND")
            transition = next((x for x in parsed["transitions"] if x["id"] == transition_id), None)
            if transition is None or transition["targetId"] != target:
                _reject("TRANSITION_NOT_REVIEWED")
            if target_binding["tuple"]["beforeSchema"] != transition["beforeSchema"] or \
                    target_binding["tuple"]["afterSchema"] != transition["afterSchema"]:
                _reject("TRANSITION_EVIDENCE_MISMATCH")
            if predecessor in transition["compatiblePredecessors"]:
                pred = predecessor_evidence
                if not pred["retryExact"] or not pred["unknownTransitionCovered"] or \
                        pred["dependencyPolicy"] != "resolved" or \
                        pred["afterSchema"] != transition["afterSchema"]:
                    _reject("PREDECESSOR_RECOVERY_UNPROVEN")
                disposition, reason = "post-barrier-compatible", "PREDECESSOR_FULLY_COMPATIBLE"
            else:
                disposition, reason = "pre-barrier-only", "PREDECESSOR_NOT_POST_BARRIER_COMPATIBLE"
        canonical = json.dumps(parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
        return Admission(
            disposition, reason, hashlib.sha256(canonical).hexdigest(),
            target, predecessor, transition_id,
        )
    except GuardError as exc:
        return Admission("refuse", exc.reason, "", None, None)


def _canonical(value: Mapping[str, Any]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii")


def _origin(value: Any) -> dict[str, Any]:
    obj = _object(value, {
        "schema", "controller", "rootId", "bootstrapId", "initialRuntime",
        "initialConfig", "initialSchema", "initialStartupInventory",
        "schemaHistoryProvenance", "originDigest",
    })
    if obj["schema"] != ORIGIN_SCHEMA or obj["controller"] != CONTROLLER:
        _reject("ORIGIN_INVALID")
    _text(obj["rootId"], pattern=ROOT_KEY)
    _text(obj["bootstrapId"], pattern=IDENTIFIER)
    for key in ("initialRuntime", "initialConfig", "initialSchema", "initialStartupInventory"):
        _digest(obj[key])
    _bool(obj["schemaHistoryProvenance"])
    _digest(obj["originDigest"])
    unsigned = dict(obj)
    digest = unsigned.pop("originDigest")
    if hashlib.sha256(_canonical(unsigned)).hexdigest() != digest:
        _reject("ORIGIN_INVALID")
    return obj


PHASES = frozenset({
    "READY", "PREPARED", "CUTOVER_POSSIBLE", "VERIFYING", "COMMITTING",
    "COMMITTED", "ROLLING_BACK", "ROLLED_BACK", "RECOVERY_REQUIRED",
    "FORWARD_RECOVERING",
})
TERMINAL = frozenset({"COMMITTED", "ROLLED_BACK"})


def _child_attempt_sequence(value: Any, incident_id: str | None = None) -> int:
    attempt = _text(value, pattern=CHILD_ATTEMPT_ID, maximum=53)
    incident, sequence = attempt.split(":")
    if incident_id is not None and incident != incident_id:
        _reject("STATE_CHILD_ATTEMPT_CONFLICT")
    return _uint(int(sequence))


def _owned_child(value: Any) -> dict[str, Any]:
    child = _object(value, CHILD_IDENTITY_FIELDS | {"lifecycle"})
    for name in ("pid", "processGroup"):
        if type(child[name]) is not int or not 1 < child[name] <= (1 << 31) - 1:
            _reject("STATE_CHILD_INVALID")
    if child["processGroup"] != child["pid"] or _uint(child["startTicks"]) == 0:
        _reject("STATE_CHILD_INVALID")
    _text(child["bootId"], pattern=BOOT_ID, maximum=36)
    _digest(child["commandDigest"])
    _child_attempt_sequence(child["attemptId"])
    if not isinstance(child["lifecycle"], str) or child["lifecycle"] not in CHILD_LIFECYCLES:
        _reject("STATE_CHILD_INVALID")
    return child


def _current(value: Any) -> dict[str, Any]:
    keys = {
        "schema", "controller", "originDigest", "operationEpoch", "operation",
        "runId", "incidentId", "phase", "reason", "target", "predecessor",
        "predecessorContainerId",
        "transitionId", "evidenceDigest", "predecessorDisposition", "ownedRun",
        "toolingDigest", "containerId", "configHash", "ownedChild", "commitWitnessDigest",
        "providerFinalizationDigest",
        "commitSubstep", "terminalReceipt", "latestAttemptId", "rollbackIssued",
        "executionAttempt", "preparedProofDigest",
    }
    if not isinstance(value, dict) or value.keys() != keys:
        _reject()
    obj = dict(value)
    if obj["schema"] != STATE_SCHEMA or obj["controller"] != CONTROLLER:
        _reject("STATE_INVALID")
    _bool(obj["rollbackIssued"])
    _digest(obj["originDigest"])
    epoch = _uint(obj["operationEpoch"])
    if epoch == 0 and obj["phase"] != "READY":
        _reject("STATE_INVALID")
    if not isinstance(obj["phase"], str) or obj["phase"] not in PHASES:
        _reject("STATE_INVALID")
    if epoch > 0 and obj["phase"] == "READY":
        _reject("STATE_INVALID")
    if obj["predecessorDisposition"] is not None:
        disposition = _text(obj["predecessorDisposition"], maximum=32)
        if disposition not in {"pre-barrier-only", "post-barrier-compatible"}:
            _reject("STATE_INVALID")
    for key in ("operation", "runId", "incidentId", "reason", "commitSubstep"):
        if obj[key] is not None:
            if key == "operation":
                pattern = re.compile(r"^(?:deploy|rollback-drill)$")
            elif key == "reason":
                pattern = re.compile(r"^[A-Z][A-Z0-9_]{0,63}$")
            elif key == "commitSubstep":
                pattern = re.compile(
                    r"^(?:provider-cleanup|terminal-policy-intent|policy-restored|replacement-(?:create-intent|container-authorized|provider-cleanup|terminal-policy-intent|policy-restored))$"
                )
            elif key == "incidentId":
                pattern = re.compile(r"^[a-f0-9]{32}$")
            else:
                pattern = IDENTIFIER
            _text(obj[key], pattern=pattern, maximum=64 if key == "reason" else MAX_STR)
    if obj["latestAttemptId"] is not None:
        _child_attempt_sequence(obj["latestAttemptId"], obj["incidentId"])
        if obj["phase"] == "PREPARED":
            _reject("STATE_CHILD_PHASE")
    if obj["executionAttempt"] is not None:
        _text(obj["executionAttempt"], pattern=LEASE_NONCE, maximum=32)
    for key in (
        "evidenceDigest", "toolingDigest", "configHash", "commitWitnessDigest",
        "providerFinalizationDigest", "terminalReceipt", "preparedProofDigest",
    ):
        if obj[key] is not None:
            _digest(obj[key])
    for key in ("target", "predecessor"):
        if obj[key] is not None:
            _binding(obj[key])
    if obj["transitionId"] is not None:
        _text(obj["transitionId"], pattern=IDENTIFIER)
    if obj["ownedRun"] is not None:
        _text(obj["ownedRun"], pattern=ROOT_KEY)
    if obj["containerId"] is not None:
        _text(obj["containerId"], pattern=re.compile(r"^[a-f0-9]{12,64}$"), maximum=64)
    if obj["predecessorContainerId"] is not None:
        _text(
            obj["predecessorContainerId"],
            pattern=re.compile(r"^[a-f0-9]{12,64}$"),
            maximum=64,
        )
    if obj["ownedChild"] is not None:
        child = _owned_child(obj["ownedChild"])
        if child["attemptId"] != obj["latestAttemptId"]:
            _reject("STATE_CHILD_ATTEMPT_CONFLICT")
        if obj["phase"] in TERMINAL | {"READY", "PREPARED"} or (
            child["lifecycle"] != "reaped" and obj["phase"] not in CHILD_ACTIVE_PHASES
        ):
            _reject("STATE_CHILD_PHASE")
    if epoch == 0:
        if any(obj[name] is not None for name in (
            "operation", "runId", "incidentId", "target", "predecessor", "transitionId",
            "predecessorContainerId",
            "reason", "evidenceDigest", "predecessorDisposition", "ownedRun", "toolingDigest",
            "containerId", "configHash",
            "ownedChild", "commitWitnessDigest", "providerFinalizationDigest",
            "commitSubstep", "terminalReceipt",
            "latestAttemptId",
            "executionAttempt",
            "preparedProofDigest",
        )):
            _reject("STATE_INVALID")
        if obj["rollbackIssued"]:
            _reject("STATE_INVALID")
    elif any(obj[name] is None for name in (
        "operation", "runId", "incidentId", "target", "predecessor", "transitionId",
        "predecessorContainerId",
        "evidenceDigest", "predecessorDisposition", "ownedRun", "toolingDigest",
        "preparedProofDigest",
    )):
        _reject("STATE_INVALID")
    if obj["phase"] in {"COMMITTING", "COMMITTED"} and any(
        obj[name] is None for name in (
            "containerId", "configHash", "commitWitnessDigest",
            "providerFinalizationDigest",
        )
    ):
        _reject("STATE_INVALID")
    if obj["providerFinalizationDigest"] is not None and obj["phase"] not in {
        "COMMITTING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING", "COMMITTED",
    }:
        _reject("STATE_INVALID")
    if obj["commitWitnessDigest"] is not None and obj["phase"] not in {
        "COMMITTING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING", "COMMITTED",
    }:
        _reject("STATE_INVALID")
    if obj["phase"] in TERMINAL and obj["terminalReceipt"] is None:
        _reject("STATE_INVALID")
    if obj["phase"] == "COMMITTED" and obj["commitSubstep"] not in {
        "policy-restored", "replacement-policy-restored",
    }:
        _reject("STATE_INVALID")
    return obj


def new_ready_state(origin_digest: str) -> dict[str, Any]:
    return {
        "schema": STATE_SCHEMA, "controller": CONTROLLER, "originDigest": _digest(origin_digest),
        "operationEpoch": 0, "operation": None, "runId": None, "incidentId": None,
        "phase": "READY", "reason": None, "target": None, "predecessor": None,
        "predecessorContainerId": None,
        "transitionId": None, "evidenceDigest": None, "predecessorDisposition": None,
        "ownedRun": None, "toolingDigest": None, "containerId": None, "configHash": None,
        "ownedChild": None, "commitWitnessDigest": None,
        "providerFinalizationDigest": None, "commitSubstep": None,
        "terminalReceipt": None, "latestAttemptId": None, "rollbackIssued": False,
        "executionAttempt": None, "preparedProofDigest": None,
    }


def new_prepared_state(
    ready: Mapping[str, Any],
    *,
    operation: str,
    run_id: str,
    incident_id: str,
    admission: Admission,
    target: Mapping[str, Any],
    predecessor: Mapping[str, Any],
    predecessor_container_id: str,
    transition_id: str | None,
    owned_run: str,
    tooling_digest: str,
    prepared_proof_digest: str,
    execution_attempt: str | None = None,
) -> dict[str, Any]:
    prior = _current(dict(ready))
    if prior["phase"] not in TERMINAL | {"READY"} or prior["operationEpoch"] == MAX_U64:
        _reject("STATE_NOT_READY")
    if admission.disposition not in {"pre-barrier-only", "post-barrier-compatible"}:
        _reject("ADMISSION_REFUSED")
    if operation == "rollback-drill" and transition_id is not None and \
            admission.disposition != "post-barrier-compatible":
        _reject("ROLLBACK_DRILL_UNSAFE")
    target_binding = _binding(target)
    predecessor_binding = _binding(predecessor)
    if target_binding["id"] != admission.target_id or \
            predecessor_binding["id"] != admission.predecessor_id or \
            transition_id != admission.transition_id:
        _reject("ADMISSION_BINDING_MISMATCH")
    result = dict(prior)
    result.update({
        "operationEpoch": prior["operationEpoch"] + 1,
        "operation": _text(operation, pattern=re.compile(r"^(?:deploy|rollback-drill)$")),
        "runId": _text(run_id, pattern=IDENTIFIER),
        "incidentId": _text(incident_id, pattern=re.compile(r"^[a-f0-9]{32}$")),
        "phase": "PREPARED", "reason": None, "target": target_binding,
        "predecessor": predecessor_binding, "transitionId": transition_id,
        "predecessorContainerId": _text(
            predecessor_container_id,
            pattern=re.compile(r"^[a-f0-9]{12,64}$"),
            maximum=64,
        ),
        "evidenceDigest": _digest(admission.contract_digest),
        "preparedProofDigest": _digest(prepared_proof_digest),
        "predecessorDisposition": admission.disposition,
        "ownedRun": _text(owned_run, pattern=ROOT_KEY), "toolingDigest": _digest(tooling_digest),
        "containerId": None, "configHash": None, "ownedChild": None,
        "commitWitnessDigest": None, "providerFinalizationDigest": None,
        "commitSubstep": None, "terminalReceipt": None,
        "latestAttemptId": None, "rollbackIssued": False,
        "executionAttempt": (
            _text(execution_attempt, pattern=LEASE_NONCE, maximum=32)
            if execution_attempt is not None else prior["executionAttempt"]
        ),
    })
    return _current(result)


PHASE_EDGES = {
    "READY": frozenset({"PREPARED"}),
    "PREPARED": frozenset({
        "CUTOVER_POSSIBLE", "VERIFYING", "ROLLING_BACK", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
    }),
    "CUTOVER_POSSIBLE": frozenset({"VERIFYING", "ROLLING_BACK", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"}),
    "VERIFYING": frozenset({"COMMITTING", "ROLLING_BACK", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"}),
    "COMMITTING": frozenset({"COMMITTED", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"}),
    "ROLLING_BACK": frozenset({"ROLLED_BACK", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"}),
    "RECOVERY_REQUIRED": frozenset({"RECOVERY_REQUIRED", "FORWARD_RECOVERING"}),
    "FORWARD_RECOVERING": frozenset({
        "CUTOVER_POSSIBLE", "VERIFYING", "COMMITTING", "ROLLING_BACK",
        "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
    }),
    "COMMITTED": frozenset({"PREPARED"}),
    "ROLLED_BACK": frozenset({"PREPARED"}),
}
INCIDENT_BINDING_FIELDS = (
    "originDigest", "operation", "runId", "incidentId", "target", "predecessor",
    "predecessorContainerId", "transitionId", "evidenceDigest",
    "predecessorDisposition", "ownedRun", "toolingDigest", "preparedProofDigest",
)


def validate_state_transition(old: Mapping[str, Any], new: Mapping[str, Any]) -> None:
    previous, candidate = _current(dict(old)), _current(dict(new))
    if previous["originDigest"] != candidate["originDigest"]:
        _reject("STATE_ORIGIN_CONFLICT")
    old_epoch, new_epoch = previous["operationEpoch"], candidate["operationEpoch"]
    if new_epoch == old_epoch + 1:
        if old_epoch == MAX_U64 or candidate["phase"] != "PREPARED" or \
                previous["phase"] not in TERMINAL | {"READY"}:
            _reject("STATE_EPOCH_CONFLICT")
        if candidate["runId"] == previous["runId"] or candidate["incidentId"] == previous["incidentId"]:
            _reject("STATE_INCIDENT_REUSE")
        return
    if new_epoch != old_epoch:
        _reject("STATE_EPOCH_CONFLICT")
    if previous["executionAttempt"] is not None and \
            candidate["executionAttempt"] != previous["executionAttempt"]:
        _reject("STATE_EXECUTION_ATTEMPT_CONFLICT")
    if candidate["phase"] == previous["phase"]:
        if previous["phase"] in {"READY", *TERMINAL}:
            if candidate != previous:
                _reject("STATE_TERMINAL_CONFLICT")
    elif candidate["phase"] not in PHASE_EDGES[previous["phase"]]:
        _reject("STATE_PHASE_CONFLICT")
    if previous["phase"] == "PREPARED" and previous["transitionId"] is not None and \
            candidate["phase"] == "VERIFYING":
        _reject("CUTOVER_BARRIER_REQUIRED")
    if candidate["phase"] == "ROLLING_BACK" and previous["phase"] in {
        "CUTOVER_POSSIBLE", "VERIFYING", "FORWARD_RECOVERING",
    } and previous["predecessorDisposition"] != "post-barrier-compatible":
        _reject("ROLLBACK_UNSAFE")
    if candidate["phase"] == "ROLLING_BACK" and (
        previous["commitWitnessDigest"] is not None
        or previous["providerFinalizationDigest"] is not None
    ):
        _reject("COMMIT_ALREADY_BEGUN")
    if any(previous[field] != candidate[field] for field in INCIDENT_BINDING_FIELDS):
        _reject("STATE_INCIDENT_CONFLICT")
    if previous["rollbackIssued"] and not candidate["rollbackIssued"]:
        _reject("STATE_ROLLBACK_LATCH_CONFLICT")
    if not previous["rollbackIssued"] and candidate["rollbackIssued"] and (
        candidate["phase"] != "ROLLING_BACK"
        or candidate["commitWitnessDigest"] is not None
        or candidate["providerFinalizationDigest"] is not None
        or candidate["predecessorDisposition"] not in {
            "pre-barrier-only", "post-barrier-compatible",
        }
    ):
        _reject("STATE_ROLLBACK_LATCH_PHASE")
    if previous["containerId"] is not None and candidate["containerId"] != previous["containerId"]:
        if (
            previous["phase"] not in {"COMMITTING", "FORWARD_RECOVERING"}
            or candidate["phase"] != previous["phase"]
            or previous["commitSubstep"] != "replacement-create-intent"
            or candidate["commitSubstep"] != "replacement-container-authorized"
            or previous["latestAttemptId"] is None
            or candidate["latestAttemptId"] != previous["latestAttemptId"]
            or previous["ownedChild"] is not None
            or candidate["ownedChild"] is not None
        ):
            _reject("STATE_CONTAINER_CONFLICT")
    if previous["configHash"] is not None and candidate["configHash"] != previous["configHash"]:
        _reject("STATE_CONFIG_CONFLICT")
    if previous["commitWitnessDigest"] is not None and \
            candidate["commitWitnessDigest"] != previous["commitWitnessDigest"]:
        _reject("STATE_WITNESS_CONFLICT")
    if previous["commitWitnessDigest"] is None and \
            candidate["commitWitnessDigest"] is not None and \
            (
                previous["phase"] != "VERIFYING"
                or candidate["phase"] != "COMMITTING"
            ):
        _reject("STATE_WITNESS_PHASE")
    replacement_steps = (
        "replacement-create-intent",
        "replacement-container-authorized",
        "replacement-provider-cleanup",
        "replacement-terminal-policy-intent",
        "replacement-policy-restored",
    )
    old_substep = previous["commitSubstep"]
    new_substep = candidate["commitSubstep"]
    if old_substep in replacement_steps:
        old_index = replacement_steps.index(old_substep)
        if new_substep not in replacement_steps[old_index:old_index + 2]:
            _reject("STATE_COMMIT_SUBSTEP_CONFLICT")
    elif new_substep in replacement_steps and new_substep != replacement_steps[0]:
        _reject("STATE_COMMIT_SUBSTEP_CONFLICT")
    if new_substep == "replacement-create-intent" and old_substep != new_substep and (
        previous["ownedChild"] is not None
        or candidate["ownedChild"] is not None
        or previous["containerId"] is None
        or previous["commitWitnessDigest"] is None
        or previous["providerFinalizationDigest"] is None
    ):
        _reject("STATE_REPLACEMENT_INTENT_CONFLICT")
    if old_substep == "replacement-create-intent" and \
            new_substep == "replacement-container-authorized" and \
            candidate["containerId"] == previous["containerId"]:
        _reject("STATE_CONTAINER_CONFLICT")
    if new_substep in replacement_steps and candidate["phase"] not in {
        "COMMITTING", "FORWARD_RECOVERING", "RECOVERY_REQUIRED", "COMMITTED",
    }:
        _reject("STATE_COMMIT_SUBSTEP_PHASE")
    if previous["providerFinalizationDigest"] is not None and \
            candidate["providerFinalizationDigest"] != previous["providerFinalizationDigest"]:
        _reject("STATE_FINALIZATION_WITNESS_CONFLICT")
    if previous["providerFinalizationDigest"] is None and \
            candidate["providerFinalizationDigest"] is not None and \
            (
                previous["phase"] != "VERIFYING"
                or candidate["phase"] != "COMMITTING"
                or candidate["commitWitnessDigest"] is None
            ):
        _reject("STATE_FINALIZATION_WITNESS_PHASE")
    if previous["terminalReceipt"] is not None and candidate["terminalReceipt"] != previous["terminalReceipt"]:
        _reject("STATE_RECEIPT_CONFLICT")
    _validate_child_transition(previous, candidate)


def _validate_child_transition(previous: Mapping[str, Any], candidate: Mapping[str, Any]) -> None:
    old_child, new_child = previous["ownedChild"], candidate["ownedChild"]
    if old_child is None and new_child is not None:
        if candidate["phase"] not in CHILD_ACTIVE_PHASES or \
                candidate["phase"] != previous["phase"]:
            _reject("STATE_CHILD_PHASE")
        if new_child["lifecycle"] != "waiting":
            _reject("STATE_CHILD_LIFECYCLE")
        # A bounded incident-local counter rejects even historical A -> B -> A
        # replay without retaining a journal of prior process identities.
        old_sequence = (
            _child_attempt_sequence(previous["latestAttemptId"], previous["incidentId"])
            if previous["latestAttemptId"] is not None else 0
        )
        if old_sequence == MAX_U64 or _child_attempt_sequence(
            candidate["latestAttemptId"], candidate["incidentId"],
        ) != old_sequence + 1:
            _reject("STATE_CHILD_ATTEMPT_CONFLICT")
        return
    if previous["latestAttemptId"] != candidate["latestAttemptId"]:
        _reject("STATE_CHILD_ATTEMPT_CONFLICT")
    if old_child is None:
        return
    if new_child is None:
        if old_child["lifecycle"] != "reaped":
            _reject("STATE_CHILD_NOT_REAPED")
        return
    if any(old_child[field] != new_child[field] for field in CHILD_IDENTITY_FIELDS):
        _reject("STATE_CHILD_CONFLICT")
    edges = {
        "waiting": {"waiting", "released", "reaped"},
        "released": {"released", "reaped"},
        "reaped": {"reaped"},
    }
    if new_child["lifecycle"] not in edges[old_child["lifecycle"]]:
        _reject("STATE_CHILD_LIFECYCLE")
    if old_child["lifecycle"] == "waiting" and new_child["lifecycle"] == "released":
        if previous["phase"] != candidate["phase"] or candidate["phase"] not in CHILD_ACTIVE_PHASES:
            _reject("STATE_CHILD_PHASE")


def advance_state(current: Mapping[str, Any], phase: str, **changes: Any) -> dict[str, Any]:
    previous = _current(dict(current))
    if phase not in PHASES:
        _reject("STATE_PHASE_CONFLICT")
    candidate_value = dict(previous)
    candidate_value.update(changes)
    candidate_value["phase"] = phase
    candidate = _current(candidate_value)
    validate_state_transition(previous, candidate)
    return candidate


def _proc_start_ticks(pid: int) -> tuple[int, int]:
    """Return the process group and kernel start tick from one bounded proc read."""
    if os.name != "posix" or type(pid) is not int or not 1 < pid <= (1 << 31) - 1:
        _reject("OWNED_CHILD_UNVERIFIABLE")
    try:
        with open(f"/proc/{pid}/stat", "rb") as stream:
            raw = stream.read(4097)
        if len(raw) > 4096 or not raw.endswith(b"\n"):
            _reject("OWNED_CHILD_UNVERIFIABLE")
        # comm is parenthesized and may itself contain spaces or parentheses.
        end = raw.rfind(b")")
        if end < 0:
            _reject("OWNED_CHILD_UNVERIFIABLE")
        fields = raw[end + 2 : -1].split()
        if len(fields) < 20:
            _reject("OWNED_CHILD_UNVERIFIABLE")
        process_group = int(fields[2])
        start_ticks = int(fields[19])
        if process_group != pid or start_ticks <= 0:
            _reject("OWNED_CHILD_UNVERIFIABLE")
        return process_group, start_ticks
    except (OSError, ValueError, IndexError):
        _reject("OWNED_CHILD_UNVERIFIABLE")


def capture_owned_child(pid: int, *, command_digest: str, attempt_id: str) -> dict[str, Any]:
    """Capture a process-group leader before its controller releases the start handshake."""
    process_group, start_ticks = _proc_start_ticks(pid)
    try:
        with open("/proc/sys/kernel/random/boot_id", "rt", encoding="ascii") as stream:
            boot_id = stream.read(129).strip()
    except OSError:
        _reject("OWNED_CHILD_UNVERIFIABLE")
    child = {
        "pid": pid,
        "processGroup": process_group,
        "bootId": boot_id,
        "startTicks": start_ticks,
        "commandDigest": _digest(command_digest),
        "attemptId": _text(attempt_id, pattern=IDENTIFIER),
        "lifecycle": "waiting",
    }
    return _owned_child(child)


def owned_child_is_same_process(child: Mapping[str, Any]) -> bool:
    """Check boot, group-leader and start-time identity without signaling by PID alone."""
    record = _owned_child(dict(child))
    try:
        with open("/proc/sys/kernel/random/boot_id", "rt", encoding="ascii") as stream:
            boot_id = stream.read(129).strip()
    except OSError:
        _reject("OWNED_CHILD_UNVERIFIABLE")
    if boot_id != record["bootId"]:
        return False
    try:
        process_group, start_ticks = _proc_start_ticks(record["pid"])
    except GuardError as exc:
        if exc.reason == "OWNED_CHILD_UNVERIFIABLE":
            return False
        raise
    return process_group == record["processGroup"] and start_ticks == record["startTicks"]


def stop_owned_child(
    root: str | os.PathLike[str],
    *,
    deploy_lock_fd: int | None,
    term_grace_seconds: float = 5.0,
) -> dict[str, str]:
    """Stop only the persisted group leader's owned process group, then prove quiescence."""
    if not 0 <= term_grace_seconds <= 10:
        _reject("OWNED_CHILD_UNVERIFIABLE")
    with deploy_lock(root, deploy_lock_fd):
        _, current = _read_guard_locked(root)
        child = current["ownedChild"]
        if child is None:
            return {"outcome": "already-quiescent"}
        if not owned_child_is_same_process(child):
            # A dead or reused leader is never authority to signal a numeric PID.
            try:
                os.killpg(child["processGroup"], 0)
            except ProcessLookupError:
                return {"outcome": "already-quiescent"}
            except PermissionError:
                _reject("OWNED_CHILD_UNVERIFIABLE")
            _reject("OWNED_CHILD_UNVERIFIABLE")
        try:
            os.killpg(child["processGroup"], 15)
        except ProcessLookupError:
            return {"outcome": "already-quiescent"}
        deadline = time.monotonic() + term_grace_seconds
        while time.monotonic() < deadline:
            try:
                os.killpg(child["processGroup"], 0)
            except ProcessLookupError:
                return {"outcome": "terminated"}
            time.sleep(0.05)
        # Before escalation, re-check the original process identity and group id.
        if not owned_child_is_same_process(child):
            try:
                os.killpg(child["processGroup"], 0)
            except ProcessLookupError:
                return {"outcome": "terminated"}
            _reject("OWNED_CHILD_UNVERIFIABLE")
        try:
            os.killpg(child["processGroup"], 9)
        except ProcessLookupError:
            return {"outcome": "terminated"}
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            try:
                os.killpg(child["processGroup"], 0)
            except ProcessLookupError:
                return {"outcome": "killed"}
            time.sleep(0.05)
        _reject("OWNED_CHILD_QUIESCENCE_UNCONFIRMED")


def clear_owned_child_after_quiescence(child: Mapping[str, Any] | None) -> None:
    if child is not None:
        require_child_group_quiescent(child)


def require_child_group_quiescent(child: Mapping[str, Any]) -> None:
    record = _owned_child(dict(child))
    if os.name != "posix" or not hasattr(os, "killpg"):
        _reject("LINUX_REQUIRED")
    try:
        os.killpg(record["processGroup"], 0)
    except ProcessLookupError:
        return
    except PermissionError:
        _reject("OWNED_CHILD_UNVERIFIABLE")
    _reject("OWNED_CHILD_STILL_RUNNING")


RECOVERY_AUTH_SCHEMA = "meet-backend/test-vps-timepad-recovery-authorization/v1"
RECOVERABLE_PHASES = frozenset({
    "PREPARED", "CUTOVER_POSSIBLE", "VERIFYING", "COMMITTING",
    "ROLLING_BACK", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
})


def authorize_recovery(
    data: bytes | Mapping[str, Any],
    *,
    root_id: str,
    current: Mapping[str, Any],
) -> dict[str, str | int]:
    authority = parse_json(data, MAX_AUTHORIZATION_BYTES) if isinstance(data, bytes) else dict(data)
    fields = {
        "schema", "rootId", "originDigest", "originalOperation", "runId", "operationEpoch",
        "incidentId", "evidenceDigest", "targetId", "revision", "version",
        "repositoryDigest", "platformImageId", "action",
    }
    auth = _object(authority, fields)
    state = _current(dict(current))
    if auth["schema"] != RECOVERY_AUTH_SCHEMA:
        _reject("RECOVERY_AUTH_INVALID")
    _text(root_id, pattern=ROOT_KEY)
    _text(auth["rootId"], pattern=ROOT_KEY)
    _digest(auth["originDigest"])
    _text(auth["originalOperation"], pattern=re.compile(r"^(?:deploy|rollback-drill|forward-recover)$"))
    _text(auth["runId"], pattern=IDENTIFIER)
    epoch = _uint(auth["operationEpoch"])
    _text(auth["incidentId"], pattern=re.compile(r"^[a-f0-9]{32}$"))
    binding = _digest(auth["evidenceDigest"])
    target_id = _text(auth["targetId"], pattern=IDENTIFIER)
    _text(auth["revision"], pattern=REVISION, maximum=64)
    _text(auth["version"], pattern=VERSION, maximum=64)
    repository = _digest(auth["repositoryDigest"])
    image_id = _digest(auth["platformImageId"])
    if auth["action"] != "retry-exact-candidate":
        _reject("RECOVERY_ACTION_UNSUPPORTED")
    if state["phase"] not in RECOVERABLE_PHASES | {"COMMITTED"}:
        _reject("RECOVERY_PHASE_REFUSED")
    target = state["target"]
    if (
        auth["rootId"] != root_id
        or auth["originDigest"] != state["originDigest"]
        or auth["originalOperation"] != state["operation"]
        or auth["runId"] != state["runId"]
        or epoch != state["operationEpoch"]
        or auth["incidentId"] != state["incidentId"]
        or binding != state["evidenceDigest"]
        or target is None
        or target["id"] != target_id
        or target["tuple"]["revision"] != auth["revision"]
        or target["tuple"]["version"] != auth["version"]
        or target["tuple"]["repositoryDigest"] != repository
        or target["tuple"]["platformImageId"] != image_id
    ):
        _reject("RECOVERY_SELECTOR_MISMATCH")
    return {
        "outcome": "already-completed" if state["phase"] == "COMMITTED" else "authorized",
        "action": "retry-exact-candidate",
        "incidentId": state["incidentId"], "operationEpoch": state["operationEpoch"],
    }


def _safe_stat(fd: int, name: str, expected_mode: int, max_bytes: int | None = None) -> os.stat_result:
    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
        _reject("STATE_PATH_UNSAFE")
    if stat.S_IMODE(info.st_mode) != expected_mode or (max_bytes is not None and info.st_size > max_bytes):
        _reject("STATE_PATH_UNSAFE")
    return info


def _require_no_acl(fd: int, *, directory: bool = False) -> None:
    target = f"/proc/self/fd/{fd}"
    attributes = ("system.posix_acl_access", "system.posix_acl_default") if directory else (
        "system.posix_acl_access",
    )
    for attribute in attributes:
        try:
            os.getxattr(target, attribute, follow_symlinks=True)
        except OSError as exc:
            if exc.errno in (errno.ENODATA, getattr(errno, "ENOATTR", errno.ENODATA)):
                continue
            _reject("ACL_CHECK_UNAVAILABLE" if exc.errno in (errno.ENOTSUP, errno.EOPNOTSUPP)
                    else "STATE_PATH_UNSAFE")
        else:
            _reject("STATE_PATH_UNSAFE")


def _open_root(path: str | os.PathLike[str]) -> int:
    if os.name != "posix" or not hasattr(os, "O_NOFOLLOW"):
        _reject("LINUX_REQUIRED")
    root = Path(path)
    if not root.is_absolute() or ".." in root.parts:
        _reject("ROOT_INVALID")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in root.parts[1:]:
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                _reject("STATE_MISSING")
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            mode = stat.S_IMODE(info.st_mode)
            sticky_shared_tmp = info.st_uid == 0 and bool(mode & stat.S_ISVTX) and \
                (mode & (stat.S_IWGRP | stat.S_IWOTH)) == (stat.S_IWGRP | stat.S_IWOTH)
            if info.st_uid != 0 or (mode & 0o022 and not sticky_shared_tmp):
                _reject("ROOT_UNSAFE")
            _require_no_acl(fd, directory=True)
        return fd
    except Exception:
        os.close(fd)
        raise


def _read_at(dir_fd: int, name: str, limit: int, mode: int = 0o600) -> bytes:
    info = _safe_stat(dir_fd, name, mode, limit)
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    try:
        if os.fstat(fd) != info:
            # stat_result equality is exact and catches replacement between checks.
            _reject("STATE_RACE")
        _require_no_acl(fd)
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(8192, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            _reject("STATE_TOO_LARGE")
        return bytes(data)
    finally:
        os.close(fd)


def _read_execution_lease_locked(root: str | os.PathLike[str]) -> dict[str, Any] | None:
    root_fd = _open_root(root)
    try:
        try:
            raw = _read_at(root_fd, EXECUTION_LEASE_NAME, MAX_EXECUTION_LEASE_BYTES)
        except FileNotFoundError:
            return None
        lease = _execution_lease(parse_json(raw, MAX_EXECUTION_LEASE_BYTES))
        if _canonical(lease) != raw:
            _reject("EXECUTION_LEASE_INVALID")
        return lease
    finally:
        os.close(root_fd)


def _execution_lease_supervisor_is_live(lease: Mapping[str, Any]) -> bool:
    """A matching nonce alone never revives a lease after its supervisor exits."""
    supervisor = lease["supervisor"]
    if not isinstance(supervisor, Mapping):
        return False
    try:
        with open("/proc/sys/kernel/random/boot_id", "rt", encoding="ascii") as stream:
            boot_id = stream.read(129).strip()
        with open(f"/proc/{supervisor['pid']}/stat", "rb") as stream:
            raw = stream.read(4097)
        if len(raw) > 4096 or not raw.endswith(b"\n"):
            return False
        end = raw.rfind(b")")
        if end < 0:
            return False
        fields = raw[end + 2:-1].split()
        if len(fields) < 20:
            return False
        start_ticks = int(fields[19])
    except (OSError, ValueError):
        return False
    return (
        type(supervisor.get("pid")) is int
        and type(supervisor.get("startTicks")) is int
        and start_ticks == supervisor["startTicks"]
        and boot_id == supervisor.get("bootId")
    )


def _validate_lease_successor(previous: Mapping[str, Any], candidate: Mapping[str, Any]) -> None:
    immutable = ("attempt", "operation", "supervisor")
    if any(previous[key] != candidate[key] for key in immutable):
        _reject("EXECUTION_LEASE_CONFLICT")
    if candidate["revision"] != previous["revision"] + 1:
        _reject("EXECUTION_LEASE_REVISION_CONFLICT")
    if previous["rollbackIssued"] and not candidate["rollbackIssued"]:
        _reject("EXECUTION_LEASE_ROLLBACK_CONFLICT")
    if previous["firstFailure"] is not None and any(
        previous[key] != candidate[key] for key in ("firstFailure", "firstStatus")
    ):
        _reject("EXECUTION_LEASE_FAILURE_CONFLICT")
    if previous["t0Ns"] is not None and any(
        previous[key] != candidate[key] for key in ("t0Ns", "workEndNs", "hardEndNs")
    ):
        _reject("EXECUTION_LEASE_DEADLINE_CONFLICT")
    lifecycle_edges = {
        "registered": {"registered", "armed", "draining"},
        "armed": {"armed", "cancel-forward", "drain-forward", "rollback-admission",
                  "draining", "quiescence-unconfirmed", "drained"},
        "cancel-forward": {"cancel-forward", "drain-forward", "draining",
                           "rollback-admission", "quiescence-unconfirmed", "drained"},
        "drain-forward": {"drain-forward", "rollback-admission", "draining",
                          "quiescence-unconfirmed", "drained"},
        "rollback-admission": {"rollback-admission", "rolling-back", "draining",
                               "quiescence-unconfirmed", "drained"},
        "rolling-back": {"rolling-back", "draining", "quiescence-unconfirmed", "drained"},
        "draining": {"draining", "quiescence-unconfirmed", "drained"},
        "quiescence-unconfirmed": {"quiescence-unconfirmed", "drained"},
        "drained": {"drained"},
    }
    if candidate["lifecycle"] not in lifecycle_edges[previous["lifecycle"]]:
        _reject("EXECUTION_LEASE_LIFECYCLE_CONFLICT")
    old_workers, new_workers = previous["workers"], candidate["workers"]
    if new_workers[:len(old_workers)] != old_workers:
        _reject("EXECUTION_LEASE_WORKER_CONFLICT")


def publish_execution_lease(
    root: str | os.PathLike[str],
    lease: Mapping[str, Any] | bytes,
    *,
    deploy_lock_fd: int,
) -> dict[str, Any]:
    """Atomically publish one supervisor lease revision while holding inherited FD9."""
    if isinstance(lease, bytes):
        candidate = _execution_lease(parse_json(lease, MAX_EXECUTION_LEASE_BYTES))
        raw = lease
        if _canonical(candidate) != raw:
            _reject("EXECUTION_LEASE_INVALID")
    else:
        candidate = _execution_lease(dict(lease))
        raw = _canonical(candidate)
    if len(raw) > MAX_EXECUTION_LEASE_BYTES:
        _reject("INPUT_TOO_LARGE")
    with deploy_lock(root, deploy_lock_fd):
        previous = _read_execution_lease_locked(root)
        if previous is None:
            if candidate["revision"] != 0 or candidate["lifecycle"] != "registered":
                _reject("EXECUTION_LEASE_REVISION_CONFLICT")
            try:
                _, current = _read_guard_locked(root)
            except FileNotFoundError:
                current = None
            if current is not None and (
                current["phase"] not in TERMINAL | {"READY"}
                or current["executionAttempt"] is not None
                and current["executionAttempt"] != candidate["attempt"]
            ):
                _reject("EXECUTION_LEASE_UNRESOLVED")
        else:
            if not _execution_lease_supervisor_is_live(previous):
                _reject("EXECUTION_LEASE_UNRESOLVED")
            _validate_lease_successor(previous, candidate)
        if not _execution_lease_supervisor_is_live(candidate):
            _reject("EXECUTION_LEASE_UNRESOLVED")
        root_fd = _open_root(root)
        try:
            _atomic_write(root_fd, EXECUTION_LEASE_NAME, raw,
                          MAX_EXECUTION_LEASE_BYTES, replace=previous is not None)
            if _read_at(root_fd, EXECUTION_LEASE_NAME, MAX_EXECUTION_LEASE_BYTES) != raw:
                _reject("EXECUTION_LEASE_READBACK_FAILED")
        finally:
            os.close(root_fd)
    return {
        "attempt": candidate["attempt"],
        "revision": candidate["revision"],
        "digest": hashlib.sha256(raw).hexdigest(),
    }


def check_execution_lease(
    root: str | os.PathLike[str],
    *,
    attempt: str | None = None,
    deploy_lock_fd: int | None = None,
) -> dict[str, Any]:
    """Read-only writer/retention interlock; never removes or reconciles a lease."""
    with deploy_lock(root, deploy_lock_fd):
        lease = _read_execution_lease_locked(root)
        if lease is None:
            return {"outcome": "unleased"}
        if deploy_lock_fd is None:
            _reject("EXECUTION_LEASE_FD_REQUIRED")
        if not _execution_lease_supervisor_is_live(lease):
            _reject("EXECUTION_LEASE_UNRESOLVED")
        if attempt is None or attempt != lease["attempt"]:
            _reject("EXECUTION_LEASE_UNRESOLVED")
        if lease["lifecycle"] in {"quiescence-unconfirmed", "drained"}:
            _reject("EXECUTION_LEASE_UNRESOLVED")
        return {"attempt": lease["attempt"], "revision": lease["revision"], "outcome": "matched"}


def _require_execution_lease_descriptor(
    root: str | os.PathLike[str],
    deploy_lock_fd: int | None,
) -> None:
    if _read_execution_lease_locked(root) is not None and deploy_lock_fd is None:
        _reject("EXECUTION_LEASE_FD_REQUIRED")


def _atomic_write(dir_fd: int, name: str, data: bytes, limit: int, *, replace: bool) -> None:
    if len(data) > limit:
        _reject("STATE_TOO_LARGE")
    if any(entry.startswith(".tmp-") for entry in os.listdir(dir_fd)):
        _reject("STATE_TEMP_CONFLICT")
    temp = ".tmp-" + secrets.token_hex(12)
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        os.fchmod(fd, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or \
                stat.S_IMODE(info.st_mode) != 0o600:
            _reject("STATE_PATH_UNSAFE")
        _require_no_acl(fd)
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                _reject("STATE_WRITE_FAILED")
            view = view[written:]
        os.fsync(fd)
    except Exception:
        os.close(fd)
        os.unlink(temp, dir_fd=dir_fd)
        raise
    os.close(fd)
    try:
        if replace:
            existing = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
            if not stat.S_ISREG(existing.st_mode) or existing.st_uid != 0 or existing.st_nlink != 1 or \
                    stat.S_IMODE(existing.st_mode) != 0o600:
                _reject("STATE_PATH_UNSAFE")
            os.replace(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        else:
            os.link(temp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd, follow_symlinks=False)
            os.unlink(temp, dir_fd=dir_fd)
        os.fsync(dir_fd)
    except Exception:
        try:
            os.unlink(temp, dir_fd=dir_fd)
        except FileNotFoundError:
            pass
        raise


def _rename_noreplace(dir_fd: int, source: str, destination: str) -> None:
    try:
        renameat2 = ctypes.CDLL(None, use_errno=True).renameat2
    except AttributeError:
        _reject("ATOMIC_RENAME_UNAVAILABLE")
    renameat2.argtypes = (
        ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint,
    )
    renameat2.restype = ctypes.c_int
    if renameat2(
        dir_fd, os.fsencode(source), dir_fd, os.fsencode(destination), RENAME_NOREPLACE,
    ) != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            _reject("BOOTSTRAP_CONFLICT")
        _reject("ATOMIC_RENAME_FAILED")


def _read_guard_locked(root: str | os.PathLike[str]) -> tuple[dict[str, Any], dict[str, Any]]:
    root_fd = _open_root(root)
    try:
        guard_fd = os.open(GUARD_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            info = os.fstat(guard_fd)
            if info.st_uid != 0 or info.st_nlink != 2 or stat.S_IMODE(info.st_mode) != 0o700:
                _reject("STATE_PATH_UNSAFE")
            _require_no_acl(guard_fd, directory=True)
            names = set(os.listdir(guard_fd))
            if names - {"origin.json", "current.json"}:
                _reject("STATE_TEMP_CONFLICT")
            if names != {"origin.json", "current.json"}:
                _reject("GUARD_STATE_LOST")
            try:
                origin_raw = _read_at(guard_fd, "origin.json", MAX_ORIGIN_BYTES)
            except FileNotFoundError:
                _reject("GUARD_STATE_LOST")
            origin = _origin(parse_json(origin_raw, MAX_ORIGIN_BYTES))
            try:
                current_raw = _read_at(guard_fd, "current.json", MAX_CURRENT_BYTES)
            except FileNotFoundError:
                _reject("GUARD_STATE_LOST")
            current = _current(parse_json(current_raw, MAX_CURRENT_BYTES))
            if current["originDigest"] != origin["originDigest"]:
                _reject("GUARD_STATE_LOST")
            return origin, current
        finally:
            os.close(guard_fd)
    finally:
        os.close(root_fd)


def read_guard(
    root: str | os.PathLike[str],
    *,
    deploy_lock_fd: int | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    with deploy_lock(root, deploy_lock_fd):
        return _read_guard_locked(root)


def _publish_current_locked(root: str | os.PathLike[str], state: Mapping[str, Any]) -> dict[str, Any]:
    validated = _current(dict(state))
    root_fd = _open_root(root)
    try:
        guard_fd = os.open(GUARD_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            guard_info = os.fstat(guard_fd)
            if guard_info.st_uid != 0 or guard_info.st_nlink != 2 or stat.S_IMODE(guard_info.st_mode) != 0o700:
                _reject("STATE_PATH_UNSAFE")
            _require_no_acl(guard_fd, directory=True)
            if set(os.listdir(guard_fd)) != {"origin.json", "current.json"}:
                _reject("GUARD_STATE_LOST")
            try:
                origin_raw = _read_at(guard_fd, "origin.json", MAX_ORIGIN_BYTES)
            except FileNotFoundError:
                _reject("GUARD_STATE_LOST")
            origin = _origin(parse_json(origin_raw, MAX_ORIGIN_BYTES))
            current_raw = _read_at(guard_fd, "current.json", MAX_CURRENT_BYTES)
            if set(os.listdir(guard_fd)) != {"origin.json", "current.json"}:
                _reject("STATE_TEMP_CONFLICT")
            old = _current(parse_json(current_raw, MAX_CURRENT_BYTES))
            if origin["originDigest"] != old["originDigest"]:
                _reject("GUARD_STATE_LOST")
            lease = _read_execution_lease_locked(root)
            if lease is None and (
                old["executionAttempt"] is not None or validated["executionAttempt"] is not None
            ):
                _reject("EXECUTION_LEASE_UNRESOLVED")
            if lease is not None:
                if validated["executionAttempt"] != lease["attempt"]:
                    _reject("EXECUTION_LEASE_UNRESOLVED")
                if not _execution_lease_supervisor_is_live(lease):
                    _reject("EXECUTION_LEASE_UNRESOLVED")
                if lease["lifecycle"] == "quiescence-unconfirmed":
                    _reject("EXECUTION_LEASE_UNRESOLVED")
            validate_state_transition(old, validated)
            old_child, new_child = old["ownedChild"], validated["ownedChild"]
            if old_child is not None and (
                new_child is None
                or (new_child["lifecycle"] == "reaped" and old_child["lifecycle"] != "reaped")
            ):
                # Both CLI paths publish here: neither may attest reap or discard
                # ownership while any member of the recorded group remains.
                require_child_group_quiescent(old_child)
            raw = _canonical(validated)
            _atomic_write(guard_fd, "current.json", raw, MAX_CURRENT_BYTES, replace=True)
            if _read_at(guard_fd, "current.json", MAX_CURRENT_BYTES) != raw:
                _reject("STATE_READBACK_FAILED")
            return validated
        finally:
            os.close(guard_fd)
    finally:
        os.close(root_fd)


def publish_current(
    root: str | os.PathLike[str],
    state: Mapping[str, Any],
    *,
    deploy_lock_fd: int | None = None,
) -> dict[str, Any]:
    with deploy_lock(root, deploy_lock_fd):
        _require_execution_lease_descriptor(root, deploy_lock_fd)
        return _publish_current_locked(root, state)


def _bootstrap_guard_locked(
    root: str | os.PathLike[str],
    *,
    authority: Mapping[str, Any],
    observed: Mapping[str, Any],
) -> dict[str, Any]:
    """Publish explicit initial authority; never infer from an existing runtime."""
    auth = _object(dict(authority), {
        "rootId", "bootstrapId", "initialRuntime", "initialConfig",
        "initialSchema", "initialStartupInventory", "schemaHistoryProvenance",
    })
    obs = _object(dict(observed), {
        "rootId", "runtime", "config", "schema", "startupInventory",
        "schemaHistoryProvenance",
    })
    _text(auth["rootId"], pattern=ROOT_KEY)
    _text(auth["bootstrapId"], pattern=IDENTIFIER)
    for key in ("initialRuntime", "initialConfig", "initialSchema", "initialStartupInventory"):
        _digest(auth[key])
    _bool(auth["schemaHistoryProvenance"])
    if not auth["schemaHistoryProvenance"] or any(
        obs[key] != auth[source] for key, source in (
            ("rootId", "rootId"), ("runtime", "initialRuntime"), ("config", "initialConfig"),
            ("schema", "initialSchema"), ("startupInventory", "initialStartupInventory"),
            ("schemaHistoryProvenance", "schemaHistoryProvenance"),
        )
    ):
        _reject("BOOTSTRAP_EVIDENCE_MISMATCH")
    origin_unsigned = {
        "schema": ORIGIN_SCHEMA, "controller": CONTROLLER, "rootId": auth["rootId"],
        "bootstrapId": auth["bootstrapId"], "initialRuntime": auth["initialRuntime"],
        "initialConfig": auth["initialConfig"], "initialSchema": auth["initialSchema"],
        "initialStartupInventory": auth["initialStartupInventory"],
        "schemaHistoryProvenance": True,
    }
    origin = dict(origin_unsigned, originDigest=hashlib.sha256(_canonical(origin_unsigned)).hexdigest())
    current = new_ready_state(origin["originDigest"])
    origin_raw, current_raw = _canonical(origin), _canonical(current)
    if len(origin_raw) > MAX_ORIGIN_BYTES or len(current_raw) > MAX_CURRENT_BYTES:
        _reject("STATE_TOO_LARGE")
    root_fd = _open_root(root)
    try:
        staging = ".timepad-bootstrap-" + auth["bootstrapId"]
        staged_siblings = {
            entry for entry in os.listdir(root_fd)
            if entry.startswith(".timepad-bootstrap-")
        }
        if staged_siblings - {staging}:
            _reject("BOOTSTRAP_STAGING_CONFLICT")
        try:
            guard_fd = os.open(GUARD_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        except FileNotFoundError:
            created = False
            try:
                stage_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            except FileNotFoundError:
                os.mkdir(staging, 0o700, dir_fd=root_fd)
                os.fsync(root_fd)
                stage_fd = os.open(staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
                created = True
            try:
                stage_info = os.fstat(stage_fd)
                if stage_info.st_uid != 0 or stage_info.st_nlink != 2 or \
                        stat.S_IMODE(stage_info.st_mode) != 0o700:
                    _reject("BOOTSTRAP_STAGING_UNSAFE")
                _require_no_acl(stage_fd, directory=True)
                entries = set(os.listdir(stage_fd))
                if entries - {"origin.json", "current.json"}:
                    _reject("BOOTSTRAP_STAGING_UNAUTHENTICATED")
                if created:
                    _atomic_write(stage_fd, "origin.json", origin_raw, MAX_ORIGIN_BYTES, replace=False)
                    _atomic_write(stage_fd, "current.json", current_raw, MAX_CURRENT_BYTES, replace=False)
                else:
                    if "origin.json" not in entries:
                        _reject("BOOTSTRAP_STAGING_UNAUTHENTICATED")
                    staged_origin = _origin(parse_json(
                        _read_at(stage_fd, "origin.json", MAX_ORIGIN_BYTES), MAX_ORIGIN_BYTES
                    ))
                    if staged_origin != origin:
                        _reject("BOOTSTRAP_CONFLICT")
                    if "current.json" not in entries:
                        _atomic_write(stage_fd, "current.json", current_raw, MAX_CURRENT_BYTES, replace=False)
                    else:
                        staged_current = _current(parse_json(
                            _read_at(stage_fd, "current.json", MAX_CURRENT_BYTES), MAX_CURRENT_BYTES
                        ))
                        if staged_current != current:
                            _reject("BOOTSTRAP_CONFLICT")
                os.fsync(stage_fd)
            finally:
                os.close(stage_fd)
            _rename_noreplace(root_fd, staging, GUARD_DIR)
            os.fsync(root_fd)
            published_fd = os.open(GUARD_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            try:
                if _read_at(published_fd, "origin.json", MAX_ORIGIN_BYTES) != origin_raw or \
                        _read_at(published_fd, "current.json", MAX_CURRENT_BYTES) != current_raw:
                    _reject("BOOTSTRAP_READBACK_FAILED")
            finally:
                os.close(published_fd)
            return {"outcome": "bootstrapped", "originDigest": origin["originDigest"], "epoch": 0}
        try:
            guard_info = os.fstat(guard_fd)
            if guard_info.st_uid != 0 or stat.S_IMODE(guard_info.st_mode) != 0o700:
                _reject("STATE_PATH_UNSAFE")
            _require_no_acl(guard_fd, directory=True)
            if set(os.listdir(guard_fd)) - {"origin.json", "current.json"}:
                _reject("STATE_TEMP_CONFLICT")
            try:
                old_origin = _origin(parse_json(
                    _read_at(guard_fd, "origin.json", MAX_ORIGIN_BYTES), MAX_ORIGIN_BYTES
                ))
                old_current = _current(parse_json(
                    _read_at(guard_fd, "current.json", MAX_CURRENT_BYTES), MAX_CURRENT_BYTES
                ))
            except FileNotFoundError:
                _reject("GUARD_STATE_LOST")
            if old_origin != origin or old_current["originDigest"] != origin["originDigest"]:
                _reject("BOOTSTRAP_CONFLICT")
            if old_current["operationEpoch"] == 0 and old_current["phase"] == "READY":
                return {"outcome": "already-initialized", "originDigest": origin["originDigest"], "epoch": 0}
            _reject("BOOTSTRAP_NOT_INITIAL")
        finally:
            os.close(guard_fd)
    finally:
        os.close(root_fd)


def bootstrap_guard(
    root: str | os.PathLike[str],
    *,
    authority: Mapping[str, Any],
    observed: Mapping[str, Any],
    deploy_lock_fd: int | None = None,
) -> dict[str, Any]:
    with deploy_lock(root, deploy_lock_fd):
        return _bootstrap_guard_locked(root, authority=authority, observed=observed)


def _validate_lock_fd(fd: int, root_fd: int) -> None:
    if type(fd) is not int or fd < 0:
        _reject("DEPLOY_LOCK_INVALID")
    try:
        info = os.fstat(fd)
        path_info = os.stat(LOCK_NAME, dir_fd=root_fd, follow_symlinks=False)
    except OSError:
        _reject("DEPLOY_LOCK_INVALID")
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != 0 or \
            stat.S_IMODE(info.st_mode) not in {0o600, 0o640, 0o644} or \
            (info.st_dev, info.st_ino) != (path_info.st_dev, path_info.st_ino):
        _reject("DEPLOY_LOCK_INVALID")
    _require_no_acl(fd)


def _read_input(path: str | os.PathLike[str], limit: int) -> bytes:
    try:
        with open(path, "rb") as source:
            data = source.read(limit + 1)
    except OSError:
        _reject("INPUT_UNAVAILABLE")
    if len(data) > limit:
        _reject("INPUT_TOO_LARGE")
    return data


@contextmanager
def deploy_lock(root: str | os.PathLike[str], inherited_fd: int | None = None) -> Iterator[int]:
    """Acquire .deploy.lock nonblocking; inherited descriptors are never unlocked."""
    if fcntl is None:
        _reject("LINUX_REQUIRED")
    owned = inherited_fd is None
    root_fd = _open_root(root)
    fd = inherited_fd
    locked = False
    try:
        if owned:
            try:
                fd = os.open(LOCK_NAME, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
            except FileNotFoundError:
                try:
                    created = os.open(
                        LOCK_NAME, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o600, dir_fd=root_fd,
                    )
                except FileExistsError:
                    pass
                else:
                    try:
                        os.fsync(created)
                        os.fsync(root_fd)
                    finally:
                        os.close(created)
                fd = os.open(LOCK_NAME, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
        _validate_lock_fd(fd, root_fd)
        if not owned:
            try:
                if not os.get_inheritable(fd):
                    _reject("DEPLOY_LOCK_INVALID")
            except OSError:
                _reject("DEPLOY_LOCK_INVALID")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            _reject("DEPLOY_LOCK_BUSY")
        locked = True
        _validate_lock_fd(fd, root_fd)
        yield fd
    finally:
        if owned:
            try:
                if locked:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                if fd is not None:
                    os.close(fd)
        os.close(root_fd)


def _cli() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check-contract")
    check.add_argument("--contract", required=True)
    admission = sub.add_parser("admit")
    admission.add_argument("--root", required=True)
    admission.add_argument("--contract", required=True)
    admission.add_argument("--evidence", required=True)
    admission.add_argument("--deploy-lock-fd", type=int)
    read = sub.add_parser("read-state")
    read.add_argument("--root", required=True)
    read.add_argument("--deploy-lock-fd", type=int)
    recovery = sub.add_parser("authorize-recovery")
    recovery.add_argument("--root", required=True)
    recovery.add_argument("--authorization", required=True)
    recovery.add_argument("--deploy-lock-fd", type=int)
    bootstrap = sub.add_parser("bootstrap")
    bootstrap.add_argument("--root", required=True)
    bootstrap.add_argument("--authority", required=True)
    bootstrap.add_argument("--observed", required=True)
    bootstrap.add_argument("--deploy-lock-fd", type=int)
    publish = sub.add_parser("publish-state")
    publish.add_argument("--root", required=True)
    publish.add_argument("--state", required=True)
    publish.add_argument("--deploy-lock-fd", type=int)
    lease = sub.add_parser("publish-lease")
    lease.add_argument("--root", required=True)
    lease.add_argument("--lease", required=True)
    lease.add_argument("--deploy-lock-fd", type=int, required=True)
    lease_check = sub.add_parser("check-lease")
    lease_check.add_argument("--root", required=True)
    lease_check.add_argument("--attempt")
    lease_check.add_argument("--deploy-lock-fd", type=int, required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--root", required=True)
    prepare.add_argument("--contract", required=True)
    prepare.add_argument("--evidence", required=True)
    prepare.add_argument("--deploy-lock-fd", type=int)
    advance = sub.add_parser("advance")
    advance.add_argument("--root", required=True)
    advance.add_argument("--phase", required=True, choices=sorted(PHASES - {"READY", "PREPARED"}))
    advance.add_argument("--changes", required=True)
    advance.add_argument("--deploy-lock-fd", type=int)
    claim_rollback = sub.add_parser("claim-rollback")
    claim_rollback.add_argument("--root", required=True)
    claim_rollback.add_argument("--deploy-lock-fd", type=int, required=True)
    lock = sub.add_parser("lock-check")
    lock.add_argument("--root", required=True)
    lock.add_argument("--deploy-lock-fd", type=int)
    capture_child = sub.add_parser("capture-child")
    capture_child.add_argument("--pid", required=True, type=int)
    capture_child.add_argument("--command-digest", required=True)
    capture_child.add_argument("--attempt-id", required=True)
    stop_child = sub.add_parser("stop-owned-child")
    stop_child.add_argument("--root", required=True)
    stop_child.add_argument("--deploy-lock-fd", type=int, required=True)
    stop_child.add_argument("--term-grace-seconds", type=float, default=5.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _cli().parse_args(argv)
    try:
        if args.command == "check-contract":
            contract = parse_contract(_read_input(args.contract, MAX_CONTRACT_BYTES))
            result: Any = {"outcome": "valid", "active": contract["active"]}
        elif args.command == "admit":
            contract = parse_contract(_read_input(args.contract, MAX_CONTRACT_BYTES))
            evidence = parse_json(_read_input(args.evidence, MAX_AUTHORIZATION_BYTES), MAX_AUTHORIZATION_BYTES)
            with deploy_lock(args.root, args.deploy_lock_fd):
                parsed_evidence = _object(
                    evidence,
                    {"rootId", "targetId", "predecessorId", "transitionId", "target", "predecessor"},
                )
                result = admit(
                    contract,
                    root_id=parsed_evidence["rootId"],
                    target_id=parsed_evidence["targetId"],
                    predecessor_id=parsed_evidence["predecessorId"],
                    transition_id=parsed_evidence["transitionId"],
                    target_tuple=parsed_evidence["target"],
                    predecessor_tuple=parsed_evidence["predecessor"],
                ).as_dict()
                if result["disposition"] == "refuse":
                    _reject(result["reason"])
        elif args.command == "read-state":
            origin, current = read_guard(args.root, deploy_lock_fd=args.deploy_lock_fd)
            result = {"outcome": "read", "originDigest": origin["originDigest"], "current": current}
        elif args.command == "authorize-recovery":
            authorization = _read_input(args.authorization, MAX_AUTHORIZATION_BYTES)
            with deploy_lock(args.root, args.deploy_lock_fd):
                origin, current = _read_guard_locked(args.root)
                result = authorize_recovery(
                    authorization, root_id=origin["rootId"], current=current
                )
        elif args.command == "bootstrap":
            authority = parse_json(_read_input(args.authority, MAX_AUTHORIZATION_BYTES), MAX_AUTHORIZATION_BYTES)
            observed = parse_json(_read_input(args.observed, MAX_AUTHORIZATION_BYTES), MAX_AUTHORIZATION_BYTES)
            result = bootstrap_guard(
                args.root, authority=authority, observed=observed,
                deploy_lock_fd=args.deploy_lock_fd,
            )
        elif args.command == "publish-state":
            state = parse_json(_read_input(args.state, MAX_CURRENT_BYTES), MAX_CURRENT_BYTES)
            result = publish_current(args.root, state, deploy_lock_fd=args.deploy_lock_fd)
        elif args.command == "publish-lease":
            lease = _read_input(args.lease, MAX_EXECUTION_LEASE_BYTES)
            result = publish_execution_lease(
                args.root, lease, deploy_lock_fd=args.deploy_lock_fd,
            )
        elif args.command == "check-lease":
            result = check_execution_lease(
                args.root, attempt=args.attempt, deploy_lock_fd=args.deploy_lock_fd,
            )
        elif args.command == "prepare":
            contract = parse_contract(_read_input(args.contract, MAX_CONTRACT_BYTES))
            evidence = _object(
                parse_json(_read_input(args.evidence, MAX_AUTHORIZATION_BYTES), MAX_AUTHORIZATION_BYTES),
                {"rootId", "targetId", "predecessorId", "predecessorContainerId",
                 "transitionId", "target", "predecessor",
                 "operation", "runId", "incidentId", "ownedRun", "toolingDigest",
                 "preparedProofDigest"},
            )
            with deploy_lock(args.root, args.deploy_lock_fd):
                origin, current = _read_guard_locked(args.root)
                admission = admit(
                    contract, root_id=evidence["rootId"], target_id=evidence["targetId"],
                    predecessor_id=evidence["predecessorId"], transition_id=evidence["transitionId"],
                    target_tuple=evidence["target"], predecessor_tuple=evidence["predecessor"],
                )
                if admission.disposition == "refuse":
                    _reject(admission.reason)
                if evidence["rootId"] != origin["rootId"]:
                    _reject("CONTRACT_INACTIVE_OR_WRONG_ROOT")
                parsed_contract = parse_contract(contract)
                target = next((item for item in parsed_contract["images"]
                               if item["id"] == evidence["targetId"]), None)
                if target is None:
                    target = next((item for item in parsed_contract["initialDomain"]
                                   if item["id"] == evidence["targetId"]), None)
                predecessor = next((item for item in parsed_contract["images"]
                                    if item["id"] == evidence["predecessorId"]), None)
                if predecessor is None:
                    predecessor = next((item for item in parsed_contract["initialDomain"]
                                        if item["id"] == evidence["predecessorId"]), None)
                if target is None or predecessor is None:
                    _reject("IMAGE_NOT_REVIEWED")
                prepared = new_prepared_state(
                    current, operation=evidence["operation"], run_id=evidence["runId"],
                    incident_id=evidence["incidentId"], admission=admission,
                    target={"id": target["id"], "tuple": evidence["target"],
                            "domain": target.get("domain", "initial")},
                    predecessor={"id": predecessor["id"], "tuple": evidence["predecessor"],
                                 "domain": predecessor.get("domain", "initial")},
                    predecessor_container_id=evidence["predecessorContainerId"],
                    transition_id=evidence["transitionId"], owned_run=evidence["ownedRun"],
                    tooling_digest=evidence["toolingDigest"],
                    prepared_proof_digest=evidence["preparedProofDigest"],
                    execution_attempt=(
                        (lease["attempt"] if lease is not None else None)
                    ) if (lease := _read_execution_lease_locked(args.root)) is not None else None,
                )
                published = _publish_current_locked(args.root, prepared)
                if _read_guard_locked(args.root)[1] != published:
                    _reject("STATE_READBACK_FAILED")
                result = {
                    "admission": admission.disposition, "epoch": published["operationEpoch"],
                    "incidentId": published["incidentId"], "result": published["phase"],
                }
        elif args.command == "advance":
            changes = _object(
                parse_json(_read_input(args.changes, MAX_CHANGES_BYTES), MAX_CHANGES_BYTES),
                {"changes"},
            )["changes"]
            allowed_changes = {
                "reason", "containerId", "configHash", "ownedChild", "commitWitnessDigest",
                "providerFinalizationDigest",
                "commitSubstep", "terminalReceipt", "latestAttemptId",
            }
            if not isinstance(changes, dict) or not changes.keys() <= allowed_changes:
                _reject("STATE_CHANGE_UNSUPPORTED")
            with deploy_lock(args.root, args.deploy_lock_fd):
                _require_execution_lease_descriptor(args.root, args.deploy_lock_fd)
                _, current = _read_guard_locked(args.root)
                advanced = advance_state(current, args.phase, **changes)
                published = _publish_current_locked(args.root, advanced)
                if _read_guard_locked(args.root)[1] != published:
                    _reject("STATE_READBACK_FAILED")
                result = {
                    "epoch": published["operationEpoch"], "incidentId": published["incidentId"],
                    "result": published["phase"],
                }
        elif args.command == "claim-rollback":
            with deploy_lock(args.root, args.deploy_lock_fd):
                _require_execution_lease_descriptor(args.root, args.deploy_lock_fd)
                _, current = _read_guard_locked(args.root)
                disposition = current["predecessorDisposition"]
                if (
                    current["rollbackIssued"]
                    or current["phase"] not in {"PREPARED", "CUTOVER_POSSIBLE", "VERIFYING"}
                    or current["ownedChild"] is not None
                    or current["commitWitnessDigest"] is not None
                    or current["providerFinalizationDigest"] is not None
                    or disposition not in {"pre-barrier-only", "post-barrier-compatible"}
                    or current["phase"] in {"CUTOVER_POSSIBLE", "VERIFYING"}
                    and disposition != "post-barrier-compatible"
                ):
                    _reject("ROLLBACK_NOT_ADMITTED")
                claimed = advance_state(
                    current,
                    "ROLLING_BACK",
                    reason="ROLLBACK_ADMITTED",
                    rollbackIssued=True,
                )
                published = _publish_current_locked(args.root, claimed)
                if _read_guard_locked(args.root)[1] != published:
                    _reject("STATE_READBACK_FAILED")
                result = {
                    "result": "rollback-admitted",
                    "epoch": published["operationEpoch"],
                    "incidentId": published["incidentId"],
                }
        elif args.command == "capture-child":
            result = capture_owned_child(
                args.pid,
                command_digest=args.command_digest,
                attempt_id=args.attempt_id,
            )
        elif args.command == "stop-owned-child":
            result = stop_owned_child(
                args.root,
                deploy_lock_fd=args.deploy_lock_fd,
                term_grace_seconds=args.term_grace_seconds,
            )
        else:
            with deploy_lock(args.root, args.deploy_lock_fd):
                result = {"outcome": "locked"}
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return 0
    except GuardError as exc:
        print(exc.reason, file=sys.stderr)
        return 2
    except OSError:
        print("FILESYSTEM_OPERATION_FAILED", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
