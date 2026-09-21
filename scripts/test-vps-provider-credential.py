#!/usr/bin/env python3
"""Private, fail-closed Firebase credential reconciliation for the release lane.

This module deliberately has no network, Docker, shell, or environment mutation
capability.  Bash owns deployment ordering and recovery; this process only
validates bounded private observations and performs the fixed-path credential
transaction.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import re
import secrets
import stat
import sys
from typing import Any, Iterable

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


def _rename_noreplace(
    directory_fd: int,
    source: str,
    destination: str,
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


def _ensure_state_root(state_root: str) -> None:
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


def _state_publish(state_root: str, run_key: str, state_kind: str) -> None:
    _state_marker(run_key, state_kind)
    _ensure_state_root(state_root)
    name = f"{run_key}-{state_kind}"
    temporary = f".provider-state.{name}.tmp"
    parent_fd = os.open(state_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        _lock_directory(parent_fd)
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
            _write_private_at(
                temporary_fd,
                OWNER_MARKER,
                _state_marker(run_key, state_kind),
                0o600,
            )
            os.fsync(temporary_fd)
        finally:
            os.close(temporary_fd)
        os.fsync(parent_fd)
        _rename_noreplace(parent_fd, temporary, name)
        published_fd = os.open(
            name,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_fd,
        )
        try:
            published = os.fstat(published_fd)
            if published.st_uid != 0 or stat.S_IMODE(published.st_mode) != 0o700:
                _fail("recovery")
            _validate_state_directory(os.path.join(state_root, name), name)
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if not _same_inode(current, published):
                _fail("recovery")
        finally:
            os.close(published_fd)
        os.fsync(parent_fd)
    finally:
        os.close(parent_fd)


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
    if not isinstance(value["providerEnabled"], bool):
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

    def fail_witness() -> None:
        if witness_fd is not None:
            os.close(witness_fd)
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
        if entry_fd is not None:
            os.close(entry_fd)
        if witness_fd is not None:
            os.close(witness_fd)


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


def _validate_terminal_state(path: str, name: str) -> None:
    terminal = os.path.join(path, "terminal.json")
    terminal_fd, terminal_info, terminal_data = _open_private_state_file(terminal)
    os.close(terminal_fd)
    if terminal_info.st_uid != 0 or terminal_info.st_nlink != 1:
        _fail("recovery")
    value = _json(terminal_data, "recovery")
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
        or value["runKey"] != run_key
        or value["outcome"] not in ("committed", "rolled-back")
        or type(value["providerEnabled"]) is not bool
    ):
        _fail("recovery")


def _validate_terminal_state_fd(directory_fd: int, name: str) -> None:
    terminal_fd, terminal_info, terminal_data = _open_private_state_file_at(
        directory_fd,
        "terminal.json",
    )
    os.close(terminal_fd)
    if terminal_info.st_uid != 0 or terminal_info.st_nlink != 1:
        _fail("recovery")
    value = _json(terminal_data, "recovery")
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
        or value["runKey"] != run_key
        or value["outcome"] not in ("committed", "rolled-back")
        or type(value["providerEnabled"]) is not bool
    ):
        _fail("recovery")


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


def _retention_interlocks_fd(root: str, state_root_fd: int) -> None:
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
    for name in os.listdir(state_root_fd):
        if name.startswith(".provider-transaction.") or name.startswith(
            ".provider-state."
        ):
            _fail("recovery")
    if os.path.isdir(parent):
        for name in os.listdir(parent):
            if name.startswith(".transaction-"):
                _fail("recovery")


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
        references = [_retention_reference(path) for path in protected_paths]
        explicit_states: set[str] = set()
        for path in protected_states:
            _retention_reference(path)
            if (
                not isinstance(path, str)
                or os.path.dirname(path.rstrip("/")) != state_root.rstrip("/")
                or os.path.islink(path)
                or not os.path.isdir(path)
            ):
                _fail("recovery")
            explicit_states.add(os.path.normpath(path))
        owned_states: list[str] = []
        for name in os.listdir(parent_fd):
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
                    if set(os.listdir(state_fd)).issubset(RETENTION_CHILDREN):
                        owned_states.append(name)
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
                try:
                    os.stat(OWNER_MARKER, dir_fd=state_fd, follow_symlinks=False)
                except FileNotFoundError:
                    pass
                else:
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
    references = [_retention_reference(path) for path in protected_paths]
    for protected in protected_states:
        _retention_reference(protected)
        if (
            not isinstance(protected, str)
            or os.path.dirname(protected.rstrip("/")) != root_norm
            or os.path.islink(protected)
            or not os.path.isdir(protected)
        ):
            _fail("recovery")
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
        try:
            if not _same_inode(os.fstat(state_fd), state_info):
                _fail("recovery")
            _lock_directory(state_fd)
            if not _same_inode(os.fstat(state_fd), state_info):
                _fail("recovery")
            _validate_state_directory_fd(state_fd, name)
            _validate_terminal_state_fd(state_fd, name)
            names = set(os.listdir(state_fd))
            if not names or not names.issubset(RETENTION_CHILDREN):
                _fail("recovery")
            if OWNER_MARKER not in names or "terminal.json" not in names:
                _fail("recovery")
            witnesses: dict[str, tuple[dict[str, int], bytes]] = {}
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
            quarantine = f".provider-state.{name}.tmp"
            try:
                os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                _fail("recovery")
            _rename_noreplace(parent_fd, name, quarantine)
            os.fsync(parent_fd)
            quarantine_fd = os.open(
                quarantine,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=parent_fd,
            )
            try:
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
                if os.listdir(quarantine_fd):
                    _fail("recovery")
            finally:
                os.close(quarantine_fd)
            os.rmdir(quarantine, dir_fd=parent_fd)
            os.fsync(parent_fd)
        finally:
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
    except (OSError, ValueError, TypeError, KeyError):
        sys.stderr.write(ERRORS["recovery"] + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
