#!/usr/bin/env python3
"""Private, fail-closed Firebase credential reconciliation for the release lane.

This module deliberately has no network, Docker, shell, or environment mutation
capability.  Bash owns deployment ordering and recovery; this process only
validates bounded private observations and performs the fixed-path credential
transaction.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import ctypes
import errno
import hashlib
import importlib.util
import io
import json
import os
import re
import secrets
import stat
import sys
from functools import cache
from typing import Any, Iterable, TYPE_CHECKING

sys.dont_write_bytecode = True
if TYPE_CHECKING:
    import test_vps_state_admission as state_admission

try:
    import fcntl
except ImportError:  # The production cleanup protocol requires Linux.
    fcntl = None

SCHEMA_VERSION = 1
MAX_INSPECTION_BYTES = 8 * 1024 * 1024
MAX_CREDENTIAL_BYTES = 1024 * 1024
MAX_WITNESS_BYTES = 16 * 1024 * 1024
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
STATE_KINDS = frozenset(("final-deploy", "rollback-drill"))
FORWARD_ORIGIN_KEY = "40368479855-1"
FORWARD_ORIGIN_STATE = FORWARD_ORIGIN_KEY + "-final-deploy"
FORWARD_ROOT = "/opt/meet-backend"
FORWARD_ACTIVE_ROOT = "/var/lib/meet-production"
FORWARD_FINISHED = "2026-10-26T17:30:24.669192243Z"
FORWARD_ARCHIVE = (
    "/var/lib/meet-test-vps-incident-archive/"
    "40368479855-1-forward-reconciled"
)
FORWARD_TARGET = {
    "releaseId": 423828315,
    "version": "1.6.0",
    "source": "462b52b403c73027a262e183d1bd9ae4964938d8",
    "indexDigest": "sha256:1f2c56da34fa905553739f79bf91647d0087ec72159efc40828ba91622033d4b",
    "amd64ManifestDigest": "sha256:9178741bc9fd1e9319acab54252e908fa2d439e66f628d0da20c169837c60cfe",
}
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


class ProviderError(Exception):
    def __init__(self, category: str):
        super().__init__(category)
        self.category = category


def _fail(category: str) -> None:
    raise ProviderError(ERRORS[category])


def _lock_directory(fd: int) -> None:
    if fcntl is None:
        _fail("prerequisite")
    fcntl.flock(fd, fcntl.LOCK_EX)


def _bounded_stdin(limit: int) -> bytes:
    data = sys.stdin.buffer.read(limit + 1)
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
    except (UnicodeDecodeError, json.JSONDecodeError, ProviderError):
        _fail(category)
    _depth(value)
    return value


def _run_key(value: str) -> str:
    import re

    if not isinstance(value, str) or re.fullmatch(RUN_KEY_RE, value) is None:
        _fail("provider")
    return value


def _result(enabled: bool, present: bool, read_only: bool, outcome: str) -> None:
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
    os.lseek(fd, 0, os.SEEK_SET)
    data = bytearray()
    while len(data) <= limit:
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
    env = config.get("Env", [])
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
    values = dict(entries)
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
        os.mkdir(parent, 0o700)
        os.chown(parent, 0, 0)
        os.chmod(parent, 0o700)
    _check_ancestors(parent)
    _acl_is_safe(parent)


def _write_private(path: str, data: bytes, mode: int, gid: int = 0) -> None:
    _check_ancestors(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.fchown(fd, 0, gid)
        os.fchmod(fd, mode)
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True)
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
    if not name or "/" in name or "\x00" in name:
        _fail("recovery")
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=directory_fd,
    )
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.fchown(fd, 0, gid)
        os.fchmod(fd, mode)
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
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
    destination_directory_fd: int | None = None,
) -> None:
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
    result = renameat2(
        directory_fd,
        os.fsencode(source),
        directory_fd if destination_directory_fd is None else destination_directory_fd,
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
        data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
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
        data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
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
        os.mkdir(state_root, 0o700)
        os.chown(state_root, 0, 0)
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
        _retention_interlocks_fd("", parent_fd)
        for candidate in (temporary, name):
            try:
                os.stat(candidate, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            _fail("recovery")
        os.mkdir(temporary, 0o700, dir_fd=parent_fd)
        temporary_fd = os.open(
            temporary,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            os.fchown(temporary_fd, 0, 0)
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
            os.fsync(temporary_fd)
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
    current = os.fstat(fd)
    if _identity(current) != _identity(before) or current.st_size != len(expected):
        _fail("changed")
    os.lseek(fd, 0, os.SEEK_SET)
    data = bytearray()
    while len(data) <= MAX_CREDENTIAL_BYTES:
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
        os.replace(temporary, marker_path)
        fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        if os.path.lexists(temporary):
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


FORWARD_IDENTITY_KEYS = frozenset(
    {"device", "inode", "mode", "uid", "gid", "nlink", "size", "mtimeNs", "ctimeNs"}
)
FORWARD_SOURCE_KEYS = frozenset(
    {"role", "path", "kind", "identity", "snapshotRef", "bytesBase64"}
)
FORWARD_STOPPED_KEYS = frozenset(
    {
        "containerId", "imageId", "revision", "version", "configHash",
        "startedAt", "finishedAt", "status", "exitCode", "running", "paused",
        "restarting", "dead", "envSnapshotRef", "envComparison", "staticInspect",
    }
)
FORWARD_REQUIRED_CHILDREN = frozenset({
    OWNER_MARKER, "config.env.production", "config.env.production.identity",
    "config.env.target", "config.env.target.identity", "config.env.previous",
    "config.base-compose.yml", "config.base-compose.yml.identity",
    "candidate-active-compose.yml", "candidate-active-compose.identity",
    "candidate-active-runtime.yml", "candidate-active-runtime.identity",
    "previous-image", "previous-image-id", "previous-revision", "previous-version",
    "previous-runtime-config-hash", "target-runtime.override.yml",
})


def _forward_identity(value: Any) -> None:
    if (not isinstance(value, dict) or set(value) != FORWARD_IDENTITY_KEYS
            or any(type(item) is not int or item < 0 for item in value.values())):
        _fail("recovery")


def _forward_identity_from_stat(info: os.stat_result) -> dict[str, int]:
    return {
        "device": int(info.st_dev),
        "inode": int(info.st_ino),
        "mode": int(info.st_mode),
        "uid": int(info.st_uid),
        "gid": int(info.st_gid),
        "nlink": int(info.st_nlink),
        "size": int(info.st_size),
        "mtimeNs": int(info.st_mtime_ns),
        "ctimeNs": int(info.st_ctime_ns),
    }


def _forward_path(value: Any) -> None:
    if (not isinstance(value, str) or not value.startswith("/")
            or "\x00" in value
            or any(part in ("", ".", "..") for part in value.split("/")[1:])):
        _fail("recovery")


def _forward_external_paths(successor: str) -> dict[str, str]:
    return {
        "production-env": FORWARD_ROOT + "/.env.production",
        "original-base": FORWARD_ROOT + "/.test-vps-tooling-" +
                         FORWARD_ORIGIN_KEY + "/docker-compose.production.yml",
        "reviewed-base": FORWARD_ROOT + "/.test-vps-tooling-" +
                         successor + "/docker-compose.production.yml",
        "active-compose": FORWARD_ACTIVE_ROOT + "/active-compose.yml",
        "active-runtime": FORWARD_ACTIVE_ROOT + "/active-runtime.override.yml",
    }


def _forward_original_base_witness(witness: dict[str, Any]) -> bool:
    return (
        witness["role"] == "original-base"
        and witness["path"] == _forward_external_paths("")["original-base"]
        and witness["kind"] == "regular-file"
        and witness["snapshotRef"] == "config.base-compose.yml"
        and witness["bytesBase64"] is None
    )


def _forward_static(inspect: dict[str, Any]) -> dict[str, Any]:
    """Only the nonsecret fields compared by stopped-runtime admission."""
    config, host = inspect["Config"], inspect["HostConfig"]
    mounts = [{
        "type": mount.get("Type", ""),
        "source": mount.get("Name") or mount.get("Source", ""),
        "destination": mount.get("Destination", ""),
        "readOnly": not mount.get("RW", True),
        "propagation": mount.get("Propagation", ""),
    } for mount in _mounts(inspect)]
    networks = [{
        "network": name, "aliases": sorted(value.get("Aliases") or []),
        "driverOpts": value.get("DriverOpts") or {},
        "ipAddress": value.get("IPAddress", ""),
        "ipPrefixLen": value.get("IPPrefixLen", 0),
        "gateway": value.get("Gateway", ""),
        "globalIpv6Address": value.get("GlobalIPv6Address", ""),
        "globalIpv6PrefixLen": value.get("GlobalIPv6PrefixLen", 0),
        "ipv6Gateway": value.get("IPv6Gateway", ""),
        "links": sorted(value.get("Links") or []),
    } for name, value in sorted(inspect["NetworkSettings"]["Networks"].items())]
    return {
        "entrypoint": config.get("Entrypoint"),
        "cmd": config.get("Cmd"),
        "user": config.get("User"),
        "mounts": sorted(mounts, key=lambda item: item["destination"]),
        "networks": networks,
        "hardening": {
            "readOnly": host["ReadonlyRootfs"],
            "restart": host["RestartPolicy"]["Name"],
            "logging": host["LogConfig"]["Type"],
            "capDrop": sorted(host["CapDrop"]),
            "securityOpt": sorted(host["SecurityOpt"]),
            "tmpfs": host["Tmpfs"],
            "memory": host["Memory"],
            "healthcheck": config["Healthcheck"]["Test"],
            "ports": host["PortBindings"],
            "privileged": host.get("Privileged", False),
            "capAdd": host.get("CapAdd") or [],
            "init": host.get("Init"),
            "networkMode": host.get("NetworkMode"),
            "pidMode": host.get("PidMode", ""),
            "ipcMode": host.get("IpcMode", "private"),
            "devices": host.get("Devices") or [],
        },
    }


def _validate_forward_static(value: Any) -> None:
    if (not isinstance(value, dict) or set(value) != {
            "entrypoint", "cmd", "user", "mounts", "networks", "hardening"}
            or value["entrypoint"] != ["java", "-jar", "app.jar"]
            or value["cmd"] not in (None, [])
            or value["user"] != "10001:10001"
            or not isinstance(value["mounts"], list)
            or not isinstance(value["networks"], list)
            or len(value["networks"]) != 1):
        _fail("recovery")
    network = value["networks"][0]
    if (not isinstance(network, dict) or set(network) != {
            "network", "aliases", "driverOpts", "ipAddress", "ipPrefixLen", "gateway",
            "globalIpv6Address", "globalIpv6PrefixLen", "ipv6Gateway", "links"}
            or network["network"] != "meet-production_default"
            or any(not isinstance(network[key], str) for key in (
                "network", "ipAddress", "gateway", "globalIpv6Address", "ipv6Gateway"))
            or any(type(network[key]) is not int or network[key] < 0
                   for key in ("ipPrefixLen", "globalIpv6PrefixLen"))
            or not isinstance(network["driverOpts"], dict)
            or any(not isinstance(key, str) or not isinstance(item, str)
                   for key, item in network["driverOpts"].items())):
        _fail("recovery")
    for key in ("aliases", "links"):
        if (not isinstance(network[key], list)
                or any(not isinstance(item, str) for item in network[key])
                or network[key] != sorted(set(network[key]))):
            _fail("recovery")
    destinations = []
    for mount in value["mounts"]:
        if (not isinstance(mount, dict) or set(mount) != {
                "type", "source", "destination", "readOnly", "propagation"}
                or any(not isinstance(mount[key], str) for key in (
                    "type", "source", "destination", "propagation"))
                or type(mount["readOnly"]) is not bool):
            _fail("recovery")
        destinations.append(mount["destination"])
        if mount["destination"] == "/data/uploads":
            if (mount["type"] != "volume"
                    or mount["source"] != "meet-production_uploads_data"
                    or mount["readOnly"]):
                _fail("recovery")
        elif mount["destination"] == "/tmp":
            if mount["type"] != "tmpfs":
                _fail("recovery")
        elif mount["destination"] == CONTAINER_CREDENTIAL_PATH:
            if mount["type"] != "bind" or not mount["readOnly"]:
                _fail("recovery")
        else:
            _fail("recovery")
    if (destinations != sorted(set(destinations))
            or "/data/uploads" not in destinations):
        _fail("recovery")
    hardening = value["hardening"]
    if (not isinstance(hardening, dict) or set(hardening) != {
            "readOnly", "restart", "logging", "capDrop", "securityOpt", "tmpfs",
            "memory", "healthcheck", "ports", "privileged", "capAdd", "init",
            "networkMode", "pidMode", "ipcMode", "devices"}
            or hardening["readOnly"] is not True
            or hardening["restart"] != "unless-stopped"
            or hardening["logging"] != "local"
            or hardening["privileged"] is not False
            or hardening["capAdd"] != []
            or hardening["init"] is not True
            or hardening["networkMode"] != "meet-production_default"
            or hardening["pidMode"] != ""
            or hardening["ipcMode"] != "private"
            or hardening["devices"] != []
            or hardening["capDrop"] != ["ALL"]
            or hardening["securityOpt"] != ["no-new-privileges:true"]
            or not isinstance(hardening["tmpfs"], dict)
            or set(hardening["tmpfs"]) != {"/tmp"}
            or not isinstance(hardening["tmpfs"]["/tmp"], str)
            or type(hardening["memory"]) is not int or hardening["memory"] <= 0
            or hardening["healthcheck"] != [
                "CMD", "curl", "--fail", "--silent", "--show-error",
                "http://127.0.0.1:8080/meetings"]
            or not isinstance(hardening["ports"], dict)
            or set(hardening["ports"]) != {"8080/tcp"}):
        _fail("recovery")
    ports = hardening["ports"]["8080/tcp"]
    if (not isinstance(ports, list) or len(ports) != 1
            or not isinstance(ports[0], dict)
            or set(ports[0]) != {"HostIp", "HostPort"}
            or ports[0]["HostIp"] != "127.0.0.1"
            or not isinstance(ports[0]["HostPort"], str)
            or not re.fullmatch(r"[1-9][0-9]{0,4}", ports[0]["HostPort"])
            or int(ports[0]["HostPort"]) > 65535):
        _fail("recovery")


def _validate_forward_adoption(data: bytes, successor_key: str) -> dict[str, Any]:
    """Strictly validate the immutable origin-to-successor ownership receipt."""
    value = _json(data, "recovery")
    expected = {
        "schemaVersion", "originRunKey", "successorRunKey", "originState",
        "originCredentialRunKey", "target", "originalMarker",
        "originalStateIdentity", "plannedArchive", "sourceWitnesses",
        "stoppedWitness",
    }
    if not isinstance(value, dict) or set(value) != expected:
        _fail("recovery")
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["originRunKey"] != FORWARD_ORIGIN_KEY
            or value["successorRunKey"] != successor_key
            or value["originState"] != FORWARD_ORIGIN_STATE):
        _fail("recovery")
    if (not isinstance(successor_key, str)
            or re.fullmatch(r"[1-9][0-9]*-1", successor_key) is None
            or successor_key == FORWARD_ORIGIN_KEY):
        _fail("recovery")
    marker = value["originalMarker"]
    if (not isinstance(marker, dict) or set(marker) != {"bytesBase64", "identity"}
            or not isinstance(marker["bytesBase64"], str)):
        _fail("recovery")
    try:
        import base64
        marker_bytes = base64.b64decode(marker["bytesBase64"], validate=True)
    except (ValueError, TypeError):
        _fail("recovery")
    if base64.b64encode(marker_bytes).decode("ascii") != marker["bytesBase64"]:
        _fail("recovery")
    _forward_identity(marker["identity"])
    marker_value = _json(marker_bytes, "recovery")
    if (not isinstance(marker_value, dict)
            or set(marker_value) != {
                "schemaVersion", "runKey", "phase", "providerEnabled",
                "durableDisposition",
            }
            or type(marker_value["schemaVersion"]) is not int
            or marker_value["schemaVersion"] != 1
            or marker_value["runKey"] != FORWARD_ORIGIN_KEY
            or marker_value["phase"] != "applying"
            or type(marker_value["providerEnabled"]) is not bool
            or marker_value["durableDisposition"] not in ("none", "created", "reused")):
        _fail("recovery")
    enabled = marker_value["providerEnabled"]
    if ((enabled and marker_value["durableDisposition"] not in ("created", "reused"))
            or (not enabled and marker_value["durableDisposition"] != "none")):
        _fail("recovery")
    if value["originCredentialRunKey"] != (FORWARD_ORIGIN_KEY if enabled else None):
        _fail("recovery")
    if value["target"] != FORWARD_TARGET:
        _fail("recovery")
    _forward_identity(value["originalStateIdentity"])
    archive = value["plannedArchive"]
    if (not isinstance(archive, dict) or set(archive) != {"path", "parentIdentity"}
            or archive["path"] != FORWARD_ARCHIVE):
        _fail("recovery")
    _forward_identity(archive["parentIdentity"])
    witnesses = value["sourceWitnesses"]
    if not isinstance(witnesses, list) or not witnesses:
        _fail("recovery")
    previous = ""
    copied_bytes = 0
    origin_paths = 0
    owner_paths = 0
    origin_directory = None
    source_children: set[str] = set()
    external_roles: set[str] = set()
    for witness in witnesses:
        if not isinstance(witness, dict) or set(witness) != FORWARD_SOURCE_KEYS:
            _fail("recovery")
        role, path, kind = witness["role"], witness["path"], witness["kind"]
        if (not isinstance(role, str) or not role or not isinstance(path, str)
                or path <= previous):
            _fail("recovery")
        previous = path
        _forward_path(path)
        _forward_identity(witness["identity"])
        identity = witness["identity"]
        historical_original = (
            _forward_original_base_witness(witness)
            and (identity["uid"], identity["gid"]) == (1001, 1001)
        )
        # This permits only the shape. The root-private saved identity and bytes
        # are authenticated again by origin validation before any mutation.
        if ((identity["uid"] != 0 or identity["gid"] != 0) and not historical_original
                or kind == "directory" and identity["mode"] != stat.S_IFDIR | 0o700
                or kind == "regular-file" and (
                    identity["mode"] not in (stat.S_IFREG | 0o600, stat.S_IFREG | 0o644)
                    or role not in _forward_external_paths(successor_key)
                    and identity["mode"] != stat.S_IFREG | 0o600)):
            _fail("recovery")
        if path.endswith("/" + FORWARD_ORIGIN_STATE):
            if role != "origin-state" or kind != "directory":
                _fail("recovery")
            if witness["identity"] != value["originalStateIdentity"]:
                _fail("recovery")
            origin_paths += 1
            origin_directory = path.rstrip("/")
        elif (path.endswith("/" + FORWARD_ORIGIN_STATE + "/" + OWNER_MARKER)
              and origin_directory is not None):
            if (role != "owner-marker" or kind != "regular-file"
                    or witness["snapshotRef"] is not None
                    or not isinstance(witness["bytesBase64"], str)):
                _fail("recovery")
            try:
                owner_bytes = base64.b64decode(
                    witness["bytesBase64"], validate=True
                )
            except (ValueError, TypeError):
                _fail("recovery")
            if base64.b64encode(owner_bytes).decode("ascii") != witness["bytesBase64"]:
                _fail("recovery")
            _parse_state_marker(
                owner_bytes, FORWARD_ORIGIN_KEY, "final-deploy"
            )
            owner_paths += 1
            source_children.add(OWNER_MARKER)
        elif role in _forward_external_paths(successor_key):
            if (path != _forward_external_paths(successor_key)[role]
                    or kind != "regular-file"
                    or witness["snapshotRef"] is None
                    or witness["bytesBase64"] is not None
                    or role == "original-base" and not _forward_original_base_witness(witness)):
                _fail("recovery")
            external_roles.add(role)
        else:
            if origin_directory is None or not path.startswith(origin_directory + "/"):
                _fail("recovery")
            relative = path[len(origin_directory) + 1:]
            if ("/" in relative or relative not in RETENTION_CHILDREN
                    or relative == OWNER_MARKER
                    or role != "state-snapshot" or kind != "regular-file"):
                _fail("recovery")
            if relative in ("terminal.json", "forward-adoption.json", "forward-acceptance.json"):
                _fail("recovery")
            source_children.add(relative)
            if witness["snapshotRef"] != relative or witness["bytesBase64"] is not None:
                _fail("recovery")
        if kind == "directory":
            if witness["snapshotRef"] is not None or witness["bytesBase64"] is not None:
                _fail("recovery")
        elif kind == "regular-file":
            ref, encoded = witness["snapshotRef"], witness["bytesBase64"]
            if witness["identity"]["nlink"] != 1:
                _fail("recovery")
            if ((ref is None) == (encoded is None)
                    or ref is not None and (
                        not isinstance(ref, str) or ref not in RETENTION_CHILDREN
                    )
                    or encoded is not None and not isinstance(encoded, str)):
                _fail("recovery")
            if encoded is not None:
                try:
                    raw = base64.b64decode(encoded, validate=True)
                except (ValueError, TypeError):
                    _fail("recovery")
                if base64.b64encode(raw).decode("ascii") != encoded:
                    _fail("recovery")
                copied_bytes += len(raw)
        else:
            _fail("recovery")
    if (origin_paths != 1 or owner_paths != 1 or origin_directory is None
            or not FORWARD_REQUIRED_CHILDREN <= source_children
            or external_roles != set(_forward_external_paths(successor_key))):
        _fail("recovery")
    stopped = value["stoppedWitness"]
    if not isinstance(stopped, dict) or set(stopped) != FORWARD_STOPPED_KEYS:
        _fail("recovery")
    if (not re.fullmatch(r"[0-9a-f]{64}", stopped["containerId"] or "")
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", stopped["imageId"] or "")
            or not re.fullmatch(r"[0-9a-f]{40}", stopped["revision"] or "")
            or not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", stopped["version"] or "")
            or not re.fullmatch(r"[0-9a-f]{64}", stopped["configHash"] or "")
            or not isinstance(stopped["startedAt"], str)
            or stopped["finishedAt"] != FORWARD_FINISHED
            or not stopped["startedAt"]
            or stopped["status"] != "exited" or type(stopped["exitCode"]) is not int
            or stopped["exitCode"] != 143
            or any(type(stopped[name]) is not bool for name in (
                "running", "paused", "restarting", "dead"))
            or stopped["running"] or stopped["paused"] or stopped["restarting"] or stopped["dead"]
            or stopped["envSnapshotRef"] != "config.env.production"
            or stopped["envComparison"] != "pending-off-predecessor-pass"):
        _fail("recovery")
    _validate_forward_static(stopped["staticInspect"])
    if copied_bytes > MAX_WITNESS_BYTES or len(data) > MAX_WITNESS_BYTES:
        _fail("recovery")
    return value


def _validate_forward_acceptance(data: bytes, adoption_data: bytes,
                                 successor_key: str) -> dict[str, Any]:
    value = _json(data, "recovery")
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "originRunKey", "successorRunKey", "adoptionSha256",
        "target", "candidate", "checks", "plannedArchive",
    }:
        _fail("recovery")
    adoption = _validate_forward_adoption(adoption_data, successor_key)
    candidate = value["candidate"]
    checks = value["checks"]
    if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["originRunKey"] != FORWARD_ORIGIN_KEY
            or value["successorRunKey"] != successor_key
            or value["adoptionSha256"] != hashlib.sha256(adoption_data).hexdigest()
            or value["target"] != FORWARD_TARGET
            or value["plannedArchive"] != FORWARD_ARCHIVE
            or not isinstance(candidate, dict)
            or set(candidate) != {"containerId", "startedAt", "platformImageId"}
            or not re.fullmatch(r"[0-9a-f]{64}", candidate["containerId"] or "")
            or not isinstance(candidate["startedAt"], str) or not candidate["startedAt"]
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", candidate["platformImageId"] or "")
            or candidate["containerId"] == adoption["stoppedWitness"]["containerId"]
            or not isinstance(checks, dict)
            or set(checks) != {"runtime", "pendingOff", "provider", "publicHealth"}
            or any(result != "pass" for result in checks.values())):
        _fail("recovery")
    return value


def _forward_receipt_for_run(
    state_root: str,
    successor_key: str,
) -> tuple[dict[str, Any], bytes] | None:
    name = successor_key + "-final-deploy"
    state_path = os.path.join(state_root, name)
    receipt_path = os.path.join(state_path, "forward-adoption.json")
    if not os.path.lexists(receipt_path):
        return None
    _validate_state_directory(state_path, name)
    receipt_fd, _, receipt_data = _open_private_state_file(receipt_path)
    os.close(receipt_fd)
    return _validate_forward_adoption(receipt_data, successor_key), receipt_data


def _forward_witness_data(
    adoption: dict[str, Any],
    state_root: str,
    path: str,
) -> bytes | None:
    witness = next(
        (item for item in adoption["sourceWitnesses"] if item["path"] == path),
        None,
    )
    if witness is None:
        _fail("recovery")
    _forward_path(path)
    if witness["kind"] == "directory":
        try:
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        except OSError:
            _fail("recovery")
        try:
            info = os.fstat(fd)
            _acl_is_safe(
                f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery"
            )
            if _forward_identity_from_stat(info) != witness["identity"]:
                _fail("recovery")
        finally:
            os.close(fd)
        return None
    fd, info, data = _open_private_state_file(path)
    try:
        if _forward_identity_from_stat(info) != witness["identity"]:
            _fail("recovery")
    finally:
        os.close(fd)
    if witness["snapshotRef"] is not None:
        ref_fd, _, expected = _open_private_state_file(
            os.path.join(
                state_root,
                adoption["successorRunKey"] + "-final-deploy",
                witness["snapshotRef"],
            )
        )
        os.close(ref_fd)
    else:
        import base64
        expected = base64.b64decode(witness["bytesBase64"], validate=True)
    if data != expected:
        _fail("recovery")
    return data


def _forward_adopt_boundary(stage: str) -> None:
    """Crash-injection seam for proving pointer replacement is always atomic."""
    return None


@cache
def _forward_state_module() -> Any:
    """Only forward recovery depends on the checksum-staged local classifier."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "test_vps_state_admission.py")
    spec = importlib.util.spec_from_file_location("_provider_state_admission", path)
    if spec is None or spec.loader is None:
        _fail("recovery")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    try:
        spec.loader.exec_module(module)
    except (OSError, ImportError):
        sys.modules.pop(spec.name, None)
        _fail("recovery")
    return module


def _forward_adoption_interlocks(root_fd: int, state_root: str) -> state_admission.Inventory:
    pointer_name = ".provider-transaction.current"
    pointer_fd, _, pointer_data = _open_private_state_file(
        os.path.join(state_root, pointer_name)
    )
    try:
        pointer = _json(pointer_data, "recovery")
    finally:
        os.close(pointer_fd)
    if (not isinstance(pointer, dict)
            or set(pointer) != {"schemaVersion", "runKey", "phase",
                                "providerEnabled", "durableDisposition"}):
        _fail("recovery")
    inventory = _forward_inventory(root_fd, state_root)
    try:
        _forward_credential_interlocks(pointer)
        return inventory
    except BaseException:
        inventory.close()
        raise


def _forward_inventory(root_fd: int, state_root: str,
                       successor: str | None = None) -> state_admission.Inventory:
    state_admission = _forward_state_module()
    own = {FORWARD_ORIGIN_STATE, ".provider-transaction.current", ".deploy.lock"}
    if successor is not None:
        own.add(successor + "-final-deploy")
    opaque = set()
    try:
        root_names = state_admission.names(root_fd, state_admission.ROOT_ENTRIES)
    except (state_admission.Rejected, OSError):
        _fail("recovery")
    for name in root_names:
        if name in own:
            continue
        if name == ".smtp-transaction.current" or name.startswith(
            (".provider-transaction.", ".provider-state.")
        ):
            _fail("recovery")
        if re.fullmatch(
            r"[0-9]+-[0-9]+-(?:rollback-drill|final-deploy)", name
        ):
            info = os.stat(name, dir_fd=root_fd, follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode):
                _fail("recovery")
            fd = os.open(
                name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            try:
                if not _same_inode(os.fstat(fd), info):
                    _fail("recovery")
                try:
                    os.stat(OWNER_MARKER, dir_fd=fd, follow_symlinks=False)
                except FileNotFoundError:
                    # Match ordinary retention: numeric legacy states without
                    # an owner marker remain opaque and are never cleaned here.
                    opaque.add(name)
                    continue
                _owned_state_fd(fd, name, require_terminal=True)
                children = _bounded_retention_children(fd)
                if children is None:
                    _fail("recovery")
                _validate_forward_retention_fd(
                    fd, state_root, name, children
                )
            finally:
                os.close(fd)
            opaque.add(name)
            continue
    _forward_read_external(os.path.join(state_root, ".deploy.lock"))
    try:
        inventory = state_admission.Inventory(root_fd, own, opaque, state_root)
        if inventory.root_names != root_names:
            inventory.close()
            _fail("recovery")
        return inventory
    except (state_admission.Rejected, OSError, ValueError):
        _fail("recovery")


def _forward_inventory_recheck(inventory: state_admission.Inventory, *,
                               added: frozenset[str] = frozenset(),
                               removed: frozenset[str] = frozenset()) -> None:
    state_admission = _forward_state_module()
    try:
        inventory.recheck(added=added, removed=removed)
    except (state_admission.Rejected, OSError, ValueError):
        _fail("recovery")


def _forward_credential_interlocks(pointer: dict[str, Any]) -> None:
    transaction_parent = _rooted(HOST_CREDENTIAL_PARENT, "")
    parent_fd = _open_optional_directory_reference(transaction_parent)
    if parent_fd is not None:
        try:
            transactions = {
                name for name in _iter_directory_fd_names(parent_fd)
                if name.startswith(".transaction-")
            }
            allowed = (
                {".transaction-" + FORWARD_ORIGIN_KEY}
                if pointer["providerEnabled"] is True else set()
            )
            if transactions != allowed:
                _fail("recovery")
        finally:
            os.close(parent_fd)


def _forward_archive_preflight(
    state_root: str,
    root_info: os.stat_result,
    adoption: dict[str, Any],
) -> None:
    _check_ancestors(FORWARD_ARCHIVE, category="recovery")
    parent = os.path.dirname(FORWARD_ARCHIVE)
    try:
        parent_info = os.stat(parent, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    if (not stat.S_ISDIR(parent_info.st_mode)
            or parent_info.st_uid != 0
            or stat.S_IMODE(parent_info.st_mode) != 0o700
            or parent_info.st_dev != root_info.st_dev
            or _forward_identity_from_stat(parent_info)
            != adoption["plannedArchive"]["parentIdentity"]):
        _fail("recovery")
    _acl_is_safe(parent, category="recovery")
    try:
        os.stat(FORWARD_ARCHIVE, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError:
        _fail("recovery")
    _fail("recovery")


def _forward_validate_origin(
    state_root: str,
    root_fd: int,
    adoption: dict[str, Any],
    snapshots: dict[str, bytes],
) -> None:
    origin_name = FORWARD_ORIGIN_STATE
    origin_fd = os.open(
        origin_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=root_fd,
    )
    try:
        origin_info = os.fstat(origin_fd)
        origin_path_info = os.stat(
            origin_name, dir_fd=root_fd, follow_symlinks=False
        )
        if (_forward_identity_from_stat(origin_info)
                != adoption["originalStateIdentity"]
                or _forward_identity_from_stat(origin_path_info)
                != adoption["originalStateIdentity"]):
            _fail("recovery")
        _validate_state_directory_fd(origin_fd, origin_name)
        if (_forward_identity_from_stat(os.fstat(origin_fd))
                != adoption["originalStateIdentity"]
                or _forward_identity_from_stat(os.stat(
                    origin_name, dir_fd=root_fd, follow_symlinks=False
                )) != adoption["originalStateIdentity"]):
            _fail("recovery")
        children: dict[str, dict[str, Any]] = {}
        for witness in adoption["sourceWitnesses"]:
            path = witness["path"]
            if path == os.path.join(state_root, origin_name):
                continue
            prefix = os.path.join(state_root, origin_name) + "/"
            if not path.startswith(prefix):
                _forward_validate_external(
                    witness, snapshots, os.path.join(state_root, origin_name))
                continue
            child = path[len(prefix):]
            if "/" in child or child in children:
                _fail("recovery")
            children[child] = witness
        if set(_iter_directory_fd_names(origin_fd)) != set(children):
            _fail("recovery")
        for child, witness in children.items():
            info = os.stat(child, dir_fd=origin_fd, follow_symlinks=False)
            if _forward_identity_from_stat(info) != witness["identity"]:
                _fail("recovery")
            if child == "terminal.json":
                _fail("recovery")
            if witness["kind"] == "directory":
                if not stat.S_ISDIR(info.st_mode):
                    _fail("recovery")
                continue
            if not stat.S_ISREG(info.st_mode):
                _fail("recovery")
            fd, opened, content = _open_private_state_file_at(origin_fd, child)
            try:
                if _forward_identity_from_stat(opened) != witness["identity"]:
                    _fail("recovery")
            finally:
                os.close(fd)
            final_path_info = os.stat(
                child, dir_fd=origin_fd, follow_symlinks=False
            )
            if _forward_identity_from_stat(final_path_info) != witness["identity"]:
                _fail("recovery")
            if witness["role"] == "owner-marker":
                expected = base64.b64decode(witness["bytesBase64"], validate=True)
            elif witness["snapshotRef"] is not None:
                expected = snapshots[witness["snapshotRef"]]
            else:
                expected = base64.b64decode(witness["bytesBase64"], validate=True)
            if content != expected:
                _fail("recovery")
        try:
            os.stat("terminal.json", dir_fd=origin_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail("recovery")
        if (_forward_identity_from_stat(os.fstat(origin_fd))
                != adoption["originalStateIdentity"]
                or _forward_identity_from_stat(os.stat(
                    origin_name, dir_fd=root_fd, follow_symlinks=False))
                != adoption["originalStateIdentity"]):
            _fail("recovery")
    finally:
        os.close(origin_fd)


def _forward_read_external(path: str) -> tuple[dict[str, int], bytes]:
    _check_ancestors(path, category="recovery")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or stat.S_IMODE(info.st_mode) not in (0o600, 0o644)
                or info.st_nlink != 1):
            _fail("recovery")
        _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
        data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
        identity = _forward_identity_from_stat(info)
        if (identity != _forward_identity_from_stat(os.fstat(fd))
                or identity != _forward_identity_from_stat(
                    os.stat(path, follow_symlinks=False))):
            _fail("recovery")
        return identity, data
    finally:
        os.close(fd)


@contextlib.contextmanager
def _forward_pinned_parent(path: str) -> Iterable[tuple[int, str]]:
    """Keep every trusted ancestor open, including its named-entry binding."""
    _forward_path(path)
    parts = path.split("/")[1:]
    descriptors = [os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)]
    identities = []
    try:
        for index in range(len(parts)):
            fd = descriptors[-1]
            info = os.fstat(fd)
            if (info.st_uid != 0
                    or stat.S_IMODE(info.st_mode) & 0o022):
                _fail("recovery")
            _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
            identities.append(_forward_identity_from_stat(info))
            if index < len(parts) - 1:
                descriptors.append(os.open(
                    parts[index], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=fd))
        yield descriptors[-1], parts[-1]
        for index, (fd, identity) in enumerate(zip(descriptors, identities)):
            if identity != _forward_identity_from_stat(os.fstat(fd)):
                _fail("recovery")
            _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
            if index and identity != _forward_identity_from_stat(os.stat(
                    parts[index - 1], dir_fd=descriptors[index - 1],
                    follow_symlinks=False)):
                _fail("recovery")
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def _forward_read_original_base(
    path: str, origin: str, snapshots: dict[str, bytes],
) -> tuple[dict[str, int], bytes]:
    """Authenticate historical evidence; Compose consumes its private copy."""
    if (path != _forward_external_paths("")["original-base"]
            or os.path.basename(origin) != FORWARD_ORIGIN_STATE):
        _fail("recovery")
    with _forward_pinned_parent(os.path.join(origin, OWNER_MARKER)) as (origin_fd, _):
        info = os.fstat(origin_fd)
        if (info.st_gid != 0 or stat.S_IMODE(info.st_mode) != 0o700):
            _fail("recovery")
        trusted = {}
        with contextlib.ExitStack() as stack:
            for name in (OWNER_MARKER, "config.base-compose.yml",
                         "config.base-compose.yml.identity"):
                fd, before, data = _open_private_state_file_at(origin_fd, name)
                stack.callback(os.close, fd)
                identity = _forward_identity_from_stat(before)
                if before.st_gid != 0:
                    _fail("recovery")
                trusted[name] = (fd, identity, data)
            _parse_state_marker(
                trusted[OWNER_MARKER][2], FORWARD_ORIGIN_KEY, "final-deploy")
            for name in ("config.base-compose.yml", "config.base-compose.yml.identity"):
                if trusted[name][2] != snapshots[name]:
                    _fail("recovery")
            with _forward_pinned_parent(path) as (parent_fd, name):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
                             | os.O_NOATIME, dir_fd=parent_fd)
                stack.callback(os.close, fd)
                info = os.fstat(fd)
                if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                        or (info.st_uid, info.st_gid) not in ((0, 0), (1001, 1001))
                        or stat.S_IMODE(info.st_mode) not in (0o600, 0o644)):
                    _fail("recovery")
                _acl_is_safe(f"/proc/self/fd/{fd}", follow_symlinks=True, category="recovery")
                identity = _forward_identity_from_stat(info)
                data = _read_fd_bounded(fd, MAX_WITNESS_BYTES)
                if data != trusted["config.base-compose.yml"][2]:
                    _fail("recovery")
                _forward_saved_identity(trusted["config.base-compose.yml.identity"][2],
                                        identity, data)
                original_identity, original_data = identity, data
                for saved_name, (saved_fd, saved_identity, saved_data) in trusted.items():
                    if (_read_fd_bounded(saved_fd, MAX_WITNESS_BYTES) != saved_data
                            or _forward_identity_from_stat(os.fstat(saved_fd)) != saved_identity
                            or _forward_identity_from_stat(os.stat(
                                saved_name, dir_fd=origin_fd,
                                follow_symlinks=False)) != saved_identity):
                        _fail("recovery")
                if (_read_fd_bounded(fd, MAX_WITNESS_BYTES) != data
                        or _forward_identity_from_stat(os.fstat(fd)) != identity
                        or _forward_identity_from_stat(os.stat(
                            name, dir_fd=parent_fd, follow_symlinks=False)) != identity):
                    _fail("recovery")
    return original_identity, original_data


def _forward_validate_external(witness: dict[str, Any],
                               snapshots: dict[str, bytes], origin: str) -> None:
    if _forward_original_base_witness(witness):
        identity, data = _forward_read_original_base(witness["path"], origin, snapshots)
    else:
        identity, data = _forward_read_external(witness["path"])
    if (identity != witness["identity"]
            or data != snapshots[witness["snapshotRef"]]):
        _fail("recovery")


def _forward_saved_identity(data: bytes, actual: dict[str, int],
                            content: bytes) -> None:
    # Existing configuration witnesses predate the receipt and use this exact
    # colon-delimited representation. Do not rebase an old inode onto new tooling.
    expected = ":".join(str(actual[key]) for key in (
        "device", "inode", "mode", "uid", "gid", "size", "mtimeNs", "ctimeNs"
    )) + ":" + hashlib.sha256(content).hexdigest() + "\n"
    if data != expected.encode():
        _fail("recovery")


def _forward_deployment_lock(state_root: str) -> None:
    path = os.path.join(state_root, ".deploy.lock")
    identity, data = _forward_read_external(path)
    if data or _forward_identity_from_stat(os.fstat(9)) != identity:
        _fail("recovery")
    if fcntl is None:
        _fail("prerequisite")
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)


def _forward_pending_module() -> Any:
    spec = importlib.util.spec_from_file_location(
        "forward_pending", os.path.join(os.path.dirname(__file__),
                                       "test-vps-locationiq-pending-off.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _forward_stopped(inspect: dict[str, Any],
                     snapshots: dict[str, bytes]) -> dict[str, Any]:
    pending = _forward_pending_module()
    try:
        pending.stopped_predecessor_record(
            [inspect], inspect["Id"], FORWARD_FINISHED)
        pending.compare_predecessor_environment(
            snapshots["config.env.production"], inspect)
    except (ValueError, pending.Rejected):
        _fail("recovery")
    labels = inspect["Config"]["Labels"]
    fields = {
        "imageId": "previous-image-id", "revision": "previous-revision",
        "version": "previous-version", "configHash": "previous-runtime-config-hash",
    }
    result = {
        "containerId": inspect["Id"], "imageId": inspect["Image"],
        "revision": labels["org.opencontainers.image.revision"],
        "version": labels["org.opencontainers.image.version"],
        "configHash": labels["com.docker.compose.config-hash"],
        "startedAt": inspect["State"]["StartedAt"],
        "finishedAt": inspect["State"]["FinishedAt"],
        "status": inspect["State"]["Status"], "exitCode": inspect["State"]["ExitCode"],
        **{name.lower(): inspect["State"][name] for name in (
            "Running", "Paused", "Restarting", "Dead")},
        "envSnapshotRef": "config.env.production",
        "envComparison": "pending-off-predecessor-pass",
        "staticInspect": _forward_static(inspect),
    }
    for field, snapshot in fields.items():
        if snapshots[snapshot] != (result[field] + "\n").encode():
            _fail("recovery")
    if (not result["containerId"].startswith("6d4a33264076")
            or result["imageId"] !=
            "sha256:8e405258c34d70d6b42d226458c381f55df47d37fa743b754e1066e05f3ae1a0"
            or inspect["Config"]["Image"] + "\n" !=
            snapshots["previous-image"].decode()
            or labels["org.opencontainers.image.source"] !=
            "https://github.com/NickolayMamonov/meet-backend-v3"):
        _fail("recovery")
    _validate_forward_static(result["staticInspect"])
    return result


def _forward_credential_preflight(marker: dict[str, Any],
                                  inspect: dict[str, Any]) -> None:
    enabled, _ = _provider_state(inspect)
    _, _, source = _provider_mount(inspect, enabled, allow_external_source=True)
    if marker["providerEnabled"] != enabled:
        _fail("recovery")
    tx = _transaction(HOST_CREDENTIAL_PARENT, FORWARD_ORIGIN_KEY)
    if not enabled:
        if marker["durableDisposition"] != "none" or os.path.lexists(tx):
            _fail("recovery")
        return
    if marker["durableDisposition"] not in ("created", "reused") or source is None:
        _fail("recovery")
    _validate_transaction(tx)
    snapshot = _read_private(os.path.join(tx, "snapshot"))
    identity = _json(_read_private(os.path.join(tx, "identity.json")), "recovery")
    _validate_identity(identity)
    _validate_credential(snapshot)
    source_identity, source_data = _read_existing(source, source=True)
    durable_identity, durable_data = _read_existing(HOST_CREDENTIAL_PATH)
    if (source_data != snapshot or source_identity != identity["predecessor"]
            or durable_data != snapshot or durable_identity != identity["durable"]):
        _fail("recovery")
    if marker["durableDisposition"] == "created":
        _verify_created_publication(tx, HOST_CREDENTIAL_PATH, identity, snapshot)
    elif set(os.listdir(tx)) != {"snapshot", "identity.json"}:
        _fail("recovery")


def _forward_image(image: dict[str, Any], image_id: str,
                   revision: str, version: str) -> None:
    config = image["Config"]
    labels = config["Labels"]
    if (image["Id"] != image_id or config["User"] != "10001:10001"
            or config.get("Entrypoint") != ["java", "-jar", "app.jar"]
            or config.get("Cmd") not in (None, [])
            or labels["org.opencontainers.image.revision"] != revision
            or labels["org.opencontainers.image.version"] != version
            or labels["org.opencontainers.image.source"] !=
            "https://github.com/NickolayMamonov/meet-backend-v3"):
        _fail("recovery")
    _image_admission(image)


def _forward_rendered(config: dict[str, Any], backend: dict[str, Any],
                       target: dict[str, Any], env: bytes) -> None:
    pending = _forward_pending_module()
    values = pending.file_environment(env)
    service = config["services"]["backend"]
    if (set(config["services"]) != {"backend", "postgres"}
            or service["image"] != pending.IMAGE
            or service.get("pull_policy") != "never"
            or service.get("user") != "10001:10001"
            or service.get("read_only") is not True
            or service.get("privileged", False) is not False
            or service.get("network_mode") is not None
            or service.get("cap_add", []) != []
            or service.get("cap_drop") != ["ALL"]
            or service.get("security_opt") != ["no-new-privileges:true"]
            or service.get("restart") != "unless-stopped"
            or service["logging"]["driver"] != "local"
            or service["mem_limit"] != backend["HostConfig"]["Memory"]
            or service.get("entrypoint") is not None
            or service.get("command") is not None):
        _fail("recovery")
    effective = dict(_env_entries(target))
    effective.update(service["environment"])
    if any(effective.get(key) != value for key, value in values.items()):
        _fail("recovery")
    proposed = {
        "Config": {"Env": [key + "=" + value for key, value in effective.items()]},
        "Mounts": [],
    }
    if _effective_tuple(proposed) != _effective_tuple(backend):
        _fail("recovery")
    ports = service["ports"]
    expected_port = backend["HostConfig"]["PortBindings"]["8080/tcp"][0]
    if (len(ports) != 1 or ports[0].get("host_ip") != "127.0.0.1"
            or ports[0].get("target") != 8080
            or str(ports[0].get("published")) != expected_port["HostPort"]
            or ports[0].get("protocol", "tcp") != "tcp"):
        _fail("recovery")
    mounts = service["volumes"]
    enabled = _provider_state(backend)[0]
    expected_destinations = {"/data/uploads"}
    if enabled:
        expected_destinations.add(CONTAINER_CREDENTIAL_PATH)
    if {mount["target"] for mount in mounts} != expected_destinations:
        _fail("recovery")
    if len(mounts) != len(expected_destinations):
        _fail("recovery")
    for mount in mounts:
        if mount["target"] == "/data/uploads":
            if (mount["type"] != "volume" or mount["source"] != "uploads_data"
                    or mount.get("read_only", False)):
                _fail("recovery")
        elif (mount["type"] != "bind" or mount["source"] != HOST_CREDENTIAL_PATH
                or mount.get("read_only") is not True
                or mount["bind"].get("create_host_path") is not False):
            _fail("recovery")
    if (service["healthcheck"]["test"] !=
            backend["Config"]["Healthcheck"]["Test"]
            or set(config["volumes"]) != {"postgres_data", "uploads_data"}
            or config["volumes"]["postgres_data"]["name"] !=
            "meet-production_postgres_data"
            or config["volumes"]["uploads_data"]["name"] !=
            "meet-production_uploads_data"):
        _fail("recovery")


def _forward_admission(state_root: str, run_key: str, deployment_root: str,
                       base_compose: str, inspection_data: bytes) -> None:
    """Build all witnesses from fixed contracts; callers cannot supply receipts."""
    paths = _forward_external_paths(run_key)
    if (deployment_root != FORWARD_ROOT or base_compose != paths["reviewed-base"]
            or not re.fullmatch(r"[1-9][0-9]*-1", run_key)
            or run_key == FORWARD_ORIGIN_KEY):
        _fail("recovery")
    _forward_deployment_lock(state_root)
    bundle = _json(inspection_data, "recovery")
    if not isinstance(bundle, dict) or set(bundle) != {
            "backend", "previousImage", "targetImage", "platformImage", "rendered"}:
        _fail("recovery")
    origin = os.path.join(state_root, FORWARD_ORIGIN_STATE)
    _validate_state_directory(origin, FORWARD_ORIGIN_STATE)
    origin_info = os.stat(origin, follow_symlinks=False)
    names = set(os.listdir(origin))
    forbidden = {
        "terminal.json", "forward-adoption.json", "forward-acceptance.json",
        "predecessor.json", "candidate.json", "final.json", "rollback.json",
        "frozen-assets.json",
    }
    if (not FORWARD_REQUIRED_CHILDREN <= names or not names <= RETENTION_CHILDREN
            or names & forbidden):
        _fail("recovery")
    snapshots: dict[str, bytes] = {}
    aggregate_size = 0
    witnesses = [{
        "role": "origin-state", "path": origin, "kind": "directory",
        "identity": _forward_identity_from_stat(origin_info),
        "snapshotRef": None, "bytesBase64": None,
    }]
    for name in sorted(names):
        fd, info, content = _open_private_state_file(os.path.join(origin, name))
        os.close(fd)
        aggregate_size += len(content)
        if aggregate_size > MAX_WITNESS_BYTES:
            _fail("recovery")
        embedded = name == OWNER_MARKER or name.endswith(".identity")
        if not embedded:
            snapshots[name] = content
        witnesses.append({
            "role": "owner-marker" if name == OWNER_MARKER else "state-snapshot",
            "path": os.path.join(origin, name), "kind": "regular-file",
            "identity": _forward_identity_from_stat(info),
            "snapshotRef": None if embedded else name,
            "bytesBase64": base64.b64encode(content).decode() if embedded else None,
        })
    original_files = {
        os.path.basename(witness["path"]): base64.b64decode(witness["bytesBase64"])
        if witness["bytesBase64"] is not None else snapshots[witness["snapshotRef"]]
        for witness in witnesses if witness["kind"] == "regular-file"
    }
    # Identity records are copied too, not only embedded: existing tools continue
    # to read the original witness format in the successor state.
    snapshots.update({name: data for name, data in original_files.items()
                      if name != OWNER_MARKER})
    for witness in witnesses:
        if witness["role"] == "state-snapshot":
            witness["snapshotRef"] = os.path.basename(witness["path"])
            witness["bytesBase64"] = None
    refs = {
        "production-env": "config.env.target",
        "original-base": "config.base-compose.yml",
        "reviewed-base": "config.base-compose.yml",
        "active-compose": "candidate-active-compose.yml",
        "active-runtime": "candidate-active-runtime.yml",
    }
    for role, path in paths.items():
        if role == "original-base":
            identity, content = _forward_read_original_base(path, origin, snapshots)
        else:
            identity, content = _forward_read_external(path)
        ref = refs[role]
        if content != snapshots[ref]:
            _fail("recovery")
        saved = {
            "production-env": "config.env.target.identity",
            "original-base": "config.base-compose.yml.identity",
            "active-compose": "candidate-active-compose.identity",
            "active-runtime": "candidate-active-runtime.identity",
        }.get(role)
        if saved:
            _forward_saved_identity(original_files[saved], identity, content)
        witnesses.append({
            "role": role, "path": path, "kind": "regular-file",
            "identity": identity, "snapshotRef": ref, "bytesBase64": None,
        })
    if (snapshots["candidate-active-compose.yml"] != snapshots["config.base-compose.yml"]
            or snapshots["candidate-active-runtime.yml"] !=
            snapshots["target-runtime.override.yml"]):
        _fail("recovery")
    pending = _forward_pending_module()
    before = pending.file_environment(snapshots["config.env.production"])
    replacements = {
        "BACKEND_IMAGE": pending.IMAGE, "BACKEND_REVISION": pending.REVISION,
        "BACKEND_VERSION": pending.VERSION,
    }
    lines = []
    for line in snapshots["config.env.production"].decode().splitlines(keepends=True):
        name = line.split("=", 1)[0]
        if name in replacements:
            ending = line[len(line.rstrip("\r\n")):]
            line = name + "=" + replacements[name] + ending
        lines.append(line)
    if (not set(replacements) <= set(before)
            or "".join(lines).encode() != snapshots["config.env.target"]
            or snapshots["config.env.previous"] != snapshots["config.env.production"]
            or any(before[key] + "\n" != snapshots[name].decode() for key, name in (
                ("BACKEND_IMAGE", "previous-image"),
                ("BACKEND_REVISION", "previous-revision"),
                ("BACKEND_VERSION", "previous-version")))):
        _fail("recovery")
    backend = _inspect(json.dumps(bundle["backend"]).encode())
    stopped = _forward_stopped(backend, snapshots)
    old_image = _inspect(json.dumps(bundle["previousImage"]).encode())
    _forward_image(old_image, stopped["imageId"], stopped["revision"], stopped["version"])
    target = _inspect(json.dumps(bundle["targetImage"]).encode())
    platform = _inspect(json.dumps(bundle["platformImage"]).encode())
    target_id = target["Id"]
    if not isinstance(target_id, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", target_id):
        _fail("recovery")
    _forward_image(target, target_id, FORWARD_TARGET["source"], FORWARD_TARGET["version"])
    _forward_image(platform, target_id, FORWARD_TARGET["source"], FORWARD_TARGET["version"])
    if target.get("Architecture") != "amd64" or target.get("Os") != "linux":
        _fail("recovery")
    _forward_rendered(bundle["rendered"], backend, target, snapshots["config.env.target"])
    pointer_fd, pointer_info, pointer_data = _open_private_state_file(
        os.path.join(state_root, ".provider-transaction.current"))
    os.close(pointer_fd)
    marker = _marker(state_root, FORWARD_ORIGIN_KEY)
    _forward_credential_preflight(marker, backend)
    adoption = {
        "schemaVersion": 1, "originRunKey": FORWARD_ORIGIN_KEY,
        "successorRunKey": run_key, "originState": FORWARD_ORIGIN_STATE,
        "originCredentialRunKey": FORWARD_ORIGIN_KEY if marker["providerEnabled"] else None,
        "target": FORWARD_TARGET,
        "originalMarker": {
            "bytesBase64": base64.b64encode(pointer_data).decode(),
            "identity": _forward_identity_from_stat(pointer_info),
        },
        "originalStateIdentity": _forward_identity_from_stat(origin_info),
        "plannedArchive": {
            "path": FORWARD_ARCHIVE,
            "parentIdentity": _forward_identity_from_stat(
                os.stat(os.path.dirname(FORWARD_ARCHIVE), follow_symlinks=False)),
        },
        "sourceWitnesses": sorted(witnesses, key=lambda item: item["path"]),
        "stoppedWitness": stopped,
    }
    encoded = json.dumps(adoption, separators=(",", ":")).encode()
    intended_key = before["LOCATIONIQ_KEY"].encode()
    if intended_key in encoded or base64.b64encode(intended_key) in encoded:
        _fail("recovery")
    _validate_forward_adoption(encoded, run_key)
    _forward_adopt(state_root, json.dumps({
        "adoptionReceiptBase64": base64.b64encode(encoded).decode(),
        "snapshots": {name: base64.b64encode(data).decode()
                      for name, data in snapshots.items()},
    }, separators=(",", ":")).encode(),
        before_commit=lambda: _forward_credential_preflight(marker, backend))


def _forward_adopt(state_root: str, request_data: bytes,
                   before_commit: Any = None) -> None:
    request = _json(request_data, "recovery")
    if (not isinstance(request, dict)
            or set(request) != {"adoptionReceiptBase64", "snapshots"}
            or not isinstance(request["adoptionReceiptBase64"], str)
            or not isinstance(request["snapshots"], dict)):
        _fail("recovery")
    try:
        receipt_data = base64.b64decode(
            request["adoptionReceiptBase64"], validate=True
        )
    except (ValueError, TypeError):
        _fail("recovery")
    if (base64.b64encode(receipt_data).decode("ascii")
            != request["adoptionReceiptBase64"]):
        _fail("recovery")
    receipt = _json(receipt_data, "recovery")
    successor_key = receipt.get("successorRunKey") if isinstance(receipt, dict) else None
    if not isinstance(successor_key, str):
        _fail("recovery")
    _run_key(successor_key)
    adoption = _validate_forward_adoption(receipt_data, successor_key)
    if len(request_data) > MAX_WITNESS_BYTES * 2:
        _fail("recovery")

    snapshot_refs = {
        witness["snapshotRef"]
        for witness in adoption["sourceWitnesses"]
        if witness["kind"] == "regular-file"
        and witness["snapshotRef"] is not None
    }
    snapshots: dict[str, bytes] = {}
    for name, encoded in request["snapshots"].items():
        if (not isinstance(name, str) or name not in snapshot_refs
                or name not in RETENTION_CHILDREN
                or name in (OWNER_MARKER, "terminal.json",
                            "forward-adoption.json", "forward-acceptance.json")
                or not isinstance(encoded, str)):
            _fail("recovery")
        try:
            content = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError):
            _fail("recovery")
        if base64.b64encode(content).decode("ascii") != encoded:
            _fail("recovery")
        snapshots[name] = content
    if set(snapshots) != snapshot_refs:
        _fail("recovery")
    if (
        len(receipt_data) + sum(map(len, snapshots.values()))
        + sum(map(len, (base64.b64decode(
            witness["bytesBase64"], validate=True
        ) for witness in adoption["sourceWitnesses"]
          if witness["bytesBase64"] is not None)))
        > MAX_WITNESS_BYTES
    ):
        _fail("recovery")

    expected_root = _validate_retention_state_root_path(state_root)
    root_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    staging = ".provider-state." + successor_key + "-final-deploy.tmp"
    destination = successor_key + "-final-deploy"
    temporary_pointer = ".provider-transaction." + successor_key + ".forward"
    credential_parent_fd = None
    inventory = None
    try:
        if not _same_inode(os.fstat(root_fd), expected_root):
            _fail("recovery")
        _lock_directory(root_fd)
        root_info = os.fstat(root_fd)
        if (not _same_inode(root_info, expected_root)
                or _forward_identity_from_stat(root_info)
                != _forward_identity_from_stat(os.stat(
                    state_root, follow_symlinks=False))):
            _fail("recovery")
        _validate_retention_state_root_fd(root_fd)
        credential_parent_fd = _open_optional_directory_reference(HOST_CREDENTIAL_PARENT)
        if credential_parent_fd is not None:
            _lock_directory(credential_parent_fd)
        inventory = _forward_adoption_interlocks(root_fd, state_root)
        _forward_archive_preflight(state_root, root_info, adoption)
        try:
            os.stat(destination, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            _fail("recovery")
        for candidate in (staging, temporary_pointer):
            try:
                os.stat(candidate, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            _fail("recovery")

        pointer_name = ".provider-transaction.current"
        pointer_path_info = os.stat(
            pointer_name, dir_fd=root_fd, follow_symlinks=False
        )
        pointer_fd, pointer_info, pointer_data = _open_private_state_file(
            os.path.join(state_root, pointer_name)
        )
        try:
            original_marker = adoption["originalMarker"]
            if (_forward_identity_from_stat(pointer_path_info)
                    != _forward_identity_from_stat(pointer_info)
                    or _forward_identity_from_stat(pointer_info)
                    != original_marker["identity"]
                    or pointer_data != base64.b64decode(
                        original_marker["bytesBase64"], validate=True)):
                _fail("recovery")
            marker = _json(pointer_data, "recovery")
            if (not isinstance(marker, dict)
                    or set(marker) != {"schemaVersion", "runKey", "phase",
                                       "providerEnabled", "durableDisposition"}
                    or type(marker["schemaVersion"]) is not int
                    or marker["schemaVersion"] != 1
                    or marker["runKey"] != FORWARD_ORIGIN_KEY
                    or marker["phase"] != "applying"
                    or type(marker["providerEnabled"]) is not bool
                    or marker["durableDisposition"] not in ("none", "created", "reused")
                    or marker["providerEnabled"]
                    != (marker["durableDisposition"] != "none")):
                _fail("recovery")
        finally:
            os.close(pointer_fd)

        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        if before_commit is not None:
            before_commit()

        _forward_inventory_recheck(inventory)
        os.mkdir(staging, 0o700, dir_fd=root_fd)
        staging_fd = os.open(
            staging, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=root_fd,
        )
        try:
            os.fchown(staging_fd, 0, 0)
            os.fchmod(staging_fd, 0o700)
            _write_private_at(
                staging_fd, OWNER_MARKER,
                _state_marker(successor_key, "final-deploy"), 0o600,
            )
            _write_private_at(staging_fd, "forward-adoption.json", receipt_data, 0o600)
            for name in sorted(snapshots):
                _write_private_at(staging_fd, name, snapshots[name], 0o600)
            os.fsync(staging_fd)
            _validate_state_directory_fd(staging_fd, destination)
            os.fsync(root_fd)
            _forward_adopt_boundary("state-staged")
            _forward_inventory_recheck(inventory, added=frozenset({staging}))
            _rename_noreplace(
                root_fd, staging, destination,
                expected_source_fd=staging_fd,
                expected_source_inode=(
                    os.fstat(staging_fd).st_dev, os.fstat(staging_fd).st_ino
                ),
            )
            published_fd = os.open(
                destination, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=root_fd,
            )
            try:
                published_info = os.fstat(published_fd)
                published_path_info = os.stat(
                    destination, dir_fd=root_fd, follow_symlinks=False
                )
                if (not _same_inode(published_info, os.fstat(staging_fd))
                        or not _same_inode(published_path_info, published_info)):
                    _fail("recovery")
                _validate_state_directory_fd(published_fd, destination)
            finally:
                os.close(published_fd)
            os.fsync(root_fd)
            _forward_adopt_boundary("state-published")
        finally:
            os.close(staging_fd)

        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        _forward_inventory_recheck(inventory, added=frozenset({destination}))
        successor_marker = dict(marker)
        successor_marker["runKey"] = successor_key
        successor_marker["phase"] = "applying"
        successor_data = json.dumps(
            successor_marker, separators=(",", ":"), sort_keys=True
        ).encode()
        _write_private_at(root_fd, temporary_pointer, successor_data, 0o600)

        # Revalidate both owners at the ownership linearization boundary.
        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        _forward_inventory_recheck(
            inventory, added=frozenset({destination, temporary_pointer}))
        current_path_info = os.stat(
            pointer_name, dir_fd=root_fd, follow_symlinks=False
        )
        current_fd, current_info, current_data = _open_private_state_file(
            os.path.join(state_root, pointer_name)
        )
        try:
            if (_forward_identity_from_stat(current_path_info)
                    != _forward_identity_from_stat(current_info)
                    or _forward_identity_from_stat(current_info)
                    != adoption["originalMarker"]["identity"]
                    or current_data != pointer_data):
                _fail("recovery")
        finally:
            os.close(current_fd)
        _forward_adopt_boundary("pointer-ready")
        if before_commit is not None:
            before_commit()
        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        _forward_archive_preflight(state_root, os.fstat(root_fd), adoption)
        if (credential_parent_fd is not None and not _same_inode(
                os.fstat(credential_parent_fd),
                os.stat(HOST_CREDENTIAL_PARENT, follow_symlinks=False))):
            _fail("recovery")
        check_fd, check_info, check_data = _open_private_state_file_at(root_fd, pointer_name)
        os.close(check_fd)
        if (_forward_identity_from_stat(check_info) != adoption["originalMarker"]["identity"]
                or check_data != pointer_data):
            _fail("recovery")
        _forward_inventory_recheck(
            inventory, added=frozenset({destination, temporary_pointer}))
        os.replace(
            temporary_pointer, pointer_name,
            src_dir_fd=root_fd, dst_dir_fd=root_fd,
        )
        _forward_adopt_boundary("pointer-renamed")
        os.fsync(root_fd)
        _forward_adopt_boundary("pointer-replaced")
    finally:
        if inventory is not None:
            inventory.close()
        if credential_parent_fd is not None:
            os.close(credential_parent_fd)
        os.close(root_fd)
    _result(marker["providerEnabled"], False, False, "forward-adopted")


def _forward_snapshots(state_root: str, adoption: dict[str, Any]) -> dict[str, bytes]:
    result = {}
    state_path = os.path.join(state_root, adoption["successorRunKey"] + "-final-deploy")
    total = 0
    for name in sorted({witness["snapshotRef"] for witness in adoption["sourceWitnesses"]
                        if witness["snapshotRef"] is not None}):
        fd, _, data = _open_private_state_file(os.path.join(state_path, name))
        os.close(fd)
        total += len(data)
        if total > MAX_WITNESS_BYTES:
            _fail("recovery")
        result[name] = data
    return result


def _forward_revalidate(state_root: str, run_key: str, inspection_data: bytes) -> None:
    _forward_deployment_lock(state_root)
    receipt = _forward_receipt_for_run(state_root, run_key)
    if receipt is None:
        _fail("recovery")
    adoption, _ = receipt
    marker = _marker(state_root, run_key)
    if marker["phase"] != "applying":
        _fail("recovery")
    snapshots = _forward_snapshots(state_root, adoption)
    root_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        with _forward_inventory(root_fd, state_root, run_key) as inventory:
            _forward_validate_origin(state_root, root_fd, adoption, snapshots)
            _forward_archive_preflight(state_root, os.fstat(root_fd), adoption)
            _forward_inventory_recheck(inventory)
    finally:
        os.close(root_fd)
    backend = _inspect(inspection_data)
    if _forward_stopped(backend, snapshots) != adoption["stoppedWitness"]:
        _fail("recovery")
    _forward_credential_preflight(marker, backend)
    _result(marker["providerEnabled"], False, False, "forward-revalidated")


def _forward_phase(state_root: str, run_key: str, phase: str) -> None:
    _forward_deployment_lock(state_root)
    if phase not in ("verifying", "finalizing"):
        _fail("recovery")
    receipt = _forward_receipt_for_run(state_root, run_key)
    if receipt is None:
        _fail("recovery")
    parent_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _lock_directory(parent_fd)
        inventory = _forward_inventory(parent_fd, state_root, run_key)
        try:
            _forward_publish_phase(state_root, run_key, phase, receipt, parent_fd, inventory)
        finally:
            inventory.close()
    finally:
        os.close(parent_fd)


def _forward_publish_phase(state_root: str, run_key: str, phase: str,
                           receipt: Any, parent_fd: int,
                           inventory: state_admission.Inventory) -> None:
    _forward_validate_origin(
        state_root, parent_fd, receipt[0], _forward_snapshots(state_root, receipt[0]))
    fd, info, data = _open_private_state_file_at(
        parent_fd, ".provider-transaction.current")
    try:
        marker = _marker(state_root, run_key)
        if marker["phase"] != {"verifying": "applying", "finalizing": "verifying"}[phase]:
            _fail("recovery")
        marker["phase"] = phase
        temporary = ".provider-transaction." + run_key + ".forward-phase"
        _forward_inventory_recheck(inventory)
        _write_private_at(parent_fd, temporary,
                          json.dumps(marker, separators=(",", ":")).encode(), 0o600)
        current_fd, current, current_data = _open_private_state_file_at(
            parent_fd, ".provider-transaction.current")
        os.close(current_fd)
        if (_forward_identity_from_stat(current) != _forward_identity_from_stat(info)
                or current_data != data):
            _fail("recovery")
        _forward_inventory_recheck(inventory, added=frozenset({temporary}))
        os.replace(temporary, ".provider-transaction.current",
                   src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        os.close(fd)


def _forward_complete(state_root: str, run_key: str, inspection_data: bytes) -> None:
    _forward_deployment_lock(state_root)
    receipt = _forward_receipt_for_run(state_root, run_key)
    if receipt is None:
        _fail("recovery")
    adoption, adoption_data = receipt
    marker = _marker(state_root, run_key)
    if marker["phase"] != "verifying":
        _fail("recovery")
    candidate = _inspect(inspection_data)
    snapshots = _forward_snapshots(state_root, adoption)
    pending = _forward_pending_module()
    try:
        pending.verify(
            "candidate", snapshots["config.env.target"], [candidate],
            candidate["Image"], adoption["stoppedWitness"]["containerId"],
            adoption["stoppedWitness"]["startedAt"], snapshots["config.env.production"],
            candidate["Id"], candidate["State"]["StartedAt"])
    except (ValueError, pending.Rejected):
        _fail("recovery")
    # A receipt never substitutes for final provider and private file checks.
    with contextlib.redirect_stdout(io.StringIO()):
        _verify(run_key, "", inspection_data, "candidate", state_root)
    acceptance = {
        "schemaVersion": 1, "originRunKey": FORWARD_ORIGIN_KEY,
        "successorRunKey": run_key, "adoptionSha256": hashlib.sha256(adoption_data).hexdigest(),
        "target": FORWARD_TARGET,
        "candidate": {"containerId": candidate["Id"],
                      "startedAt": candidate["State"]["StartedAt"],
                      "platformImageId": candidate["Image"]},
        "checks": {name: "pass" for name in ("runtime", "pendingOff", "provider", "publicHealth")},
        "plannedArchive": FORWARD_ARCHIVE,
    }
    acceptance_data = json.dumps(acceptance, separators=(",", ":")).encode()
    _validate_forward_acceptance(acceptance_data, adoption_data, run_key)
    _forward_phase(state_root, run_key, "finalizing")
    root_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    state_name = run_key + "-final-deploy"
    state_fd = os.open(os.path.join(state_root, state_name),
                       os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    archive_parent_fd = os.open(os.path.dirname(FORWARD_ARCHIVE),
                                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    inventory = None
    try:
        _lock_directory(root_fd)
        _lock_directory(state_fd)
        _lock_directory(archive_parent_fd)
        _validate_state_directory_fd(state_fd, state_name)
        _validate_retention_state_root_fd(root_fd)
        _revalidate_retention_state_root_path(state_root, os.fstat(root_fd))
        inventory = _forward_inventory(root_fd, state_root, run_key)
        if (_forward_identity_from_stat(os.fstat(archive_parent_fd))
                != adoption["plannedArchive"]["parentIdentity"]):
            _fail("recovery")
        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        _forward_archive_preflight(state_root, os.fstat(root_fd), adoption)
        for name in ("forward-acceptance.json", "terminal.json"):
            try:
                os.stat(name, dir_fd=state_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            _fail("recovery")
        _forward_adopt_boundary("acceptance-before")
        _forward_inventory_recheck(inventory)
        _write_private_at(state_fd, "forward-acceptance.json", acceptance_data, 0o600)
        _forward_adopt_boundary("acceptance-file-synced")
        os.fsync(state_fd)
        _forward_adopt_boundary("acceptance-directory-synced")
        _forward_adopt_boundary("credential-cleanup-before")
        _forward_inventory_recheck(inventory)
        durable_before = None
        durable_info_before = None
        if marker["providerEnabled"]:
            durable_info_before = os.stat(HOST_CREDENTIAL_PATH, follow_symlinks=False)
            _, durable_before = _read_existing(HOST_CREDENTIAL_PATH)
        with contextlib.redirect_stdout(io.StringIO()):
            _finish(run_key, state_root, "", "committed", inspection_data)
        _forward_adopt_boundary("credential-cleanup-after")
        if os.path.lexists(_transaction(HOST_CREDENTIAL_PARENT, FORWARD_ORIGIN_KEY)):
            _fail("recovery")
        if marker["providerEnabled"]:
            _, durable_after = _read_existing(HOST_CREDENTIAL_PATH)
            durable_info_after = os.stat(HOST_CREDENTIAL_PATH, follow_symlinks=False)
            if (durable_after != durable_before
                    or not _same_inode(durable_info_after, durable_info_before)
                    or durable_info_after.st_nlink != 1):
                _fail("recovery")
        _forward_validate_origin(state_root, root_fd, adoption, snapshots)
        _forward_archive_preflight(state_root, os.fstat(root_fd), adoption)
        origin_fd = os.open(FORWARD_ORIGIN_STATE,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        try:
            _forward_adopt_boundary("archive-before")
            _forward_inventory_recheck(inventory)
            _rename_noreplace(
                root_fd, FORWARD_ORIGIN_STATE, os.path.basename(FORWARD_ARCHIVE),
                expected_source_fd=origin_fd,
                expected_source_inode=(os.fstat(origin_fd).st_dev, os.fstat(origin_fd).st_ino),
                destination_directory_fd=archive_parent_fd)
            _forward_adopt_boundary("archive-renamed")
            _validate_forward_archive(adoption, state_root, require_source_absent=True)
            _forward_adopt_boundary("archive-source-parent-sync-before")
            os.fsync(root_fd)
            _forward_adopt_boundary("archive-source-parent-synced")
            _forward_adopt_boundary("archive-target-parent-sync-before")
            os.fsync(archive_parent_fd)
            _forward_adopt_boundary("archive-target-parent-synced")
        finally:
            os.close(origin_fd)
        terminal_data = json.dumps({
            "schemaVersion": 1, "runKey": run_key, "outcome": "committed",
            "providerEnabled": marker["providerEnabled"],
        }, separators=(",", ":")).encode()
        _forward_adopt_boundary("terminal-before")
        _forward_inventory_recheck(inventory, removed=frozenset({FORWARD_ORIGIN_STATE}))
        _write_private_at(state_fd, "terminal.json", terminal_data, 0o600)
        _forward_adopt_boundary("terminal-file-synced")
        os.fsync(state_fd)
        _forward_adopt_boundary("terminal-directory-synced")
        _validate_forward_retention_fd(
            state_fd, state_root, state_name, _bounded_retention_children(state_fd))
        pointer_fd, info, pointer_data = _open_private_state_file_at(
            root_fd, ".provider-transaction.current")
        os.close(pointer_fd)
        if _marker(state_root, run_key)["phase"] != "finalizing":
            _fail("recovery")
        _forward_adopt_boundary("pointer-unlink-before")
        _forward_inventory_recheck(inventory, removed=frozenset({FORWARD_ORIGIN_STATE}))
        _witnessed_unlink(
            root_fd, ".provider-transaction.current",
            expected_identity=_identity(info), expected_data=pointer_data,
            uid=0, gid=0, mode=0o600, link_count=1)
        _forward_adopt_boundary("pointer-unlinked")
        os.fsync(root_fd)
        _forward_adopt_boundary("pointer-unlink-parent-synced")
    finally:
        if inventory is not None:
            inventory.close()
        os.close(root_fd)
        os.close(state_fd)
        os.close(archive_parent_fd)
    with contextlib.redirect_stdout(io.StringIO()):
        _retention_check("", state_root)
    _result(marker["providerEnabled"], marker["providerEnabled"],
            marker["providerEnabled"], "committed")


def _credential_owner_key(
    run_key: str,
    state_root: str,
    enabled: bool,
) -> str:
    receipt = _forward_receipt_for_run(state_root, run_key)
    if receipt is None:
        return run_key
    adoption, _ = receipt
    expected = FORWARD_ORIGIN_KEY if enabled else None
    if adoption["originCredentialRunKey"] != expected:
        _fail("recovery")
    original = _json(base64.b64decode(adoption["originalMarker"]["bytesBase64"]),
                     "recovery")
    marker = _marker(state_root, run_key)
    if any(marker[key] != original[key] for key in (
            "providerEnabled", "durableDisposition")):
        _fail("recovery")
    # The immutable adoption binding authorizes only this original transaction
    # alias. Existing verify/finish code reopens the transaction and validates
    # its secret snapshot, identity, publication hard link, and durable file;
    # those credential descendants are not copied into the new state or placed
    # in sourceWitnesses, whose external entries are limited to config/tooling.
    return FORWARD_ORIGIN_KEY if enabled else run_key


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
) -> None:
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
        try:
            os.unlink(quarantine, dir_fd=directory_fd)
        except OSError:
            try:
                os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except FileNotFoundError:
                try:
                    os.rename(
                        quarantine,
                        name,
                        src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd,
                    )
                except OSError:
                    pass
            _fail("recovery")
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
        os.rmdir(name, dir_fd=parent_fd)
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
        os.mkdir(tx, 0o700)
        os.chown(tx, 0, 0)
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
    if (state_root and _forward_receipt_for_run(state_root, run_key) is not None
            and phase != "candidate"):
        _fail("recovery")
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
        credential_run_key = (
            _credential_owner_key(run_key, state_root, enabled)
            if state_root else run_key
        )
        tx = _transaction(
            _rooted(HOST_CREDENTIAL_PARENT, root), credential_run_key
        )
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
    marker = _marker(state_root, run_key)
    receipt = _forward_receipt_for_run(state_root, run_key)
    if receipt is not None:
        if outcome != "committed" or marker["phase"] != "finalizing":
            _fail("recovery")
        acceptance_fd, _, acceptance_data = _open_private_state_file(os.path.join(
            state_root, run_key + "-final-deploy", "forward-acceptance.json"))
        os.close(acceptance_fd)
        _validate_forward_acceptance(acceptance_data, receipt[1], run_key)
    disposition = marker["durableDisposition"]
    if marker["providerEnabled"] != enabled:
        _fail("recovery")
    credential_run_key = _credential_owner_key(
        run_key, state_root, enabled
    )
    tx = _transaction(parent, credential_run_key)
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
    with os.scandir(f"/proc/self/fd/{directory_fd}") as entries:
        for entry in entries:
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
    allowed_temporary: str | None = None,
) -> None:
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
        return
    try:
        for name in _iter_directory_fd_names(parent_fd):
            if name.startswith(".transaction-"):
                _fail("recovery")
    finally:
        os.close(parent_fd)


def _retention_interlocks(root: str, state_root: str) -> None:
    state_root_fd = os.open(
        state_root,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    try:
        _retention_interlocks_fd(root, state_root_fd)
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
        _retention_interlocks_fd(root, parent_fd)
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
                    child_names = _bounded_retention_children(state_fd)
                    _validate_forward_retention_fd(
                        state_fd, state_root, name, child_names
                    )
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
) -> None:
    owned_states = _retention_classify(
        root,
        state_root,
        protected_paths,
        protected_states,
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
    sys.stdout.buffer.write(encoded + b"\n")


def _retention_check(
    root: str,
    state_root: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
) -> None:
    _retention_classify(root, state_root, protected_paths, protected_states)
    _result(False, False, False, "retention-safe")


RETENTION_CHILDREN = frozenset(
    {
        "terminal.json",
        OWNER_MARKER,
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
FORWARD_RETENTION_CHILDREN = frozenset(
    {"forward-adoption.json", "forward-acceptance.json"}
)


def _bounded_retention_children(directory_fd: int) -> set[str] | None:
    names: set[str] = set()
    for name in _iter_directory_fd_names(directory_fd):
        if name not in RETENTION_CHILDREN | FORWARD_RETENTION_CHILDREN:
            return None
        names.add(name)
    return names


def _validate_forward_archive(
    adoption: dict[str, Any],
    state_root: str,
    *,
    require_source_absent: bool,
) -> None:
    archive_path = FORWARD_ARCHIVE
    archive_root = os.path.dirname(archive_path)
    try:
        _check_ancestors(archive_path, category="recovery")
        root_info = os.stat(archive_root, follow_symlinks=False)
        archive_info = os.stat(archive_path, follow_symlinks=False)
    except OSError:
        _fail("recovery")
    if (not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != 0
            or stat.S_IMODE(root_info.st_mode) != 0o700
            or not stat.S_ISDIR(archive_info.st_mode)
            or archive_info.st_uid != 0 or stat.S_IMODE(archive_info.st_mode) != 0o700):
        _fail("recovery")
    _acl_is_safe(archive_root, category="recovery")
    _acl_is_safe(archive_path, category="recovery")
    source_identity = adoption["originalStateIdentity"]
    actual_archive_identity = _forward_identity_from_stat(archive_info)
    # Rename may alter only directory metadata fields; inode, type, ownership,
    # and permissions remain the identity proof for the archived state root.
    for key in FORWARD_IDENTITY_KEYS - {"ctimeNs"}:
        if actual_archive_identity[key] != source_identity[key]:
            _fail("recovery")
    state_path = os.path.join(state_root, FORWARD_ORIGIN_STATE)
    if require_source_absent and os.path.lexists(state_path):
        _fail("recovery")

    expected: dict[str, dict[str, Any]] = {}
    root_witnesses = 0
    for witness in adoption["sourceWitnesses"]:
        path = witness["path"]
        if path == state_path:
            if witness["kind"] != "directory":
                _fail("recovery")
            root_witnesses += 1
            if witness["identity"] != source_identity:
                _fail("recovery")
            continue
        if path.startswith(state_path + "/"):
            relative = path[len(state_path) + 1:]
            if "/" in relative or relative in ("", ".", "..") or relative in expected:
                _fail("recovery")
            expected[relative] = witness
    if root_witnesses != 1:
        _fail("recovery")
    parent_identity = _forward_identity_from_stat(root_info)
    for key in ("device", "inode", "mode", "uid", "gid"):
        if parent_identity[key] != adoption["plannedArchive"]["parentIdentity"][key]:
            _fail("recovery")
    try:
        actual_names = set(os.listdir(archive_path))
    except OSError:
        _fail("recovery")
    if actual_names != set(expected):
        _fail("recovery")
    archive_fd = os.open(
        archive_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    )
    try:
        if (_forward_identity_from_stat(os.fstat(archive_fd))
                != actual_archive_identity):
            _fail("recovery")
        for name, witness in expected.items():
            try:
                info = os.stat(name, dir_fd=archive_fd, follow_symlinks=False)
            except OSError:
                _fail("recovery")
            identity = witness["identity"]
            if _forward_identity_from_stat(info) != identity:
                _fail("recovery")
            if witness["kind"] == "directory":
                if not stat.S_ISDIR(info.st_mode):
                    _fail("recovery")
                continue
            if not stat.S_ISREG(info.st_mode):
                _fail("recovery")
            fd, opened, data = _open_private_state_file_at(archive_fd, name)
            try:
                if _forward_identity_from_stat(opened) != identity:
                    _fail("recovery")
                if witness["snapshotRef"] is not None:
                    reference_fd, _, reference = _open_private_state_file(
                        os.path.join(state_root, adoption["successorRunKey"]
                                     + "-final-deploy", witness["snapshotRef"])
                    )
                    os.close(reference_fd)
                    if data != reference:
                        _fail("recovery")
                else:
                    import base64
                    embedded = base64.b64decode(witness["bytesBase64"], validate=True)
                    if data != embedded:
                        _fail("recovery")
            finally:
                os.close(fd)
        if (_forward_identity_from_stat(os.fstat(archive_fd))
                != _forward_identity_from_stat(os.stat(
                    archive_path, follow_symlinks=False))):
            _fail("recovery")
    finally:
        os.close(archive_fd)


def _validate_forward_retention_fd(
    state_fd: int,
    state_root: str,
    state_name: str,
    child_names: set[str] | None,
) -> None:
    if child_names is None:
        if {"forward-adoption.json", "forward-acceptance.json"} & set(
                _iter_directory_fd_names(state_fd)):
            _fail("recovery")
        return
    has_adoption = "forward-adoption.json" in (child_names or set())
    has_acceptance = "forward-acceptance.json" in (child_names or set())
    if has_adoption != has_acceptance:
        _fail("recovery")
    if not has_adoption:
        return
    successor, kind = _state_parts(state_name)
    if kind != "final-deploy":
        _fail("recovery")
    adoption_fd, _, adoption_data = _open_private_state_file_at(
        state_fd, "forward-adoption.json"
    )
    acceptance_fd, _, acceptance_data = _open_private_state_file_at(
        state_fd, "forward-acceptance.json"
    )
    try:
        adoption = _validate_forward_adoption(adoption_data, successor)
        _validate_forward_acceptance(
            acceptance_data, adoption_data, successor
        )
    finally:
        os.close(adoption_fd)
        os.close(acceptance_fd)
    terminal_fd, _, terminal_data = _open_private_state_file_at(
        state_fd, "terminal.json"
    )
    os.close(terminal_fd)
    outcome, enabled = _parse_terminal_state_data(terminal_data, state_name)
    original_marker = _json(base64.b64decode(
        adoption["originalMarker"]["bytesBase64"]), "recovery")
    if outcome != "committed" or enabled != original_marker["providerEnabled"]:
        _fail("recovery")
    _validate_forward_archive(adoption, state_root, require_source_absent=True)
    transaction = _transaction(
        HOST_CREDENTIAL_PARENT, FORWARD_ORIGIN_KEY
    )
    if os.path.lexists(transaction):
        _fail("recovery")


def _retention_delete(
    state_root: str,
    state_path: str,
    protected_paths: Iterable[str] = (),
    protected_states: Iterable[str] = (),
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
        _retention_interlocks_fd("", parent_fd)
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
            _validate_forward_retention_fd(
                state_fd, state_root, name, names
            )
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
            _retention_interlocks_fd("", parent_fd)
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
            os.fsync(parent_fd)
            _retention_interlocks_fd(
                "",
                parent_fd,
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
                os.fsync(quarantine_fd)
                if next(_iter_directory_fd_names(quarantine_fd), None) is not None:
                    _fail("recovery")
            finally:
                os.close(quarantine_fd)
            os.rmdir(quarantine, dir_fd=parent_fd)
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
            "state-publish",
            "forward-adopt",
            "forward-revalidate",
            "forward-phase",
            "forward-complete",
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
    parser.add_argument("--deployment-root", default="")
    parser.add_argument("--base-compose", default="")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    try:
        args = _parser().parse_args(list(argv) if argv is not None else None)
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
            _finish(args.run_key, args.state_root, "", args.outcome, _bounded_stdin(MAX_INSPECTION_BYTES))
        elif args.command == "state-publish":
            _state_publish(args.state_root, args.run_key, args.state_kind)
        elif args.command == "forward-adopt":
            _forward_admission(args.state_root, args.run_key, args.deployment_root,
                               args.base_compose, _bounded_stdin(MAX_INSPECTION_BYTES))
        elif args.command == "forward-revalidate":
            _forward_revalidate(args.state_root, args.run_key,
                                 _bounded_stdin(MAX_INSPECTION_BYTES))
        elif args.command == "forward-phase":
            _forward_phase(args.state_root, args.run_key, args.phase)
        elif args.command == "forward-complete":
            _forward_complete(args.state_root, args.run_key,
                              _bounded_stdin(MAX_INSPECTION_BYTES))
        elif args.command == "retention-list":
            _retention_list(
                "",
                args.state_root,
                args.protected_path,
                args.protected_state,
            )
        elif args.command == "retention-check":
            _retention_check(
                "",
                args.state_root,
                args.protected_path,
                args.protected_state,
            )
        else:
            _retention_delete(
                args.state_root,
                args.retention_state,
                args.protected_path,
                args.protected_state,
            )
        return 0
    except ProviderError as exc:
        sys.stderr.write(exc.category + "\n")
        return 1
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        sys.stderr.write(ERRORS["recovery"] + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
