#!/usr/bin/env python3
"""Private, fail-closed Firebase credential reconciliation for the release lane.

This module deliberately has no external network, Docker, shell, or environment mutation
capability.  Bash owns deployment ordering and recovery; this process only
validates bounded private observations and performs the fixed-path credential
transaction.

Controller-dispatched operations bind --execution-attempt, --execution-grant
and --deadline-ns to the inherited private supervisor channel. The durable
lease and deploy lock do not replace live revocation checks at mutation/wait
boundaries. Direct public operations without a lease retain their ordinary API.
"""

from __future__ import annotations

import argparse
import contextlib
import contextvars
import ctypes
import errno
import hashlib
import importlib.util
import ipaddress
import json
import os
import pathlib
import re
import secrets
import select
import stat
import sys
import time
from typing import Any, Callable, Iterable, Iterator

try:
    import fcntl
except ImportError:  # The production cleanup protocol requires Linux.
    fcntl = None

SCHEMA_VERSION = 1
MAX_INSPECTION_BYTES = 8 * 1024 * 1024
MAX_CREDENTIAL_BYTES = 1024 * 1024
MAX_WITNESS_BYTES = 16 * 1024 * 1024
MAX_FINALIZATION_BYTES = 8 * 1024
MAX_PREPARED_BYTES = 8 * 1024
MAX_MODEL_BYTES = 256 * 1024
MAX_RESOURCES_BYTES = 16 * 1024
MAX_RESOURCE_REQUEST_BYTES = 4 * 1024
MAX_RESOURCE_ENTRIES = 256
RESOURCE_ADMISSION_SCHEMA = "meet-backend/test-vps-timepad-resource-admission/v1"
RESOURCE_BASELINE_SCHEMA = "meet-backend/test-vps-timepad-resources/v1"
RESOURCE_PROJECT = "meet-production"
RESOURCE_NETWORK = "meet-production_default"
RESOURCE_VOLUMES = {
    "uploads_data": "meet-production_uploads_data",
    "postgres_data": "meet-production_postgres_data",
}
POSTGRES_IMAGE = (
    "postgres:16-alpine@sha256:"
    "4327b9fd295502f326f44153a1045a7170ddbfffed1c3829798328556cfd09e2"
)
MAX_JSON_DEPTH = 32
MAX_OWNER_BYTES = 4096
CONTAINER_CREDENTIAL_PATH = "/run/secrets/meet-firebase-service-account.json"
HOST_CREDENTIAL_PARENT = "/var/lib/meet-production/credentials"
HOST_CREDENTIAL_PATH = HOST_CREDENTIAL_PARENT + "/firebase-service-account.json"
EXPECTED_PROJECT = "meeting-1d258"
RUN_KEY_RE = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"
STATE_RUN_KEY_RE = r"^[0-9]+-[0-9]+$"
OWNER_MARKER = "provider-owner.json"
OWNER = "meet-test-vps-provider"
FINALIZATION_SCHEMA = "meet-backend/test-vps-provider-finalization/v1"
LIVE_RESUME_SCHEMA = "meet-backend/test-vps-provider-live-resume/v1"
ABSENCE_RESUME_SCHEMA = "meet-backend/test-vps-provider-absence-resume/v1"
PREPARED_INPUT_SCHEMA = "meet-backend/test-vps-timepad-prepared-input/v1"
PREPARED_SCHEMA = "meet-backend/test-vps-timepad-prepared/v1"
_DEADLINE_NS: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "provider_deadline_ns", default=None
)
_EXECUTION_CHECK: contextvars.ContextVar[Callable[[], None] | None] = contextvars.ContextVar(
    "provider_execution_check", default=None
)
MAX_LIVE_RESUME_BYTES = MAX_INSPECTION_BYTES + 32768
STATE_KINDS = frozenset(("final-deploy", "rollback-drill"))
RENAME_NOREPLACE = 1
PUSH_KEYS = (
    "APP_PUSH_PROVIDER_ENABLED",
    "APP_PUSH_DISCOVERY_ENABLED",
    "APP_PUSH_DISPATCH_ENABLED",
    "APP_PUSH_DIAGNOSTIC_ENABLED",
    "APP_PUSH_MAINTENANCE_ENABLED",
    "APP_PUSH_PROJECT_ID",
    "APP_PUSH_CREDENTIALS_FILE",
)
FLAG_KEYS = set(PUSH_KEYS[:5])
ALTERNATE_CONFIG_KEYS = {
    "SPRING_APPLICATION_JSON",
    "SPRING_CONFIG_LOCATION",
    "SPRING_CONFIG_ADDITIONAL_LOCATION",
    "SPRING_CONFIG_IMPORT",
    "SPRING_CONFIG_NAME",
    "SPRING_CONFIG_DATA_LOCATION",
}
ERRORS = {
    "provider": "PROVIDER_STATE_INVALID",
    "credential": "CREDENTIAL_INVALID",
    "changed": "CREDENTIAL_CHANGED",
    "durable": "DURABLE_CONFLICT",
    "recovery": "RECOVERY_REQUIRED",
    "prerequisite": "PREREQUISITE_MISSING",
}


def _deploy_lock_mode_is_safe(mode: int) -> bool:
    permissions = stat.S_IMODE(mode)
    return permissions in (0o600, 0o640, 0o644)


class ProviderError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def _fail(category: str) -> None:
    raise ProviderError(ERRORS[category])


def _deadline_check() -> None:
    deadline = _DEADLINE_NS.get()
    if deadline is not None and time.monotonic_ns() >= deadline:
        _fail("recovery")
    check = _EXECUTION_CHECK.get()
    if check is not None:
        check()


@contextlib.contextmanager
def _operation_deadline(deadline_ns: int | None) -> Iterator[None]:
    if deadline_ns is not None and (
        type(deadline_ns) is not int or not 0 < deadline_ns < 1 << 63
    ):
        _fail("recovery")
    inherited = _DEADLINE_NS.get()
    end = deadline_ns if deadline_ns is not None else time.monotonic_ns() + 30_000_000_000
    if inherited is not None:
        end = min(end, inherited)
    token = _DEADLINE_NS.set(end)
    try:
        _deadline_check()
        yield
        _deadline_check()
    finally:
        _DEADLINE_NS.reset(token)


def _lock_directory(fd: int) -> None:
    _deadline_check()
    if fcntl is None:
        _fail("prerequisite")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        _fail("recovery")


def _validate_execution_arguments(args: argparse.Namespace) -> bool:
    values = (args.execution_attempt, args.execution_grant, args.deadline_ns)
    supplied = any(value is not None for value in values)
    if supplied and (
        any(value is None for value in values)
        or any(
            not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{32}", value) is None
            for value in values[:2]
        )
        or type(args.deadline_ns) is not int
        or not 0 < args.deadline_ns < 1 << 63
    ):
        _fail("recovery")
    return supplied


def _execution_interlock(args: argparse.Namespace, lock_fd: int) -> dict[str, Any] | None:
    """An inherited lock is necessary, but not sufficient, to reuse a lease."""
    _deadline_check()
    supplied = _validate_execution_arguments(args)
    try:
        os.stat(
            os.path.join(args.state_root, ".timepad-execution.json"),
            follow_symlinks=False,
        )
    except FileNotFoundError:
        if supplied:
            _fail("recovery")
        return
    module = _timepad_state_module()
    try:
        lease = module._read_execution_lease_locked(args.state_root)
        if lease is None:
            _fail("recovery")
        if (
            args.deploy_lock_fd is None
            or args.execution_attempt is None
            or args.execution_grant is None
            or args.deadline_ns is None
        ):
            _fail("recovery")
        cleanup = lease["workerMode"] == "fail-closed-worker"
        module.check_execution_lease(
            args.state_root,
            attempt=args.execution_attempt,
            deploy_lock_fd=lock_fd,
            purpose="cleanup-stop-proof" if cleanup else "writer",
        )
        if cleanup:
            if args.command != "runtime-request-proof":
                _fail("recovery")
        # Only read-only correlated stop proof may use the cleanup reserve.
        end = lease["hardEndNs"] if cleanup else lease["workEndNs"]
        if end is None:
            end = time.monotonic_ns() + 30_000_000_000
        if args.deadline_ns > end or lease["lifecycle"] not in {
            "registered", "armed", "rollback-admission", "rolling-back", "draining",
        }:
            _fail("recovery")
        if lease["lifecycle"] == "rollback-admission" and args.command not in {
            "verify", "live-resume", "absence-resume",
        }:
            _fail("recovery")
        role = lease["workerMode"]
        if (
            role == "controller-worker" and (
                lease["lifecycle"] not in {"registered", "armed"}
                or lease["firstFailure"] is not None
            )
            or role == "rollback-worker" and (
                lease["operation"] != "deploy" or not lease["rollbackIssued"]
                or lease["lifecycle"] not in {"rollback-admission", "rolling-back"}
            )
            or role == "retention-worker" and (
                lease["operation"] != "retention"
                or lease["lifecycle"] not in {"registered", "armed"}
                or lease["firstFailure"] is not None
                or args.command not in {"retention-list", "retention-check", "retention-delete"}
            )
            or role not in {"controller-worker", "rollback-worker", "retention-worker", "fail-closed-worker"}
        ):
            _fail("recovery")
    except (module.GuardError, OSError, ValueError, TypeError, KeyError):
        _fail("recovery")
    _deadline_check()
    return lease


@contextlib.contextmanager
def _execution_mutation(
    args: argparse.Namespace, lease: dict[str, Any] | None,
) -> Iterator[None]:
    """Keep the private grant authoritative at every mutation and bounded wait."""
    if lease is None:
        yield
        return
    from test_vps_timepad_supervisor import SupervisorError, WorkerClient

    client = None
    token = None
    try:
        client = WorkerClient(args.state_root)
        role = lease["workerMode"]
        if (
            client.attempt != args.execution_attempt
            or client.attempt != lease["attempt"]
            or client.role != role
            or client.supervisor != lease["supervisor"]
        ):
            _fail("recovery")
        expected_name = (
            "cleanup-stop" if role == "fail-closed-worker"
            else "rollback-admission" if lease["lifecycle"] == "rollback-admission"
            else "recovery-admission" if lease["operation"] == "forward-recover"
            and lease["lifecycle"] == "registered"
            else "provider"
        )
        if expected_name == "recovery-admission" and args.command not in {
            "live-resume", "absence-resume", "runtime-request-proof", "resource-admission",
        }:
            _fail("recovery")

        def check() -> None:
            if time.monotonic_ns() >= args.deadline_ns:
                _fail("recovery")
            response = client.request(
                "validate-grant", grantId=args.execution_grant, endNs=args.deadline_ns,
            )
            if response != {
                "attempt": args.execution_attempt, "grantId": args.execution_grant,
                "endNs": args.deadline_ns, "role": role, "name": expected_name,
            }:
                _fail("recovery")
            if time.monotonic_ns() >= args.deadline_ns:
                _fail("recovery")

        token = _EXECUTION_CHECK.set(check)
        _deadline_check()
        yield
        _deadline_check()
    except SupervisorError:
        _fail("recovery")
    finally:
        if token is not None:
            _EXECUTION_CHECK.reset(token)
        if client is not None:
            client.close()


@contextlib.contextmanager
def _deploy_lock(
    state_root: str,
    inherited_fd: int | None,
    *,
    create_state_root: bool = False,
) -> Iterator[int]:
    """Serialize public provider operations with the controller's deploy lock."""
    if fcntl is None:
        _fail("prerequisite")
    if create_state_root:
        expected_root = _ensure_state_root(state_root)
    else:
        expected_root = _validate_retention_state_root_path(state_root)
    root_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock_fd: int | None = inherited_fd
    owns_fd = inherited_fd is None
    try:
        root_info = os.fstat(root_fd)
        if not _same_inode(root_info, expected_root):
            _fail("recovery")
        _validate_retention_state_root_fd(root_fd)
        if owns_fd:
            try:
                _deadline_check()
                lock_fd = os.open(
                    ".deploy.lock",
                    os.O_RDWR
                    | os.O_CREAT
                    | os.O_EXCL
                    | os.O_NOFOLLOW
                    | os.O_NONBLOCK,
                    0o600,
                    dir_fd=root_fd,
                )
                _deadline_check()
                os.fsync(lock_fd)
                _deadline_check()
                os.fsync(root_fd)
            except FileExistsError:
                try:
                    lock_fd = os.open(
                        ".deploy.lock",
                        os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
                        dir_fd=root_fd,
                    )
                except OSError:
                    _fail("recovery")
            except OSError:
                _fail("recovery")
            lock_info = os.fstat(lock_fd)
            if lock_info.st_nlink == 0:
                _fail("recovery")
        else:
            if type(inherited_fd) is not int or inherited_fd < 0:
                _fail("recovery")
            try:
                lock_info = os.fstat(inherited_fd)
                if not os.get_inheritable(inherited_fd):
                    _fail("recovery")
            except OSError:
                _fail("recovery")
        if (
            not stat.S_ISREG(lock_info.st_mode)
            or lock_info.st_uid != 0
            or lock_info.st_nlink != 1
            or not _deploy_lock_mode_is_safe(lock_info.st_mode)
        ):
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{lock_fd}",
            follow_symlinks=True,
            category="recovery",
        )
        try:
            path_info = os.stat(
                ".deploy.lock",
                dir_fd=root_fd,
                follow_symlinks=False,
            )
        except OSError:
            _fail("recovery")
        if not _same_inode(path_info, lock_info):
            _fail("recovery")
        _revalidate_retention_state_root_path(state_root, root_info)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            _fail("recovery")
        yield lock_fd
    finally:
        if owns_fd and lock_fd is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            finally:
                os.close(lock_fd)
        os.close(root_fd)


def _bounded_stdin(limit: int) -> bytes:
    _deadline_check()
    deadline = _DEADLINE_NS.get()
    if deadline is None:
        data = sys.stdin.buffer.read(limit + 1)
    else:
        fd = sys.stdin.buffer.fileno()
        regular = stat.S_ISREG(os.fstat(fd).st_mode)
        chunks = bytearray()
        while len(chunks) <= limit:
            _deadline_check()
            if not regular and not select.select(
                [fd], [], [], min(
                    0.1, max(0, (deadline - time.monotonic_ns()) / 1_000_000_000),
                ),
            )[0]:
                continue
            _deadline_check()
            chunk = os.read(fd, min(65536, limit + 1 - len(chunks)))
            if not chunk:
                break
            chunks.extend(chunk)
        data = bytes(chunks)
    _deadline_check()
    if len(data) > limit:
        _fail("provider")
    return data


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("provider")
        result[key] = value
    return result


def _depth(value: Any, level: int = 0) -> None:
    if level > MAX_JSON_DEPTH:
        _fail("provider")
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str):
                _fail("provider")
            _depth(item, level + 1)
    elif isinstance(value, list):
        for item in value:
            _depth(item, level + 1)


def _json(data: bytes, category: str = "provider") -> Any:
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_pairs)
        _depth(value)
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError, ValueError, ProviderError):
        _fail(category)
    return value


def _run_key(value: str) -> str:
    import re

    if not isinstance(value, str) or re.fullmatch(RUN_KEY_RE, value) is None:
        _fail("provider")
    return value


def _result(enabled: bool, present: bool, read_only: bool, outcome: str) -> None:
    _deadline_check()
    print(
        json.dumps(
            {
                "schemaVersion": SCHEMA_VERSION,
                "providerEnabled": bool(enabled),
                "credentialMountPresent": bool(present),
                "credentialMountReadOnly": bool(read_only),
                "outcome": outcome,
            },
            separators=(",", ":"),
        )
    )


def _mode_is_safe(mode: int, *, source: bool = False) -> bool:
    permissions = stat.S_IMODE(mode)
    if permissions & (stat.S_IWGRP | stat.S_IWOTH | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH):
        return False
    if not source and permissions != 0o440:
        return False
    if source and (
        permissions & stat.S_IROTH
        or not permissions & stat.S_IRGRP
        or permissions & stat.S_IRUSR == 0
    ):
        return False
    return True


def _acl_is_safe(
    path: str,
    *,
    follow_symlinks: bool = False,
    category: str = "credential",
) -> bool:
    # Ordinary mode bits do not represent POSIX access or default ACL entries.
    # Missing ACL xattrs are safe; an unavailable xattr interface is not proof
    # that a private object is safe and therefore blocks the operation.
    getter = getattr(os, "getxattr", None)
    if getter is None:
        _fail("prerequisite")
    for attribute in ("system.posix_acl_access", "system.posix_acl_default"):
        try:
            getter(path, attribute, follow_symlinks=follow_symlinks)
        except OSError as exc:
            if exc.errno in (
                errno.ENODATA,
                errno.ENOATTR if hasattr(errno, "ENOATTR") else errno.ENODATA,
            ):
                continue
            if exc.errno in (
                errno.ENOTSUP,
                errno.EOPNOTSUPP if hasattr(errno, "EOPNOTSUPP") else errno.ENOTSUP,
            ):
                _fail("prerequisite")
            _fail(category)
        else:
            _fail(category)
    return True


def _components(path: str) -> tuple[str, list[str]]:
    if not isinstance(path, str) or not path.startswith("/") or "\x00" in path:
        _fail("credential")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts[1:]):
        _fail("credential")
    return "/", parts[1:]


def _check_ancestors(path: str, *, category: str = "credential") -> None:
    base, parts = _components(path)
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        root_info = os.fstat(fd)
        if root_info.st_uid != 0 or stat.S_IMODE(root_info.st_mode) & (
            stat.S_IWGRP | stat.S_IWOTH
        ):
            _fail(category)
        _acl_is_safe(
            f"/proc/self/fd/{fd}",
            follow_symlinks=True,
            category=category,
        )
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            previous_fd = fd
            fd = child
            os.close(previous_fd)
            info = os.fstat(fd)
            if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & (
                stat.S_IWGRP | stat.S_IWOTH
            ):
                _fail(category)
            _acl_is_safe(
                f"/proc/self/fd/{fd}",
                follow_symlinks=True,
                category=category,
            )
    finally:
        os.close(fd)


def _open_regular(path: str, *, max_bytes: int, source: bool = False) -> tuple[int, os.stat_result, bytes]:
    _deadline_check()
    _check_ancestors(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    if hasattr(os, "O_NOATIME"):
        flags |= os.O_NOATIME
    try:
        fd = os.open(path, flags)
    except OSError:
        _fail("credential")
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != 0:
            _fail("credential")
        if source:
            if before.st_gid != 10001 or not _mode_is_safe(before.st_mode, source=True):
                _fail("credential")
        elif before.st_gid != 10001 or not _mode_is_safe(before.st_mode):
            _fail("credential")
        if not _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True):
            _fail("credential")
        data = bytearray()
        while len(data) <= max_bytes:
            _deadline_check()
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > max_bytes:
            _fail("credential")
        after = os.fstat(fd)
        if _identity(before) != _identity(after) or before.st_size != after.st_size:
            _fail("changed")
        os.lseek(fd, 0, os.SEEK_SET)
        reread = bytearray()
        while len(reread) <= max_bytes:
            _deadline_check()
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(reread)))
            if not chunk:
                break
            reread.extend(chunk)
        if bytes(reread) != bytes(data):
            _fail("changed")
        final = os.fstat(fd)
        if _identity(after) != _identity(final) or after.st_size != final.st_size:
            _fail("changed")
        return fd, before, bytes(data)
    except Exception:
        os.close(fd)
        raise


def _identity(info: os.stat_result) -> dict[str, int]:
    return {
        "device": int(info.st_dev),
        "inode": int(info.st_ino),
        "mtimeNs": int(info.st_mtime_ns),
        "ctimeNs": int(info.st_ctime_ns),
    }


def _same_identity(left: dict[str, int], right: dict[str, int]) -> bool:
    return left == right


def _same_inode(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _stable_entry_identity(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_nlink,
    )


def _read_fd_bounded(fd: int, limit: int) -> bytes:
    _deadline_check()
    os.lseek(fd, 0, os.SEEK_SET)
    data = bytearray()
    while len(data) <= limit:
        _deadline_check()
        chunk = os.read(fd, min(65536, limit + 1 - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    if len(data) > limit:
        _fail("recovery")
    return bytes(data)


def _child_witness(
    directory_fd: int,
    name: str,
    *,
    limit: int = MAX_WITNESS_BYTES,
) -> tuple[dict[str, int], bytes]:
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        _fail("recovery")
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            _fail("recovery")
        data = _read_fd_bounded(fd, limit)
        after = os.fstat(fd)
        if _identity(before) != _identity(after):
            _fail("recovery")
        identity = _identity(before)
        # Keep the descriptor open through the witnessed mutation.  Some
        # filesystems can immediately reuse an unlinked inode with identical
        # ctime/mtime metadata; an open witness prevents that ambiguity.
        identity["_witnessFd"] = fd
        return identity, data
    except Exception:
        os.close(fd)
        raise


def _witness_identity(value: dict[str, int]) -> dict[str, int]:
    return {
        key: item
        for key, item in value.items()
        if key != "_witnessFd"
    }


def _validate_quarantine_name(name: str, quarantine_name: str) -> str:
    if (
        not isinstance(quarantine_name, str)
        or not quarantine_name
        or quarantine_name in (".", "..")
        or "/" in quarantine_name
        or "\x00" in quarantine_name
        or quarantine_name == name
    ):
        _fail("recovery")
    return quarantine_name


def _close_owned_witnesses(
    witnesses: Iterable[tuple[dict[str, int], bytes]],
) -> None:
    for identity, _ in witnesses:
        witness_fd = identity.pop("_witnessFd", None)
        if witness_fd is None:
            continue
        try:
            os.close(witness_fd)
        except OSError:
            pass


def _validate_credential(data: bytes) -> None:
    if len(data) > MAX_CREDENTIAL_BYTES:
        _fail("credential")
    value = _json(data, "credential")
    if not isinstance(value, dict):
        _fail("credential")
    required = ("type", "project_id", "client_email", "client_id", "private_key_id", "private_key", "token_uri")
    if value.get("type") != "service_account" or value.get("project_id") != EXPECTED_PROJECT:
        _fail("credential")
    for key in required[2:]:
        if not isinstance(value.get(key), str) or not value[key].strip():
            _fail("credential")
    private_key = value["private_key"]
    if "BEGIN PRIVATE KEY" not in private_key or "END PRIVATE KEY" not in private_key:
        _fail("credential")


def _env_entries(inspect: dict[str, Any]) -> list[tuple[str, str]]:
    config = inspect.get("Config")
    if not isinstance(config, dict):
        _fail("provider")
    return _configuration_env_entries(config.get("Env", []))


def _configuration_env_entries(env: Any) -> list[tuple[str, str]]:
    if not isinstance(env, list):
        _fail("provider")
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for item in env:
        if not isinstance(item, str) or "=" not in item:
            _fail("provider")
        key, value = item.split("=", 1)
        if key in seen:
            _fail("provider")
        seen.add(key)
        entries.append((key, value))
    return entries


def _validate_configuration_channels(
    config: dict[str, Any], entries: list[tuple[str, str]]
) -> None:
    for key, value in entries:
        normalized = key.upper().replace("-", "_").replace(".", "_")
        if normalized in PUSH_KEYS and key != normalized:
            _fail("provider")
        if normalized in ALTERNATE_CONFIG_KEYS:
            _fail("provider")
        if key in ("JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"):
            lowered = value.lower()
            if any(
                token in lowered
                for token in (
                    "app.push",
                    "spring.application.json",
                    "spring.config.location",
                    "spring.config.additional-location",
                    "spring.config.import",
                    "spring.config.name",
                    "spring.config.data.location",
                )
            ):
                _fail("provider")
    for field in ("Cmd", "Entrypoint"):
        command = config.get(field, [])
        if command is None:
            continue
        if not isinstance(command, list) or any(not isinstance(item, str) for item in command):
            _fail("provider")
        if any(
            token in item.lower()
            for item in command
            for token in (
                "--app.push",
                "-dapp.push",
                "spring.application.json",
                "spring.config.location",
                "spring.config.additional-location",
                "spring.config.import",
                "spring.config.name",
                "spring.config.data.location",
            )
        ):
            _fail("provider")


def _image_admission(inspect: dict[str, Any]) -> None:
    config = inspect.get("Config")
    if not isinstance(config, dict):
        _fail("provider")
    _validate_configuration_channels(config, _env_entries(inspect))


def _provider_state(inspect: dict[str, Any]) -> tuple[bool, dict[str, str]]:
    config = inspect.get("Config")
    if not isinstance(config, dict):
        _fail("provider")
    entries = _env_entries(inspect)
    _validate_configuration_channels(config, entries)
    return _provider_values(dict(entries))


def _provider_values(values: dict[str, str]) -> tuple[bool, dict[str, str]]:
    enabled_value = values.get("APP_PUSH_PROVIDER_ENABLED", "false").strip().lower()
    if enabled_value not in ("true", "false"):
        _fail("provider")
    enabled = enabled_value == "true"
    for key in FLAG_KEYS:
        raw = values.get(key, "false").strip().lower()
        if raw not in ("true", "false"):
            _fail("provider")
    project = values.get("APP_PUSH_PROJECT_ID", EXPECTED_PROJECT)
    credentials = values.get("APP_PUSH_CREDENTIALS_FILE", "")
    if project != EXPECTED_PROJECT:
        _fail("provider")
    if enabled and credentials != CONTAINER_CREDENTIAL_PATH:
        _fail("provider")
    if not enabled and credentials:
        _fail("provider")
    return enabled, {key: values.get(key, "") for key in PUSH_KEYS}


def _mounts(inspect: dict[str, Any]) -> list[dict[str, Any]]:
    mounts = inspect.get("Mounts", [])
    if not isinstance(mounts, list):
        _fail("provider")
    if any(not isinstance(mount, dict) for mount in mounts):
        _fail("provider")
    return list(mounts)


def _provider_mount(
    inspect: dict[str, Any],
    enabled: bool,
    *,
    allow_external_source: bool = False,
) -> tuple[bool, bool, str | None]:
    matches: list[dict[str, Any]] = []
    seen_upload = False
    seen_tmpfs = False
    for mount in _mounts(inspect):
        destination = mount.get("Destination")
        if destination == CONTAINER_CREDENTIAL_PATH:
            matches.append(mount)
        elif destination == "/data/uploads":
            if seen_upload or mount.get("Type") != "volume":
                _fail("provider")
            seen_upload = True
        elif destination == "/tmp":
            if seen_tmpfs or mount.get("Type") != "tmpfs":
                _fail("provider")
            seen_tmpfs = True
        elif isinstance(destination, str) and (
            destination.startswith(CONTAINER_CREDENTIAL_PATH + "/")
            or CONTAINER_CREDENTIAL_PATH.startswith(destination.rstrip("/") + "/")
        ):
            _fail("provider")
        else:
            _fail("provider")
    if not enabled:
        if matches:
            _fail("provider")
        return False, False, None
    if len(matches) != 1:
        _fail("provider")
    mount = matches[0]
    if mount.get("Type") != "bind" or bool(mount.get("RW", True)):
        _fail("provider")
    source = mount.get("Source")
    if not isinstance(source, str) or not source.startswith("/") or "\x00" in source:
        _fail("provider")
    if any(part in ("", ".", "..") for part in source.split("/")[1:]):
        _fail("provider")
    if not allow_external_source and source != HOST_CREDENTIAL_PATH:
        _fail("provider")
    return True, True, source


def _inspect(data: bytes) -> dict[str, Any]:
    value = _json(data)
    if isinstance(value, list):
        if len(value) != 1 or not isinstance(value[0], dict):
            _fail("provider")
        value = value[0]
    if not isinstance(value, dict):
        _fail("provider")
    return value


def _inspect_records(data: bytes) -> tuple[dict[str, Any], dict[str, Any] | None]:
    value = _json(data)
    if isinstance(value, list) and len(value) == 2 and all(
        isinstance(item, (dict, list)) for item in value
    ):
        previous = _inspect(json.dumps(value[0], separators=(",", ":")).encode())
        current = _inspect(json.dumps(value[1], separators=(",", ":")).encode())
        return current, previous
    return _inspect(data), None


def _effective_tuple(inspect: dict[str, Any]) -> dict[str, str]:
    enabled, values = _provider_state(inspect)
    return _normalized_provider_tuple(enabled, values)


def _normalized_provider_tuple(enabled: bool, values: dict[str, str]) -> dict[str, str]:
    result = {
        key: values.get(key, "")
        for key in PUSH_KEYS
    }
    for key in FLAG_KEYS:
        result[key] = result[key].strip().lower() or "false"
    result["APP_PUSH_PROJECT_ID"] = (
        result["APP_PUSH_PROJECT_ID"] or EXPECTED_PROJECT
    )
    result["APP_PUSH_CREDENTIALS_FILE"] = (
        result["APP_PUSH_CREDENTIALS_FILE"] or ""
    )
    result["APP_PUSH_PROVIDER_ENABLED"] = "true" if enabled else "false"
    return result


def _finalization_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _validate_finalization_file_record(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "device", "inode", "uid", "gid", "mode", "size", "mtimeNs", "ctimeNs",
        "links", "sha256",
    }:
        _fail("recovery")
    for key in (
        "device", "inode", "uid", "gid", "mode", "size", "mtimeNs", "ctimeNs", "links",
    ):
        if type(value[key]) is not int or value[key] < 0:
            _fail("recovery")
    if value["links"] < 1 or re.fullmatch(r"[0-9a-f]{64}", str(value["sha256"])) is None:
        _fail("recovery")


def _validate_finalization_directory_record(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "device", "inode", "uid", "gid", "mode", "links",
    }:
        _fail("recovery")
    if any(type(value[key]) is not int or value[key] < 0 for key in value):
        _fail("recovery")


def _validate_finalization_witness(value: Any) -> dict[str, Any]:
    keys = {
        "schema", "outcome", "runKey", "stateKind", "ownedRun", "rootId",
        "originDigest", "incidentId", "operationEpoch", "evidenceDigest",
        "commitWitnessDigest", "containerId", "configHash", "imageId",
        "revision", "version", "repositoryDigest", "platformImageId",
        "providerEnabled", "durableDisposition", "effectiveProviderDigest",
        "config", "transaction", "durableCredential", "terminal", "pointer", "startAttemptId",
    }
    if not isinstance(value, dict) or set(value) != keys:
        _fail("recovery")
    if value["schema"] != FINALIZATION_SCHEMA or value["outcome"] != "committed":
        _fail("recovery")
    _run_key(value["runKey"])
    if (
        not isinstance(value["stateKind"], str)
        or value["stateKind"] not in STATE_KINDS
    ):
        _fail("recovery")
    if value["ownedRun"] != f'{value["runKey"]}-{value["stateKind"]}':
        _fail("recovery")
    for key in (
        "originDigest", "evidenceDigest", "commitWitnessDigest", "configHash",
        "repositoryDigest", "platformImageId", "effectiveProviderDigest",
    ):
        if not isinstance(value[key], str) or re.fullmatch(r"[0-9a-f]{64}", value[key]) is None:
            _fail("recovery")
    if (
        not isinstance(value["rootId"], str)
        or not value["rootId"]
        or len(value["rootId"]) > 128
        or not isinstance(value["incidentId"], str)
        or re.fullmatch(r"[a-f0-9]{32}", value["incidentId"]) is None
        or type(value["operationEpoch"]) is not int
        or value["operationEpoch"] <= 0
    ):
        _fail("recovery")
    attempt = re.fullmatch(
        r"([a-f0-9]{32}):([1-9][0-9]{0,19})",
        value["startAttemptId"] if isinstance(value["startAttemptId"], str) else "",
    )
    if (
        attempt is None or attempt.group(1) != value["incidentId"]
        or int(attempt.group(2)) > (1 << 64) - 1
    ):
        _fail("recovery")
    if (
        not isinstance(value["containerId"], str)
        or re.fullmatch(r"[a-f0-9]{12,64}", value["containerId"]) is None
        or not isinstance(value["imageId"], str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", value["imageId"]) is None
        or not isinstance(value["platformImageId"], str)
        or re.fullmatch(r"[0-9a-f]{64}", value["platformImageId"]) is None
        or not isinstance(value["revision"], str)
        or re.fullmatch(r"[a-f0-9]{40,64}", value["revision"]) is None
        or not isinstance(value["version"], str)
        or not value["version"]
        or len(value["version"]) > 64
    ):
        _fail("recovery")
    if value["imageId"] != "sha256:" + value["platformImageId"]:
        _fail("recovery")
    if type(value["providerEnabled"]) is not bool:
        _fail("recovery")
    if value["durableDisposition"] not in ("none", "created", "reused"):
        _fail("recovery")
    if (
        not isinstance(value["config"], list)
        or len(value["config"]) != 4
        or any(not isinstance(entry, dict) for entry in value["config"])
    ):
        _fail("recovery")
    config_names: set[str] = set()
    for entry in value["config"]:
        if not isinstance(entry, dict) or set(entry) != {"name", "identity"}:
            _fail("recovery")
        if not isinstance(entry["name"], str) or entry["name"] not in {
            "config.env.target",
            "config.env.target.identity",
            "config.base-compose.yml",
            "config.base-compose.yml.identity",
        } or entry["name"] in config_names:
            _fail("recovery")
        config_names.add(entry["name"])
        _validate_finalization_file_record(entry["identity"])
    if config_names != {
        "config.env.target",
        "config.env.target.identity",
        "config.base-compose.yml",
        "config.base-compose.yml.identity",
    }:
        _fail("recovery")
    if value["providerEnabled"]:
        if value["durableDisposition"] not in ("created", "reused"):
            _fail("recovery")
        transaction = value["transaction"]
        if not isinstance(transaction, dict) or set(transaction) != {
            "parent", "directory", "entries",
        }:
            _fail("recovery")
        _validate_finalization_directory_record(transaction["parent"])
        _validate_finalization_directory_record(transaction["directory"])
        expected_names = ["identity.json", "snapshot"]
        if value["durableDisposition"] == "created":
            expected_names.append("publication")
        entries = transaction["entries"]
        if (
            not isinstance(entries, list)
            or any(not isinstance(entry, dict) for entry in entries)
            or [entry.get("name") for entry in entries] != expected_names
        ):
            _fail("recovery")
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != {
                "name", "identity", "quarantineName", "linkProgression",
            }:
                _fail("recovery")
            _validate_finalization_file_record(entry["identity"])
            expected_quarantine = f'.provider-cleanup-{value["runKey"]}-{entry["name"].replace(".", "-")}'
            if entry["quarantineName"] != expected_quarantine:
                _fail("recovery")
            if entry["name"] == "publication":
                if entry["linkProgression"] != [2, 1]:
                    _fail("recovery")
            elif entry["linkProgression"] != [1]:
                _fail("recovery")
        durable = value["durableCredential"]
        if durable is None:
            _fail("recovery")
        _validate_finalization_file_record(durable)
        if durable["links"] != (2 if value["durableDisposition"] == "created" else 1):
            _fail("recovery")
    elif (
        value["durableDisposition"] != "none"
        or value["transaction"] is not None
        or value["durableCredential"] is not None
    ):
        _fail("recovery")
    terminal = value["terminal"]
    if not isinstance(terminal, dict) or set(terminal) != {
        "schemaVersion", "runKey", "outcome", "providerEnabled",
    } or terminal != {
        "schemaVersion": SCHEMA_VERSION,
        "runKey": value["runKey"],
        "outcome": "committed",
        "providerEnabled": value["providerEnabled"],
    }:
        _fail("recovery")
    if value["pointer"] != {
        "schemaVersion": SCHEMA_VERSION,
        "runKey": value["runKey"],
        "phase": "finalizing",
        "providerEnabled": value["providerEnabled"],
        "durableDisposition": value["durableDisposition"],
    }:
        _fail("recovery")
    return value


def _directory_record(info: os.stat_result) -> dict[str, int]:
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0:
        _fail("recovery")
    return {
        "device": int(info.st_dev),
        "inode": int(info.st_ino),
        "uid": int(info.st_uid),
        "gid": int(info.st_gid),
        "mode": stat.S_IMODE(info.st_mode),
        "links": int(info.st_nlink),
    }


def _file_record(
    directory_fd: int,
    name: str,
    *,
    uid: int = 0,
    gid: int = 0,
    mode: int = 0o600,
    links: int = 1,
) -> dict[str, Any]:
    identity, data = _child_witness(directory_fd, name, limit=MAX_WITNESS_BYTES)
    witness_fd = identity.pop("_witnessFd")
    try:
        info = os.fstat(witness_fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != uid
            or info.st_gid != gid
            or stat.S_IMODE(info.st_mode) != mode
            or info.st_nlink != links
            or _identity(info) != identity
        ):
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{witness_fd}",
            follow_symlinks=True,
            category="recovery",
        )
        path_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if _stable_entry_identity(path_info) != _stable_entry_identity(info):
            _fail("recovery")
        return {
            "device": int(info.st_dev),
            "inode": int(info.st_ino),
            "uid": int(info.st_uid),
            "gid": int(info.st_gid),
            "mode": stat.S_IMODE(info.st_mode),
            "size": int(info.st_size),
            "mtimeNs": int(info.st_mtime_ns),
            "ctimeNs": int(info.st_ctime_ns),
            "links": int(info.st_nlink),
            "sha256": _finalization_digest(data),
        }
    finally:
        os.close(witness_fd)


def _read_child_file(directory_fd: int, name: str, limit: int) -> tuple[dict[str, Any], bytes]:
    identity, data = _child_witness(directory_fd, name, limit=limit)
    witness_fd = identity.pop("_witnessFd")
    try:
        info = os.fstat(witness_fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
            or _identity(info) != identity
        ):
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{witness_fd}",
            follow_symlinks=True,
            category="recovery",
        )
        path_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if _stable_entry_identity(path_info) != _stable_entry_identity(info):
            _fail("recovery")
        record = {
            "device": int(info.st_dev),
            "inode": int(info.st_ino),
            "uid": int(info.st_uid),
            "gid": int(info.st_gid),
            "mode": stat.S_IMODE(info.st_mode),
            "size": int(info.st_size),
            "mtimeNs": int(info.st_mtime_ns),
            "ctimeNs": int(info.st_ctime_ns),
            "links": int(info.st_nlink),
            "sha256": _finalization_digest(data),
        }
        return record, data
    finally:
        os.close(witness_fd)


def _read_finalization_witness(directory_fd: int) -> tuple[dict[str, Any], bytes]:
    try:
        info = os.stat(
            "provider-finalization.json",
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except OSError:
        _fail("recovery")
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
        or info.st_size > MAX_FINALIZATION_BYTES
    ):
        _fail("recovery")
    record, data = _read_child_file(
        directory_fd,
        "provider-finalization.json",
        MAX_FINALIZATION_BYTES,
    )
    value = _validate_finalization_witness(_json(data, "recovery"))
    if record["size"] != len(data):
        _fail("recovery")
    return value, data


def _timepad_current(state_root: str, deploy_lock_fd: int) -> tuple[Any, dict[str, Any], dict[str, Any]]:
    module = _timepad_state_module()
    try:
        origin, current = module._read_guard_locked(state_root)
    except (module.GuardError, OSError, ValueError, TypeError, AttributeError):
        _fail("recovery")
    if not isinstance(origin, dict) or not isinstance(current, dict):
        _fail("recovery")
    if not isinstance(deploy_lock_fd, int) or deploy_lock_fd < 0:
        _fail("recovery")
    return module, origin, current


def _controller_commit_witness(
    run_fd: int,
    current: dict[str, Any],
    *,
    require_state_digest: bool,
) -> tuple[dict[str, Any], bytes, str]:
    _, data = _read_child_file(
        run_fd,
        "timepad-commit-witness.json",
        MAX_OWNER_BYTES,
    )
    value = _json(data, "recovery")
    expected_keys = {
        "schema", "operationEpoch", "incidentId", "containerId", "configHash",
        "imageId", "revision", "version", "providerEnabled",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        _fail("recovery")
    if (
        value["schema"] != "meet-backend/test-vps-timepad-commit-witness/v1"
        or type(value["operationEpoch"]) is not int
        or type(value["providerEnabled"]) is not bool
        or not isinstance(value["incidentId"], str)
        or not isinstance(value["containerId"], str)
        or not isinstance(value["configHash"], str)
        or not isinstance(value["imageId"], str)
        or not isinstance(value["revision"], str)
        or not isinstance(value["version"], str)
    ):
        _fail("recovery")
    digest = _finalization_digest(data)
    recorded_digest = current.get("commitWitnessDigest")
    if require_state_digest:
        if recorded_digest != digest:
            _fail("recovery")
    elif recorded_digest is not None and recorded_digest != digest:
        _fail("recovery")
    return value, data, digest


def _finalization_context(
    run_key: str,
    state_root: str,
    state_kind: str,
    inspect_data: bytes,
    deploy_lock_fd: int,
    *,
    for_resume: bool,
) -> tuple[dict[str, Any], int, int, dict[str, Any], dict[str, Any], bytes]:
    if state_kind not in STATE_KINDS:
        _fail("recovery")
    run_name = f"{run_key}-{state_kind}"
    module, origin, current = _timepad_current(state_root, deploy_lock_fd)
    allowed_phases = {"COMMITTING", "COMMITTED"}
    if not for_resume:
        allowed_phases |= {"VERIFYING"}
    if (
        current.get("phase") not in allowed_phases
        or current.get("ownedChild") is not None
        or current.get("operation") != "deploy"
        or current.get("ownedRun") != run_name
        or current.get("operationEpoch") <= 0
        or current.get("runId") != run_key
        or current.get("commitSubstep") not in (
            None,
            "provider-cleanup",
            "terminal-policy-intent",
            "policy-restored",
            "replacement-container-authorized",
            "replacement-provider-cleanup",
            "replacement-terminal-policy-intent",
            "replacement-policy-restored",
        )
        or not for_resume
        and isinstance(current.get("commitSubstep"), str)
        and current["commitSubstep"].startswith("replacement-")
    ):
        _fail("recovery")
    try:
        module.require_runtime_request_completion(current)
    except module.GuardError:
        _fail("recovery")
    try:
        _validate_state_directory(os.path.join(state_root, run_name), run_name)
        run_fd = os.open(
            os.path.join(state_root, run_name),
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
    except OSError:
        _fail("recovery")
    try:
        run_info = os.fstat(run_fd)
        _directory_record(run_info)
        if stat.S_IMODE(run_info.st_mode) != 0o700:
            _fail("recovery")
        commit, commit_data, commit_digest = _controller_commit_witness(
            run_fd,
            current,
            require_state_digest=for_resume,
        )
        inspect = _inspect(inspect_data)
        enabled, _ = _provider_state(inspect)
        present, read_only, source = _provider_mount(inspect, enabled)
        target = current.get("target")
        if not isinstance(target, dict) or not isinstance(target.get("tuple"), dict):
            _fail("recovery")
        target_tuple = target["tuple"]
        config = inspect.get("Config")
        labels = config.get("Labels") if isinstance(config, dict) else None
        config_hash = labels.get("com.docker.compose.config-hash") if isinstance(labels, dict) else None
        container_id = inspect.get("Id")
        image_id = inspect.get("Image")
        if (
            enabled != commit["providerEnabled"]
            or commit["operationEpoch"] != current["operationEpoch"]
            or commit["incidentId"] != current["incidentId"]
            or (not for_resume and commit["containerId"] != current["containerId"])
            or commit["configHash"] != current["configHash"]
            or commit["configHash"] != config_hash
            or current["containerId"] != container_id
            or commit["imageId"] != image_id
            or commit["imageId"] != (
                "sha256:" + target_tuple.get("platformImageId", "")
            )
            or commit["revision"] != target_tuple.get("revision")
            or commit["version"] != target_tuple.get("version")
            or origin.get("originDigest") != current.get("originDigest")
            or not present and (read_only or source is not None)
            or enabled and (not present or not read_only or source != HOST_CREDENTIAL_PATH)
        ):
            _fail("recovery")
        if for_resume and (
            current.get("providerFinalizationDigest") is None
            or current.get("commitSubstep") not in (
                "provider-cleanup", "terminal-policy-intent", "policy-restored",
                "replacement-container-authorized", "replacement-provider-cleanup",
                "replacement-terminal-policy-intent", "replacement-policy-restored",
            )
        ):
            _fail("recovery")
        if not for_resume and current["phase"] == "COMMITTING" and (
            current.get("providerFinalizationDigest") is None
        ):
            _fail("recovery")
        if for_resume:
            witness, witness_data = _read_finalization_witness(run_fd)
            if _finalization_digest(witness_data) != current["providerFinalizationDigest"]:
                _fail("recovery")
            _receipt_runtime_binding(witness, current, commit, inspect)
        return module, run_fd, deploy_lock_fd, origin, current, commit_data
    except Exception:
        os.close(run_fd)
        raise


def _build_finalization_witness(
    *,
    run_key: str,
    state_kind: str,
    origin: dict[str, Any],
    current: dict[str, Any],
    commit: dict[str, Any],
    run_fd: int,
    inspect: dict[str, Any],
    state_root: str,
) -> dict[str, Any]:
    enabled, _ = _provider_state(inspect)
    marker = _marker(state_root, run_key)
    if marker["phase"] not in ("verifying", "finalizing"):
        _fail("recovery")
    if marker["providerEnabled"] != enabled:
        _fail("recovery")
    disposition = marker["durableDisposition"]
    if enabled and disposition not in ("created", "reused"):
        _fail("recovery")
    if not enabled and disposition != "none":
        _fail("recovery")

    config_records = [
        {"name": name, "identity": _file_record(run_fd, name)}
        for name in (
            "config.env.target",
            "config.env.target.identity",
            "config.base-compose.yml",
            "config.base-compose.yml.identity",
        )
    ]
    transaction: dict[str, Any] | None = None
    durable_credential: dict[str, Any] | None = None
    if enabled:
        parent = _rooted(HOST_CREDENTIAL_PARENT, None)
        tx = _transaction(parent, run_key)
        _validate_transaction(tx)
        identity_data = _read_private(os.path.join(tx, "identity.json"))
        identity = _json(identity_data, "recovery")
        _validate_identity(identity)
        snapshot = _read_private(os.path.join(tx, "snapshot"))
        tx_fd = os.open(tx, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            parent_info = os.fstat(parent_fd)
            tx_info = os.fstat(tx_fd)
            if (
                stat.S_IMODE(parent_info.st_mode) != 0o700
                or stat.S_IMODE(tx_info.st_mode) != 0o700
                or parent_info.st_uid != 0
                or tx_info.st_uid != 0
            ):
                _fail("recovery")
            children = ["identity.json", "snapshot"]
            if disposition == "created":
                children.append("publication")
            expected_names = set(children)
            if set(os.listdir(tx_fd)) != expected_names:
                _fail("recovery")
            entries = []
            for name in children:
                record = _file_record(
                    tx_fd,
                    name,
                    gid=10001 if name == "publication" else 0,
                    mode=0o440 if name == "publication" else 0o600,
                    links=2 if name == "publication" else 1,
                )
                if name == "publication" and record["sha256"] != _finalization_digest(snapshot):
                    _fail("recovery")
                entries.append(
                    {
                        "name": name,
                        "identity": record,
                        "quarantineName": (
                            f".provider-cleanup-{run_key}-{name.replace('.', '-')}"
                        ),
                        "linkProgression": [2, 1] if name == "publication" else [1],
                    }
                )
            durable_path = _rooted(HOST_CREDENTIAL_PATH, None)
            durable_fd, durable_info, durable_data = _open_regular(
                durable_path,
                max_bytes=MAX_CREDENTIAL_BYTES,
            )
            try:
                if (
                    identity["durable"] != _identity(durable_info)
                    or durable_data != snapshot
                    or disposition == "created" and durable_info.st_nlink != 2
                    or disposition == "reused" and durable_info.st_nlink != 1
                ):
                    _fail("recovery")
                durable_credential = {
                    "device": int(durable_info.st_dev),
                    "inode": int(durable_info.st_ino),
                    "uid": int(durable_info.st_uid),
                    "gid": int(durable_info.st_gid),
                    "mode": stat.S_IMODE(durable_info.st_mode),
                    "size": int(durable_info.st_size),
                    "mtimeNs": int(durable_info.st_mtime_ns),
                    "ctimeNs": int(durable_info.st_ctime_ns),
                    "links": int(durable_info.st_nlink),
                    "sha256": _finalization_digest(durable_data),
                }
            finally:
                os.close(durable_fd)
            transaction = {
                "parent": _directory_record(parent_info),
                "directory": _directory_record(tx_info),
                "entries": entries,
            }
        finally:
            os.close(tx_fd)
            os.close(parent_fd)
    tuple_digest = _finalization_digest(
        json.dumps(
            _effective_tuple(inspect),
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    )
    target_tuple = current["target"]["tuple"]
    witness = {
        "schema": FINALIZATION_SCHEMA,
        "outcome": "committed",
        "runKey": run_key,
        "stateKind": state_kind,
        "ownedRun": current["ownedRun"],
        "rootId": origin["rootId"],
        "originDigest": current["originDigest"],
        "incidentId": current["incidentId"],
        "operationEpoch": current["operationEpoch"],
        "evidenceDigest": current["evidenceDigest"],
        "commitWitnessDigest": _finalization_digest(
            _read_child_file(run_fd, "timepad-commit-witness.json", MAX_OWNER_BYTES)[1]
        ),
        "containerId": commit["containerId"],
        "configHash": commit["configHash"],
        "imageId": commit["imageId"],
        "revision": commit["revision"],
        "version": commit["version"],
        "repositoryDigest": target_tuple["repositoryDigest"],
        "platformImageId": target_tuple["platformImageId"],
        "providerEnabled": enabled,
        "durableDisposition": disposition,
        "effectiveProviderDigest": tuple_digest,
        # Correlates the one permitted replacement start, not schema compatibility.
        "startAttemptId": current["latestAttemptId"],
        "config": config_records,
        "transaction": transaction,
        "durableCredential": durable_credential,
        "terminal": {
            "schemaVersion": SCHEMA_VERSION,
            "runKey": run_key,
            "outcome": "committed",
            "providerEnabled": enabled,
        },
        "pointer": {
            "schemaVersion": SCHEMA_VERSION,
            "runKey": run_key,
            "phase": "finalizing",
            "providerEnabled": enabled,
            "durableDisposition": disposition,
        },
    }
    return _validate_finalization_witness(witness)


def _store_finalization_witness(run_fd: int, data: bytes) -> None:
    if len(data) > MAX_FINALIZATION_BYTES:
        _fail("recovery")
    name = "provider-finalization.json"
    try:
        existing = _read_child_file(run_fd, name, MAX_FINALIZATION_BYTES)[1]
    except ProviderError:
        try:
            os.stat(name, dir_fd=run_fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        else:
            _fail("recovery")
    if existing is not None:
        if existing != data:
            _fail("recovery")
        return
    temporary = ".provider-finalization.tmp"
    try:
        os.stat(temporary, dir_fd=run_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        _fail("recovery")
    _write_private_at(run_fd, temporary, data, 0o600)
    _rename_noreplace(run_fd, temporary, name)
    _deadline_check()
    os.fsync(run_fd)


def _finalization_expected_identity(record: dict[str, Any]) -> dict[str, int]:
    return {
        "device": record["device"],
        "inode": record["inode"],
        "mtimeNs": record["mtimeNs"],
        "ctimeNs": record["ctimeNs"],
    }


def _finalization_stable_identity(record: dict[str, Any]) -> tuple[int, ...]:
    return (
        record["device"],
        record["inode"],
        stat.S_IFREG | record["mode"],
        record["uid"],
        record["gid"],
        record["size"],
        record["mtimeNs"],
        record["links"],
    )


def _matches_finalization_context(
    witness: dict[str, Any],
    *,
    origin: dict[str, Any],
    current: dict[str, Any],
    commit: dict[str, Any],
    commit_data: bytes,
    run_fd: int,
    inspect: dict[str, Any],
) -> None:
    _matches_finalization_identity(
        witness, origin=origin, current=current, commit=commit,
        commit_data=commit_data, run_fd=run_fd,
        effective_provider_digest=_finalization_digest(json.dumps(
            _effective_tuple(inspect), sort_keys=True, separators=(",", ":"),
        ).encode()),
    )


def _matches_finalization_identity(
    witness: dict[str, Any],
    *,
    origin: dict[str, Any],
    current: dict[str, Any],
    commit: dict[str, Any],
    commit_data: bytes,
    run_fd: int,
    effective_provider_digest: str,
) -> None:
    target_tuple = current["target"]["tuple"]
    expected = {
        "runKey": current["runId"],
        "stateKind": _state_parts(current["ownedRun"])[1],
        "ownedRun": current["ownedRun"],
        "rootId": origin["rootId"],
        "originDigest": current["originDigest"],
        "incidentId": current["incidentId"],
        "operationEpoch": current["operationEpoch"],
        "evidenceDigest": current["evidenceDigest"],
        "commitWitnessDigest": _finalization_digest(commit_data),
        "containerId": commit["containerId"],
        "configHash": commit["configHash"],
        "imageId": commit["imageId"],
        "revision": commit["revision"],
        "version": commit["version"],
        "repositoryDigest": target_tuple["repositoryDigest"],
        "platformImageId": target_tuple["platformImageId"],
        "providerEnabled": commit["providerEnabled"],
        "effectiveProviderDigest": effective_provider_digest,
    }
    if any(witness[key] != value for key, value in expected.items()):
        _fail("recovery")
    actual_config = [
        {"name": name, "identity": _file_record(run_fd, name)}
        for name in (
            "config.env.target",
            "config.env.target.identity",
            "config.base-compose.yml",
            "config.base-compose.yml.identity",
        )
    ]
    if witness["config"] != actual_config:
        _fail("recovery")


def _receipt_runtime_binding(
    witness: dict[str, Any], current: dict[str, Any],
    commit: dict[str, Any], inspect: dict[str, Any],
    *, require_replacement_health: bool = True,
) -> None:
    """The original receipt proves cleanup; replacement health is a separate proof."""
    expected = {
        "schema": "meet-backend/test-vps-timepad-commit-witness/v1",
        "operationEpoch": current["operationEpoch"],
        "incidentId": current["incidentId"],
        "containerId": witness["containerId"],
        "configHash": current["configHash"],
        "imageId": inspect["Image"],
        "revision": current["target"]["tuple"]["revision"],
        "version": current["target"]["tuple"]["version"],
        "providerEnabled": _provider_state(inspect)[0],
    }
    if (
        commit != expected
        or inspect["Id"] != current["containerId"]
        or commit["configHash"] != inspect["Config"]["Labels"].get(
            "com.docker.compose.config-hash"
        )
        or witness["configHash"] != current["configHash"]
        or witness["operationEpoch"] != current["operationEpoch"]
        or witness["incidentId"] != current["incidentId"]
        or witness["imageId"] != inspect["Image"]
        or witness["revision"] != expected["revision"]
        or witness["version"] != expected["version"]
    ):
        _fail("recovery")
    baseline = witness.get("startAttemptId")
    latest = current.get("latestAttemptId")
    pattern = r"([a-f0-9]{32}):([1-9][0-9]{0,19})"
    original = re.fullmatch(pattern, baseline if isinstance(baseline, str) else "")
    attempt = re.fullmatch(pattern, latest if isinstance(latest, str) else "")
    if (
        original is None or attempt is None
        or original.group(1) != current["incidentId"]
        or attempt.group(1) != current["incidentId"]
        or int(original.group(2)) > (1 << 64) - 1
        or int(attempt.group(2)) > (1 << 64) - 1
    ):
        _fail("recovery")
    replacement = current["containerId"] != witness["containerId"]
    replacement_substeps = {
        "replacement-container-authorized",
        "replacement-provider-cleanup",
        "replacement-terminal-policy-intent",
        "replacement-policy-restored",
    }
    if current["commitSubstep"] in replacement_substeps and not replacement:
        _fail("recovery")
    # The counter identifies every owned command, including exact-container
    # retries. The monotonic replacement substeps, not a counter delta, enforce
    # the single replacement budget.
    if int(attempt.group(2)) < int(original.group(2)) + int(replacement):
        _fail("recovery")
    if replacement:
        if current["commitSubstep"] not in replacement_substeps or current["phase"] not in {
            "COMMITTING", "COMMITTED", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
        } or current["ownedChild"] is not None:
            _fail("recovery")
        _, healthy = _live_resume_runtime(inspect, current, "runtime")
        if require_replacement_health and not healthy:
            _fail("recovery")


def _resume_quarantined_child(
    directory_fd: int,
    entry: dict[str, Any],
    *,
    link_count: int,
) -> None:
    name = entry["name"]
    quarantine_name = entry["quarantineName"]
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        _fail("recovery")
    try:
        quarantine_info = os.stat(
            quarantine_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
    except OSError:
        _fail("recovery")
    record = entry["identity"]
    stable = _finalization_stable_identity(record)
    if (
        not stat.S_ISREG(quarantine_info.st_mode)
        or _stable_entry_identity(quarantine_info) != stable
        or quarantine_info.st_nlink != link_count
    ):
        _fail("recovery")
    try:
        fd = os.open(
            quarantine_name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        _fail("recovery")
    try:
        before = os.fstat(fd)
        if (
            not _same_inode(before, quarantine_info)
            or _stable_entry_identity(before) != stable
            or before.st_nlink != link_count
        ):
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{fd}",
            follow_symlinks=True,
            category="recovery",
        )
        data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
        if _finalization_digest(data) != record["sha256"]:
            _fail("recovery")
        after = os.fstat(fd)
        path_after = os.stat(
            quarantine_name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if (
            _stable_entry_identity(after) != stable
            or _stable_entry_identity(path_after) != stable
            or after.st_nlink != link_count
        ):
            _fail("recovery")
        _deadline_check()
        os.unlink(quarantine_name, dir_fd=directory_fd)
        _deadline_check()
        os.fsync(directory_fd)
    finally:
        os.close(fd)


def _cleanup_transaction_from_witness(
    run_key: str,
    witness: dict[str, Any],
) -> None:
    if not witness["providerEnabled"]:
        tx = _transaction(_rooted(HOST_CREDENTIAL_PARENT, None), run_key)
        try:
            os.stat(tx, follow_symlinks=False)
        except FileNotFoundError:
            return
        _fail("recovery")
    transaction = witness["transaction"]
    parent = _rooted(HOST_CREDENTIAL_PARENT, None)
    name = ".transaction-" + run_key
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        parent_info = os.fstat(parent_fd)
        parent_record = _directory_record(parent_info)
        if any(
            parent_record[key] != transaction["parent"][key]
            for key in ("device", "inode", "uid", "gid", "mode")
        ):
            _fail("recovery")
        _lock_directory(parent_fd)
        try:
            tx_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(tx_info.st_mode):
            _fail("recovery")
        tx_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            tx_record = _directory_record(os.fstat(tx_fd))
            if any(
                tx_record[key] != transaction["directory"][key]
                for key in ("device", "inode", "uid", "gid", "mode")
            ) or not _same_inode(os.fstat(tx_fd), tx_info):
                _fail("recovery")
            _lock_directory(tx_fd)
            entries = transaction["entries"]
            names = set(_iter_directory_fd_names(tx_fd))
            all_names = {
                item
                for entry in entries
                for item in (entry["name"], entry["quarantineName"])
            }
            if names - all_names:
                _fail("recovery")
            first_present = next(
                (
                    index
                    for index, entry in enumerate(entries)
                    if entry["name"] in names or entry["quarantineName"] in names
                ),
                len(entries),
            )
            for index, entry in enumerate(entries):
                original = entry["name"]
                quarantine = entry["quarantineName"]
                if index < first_present:
                    if original in names or quarantine in names:
                        _fail("recovery")
                    continue
                if index > first_present:
                    if original not in names or quarantine in names:
                        _fail("recovery")
                    continue
                if quarantine in names:
                    if original in names:
                        _fail("recovery")
                    link_count = (
                        entry["identity"]["links"]
                        if original == "publication"
                        else 1
                    )
                    _resume_quarantined_child(
                        tx_fd,
                        entry,
                        link_count=link_count,
                    )
                    names.remove(quarantine)
                elif original in names:
                    link_count = entry["identity"]["links"]
                    _witnessed_unlink(
                        tx_fd,
                        original,
                        expected_identity=_finalization_expected_identity(
                            entry["identity"]
                        ),
                        uid=entry["identity"]["uid"],
                        gid=entry["identity"]["gid"],
                        mode=entry["identity"]["mode"],
                        link_count=link_count,
                        quarantine_name=quarantine,
                        expected_data_digest=entry["identity"]["sha256"],
                        expected_stable_identity=_finalization_stable_identity(
                            entry["identity"]
                        ),
                    )
                    names.remove(original)
                    _deadline_check()
                    os.fsync(tx_fd)
                else:
                    _fail("recovery")
            if set(_iter_directory_fd_names(tx_fd)):
                _fail("recovery")
        finally:
            os.close(tx_fd)
        current_tx = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not _same_inode(current_tx, tx_info):
            _fail("recovery")
        _deadline_check()
        os.rmdir(name, dir_fd=parent_fd)
        _deadline_check()
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _verify_durable_credential(witness: dict[str, Any]) -> None:
    if not witness["providerEnabled"]:
        return
    path = _rooted(HOST_CREDENTIAL_PATH, None)
    fd, info, data = _open_regular(path, max_bytes=MAX_CREDENTIAL_BYTES)
    try:
        _validate_credential(data)
        record = witness["durableCredential"]
        if (
            info.st_dev != record["device"]
            or info.st_ino != record["inode"]
            or info.st_uid != record["uid"]
            or info.st_gid != record["gid"]
            or stat.S_IMODE(info.st_mode) != record["mode"]
            or info.st_size != record["size"]
            or info.st_mtime_ns != record["mtimeNs"]
            or info.st_nlink != 1
            or _finalization_digest(data) != record["sha256"]
        ):
            _fail("recovery")
    finally:
        os.close(fd)


def _terminal_bytes(witness: dict[str, Any]) -> bytes:
    return json.dumps(
        witness["terminal"],
        separators=(",", ":"),
    ).encode()


def _publish_terminal_record(run_fd: int, witness: dict[str, Any]) -> None:
    expected = _terminal_bytes(witness)
    try:
        terminal_info = os.stat(
            "terminal.json",
            dir_fd=run_fd,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        temporary = ".provider-terminal.tmp"
        try:
            os.stat(temporary, dir_fd=run_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail("recovery")
        _write_private_at(run_fd, temporary, expected, 0o600)
        _rename_noreplace(run_fd, temporary, "terminal.json")
        _deadline_check()
        os.fsync(run_fd)
        return
    except OSError:
        _fail("recovery")
    if (
        not stat.S_ISREG(terminal_info.st_mode)
        or terminal_info.st_uid != 0
        or stat.S_IMODE(terminal_info.st_mode) != 0o600
        or terminal_info.st_nlink != 1
    ):
        _fail("recovery")
    fd, _, actual = _open_private_state_file_at(run_fd, "terminal.json")
    try:
        if actual != expected:
            _fail("recovery")
        _parse_terminal_state_data(actual, witness["ownedRun"])
    finally:
        os.close(fd)


def _unlink_finalizing_pointer(
    state_root: str,
    run_key: str,
    witness: dict[str, Any],
) -> None:
    root_fd = os.open(
        state_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        try:
            info = os.stat(
                ".provider-transaction.current",
                dir_fd=root_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            _fail("recovery")
        marker = _marker(state_root, run_key)
        if marker != witness["pointer"]:
            _fail("recovery")
        pointer_fd, pointer_info, data = _open_private_state_file_at(
            root_fd,
            ".provider-transaction.current",
        )
        try:
            if not _same_inode(info, pointer_info):
                _fail("recovery")
            if _json(data, "recovery") != witness["pointer"]:
                _fail("recovery")
            final = os.stat(
                ".provider-transaction.current",
                dir_fd=root_fd,
                follow_symlinks=False,
            )
            if (
                not _same_inode(final, os.fstat(pointer_fd))
                or _identity(final) != _identity(os.fstat(pointer_fd))
            ):
                _fail("recovery")
            _deadline_check()
            os.unlink(".provider-transaction.current", dir_fd=root_fd)
            _deadline_check()
            os.fsync(root_fd)
        finally:
            os.close(pointer_fd)
    finally:
        os.close(root_fd)


def _finalization_result(digest: str, outcome: str) -> None:
    _deadline_check()
    if (
        re.fullmatch(r"[0-9a-f]{64}", digest) is None
        or outcome != "witness-prepared"
    ):
        _fail("recovery")
    sys.stdout.write(
        json.dumps(
            {
                "schemaVersion": SCHEMA_VERSION,
                "providerFinalizationDigest": digest,
                "outcome": outcome,
            },
            separators=(",", ":"),
        )
        + "\n"
    )


def _open_deploy_state_root(state_root: str) -> int:
    expected = _validate_retention_state_root_path(state_root)
    try:
        fd = os.open(
            state_root,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        )
    except OSError:
        _fail("recovery")
    if not _same_inode(os.fstat(fd), expected):
        os.close(fd)
        _fail("recovery")
    _validate_retention_state_root_fd(fd)
    return fd


def _prepare_committed_finalization(
    run_key: str,
    state_root: str,
    state_kind: str,
    inspect_data: bytes,
    deploy_lock_fd: int,
) -> None:
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        _, run_fd, _, origin, current, _ = _finalization_context(
            run_key,
            state_root,
            state_kind,
            inspect_data,
            deploy_lock_fd,
            for_resume=False,
        )
        try:
            _lock_directory(run_fd)
            if current["phase"] not in ("VERIFYING", "COMMITTING"):
                _fail("recovery")
            if current["phase"] == "COMMITTING" and current.get("commitSubstep") != "provider-cleanup":
                _fail("recovery")
            commit, _, _ = _controller_commit_witness(
                run_fd,
                current,
                require_state_digest=current["phase"] == "COMMITTING",
            )
            inspect = _inspect(inspect_data)
            witness = _build_finalization_witness(
                run_key=run_key,
                state_kind=state_kind,
                origin=origin,
                current=current,
                commit=commit,
                run_fd=run_fd,
                inspect=inspect,
                state_root=state_root,
            )
            data = json.dumps(
                witness,
                sort_keys=True,
                separators=(",", ":"),
            ).encode()
            if len(data) > MAX_FINALIZATION_BYTES:
                _fail("recovery")
            _store_finalization_witness(run_fd, data)
            digest = _finalization_digest(data)
            if (
                current.get("providerFinalizationDigest") is not None
                and current["providerFinalizationDigest"] != digest
            ):
                _fail("recovery")
            _finalization_result(digest, "witness-prepared")
        finally:
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _finalize_tx_residual(
    run_key: str,
    transaction: dict[str, Any],
) -> None:
    parent = _rooted(HOST_CREDENTIAL_PARENT, None)
    name = ".transaction-" + run_key
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        parent_info = os.fstat(parent_fd)
        expected_parent = transaction["parent"]
        if any(
            getattr(parent_info, field) != value
            for field, value in (
                ("st_dev", expected_parent["device"]),
                ("st_ino", expected_parent["inode"]),
                ("st_uid", expected_parent["uid"]),
                ("st_gid", expected_parent["gid"]),
            )
        ) or stat.S_IMODE(parent_info.st_mode) != expected_parent["mode"]:
            _fail("recovery")
        _lock_directory(parent_fd)
        try:
            tx_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(tx_info.st_mode):
            _fail("recovery")
        tx_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            tx_info_fd = os.fstat(tx_fd)
            expected_tx = transaction["directory"]
            if (
                not _same_inode(tx_info_fd, tx_info)
                or tx_info_fd.st_uid != expected_tx["uid"]
                or tx_info_fd.st_gid != expected_tx["gid"]
                or stat.S_IMODE(tx_info_fd.st_mode) != expected_tx["mode"]
                or (tx_info_fd.st_dev, tx_info_fd.st_ino)
                != (expected_tx["device"], expected_tx["inode"])
            ):
                _fail("recovery")
            _lock_directory(tx_fd)
            entries = transaction["entries"]
            allowed = {
                name
                for entry in entries
                for name in (entry["name"], entry["quarantineName"])
            }
            while True:
                names = set(_iter_directory_fd_names(tx_fd))
                if names - allowed:
                    _fail("recovery")
                first = next(
                    (
                        index
                        for index, entry in enumerate(entries)
                        if entry["name"] in names or entry["quarantineName"] in names
                    ),
                    len(entries),
                )
                if first == len(entries):
                    break
                for index, entry in enumerate(entries):
                    original = entry["name"]
                    quarantine = entry["quarantineName"]
                    if index < first:
                        if original in names or quarantine in names:
                            _fail("recovery")
                        continue
                    if index > first:
                        if original not in names or quarantine in names:
                            _fail("recovery")
                        continue
                    if (original in names) == (quarantine in names):
                        _fail("recovery")
                entry = entries[first]
                _witnessed_unlink(
                    tx_fd,
                    entry["name"],
                    expected_identity=_finalization_expected_identity(
                        entry["identity"]
                    ),
                    uid=entry["identity"]["uid"],
                    gid=entry["identity"]["gid"],
                    mode=entry["identity"]["mode"],
                    link_count=entry["identity"]["links"],
                    quarantine_name=entry["quarantineName"],
                    expected_data_digest=entry["identity"]["sha256"],
                    expected_stable_identity=_finalization_stable_identity(
                        entry["identity"]
                    ),
                )
                _deadline_check()
                os.fsync(tx_fd)
        finally:
            os.close(tx_fd)
        final_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not _same_inode(final_info, tx_info):
            _fail("recovery")
        _deadline_check()
        os.rmdir(name, dir_fd=parent_fd)
        _deadline_check()
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _verify_finalization_durable(witness: dict[str, Any]) -> None:
    if not witness["providerEnabled"]:
        return
    fd, info, data = _open_regular(
        _rooted(HOST_CREDENTIAL_PATH, None),
        max_bytes=MAX_CREDENTIAL_BYTES,
    )
    try:
        _validate_credential(data)
        expected = witness["durableCredential"]
        if (
            (info.st_dev, info.st_ino, info.st_uid, info.st_gid)
            != (
                expected["device"],
                expected["inode"],
                expected["uid"],
                expected["gid"],
            )
            or stat.S_IMODE(info.st_mode) != expected["mode"]
            or info.st_size != expected["size"]
            or info.st_mtime_ns != expected["mtimeNs"]
            or info.st_nlink != 1
            or _finalization_digest(data) != expected["sha256"]
        ):
            _fail("recovery")
    finally:
        os.close(fd)


def _publish_finalization_terminal(
    run_fd: int,
    witness: dict[str, Any],
) -> None:
    expected = json.dumps(
        witness["terminal"],
        separators=(",", ":"),
    ).encode()
    try:
        current = os.stat(
            "terminal.json",
            dir_fd=run_fd,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        temporary = ".provider-terminal.tmp"
        try:
            os.stat(temporary, dir_fd=run_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail("recovery")
        _write_private_at(run_fd, temporary, expected, 0o600)
        _rename_noreplace(run_fd, temporary, "terminal.json")
        _deadline_check()
        os.fsync(run_fd)
        return
    except OSError:
        _fail("recovery")
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != 0
        or stat.S_IMODE(current.st_mode) != 0o600
        or current.st_nlink != 1
    ):
        _fail("recovery")
    fd, opened, data = _open_private_state_file_at(run_fd, "terminal.json")
    try:
        if not _same_inode(current, opened) or data != expected:
            _fail("recovery")
        _parse_terminal_state_data(data, witness["ownedRun"])
    finally:
        os.close(fd)


def _validate_existing_finalization_terminal(
    run_fd: int,
    witness: dict[str, Any],
) -> None:
    expected = json.dumps(
        witness["terminal"],
        separators=(",", ":"),
    ).encode()
    try:
        info = os.stat("terminal.json", dir_fd=run_fd, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
    ):
        _fail("recovery")
    fd, opened, data = _open_private_state_file_at(run_fd, "terminal.json")
    try:
        if not _same_inode(info, opened) or data != expected:
            _fail("recovery")
        _parse_terminal_state_data(data, witness["ownedRun"])
    finally:
        os.close(fd)


def _remove_finalizing_pointer(
    state_root: str,
    run_key: str,
    witness: dict[str, Any],
) -> None:
    root_fd = _open_deploy_state_root(state_root)
    try:
        try:
            path_info = os.stat(
                ".provider-transaction.current",
                dir_fd=root_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            return
        except OSError:
            _fail("recovery")
        if (
            not stat.S_ISREG(path_info.st_mode)
            or path_info.st_uid != 0
            or stat.S_IMODE(path_info.st_mode) != 0o600
            or path_info.st_nlink != 1
        ):
            _fail("recovery")
        marker = _marker(state_root, run_key)
        if marker != witness["pointer"]:
            _fail("recovery")
        fd, opened, data = _open_private_state_file_at(
            root_fd,
            ".provider-transaction.current",
        )
        try:
            if (
                not _same_inode(path_info, opened)
                or _json(data, "recovery") != witness["pointer"]
                or _identity(path_info) != _identity(os.fstat(fd))
            ):
                _fail("recovery")
            latest_path = os.stat(
                ".provider-transaction.current",
                dir_fd=root_fd,
                follow_symlinks=False,
            )
            if (
                not _same_inode(latest_path, os.fstat(fd))
                or _identity(latest_path) != _identity(os.fstat(fd))
            ):
                _fail("recovery")
            _deadline_check()
            os.unlink(".provider-transaction.current", dir_fd=root_fd)
            _deadline_check()
            os.fsync(root_fd)
        finally:
            os.close(fd)
    finally:
        os.close(root_fd)


def _finish_committed_resume(
    run_key: str,
    state_root: str,
    state_kind: str,
    inspect_data: bytes,
    deploy_lock_fd: int,
) -> None:
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        _, run_fd, _, origin, current, commit_data = _finalization_context(
            run_key,
            state_root,
            state_kind,
            inspect_data,
            deploy_lock_fd,
            for_resume=True,
        )
        try:
            _lock_directory(run_fd)
            witness, witness_data = _read_finalization_witness(run_fd)
            witness_digest = _finalization_digest(witness_data)
            if (
                witness_digest != current["providerFinalizationDigest"]
                or witness["commitWitnessDigest"] != current["commitWitnessDigest"]
                or witness["originDigest"] != origin["originDigest"]
                or witness["ownedRun"] != current["ownedRun"]
                or witness["runKey"] != run_key
                or witness["stateKind"] != state_kind
            ):
                _fail("recovery")
            try:
                pointer_info = os.stat(
                    ".provider-transaction.current",
                    dir_fd=root_fd,
                    follow_symlinks=False,
                )
                pointer_present = True
            except FileNotFoundError:
                pointer_present = False
            if pointer_present and _marker(state_root, run_key) != witness["pointer"]:
                _fail("recovery")
            if not pointer_present:
                _validate_existing_finalization_terminal(run_fd, witness)
                tx = _transaction(_rooted(HOST_CREDENTIAL_PARENT, None), run_key)
                try:
                    os.stat(tx, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
                    _fail("recovery")
            commit, actual_commit_data, commit_digest = _controller_commit_witness(
                run_fd,
                current,
                require_state_digest=True,
            )
            if actual_commit_data != commit_data:
                _fail("recovery")
            inspect = _inspect(inspect_data)
            _matches_finalization_context(
                witness,
                origin=origin,
                current=current,
                commit=commit,
                commit_data=commit_data,
                run_fd=run_fd,
                inspect=inspect,
            )
            if commit_digest != witness["commitWitnessDigest"]:
                _fail("recovery")
            _finalize_tx_residual(run_key, witness["transaction"]) if witness[
                "providerEnabled"
            ] else _cleanup_transaction_from_witness(run_key, witness)
            _verify_finalization_durable(witness)
            _publish_finalization_terminal(run_fd, witness)
            _remove_finalizing_pointer(state_root, run_key, witness)
            enabled = witness["providerEnabled"]
            _result(enabled, enabled, enabled, "committed")
        finally:
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _live_resume_authority(
    value: Any,
    *,
    module: Any,
    origin: dict[str, Any],
    current: dict[str, Any],
    run_key: str,
    state_kind: str,
) -> tuple[dict[str, Any], str]:
    keys = {"schema", "authorization", "inspection", "stage"}
    if current.get("phase") == "PREPARED":
        keys |= {"imageInspection", "targetConfiguration", "backendInventory"}
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or value["schema"] != LIVE_RESUME_SCHEMA
        or value["stage"] not in ("admission", "runtime", "quiescence")
        or value["stage"] == "quiescence" and (
            current.get("ownedChild") is None or current.get("phase") == "COMMITTED"
        )
        or not isinstance(value["authorization"], dict)
    ):
        _fail("recovery")
    _resume_binding_authority(
        value["authorization"], module=module, origin=origin, current=current,
        run_key=run_key, state_kind=state_kind,
    )
    if current["phase"] == "PREPARED" and any(
        current.get(key) is not None
        for key in (
            "containerId", "configHash", "commitWitnessDigest",
            "providerFinalizationDigest", "commitSubstep", "terminalReceipt",
            "ownedChild", "latestAttemptId",
        )
    ):
        _fail("recovery")
    # Quiescence admission is read-only and authorizes no finalization. It
    # proves all inputs before the controller asks the state helper to signal
    # the independently identified owned group. Runtime proof follows again
    # after stop, group absence and durable reap/clear.
    if current["ownedChild"] is not None:
        try:
            if value["stage"] != "quiescence" or not module.owned_child_is_same_process(
                current["ownedChild"]
            ):
                module.require_child_group_quiescent(current["ownedChild"])
        except (module.GuardError, OSError):
            _fail("recovery")
    inspect = _inspect(json.dumps(value["inspection"], separators=(",", ":")).encode())
    if current["phase"] == "PREPARED" and (
        value["stage"] != "admission"
        or value["backendInventory"] != [current["predecessorContainerId"]]
        or inspect.get("Id") != current["predecessorContainerId"]
    ):
        _fail("recovery")
    return inspect, value["stage"]


def _resume_binding_authority(
    authorization: dict[str, Any], *, module: Any, origin: dict[str, Any],
    current: dict[str, Any], run_key: str, state_kind: str,
) -> None:
    if (
        current.get("originDigest") != origin.get("originDigest")
        or current.get("runId") != run_key
        or current.get("ownedRun") != f"{run_key}-{state_kind}"
        or current.get("operation") != (
            "deploy" if state_kind == "final-deploy" else "rollback-drill"
        )
    ):
        _fail("recovery")
    try:
        module.authorize_recovery(
            authorization, root_id=origin["rootId"], current=current
        )
        contract = module.parse_contract(module._read_input(
            pathlib.Path(__file__).with_name("test-vps-timepad-release-contracts.json"),
            module.MAX_CONTRACT_BYTES,
        ))
        admission = module.admit(
            contract,
            root_id=origin["rootId"],
            target_id=current["target"]["id"],
            predecessor_id=current["predecessor"]["id"],
            transition_id=current["transitionId"],
            target_tuple=current["target"]["tuple"],
            predecessor_tuple=current["predecessor"]["tuple"],
        )
    except (module.GuardError, OSError, ValueError, TypeError, KeyError):
        _fail("recovery")
    target = current["target"]["tuple"]
    if (
        admission.disposition != current["predecessorDisposition"]
        or admission.contract_digest != current["evidenceDigest"]
        or target["retryExact"] is not True
        or target["unknownTransitionCovered"] is not True
        or target["dependencyPolicy"] != "resolved"
    ):
        _fail("recovery")
def _live_resume_runtime(
    inspect: dict[str, Any], current: dict[str, Any], stage: str
) -> tuple[bool, bool]:
    config = inspect.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    state = inspect.get("State")
    host = inspect.get("HostConfig")
    restart = host.get("RestartPolicy") if isinstance(host, dict) else None
    if (
        not isinstance(labels, dict)
        or not isinstance(state, dict)
        or not isinstance(restart, dict)
        or type(state.get("Running")) is not bool
        or state.get("Paused") is not False
        or state.get("Restarting") is not False
        or state.get("Dead") is not False
        or labels.get("com.docker.compose.project") != "meet-production"
        or labels.get("com.docker.compose.service") != "backend"
        or not isinstance(inspect.get("Id"), str)
        or re.fullmatch(r"[a-f0-9]{12,64}", inspect["Id"]) is None
        or not isinstance(labels.get("com.docker.compose.config-hash"), str)
        or re.fullmatch(
            r"[a-f0-9]{64}", labels["com.docker.compose.config-hash"]
        ) is None
        or restart.get("Name") not in ("no", "unless-stopped")
    ):
        _fail("recovery")
    target = current["target"]["tuple"]
    exact_target = (
        current["phase"] != "PREPARED"
        and inspect.get("Image") == "sha256:" + target["platformImageId"]
    )
    expected_tuple = target
    if exact_target:
        if (
            current.get("containerId") != inspect["Id"]
            or current.get("configHash") != labels["com.docker.compose.config-hash"]
        ):
            _fail("recovery")
    else:
        if stage != "admission" or current["phase"] not in {
            "PREPARED", "CUTOVER_POSSIBLE", "ROLLING_BACK",
            "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
        } or current.get("providerFinalizationDigest") is not None:
            _fail("recovery")
        expected_tuple = current["predecessor"]["tuple"]
        if (
            inspect.get("Image") != "sha256:" + expected_tuple["platformImageId"]
            or inspect["Id"] != current.get("predecessorContainerId")
        ):
            _fail("recovery")
        # Past the fence even a known incompatible predecessor must be stopped.
        if current["phase"] != "PREPARED" and (
            state["Running"] or restart["Name"] != "no"
        ):
            _fail("recovery")
    if (
        labels.get("org.opencontainers.image.revision") != expected_tuple["revision"]
        or labels.get("org.opencontainers.image.version") != expected_tuple["version"]
        or labels.get("org.opencontainers.image.source")
        != "https://github.com/NickolayMamonov/meet-backend-v3"
        or config.get("User") != "10001:10001"
    ):
        _fail("recovery")
    phase = current["phase"]
    if exact_target and phase != "COMMITTED":
        permitted = {"no"}
        if phase in {"COMMITTING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"} and (
            current["commitSubstep"] in {
                "terminal-policy-intent", "policy-restored",
                "replacement-terminal-policy-intent", "replacement-policy-restored",
            }
        ):
            permitted.add("unless-stopped")
        if restart["Name"] not in permitted:
            _fail("recovery")
    healthy = (
        exact_target and state["Running"]
        and isinstance(state.get("Health"), dict)
        and state["Health"].get("Status") == "healthy"
    )
    if phase == "COMMITTED" and (
        not healthy or restart["Name"] != "unless-stopped"
        or current["ownedChild"] is not None
    ):
        _fail("recovery")
    return exact_target, healthy


def _runtime_request_proof(
    current: dict[str, Any], inspect: dict[str, Any],
) -> dict[str, Any]:
    """Revalidate the effect of an explicitly acknowledged single-container RPC.

    An inspect/ps result cannot complete an intent: the original synchronous
    daemon response must already be durable. The digest covers only sanitized
    correlation/runtime fields, never environment or provider payloads.
    """
    module = _timepad_state_module()
    try:
        request = module.runtime_request(current["runtimeRequest"])
    except (module.GuardError, TypeError, KeyError):
        _fail("recovery")
    predecessor = request.get("role") == "predecessor"
    if predecessor and (
        current["phase"] != "PREPARED"
        or request["containerId"] != current["predecessorContainerId"]
        or request["imageId"] != current["predecessor"]["tuple"]["platformImageId"]
        or any(request[key] != current[key] for key in (
            "originDigest", "incidentId", "operationEpoch", "executionAttempt",
            "preparedProofDigest", "evidenceDigest",
        ))
    ):
        _fail("recovery")
    admission = predecessor and request["lifecycle"] == "intent"
    if request["operation"] == "create" or (
        request["lifecycle"] != "acknowledged" and not admission
    ):
        _fail("recovery")
    if request["childAttemptId"] is not None and current["ownedChild"] is not None:
        if request["childAttemptId"] != current["ownedChild"]["attemptId"]:
            _fail("recovery")
        try:
            module.require_child_group_quiescent(current["ownedChild"])
        except (module.GuardError, OSError):
            _fail("recovery")
    exact, _ = _live_resume_runtime(inspect, current, "admission" if predecessor else "runtime")
    if (
        exact == predecessor or inspect["Id"] != request["containerId"]
        or inspect["Image"] != "sha256:" + request["imageId"]
        or inspect["Config"]["Labels"]["com.docker.compose.config-hash"] != request["configHash"]
    ):
        _fail("recovery")
    running = inspect["State"]["Running"]
    policy = inspect["HostConfig"]["RestartPolicy"]["Name"]
    operation = request["operation"]
    if admission:
        if current["phase"] != "PREPARED" or (
            operation == "suppress" and not running
            or operation == "stop" and policy != "no"
        ):
            _fail("recovery")
        return {
            "requestNonce": request["nonce"],
            "admissionDigest": _configuration_digest({
                "request": request, "running": running, "restartPolicy": policy,
            }),
        }
    if (
        operation == "start" and (not running or policy != "no")
        or operation == "stop" and (running or policy != "no")
        or operation == "suppress" and policy != "no"
        or operation == "restore-policy" and (not running or policy != "unless-stopped")
    ):
        _fail("recovery")
    return {
        "requestNonce": request["nonce"],
        "completionDigest": _configuration_digest({
            "request": request, "originDigest": current["originDigest"],
            "incidentId": current["incidentId"], "operationEpoch": current["operationEpoch"],
            "evidenceDigest": current["evidenceDigest"],
            "running": running, "restartPolicy": policy,
        }),
    }


def _runtime_request_completion(
    run_key: str, state_root: str, state_kind: str, input_data: bytes, deploy_lock_fd: int,
) -> None:
    """Fixed read-only adapter; publication remains under the controller's state grant."""
    value = _json(input_data, "recovery")
    if not isinstance(value, dict):
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        module, _, current = _timepad_current(state_root, deploy_lock_fd)
        if (
            state_kind not in STATE_KINDS or current["runId"] != run_key
            or current["ownedRun"] != f"{run_key}-{state_kind}"
            or current["runtimeRequest"] is None
            or value.get("requestNonce") != current["runtimeRequest"]["nonce"]
        ):
            _fail("recovery")
        create = current["runtimeRequest"]["operation"] == "create"
        fields = {"requestNonce", "inspection"}
        if create:
            fields |= {
                "imageInspection", "targetConfiguration", "backendInventory", "composeInventory",
                "resourceEvidence", "requestBaseline",
            }
        if set(value) != fields:
            _fail("recovery")
        run_fd = os.open(
            current["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd,
        )
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, current["ownedRun"])
            inspection = _inspect(json.dumps(value["inspection"], separators=(",", ":")).encode())
            if create:
                request = current["runtimeRequest"]
                name = ("timepad-create-completion.json" if request["role"] == "initial"
                        else "timepad-replacement-completion.json")
                result = _stopped_create_binding(
                    run_fd, current,
                    _inspect(json.dumps(value["imageInspection"], separators=(",", ":")).encode()),
                    value["targetConfiguration"], inspection,
                    value["backendInventory"], value["composeInventory"],
                    completion_lease=module._read_execution_lease_locked(state_root),
                    completion_receipt=_read_child_file(
                        run_fd, name, module.MAX_CREATE_COMPLETION_BYTES,
                    )[1],
                    resource_evidence=value["resourceEvidence"],
                    request_baseline=value["requestBaseline"],
                )
            else:
                _live_resume_config(run_fd, current)
                if current["runtimeRequest"].get("role") == "predecessor":
                    if current["phase"] != "PREPARED":
                        _fail("recovery")
                    proof = _prepared_proof(run_fd, current)
                    _prepared_no_commit_files(run_fd)
                    _live_resume_runtime(inspection, current, "admission")
                    _live_resume_predecessor(run_fd, current, inspection)
                    if (
                        proof["provider"] != _prepared_transaction(run_key, state_root, inspection)
                        or proof["effectiveProviderDigest"] != _configuration_digest(_effective_tuple(inspection))
                    ):
                        _fail("recovery")
                result = _runtime_request_proof(current, inspection)
            _, _, final = _timepad_current(state_root, deploy_lock_fd)
            if final != current:
                _fail("recovery")
            _deadline_check()
            print(json.dumps(result, separators=(",", ":")))
        finally:
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _live_resume_config(run_fd: int, current: dict[str, Any]) -> None:
    if current["phase"] == "PREPARED":
        _prepared_proof(run_fd, current)
        return
    names = ("config.env.target", "config.base-compose.yml")
    for name in names:
        _snapshot_source_identity(run_fd, name)


def _snapshot_source_identity(run_fd: int, name: str) -> None:
    record, data = _read_child_file(run_fd, name, MAX_CREDENTIAL_BYTES)
    _, identity = _read_child_file(run_fd, name + ".identity", MAX_OWNER_BYTES)
    match = re.fullmatch(
        rb"([0-9]+):([0-9]+):([0-9]+):([0-9]+):([0-9]+):"
        rb"([0-9]+):([0-9]+):([0-9]+):([0-9a-f]{64})\n?",
        identity,
    )
    if match is None:
        _fail("recovery")
    fields = match.groups()
    if (
        int(fields[3]) != 0
        or not stat.S_ISREG(int(fields[2]))
        or stat.S_IMODE(int(fields[2])) & 0o022
        or int(fields[5]) != len(data)
        or fields[8].decode("ascii") != record["sha256"]
    ):
        _fail("recovery")


PREPARED_CONFIG = (
    "config.env.production", "config.env.production.identity",
    "config.base-compose.yml", "config.base-compose.yml.identity",
    "config.env.target", "config.env.previous", "target-runtime.override.yml",
)
PREPARED_BINDING = (
    "originDigest", "operationEpoch", "operation", "runId", "incidentId",
    "ownedRun", "target", "transitionId", "evidenceDigest", "toolingDigest",
    "predecessorContainerId",
)


def _prepared_no_commit_files(run_fd: int) -> None:
    for name in (
        "timepad-commit-witness.json", "provider-finalization.json", "terminal.json",
    ):
        try:
            os.stat(name, dir_fd=run_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        _fail("recovery")


def _prepared_environment(run_fd: int, current: dict[str, Any]) -> None:
    _, source = _read_child_file(run_fd, "config.env.production", MAX_CREDENTIAL_BYTES)
    try:
        text = source.decode("utf-8")
    except UnicodeDecodeError:
        _fail("recovery")
    for name, binding, reference in (
        (
            "config.env.target", current["target"],
            "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
            + current["target"]["tuple"]["repositoryDigest"],
        ),
        (
            "config.env.previous", current["predecessor"],
            _read_child_file(run_fd, "previous-image", MAX_OWNER_BYTES)[1].decode("ascii").rstrip("\n"),
        ),
    ):
        replacements = {
            "BACKEND_IMAGE": reference,
            "BACKEND_REVISION": binding["tuple"]["revision"],
            "BACKEND_VERSION": binding["tuple"]["version"],
        }
        seen = set()
        lines = []
        for line in text.splitlines(keepends=True):
            match = re.match(r"^(BACKEND_IMAGE|BACKEND_REVISION|BACKEND_VERSION)=", line)
            if match:
                key = match.group(1)
                if key in seen:
                    _fail("recovery")
                seen.add(key)
                ending = line[len(line.rstrip("\r\n")):]
                line = f"{key}={replacements[key]}{ending}"
            lines.append(line)
        _, actual = _read_child_file(run_fd, name, MAX_CREDENTIAL_BYTES)
        if seen != set(replacements) or actual != "".join(lines).encode("utf-8"):
            _fail("recovery")


def _prepared_config_records(run_fd: int) -> list[dict[str, Any]]:
    names = list(PREPARED_CONFIG)
    for kind in ("compose", "runtime"):
        group = (
            f"had-active-{kind}", f"previous-active-{kind}.yml",
            f"previous-active-{kind}.identity",
        )
        present = []
        for name in group:
            try:
                os.stat(name, dir_fd=run_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            present.append(name)
        if present and tuple(present) != group:
            _fail("recovery")
        names.extend(present)
    return [{"name": name, "identity": _file_record(run_fd, name)} for name in names]


def _prepared_transaction(
    run_key: str, state_root: str, inspect: dict[str, Any],
) -> dict[str, Any]:
    return _intact_provider_record(
        run_key, state_root, inspect, allowed_phases={"prepared", "applying"},
    )


def _intact_provider_record(
    run_key: str, state_root: str, inspect: dict[str, Any], *, allowed_phases: set[str],
) -> dict[str, Any]:
    marker = _live_resume_transaction(run_key, state_root, inspect, predecessor=True)
    if marker["phase"] not in allowed_phases:
        _fail("recovery")
    result: dict[str, Any] = {
        "providerEnabled": marker["providerEnabled"],
        "durableDisposition": marker["durableDisposition"],
        "transaction": None,
    }
    if not marker["providerEnabled"]:
        return result
    parent_fd = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
    if parent_fd is None:
        _fail("recovery")
    try:
        tx_fd = os.open(
            ".transaction-" + run_key, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            _lock_directory(tx_fd)
            names = ["identity.json", "snapshot"]
            if marker["durableDisposition"] == "created":
                names.append("publication")
            result["transaction"] = {
                "parent": _directory_record(os.fstat(parent_fd)),
                "directory": _directory_record(os.fstat(tx_fd)),
                "entries": [
                    {"name": name, "identity": _file_record(
                        tx_fd, name, gid=10001 if name == "publication" else 0,
                        mode=0o440 if name == "publication" else 0o600,
                        links=2 if name == "publication" else 1,
                    )}
                    for name in names
                ],
            }
        finally:
            os.close(tx_fd)
    finally:
        os.close(parent_fd)
    return result


def _rollback_source(path: str) -> tuple[bytes, bytes]:
    """Read a protected live configuration and its existing shell identity."""
    parent, name = _open_reference_parent(path)
    fd = None
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode) or info.st_uid != 0
            or info.st_mode & 0o022 or info.st_nlink != 1
            or info.st_size > MAX_CREDENTIAL_BYTES
        ):
            _fail("recovery")
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
        data = bytearray()
        while len(data) <= MAX_CREDENTIAL_BYTES:
            _deadline_check()
            chunk = os.read(fd, min(65536, MAX_CREDENTIAL_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        final_info = os.fstat(fd)
        path_info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if (
            len(data) != info.st_size
            or len(data) > MAX_CREDENTIAL_BYTES
            or _stable_entry_identity(final_info) != _stable_entry_identity(info)
            or final_info.st_ctime_ns != info.st_ctime_ns
            or _stable_entry_identity(path_info) != _stable_entry_identity(info)
            or path_info.st_ctime_ns != info.st_ctime_ns
        ):
            _fail("recovery")
        identity = (
            f"{info.st_dev}:{info.st_ino}:{info.st_mode}:{info.st_uid}:"
            f"{info.st_gid}:{info.st_size}:{info.st_mtime_ns}:{info.st_ctime_ns}:"
            f"{hashlib.sha256(data).hexdigest()}\n"
        ).encode("ascii")
        return bytes(data), identity
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent)


def _rollback_configuration(run_fd: int, deployment_root: str, base_compose: str) -> str:
    """Admit only a completely recorded original or target configuration."""
    _retention_reference(deployment_root)
    _retention_reference(base_compose)
    base, identity = _rollback_source(base_compose)
    if (
        base != _read_child_file(run_fd, "config.base-compose.yml", MAX_CREDENTIAL_BYTES)[1]
        or identity != _read_child_file(run_fd, "config.base-compose.yml.identity", MAX_OWNER_BYTES)[1]
    ):
        _fail("recovery")
    environment, identity = _rollback_source(deployment_root + "/.env.production")
    selected = None
    for view in ("production", "target"):
        name = f"config.env.{view}"
        expected = _read_child_file(run_fd, name, MAX_CREDENTIAL_BYTES)[1]
        try:
            recorded = _read_child_file(run_fd, name + ".identity", MAX_OWNER_BYTES)[1]
        except FileNotFoundError:
            continue
        if environment == expected and identity == recorded:
            selected = view
            break
    if selected is None:
        _fail("recovery")
    for kind, path in (
        ("compose", "/var/lib/meet-production/active-compose.yml"),
        ("runtime", "/var/lib/meet-production/active-runtime.override.yml"),
    ):
        try:
            live, identity = _rollback_source(path)
        except FileNotFoundError:
            try:
                os.stat(f"had-active-{kind}", dir_fd=run_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            _fail("recovery")
        admitted = False
        for prefix in ("previous", "candidate"):
            try:
                recorded = _read_child_file(
                    run_fd, f"{prefix}-active-{kind}.identity", MAX_OWNER_BYTES,
                )[1]
                expected = _read_child_file(
                    run_fd, f"{prefix}-active-{kind}.yml", MAX_CREDENTIAL_BYTES,
                )[1]
            except FileNotFoundError:
                continue
            if identity == recorded and live == expected:
                admitted = True
                break
        if not admitted:
            _fail("recovery")
    return selected


def _rollback_runtime_proof(
    state_root: str, current: dict[str, Any], lease: dict[str, Any],
    input_data: bytes, check: Callable[[], None], *, claim: bool = False,
) -> dict[str, Any]:
    """Read-only failure rollback proof; never imports forward-recovery authority."""
    token = _EXECUTION_CHECK.set(check)
    try:
        return _reconstruct_rollback_runtime(state_root, current, lease, input_data, check, claim=claim)
    finally:
        _EXECUTION_CHECK.reset(token)


def _reconstruct_rollback_runtime(
    state_root: str, current: dict[str, Any], lease: dict[str, Any],
    input_data: bytes, check: Callable[[], None], *, claim: bool,
) -> dict[str, Any]:
    check()
    module = _timepad_state_module()
    module._rollback_state_admission(
        current, lease, "rolling-back" if claim else "rollback-admission",
    )
    value = _json(input_data, "recovery")
    if (
        not isinstance(value, dict)
        or set(value) != {"deploymentRoot", "baseCompose", "backendInventory", "inspection"}
        or value["backendInventory"] != [current["predecessorContainerId"]]
        or current["containerId"] is not None
    ):
        # A replaced/absent predecessor needs independently reconstructed
        # original runtime evidence; one candidate inventory cannot supply it.
        _fail("recovery")
    inspect = _inspect(json.dumps(value["inspection"], separators=(",", ":")).encode())
    if _live_resume_runtime(inspect, current, "admission")[0]:
        _fail("recovery")
    if current["runtimeRequest"] is not None:
        request = module.require_runtime_request_completion(current)
        if request.get("role") != "predecessor":
            _fail("recovery")
    elif current["phase"] != "PREPARED":
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        run_fd = os.open(
            current["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd,
        )
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, current["ownedRun"])
            proof = _prepared_proof(run_fd, current)
            _prepared_no_commit_files(run_fd)
            _prepared_environment(run_fd, current)
            _live_resume_predecessor(run_fd, current, inspect)
            provider = _intact_provider_record(
                current["runId"], state_root, inspect,
                allowed_phases={"prepared", "applying", "verifying"},
            )
            if (
                provider != proof["provider"]
                or proof["effectiveProviderDigest"] != _configuration_digest(_effective_tuple(inspect))
            ):
                _fail("recovery")
            installed = _rollback_configuration(run_fd, value["deploymentRoot"], value["baseCompose"])
            reference = _read_child_file(run_fd, "previous-image", MAX_OWNER_BYTES)[1].decode("ascii").rstrip("\n")
            result = {
                **{key: current[key] for key in (
                    "originDigest", "incidentId", "operationEpoch", "executionAttempt",
                    "runId", "ownedRun", "preparedProofDigest", "evidenceDigest",
                )},
                "currentDigest": _configuration_digest(current),
                "leaseRevision": lease["revision"],
                "predecessor": current["predecessor"], "predecessorContainerId": inspect["Id"],
                "previousImage": reference,
                "previousConfigHash": inspect["Config"]["Labels"]["com.docker.compose.config-hash"],
                "providerEnabled": provider["providerEnabled"],
                "durableDisposition": provider["durableDisposition"],
                "installedEnvironment": installed,
            }
            check()
            return dict(result, proofDigest=_configuration_digest(result))
        finally:
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _prepared_proof(run_fd: int, current: dict[str, Any]) -> dict[str, Any]:
    try:
        os.stat(".timepad-prepared.tmp", dir_fd=run_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        _fail("recovery")
    _, data = _read_child_file(run_fd, "timepad-prepared.json", MAX_PREPARED_BYTES)
    if _finalization_digest(data) != current.get("preparedProofDigest"):
        _fail("recovery")
    proof = _json(data, "recovery")
    if (
        not isinstance(proof, dict)
        or set(proof) != {
            "schema", "binding", "config", "provider", "targetConfigurationDigest",
            "effectiveProviderDigest", "operationToken", "modelDigest", "toolingDigest",
            "resourcesDigest",
        }
        or proof["schema"] != PREPARED_SCHEMA
        or proof["binding"] != {key: current[key] for key in PREPARED_BINDING}
        or proof["config"] != _prepared_config_records(run_fd)
    ):
        _fail("recovery")
    for field in (
        "targetConfigurationDigest", "effectiveProviderDigest", "modelDigest", "toolingDigest",
        "resourcesDigest",
    ):
        if not isinstance(proof[field], str) or re.fullmatch(
            r"[0-9a-f]{64}", proof[field]
        ) is None:
            _fail("recovery")
    if (
        not isinstance(proof["operationToken"], str)
        or re.fullmatch(r"[0-9a-f]{32}", proof["operationToken"]) is None
        or proof["toolingDigest"] != current["toolingDigest"]
        or proof["modelDigest"] != proof["targetConfigurationDigest"]
    ):
        _fail("recovery")
    _read_resource_baseline(run_fd, proof["resourcesDigest"])
    provider = proof["provider"]
    if (
        not isinstance(provider, dict)
        or set(provider) != {"providerEnabled", "durableDisposition", "transaction"}
        or type(provider["providerEnabled"]) is not bool
    ):
        _fail("recovery")
    transaction = provider["transaction"]
    if not provider["providerEnabled"]:
        if provider["durableDisposition"] != "none" or transaction is not None:
            _fail("recovery")
    else:
        if (
            provider["durableDisposition"] not in {"created", "reused"}
            or not isinstance(transaction, dict)
            or set(transaction) != {"parent", "directory", "entries"}
        ):
            _fail("recovery")
        _validate_finalization_directory_record(transaction["parent"])
        _validate_finalization_directory_record(transaction["directory"])
        names = ["identity.json", "snapshot"]
        if provider["durableDisposition"] == "created":
            names.append("publication")
        if (
            not isinstance(transaction["entries"], list)
            or len(transaction["entries"]) != len(names)
        ):
            _fail("recovery")
        for name, entry in zip(names, transaction["entries"]):
            if (
                not isinstance(entry, dict) or set(entry) != {"name", "identity"}
                or entry["name"] != name
            ):
                _fail("recovery")
            _validate_finalization_file_record(entry["identity"])
    return proof


def _configuration_digest(configuration: Any) -> str:
    return _finalization_digest(json.dumps(
        configuration, sort_keys=True, separators=(",", ":"), allow_nan=False,
    ).encode())


def _model_digest(configuration: Any) -> str:
    data = json.dumps(configuration, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    if len(data) > MAX_MODEL_BYTES:
        _fail("recovery")
    return _finalization_digest(data)


def _private_equal(actual: Any, expected: Any) -> None:
    # JSON equality also distinguishes booleans from integers, unlike Python ==.
    if json.dumps(actual, sort_keys=True, separators=(",", ":"), allow_nan=False) != \
            json.dumps(expected, sort_keys=True, separators=(",", ":"), allow_nan=False):
        _fail("recovery")


def _resource_bytes(value: Any, limit: int) -> bytes:
    _deadline_check()
    try:
        _depth(value)
        data = json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False,
        ).encode("utf-8")
    except (ValueError, TypeError, RecursionError):
        _fail("recovery")
    if len(data) > limit:
        _fail("recovery")
    return data


def _resource_list(value: Any) -> list[Any]:
    if not isinstance(value, list) or len(value) > MAX_RESOURCE_ENTRIES:
        _fail("recovery")
    return value


def _resource_id(value: Any) -> str:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        _fail("recovery")
    return value


def _resource_labels(value: Any) -> dict[str, str]:
    if not isinstance(value, dict) or len(value) > MAX_RESOURCE_ENTRIES or any(
        not isinstance(key, str) or not key or not isinstance(item, str)
        or len(key) > 4096 or len(item) > 4096 for key, item in value.items()
    ):
        _fail("recovery")
    return value


def _resource_ids(value: Any) -> list[str]:
    values = [_resource_id(item) for item in _resource_list(value)]
    if len(set(values)) != len(values):
        _fail("recovery")
    return sorted(values)


def _resource_hash(kind: str, name: str) -> str:
    # Compose v2.39.4 hashes typed compose-go v2.9.0 JSON in declaration order.
    # Network's empty typed IPAM is retained; volume's default driver is local.
    # CustomLabels (including the compose ownership labels) are not serialized.
    if kind == "network" and name == RESOURCE_NETWORK:
        data = b'{"name":"meet-production_default","ipam":{}}'
    elif kind == "volume" and name in RESOURCE_VOLUMES.values():
        data = ('{"name":"' + name + '","driver":"local"}').encode("utf-8")
    else:
        _fail("recovery")
    return hashlib.sha256(data).hexdigest()


def _resource_owner(labels: Any, kind: str, logical: str, name: str) -> dict[str, str]:
    labels = _resource_labels(labels)
    if labels.get("com.docker.compose.project") != RESOURCE_PROJECT or \
            labels.get("com.docker.compose." + kind) != logical:
        _fail("recovery")
    key = "com.docker.compose.config-hash"
    if key in labels:
        actual = labels[key]
        if (kind == "volume" or actual != "") and actual != _resource_hash(kind, name):
            _fail("recovery")
    return labels


def _resource_model(configuration: Any, token: str) -> dict[str, Any]:
    backend = _create_backend_model(configuration, token)
    if set(configuration["services"]) != {"backend", "postgres"} or \
            configuration.get("networks") != {"default": {"name": RESOURCE_NETWORK}} or \
            configuration.get("volumes") != {
                logical: {"name": name} for logical, name in RESOURCE_VOLUMES.items()
            } or backend.get("depends_on") not in (
                {"postgres": {"condition": "service_healthy", "required": True}},
                {"postgres": {"condition": "service_healthy"}},
            ):
        _fail("recovery")
    postgres = configuration["services"]["postgres"]
    required = {"image", "environment", "volumes", "healthcheck", "restart", "security_opt", "logging"}
    if not isinstance(postgres, dict) or not required <= postgres.keys() or \
            postgres.keys() - required - {"networks"}:
        _fail("recovery")
    if (
        postgres["image"] != POSTGRES_IMAGE or postgres["restart"] != "unless-stopped"
        or postgres["security_opt"] != ["no-new-privileges:true"]
        or postgres["logging"] != backend["logging"]
        or postgres.get("networks", {"default": None}) not in ({"default": None}, {"default": {}})
        or postgres["volumes"] not in (
            [{"type": "volume", "source": "postgres_data", "target": "/var/lib/postgresql/data"}],
            [{"type": "volume", "source": "postgres_data", "target": "/var/lib/postgresql/data",
              "volume": {}}],
        )
        or not isinstance(postgres["environment"], dict)
        or set(postgres["environment"]) != {"POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD"}
    ):
        _fail("recovery")
    for key, source in (("POSTGRES_DB", "DB_NAME"), ("POSTGRES_USER", "DB_USERNAME"),
                        ("POSTGRES_PASSWORD", "DB_PASSWORD")):
        value = postgres["environment"][key]
        if not isinstance(value, str) or not value or backend["environment"].get(source) != value:
            _fail("recovery")
    health = {
        "test": ["CMD-SHELL", 'pg_isready -U "$${POSTGRES_USER}" -d "$${POSTGRES_DB}"'],
        "interval": "10s", "timeout": "5s", "retries": 10, "start_period": "10s",
    }
    # Config renderers may escape literal dollars; Engine's Test is unescaped.
    unescaped_health = dict(
        health, test=["CMD-SHELL", 'pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"'],
    )

    def canonical(value: Any) -> str:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)

    accepted_healthchecks = (canonical(health), canonical(unescaped_health))
    if canonical(postgres["healthcheck"]) not in accepted_healthchecks:
        _fail("recovery")
    return postgres


def _resource_network(value: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    if not isinstance(value, dict):
        _fail("recovery")
    required = {
        "Name", "Id", "Created", "Scope", "Driver", "EnableIPv6", "IPAM",
        "Internal", "Attachable", "Ingress", "ConfigFrom", "ConfigOnly", "Containers",
        "Options", "Labels",
    }
    if not required <= value.keys() or value.keys() - required - {"EnableIPv4"}:
        _fail("recovery")
    _resource_id(value["Id"])
    labels = _resource_owner(value["Labels"], "network", "default", RESOURCE_NETWORK)
    for key, expected in {
        "Name": RESOURCE_NETWORK, "Scope": "local", "Driver": "bridge", "Options": {},
        "Internal": False, "Attachable": False, "Ingress": False, "ConfigOnly": False,
        "EnableIPv6": False, "ConfigFrom": {"Network": ""},
    }.items():
        _private_equal(value[key], expected)
    _private_equal(value.get("EnableIPv4", True), True)
    if not isinstance(value["Created"], str) or not value["Created"]:
        _fail("recovery")
    ipam = value["IPAM"]
    if not isinstance(ipam, dict) or set(ipam) != {"Driver", "Options", "Config"} or \
            ipam["Driver"] != "default" or ipam["Options"] not in (None, {}) or \
            not isinstance(ipam["Config"], list) or len(ipam["Config"]) != 1:
        _fail("recovery")
    allocation = ipam["Config"][0]
    if not isinstance(allocation, dict) or set(allocation) != {"Subnet", "Gateway"} or \
            any(not isinstance(item, str) for item in allocation.values()):
        _fail("recovery")
    try:
        subnet = ipaddress.IPv4Network(allocation["Subnet"], strict=True)
        gateway = ipaddress.IPv4Address(allocation["Gateway"])
    except (ValueError, TypeError):
        _fail("recovery")
    if gateway not in subnet or gateway in (subnet.network_address, subnet.broadcast_address):
        _fail("recovery")
    endpoints = value["Containers"]
    if not isinstance(endpoints, dict) or len(endpoints) > MAX_RESOURCE_ENTRIES:
        _fail("recovery")
    projection = {key: value[key] for key in required - {"Containers"}}
    # Presence and value of resource labels are preserved, including missing hash.
    projection["Labels"] = labels
    projection["EnableIPv4"] = value.get("EnableIPv4", True)
    return projection, endpoints


def _resource_volume(value: Any, logical: str) -> dict[str, Any]:
    required = {"Name", "CreatedAt", "Mountpoint", "Driver", "Scope", "Labels", "Options"}
    if not isinstance(value, dict) or set(value) != required:
        _fail("recovery")
    name = RESOURCE_VOLUMES[logical]
    _resource_owner(value["Labels"], "volume", logical, name)
    if value["Name"] != name or value["Scope"] != "local" or value["Driver"] != "local" or \
            value["Options"] not in (None, {}):
        _fail("recovery")
    path = value["Mountpoint"]
    if not isinstance(path, str) or not path.startswith("/") or "\x00" in path or \
            any(part in ("", ".", "..") for part in path.split("/")[1:]) or \
            not isinstance(value["CreatedAt"], str) or not value["CreatedAt"]:
        _fail("recovery")
    return dict(value)


def _resource_endpoint(
    value: Any, *, identity: str, service: str, network: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(value, dict) or value.keys() - {
        "IPAMConfig", "Links", "Aliases", "DriverOpts", "NetworkID", "EndpointID", "Gateway",
        "IPAddress", "IPPrefixLen", "IPv6Gateway", "GlobalIPv6Address", "GlobalIPv6PrefixLen",
        "MacAddress", "DNSNames", "GwPriority",
    } or value.get("NetworkID") != network["Id"]:
        _fail("recovery")
    for key in ("IPAMConfig", "Links", "DriverOpts"):
        if value.get(key) not in (None, {}, []):
            _fail("recovery")
    aliases = value.get("Aliases")
    if not isinstance(aliases, list) or any(not isinstance(item, str) for item in aliases) or \
            sorted(aliases) != sorted([RESOURCE_PROJECT + "-" + service + "-1", service]):
        _fail("recovery")
    dns_names = value.get("DNSNames")
    if dns_names is not None and (
        not isinstance(dns_names, list) or any(not isinstance(item, str) for item in dns_names)
        or len(dns_names) != len(set(dns_names))
        or not set(dns_names) <= {RESOURCE_PROJECT + "-" + service + "-1", service, identity[:12]}
    ):
        _fail("recovery")
    for key in ("IPv6Gateway", "GlobalIPv6Address"):
        if value.get(key, "") != "":
            _fail("recovery")
    for key in ("GlobalIPv6PrefixLen", "GwPriority"):
        _private_equal(value.get(key, 0), 0)
    active = value.get("EndpointID", "") != ""
    if active:
        _resource_id(value["EndpointID"])
        if not isinstance(value.get("IPAddress"), str):
            _fail("recovery")
        allocation = network["IPAM"]["Config"][0]
        try:
            address = ipaddress.IPv4Address(value.get("IPAddress"))
            subnet = ipaddress.IPv4Network(allocation["Subnet"])
        except (ValueError, TypeError):
            _fail("recovery")
        if address not in subnet or address in (
            subnet.network_address, subnet.broadcast_address,
            ipaddress.IPv4Address(allocation["Gateway"]),
        ) or value.get("Gateway") != allocation["Gateway"] or \
                type(value.get("IPPrefixLen")) is not int or value["IPPrefixLen"] != subnet.prefixlen or \
                not isinstance(value.get("MacAddress"), str) or \
                re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", value["MacAddress"]) is None:
            _fail("recovery")
    else:
        for key in ("Gateway", "IPAddress", "MacAddress"):
            if value.get(key, "") != "":
                _fail("recovery")
        _private_equal(value.get("IPPrefixLen", 0), 0)
    # Keep semantic defaults explicit so harmless Engine omission does not hide allocation drift.
    return {
        "NetworkID": network["Id"], "EndpointID": value.get("EndpointID", ""),
        "Gateway": value.get("Gateway", ""), "IPAddress": value.get("IPAddress", ""),
        "IPPrefixLen": value.get("IPPrefixLen", 0), "MacAddress": value.get("MacAddress", ""),
        "Aliases": sorted(aliases), "DNSNames": sorted(dns_names) if dns_names is not None else None,
    }


def _resource_postgres(
    observed: dict[str, Any], image: Any, model: dict[str, Any], endpoint: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(image, dict) or image.get("Id") != observed.get("Image") or \
            not isinstance(image.get("Config"), dict):
        _fail("recovery")
    if not isinstance(image.get("Id"), str) or re.fullmatch(r"sha256:[0-9a-f]{64}", image["Id"]) is None:
        _fail("recovery")
    digests = _resource_list(image.get("RepoDigests"))
    digest = POSTGRES_IMAGE.split("@", 1)[1]
    if not any(item in digests for item in (
        "postgres@" + digest, "docker.io/library/postgres@" + digest,
    )):
        _fail("recovery")
    config, host, runtime = observed.get("Config"), observed.get("HostConfig"), observed.get("State")
    if not all(isinstance(value, dict) for value in (config, host, runtime)):
        _fail("recovery")
    expected_env = dict(_env_entries(image))
    expected_env.update(model["environment"])
    _private_equal(dict(_env_entries(observed)), expected_env)
    image_config = image["Config"]
    overrides = {
        "Image": POSTGRES_IMAGE, "Env": config["Env"], "Labels": config["Labels"],
        "Hostname": observed["Id"][:12],
        "Healthcheck": {"Test": ["CMD-SHELL", 'pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"'],
                        "Interval": 10000000000,
                        "Timeout": 5000000000, "Retries": 10, "StartPeriod": 10000000000},
    }
    defaults = {
        "Domainname": "", "AttachStdin": False, "AttachStdout": True, "AttachStderr": True,
        "Tty": False, "OpenStdin": False, "StdinOnce": False, "NetworkDisabled": False,
        "MacAddress": "", "StopTimeout": 10,
    }
    for key in config:
        if key in overrides:
            _private_equal(config[key], overrides[key])
        elif key in image_config:
            _private_equal(config[key], image_config[key])
        elif key in defaults:
            _private_equal(config[key], defaults[key])
        else:
            _fail("recovery")
    for key in image_config.keys() - {"Env", "Labels", "Healthcheck", "Hostname", "Image"}:
        _private_equal(config.get(key), image_config[key])
    for key, value in overrides.items():
        _private_equal(config.get(key), value)
    labels = config["Labels"]
    for key, value in (image_config.get("Labels") or {}).items():
        _private_equal(labels.get(key), value)
    for key, value in {
        "com.docker.compose.version": "2.39.4", "com.docker.compose.image": image["Id"],
    }.items():
        _private_equal(labels.get(key), value)
    compose_metadata = {
        "com.docker.compose.project", "com.docker.compose.service",
        "com.docker.compose.container-number", "com.docker.compose.oneoff",
        "com.docker.compose.version", "com.docker.compose.image", "com.docker.compose.config-hash",
        "com.docker.compose.depends_on", "com.docker.compose.project.config_files",
        "com.docker.compose.project.working_dir", "com.docker.compose.project.environment_file",
    }
    if labels.keys() - compose_metadata - (image_config.get("Labels") or {}).keys():
        _fail("recovery")
    if "org.meet.timepad.operation" in labels or \
            re.fullmatch(r"[0-9a-f]{64}", labels.get("com.docker.compose.config-hash", "")) is None:
        _fail("recovery")
    expected_host = {
        "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0},
        "SecurityOpt": ["no-new-privileges:true"], "NetworkMode": RESOURCE_NETWORK,
        "LogConfig": {"Type": "local", "Config": model["logging"]["options"]},
        "Binds": ["meet-production_postgres_data:/var/lib/postgresql/data:rw"],
    }
    host_defaults = {
        "ReadonlyRootfs": False, "Init": None, "Memory": 0, "Privileged": False,
        "PublishAllPorts": False, "AutoRemove": False, "CapAdd": None, "CapDrop": None,
        "Devices": None, "DeviceCgroupRules": None, "DeviceRequests": None, "VolumesFrom": None,
        "Links": None, "ExtraHosts": None, "GroupAdd": None, "Sysctls": None, "Tmpfs": None,
        "Ulimits": None, "StorageOpt": None, "CgroupParent": "", "Cgroup": "",
        "ContainerIDFile": "", "PidMode": "", "UTSMode": "", "UsernsMode": "",
        "IpcMode": "private", "CgroupnsMode": "private", "Isolation": "",
        "CpuShares": 0, "NanoCpus": 0, "CpuPeriod": 0, "CpuQuota": 0,
        "CpuRealtimePeriod": 0, "CpuRealtimeRuntime": 0, "CpusetCpus": "", "CpusetMems": "",
        "MemoryReservation": 0, "MemorySwap": 0, "MemorySwappiness": None,
        "OomKillDisable": None, "OomScoreAdj": 0, "PidsLimit": None,
        "BlkioWeight": 0, "BlkioWeightDevice": None, "BlkioDeviceReadBps": None,
        "BlkioDeviceWriteBps": None, "BlkioDeviceReadIOps": None, "BlkioDeviceWriteIOps": None,
        "Dns": [], "DnsOptions": [], "DnsSearch": [], "ShmSize": 67108864, "Runtime": "runc",
        "ConsoleSize": [0, 0], "VolumeDriver": "", "Mounts": [], "PortBindings": {},
        "MaskedPaths": [
            "/proc/asound", "/proc/acpi", "/proc/interrupts", "/proc/kcore", "/proc/keys",
            "/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug",
            "/proc/scsi", "/sys/firmware", "/sys/devices/virtual/powercap",
        ],
        "ReadonlyPaths": ["/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger"],
    }
    if host.keys() - expected_host.keys() - host_defaults.keys():
        _fail("recovery")
    if not {"Privileged", "CapAdd", "Devices", "DeviceRequests", "PidMode", "UsernsMode"} <= host.keys():
        _fail("recovery")
    for key, value in expected_host.items():
        _private_equal(host.get(key), value)
    for key, value in host_defaults.items():
        if key in host:
            _private_equal(host[key], value)
    for key, value in {
        "Status": "running", "Running": True, "Paused": False, "Restarting": False,
        "Dead": False, "OOMKilled": False, "Error": "",
    }.items():
        _private_equal(runtime.get(key), value)
    if not isinstance(runtime.get("Health"), dict) or runtime["Health"].get("Status") != "healthy" or \
            type(runtime.get("Pid")) is not int or runtime["Pid"] <= 0 or \
            not isinstance(runtime.get("StartedAt"), str) or not runtime["StartedAt"] or \
            runtime["StartedAt"] == "0001-01-01T00:00:00Z" or \
            type(observed.get("RestartCount")) is not int or observed["RestartCount"] < 0 or \
            not endpoint["EndpointID"]:
        _fail("recovery")
    return {
        "containerId": observed["Id"], "imageId": image["Id"],
        "configurationDigest": _configuration_digest({"Config": config, "HostConfig": host}),
        "startedAt": runtime["StartedAt"], "pid": runtime["Pid"],
        "restartCount": observed["RestartCount"], "endpoint": endpoint,
    }


def _resource_observation(observed: Any, role: dict[str, Any], stage: str) -> dict[str, Any]:
    fields = {
        "targetConfiguration", "postgresImageInspection", "projectInventory", "daemonInventory",
        "composeInventory", "backendInventory", "containerInspections", "networkInventory",
        "networkInspections", "volumeInventory", "volumeInspections",
    }
    if not isinstance(observed, dict) or set(observed) != fields:
        _fail("recovery")
    _resource_bytes(observed, MAX_INSPECTION_BYTES)
    model = _resource_model(observed["targetConfiguration"], role["operationToken"])
    containers: dict[str, Any] = {}
    for container in _resource_list(observed["containerInspections"]):
        _deadline_check()
        if not isinstance(container, dict):
            _fail("recovery")
        identity = _resource_id(container.get("Id"))
        if identity in containers:
            _fail("recovery")
        containers[identity] = container
    daemon: dict[str, Any] = {}
    members: dict[str, Any] = {}
    for entry in _resource_list(observed["daemonInventory"]):
        if not isinstance(entry, dict) or set(entry) != {"Id", "Names", "Labels"}:
            _fail("recovery")
        identity = _resource_id(entry["Id"])
        labels = _resource_labels(entry["Labels"])
        name = entry["Names"]
        if identity in daemon or identity not in containers or not isinstance(name, str) or \
                re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", name) is None:
            _fail("recovery")
        container = containers[identity]
        if container.get("Name") != "/" + name or not isinstance(container.get("Config"), dict):
            _fail("recovery")
        actual_labels = container["Config"].get("Labels")
        if actual_labels is None:
            actual_labels = {}
        _private_equal(_resource_labels(actual_labels), labels)
        daemon[identity] = entry
        project = labels.get("com.docker.compose.project") == RESOURCE_PROJECT
        reserved = name.startswith((RESOURCE_PROJECT + "-", RESOURCE_PROJECT + "_"))
        if not project:
            if reserved:
                _fail("recovery")
            continue
        service = labels.get("com.docker.compose.service")
        if service not in {"backend", "postgres"} or service in members or \
                name != RESOURCE_PROJECT + "-" + service + "-1" or \
                labels.get("com.docker.compose.container-number") != "1" or \
                labels.get("com.docker.compose.oneoff") != "False":
            _fail("recovery")
        members[service] = container
    if set(daemon) != set(containers) or len({item["Names"] for item in daemon.values()}) != len(daemon):
        _fail("recovery")
    project_ids = sorted(item["Id"] for item in members.values())
    if _resource_ids(observed["projectInventory"]) != project_ids or \
            _resource_ids(observed["composeInventory"]) != project_ids or "postgres" not in members:
        _fail("recovery")
    backend = members.get("backend")
    backend_id = backend["Id"] if backend is not None else None
    if _resource_ids(observed["backendInventory"]) != ([] if backend_id is None else [backend_id]):
        _fail("recovery")
    if stage in {"post-create", "completion"}:
        if backend is None or backend_id in {
            role["backendContainerId"], role["priorBackendContainerId"],
        } or backend["Config"]["Labels"].get("org.meet.timepad.operation") != role["operationToken"]:
            _fail("recovery")
        runtime = backend.get("State")
        if not isinstance(runtime, dict):
            _fail("recovery")
        for key, value in {
            "Status": "created", "Running": False, "Paused": False, "Restarting": False,
            "Dead": False, "OOMKilled": False, "Pid": 0, "ExitCode": 0, "Error": "",
            "StartedAt": "0001-01-01T00:00:00Z", "FinishedAt": "0001-01-01T00:00:00Z",
        }.items():
            _private_equal(runtime.get(key), value)
        _private_equal(backend.get("RestartCount"), 0)
    elif backend_id != role["backendContainerId"] and not (
        backend_id is None and role["allowEmptyBackend"]
    ):
        _fail("recovery")
    if backend is not None and role["priorBackendContainerId"] is not None and \
            backend["Config"]["Labels"].get("org.meet.timepad.operation") != role["operationToken"]:
        _fail("recovery")
    if stage == "pre-release" and backend is not None:
        state, host = backend.get("State"), backend.get("HostConfig")
        if not isinstance(state, dict) or not isinstance(host, dict) or \
                state.get("Running") is not False or host.get("RestartPolicy") != {
                    "Name": "no", "MaximumRetryCount": 0,
                }:
            _fail("recovery")
        for key, value in {"Paused": False, "Restarting": False, "Dead": False, "Pid": 0}.items():
            _private_equal(state.get(key), value)
    network_entries = {}
    for entry in _resource_list(observed["networkInventory"]):
        if not isinstance(entry, dict) or set(entry) != {"ID", "Name", "Labels"}:
            _fail("recovery")
        identity = _resource_id(entry["ID"])
        labels = _resource_labels(entry["Labels"])
        name = entry["Name"]
        if identity in network_entries or not isinstance(name, str) or not name:
            _fail("recovery")
        network_entries[identity] = entry
        if labels.get("com.docker.compose.project") == RESOURCE_PROJECT and name != RESOURCE_NETWORK:
            _fail("recovery")
    networks = _resource_list(observed["networkInspections"])
    matching = [item for item in network_entries.values() if item["Name"] == RESOURCE_NETWORK]
    if len(networks) != 1 or len(matching) != 1:
        _fail("recovery")
    network, active_endpoints = _resource_network(networks[0])
    if network["Id"] != matching[0]["ID"]:
        _fail("recovery")
    _private_equal(network["Labels"], matching[0]["Labels"])
    volume_entries = {}
    for entry in _resource_list(observed["volumeInventory"]):
        if not isinstance(entry, dict) or set(entry) != {"Name", "Driver", "Labels"}:
            _fail("recovery")
        name, labels = entry["Name"], _resource_labels(entry["Labels"])
        if not isinstance(name, str) or not name or name in volume_entries:
            _fail("recovery")
        volume_entries[name] = entry
        if labels.get("com.docker.compose.project") == RESOURCE_PROJECT and name not in RESOURCE_VOLUMES.values():
            _fail("recovery")
    volumes = {}
    for value in _resource_list(observed["volumeInspections"]):
        if not isinstance(value, dict):
            _fail("recovery")
        logical = next((key for key, name in RESOURCE_VOLUMES.items() if name == value.get("Name")), None)
        if logical is None or logical in volumes:
            _fail("recovery")
        volume = _resource_volume(value, logical)
        if volume["Name"] not in volume_entries:
            _fail("recovery")
        _private_equal(volume_entries[volume["Name"]], {
            "Name": volume["Name"], "Driver": volume["Driver"], "Labels": volume["Labels"],
        })
        volumes[logical] = volume
    if set(volumes) != set(RESOURCE_VOLUMES) or \
            len({value["Mountpoint"] for value in volumes.values()}) != 2:
        _fail("recovery")
    consumers: dict[str, list[str]] = {key: [] for key in RESOURCE_VOLUMES}
    endpoints = {}
    for identity, container in containers.items():
        _deadline_check()
        mounts = _resource_list(container.get("Mounts"))
        service = next((key for key, member in members.items() if member["Id"] == identity), None)
        if service == "postgres" and len(mounts) != 1:
            _fail("recovery")
        destinations = set()
        for mount in mounts:
            if not isinstance(mount, dict) or not isinstance(mount.get("Destination"), str) or \
                    mount["Destination"] in destinations:
                _fail("recovery")
            destinations.add(mount["Destination"])
            if service == "backend" and mount["Destination"] != "/data/uploads":
                if mount["Destination"] == "/tmp" and mount.get("Type") == "tmpfs":
                    pass
                elif mount["Destination"] == CONTAINER_CREDENTIAL_PATH and \
                        mount.get("Type") == "bind" and mount.get("Source") == HOST_CREDENTIAL_PATH and \
                        mount.get("RW") is False:
                    pass
                else:
                    _fail("recovery")
            for logical, volume in volumes.items():
                source = mount.get("Source")
                if mount.get("Name") == volume["Name"] or (
                    isinstance(source, str) and (
                        source == volume["Mountpoint"] or source.startswith(volume["Mountpoint"] + "/")
                    )
                ):
                    service = "backend" if logical == "uploads_data" else "postgres"
                    if members.get(service, {}).get("Id") != identity or \
                            mount.get("Type") != "volume" or mount.get("Name") != volume["Name"] or \
                            mount.get("Source") != volume["Mountpoint"] or mount.get("Driver") != "local" or \
                            mount.get("Destination") != (
                                "/data/uploads" if logical == "uploads_data" else "/var/lib/postgresql/data"
                            ) or mount.get("RW") is not True or mount.get("Propagation", "") != "" or \
                            mount.get("Mode", "rw") not in ("", "rw"):
                        _fail("recovery")
                    consumers[logical].append(identity)
        settings = container.get("NetworkSettings")
        attached = settings.get("Networks") if isinstance(settings, dict) else None
        if not isinstance(attached, dict) or len(attached) > MAX_RESOURCE_ENTRIES:
            _fail("recovery")
        if any(
            not isinstance(name, str) or not name or not isinstance(value, dict)
            for name, value in attached.items()
        ):
            _fail("recovery")
        relevant = [name for name, value in attached.items() if name == RESOURCE_NETWORK or (
            isinstance(value, dict) and value.get("NetworkID") == network["Id"]
        )]
        if relevant:
            service = next((key for key, member in members.items() if member["Id"] == identity), None)
            if service is None or set(attached) != {RESOURCE_NETWORK}:
                _fail("recovery")
            endpoints[identity] = _resource_endpoint(
                attached[RESOURCE_NETWORK], identity=identity, service=service, network=network,
            )
        elif identity in project_ids:
            _fail("recovery")
    if sorted(consumers["postgres_data"]) != [members["postgres"]["Id"]] or \
            sorted(consumers["uploads_data"]) != ([] if backend_id is None else [backend_id]):
        _fail("recovery")
    expected_active = {}
    for identity, endpoint in endpoints.items():
        if endpoint["EndpointID"]:
            expected_active[identity] = {
                "Name": containers[identity]["Name"][1:], "EndpointID": endpoint["EndpointID"],
                "MacAddress": endpoint["MacAddress"],
                "IPv4Address": endpoint["IPAddress"] + "/" + str(endpoint["IPPrefixLen"]),
                "IPv6Address": "",
            }
    _private_equal(active_endpoints, expected_active)
    if stage in {"pre-release", "post-create", "completion"} and backend_id is not None and \
            endpoints[backend_id]["EndpointID"]:
        _fail("recovery")
    postgres = _resource_postgres(
        members["postgres"], observed["postgresImageInspection"], model, endpoints[members["postgres"]["Id"]],
    )
    membership = {
        "backendContainerId": backend_id, "projectInventory": project_ids,
        "volumeConsumers": {key: sorted(value) for key, value in consumers.items()},
        "endpoints": endpoints,
    }
    _resource_bytes(membership, MAX_RESOURCE_REQUEST_BYTES)
    result = {
        "schema": RESOURCE_BASELINE_SCHEMA,
        "modelDigest": _model_digest(observed["targetConfiguration"]),
        "postgres": postgres, "network": network, "volumes": volumes, "membership": membership,
    }
    _resource_bytes(result, MAX_RESOURCES_BYTES)
    return result


def _resource_admission(value: Any) -> dict[str, Any]:
    """Pure bounded comparison; supplied role/baseline carry no independent authority."""
    _resource_bytes(value, MAX_INSPECTION_BYTES)
    fields = {
        "schema", "baseline", "observed", "stage", "role", "requestBaseline", "expectedMembershipDigest",
    }
    if not isinstance(value, dict) or set(value) != fields or \
            value["schema"] != RESOURCE_ADMISSION_SCHEMA or \
            value["stage"] not in {
                "prepared", "pre-release", "post-create", "completion", "recovery",
            }:
        _fail("recovery")
    role = value["role"]
    if not isinstance(role, dict) or set(role) != {
        "operationToken", "backendContainerId", "priorBackendContainerId", "allowEmptyBackend",
    } or not isinstance(role["operationToken"], str) or \
            re.fullmatch(r"[a-f0-9]{32}", role["operationToken"]) is None or \
            type(role["allowEmptyBackend"]) is not bool:
        _fail("recovery")
    for key in ("backendContainerId", "priorBackendContainerId"):
        if role[key] is not None:
            _resource_id(role[key])
    if role["backendContainerId"] is None and not role["allowEmptyBackend"]:
        _fail("recovery")
    current = _resource_observation(value["observed"], role, value["stage"])
    baseline = value["baseline"]
    if value["stage"] == "prepared":
        if baseline is not None or value["requestBaseline"] is not None or \
                value["expectedMembershipDigest"] is not None or role["allowEmptyBackend"]:
            _fail("recovery")
        baseline = current
    else:
        if not isinstance(baseline, dict) or set(baseline) != set(current):
            _fail("recovery")
        _resource_bytes(baseline, MAX_RESOURCES_BYTES)
        _private_equal(
            {key: item for key, item in baseline.items() if key != "membership"},
            {key: item for key, item in current.items() if key != "membership"},
        )
    membership = current["membership"]
    expected = value["expectedMembershipDigest"]
    membership_digest = _configuration_digest(membership)
    if expected is not None and (
        not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None
        or expected != membership_digest
    ):
        _fail("recovery")
    if value["stage"] in {"post-create", "completion"} or \
            value["stage"] == "recovery" and value["requestBaseline"] is not None:
        previous = value["requestBaseline"]
        if not isinstance(previous, dict) or set(previous) != set(membership) or \
                previous["backendContainerId"] not in (
                    None, role["priorBackendContainerId"] if value["stage"] == "recovery"
                    else role["backendContainerId"],
                ):
            _fail("recovery")
        _resource_bytes(previous, MAX_RESOURCE_REQUEST_BYTES)
        old, new = previous["backendContainerId"], membership["backendContainerId"]
        if value["stage"] == "recovery" and (
            role["allowEmptyBackend"] or old is None or new != role["backendContainerId"]
        ):
            _fail("recovery")
        expected_previous = {
            "backendContainerId": old,
            "projectInventory": sorted([current["postgres"]["containerId"]] + ([] if old is None else [old])),
            "volumeConsumers": {
                "postgres_data": [current["postgres"]["containerId"]],
                "uploads_data": [] if old is None else [old],
            },
            "endpoints": dict(membership["endpoints"]),
        }
        del expected_previous["endpoints"][new]
        if old is not None:
            old_endpoints = previous.get("endpoints")
            if not isinstance(old_endpoints, dict) or old not in old_endpoints:
                _fail("recovery")
            old_endpoint = old_endpoints[old]
            if not isinstance(old_endpoint, dict) or old_endpoint.get("EndpointID") != "" or \
                    old_endpoint.get("IPAddress") != "":
                _fail("recovery")
            _private_equal(old_endpoint, _resource_endpoint(
                old_endpoint, identity=old, service="backend", network=current["network"],
            ))
            expected_previous["endpoints"][old] = old_endpoint
        elif not role["allowEmptyBackend"]:
            _fail("recovery")
        _private_equal(previous, expected_previous)
    elif value["stage"] == "recovery":
        if role["allowEmptyBackend"] or baseline["membership"]["backendContainerId"] is None or \
                baseline["membership"]["backendContainerId"] != role["backendContainerId"]:
            _fail("recovery")
        _private_equal(membership, baseline["membership"])
    elif value["requestBaseline"] is not None:
        _fail("recovery")
    _deadline_check()
    return {
        "baseline": baseline, "baselineDigest": _configuration_digest(baseline),
        "membership": membership, "membershipDigest": membership_digest,
    }


def _read_resource_baseline(run_fd: int, digest: str) -> dict[str, Any]:
    for temporary in (".timepad-resources.tmp", ".timepad-resource-request.tmp"):
        try:
            os.stat(temporary, dir_fd=run_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail("recovery")
    _, data = _read_child_file(run_fd, "timepad-resources.json", MAX_RESOURCES_BYTES)
    value = _json(data, "recovery")
    if not isinstance(value, dict) or value.get("schema") != RESOURCE_BASELINE_SCHEMA or \
            _finalization_digest(data) != digest or data != _resource_bytes(value, MAX_RESOURCES_BYTES):
        _fail("recovery")
    return value


def _read_resource_request(run_fd: int, digest: str) -> dict[str, Any]:
    _, data = _read_child_file(run_fd, "timepad-resource-request.json", MAX_RESOURCE_REQUEST_BYTES)
    value = _json(data, "recovery")
    if not isinstance(value, dict) or _finalization_digest(data) != digest or \
            data != _resource_bytes(value, MAX_RESOURCE_REQUEST_BYTES):
        _fail("recovery")
    return value


def _resource_envelope(
    *, stage: str, role: dict[str, Any], observed: Any, baseline: Any = None,
    request_baseline: Any = None, expected_membership_digest: Any = None,
) -> dict[str, Any]:
    return {
        "schema": RESOURCE_ADMISSION_SCHEMA, "stage": stage, "role": role,
        "baseline": baseline, "observed": observed, "requestBaseline": request_baseline,
        "expectedMembershipDigest": expected_membership_digest,
    }


def _resource_role(
    current: dict[str, Any], proof: dict[str, Any], *, allow_empty: bool = False,
) -> dict[str, Any]:
    request = current.get("runtimeRequest")
    replacement = current.get("commitSubstep", "").startswith("replacement-") \
        if isinstance(current.get("commitSubstep"), str) else False
    if isinstance(request, dict) and request.get("operation") == "create":
        replacement = request["role"] == "replacement"
        backend_id = request["priorContainerId"] if replacement else current["predecessorContainerId"]
    else:
        backend_id = current.get("containerId") if replacement else current["predecessorContainerId"]
    return {
        "operationToken": proof["operationToken"], "backendContainerId": backend_id,
        "priorBackendContainerId": current["predecessorContainerId"] if replacement else None,
        "allowEmptyBackend": allow_empty,
    }


def _resource_recovery_role(
    current: dict[str, Any], proof: dict[str, Any], *,
    request_baseline: dict[str, Any] | None = None,
) -> dict[str, Any]:
    request = current.get("runtimeRequest")
    if current.get("phase") not in {
        "CUTOVER_POSSIBLE", "VERIFYING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
        "COMMITTING", "COMMITTED",
    } or current.get("containerId") is None:
        _fail("recovery")
    if isinstance(request, dict) and request.get("operation") == "create":
        if (
            request.get("lifecycle") != "bound"
            or request.get("containerId") != current["containerId"]
            or request.get("operationToken") != proof["operationToken"]
            or request.get("preparedProofDigest") != current.get("preparedProofDigest")
            or request.get("resourcesDigest") != proof["resourcesDigest"]
            or request.get("role") not in {"initial", "replacement"}
        ):
            _fail("recovery")
        request_prior_id = request.get("priorContainerId")
        if request["role"] == "replacement" and \
                request_prior_id != current.get("predecessorContainerId"):
            _fail("recovery")
        if request["role"] == "initial" and request_prior_id is not None:
            _fail("recovery")
        prior_id = request_prior_id or current.get("predecessorContainerId")
    elif (
        request_baseline is None
        or not isinstance(request, dict)
        or request.get("operation") not in {"suppress", "stop"}
        or request.get("lifecycle") != "completed"
        or request.get("containerId") != current["containerId"]
        or request.get("configHash") != current.get("configHash")
        or request_baseline.get("backendContainerId") != current.get("predecessorContainerId")
    ):
        _fail("recovery")
    else:
        prior_id = request_baseline["backendContainerId"]
    return {
        "operationToken": proof["operationToken"],
        "backendContainerId": current["containerId"],
        "priorBackendContainerId": prior_id,
        "allowEmptyBackend": False,
    }


def _retained_create_completion(
    run_fd: int, current: dict[str, Any], proof: dict[str, Any],
    module: Any, state_root: str,
) -> dict[str, Any]:
    """Authenticate the acknowledged create after a later runtime request replaced it."""
    request = current.get("runtimeRequest")
    try:
        request = module.runtime_request(request)
        module.require_runtime_request_completion(current)
    except (module.GuardError, TypeError, KeyError):
        _fail("recovery")
    if (
        request["operation"] not in {"suppress", "stop"}
        or request["containerId"] != current.get("containerId")
        or request["configHash"] != current.get("configHash")
        or request["imageId"] != current["target"]["tuple"]["platformImageId"]
        or current.get("ownedChild") is not None
        or current.get("phase") == "PREPARED"
    ):
        _fail("recovery")
    lease = module._read_execution_lease_locked(state_root)
    if lease is None or lease["createCompletion"] is None:
        _fail("recovery")
    try:
        completion = module._create_completion_evidence(lease["createCompletion"])
    except (module.GuardError, TypeError, KeyError):
        _fail("recovery")
    if (
        completion["acknowledged"] is not True
        or completion["resourcesDigest"] != proof["resourcesDigest"]
        or lease["operation"] not in {"deploy", "forward-recover"}
        or lease["attempt"] != current["executionAttempt"]
        or completion["executionAttempt"] != lease["attempt"]
    ):
        _fail("recovery")
    receipt_name = (
        "timepad-replacement-completion.json"
        if isinstance(current.get("commitSubstep"), str)
        and current["commitSubstep"].startswith("replacement-")
        else "timepad-create-completion.json"
    )
    receipt = _read_child_file(
        run_fd, receipt_name, module.MAX_CREATE_COMPLETION_BYTES,
    )[1]
    value = _json(receipt, "recovery")
    expected = {
        "schema": module.CREATE_COMPLETION_SCHEMA,
        **{key: completion[key] for key in (
            "requestDigest", "executionAttempt", "childIdentity", "resourcesDigest",
            "resourceRequestDigest", "waitStatus", "uncancelled", "descendantsDrained",
        )},
    }
    if (
        value != expected
        or receipt != module._canonical(expected)
        or hashlib.sha256(receipt).hexdigest() != completion["receiptDigest"]
    ):
        _fail("recovery")
    request_baseline = _read_resource_request(
        run_fd, completion["resourceRequestDigest"],
    )
    if request_baseline["backendContainerId"] != current.get("predecessorContainerId"):
        _fail("recovery")
    return request_baseline


def _recovery_candidate_runtime(
    value: dict[str, Any], current: dict[str, Any], request: dict[str, Any],
) -> None:
    observed = value.get("observed")
    containers = observed.get("containerInspections") if isinstance(observed, dict) else None
    if not isinstance(containers, list):
        _fail("recovery")
    candidates = [
        row for row in containers
        if isinstance(row, dict) and row.get("Id") == current.get("containerId")
    ]
    if len(candidates) != 1:
        _fail("recovery")
    exact_target, _ = _live_resume_runtime(candidates[0], current, "runtime")
    runtime = candidates[0].get("State")
    host = candidates[0].get("HostConfig")
    if (
        not exact_target
        or candidates[0].get("Id") != request.get("containerId")
        or candidates[0].get("Config", {}).get("Labels", {}).get(
            "com.docker.compose.config-hash"
        ) != request.get("configHash")
        or not isinstance(runtime, dict)
        or not isinstance(host, dict)
        or request["operation"] == "stop" and runtime.get("Running") is not False
        or host.get("RestartPolicy", {}).get("Name") != "no"
    ):
        _fail("recovery")


def _resource_admission_command(
    run_key: str, state_root: str, state_kind: str, data: bytes, deploy_lock_fd: int,
) -> None:
    value = _json(data, "recovery")
    if not isinstance(value, dict) or value.get("stage") == "prepared":
        # Initial authority is established only by prepare-transition-proof.
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        module, _, current = _timepad_current(state_root, deploy_lock_fd)
        if state_kind not in STATE_KINDS or current["runId"] != run_key or \
                current["ownedRun"] != f"{run_key}-{state_kind}":
            _fail("recovery")
        run_fd = os.open(current["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, current["ownedRun"])
            proof = _prepared_proof(run_fd, current)
            baseline = _read_resource_baseline(run_fd, proof["resourcesDigest"])
            # An absence-recovery authorization must be supplied by the existing
            # private recovery path, not by this public JSON adapter.
            if value.get("stage") == "recovery" and \
                    current["phase"] == "PREPARED" and current.get("runtimeRequest") is None:
                role = _resource_role(current, proof)
                if role["backendContainerId"] is None:
                    _fail("recovery")
            elif value.get("stage") == "recovery":
                request = current.get("runtimeRequest")
                if isinstance(request, dict) and request.get("operation") in {"suppress", "stop"}:
                    saved_request = _retained_create_completion(
                        run_fd, current, proof, module, state_root,
                    )
                    _private_equal(value.get("requestBaseline"), saved_request)
                    _recovery_candidate_runtime(value, current, request)
                    role = _resource_recovery_role(
                        current, proof, request_baseline=saved_request,
                    )
                else:
                    role = _resource_recovery_role(current, proof)
            else:
                role = _resource_role(current, proof)
            _private_equal(value.get("role"), role)
            _private_equal(value.get("baseline"), baseline)
            if value.get("stage") in {"post-create", "completion"}:
                try:
                    request = module.require_create_normal_completion(current)
                except module.GuardError:
                    _fail("recovery")
                if request["resourcesDigest"] != proof["resourcesDigest"]:
                    _fail("recovery")
                _private_equal(value.get("requestBaseline"), _read_resource_request(
                    run_fd, request["resourceRequestDigest"],
                ))
            elif value.get("stage") == "recovery":
                request = current.get("runtimeRequest")
                if isinstance(request, dict) and request.get("operation") in {"suppress", "stop"}:
                    # _retained_create_completion authenticated this exact saved
                    # request against the durable completion receipt and lease.
                    pass
                elif isinstance(request, dict) and request.get("operation") == "create":
                    _private_equal(value.get("requestBaseline"), _read_resource_request(
                        run_fd, request["resourceRequestDigest"],
                    ))
                elif value.get("requestBaseline") is not None:
                    _fail("recovery")
            elif value.get("expectedMembershipDigest") is not None:
                _read_resource_request(run_fd, value["expectedMembershipDigest"])
            result = _resource_admission(value)
            _, _, final = _timepad_current(state_root, deploy_lock_fd)
            if final != current:
                _fail("recovery")
            _deadline_check()
            print(_resource_bytes(result, MAX_RESOURCES_BYTES + MAX_RESOURCE_REQUEST_BYTES + 1024).decode())
        finally:
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _create_backend_model(configuration: Any, token: str) -> dict[str, Any]:
    """Repository-specific effective model; this is not a general Compose translator."""
    _model_digest(configuration)
    if (
        not isinstance(configuration, dict)
        or set(configuration) - {"name", "services", "networks", "volumes", "x-bounded-logging"}
        or configuration.get("name") != "meet-production"
        or not isinstance(configuration.get("services"), dict)
        or set(configuration["services"]) - {"backend", "postgres"}
        or not isinstance(configuration["services"].get("backend"), dict)
    ):
        _fail("recovery")
    backend = configuration["services"]["backend"]
    allowed = {
        "image", "pull_policy", "build", "environment", "depends_on", "ports", "volumes",
        "user", "tmpfs", "read_only", "init", "cap_drop", "security_opt", "healthcheck",
        "stop_grace_period", "mem_limit", "restart", "logging", "networks", "labels",
    }
    required = {
        "image", "environment", "ports", "volumes", "user", "tmpfs", "read_only",
        "init", "cap_drop", "security_opt", "healthcheck", "mem_limit", "restart",
        "logging", "labels",
    }
    if not required <= backend.keys() or backend.keys() - allowed:
        _fail("recovery")
    if (
        backend["user"] != "10001:10001" or backend["read_only"] is not True
        or backend["init"] is not True or backend["cap_drop"] != ["ALL"]
        or backend["security_opt"] != ["no-new-privileges:true"]
        or backend["tmpfs"] != ["/tmp"] or backend["restart"] != "unless-stopped"
        or backend.get("pull_policy", "never") != "never"
        or backend.get("networks", {"default": None}) not in (
            {"default": None}, {"default": {}},
        )
        or not isinstance(backend["labels"], dict)
        or backend["labels"].get("org.meet.timepad.operation") != token
        or any(not isinstance(k, str) or not isinstance(v, str)
               for k, v in backend["labels"].items())
        or any(key.startswith("com.docker.compose.") for key in backend["labels"])
    ):
        _fail("recovery")
    dependency = backend.get("depends_on", {})
    if dependency not in ({}, {"postgres": {"condition": "service_healthy", "required": True}},
                          {"postgres": {"condition": "service_healthy"}}):
        _fail("recovery")
    for key, names in (
        ("networks", {"default": "meet-production_default"}),
        ("volumes", {"uploads_data": "meet-production_uploads_data",
                     "postgres_data": "meet-production_postgres_data"}),
    ):
        resources = configuration.get(key, {})
        if not isinstance(resources, dict) or resources.keys() - names.keys():
            _fail("recovery")
        for name, resource in resources.items():
            if resource != {"name": names[name]}:
                _fail("recovery")
    _create_model_controls(backend)
    return backend


def _create_model_controls(backend: dict[str, Any]) -> None:
    """Reject unsupported resource requests before Compose can create anything."""
    if not isinstance(backend["environment"], dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in backend["environment"].items()
    ):
        _fail("recovery")
    health = backend["healthcheck"]
    if not isinstance(health, dict) or health.keys() - {
        "test", "interval", "timeout", "retries", "start_period", "start_interval",
    }:
        _fail("recovery")
    for key, value in health.items():
        if key == "test":
            if not isinstance(value, list) or not value \
                    or any(not isinstance(item, str) for item in value) \
                    or value[0] not in {"CMD", "CMD-SHELL"}:
                _fail("recovery")
        elif key == "retries":
            if type(value) is not int or value < 1:
                _fail("recovery")
        else:
            _create_duration(value)
    if _create_duration(backend.get("stop_grace_period", "30s")) % 1000000000:
        _fail("recovery")
    if type(backend["mem_limit"]) is not int or backend["mem_limit"] <= 0:
        _fail("recovery")
    logging = backend["logging"]
    if not isinstance(logging, dict) or set(logging) != {"driver", "options"} or \
            logging["driver"] != "local" or not isinstance(logging["options"], dict) or \
            set(logging["options"]) != {"max-size", "max-file"} or any(
                not isinstance(value, str) or not value for value in logging["options"].values()
            ):
        _fail("recovery")
    ports = backend["ports"]
    if (
        not isinstance(ports, list) or len(ports) != 1 or not isinstance(ports[0], dict)
        or ports[0].keys() - {"mode", "host_ip", "target", "published", "protocol"}
        or ports[0].get("host_ip") != "127.0.0.1" or type(ports[0].get("target")) is not int
        or ports[0]["target"] != 8080 or ports[0].get("protocol", "tcp") != "tcp"
        or ports[0].get("mode", "ingress") != "ingress"
        or not isinstance(ports[0].get("published"), str)
        or re.fullmatch(r"[1-9][0-9]{0,4}", ports[0]["published"]) is None
        or int(ports[0]["published"]) > 65535
    ):
        _fail("recovery")
    mounts = backend["volumes"]
    if not isinstance(mounts, list) or len(mounts) not in {1, 2}:
        _fail("recovery")
    destinations = []
    for mount in mounts:
        if not isinstance(mount, dict) or mount not in (
            {"type": "volume", "source": "uploads_data", "target": "/data/uploads"},
            {"type": "volume", "source": "uploads_data", "target": "/data/uploads", "volume": {}},
            {"type": "bind", "source": HOST_CREDENTIAL_PATH, "target": CONTAINER_CREDENTIAL_PATH,
             "read_only": True, "bind": {"create_host_path": False}},
        ):
            _fail("recovery")
        if mount["type"] == "bind" and (
            mount["read_only"] is not True or mount["bind"]["create_host_path"] is not False
        ):
            _fail("recovery")
        destinations.append(mount["target"])
    if len(set(destinations)) != len(destinations) or "/data/uploads" not in destinations:
        _fail("recovery")


def _create_duration(value: Any) -> int:
    if not isinstance(value, str):
        _fail("recovery")
    match = re.fullmatch(r"([0-9]{1,9})(ns|us|ms|s|m|h)", value)
    if match is None:
        _fail("recovery")
    return int(match[1]) * {"ns": 1, "us": 1000, "ms": 1000000,
                           "s": 1000000000, "m": 60000000000, "h": 3600000000000}[match[2]]


def _create_runtime_configuration(
    image: dict[str, Any], configuration: Any, observed: dict[str, Any], token: str,
) -> None:
    """Compare the private projections used by runtime invariants before any start."""
    backend = _create_backend_model(configuration, token)
    config, host = observed.get("Config"), observed.get("HostConfig")
    image_config = image.get("Config")
    if not all(isinstance(value, dict) for value in (config, host, image_config)):
        _fail("recovery")
    environment = dict(_env_entries(image))
    environment.update(backend["environment"])
    _private_equal(dict(_env_entries(observed)), environment)
    for key in ("Entrypoint", "Cmd", "WorkingDir", "StopSignal"):
        _private_equal(config.get(key), image_config.get(key))
    _private_equal(config.get("Image"), backend["image"])
    _private_equal(config.get("User"), backend["user"])
    config_defaults = {
        "Domainname": "", "AttachStdin": False, "AttachStdout": True, "AttachStderr": True,
        "Tty": False, "OpenStdin": False, "StdinOnce": False, "OnBuild": None,
        "NetworkDisabled": False, "MacAddress": "",
    }
    config_fields = {
        "Image", "User", "Env", "Labels", "Entrypoint", "Cmd", "WorkingDir",
        "StopSignal", "StopTimeout", "Healthcheck", "Volumes", "ExposedPorts", "Hostname",
    }
    if config.keys() - config_fields - config_defaults.keys():
        _fail("recovery")
    for key, value in config_defaults.items():
        if key in config:
            _private_equal(config[key], value)
    if config.get("Hostname", observed["Id"][:12]) != observed["Id"][:12]:
        _fail("recovery")
    # Image-declared anonymous volumes would introduce unreviewed inheritance.
    if image_config.get("Volumes") not in (None, {}) or config.get("Volumes") not in (None, {}):
        _fail("recovery")
    labels = config.get("Labels")
    expected_labels = dict(image_config.get("Labels") or {})
    expected_labels.update(backend["labels"])
    compose_labels = {
        "com.docker.compose.project": "meet-production",
        "com.docker.compose.service": "backend",
        "com.docker.compose.container-number": "1",
        "com.docker.compose.oneoff": "False",
        "com.docker.compose.version": "2.39.4",
        "com.docker.compose.image": image["Id"],
    }
    if not isinstance(labels, dict):
        _fail("recovery")
    for key, value in {**expected_labels, **compose_labels}.items():
        if labels.get(key) != value and os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1":
            diagnostic_path = os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTIC_FILE", "")
            safe_labels = {
                "com.docker.compose.project", "com.docker.compose.service",
                "com.docker.compose.container-number", "com.docker.compose.oneoff",
                "com.docker.compose.version", "com.docker.compose.image",
                "org.opencontainers.image.revision", "org.opencontainers.image.version",
                "org.opencontainers.image.source",
                "com.docker.compose.config-hash", "com.docker.compose.depends_on",
                "com.docker.compose.project.config_files",
                "com.docker.compose.project.working_dir",
                "com.docker.compose.project.environment_file",
            }
            label_class = (
                "known" if key in safe_labels
                else "oci" if key.startswith("org.opencontainers.image.")
                else "compose" if key.startswith("com.docker.compose.")
                else "other"
            )
            record = (
                "label_mismatch key=" + key + "\n" if key in safe_labels
                else "label_mismatch class=" + label_class + "\n"
            ).encode("ascii")
            if record and re.fullmatch(
                r"/var/lib/timepad-fixture/case-create-worker-[A-Za-z0-9_-]+/driver-diagnostics",
                diagnostic_path,
            ):
                try:
                    fd = os.open(
                        diagnostic_path,
                        os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_CLOEXEC,
                    )
                    try:
                        metadata = os.fstat(fd)
                        if stat.S_ISREG(metadata.st_mode) and metadata.st_size <= 4096 - len(record):
                            os.write(fd, record)
                    finally:
                        os.close(fd)
                except OSError:
                    pass
        _private_equal(labels.get(key), value)
    metadata = {
        "com.docker.compose.config-hash", "com.docker.compose.depends_on",
        "com.docker.compose.project.config_files", "com.docker.compose.project.working_dir",
        "com.docker.compose.project.environment_file",
    }
    if labels.keys() - expected_labels.keys() - compose_labels.keys() - metadata:
        _fail("recovery")
    if any(not isinstance(value, str) or len(value) > 4096 for value in labels.values()):
        _fail("recovery")
    health = backend["healthcheck"]
    expected_health = dict(image_config.get("Healthcheck") or {})
    for key, value in health.items():
        destination = {
            "test": "Test", "interval": "Interval", "timeout": "Timeout",
            "retries": "Retries", "start_period": "StartPeriod", "start_interval": "StartInterval",
        }[key]
        expected_health[destination] = value if key in {"test", "retries"} else _create_duration(value)
    _private_equal(config.get("Healthcheck"), expected_health)
    stop = _create_duration(backend.get("stop_grace_period", "30s"))
    _private_equal(config.get("StopTimeout"), stop // 1000000000)
    memory = backend["mem_limit"]
    logging = backend["logging"]
    expected_host = {
        "ReadonlyRootfs": True, "Init": True, "CapDrop": ["ALL"],
        "SecurityOpt": ["no-new-privileges:true"], "Tmpfs": {"/tmp": ""},
        "Memory": memory, "LogConfig": {"Type": "local", "Config": logging["options"]},
        "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0},
        "NetworkMode": "meet-production_default",
    }
    # Every other supported host control must have its inert Engine default.
    defaults = {
        "Privileged": False, "PublishAllPorts": False, "AutoRemove": False,
        "ReadonlyPaths": None, "MaskedPaths": None, "CapAdd": None, "Devices": None,
        "DeviceCgroupRules": None, "DeviceRequests": None, "VolumesFrom": None,
        "Links": None, "ExtraHosts": None, "GroupAdd": None, "Sysctls": None,
        "Ulimits": None, "StorageOpt": None, "CgroupParent": "", "Cgroup": "",
        "ContainerIDFile": "", "PidMode": "", "UTSMode": "", "UsernsMode": "",
        "IpcMode": "private", "CgroupnsMode": "private", "Isolation": "",
        "CpuShares": 0, "NanoCpus": 0, "CpuPeriod": 0, "CpuQuota": 0,
        "CpuRealtimePeriod": 0, "CpuRealtimeRuntime": 0, "CpusetCpus": "",
        "CpusetMems": "", "MemoryReservation": 0, "MemorySwap": memory * 2,
        "MemorySwappiness": None, "OomKillDisable": None, "OomScoreAdj": 0,
        "PidsLimit": None, "BlkioWeight": 0, "BlkioWeightDevice": None,
        "BlkioDeviceReadBps": None, "BlkioDeviceWriteBps": None,
        "BlkioDeviceReadIOps": None, "BlkioDeviceWriteIOps": None,
        "Dns": [], "DnsOptions": [], "DnsSearch": [], "ShmSize": 67108864,
        "Runtime": "runc", "ConsoleSize": [0, 0], "VolumeDriver": "",
    }
    # Engine's standard path restrictions are not arbitrary host controls.
    defaults["MaskedPaths"] = [
        "/proc/asound", "/proc/acpi", "/proc/interrupts", "/proc/kcore", "/proc/keys",
        "/proc/latency_stats", "/proc/timer_list", "/proc/timer_stats", "/proc/sched_debug",
        "/proc/scsi", "/sys/firmware", "/sys/devices/virtual/powercap",
    ]
    defaults["ReadonlyPaths"] = [
        "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys", "/proc/sysrq-trigger",
    ]
    for key, value in expected_host.items():
        _private_equal(host.get(key), value)
    for key, value in defaults.items():
        if key in host:
            if key in {"MaskedPaths", "ReadonlyPaths"}:
                if not isinstance(host[key], list) or any(not isinstance(item, str) for item in host[key]):
                    _fail("recovery")
                _private_equal(sorted(host[key]), sorted(value))
            else:
                _private_equal(host[key], value)
    if host.keys() - expected_host.keys() - defaults.keys() - {"Mounts", "Binds", "PortBindings"}:
        _fail("recovery")
    for key in ("Privileged", "CapAdd", "Devices", "DeviceRequests", "PidMode", "UsernsMode"):
        if key not in host:
            _fail("recovery")
    ports = backend["ports"]
    _private_equal(host.get("PortBindings"), {
        "8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": ports[0]["published"]}],
    })
    _private_equal(config.get("ExposedPorts"), {"8080/tcp": {}})
    mounts = []
    binds = []
    api_mounts = []
    for mount in backend["volumes"]:
        if not isinstance(mount, dict):
            _fail("recovery")
        if mount.get("type") == "volume":
            if mount not in (
                {"type": "volume", "source": "uploads_data", "target": "/data/uploads"},
                {"type": "volume", "source": "uploads_data", "target": "/data/uploads", "volume": {}},
            ):
                _fail("recovery")
            mounts.append(("volume", "meet-production_uploads_data", "/data/uploads", False, ""))
            binds.append("meet-production_uploads_data:/data/uploads:rw")
        elif mount == {
            "type": "bind", "source": HOST_CREDENTIAL_PATH, "target": CONTAINER_CREDENTIAL_PATH,
            "read_only": True, "bind": {"create_host_path": False},
        }:
            mounts.append(("bind", HOST_CREDENTIAL_PATH, CONTAINER_CREDENTIAL_PATH, True, "rprivate"))
            api_mounts.append({
                "Type": "bind", "Source": HOST_CREDENTIAL_PATH,
                "Target": CONTAINER_CREDENTIAL_PATH, "ReadOnly": True, "BindOptions": {},
            })
        else:
            _fail("recovery")
    actual_mounts = []
    for mount in _mounts(observed):
        if type(mount.get("RW")) is not bool:
            _fail("recovery")
        actual_mounts.append((
            mount.get("Type"), mount.get("Name") or mount.get("Source"),
            mount.get("Destination"), not mount["RW"], mount.get("Propagation", ""),
        ))
    if len(mounts) != len(set(mounts)) or sorted(actual_mounts) != sorted(mounts):
        _fail("recovery")
    _private_equal(sorted(host.get("Binds") or []), sorted(binds))
    _private_equal(host.get("Mounts") or [], api_mounts)
    network = observed.get("NetworkSettings")
    endpoints = network.get("Networks") if isinstance(network, dict) else None
    if not isinstance(endpoints, dict) or set(endpoints) != {"meet-production_default"}:
        _fail("recovery")
    endpoint = endpoints["meet-production_default"]
    if not isinstance(endpoint, dict) or any(endpoint.get(key) not in (None, {}, []) for key in (
        "IPAMConfig", "Links", "DriverOpts",
    )):
        _fail("recovery")
    _private_equal(sorted(endpoint.get("Aliases") or []), ["backend", "meet-production-backend-1"])
    if endpoint.keys() - {
        "IPAMConfig", "Links", "Aliases", "DriverOpts", "NetworkID", "EndpointID", "Gateway",
        "IPAddress", "IPPrefixLen", "IPv6Gateway", "GlobalIPv6Address", "GlobalIPv6PrefixLen",
        "MacAddress", "DNSNames", "GwPriority",
    }:
        _fail("recovery")
    for key in ("EndpointID", "Gateway", "IPAddress", "IPv6Gateway", "GlobalIPv6Address", "MacAddress"):
        if endpoint.get(key, "") != "":
            _fail("recovery")
    for key in ("IPPrefixLen", "GlobalIPv6PrefixLen", "GwPriority"):
        _private_equal(endpoint.get(key, 0), 0)


def _stopped_create_binding(
    run_fd: int, current: dict[str, Any], image: dict[str, Any], configuration: Any,
    observed: dict[str, Any], backend_inventory: Any, compose_inventory: Any,
    *, completion_lease: dict[str, Any] | None, completion_receipt: bytes,
    resource_evidence: Any = None, request_baseline: Any = None,
) -> dict[str, Any]:
    """Independent binding never supplies or repairs the supervisor completion acknowledgment."""
    def require_equal(stage: str, actual: Any, expected: Any) -> None:
        try:
            _private_equal(actual, expected)
        except ProviderError:
            if os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1":
                if stage not in {
                    "request-baseline", "resource-target", "container-inspection",
                    "resources-digest", "resource-request-digest", "container-runtime",
                }:
                    _fail("recovery")
                print(
                    "fixture_timepad_create=binding_refusal stage=" + stage,
                    file=sys.stderr, flush=True,
                )
            raise

    module = _timepad_state_module()
    try:
        request = module.require_create_normal_completion(current)
        if completion_lease is None:
            _fail("recovery")
        module.validate_create_completion(
            current, completion_lease, completion_receipt, acknowledged=True,
        )
    except module.GuardError:
        _fail("recovery")
    proof, _ = _prepared_target(run_fd, current, image, configuration)
    require_equal(
        "request-baseline",
        request_baseline, _read_resource_request(run_fd, request["resourceRequestDigest"]),
    )
    resources = _resource_admission(_resource_envelope(
        stage="post-create", role=_resource_role(current, proof),
        observed=resource_evidence,
        baseline=_read_resource_baseline(run_fd, proof["resourcesDigest"]),
        request_baseline=request_baseline,
    ))
    require_equal("resource-target", resource_evidence["targetConfiguration"], configuration)
    require_equal(
        "container-inspection",
        next(
            item for item in resource_evidence["containerInspections"]
            if item["Id"] == resources["membership"]["backendContainerId"]
        ),
        observed,
    )
    require_equal("resources-digest", request.get("resourcesDigest"), resources["baselineDigest"])
    require_equal(
        "resource-request-digest", request.get("resourceRequestDigest"),
        _configuration_digest(request_baseline),
    )
    if (
        current["ownedChild"] is not None
        or request["operationToken"] != proof["operationToken"]
        or request["modelDigest"] != proof["modelDigest"]
        or request["toolingDigest"] != proof["toolingDigest"]
        or request["preparedProofDigest"] != current["preparedProofDigest"]
    ):
        _fail("recovery")
    identity = observed.get("Id")
    if (
        not isinstance(identity, str) or re.fullmatch(r"[a-f0-9]{64}", identity) is None
        or identity in {request["priorContainerId"], current["predecessorContainerId"]}
        or backend_inventory != [identity]
        or _resource_ids(compose_inventory) != resources["membership"]["projectInventory"]
        or observed.get("Image") != "sha256:" + request["imageId"]
        or observed.get("RestartCount") != 0
    ):
        _fail("recovery")
    runtime = observed.get("State")
    if not isinstance(runtime, dict):
        _fail("recovery")
    for key, value in {
        "Status": "created", "Running": False, "Paused": False, "Restarting": False,
        "Dead": False, "OOMKilled": False, "Pid": 0, "ExitCode": 0, "Error": "",
        "StartedAt": "0001-01-01T00:00:00Z", "FinishedAt": "0001-01-01T00:00:00Z",
    }.items():
        require_equal("container-runtime", runtime.get(key), value)
    _create_runtime_configuration(image, configuration, observed, proof["operationToken"])
    config_hash = observed["Config"]["Labels"].get("com.docker.compose.config-hash")
    if not isinstance(config_hash, str) or re.fullmatch(r"[a-f0-9]{64}", config_hash) is None:
        _fail("recovery")
    if request["role"] == "replacement" and config_hash != current["configHash"]:
        _fail("recovery")
    if request["lifecycle"] == "bound" and (
        request["containerId"] != identity or request["configHash"] != config_hash
    ):
        _fail("recovery")
    _deadline_check()
    return {
        "requestNonce": request["nonce"], "containerId": identity,
        "configHash": config_hash, "completionDigest": request["completionDigest"],
        "resourcesDigest": resources["baselineDigest"],
        "resourceRequestDigest": _configuration_digest(request_baseline),
    }


def _prepared_target(
    run_fd: int, current: dict[str, Any], image_value: Any, configuration: Any,
) -> tuple[dict[str, Any], dict[str, str]]:
    proof = _prepared_proof(run_fd, current)
    image = _inspect(json.dumps(image_value, separators=(",", ":")).encode())
    effective = _absence_target_tuple(image, configuration, current)
    if (
        proof["targetConfigurationDigest"] != _model_digest(configuration)
        or proof["effectiveProviderDigest"] != _configuration_digest(effective)
    ):
        _fail("recovery")
    return proof, effective


def _prepared_absent_transaction(
    run_key: str, state_root: str, proof: dict[str, Any],
) -> None:
    """Validate intact target inputs without inventing an observed container."""
    expected = proof["provider"]
    marker = _marker(state_root, run_key)
    if (
        marker["phase"] not in {"prepared", "applying"}
        or marker["providerEnabled"] != expected["providerEnabled"]
        or marker["durableDisposition"] != expected["durableDisposition"]
    ):
        _fail("recovery")
    tx = _transaction(HOST_CREDENTIAL_PARENT, run_key)
    if not expected["providerEnabled"]:
        if os.path.lexists(tx) or expected["transaction"] is not None:
            _fail("recovery")
        return
    _validate_transaction(tx)
    parent_fd = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
    if parent_fd is None:
        _fail("recovery")
    try:
        tx_fd = os.open(tx, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            _lock_directory(tx_fd)
            transaction = expected["transaction"]
            if (
                _directory_record(os.fstat(parent_fd)) != transaction["parent"]
                or _directory_record(os.fstat(tx_fd)) != transaction["directory"]
                or set(_iter_directory_fd_names(tx_fd)) != {
                    entry["name"] for entry in transaction["entries"]
                }
            ):
                _fail("recovery")
            for entry in transaction["entries"]:
                name = entry["name"]
                if _file_record(
                    tx_fd, name, gid=10001 if name == "publication" else 0,
                    mode=0o440 if name == "publication" else 0o600,
                    links=2 if name == "publication" else 1,
                ) != entry["identity"]:
                    _fail("recovery")
            _, identity_data = _read_child_file(tx_fd, "identity.json", MAX_OWNER_BYTES)
            _, snapshot = _read_child_file(tx_fd, "snapshot", MAX_CREDENTIAL_BYTES)
            identity = _json(identity_data, "recovery")
            _validate_identity(identity)
            _validate_credential(snapshot)
            durable_identity, durable = _read_existing(HOST_CREDENTIAL_PATH)
            if durable_identity != identity["durable"] or durable != snapshot:
                _fail("recovery")
            if marker["durableDisposition"] == "created":
                _verify_created_publication(tx, HOST_CREDENTIAL_PATH, identity, snapshot)
            elif os.stat(HOST_CREDENTIAL_PATH, follow_symlinks=False).st_nlink != 1:
                _fail("recovery")
        finally:
            os.close(tx_fd)
    finally:
        os.close(parent_fd)


def _prepare_transition_proof(
    run_key: str, state_root: str, state_kind: str, input_data: bytes,
    deploy_lock_fd: int,
) -> None:
    if state_kind not in STATE_KINDS:
        _fail("recovery")
    value = _json(input_data, "recovery")
    if not isinstance(value, dict) or set(value) != {
        "schema", "evidence", "predecessorInspection", "imageInspection",
        "targetConfiguration", "operationToken", "toolingDigest", "resourceEvidence",
    } or value["schema"] != PREPARED_INPUT_SCHEMA:
        _fail("recovery")
    evidence = value["evidence"]
    required = {
        "rootId", "targetId", "predecessorId", "predecessorContainerId",
        "transitionId", "target", "predecessor", "operation", "runId",
        "incidentId", "ownedRun", "toolingDigest",
    }
    if not isinstance(evidence, dict) or set(evidence) != required:
        _fail("recovery")
    if (
        not isinstance(value["operationToken"], str)
        or re.fullmatch(r"[0-9a-f]{32}", value["operationToken"]) is None
        or value["toolingDigest"] != evidence["toolingDigest"]
    ):
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        module, origin, previous = _timepad_current(state_root, deploy_lock_fd)
        try:
            contract = module.parse_contract(module._read_input(
                pathlib.Path(__file__).with_name("test-vps-timepad-release-contracts.json"),
                module.MAX_CONTRACT_BYTES,
            ))
            admission = module.admit(
                contract, root_id=origin["rootId"], target_id=evidence["targetId"],
                predecessor_id=evidence["predecessorId"],
                transition_id=evidence["transitionId"], target_tuple=evidence["target"],
                predecessor_tuple=evidence["predecessor"],
            )
            target = next(item for item in contract["images"] if item["id"] == evidence["targetId"])
            predecessor = next(item for item in contract["images"] if item["id"] == evidence["predecessorId"])
        except (module.GuardError, OSError, ValueError, TypeError, KeyError, StopIteration):
            _fail("recovery")
        if (
            previous["phase"] not in {"READY", "COMMITTED", "ROLLED_BACK"}
            or previous["operationEpoch"] >= (1 << 64) - 1
            or evidence["rootId"] != origin["rootId"]
            or evidence["runId"] != run_key
            or evidence["ownedRun"] != f"{run_key}-{state_kind}"
            or evidence["runId"] == previous.get("runId")
            or evidence["incidentId"] == previous.get("incidentId")
            or evidence["operation"] != (
                "deploy" if state_kind == "final-deploy" else "rollback-drill"
            )
            or admission.disposition not in {"pre-barrier-only", "post-barrier-compatible"}
            or evidence["operation"] == "rollback-drill"
            and evidence["transitionId"] is not None
            and admission.disposition != "post-barrier-compatible"
        ):
            _fail("recovery")
        current = dict(
            evidence, originDigest=origin["originDigest"],
            operationEpoch=previous["operationEpoch"] + 1, target=target,
            predecessor=predecessor, evidenceDigest=admission.contract_digest,
            phase="PREPARED", containerId=None, configHash=None, ownedChild=None,
            providerFinalizationDigest=None,
        )
        for field, pattern in (
            ("incidentId", r"[a-f0-9]{32}"), ("toolingDigest", r"[a-f0-9]{64}"),
            ("predecessorContainerId", r"[a-f0-9]{12,64}"),
        ):
            if not isinstance(current[field], str) or re.fullmatch(pattern, current[field]) is None:
                _fail("recovery")
        run_fd = os.open(
            evidence["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_fd,
        )
        credential_parent = None
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, evidence["ownedRun"])
            credential_parent = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
            if credential_parent is not None:
                _lock_directory(credential_parent)
                if any(
                    name.startswith(".transaction-") and name != ".transaction-" + run_key
                    for name in _iter_directory_fd_names(credential_parent)
                ):
                    _fail("recovery")
            for name in _iter_directory_fd_names(root_fd):
                if name == ".smtp-transaction.current" or (
                    name.startswith((".provider-transaction.", ".provider-state."))
                    and name != ".provider-transaction.current"
                ):
                    _fail("recovery")
            inspect = _inspect(json.dumps(value["predecessorInspection"]).encode())
            if _live_resume_runtime(inspect, current, "admission")[0]:
                _fail("recovery")
            _live_resume_predecessor(run_fd, current, inspect)
            image = _inspect(json.dumps(value["imageInspection"]).encode())
            effective = _absence_target_tuple(image, value["targetConfiguration"], current)
            _create_backend_model(value["targetConfiguration"], value["operationToken"])
            resources = _resource_admission(_resource_envelope(
                stage="prepared",
                role={
                    "operationToken": value["operationToken"],
                    "backendContainerId": current["predecessorContainerId"],
                    "priorBackendContainerId": None, "allowEmptyBackend": False,
                },
                observed=value["resourceEvidence"],
            ))
            _private_equal(
                value["resourceEvidence"]["targetConfiguration"], value["targetConfiguration"],
            )
            captured_predecessor = next(
                item for item in value["resourceEvidence"]["containerInspections"]
                if item["Id"] == current["predecessorContainerId"]
            )
            for key in ("Id", "Image", "Config", "HostConfig", "Mounts", "NetworkSettings"):
                _private_equal(inspect.get(key), captured_predecessor.get(key))
            if effective != _effective_tuple(inspect):
                _fail("recovery")
            provider = _prepared_transaction(run_key, state_root, inspect)
            _prepared_no_commit_files(run_fd)
            _prepared_environment(run_fd, current)
            for name in ("config.env.production", "config.base-compose.yml"):
                _snapshot_source_identity(run_fd, name)
            proof = {
                "schema": PREPARED_SCHEMA,
                "binding": {key: current[key] for key in PREPARED_BINDING},
                "config": _prepared_config_records(run_fd),
                "provider": provider,
                "targetConfigurationDigest": _model_digest(value["targetConfiguration"]),
                "effectiveProviderDigest": _configuration_digest(effective),
                "operationToken": value["operationToken"],
                "modelDigest": _model_digest(value["targetConfiguration"]),
                "toolingDigest": value["toolingDigest"],
                "resourcesDigest": resources["baselineDigest"],
            }
            data = json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()
            if len(data) > MAX_PREPARED_BYTES:
                _fail("recovery")
            resource_data = _resource_bytes(resources["baseline"], MAX_RESOURCES_BYTES)
            try:
                os.stat("timepad-resources.json", dir_fd=run_fd, follow_symlinks=False)
            except FileNotFoundError:
                _write_private_at(run_fd, ".timepad-resources.tmp", resource_data, 0o600)
                _rename_noreplace(run_fd, ".timepad-resources.tmp", "timepad-resources.json")
                _deadline_check()
                os.fsync(run_fd)
            _private_equal(
                _read_resource_baseline(run_fd, resources["baselineDigest"]), resources["baseline"],
            )
            for entry in proof["config"]:
                fd = os.open(
                    entry["name"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=run_fd,
                )
                try:
                    _deadline_check()
                    os.fsync(fd)
                finally:
                    os.close(fd)
            try:
                os.stat("timepad-prepared.json", dir_fd=run_fd, follow_symlinks=False)
            except FileNotFoundError:
                _write_private_at(run_fd, ".timepad-prepared.tmp", data, 0o600)
                _rename_noreplace(run_fd, ".timepad-prepared.tmp", "timepad-prepared.json")
                _deadline_check()
                os.fsync(run_fd)
            current["preparedProofDigest"] = _finalization_digest(data)
            if _prepared_proof(run_fd, current) != proof:
                _fail("recovery")
            _deadline_check()
            sys.stdout.write(json.dumps({
                "schemaVersion": 1, "preparedProofDigest": current["preparedProofDigest"],
                "resourcesDigest": resources["baselineDigest"],
                "outcome": "proof-prepared",
            }, separators=(",", ":")) + "\n")
        finally:
            if credential_parent is not None:
                os.close(credential_parent)
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _live_resume_predecessor(
    run_fd: int, current: dict[str, Any], inspect: dict[str, Any]
) -> None:
    expected_tuple = current["predecessor"]["tuple"]
    labels = inspect["Config"]["Labels"]
    expected = {
        "previous-image-id": "sha256:" + expected_tuple["platformImageId"],
        "previous-revision": expected_tuple["revision"],
        "previous-version": expected_tuple["version"],
        "previous-runtime-config-hash": labels["com.docker.compose.config-hash"],
    }
    for name, value in expected.items():
        _, data = _read_child_file(run_fd, name, MAX_OWNER_BYTES)
        if data != (value + "\n").encode("ascii"):
            _fail("recovery")
    _, data = _read_child_file(run_fd, "previous-image", MAX_OWNER_BYTES)
    try:
        reference = data.decode("ascii")
    except UnicodeDecodeError:
        _fail("recovery")
    if re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:"
        + expected_tuple["repositoryDigest"] + r"\n",
        reference,
    ) is None:
        _fail("recovery")


def _live_resume_transaction(
    run_key: str, state_root: str, inspect: dict[str, Any], *, predecessor: bool
) -> dict[str, Any]:
    enabled, _ = _provider_state(inspect)
    _, _, source = _provider_mount(inspect, enabled, allow_external_source=predecessor)
    marker = _marker(state_root, run_key)
    if (
        marker["phase"] not in {"prepared", "applying", "verifying", "rolling-back"}
        or marker["providerEnabled"] != enabled
        or enabled and marker["durableDisposition"] not in {"created", "reused"}
        or not enabled and marker["durableDisposition"] != "none"
    ):
        _fail("recovery")
    tx = _transaction(HOST_CREDENTIAL_PARENT, run_key)
    if not enabled:
        if os.path.lexists(tx):
            _fail("recovery")
        return marker
    _validate_transaction(tx)
    tx_fd = os.open(tx, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _lock_directory(tx_fd)
        expected_names = {"identity.json", "snapshot"}
        if marker["durableDisposition"] == "created":
            expected_names.add("publication")
        if set(_iter_directory_fd_names(tx_fd)) != expected_names:
            _fail("recovery")
        _, identity_data = _read_child_file(tx_fd, "identity.json", MAX_OWNER_BYTES)
        _, snapshot = _read_child_file(tx_fd, "snapshot", MAX_CREDENTIAL_BYTES)
        identity = _json(identity_data, "recovery")
        _validate_identity(identity)
        _validate_credential(snapshot)
        durable, data = _read_existing(HOST_CREDENTIAL_PATH)
        if data != snapshot or durable != identity["durable"]:
            _fail("recovery")
        if marker["durableDisposition"] == "created":
            _verify_created_publication(tx, HOST_CREDENTIAL_PATH, identity, snapshot)
        else:
            info = os.stat(HOST_CREDENTIAL_PATH, follow_symlinks=False)
            if info.st_nlink != 1:
                _fail("recovery")
        if predecessor:
            if source is None:
                _fail("recovery")
            previous_identity, previous_data = _read_existing(source, source=True)
            if previous_identity != identity["predecessor"] or previous_data != snapshot:
                _fail("recovery")
        return marker
    finally:
        os.close(tx_fd)


def _live_resume_receipt(
    root_fd: int, run_fd: int, state_root: str, current: dict[str, Any],
    origin: dict[str, Any], inspect: dict[str, Any],
) -> None:
    witness, data = _read_finalization_witness(run_fd)
    if _finalization_digest(data) != current["providerFinalizationDigest"]:
        _fail("recovery")
    commit, commit_data, _ = _controller_commit_witness(
        run_fd, current, require_state_digest=True
    )
    _receipt_runtime_binding(
        witness, current, commit, inspect, require_replacement_health=False,
    )
    _matches_finalization_context(
        witness, origin=origin, current=current, commit=commit,
        commit_data=commit_data, run_fd=run_fd, inspect=inspect,
    )
    _receipt_residuals(root_fd, run_fd, state_root, current, witness, inspect=inspect)


def _receipt_residuals(
    root_fd: int, run_fd: int, state_root: str, current: dict[str, Any],
    witness: dict[str, Any], *, inspect: dict[str, Any] | None,
) -> None:
    try:
        os.stat(".provider-transaction.current", dir_fd=root_fd, follow_symlinks=False)
    except FileNotFoundError:
        marker = None
        _validate_existing_finalization_terminal(run_fd, witness)
    else:
        marker = _marker(state_root, current["runId"])
        if marker != witness["pointer"]:
            # Crash before finalizing publication permits only intact inputs.
            if marker != dict(witness["pointer"], phase="verifying"):
                _fail("recovery")
            if inspect is not None:
                _live_resume_transaction(
                    current["runId"], state_root, inspect, predecessor=False
                )
    tx = _transaction(HOST_CREDENTIAL_PARENT, current["runId"])
    if current["phase"] == "COMMITTED" and marker is not None:
        _fail("recovery")
    publication_present = False
    if os.path.lexists(tx):
        if not witness["providerEnabled"] or marker is None:
            _fail("recovery")
        tx_fd = os.open(tx, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            _lock_directory(tx_fd)
            transaction = witness["transaction"]
            actual_dir = _directory_record(os.fstat(tx_fd))
            if any(
                actual_dir[key] != transaction["directory"][key]
                for key in ("device", "inode", "uid", "gid", "mode")
            ):
                _fail("recovery")
            parent_fd = os.open(
                HOST_CREDENTIAL_PARENT, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            )
            try:
                actual_parent = _directory_record(os.fstat(parent_fd))
                if any(
                    actual_parent[key] != transaction["parent"][key]
                    for key in ("device", "inode", "uid", "gid", "mode")
                ):
                    _fail("recovery")
            finally:
                os.close(parent_fd)
            names = set(_iter_directory_fd_names(tx_fd))
            entries = transaction["entries"]
            if inspect is None and marker["phase"] == "verifying" and names != {
                entry["name"] for entry in entries
            }:
                _fail("recovery")
            allowed = {n for e in entries for n in (e["name"], e["quarantineName"])}
            if names - allowed:
                _fail("recovery")
            first = next(
                (i for i, e in enumerate(entries)
                 if e["name"] in names or e["quarantineName"] in names),
                len(entries),
            )
            for i, entry in enumerate(entries):
                original, quarantine = entry["name"], entry["quarantineName"]
                if i < first:
                    continue
                if i > first and (original not in names or quarantine in names):
                    _fail("recovery")
                if (original in names) == (quarantine in names):
                    _fail("recovery")
                name = original if original in names else quarantine
                expected = entry["identity"]
                actual = _file_record(
                    tx_fd, name, uid=expected["uid"], gid=expected["gid"],
                    mode=expected["mode"], links=expected["links"],
                )
                compare = set(expected) - ({"ctimeNs"} if name == quarantine else set())
                if any(actual[key] != expected[key] for key in compare):
                    _fail("recovery")
                publication_present |= original == "publication"
        finally:
            os.close(tx_fd)
    elif marker is not None and marker["phase"] != "finalizing" and witness["providerEnabled"]:
        _fail("recovery")
    if witness["providerEnabled"]:
        fd, info, credential = _open_regular(
            HOST_CREDENTIAL_PATH, max_bytes=MAX_CREDENTIAL_BYTES
        )
        try:
            _validate_credential(credential)
            expected = witness["durableCredential"]
            actual = {
                "device": info.st_dev, "inode": info.st_ino, "uid": info.st_uid,
                "gid": info.st_gid, "mode": stat.S_IMODE(info.st_mode),
                "size": info.st_size, "mtimeNs": info.st_mtime_ns,
                "links": info.st_nlink, "sha256": _finalization_digest(credential),
            }
            if actual != {
                key: (2 if publication_present else 1) if key == "links" else expected[key]
                for key in actual
            }:
                _fail("recovery")
        finally:
            os.close(fd)
    if current["phase"] == "COMMITTED":
        stream = json.dumps({
            "schemaVersion": SCHEMA_VERSION,
            "providerEnabled": witness["providerEnabled"],
            "credentialMountPresent": witness["providerEnabled"],
            "credentialMountReadOnly": witness["providerEnabled"],
            "outcome": "committed",
        }, separators=(",", ":")).encode()
        if _finalization_digest(stream) != current["terminalReceipt"]:
            _fail("recovery")


def _absence_target_tuple(
    image: dict[str, Any], configuration: Any, current: dict[str, Any],
) -> dict[str, str]:
    """Resolve configuration evidence, without constructing a runtime record."""
    _image_admission(image)
    target = current["target"]["tuple"]
    labels = image["Config"].get("Labels")
    if (
        image.get("Id") != "sha256:" + target["platformImageId"]
        or image["Config"].get("User") != "10001:10001"
        or not isinstance(labels, dict)
        or labels.get("org.opencontainers.image.revision") != target["revision"]
        or labels.get("org.opencontainers.image.version") != target["version"]
        or labels.get("org.opencontainers.image.source")
        != "https://github.com/NickolayMamonov/meet-backend-v3"
        or not isinstance(configuration, dict)
        or not isinstance(configuration.get("services"), dict)
        or not isinstance(configuration["services"].get("backend"), dict)
    ):
        _fail("recovery")
    backend = configuration["services"]["backend"]
    reference = backend.get("image")
    environment = backend.get("environment", {})
    if (
        not isinstance(reference, str)
        or reference != "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
        + target["repositoryDigest"]
        or not isinstance(environment, dict)
        or any(not isinstance(k, str) or not isinstance(v, str)
               for k, v in environment.items())
    ):
        _fail("recovery")
    values = dict(_env_entries(image))
    values.update(environment)
    config = dict(image["Config"])
    for source, destination in (("command", "Cmd"), ("entrypoint", "Entrypoint")):
        if source in backend:
            config[destination] = backend[source]
    _validate_configuration_channels(config, list(values.items()))
    enabled, provider = _provider_values(values)
    volumes = backend.get("volumes", [])
    if not isinstance(volumes, list):
        _fail("recovery")
    credential = []
    for mount in volumes:
        if not isinstance(mount, dict):
            _fail("recovery")
        destination = mount.get("target")
        if destination == CONTAINER_CREDENTIAL_PATH:
            credential.append(mount)
        elif destination != "/data/uploads":
            _fail("recovery")
    if enabled:
        if len(credential) != 1 or not isinstance(credential[0].get("bind"), dict):
            _fail("recovery")
        if any((
            credential[0].get("type") != "bind",
            credential[0].get("source") != HOST_CREDENTIAL_PATH,
            credential[0].get("read_only") is not True,
            credential[0]["bind"].get("create_host_path") is not False,
        )):
            _fail("recovery")
    elif credential:
        _fail("recovery")
    return _normalized_provider_tuple(enabled, provider)


def _absence_receipt(
    root_fd: int, run_fd: int, state_root: str, current: dict[str, Any],
    origin: dict[str, Any], effective: dict[str, str],
) -> None:
    if (
        current["phase"] not in {"COMMITTING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING"}
        or current["ownedChild"] is not None
        or current["providerFinalizationDigest"] is None
        or current["commitWitnessDigest"] is None
        or current["commitSubstep"] not in {
            "provider-cleanup", "terminal-policy-intent", "policy-restored",
        }
    ):
        _fail("recovery")
    witness, data = _read_finalization_witness(run_fd)
    if _finalization_digest(data) != current["providerFinalizationDigest"]:
        _fail("recovery")
    commit, commit_data, _ = _controller_commit_witness(
        run_fd, current, require_state_digest=True,
    )
    target = current["target"]["tuple"]
    if (
        commit != {
            "schema": "meet-backend/test-vps-timepad-commit-witness/v1",
            "operationEpoch": current["operationEpoch"],
            "incidentId": current["incidentId"],
            "containerId": current["containerId"], "configHash": current["configHash"],
            "imageId": "sha256:" + target["platformImageId"],
            "revision": target["revision"], "version": target["version"],
            "providerEnabled": effective["APP_PUSH_PROVIDER_ENABLED"] == "true",
        }
        or witness["containerId"] != current["containerId"]
    ):
        _fail("recovery")
    original = re.fullmatch(
        re.escape(current["incidentId"]) + r":([1-9][0-9]{0,19})",
        witness["startAttemptId"],
    )
    latest = re.fullmatch(
        re.escape(current["incidentId"]) + r":([1-9][0-9]{0,19})",
        current["latestAttemptId"] or "",
    )
    if original is None or latest is None or not (
        int(original.group(1)) <= int(latest.group(1)) <= (1 << 64) - 1
    ):
        _fail("recovery")
    _matches_finalization_identity(
        witness, origin=origin, current=current, commit=commit,
        commit_data=commit_data, run_fd=run_fd,
        effective_provider_digest=_finalization_digest(json.dumps(
            effective, sort_keys=True, separators=(",", ":"),
        ).encode()),
    )
    _receipt_residuals(root_fd, run_fd, state_root, current, witness, inspect=None)


def _absence_resume(
    run_key: str, state_root: str, state_kind: str,
    input_data: bytes, deploy_lock_fd: int,
) -> None:
    if (
        type(deploy_lock_fd) is not int or deploy_lock_fd < 0
        or state_kind != "final-deploy" or len(input_data) > MAX_LIVE_RESUME_BYTES
    ):
        _fail("recovery")
    value = _json(input_data, "recovery")
    if (
        not isinstance(value, dict)
        or set(value) != {
            "schema", "authorization", "imageInspection",
            "targetConfiguration", "backendInventory",
        }
        or value["schema"] != ABSENCE_RESUME_SCHEMA
        or value["backendInventory"] != []
        or not isinstance(value["authorization"], dict)
    ):
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        module, origin, current = _timepad_current(state_root, deploy_lock_fd)
        _resume_binding_authority(
            value["authorization"], module=module, origin=origin, current=current,
            run_key=run_key, state_kind=state_kind,
        )
        image = _inspect(json.dumps(value["imageInspection"], separators=(",", ":")).encode())
        effective = _absence_target_tuple(image, value["targetConfiguration"], current)
        run_fd = os.open(
            current["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_fd,
        )
        credential_parent = None
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, current["ownedRun"])
            if current["phase"] != "PREPARED":
                try:
                    module.require_runtime_request_completion(current)
                except module.GuardError:
                    _fail("recovery")
            for name in _iter_directory_fd_names(root_fd):
                if name == ".smtp-transaction.current" or (
                    name.startswith((".provider-transaction.", ".provider-state."))
                    and name != ".provider-transaction.current"
                ):
                    _fail("recovery")
            credential_parent = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
            if credential_parent is not None:
                _lock_directory(credential_parent)
                for name in _iter_directory_fd_names(credential_parent):
                    if name.startswith(".transaction-") and name != ".transaction-" + run_key:
                        _fail("recovery")
            _live_resume_config(run_fd, current)
            if current["phase"] == "PREPARED":
                if any(current.get(key) is not None for key in (
                    "containerId", "configHash", "ownedChild", "latestAttemptId",
                    "commitWitnessDigest", "providerFinalizationDigest",
                    "commitSubstep", "terminalReceipt",
                )):
                    _fail("recovery")
                proof, _ = _prepared_target(
                    run_fd, current, value["imageInspection"], value["targetConfiguration"],
                )
                _prepared_absent_transaction(run_key, state_root, proof)
                _prepared_no_commit_files(run_fd)
            else:
                _absence_receipt(root_fd, run_fd, state_root, current, origin, effective)
            _, final_origin, final_current = _timepad_current(state_root, deploy_lock_fd)
            if final_origin != origin or final_current != current:
                _fail("recovery")
            enabled = effective["APP_PUSH_PROVIDER_ENABLED"] == "true"
            _result(enabled, enabled, enabled, "retry-exact-candidate")
        finally:
            if credential_parent is not None:
                os.close(credential_parent)
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _live_resume(
    run_key: str, state_root: str, state_kind: str,
    input_data: bytes, deploy_lock_fd: int,
) -> None:
    """Private, read-only proof; the controller owns reconciliation and retries."""
    _result(*_validate_live_resume(run_key, state_root, state_kind, input_data, deploy_lock_fd))


def _validate_live_resume(
    run_key: str, state_root: str, state_kind: str,
    input_data: bytes, deploy_lock_fd: int,
) -> tuple[bool, bool, bool, str]:
    """Shared read-only admission; no lease, schema, configuration or runtime writes."""
    if (
        type(deploy_lock_fd) is not int or deploy_lock_fd < 0
        or state_kind not in STATE_KINDS
        or len(input_data) > MAX_LIVE_RESUME_BYTES
    ):
        _fail("recovery")
    root_fd = _open_deploy_state_root(state_root)
    try:
        _lock_directory(root_fd)
        module, origin, current = _timepad_current(state_root, deploy_lock_fd)
        value = _json(input_data, "recovery")
        inspect, stage = _live_resume_authority(
            value, module=module, origin=origin,
            current=current, run_key=run_key, state_kind=state_kind,
        )
        exact_target, healthy = _live_resume_runtime(inspect, current, stage)
        run_fd = os.open(
            current["ownedRun"], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_fd,
        )
        credential_parent = None
        try:
            _lock_directory(run_fd)
            _validate_state_directory_fd(run_fd, current["ownedRun"])
            if current["phase"] != "PREPARED":
                try:
                    if current["runtimeRequest"] is not None and \
                            current["runtimeRequest"]["lifecycle"] == "acknowledged":
                        _runtime_request_proof(current, inspect)
                    else:
                        module.require_runtime_request_completion(current)
                except module.GuardError:
                    _fail("recovery")
            for name in _iter_directory_fd_names(root_fd):
                if name == ".smtp-transaction.current" or (
                    name.startswith((".provider-transaction.", ".provider-state."))
                    and name != ".provider-transaction.current"
                ):
                    _fail("recovery")
            credential_parent = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
            if credential_parent is not None:
                _lock_directory(credential_parent)
                for name in _iter_directory_fd_names(credential_parent):
                    if name.startswith(".transaction-") and name != (
                        ".transaction-" + run_key
                    ):
                        _fail("recovery")
            _live_resume_config(run_fd, current)
            if not exact_target:
                _live_resume_predecessor(run_fd, current, inspect)
            if current["phase"] == "PREPARED":
                proof, effective = _prepared_target(
                    run_fd, current, value["imageInspection"], value["targetConfiguration"],
                )
                if effective != _effective_tuple(inspect) or proof["provider"] != (
                    _prepared_transaction(run_key, state_root, inspect)
                ):
                    _fail("recovery")
                _prepared_no_commit_files(run_fd)
            enabled, _ = _provider_state(inspect)
            present, read_only, _ = _provider_mount(
                inspect, enabled, allow_external_source=not exact_target
            )
            if current["providerFinalizationDigest"] is not None:
                if not exact_target:
                    _fail("recovery")
                _live_resume_receipt(root_fd, run_fd, state_root, current, origin, inspect)
                outcome = "already-completed" if current["phase"] == "COMMITTED" else (
                    "finalization-only" if healthy else "retry-exact-candidate"
                )
            else:
                if current["phase"] in {"COMMITTING", "COMMITTED"}:
                    _fail("recovery")
                marker = _live_resume_transaction(
                    run_key, state_root, inspect, predecessor=not exact_target
                )
                # Applying is published before target configuration writes,
                # while the schema phase remains PREPARED until the barrier.
                allowed_phases = {
                    "PREPARED": {"prepared", "applying"},
                    "CUTOVER_POSSIBLE": {"prepared", "applying", "verifying"},
                    "ROLLING_BACK": {"prepared", "applying", "verifying", "rolling-back"},
                    "VERIFYING": {"verifying"},
                    "RECOVERY_REQUIRED": {"verifying"},
                    "FORWARD_RECOVERING": {"verifying"},
                }
                if marker["phase"] not in allowed_phases.get(current["phase"], set()):
                    _fail("recovery")
                outcome = (
                    "finalization-only"
                    if current["phase"] in {
                        "VERIFYING", "RECOVERY_REQUIRED", "FORWARD_RECOVERING",
                    } and exact_target and healthy
                    and current["ownedChild"] is None and marker["phase"] == "verifying"
                    else "retry-exact-candidate"
                )
            if stage == "quiescence":
                outcome = "retry-exact-candidate"
            _, final_origin, final_current = _timepad_current(state_root, deploy_lock_fd)
            if final_origin != origin or final_current != current:
                _fail("recovery")
            return enabled, present, read_only, outcome
        finally:
            if credential_parent is not None:
                os.close(credential_parent)
            os.close(run_fd)
    finally:
        os.close(root_fd)


def _recovery_lease_runtime_proof(
    state_root: str, current: dict[str, Any], authorization: bytes,
    input_data: bytes, deploy_lock_fd: int, check: Callable[[], None],
    *, create_completion_recovery: bool = False,
) -> dict[str, Any]:
    """Fixed registration-only proof before replacing stale execution ownership.

    Inventories constrain ownership, but cannot complete an intent. The old
    request must have its durable synchronous daemon acknowledgment first.
    """
    module = _timepad_state_module()
    value = _json(input_data, "recovery")
    if create_completion_recovery:
        if (
            not isinstance(value, dict)
            or set(value) != {
                "inspection", "backendInventory", "composeInventory",
                "imageInspection", "targetConfiguration", "resourceEvidence",
                "requestBaseline",
            }
        ):
            _fail("recovery")
        authorization_value = _json(authorization, "recovery")
        if not isinstance(authorization_value, dict):
            _fail("recovery")
        request = current.get("runtimeRequest")
        if (
            not isinstance(request, dict)
            or request.get("operation") != "create"
            or request.get("lifecycle") not in {"normal-completed", "bound"}
            or current.get("phase") == "PREPARED"
            or current.get("ownedChild") is not None
            or request.get("role") not in {"initial", "replacement"}
        ):
            _fail("recovery")
        if request["lifecycle"] == "normal-completed":
            role_binding_matches = (
                request["containerId"] is None
                and request["configHash"] is None
                and (
                    request["role"] == "initial"
                    and request["priorContainerId"] is None
                    and current.get("containerId") is None
                    and current.get("configHash") is None
                    or request["role"] == "replacement"
                    and isinstance(request["priorContainerId"], str)
                    and current.get("containerId") == request["priorContainerId"]
                    and isinstance(current.get("configHash"), str)
                )
            )
        else:
            role_binding_matches = (
                request["containerId"] == current.get("containerId")
                and request["configHash"] == current.get("configHash")
                and isinstance(request["containerId"], str)
                and (
                    request["role"] == "initial"
                    and request["priorContainerId"] is None
                    or request["role"] == "replacement"
                    and isinstance(request["priorContainerId"], str)
                    and request["containerId"] != request["priorContainerId"]
                )
            )
        if not role_binding_matches:
            _fail("recovery")
        observed = _inspect(
            json.dumps(value["inspection"], separators=(",", ":")).encode()
        )
        if (
            not isinstance(value["backendInventory"], list)
            or len(value["backendInventory"]) != 1
            or value["backendInventory"] != [observed.get("Id")]
            or not isinstance(value["composeInventory"], list)
            or len(value["composeInventory"]) > MAX_RESOURCE_ENTRIES
        ):
            _fail("recovery")
        root_fd = _open_deploy_state_root(state_root)
        try:
            _lock_directory(root_fd)
            module, origin, durable_current = _timepad_current(
                state_root, deploy_lock_fd,
            )
            if durable_current != current:
                _fail("recovery")
            _resume_binding_authority(
                authorization_value,
                module=module,
                origin=origin,
                current=durable_current,
                run_key=current["runId"],
                state_kind=current["ownedRun"].removeprefix(current["runId"] + "-"),
            )
            lease = module._read_execution_lease_locked(state_root)
            run_fd = os.open(
                current["ownedRun"],
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            try:
                _lock_directory(run_fd)
                _validate_state_directory_fd(run_fd, current["ownedRun"])
                name = (
                    "timepad-create-completion.json"
                    if request["role"] == "initial"
                    else "timepad-replacement-completion.json"
                )
                receipt = _read_child_file(
                    run_fd, name, module.MAX_CREATE_COMPLETION_BYTES,
                )[1]
                _stopped_create_binding(
                    run_fd, current,
                    _inspect(json.dumps(
                        value["imageInspection"], separators=(",", ":"),
                    ).encode()),
                    value["targetConfiguration"], observed,
                    value["backendInventory"], value["composeInventory"],
                    completion_lease=lease,
                    completion_receipt=receipt,
                    resource_evidence=value["resourceEvidence"],
                    request_baseline=value["requestBaseline"],
                )
                if _timepad_current(state_root, deploy_lock_fd)[2] != current:
                    _fail("recovery")
            finally:
                os.close(run_fd)
        finally:
            os.close(root_fd)
        check()
        return request
    if not isinstance(value, dict) or set(value) != {
        "inspection", "backendInventory", "composeInventory",
    } or value["backendInventory"] != [current["containerId"]] or \
            value["composeInventory"] != value["backendInventory"]:
        _fail("recovery")
    if current["phase"] == "PREPARED" or current["containerId"] is None or \
            current["runtimeRequest"] is None:
        _fail("recovery")
    inspect = _inspect(json.dumps(value["inspection"], separators=(",", ":")).encode())
    exact, _ = _live_resume_runtime(inspect, current, "runtime")
    if not exact:
        _fail("recovery")
    request = current["runtimeRequest"]
    if request["lifecycle"] == "acknowledged":
        proof = _runtime_request_proof(current, inspect)
        request = dict(request, lifecycle="completed", completionDigest=proof["completionDigest"])
    else:
        try:
            module.require_runtime_request_completion(current)
        except (ValueError, TypeError, KeyError, module.GuardError):
            _fail("recovery")
    run_key = current["runId"]
    state_kind = current["ownedRun"].removeprefix(run_key + "-")
    payload = json.dumps({
        "schema": LIVE_RESUME_SCHEMA, "authorization": _json(authorization, "recovery"),
        "inspection": value["inspection"], "stage": "runtime",
    }, separators=(",", ":")).encode()
    token = _EXECUTION_CHECK.set(check)
    try:
        check()
        _validate_live_resume(run_key, state_root, state_kind, payload, deploy_lock_fd)
        check()
    finally:
        _EXECUTION_CHECK.reset(token)
    return request


def _rooted(path: str, root: str | None) -> str:
    # Production paths are compiled constants. Tests inject isolated roots by
    # replacing these constants after importing the module; no production
    # caller may remap a fixed destination through an argument.
    if root:
        _fail("provider")
    return path


def _transaction(root: str, run_key: str) -> str:
    _run_key(run_key)
    return os.path.join(root, ".transaction-" + run_key)


def _ensure_parent(parent: str) -> None:
    if os.path.lexists(parent):
        if os.path.islink(parent) or not os.path.isdir(parent):
            _fail("credential")
        info = os.stat(parent, follow_symlinks=False)
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            _fail("credential")
    else:
        _check_ancestors(parent)
        _deadline_check()
        os.mkdir(parent, 0o700)
        _deadline_check()
        os.chown(parent, 0, 0)
        _deadline_check()
        os.chmod(parent, 0o700)
    _check_ancestors(parent)
    _acl_is_safe(parent)


def _write_private(path: str, data: bytes, mode: int, gid: int = 0) -> None:
    _deadline_check()
    _check_ancestors(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    _deadline_check()
    fd = os.open(path, flags, mode)
    try:
        offset = 0
        while offset < len(data):
            _deadline_check()
            offset += os.write(fd, data[offset:])
        _deadline_check()
        os.fsync(fd)
        _deadline_check()
        os.fchown(fd, 0, gid)
        _deadline_check()
        os.fchmod(fd, mode)
        _deadline_check()
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True)
        _deadline_check()
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_private_at(
    directory_fd: int,
    name: str,
    data: bytes,
    mode: int,
    gid: int = 0,
) -> None:
    _deadline_check()
    if not name or "/" in name or "\x00" in name:
        _fail("recovery")
    _deadline_check()
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=directory_fd,
    )
    try:
        offset = 0
        while offset < len(data):
            _deadline_check()
            offset += os.write(fd, data[offset:])
        _deadline_check()
        os.fsync(fd)
        _deadline_check()
        os.fchown(fd, 0, gid)
        _deadline_check()
        os.fchmod(fd, mode)
        _deadline_check()
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
        _deadline_check()
        os.fsync(fd)
    finally:
        os.close(fd)


def _rename_noreplace_boundary(
    directory_fd: int,
    source: str,
    destination: str,
) -> None:
    return None


def _rename_noreplace(
    directory_fd: int,
    source: str,
    destination: str,
    *,
    expected_source_fd: int | None = None,
    expected_source_inode: tuple[int, int] | None = None,
) -> None:
    _deadline_check()
    if (
        not source
        or not destination
        or "/" in source
        or "/" in destination
        or "\x00" in source
        or "\x00" in destination
    ):
        _fail("recovery")
    if expected_source_fd is not None:
        opened = os.fstat(expected_source_fd)
        current = os.stat(
            source,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if (
            not stat.S_ISDIR(opened.st_mode)
            or not stat.S_ISDIR(current.st_mode)
            or not _same_inode(opened, current)
            or (
                expected_source_inode is not None
                and (opened.st_dev, opened.st_ino) != expected_source_inode
            )
        ):
            _fail("recovery")
    _rename_noreplace_boundary(directory_fd, source, destination)
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renameat2 = libc.renameat2
    except (AttributeError, OSError):
        _fail("recovery")
    renameat2.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameat2.restype = ctypes.c_int
    _deadline_check()
    result = renameat2(
        directory_fd,
        os.fsencode(source),
        directory_fd,
        os.fsencode(destination),
        RENAME_NOREPLACE,
    )
    if result != 0:
        # EEXIST, ENOSYS and unsupported filesystems are all recovery states.
        ctypes.get_errno()
        _fail("recovery")


def _state_parts(name: str) -> tuple[str, str]:
    match = re.fullmatch(
        r"(?P<run>[0-9]+-[0-9]+)-(?P<kind>final-deploy|rollback-drill)",
        name,
    )
    if match is None:
        _fail("recovery")
    return match.group("run"), match.group("kind")


def _state_marker(run_key: str, state_kind: str) -> bytes:
    if re.fullmatch(STATE_RUN_KEY_RE, run_key) is None or state_kind not in STATE_KINDS:
        _fail("recovery")
    return json.dumps(
        {
            "schemaVersion": 1,
            "owner": OWNER,
            "runKey": run_key,
            "stateKind": state_kind,
        },
        separators=(",", ":"),
    ).encode()


def _parse_state_marker(data: bytes, run_key: str, state_kind: str) -> None:
    if len(data) > MAX_OWNER_BYTES:
        _fail("recovery")
    value = _json(data, "recovery")
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "owner",
        "runKey",
        "stateKind",
    }:
        _fail("recovery")
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != 1
        or value["owner"] != OWNER
        or value["runKey"] != run_key
        or value["stateKind"] != state_kind
        or not isinstance(value["owner"], str)
        or not isinstance(value["runKey"], str)
        or not isinstance(value["stateKind"], str)
    ):
        _fail("recovery")


def _validate_state_directory(path: str, name: str) -> tuple[str, str]:
    run_key, state_kind = _state_parts(name)
    if os.path.islink(path) or not os.path.isdir(path):
        _fail("recovery")
    info = os.stat(path, follow_symlinks=False)
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        _fail("recovery")
    _acl_is_safe(path, category="recovery")
    marker = os.path.join(path, OWNER_MARKER)
    fd, marker_info, data = _open_private_state_file(marker)
    os.close(fd)
    if (
        marker_info.st_uid != 0
        or marker_info.st_nlink != 1
        or stat.S_IMODE(marker_info.st_mode) != 0o600
    ):
        _fail("recovery")
    _parse_state_marker(data, run_key, state_kind)
    return run_key, state_kind


def _open_private_state_file(path: str) -> tuple[int, os.stat_result, bytes]:
    _check_ancestors(path, category="recovery")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        _fail("recovery")
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            _fail("recovery")
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
        data = _read_fd_bounded(fd, MAX_OWNER_BYTES)
        final = os.fstat(fd)
        if _identity(info) != _identity(final):
            _fail("recovery")
        return fd, info, data
    except Exception:
        os.close(fd)
        raise


def _open_private_state_file_at(
    directory_fd: int,
    name: str,
) -> tuple[int, os.stat_result, bytes]:
    if not name or "/" in name or "\x00" in name:
        _fail("recovery")
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        _fail("recovery")
    try:
        info = os.fstat(fd)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or stat.S_IMODE(info.st_mode) != 0o600
            or info.st_nlink != 1
        ):
            _fail("recovery")
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
        data = _read_fd_bounded(fd, MAX_OWNER_BYTES)
        final = os.fstat(fd)
        if _identity(info) != _identity(final):
            _fail("recovery")
        return fd, info, data
    except Exception:
        os.close(fd)
        raise


def _ensure_state_root(state_root: str) -> os.stat_result:
    if (
        not isinstance(state_root, str)
        or not state_root.startswith("/")
        or "\x00" in state_root
        or any(part in ("", ".", "..") for part in state_root.split("/")[1:])
    ):
        _fail("recovery")
    if os.path.lexists(state_root):
        if os.path.islink(state_root) or not os.path.isdir(state_root):
            _fail("recovery")
        info = os.stat(state_root, follow_symlinks=False)
        if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            _fail("recovery")
    else:
        _check_ancestors(state_root, category="recovery")
        _deadline_check()
        os.mkdir(state_root, 0o700)
        _deadline_check()
        os.chown(state_root, 0, 0)
        _deadline_check()
        os.chmod(state_root, 0o700)
    _check_ancestors(state_root, category="recovery")
    _acl_is_safe(state_root, category="recovery")
    return os.stat(state_root, follow_symlinks=False)


def _state_publish(state_root: str, run_key: str, state_kind: str) -> None:
    _state_marker(run_key, state_kind)
    expected_root = _ensure_state_root(state_root)
    name = f"{run_key}-{state_kind}"
    temporary = f".provider-state.{name}.tmp"
    parent_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _lock_directory(parent_fd)
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _validate_retention_state_root_fd(parent_fd)
        _timepad_publication_guard(state_root)
        _retention_interlocks_fd("", parent_fd)
        for candidate in (temporary, name):
            try:
                os.stat(candidate, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            _fail("recovery")
        _deadline_check()
        os.mkdir(temporary, 0o700, dir_fd=parent_fd)
        temporary_fd = os.open(
            temporary,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            _deadline_check()
            os.fchown(temporary_fd, 0, 0)
            _deadline_check()
            os.fchmod(temporary_fd, 0o700)
            temporary_inode = (
                os.fstat(temporary_fd).st_dev,
                os.fstat(temporary_fd).st_ino,
            )
            _write_private_at(
                temporary_fd,
                OWNER_MARKER,
                _state_marker(run_key, state_kind),
                0o600,
            )
            _deadline_check()
            os.fsync(temporary_fd)
            _deadline_check()
            os.fsync(parent_fd)
            _retention_interlocks_fd(
                "",
                parent_fd,
                allowed_temporary=temporary,
            )
            source_path_info = os.stat(
                temporary,
                dir_fd=parent_fd,
                follow_symlinks=False,
            )
            source_fd_info = os.fstat(temporary_fd)
            if (
                not _same_inode(source_path_info, source_fd_info)
                or (source_fd_info.st_dev, source_fd_info.st_ino)
                != temporary_inode
            ):
                _fail("recovery")
            _validate_state_directory_fd(temporary_fd, name)
            _timepad_publication_guard(state_root)
            _rename_noreplace(
                parent_fd,
                temporary,
                name,
                expected_source_fd=temporary_fd,
                expected_source_inode=temporary_inode,
            )
            published_fd = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            try:
                published = os.fstat(published_fd)
                if (
                    not _same_inode(published, os.fstat(temporary_fd))
                    or (published.st_dev, published.st_ino) != temporary_inode
                ):
                    _fail("recovery")
                _validate_state_directory_fd(published_fd, name)
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if not _same_inode(current, published):
                    _fail("recovery")
                _revalidate_retention_state_root_path(state_root, expected_root)
            finally:
                os.close(published_fd)
            _deadline_check()
            os.fsync(parent_fd)
        finally:
            os.close(temporary_fd)
    finally:
        os.close(parent_fd)
    _result(False, False, False, "published")


def _read_existing(path: str, source: bool = False) -> tuple[dict[str, int], bytes]:
    fd, info, data = _open_regular(path, max_bytes=MAX_CREDENTIAL_BYTES, source=source)
    try:
        return _identity(info), data
    finally:
        os.close(fd)


def _revalidate_open_source(
    path: str,
    fd: int,
    before: os.stat_result,
    expected: bytes,
) -> None:
    _deadline_check()
    current = os.fstat(fd)
    if _identity(current) != _identity(before) or current.st_size != len(expected):
        _fail("changed")
    os.lseek(fd, 0, os.SEEK_SET)
    data = bytearray()
    while len(data) <= MAX_CREDENTIAL_BYTES:
        _deadline_check()
        chunk = os.read(fd, min(65536, MAX_CREDENTIAL_BYTES + 1 - len(data)))
        if not chunk:
            break
        data.extend(chunk)
    if bytes(data) != expected:
        _fail("changed")
    final = os.fstat(fd)
    if _identity(final) != _identity(before) or final.st_size != len(expected):
        _fail("changed")
    _check_ancestors(path)
    path_info = os.stat(path, follow_symlinks=False)
    if _identity(path_info) != _identity(final):
        _fail("changed")


def _read_private(path: str) -> bytes:
    _deadline_check()
    _check_ancestors(path, category="recovery")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        _fail("recovery")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{fd}",
            follow_symlinks=True,
            category="recovery",
        )
        data = bytearray()
        while len(data) <= MAX_CREDENTIAL_BYTES:
            _deadline_check()
            chunk = os.read(fd, min(65536, MAX_CREDENTIAL_BYTES + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > MAX_CREDENTIAL_BYTES:
            _fail("recovery")
        return bytes(data)
    finally:
        os.close(fd)


def _record(tx: str, predecessor: dict[str, int], durable: dict[str, int]) -> None:
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "predecessor": predecessor,
        "durable": durable,
    }
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    _write_private(os.path.join(tx, "identity.json"), encoded, 0o600)
    fd = os.open(tx, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _deadline_check()
        os.fsync(fd)
    finally:
        os.close(fd)


def _marker(state_root: str, run_key: str) -> dict[str, Any]:
    path = os.path.join(state_root, ".provider-transaction.current")
    value = _json(_read_private(path), "recovery")
    if set(value) != {
        "schemaVersion",
        "runKey",
        "phase",
        "providerEnabled",
        "durableDisposition",
    }:
        _fail("recovery")
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != SCHEMA_VERSION
        or value["runKey"] != run_key
    ):
        _fail("recovery")
    if value["phase"] not in (
        "preparing",
        "prepared",
        "applying",
        "verifying",
        "rolling-back",
        "finalizing",
    ):
        _fail("recovery")
    if value["durableDisposition"] not in ("none", "created", "reused"):
        _fail("recovery")
    if type(value["providerEnabled"]) is not bool:
        _fail("recovery")
    return value


def _update_marker_disposition(
    state_root: str,
    run_key: str,
    enabled: bool,
    disposition: str,
) -> None:
    if disposition not in ("created", "reused"):
        _fail("recovery")
    marker_path = os.path.join(state_root, ".provider-transaction.current")
    marker = _marker(state_root, run_key)
    if (
        marker["phase"] != "preparing"
        or marker["providerEnabled"] != enabled
        or marker["durableDisposition"] != "none"
    ):
        _fail("recovery")
    marker["durableDisposition"] = disposition
    encoded = json.dumps(marker, separators=(",", ":"), sort_keys=True).encode()
    temporary = os.path.join(state_root, ".provider-transaction." + run_key + ".prepare")
    if os.path.lexists(temporary):
        _fail("recovery")
    _write_private(temporary, encoded, 0o600)
    try:
        _deadline_check()
        os.replace(temporary, marker_path)
        fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            _deadline_check()
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        if os.path.lexists(temporary):
            _deadline_check()
            os.unlink(temporary)
        _fail("recovery")


def _validate_identity(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "predecessor",
        "durable",
    }:
        _fail("recovery")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != SCHEMA_VERSION:
        _fail("recovery")
    for record in (value["predecessor"], value["durable"]):
        if not isinstance(record, dict) or set(record) != {
            "device",
            "inode",
            "mtimeNs",
            "ctimeNs",
        }:
            _fail("recovery")
        if any(
            type(record[key]) is not int or record[key] < 0
            for key in record
        ):
            _fail("recovery")


def _validate_transaction(tx: str) -> None:
    if not os.path.isdir(tx) or os.path.islink(tx):
        _fail("recovery")
    _check_ancestors(tx, category="recovery")
    info = os.stat(tx, follow_symlinks=False)
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        _fail("recovery")
    _acl_is_safe(tx, category="recovery")
    allowed = {"snapshot", "publication", "identity.json"}
    names = set(os.listdir(tx))
    if not names.issubset(allowed):
        _fail("recovery")
    if not {"snapshot", "identity.json"}.issubset(names):
        _fail("recovery")
    for name in names:
        path = os.path.join(tx, name)
        if os.path.islink(path):
            _fail("recovery")
        _acl_is_safe(path, category="recovery")


def _verify_created_publication(
    tx: str,
    destination: str,
    identity: dict[str, Any],
    snapshot: bytes,
) -> dict[str, int]:
    publication = os.path.join(tx, "publication")
    if not os.path.isfile(publication) or os.path.islink(publication):
        _fail("recovery")
    try:
        publication_identity, publication_data = _read_existing(
            publication,
            source=True,
        )
        durable_identity, durable_data = _read_existing(destination)
        publication_info = os.stat(publication, follow_symlinks=False)
        durable_info = os.stat(destination, follow_symlinks=False)
    except ProviderError as error:
        if error.category == ERRORS["recovery"]:
            raise
        _fail("recovery")
    if (
        publication_identity != durable_identity
        or identity["durable"] != durable_identity
        or publication_data != snapshot
        or durable_data != snapshot
        or publication_info.st_nlink != 2
        or publication_info.st_uid != 0
        or publication_info.st_gid != 10001
        or stat.S_IMODE(publication_info.st_mode) != 0o440
        or durable_info.st_uid != 0
        or durable_info.st_gid != 10001
        or stat.S_IMODE(durable_info.st_mode) != 0o440
    ):
        _fail("recovery")
    return durable_identity


def _witnessed_unlink(
    directory_fd: int,
    name: str,
    *,
    expected_identity: dict[str, int] | None = None,
    expected_data: bytes | None = None,
    uid: int,
    gid: int,
    mode: int,
    link_count: int,
    quarantine_name: str | None = None,
    expected_data_digest: str | None = None,
    expected_stable_identity: tuple[int, ...] | None = None,
) -> None:
    _deadline_check()
    witness_fd = (
        expected_identity.pop("_witnessFd", None)
        if expected_identity is not None
        else None
    )
    entry_fd: int | None = None

    def close_owned(fd: int | None) -> None:
        # Early witness failures occur before the main mutation finally block.
        # Cleanup must preserve RECOVERY_REQUIRED even if an injected race
        # already invalidated one descriptor.
        if fd is None:
            return
        try:
            os.close(fd)
        except OSError:
            pass

    def fail_witness() -> None:
        nonlocal entry_fd, witness_fd
        close_owned(entry_fd)
        close_owned(witness_fd)
        entry_fd = None
        witness_fd = None
        _fail("recovery")

    if expected_data is not None and expected_data_digest is not None:
        fail_witness()
    if expected_data_digest is not None and re.fullmatch(
        r"[0-9a-f]{64}",
        expected_data_digest,
    ) is None:
        fail_witness()
    if quarantine_name is not None:
        quarantine = _validate_quarantine_name(name, quarantine_name)
        try:
            os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            try:
                quarantine_info = os.stat(
                    quarantine,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except OSError:
                fail_witness()
            expected_stable = expected_stable_identity
            if expected_stable is None:
                if expected_identity is None:
                    fail_witness()
                expected_stable = (
                    expected_identity["device"],
                    expected_identity["inode"],
                    stat.S_IFREG | mode,
                    uid,
                    gid,
                    quarantine_info.st_size,
                    expected_identity["mtimeNs"],
                    link_count,
                )
            if (
                not stat.S_ISREG(quarantine_info.st_mode)
                or _stable_entry_identity(quarantine_info) != expected_stable
                or quarantine_info.st_nlink != link_count
            ):
                fail_witness()
            try:
                entry_fd = os.open(
                    quarantine,
                    os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                    dir_fd=directory_fd,
                )
            except OSError:
                fail_witness()
            try:
                opened = os.fstat(entry_fd)
                if (
                    not _same_inode(opened, quarantine_info)
                    or _stable_entry_identity(opened) != expected_stable
                    or opened.st_nlink != link_count
                    or opened.st_uid != uid
                    or opened.st_gid != gid
                    or stat.S_IMODE(opened.st_mode) != mode
                ):
                    _fail("recovery")
                _acl_is_safe(
                    f"/proc/self/fd/{entry_fd}",
                    follow_symlinks=True,
                    category="recovery",
                )
                data = _read_fd_bounded(entry_fd, MAX_WITNESS_BYTES)
                if (
                    expected_data_digest is not None
                    and _finalization_digest(data) != expected_data_digest
                ):
                    _fail("recovery")
                final_info = os.stat(
                    quarantine,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if (
                    _stable_entry_identity(os.fstat(entry_fd)) != expected_stable
                    or _stable_entry_identity(final_info) != expected_stable
                ):
                    _fail("recovery")
                _deadline_check()
                os.unlink(quarantine, dir_fd=directory_fd)
                _deadline_check()
                os.fsync(directory_fd)
                return
            finally:
                close_owned(entry_fd)
        except OSError:
            fail_witness()
        else:
            try:
                os.stat(quarantine, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                fail_witness()

    try:
        path_info = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        fail_witness()
    if (
        not stat.S_ISREG(path_info.st_mode)
        or path_info.st_uid != uid
        or path_info.st_gid != gid
        or stat.S_IMODE(path_info.st_mode) != mode
        or path_info.st_nlink != link_count
        or (
            expected_identity is not None
            and _identity(path_info) != _witness_identity(expected_identity)
        )
    ):
        fail_witness()
    try:
        entry_fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
            dir_fd=directory_fd,
        )
    except OSError:
        fail_witness()
    try:
        opened = os.fstat(entry_fd)
        if (
            _identity(opened) != _identity(path_info)
            or (
                witness_fd is not None
                and _identity(opened) != _identity(os.fstat(witness_fd))
            )
            or opened.st_uid != uid
            or opened.st_gid != gid
            or stat.S_IMODE(opened.st_mode) != mode
            or opened.st_nlink != link_count
        ):
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{entry_fd}",
            follow_symlinks=True,
            category="recovery",
        )
        if expected_data is not None:
            if _read_fd_bounded(
                entry_fd,
                max(MAX_CREDENTIAL_BYTES, len(expected_data)),
            ) != expected_data:
                _fail("recovery")
        elif expected_data_digest is not None and _finalization_digest(
            _read_fd_bounded(entry_fd, MAX_WITNESS_BYTES)
        ) != expected_data_digest:
            _fail("recovery")
        final_fd_info = os.fstat(entry_fd)
        final_path_info = os.stat(
            name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if (
            _identity(final_fd_info) != _identity(opened)
            or _identity(final_path_info) != _identity(final_fd_info)
            or (
                expected_identity is not None
                and _identity(final_path_info) != _witness_identity(expected_identity)
            )
            or final_fd_info.st_uid != uid
            or final_fd_info.st_gid != gid
            or stat.S_IMODE(final_fd_info.st_mode) != mode
            or final_path_info.st_uid != uid
            or final_path_info.st_gid != gid
            or stat.S_IMODE(final_path_info.st_mode) != mode
            or final_fd_info.st_nlink != link_count
            or final_path_info.st_nlink != link_count
        ):
            _fail("recovery")
        if expected_data is not None:
            final_before = os.fstat(entry_fd)
            final_data = _read_fd_bounded(
                entry_fd,
                max(MAX_CREDENTIAL_BYTES, len(expected_data)),
            )
            final_after = os.fstat(entry_fd)
            if (
                _identity(final_before) != _identity(final_after)
                or final_data != expected_data
            ):
                _fail("recovery")
        elif expected_data_digest is not None and _finalization_digest(
            _read_fd_bounded(entry_fd, MAX_WITNESS_BYTES)
        ) != expected_data_digest:
            _fail("recovery")
        if quarantine_name is not None:
            quarantine = _validate_quarantine_name(name, quarantine_name)
            try:
                os.stat(quarantine, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _fail("recovery")
        else:
            quarantine = None
            for _ in range(8):
                candidate = f".cleanup-{os.getpid()}-{secrets.token_hex(8)}"
                try:
                    os.stat(candidate, dir_fd=directory_fd, follow_symlinks=False)
                except FileNotFoundError:
                    quarantine = candidate
                    break
            if quarantine is None:
                _fail("recovery")
        _rename_noreplace(directory_fd, name, quarantine)
        _deadline_check()
        os.fsync(directory_fd)
        quarantine_info = os.stat(
            quarantine,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if _stable_entry_identity(quarantine_info) != _stable_entry_identity(final_fd_info):
            try:
                os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                try:
                    _deadline_check()
                    os.rename(
                        quarantine,
                        name,
                        src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd,
                    )
                except OSError:
                    pass
            _fail("recovery")
        post_rename_info = os.fstat(entry_fd)
        if (
            _stable_entry_identity(post_rename_info)
            != _stable_entry_identity(final_fd_info)
            or post_rename_info.st_uid != uid
            or post_rename_info.st_gid != gid
            or stat.S_IMODE(post_rename_info.st_mode) != mode
            or post_rename_info.st_nlink != link_count
        ):
            _fail("recovery")
        if expected_data is not None:
            if _read_fd_bounded(
                entry_fd,
                max(MAX_CREDENTIAL_BYTES, len(expected_data)),
            ) != expected_data:
                _fail("recovery")
        elif expected_data_digest is not None and _finalization_digest(
            _read_fd_bounded(entry_fd, MAX_WITNESS_BYTES)
        ) != expected_data_digest:
            _fail("recovery")
        try:
            _deadline_check()
            os.unlink(quarantine, dir_fd=directory_fd)
        except OSError:
            try:
                os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                try:
                    _deadline_check()
                    os.rename(
                        quarantine,
                        name,
                        src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd,
                    )
                except OSError:
                    pass
            _fail("recovery")
        _deadline_check()
        os.fsync(directory_fd)
        try:
            os.stat(quarantine, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        _fail("recovery")
    finally:
        close_owned(entry_fd)
        close_owned(witness_fd)


def _remove_created_destination(
    destination: str,
    expected_identity: dict[str, int],
    snapshot: bytes,
) -> None:
    parent, name = os.path.split(destination)
    if not parent or not name or "/" in name:
        _fail("recovery")
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        _lock_directory(parent_fd)
        _witnessed_unlink(
            parent_fd,
            name,
            expected_identity=expected_identity,
            expected_data=snapshot,
            uid=0,
            gid=10001,
            mode=0o440,
            link_count=2,
        )
        _deadline_check()
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _remove_transaction(
    tx: str,
    *,
    outcome: str,
    disposition: str,
    snapshot: bytes,
) -> None:
    parent, name = os.path.split(tx)
    if not parent or not name or "/" in name:
        _fail("recovery")
    parent_fd = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        _lock_directory(parent_fd)
        tx_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISDIR(tx_info.st_mode) or tx_info.st_uid != 0 or stat.S_IMODE(tx_info.st_mode) != 0o700:
            _fail("recovery")
        tx_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            if not _same_inode(os.fstat(tx_fd), tx_info):
                _fail("recovery")
            _lock_directory(tx_fd)
            names = set(os.listdir(tx_fd))
            allowed = {"snapshot", "identity.json"}
            if disposition == "created":
                allowed.add("publication")
            if not names.issubset(allowed) or not {"snapshot", "identity.json"}.issubset(names):
                _fail("recovery")
            witnesses = {
                child: _child_witness(tx_fd, child)
                for child in names
            }
            for child in ("identity.json", "snapshot", "publication"):
                if child not in names:
                    continue
                child_gid = 10001 if child == "publication" else 0
                child_mode = 0o440 if child == "publication" else 0o600
                child_links = 2 if child == "publication" and outcome == "committed" else 1
                child_identity, child_data = witnesses[child]
                _witnessed_unlink(
                    tx_fd,
                    child,
                    expected_identity=child_identity,
                    expected_data=snapshot if child == "publication" else child_data,
                    uid=0,
                    gid=child_gid,
                    mode=child_mode,
                    link_count=child_links,
                )
            if os.listdir(tx_fd):
                _fail("recovery")
        finally:
            os.close(tx_fd)
        final_tx_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if not _same_inode(final_tx_info, tx_info):
            _fail("recovery")
        _deadline_check()
        os.rmdir(name, dir_fd=parent_fd)
        _deadline_check()
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


def _prepare(run_key: str, state_root: str, root: str, inspect_data: bytes) -> tuple[bool, bool, bool]:
    inspect, previous = _inspect_records(inspect_data)
    enabled, _ = _provider_state(inspect)
    if previous is not None:
        if _effective_tuple(inspect) != _effective_tuple(previous):
            _fail("provider")
    present, read_only, source = _provider_mount(
        inspect,
        enabled,
        allow_external_source=True,
    )
    if not enabled:
        _result(False, False, False, "prepared")
        return False, False, False
    if source is None:
        _fail("provider")
    parent = _rooted(HOST_CREDENTIAL_PARENT, root)
    destination = _rooted(HOST_CREDENTIAL_PATH, root)
    source = _rooted(source, root) if root else source
    _ensure_parent(parent)
    source_fd, source_info, source_data = _open_regular(
        source,
        max_bytes=MAX_CREDENTIAL_BYTES,
        source=True,
    )
    try:
        source_identity = _identity(source_info)
        _validate_credential(source_data)
        _revalidate_open_source(source, source_fd, source_info, source_data)
        tx = _transaction(parent, run_key)
        if os.path.lexists(tx):
            _fail("durable")
        _deadline_check()
        os.mkdir(tx, 0o700)
        _deadline_check()
        os.chown(tx, 0, 0)
        _deadline_check()
        os.chmod(tx, 0o700)
        try:
            _write_private(os.path.join(tx, "snapshot"), source_data, 0o600)
            _revalidate_open_source(source, source_fd, source_info, source_data)
            if os.path.lexists(destination):
                if os.path.islink(destination):
                    _fail("durable")
                durable_identity, durable_data = _read_existing(destination)
                _validate_credential(durable_data)
                if durable_data != source_data:
                    _fail("durable")
                disposition = "reused"
            else:
                publication = os.path.join(tx, "publication")
                _write_private(publication, source_data, 0o440, gid=10001)
                try:
                    _deadline_check()
                    os.link(publication, destination, follow_symlinks=False)
                except FileExistsError:
                    _fail("durable")
                durable_identity, durable_data = _read_existing(destination)
                if durable_data != source_data:
                    _fail("changed")
                publication_info = os.stat(publication, follow_symlinks=False)
                destination_info = os.stat(destination, follow_symlinks=False)
                if (
                    _identity(publication_info) != _identity(destination_info)
                    or publication_info.st_nlink != 2
                ):
                    _fail("changed")
                disposition = "created"
            _revalidate_open_source(source, source_fd, source_info, source_data)
            _record(tx, source_identity, durable_identity)
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                _deadline_check()
                os.fsync(fd)
            finally:
                os.close(fd)
            _update_marker_disposition(state_root, run_key, enabled, disposition)
        except Exception:
            # Never remove a published destination here.  Bash recovery/retention
            # must prove ownership before cleanup after a failed publication.
            raise
        _result(True, present, read_only, "prepared")
        return True, present, read_only
    finally:
        os.close(source_fd)


def _verify(
    run_key: str,
    root: str,
    inspect_data: bytes,
    phase: str,
    state_root: str = "",
) -> None:
    if phase not in ("predecessor", "candidate", "rollback"):
        _fail("provider")
    inspect, previous = _inspect_records(inspect_data)
    enabled, _ = _provider_state(inspect)
    if previous is not None and _effective_tuple(inspect) != _effective_tuple(previous):
        _fail("provider")
    present, read_only, source = _provider_mount(
        inspect,
        enabled,
        allow_external_source=phase in ("predecessor", "rollback"),
    )
    identity: dict[str, Any] = {}
    disposition = "none"
    if state_root:
        marker = _marker(state_root, run_key)
        expected_phases = {
            "predecessor": {"prepared"},
            "candidate": {"verifying"},
            "rollback": {"rolling-back"},
        }
        if marker["phase"] not in expected_phases[phase]:
            _fail("recovery")
        if marker["providerEnabled"] != enabled:
            _fail("recovery")
        disposition = marker["durableDisposition"]
        if enabled and marker["durableDisposition"] not in ("created", "reused"):
            _fail("recovery")
        if not enabled and marker["durableDisposition"] != "none":
            _fail("recovery")
    if enabled:
        if source is None:
            _fail("provider")
        if phase == "candidate" and source != HOST_CREDENTIAL_PATH:
            _fail("provider")
        if phase == "predecessor" and previous is not None:
            previous_enabled, _ = _provider_state(previous)
            previous_mount = _provider_mount(
                previous,
                previous_enabled,
                allow_external_source=True,
            )
            if (
                previous_enabled != enabled
                or _effective_tuple(previous) != _effective_tuple(inspect)
                or previous_mount != (present, read_only, source)
            ):
                _fail("changed")
        if phase == "rollback" and previous is not None:
            previous_present, previous_read_only, previous_source = (
                _provider_mount(
                    previous,
                    _provider_state(previous)[0],
                    allow_external_source=True,
                )
            )
            if (
                previous_present != present
                or previous_read_only != read_only
                or previous_source != source
            ):
                _fail("provider")
        destination = _rooted(HOST_CREDENTIAL_PATH, root)
        durable_identity, durable = _read_existing(destination)
        _validate_credential(durable)
        tx = _transaction(_rooted(HOST_CREDENTIAL_PARENT, root), run_key)
        snapshot_path = os.path.join(tx, "snapshot")
        if phase in ("predecessor", "candidate", "rollback") and state_root:
            _validate_transaction(tx)
            identity = _json(_read_private(os.path.join(tx, "identity.json")), "recovery")
            _validate_identity(identity)
        snapshot = _read_private(snapshot_path)
        if state_root and disposition == "created":
            _verify_created_publication(tx, destination, identity, snapshot)
        elif state_root and identity["durable"] != durable_identity:
            _fail("changed")
        if snapshot != durable:
            _fail("changed")
        if phase == "predecessor" and state_root:
            if source is None:
                _fail("changed")
            source_identity, source_data = _read_existing(source, source=True)
            if (
                identity["predecessor"] != source_identity
                or source_data != snapshot
            ):
                _fail("changed")
    _result(enabled, present, read_only, "verified")


def _finish(run_key: str, state_root: str, root: str, outcome: str, inspect_data: bytes) -> None:
    if outcome not in ("committed", "rolled-back"):
        _fail("provider")
    inspect = _inspect(inspect_data)
    enabled, _ = _provider_state(inspect)
    present, read_only, source = _provider_mount(
        inspect,
        enabled,
        allow_external_source=outcome == "rolled-back",
    )
    parent = _rooted(HOST_CREDENTIAL_PARENT, root)
    tx = _transaction(parent, run_key)
    marker = _marker(state_root, run_key)
    disposition = marker["durableDisposition"]
    if marker["providerEnabled"] != enabled:
        _fail("recovery")
    if enabled and disposition not in ("created", "reused"):
        _fail("recovery")
    if disposition != "none" and (
        not os.path.isdir(tx) or os.path.islink(tx)
    ):
        _fail("recovery")
    if disposition == "none" and os.path.lexists(tx):
        _fail("recovery")
    if os.path.isdir(tx) and not os.path.islink(tx):
        _validate_transaction(tx)
        identity = _json(_read_private(os.path.join(tx, "identity.json")), "recovery")
        _validate_identity(identity)
        snapshot = _read_private(os.path.join(tx, "snapshot"))
        destination = _rooted(HOST_CREDENTIAL_PATH, root)
        if disposition == "created":
            durable_identity = _verify_created_publication(
                tx,
                destination,
                identity,
                snapshot,
            )
        else:
            durable_identity, durable_data = _read_existing(destination)
            if identity["durable"] != durable_identity or durable_data != snapshot:
                _fail("recovery")
        if enabled:
            if source is None:
                _fail("recovery")
            source_identity, source_data = _read_existing(source, source=True)
            if outcome == "rolled-back" and (
                identity["predecessor"] != source_identity
                or source_data != snapshot
            ):
                _fail("recovery")
            if outcome == "rolled-back" and disposition == "created":
                if source_identity == durable_identity:
                    _fail("recovery")
        if outcome == "rolled-back" and disposition == "created":
            _remove_created_destination(destination, durable_identity, snapshot)
        _remove_transaction(
            tx,
            outcome=outcome,
            disposition=disposition,
            snapshot=snapshot,
        )
    _result(enabled, present, read_only, outcome)


def _check() -> None:
    required = ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK", "O_NOATIME")
    if any(not hasattr(os, name) for name in required):
        _fail("prerequisite")
    if not hasattr(os, "getxattr"):
        _fail("prerequisite")
    if not hasattr(os, "link") or not hasattr(os, "fsync") or not hasattr(os.stat_result, "st_mtime_ns"):
        _fail("prerequisite")
    try:
        getattr(ctypes.CDLL(None, use_errno=True), "renameat2")
    except (AttributeError, OSError):
        _fail("prerequisite")
    _result(False, False, False, "checked")


def _retention_reference(path: str) -> str:
    if (
        not isinstance(path, str)
        or not path.startswith("/")
        or "\x00" in path
        or any(part in ("", ".", "..") for part in path.split("/")[1:])
    ):
        _fail("recovery")
    current = "/"
    for component in path.split("/")[1:]:
        current = os.path.join(current, component)
        if os.path.islink(current):
            _fail("recovery")
    if os.path.lexists(path) and os.path.realpath(path) != path:
        _fail("recovery")
    return path


def _open_reference_parent(path: str) -> tuple[int, str]:
    components = path.split("/")[1:]
    if not components or any(not component for component in components):
        _fail("recovery")
    parent_fd = os.open(
        "/",
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        for component in components[:-1]:
            next_fd = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            os.close(parent_fd)
            parent_fd = next_fd
        return parent_fd, components[-1]
    except Exception:
        os.close(parent_fd)
        raise


def _protected_reference_witness(
    path: str,
) -> tuple[tuple[int, ...], bytes | None] | None:
    _retention_reference(path)
    try:
        parent_fd, name = _open_reference_parent(path)
    except FileNotFoundError:
        return None
    try:
        try:
            info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(info.st_mode):
            _fail("recovery")
        data: bytes | None = None
        if stat.S_ISREG(info.st_mode):
            fd = os.open(
                name,
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                dir_fd=parent_fd,
            )
            try:
                before = os.fstat(fd)
                if not _same_inode(before, info):
                    _fail("recovery")
                data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
                after = os.fstat(fd)
                if _stable_entry_identity(before) != _stable_entry_identity(after):
                    _fail("recovery")
                info = before
            finally:
                os.close(fd)
        return _stable_entry_identity(info), data
    finally:
        os.close(parent_fd)


def _revalidate_protected_references(
    paths: Iterable[str],
    witnesses: Iterable[tuple[tuple[int, ...], bytes | None] | None],
) -> None:
    for path, witness in zip(paths, witnesses):
        if _protected_reference_witness(path) != witness:
            _fail("recovery")


def _reject_protected_reference_aliases(
    witnesses: Iterable[tuple[tuple[int, ...], bytes | None] | None],
    state_info: os.stat_result,
    child_witnesses: dict[str, tuple[dict[str, int], bytes]],
) -> None:
    state_inode = (state_info.st_dev, state_info.st_ino)
    child_inodes = {
        (identity["device"], identity["inode"])
        for identity, _ in child_witnesses.values()
    }
    for witness in witnesses:
        if witness is None:
            continue
        reference_inode = (witness[0][0], witness[0][1])
        if reference_inode == state_inode or reference_inode in child_inodes:
            _fail("recovery")


def _owned_state(path: str, name: str, *, require_terminal: bool) -> tuple[str, str]:
    run_key, state_kind = _validate_state_directory(path, name)
    if require_terminal:
        _validate_terminal_state(path, name)
    return run_key, state_kind


def _validate_state_directory_fd(directory_fd: int, name: str) -> tuple[str, str]:
    run_key, state_kind = _state_parts(name)
    info = os.fstat(directory_fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        _fail("recovery")
    _acl_is_safe(
        f"/proc/self/fd/{directory_fd}",
        follow_symlinks=True,
        category="recovery",
    )
    marker_fd, marker_info, data = _open_private_state_file_at(
        directory_fd,
        OWNER_MARKER,
    )
    os.close(marker_fd)
    if (
        marker_info.st_uid != 0
        or marker_info.st_nlink != 1
        or stat.S_IMODE(marker_info.st_mode) != 0o600
    ):
        _fail("recovery")
    _parse_state_marker(data, run_key, state_kind)
    return run_key, state_kind


def _parse_terminal_state_data(data: bytes, name: str) -> tuple[str, bool]:
    value = _json(data, "recovery")
    run_key, _ = _state_parts(name)
    if set(value) != {
        "schemaVersion",
        "runKey",
        "outcome",
        "providerEnabled",
    }:
        _fail("recovery")
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != SCHEMA_VERSION
        or type(value["runKey"]) is not str
        or value["runKey"] != run_key
        or type(value["outcome"]) is not str
        or value["outcome"] not in ("committed", "rolled-back")
        or type(value["providerEnabled"]) is not bool
    ):
        _fail("recovery")
    return value["outcome"], value["providerEnabled"]


def _validate_terminal_state(path: str, name: str) -> None:
    terminal = os.path.join(path, "terminal.json")
    terminal_fd, terminal_info, terminal_data = _open_private_state_file(terminal)
    os.close(terminal_fd)
    if terminal_info.st_uid != 0 or terminal_info.st_nlink != 1:
        _fail("recovery")
    _parse_terminal_state_data(terminal_data, name)


def _validate_terminal_state_fd(directory_fd: int, name: str) -> None:
    terminal_fd, terminal_info, terminal_data = _open_private_state_file_at(
        directory_fd,
        "terminal.json",
    )
    os.close(terminal_fd)
    if terminal_info.st_uid != 0 or terminal_info.st_nlink != 1:
        _fail("recovery")
    _parse_terminal_state_data(terminal_data, name)


def _owned_state_fd(
    directory_fd: int,
    name: str,
    *,
    require_terminal: bool,
) -> tuple[str, str]:
    result = _validate_state_directory_fd(directory_fd, name)
    if require_terminal:
        _validate_terminal_state_fd(directory_fd, name)
    return result


def _iter_directory_fd_names(directory_fd: int) -> Iterable[str]:
    _deadline_check()
    with os.scandir(f"/proc/self/fd/{directory_fd}") as entries:
        for entry in entries:
            _deadline_check()
            yield entry.name


def _open_optional_directory_reference(path: str) -> int | None:
    _retention_reference(path)
    try:
        parent_fd, name = _open_reference_parent(path)
    except FileNotFoundError:
        return None
    try:
        try:
            expected = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if (
            stat.S_ISLNK(expected.st_mode)
            or not stat.S_ISDIR(expected.st_mode)
            or expected.st_uid != 0
            or stat.S_IMODE(expected.st_mode) != 0o700
        ):
            _fail("recovery")
        directory_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        opened = os.fstat(directory_fd)
        if not _same_inode(opened, expected):
            os.close(directory_fd)
            _fail("recovery")
        _acl_is_safe(
            f"/proc/self/fd/{directory_fd}",
            follow_symlinks=True,
            category="recovery",
        )
        return directory_fd
    finally:
        os.close(parent_fd)


def _retention_interlocks_fd(
    root: str,
    state_root_fd: int,
    *,
    state_root: str | None = None,
    deploy_lock_fd: int | None = None,
    allowed_temporary: str | None = None,
) -> str | None:
    guard = None
    if state_root is not None:
        guard = _timepad_retention_guard(state_root, state_root_fd, deploy_lock_fd)
    parent = _rooted(HOST_CREDENTIAL_PARENT, root)
    for name in (
        ".provider-transaction.current",
        ".smtp-transaction.current",
    ):
        try:
            os.stat(name, dir_fd=state_root_fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        else:
            _fail("recovery")
    for name in _iter_directory_fd_names(state_root_fd):
        if name.startswith(".provider-transaction.") or name.startswith(
            ".provider-state."
        ):
            if allowed_temporary is not None and name == allowed_temporary:
                continue
            _fail("recovery")
    parent_fd = _open_optional_directory_reference(parent)
    if parent_fd is None:
        return guard
    try:
        for name in _iter_directory_fd_names(parent_fd):
            if name.startswith(".transaction-"):
                _fail("recovery")
    finally:
        os.close(parent_fd)
    return guard


def _timepad_state_module():
    spec = importlib.util.spec_from_file_location(
        "test_vps_timepad_state_for_provider_retention",
        pathlib.Path(__file__).with_name("test_vps_timepad_state.py"),
    )
    if spec is None or spec.loader is None:
        _fail("prerequisite")
    module = sys.modules.get(spec.name)
    if module is None:
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        try:
            spec.loader.exec_module(module)
        except (ImportError, OSError, SyntaxError):
            sys.modules.pop(spec.name, None)
            _fail("prerequisite")
    return module


def _timepad_retention_guard(
    state_root: str,
    state_root_fd: int,
    deploy_lock_fd: int | None,
) -> str | None:
    """Fail closed on guard state and identify the latest run that retention must keep."""
    try:
        root_path_info = os.stat(state_root, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    root_fd_info = os.fstat(state_root_fd)
    if not _same_inode(root_path_info, root_fd_info):
        _fail("recovery")
    try:
        names = set(_iter_directory_fd_names(state_root_fd))
    except OSError:
        _fail("recovery")
    if any(name.startswith(".timepad-bootstrap-") for name in names):
        _fail("recovery")
    try:
        os.stat("timepad-guard", dir_fd=state_root_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError:
        _fail("recovery")

    module = _timepad_state_module()
    try:
        if deploy_lock_fd is None:
            _, current = module.read_guard(state_root)
        else:
            _, current = module.read_guard(state_root, deploy_lock_fd=deploy_lock_fd)
    except (module.GuardError, OSError, ValueError, TypeError, AttributeError):
        _fail("recovery")
    try:
        final_root_path_info = os.stat(state_root, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    if not _same_inode(final_root_path_info, os.fstat(state_root_fd)):
        _fail("recovery")
    if current["phase"] == "READY":
        if current.get("operationEpoch") != 0 or current.get("ownedRun") is not None:
            _fail("recovery")
        return None
    if current["phase"] not in {"COMMITTED", "ROLLED_BACK"}:
        _fail("recovery")
    owned_run = current["ownedRun"]
    if not isinstance(owned_run, str):
        _fail("recovery")
    try:
        _state_parts(owned_run)
    except ProviderError:
        _fail("recovery")
    return owned_run


def _timepad_publication_guard(state_root: str) -> None:
    """A new run cannot obscure an unresolved incident or bootstrap attempt."""
    guard_present = False
    with os.scandir(state_root) as entries:
        for entry in entries:
            _deadline_check()
            if entry.name.startswith(".timepad-bootstrap-"):
                _fail("recovery")
            guard_present |= entry.name == "timepad-guard"
    if not guard_present:
        return
    module = _timepad_state_module()
    try:
        _, current = module._read_guard_locked(state_root)
    except (module.GuardError, OSError, ValueError, TypeError, KeyError):
        _fail("recovery")
    if current["phase"] not in {"READY", "COMMITTED", "ROLLED_BACK"}:
        _fail("recovery")


def _retention_guard_protects_state(name: str, latest_run: str | None) -> bool:
    return latest_run is not None and name == latest_run


def _retention_interlocks(
    root: str,
    state_root: str,
    deploy_lock_fd: int | None = None,
) -> str | None:
    state_root_fd = os.open(
        state_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        return _retention_interlocks_fd(
            root,
            state_root_fd,
            state_root=state_root,
            deploy_lock_fd=deploy_lock_fd,
        )
    finally:
        os.close(state_root_fd)


def _validate_retention_state_root_path(state_root: str) -> os.stat_result:
    if (
        not isinstance(state_root, str)
        or not state_root.startswith("/")
        or "\x00" in state_root
        or any(part in ("", ".", "..") for part in state_root.split("/")[1:])
        or not os.path.lexists(state_root)
        or os.path.islink(state_root)
        or not os.path.isdir(state_root)
    ):
        _fail("recovery")
    info = os.stat(state_root, follow_symlinks=False)
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        _fail("recovery")
    _check_ancestors(state_root, category="recovery")
    _acl_is_safe(state_root, category="recovery")
    return info


def _validate_retention_state_root_fd(fd: int) -> None:
    info = os.fstat(fd)
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        _fail("recovery")
    _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")


def _revalidate_retention_state_root_path(
    state_root: str,
    expected_root: os.stat_result,
) -> None:
    try:
        current = os.stat(state_root, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    if not _same_inode(current, expected_root):
        _fail("recovery")


def _retention_classify(
    root: str,
    state_root: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
    deploy_lock_fd: int | None = None,
) -> list[str]:
    if (
        not isinstance(state_root, str)
        or not state_root.startswith("/")
        or "\x00" in state_root
        or any(part in ("", ".", "..") for part in state_root.split("/")[1:])
    ):
        _fail("recovery")
    expected_root = _validate_retention_state_root_path(state_root)
    parent_fd = os.open(
        state_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _lock_directory(parent_fd)
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _validate_retention_state_root_fd(parent_fd)
        latest_run = _retention_interlocks_fd(
            root,
            parent_fd,
            state_root=state_root,
            deploy_lock_fd=deploy_lock_fd,
        )
        references = list(protected_paths)
        reference_witnesses = [
            _protected_reference_witness(path) for path in references
        ]
        explicit_states: set[str] = set()
        for path in protected_states:
            witness = _protected_reference_witness(path)
            if (
                os.path.dirname(path.rstrip("/")) != state_root.rstrip("/")
                or witness is None
                or not stat.S_ISDIR(witness[0][2])
            ):
                _fail("recovery")
            explicit_states.add(os.path.normpath(path))
        _revalidate_protected_references(references, reference_witnesses)
        owned_states: list[str] = []
        encoded_size = len(
            b'{"schemaVersion":1,"outcome":"retention-safe","ownedStates":['
        ) + len(b"]}\n")
        for name in _iter_directory_fd_names(parent_fd):
            if re.fullmatch(r"[0-9]+-[0-9]+-(?:rollback-drill|final-deploy)", name):
                state_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if stat.S_ISLNK(state_info.st_mode) or not stat.S_ISDIR(
                    state_info.st_mode
                ):
                    _fail("recovery")
                state_fd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=parent_fd,
                )
                try:
                    if not _same_inode(os.fstat(state_fd), state_info):
                        _fail("recovery")
                    try:
                        os.stat(
                            OWNER_MARKER,
                            dir_fd=state_fd,
                            follow_symlinks=False,
                        )
                    except FileNotFoundError:
                        # An absent marker is an unowned legacy state.  Its
                        # contents are deliberately opaque and never
                        # participate in retention.
                        continue
                    _owned_state_fd(state_fd, name, require_terminal=True)
                    if _retention_guard_protects_state(name, latest_run):
                        continue
                    child_names = _bounded_retention_children(state_fd)
                    if child_names is not None:
                        encoded_name = json.dumps(
                            name,
                            separators=(",", ":"),
                        ).encode()
                        additional = len(encoded_name) + (
                            1 if owned_states else 0
                        )
                        if encoded_size + additional > MAX_INSPECTION_BYTES:
                            _fail("recovery")
                        encoded_size += additional
                        owned_states.append(name)
                    if not _same_inode(os.fstat(state_fd), state_info):
                        _fail("recovery")
                finally:
                    os.close(state_fd)
                continue
            state_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if stat.S_ISLNK(state_info.st_mode):
                _fail("recovery")
            if not stat.S_ISDIR(state_info.st_mode):
                continue
            if name.startswith(".provider-state."):
                _fail("recovery")
            state_fd = os.open(
                name,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            try:
                if not _same_inode(os.fstat(state_fd), state_info):
                    _fail("recovery")
                try:
                    os.stat(
                        OWNER_MARKER,
                        dir_fd=state_fd,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    pass
                else:
                    _fail("recovery")
                if not _same_inode(os.fstat(state_fd), state_info):
                    _fail("recovery")
            finally:
                os.close(state_fd)
            path = os.path.join(state_root, name)
            if os.path.normpath(path) in explicit_states:
                continue
            for reference in references:
                if reference == path or reference.startswith(path + "/"):
                    # The caller resolves Docker/Compose references and passes
                    # them here.  A component boundary is required so a state
                    # named "1-2" cannot protect or match "1-20".
                    break
    finally:
        os.close(parent_fd)
    return sorted(owned_states)


def _retention_list(
    root: str,
    state_root: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
    deploy_lock_fd: int | None = None,
) -> None:
    owned_states = _retention_classify(
        root,
        state_root,
        protected_paths,
        protected_states,
        deploy_lock_fd=deploy_lock_fd,
    )
    encoded = json.dumps(
        {
            "schemaVersion": 1,
            "outcome": "retention-safe",
            "ownedStates": owned_states,
        },
        separators=(",", ":"),
    ).encode()
    if len(encoded) > MAX_INSPECTION_BYTES:
        _fail("recovery")
    _deadline_check()
    sys.stdout.buffer.write(encoded + b"\n")


def _retention_check(
    root: str,
    state_root: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
    deploy_lock_fd: int | None = None,
) -> None:
    _retention_classify(
        root,
        state_root,
        protected_paths,
        protected_states,
        deploy_lock_fd=deploy_lock_fd,
    )
    _result(False, False, False, "retention-safe")


RETENTION_CHILDREN = frozenset(
    {
        "terminal.json",
        OWNER_MARKER,
        "provider-finalization.json",
        "timepad-prepared.json",
        "timepad-resources.json",
        "timepad-resource-request.json",
        "timepad-create-completion.json",
        "timepad-replacement-completion.json",
        "timepad-commit-witness.json",
        "previous-active-compose.yml",
        "previous-active-compose.identity",
        "previous-active-runtime.yml",
        "previous-active-runtime.identity",
        "candidate-active-compose.yml",
        "candidate-active-compose.identity",
        "candidate-active-runtime.yml",
        "candidate-active-runtime.identity",
        "had-active-compose",
        "had-active-runtime",
        "previous-image",
        "previous-image-id",
        "previous-revision",
        "previous-version",
        "previous-runtime-config-hash",
        "target-runtime.override.yml",
        "predecessor.json",
        "candidate.json",
        "final.json",
        "rollback.json",
        "frozen-assets.json",
        "config.env.production",
        "config.env.production.identity",
        "config.env.target",
        "config.env.target.identity",
        "config.env.previous",
        "config.env.previous.identity",
        "config.base-compose.yml",
        "config.base-compose.yml.identity",
    }
)


def _bounded_retention_children(directory_fd: int) -> set[str] | None:
    names: set[str] = set()
    for name in _iter_directory_fd_names(directory_fd):
        if name not in RETENTION_CHILDREN:
            return None
        names.add(name)
    return names


def _retention_delete(
    state_root: str,
    state_path: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
    deploy_lock_fd: int | None = None,
) -> None:
    if (
        not isinstance(state_root, str)
        or not state_root.startswith("/")
        or "\x00" in state_root
        or any(part in ("", ".", "..") for part in state_root.split("/")[1:])
        or not isinstance(state_path, str)
        or not state_path.startswith("/")
        or "\x00" in state_path
        or any(part in ("", ".", "..") for part in state_path.split("/")[1:])
    ):
        _fail("recovery")
    name = os.path.basename(state_path)
    if re.fullmatch(r"[0-9]+-[0-9]+-(?:rollback-drill|final-deploy)", name) is None:
        _fail("recovery")
    state_norm = os.path.normpath(state_path)
    root_norm = os.path.normpath(state_root)
    if os.path.dirname(state_norm) != root_norm:
        _fail("recovery")
    references = list(protected_paths)
    reference_witnesses = [
        _protected_reference_witness(path) for path in references
    ]
    protected_state_paths = list(protected_states)
    protected_state_witnesses: list[
        tuple[tuple[int, ...], bytes | None] | None
    ] = []
    for protected in protected_state_paths:
        witness = _protected_reference_witness(protected)
        if (
            os.path.dirname(protected.rstrip("/")) != root_norm
            or witness is None
            or not stat.S_ISDIR(witness[0][2])
        ):
            _fail("recovery")
        protected_state_witnesses.append(witness)
        protected_norm = os.path.normpath(protected)
        if (
            protected_norm == state_norm
            or protected_norm.startswith(state_norm + os.sep)
            or state_norm.startswith(protected_norm + os.sep)
        ):
            _fail("recovery")
    for reference in references:
        reference_norm = os.path.normpath(reference)
        if (
            reference_norm == state_norm
            or reference_norm.startswith(state_norm + os.sep)
            or state_norm.startswith(reference_norm + os.sep)
        ):
            _fail("recovery")
    expected_root = _validate_retention_state_root_path(state_root)
    parent_fd = os.open(
        state_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _lock_directory(parent_fd)
        if not _same_inode(os.fstat(parent_fd), expected_root):
            _fail("recovery")
        _validate_retention_state_root_fd(parent_fd)
        latest_run = _retention_interlocks_fd(
            "",
            parent_fd,
            state_root=state_root,
            deploy_lock_fd=deploy_lock_fd,
        )
        if _retention_guard_protects_state(name, latest_run):
            _fail("recovery")
        _revalidate_protected_references(references, reference_witnesses)
        _revalidate_protected_references(
            protected_state_paths,
            protected_state_witnesses,
        )
        _revalidate_retention_state_root_path(state_root, expected_root)
        state_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (
            not stat.S_ISDIR(state_info.st_mode)
            or state_info.st_uid != 0
            or stat.S_IMODE(state_info.st_mode) != 0o700
        ):
            _fail("recovery")
        state_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        witnesses: dict[str, tuple[dict[str, int], bytes]] = {}
        try:
            if not _same_inode(os.fstat(state_fd), state_info):
                _fail("recovery")
            _lock_directory(state_fd)
            if not _same_inode(os.fstat(state_fd), state_info):
                _fail("recovery")
            _validate_state_directory_fd(state_fd, name)
            _validate_terminal_state_fd(state_fd, name)
            _revalidate_protected_references(references, reference_witnesses)
            _revalidate_protected_references(
                protected_state_paths,
                protected_state_witnesses,
            )
            names = _bounded_retention_children(state_fd)
            if not names:
                _fail("recovery")
            if OWNER_MARKER not in names or "terminal.json" not in names:
                _fail("recovery")
            for child in names:
                child_info = os.stat(child, dir_fd=state_fd, follow_symlinks=False)
                if (
                    not stat.S_ISREG(child_info.st_mode)
                    or child_info.st_uid != 0
                    or stat.S_IMODE(child_info.st_mode) != 0o600
                    or child_info.st_nlink != 1
                ):
                    _fail("recovery")
                witnesses[child] = _child_witness(state_fd, child)
            # Re-parse the bytes captured by the deletion witnesses.  The
            # earlier path-based validation only admits the state; it must not
            # authorize deletion after a child replacement.  Semantic
            # admission and unlink authorization therefore share these exact
            # descriptor-backed bytes and identities.
            _parse_state_marker(
                witnesses[OWNER_MARKER][1],
                *_state_parts(name),
            )
            _parse_terminal_state_data(witnesses["terminal.json"][1], name)
            _reject_protected_reference_aliases(
                [*reference_witnesses, *protected_state_witnesses],
                state_info,
                witnesses,
            )
            quarantine = f".provider-state.{name}.tmp"
            try:
                os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _fail("recovery")
            latest_run = _retention_interlocks_fd(
                "",
                parent_fd,
                state_root=state_root,
                deploy_lock_fd=deploy_lock_fd,
            )
            if _retention_guard_protects_state(name, latest_run):
                _fail("recovery")
            current_state = os.stat(
                name,
                dir_fd=parent_fd,
                follow_symlinks=False,
            )
            if not _same_inode(current_state, state_info):
                _fail("recovery")
            _revalidate_protected_references(references, reference_witnesses)
            _revalidate_protected_references(
                protected_state_paths,
                protected_state_witnesses,
            )
            _rename_noreplace(parent_fd, name, quarantine)
            _deadline_check()
            os.fsync(parent_fd)
            _retention_interlocks_fd(
                "",
                parent_fd,
                state_root=state_root,
                deploy_lock_fd=deploy_lock_fd,
                allowed_temporary=quarantine,
            )
            try:
                os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _fail("recovery")
            quarantine_fd = os.open(
                quarantine,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            try:
                if (
                    not _same_inode(os.fstat(quarantine_fd), state_info)
                    or not _same_inode(os.fstat(quarantine_fd), os.fstat(state_fd))
                ):
                    _fail("recovery")
                # state_fd already holds the descriptor lock for this inode;
                # reopening it after the no-replace move would deadlock on
                # Linux flock semantics.
                for child in sorted(names - {OWNER_MARKER}):
                    child_identity, child_data = witnesses[child]
                    _witnessed_unlink(
                        quarantine_fd,
                        child,
                        expected_identity=child_identity,
                        expected_data=child_data,
                        uid=0,
                        gid=0,
                        mode=0o600,
                        link_count=1,
                    )
                    _deadline_check()
                    os.fsync(quarantine_fd)
                child_identity, child_data = witnesses[OWNER_MARKER]
                _witnessed_unlink(
                    quarantine_fd,
                    OWNER_MARKER,
                    expected_identity=child_identity,
                    expected_data=child_data,
                    uid=0,
                    gid=0,
                    mode=0o600,
                    link_count=1,
                )
                _deadline_check()
                os.fsync(quarantine_fd)
                if next(_iter_directory_fd_names(quarantine_fd), None) is not None:
                    _fail("recovery")
            finally:
                os.close(quarantine_fd)
            _deadline_check()
            os.rmdir(quarantine, dir_fd=parent_fd)
            _deadline_check()
            os.fsync(parent_fd)
        finally:
            _close_owned_witnesses(witnesses.values())
            os.close(state_fd)
    finally:
        os.close(parent_fd)
    _result(False, False, False, "retention-safe")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument(
        "command",
        choices=(
            "check",
            "check-image",
            "observe",
            "prepare",
            "verify",
            "finish",
            "prepare-finalization",
            "finish-committed-resume",
            "live-resume",
            "absence-resume",
            "prepare-transition-proof",
            "runtime-request-proof",
            "resource-admission",
            "state-publish",
            "retention-list",
            "retention-check",
            "retention-delete",
        ),
    )
    parser.add_argument("--run-key", default="")
    parser.add_argument("--state-root", default="/var/lib/meet-test-vps-deploy")
    parser.add_argument("--phase", default="")
    parser.add_argument("--outcome", default="")
    parser.add_argument("--protected-path", action="append", default=[])
    parser.add_argument("--protected-state", action="append", default=[])
    parser.add_argument("--retention-state", default="")
    parser.add_argument("--state-kind", default="")
    parser.add_argument("--deploy-lock-fd", type=int)
    parser.add_argument("--execution-attempt")
    parser.add_argument("--execution-grant")
    parser.add_argument("--deadline-ns", type=int)
    return parser


def _dispatch(args: argparse.Namespace) -> None:
    if args.command == "check":
        _check()
    elif args.command == "check-image":
        _image_admission(_inspect(_bounded_stdin(MAX_INSPECTION_BYTES)))
        _result(False, False, False, "checked")
    elif args.command == "observe":
        inspect = _inspect(_bounded_stdin(MAX_INSPECTION_BYTES))
        enabled, _ = _provider_state(inspect)
        present, read_only, _ = _provider_mount(
            inspect,
            enabled,
            allow_external_source=True,
        )
        _result(enabled, present, read_only, "observed")
    elif args.command == "prepare":
        _run_key(args.run_key)
        _prepare(args.run_key, args.state_root, "", _bounded_stdin(MAX_INSPECTION_BYTES))
    elif args.command == "verify":
        _run_key(args.run_key)
        _verify(
            args.run_key,
            "",
            _bounded_stdin(MAX_INSPECTION_BYTES),
            args.phase,
            args.state_root,
        )
    elif args.command == "finish":
        _run_key(args.run_key)
        _finish(
            args.run_key,
            args.state_root,
            "",
            args.outcome,
            _bounded_stdin(MAX_INSPECTION_BYTES),
        )
    elif args.command == "prepare-finalization":
        _run_key(args.run_key)
        _prepare_committed_finalization(
            args.run_key,
            args.state_root,
            args.state_kind,
            _bounded_stdin(MAX_INSPECTION_BYTES),
            args.active_deploy_lock_fd,
        )
    elif args.command == "finish-committed-resume":
        _run_key(args.run_key)
        _finish_committed_resume(
            args.run_key,
            args.state_root,
            args.state_kind,
            _bounded_stdin(MAX_INSPECTION_BYTES),
            args.active_deploy_lock_fd,
        )
    elif args.command == "live-resume":
        _run_key(args.run_key)
        _live_resume(
            args.run_key, args.state_root, args.state_kind,
            _bounded_stdin(MAX_LIVE_RESUME_BYTES), args.active_deploy_lock_fd,
        )
    elif args.command == "absence-resume":
        _run_key(args.run_key)
        _absence_resume(
            args.run_key, args.state_root, args.state_kind,
            _bounded_stdin(MAX_LIVE_RESUME_BYTES), args.active_deploy_lock_fd,
        )
    elif args.command == "prepare-transition-proof":
        _run_key(args.run_key)
        _prepare_transition_proof(
            args.run_key, args.state_root, args.state_kind,
            _bounded_stdin(MAX_LIVE_RESUME_BYTES), args.active_deploy_lock_fd,
        )
    elif args.command == "runtime-request-proof":
        _run_key(args.run_key)
        _runtime_request_completion(
            args.run_key, args.state_root, args.state_kind,
            _bounded_stdin(MAX_INSPECTION_BYTES), args.active_deploy_lock_fd,
        )
    elif args.command == "resource-admission":
        _run_key(args.run_key)
        _resource_admission_command(
            args.run_key, args.state_root, args.state_kind,
            _bounded_stdin(MAX_INSPECTION_BYTES), args.active_deploy_lock_fd,
        )
    elif args.command == "state-publish":
        _state_publish(args.state_root, args.run_key, args.state_kind)
    elif args.command == "retention-list":
        _retention_list(
            "",
            args.state_root,
            args.protected_path,
            args.protected_state,
            deploy_lock_fd=args.active_deploy_lock_fd,
        )
    elif args.command == "retention-check":
        _retention_check(
            "",
            args.state_root,
            args.protected_path,
            args.protected_state,
            deploy_lock_fd=args.active_deploy_lock_fd,
        )
    else:
        _retention_delete(
            args.state_root,
            args.retention_state,
            args.protected_path,
            args.protected_state,
            deploy_lock_fd=args.active_deploy_lock_fd,
        )


def main(argv: Iterable[str] | None = None) -> int:
    try:
        args = _parser().parse_args(list(argv) if argv is not None else None)
        execution_supplied = _validate_execution_arguments(args)
        lock_commands = {
            "prepare",
            "verify",
            "finish",
            "prepare-finalization",
            "finish-committed-resume",
            "live-resume",
            "absence-resume",
            "prepare-transition-proof",
            "runtime-request-proof",
            "resource-admission",
            "state-publish",
            "retention-list",
            "retention-check",
            "retention-delete",
        }
        if args.deploy_lock_fd is not None and args.command not in lock_commands:
            _fail("recovery")
        if args.command in {"live-resume", "absence-resume", "prepare-transition-proof", "runtime-request-proof", "resource-admission"} and args.deploy_lock_fd is None:
            _fail("recovery")
        if args.command in {"live-resume", "absence-resume", "prepare-transition-proof", "runtime-request-proof", "resource-admission"} and (
            args.phase or args.outcome or args.protected_path
            or args.protected_state or args.retention_state
        ):
            _fail("recovery")
        if args.command in lock_commands:
            with _operation_deadline(args.deadline_ns):
                with _deploy_lock(
                    args.state_root,
                    args.deploy_lock_fd,
                    create_state_root=args.command == "state-publish" and not execution_supplied,
                ) as active_deploy_lock_fd:
                    args.active_deploy_lock_fd = active_deploy_lock_fd
                    lease = _execution_interlock(args, active_deploy_lock_fd)
                    with _execution_mutation(args, lease):
                        _dispatch(args)
        else:
            if (
                args.execution_attempt is not None or args.execution_grant is not None
                or args.deadline_ns is not None
            ):
                _fail("recovery")
            _dispatch(args)
        return 0
    except ProviderError as exc:
        sys.stderr.write(exc.category + "\n")
        return 1
    except (OSError, ValueError, TypeError, KeyError):
        sys.stderr.write(ERRORS["recovery"] + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
