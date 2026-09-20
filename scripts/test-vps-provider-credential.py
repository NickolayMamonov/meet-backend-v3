#!/usr/bin/env python3
"""Private, fail-closed Firebase credential reconciliation for the release lane.

This module deliberately has no network, Docker, shell, or environment mutation
capability.  Bash owns deployment ordering and recovery; this process only
validates bounded private observations and performs the fixed-path credential
transaction.
"""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import stat
import sys
from typing import Any, Iterable

SCHEMA_VERSION = 1
MAX_INSPECTION_BYTES = 8 * 1024 * 1024
MAX_CREDENTIAL_BYTES = 1024 * 1024
MAX_JSON_DEPTH = 32
CONTAINER_CREDENTIAL_PATH = "/run/secrets/meet-firebase-service-account.json"
HOST_CREDENTIAL_PARENT = "/var/lib/meet-production/credentials"
HOST_CREDENTIAL_PATH = HOST_CREDENTIAL_PARENT + "/firebase-service-account.json"
EXPECTED_PROJECT = "meeting-1d258"
RUN_KEY_RE = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"
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
            sort_keys=True,
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


def _acl_is_safe(path: str, *, follow_symlinks: bool = False) -> bool:
    # An extended access ACL is not represented by ordinary mode bits.  If the
    # Linux xattr interface is available, reject an ACL we cannot prove safe.
    getter = getattr(os, "getxattr", None)
    if getter is None:
        return True
    try:
        getter(path, "system.posix_acl_access", follow_symlinks=follow_symlinks)
    except OSError as exc:
        if exc.errno in (
            errno.ENODATA,
            errno.ENOATTR if hasattr(errno, "ENOATTR") else errno.ENODATA,
        ):
            return True
        _fail("credential")
    return False


def _components(path: str) -> tuple[str, list[str]]:
    if not isinstance(path, str) or not path.startswith("/") or "\x00" in path:
        _fail("credential")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts[1:]):
        _fail("credential")
    return "/", parts[1:]


def _check_ancestors(path: str) -> None:
    base, parts = _components(path)
    fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        root_info = os.fstat(fd)
        if root_info.st_uid != 0 or stat.S_IMODE(root_info.st_mode) & (
            stat.S_IWGRP | stat.S_IWOTH
        ):
            _fail("credential")
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                info = os.fstat(child)
                if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & (stat.S_IWGRP | stat.S_IWOTH):
                    _fail("credential")
                if not _acl_is_safe(f"/proc/self/fd/{child}", follow_symlinks=True):
                    _fail("credential")
            finally:
                os.close(fd)
            fd = child
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


def _provider_state(inspect: dict[str, Any]) -> tuple[bool, dict[str, str]]:
    config = inspect.get("Config")
    if not isinstance(config, dict):
        _fail("provider")
    entries = _env_entries(inspect)
    values = dict(entries)
    for key, value in entries:
        normalized = key.upper().replace("-", "_")
        if normalized in PUSH_KEYS and key != normalized:
            _fail("provider")
        if normalized in ("SPRING_APPLICATION_JSON",):
            if value:
                _fail("provider")
        if key in (
            "SPRING_CONFIG_LOCATION",
            "SPRING_CONFIG_ADDITIONAL_LOCATION",
            "SPRING_CONFIG_IMPORT",
        ) and value:
            _fail("provider")
        if key in ("JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS"):
            if any(
                token in value
                for token in (
                    "app.push",
                    "APP_PUSH",
                    "spring.config.location",
                    "spring.config.additional-location",
                    "spring.config.import",
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
            token in item
            for item in command
            for token in (
                "--app.push",
                "-Dapp.push",
                "spring.config.location",
                "spring.config.additional-location",
                "spring.config.import",
            )
        ):
            _fail("provider")
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
    if project and project != EXPECTED_PROJECT:
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


def _provider_mount(inspect: dict[str, Any], enabled: bool) -> tuple[bool, bool, str | None]:
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
    if source != HOST_CREDENTIAL_PATH:
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
    # Production paths are compiled constants.  Tests can inject a complete
    # filesystem root by importing this module and replacing these constants.
    if root:
        if path == HOST_CREDENTIAL_PARENT:
            return root
        if path.startswith(HOST_CREDENTIAL_PARENT + "/"):
            return root + path[len(HOST_CREDENTIAL_PARENT) :]
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
    if not _acl_is_safe(parent):
        _fail("credential")


def _write_private(path: str, data: bytes, mode: int, gid: int = 0) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        offset = 0
        while offset < len(data):
            offset += os.write(fd, data[offset:])
        os.fsync(fd)
        os.fchown(fd, 0, gid)
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)


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
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        _fail("recovery")
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o600:
            _fail("recovery")
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
    if value["schemaVersion"] != SCHEMA_VERSION or value["runKey"] != run_key:
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


def _validate_identity(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion",
        "predecessor",
        "durable",
    }:
        _fail("recovery")
    if value["schemaVersion"] != SCHEMA_VERSION:
        _fail("recovery")
    for record in (value["predecessor"], value["durable"]):
        if not isinstance(record, dict) or set(record) != {
            "device",
            "inode",
            "mtimeNs",
            "ctimeNs",
        }:
            _fail("recovery")
        if any(not isinstance(record[key], int) or record[key] < 0 for key in record):
            _fail("recovery")


def _validate_transaction(tx: str) -> None:
    if not os.path.isdir(tx) or os.path.islink(tx):
        _fail("recovery")
    info = os.stat(tx, follow_symlinks=False)
    if info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
        _fail("recovery")
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


def _prepare(run_key: str, state_root: str, root: str, inspect_data: bytes) -> tuple[bool, bool, bool]:
    inspect, previous = _inspect_records(inspect_data)
    enabled, _ = _provider_state(inspect)
    if previous is not None:
        if _effective_tuple(inspect) != _effective_tuple(previous):
            _fail("provider")
    present, read_only, source = _provider_mount(inspect, enabled)
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
                    or publication_info.st_nlink < 2
                ):
                    _fail("changed")
                disposition = "created"
            _revalidate_open_source(source, source_fd, source_info, source_data)
            _record(tx, source_identity, durable_identity)
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        except Exception:
            # Never remove a published destination here.  Bash recovery/retention
            # must prove ownership before cleanup after a failed publication.
            raise
        _result(True, present, read_only, "prepared")
        return True, present, read_only
    finally:
        os.close(source_fd)


def _verify(run_key: str, root: str, inspect_data: bytes, phase: str) -> None:
    if phase not in ("predecessor", "candidate", "rollback"):
        _fail("provider")
    inspect, previous = _inspect_records(inspect_data)
    enabled, _ = _provider_state(inspect)
    if previous is not None and _effective_tuple(inspect) != _effective_tuple(previous):
        _fail("provider")
    present, read_only, source = _provider_mount(inspect, enabled)
    if enabled:
        if source is None:
            _fail("provider")
        if phase == "candidate" and source != HOST_CREDENTIAL_PATH:
            _fail("provider")
        if phase == "rollback" and previous is not None:
            _, previous_present, previous_source = (
                _provider_mount(previous, _provider_state(previous)[0])
            )
            if previous_present != present or previous_source != source:
                _fail("provider")
        destination = _rooted(HOST_CREDENTIAL_PATH, root)
        _, durable = _read_existing(destination)
        _validate_credential(durable)
        tx = _transaction(_rooted(HOST_CREDENTIAL_PARENT, root), run_key)
        snapshot_path = os.path.join(tx, "snapshot")
        if phase in ("candidate", "rollback"):
            _validate_transaction(tx)
        snapshot = _read_private(snapshot_path)
        if snapshot != durable:
            _fail("changed")
    _result(enabled, present, read_only, "verified")


def _finish(run_key: str, state_root: str, root: str, outcome: str, inspect_data: bytes) -> None:
    if outcome not in ("committed", "rolled-back"):
        _fail("provider")
    inspect = _inspect(inspect_data)
    enabled, _ = _provider_state(inspect)
    present, read_only, source = _provider_mount(inspect, enabled)
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
            if present and source == HOST_CREDENTIAL_PATH:
                _fail("recovery")
            os.unlink(destination)
        for name in ("identity.json", "snapshot", "publication"):
            path = os.path.join(tx, name)
            if os.path.lexists(path):
                os.unlink(path)
        os.rmdir(tx)
    _result(enabled, present, read_only, outcome)


def _check() -> None:
    required = ("O_NOFOLLOW", "O_DIRECTORY", "O_NONBLOCK", "O_NOATIME")
    if any(not hasattr(os, name) for name in required):
        _fail("prerequisite")
    if not hasattr(os, "link") or not hasattr(os, "fsync") or not hasattr(os.stat_result, "st_mtime_ns"):
        _fail("prerequisite")
    _result(False, False, False, "checked")


def _retention_check(root: str, state_root: str) -> None:
    parent = _rooted(HOST_CREDENTIAL_PARENT, root)
    marker = os.path.join(state_root, ".provider-transaction.current")
    if os.path.lexists(marker):
        _fail("recovery")
    if os.path.isdir(state_root) and any(
        name.startswith(".provider-transaction.")
        for name in os.listdir(state_root)
    ):
        _fail("recovery")
    if os.path.isdir(parent):
        for name in os.listdir(parent):
            if name.startswith(".transaction-"):
                _fail("recovery")
    _result(False, False, False, "retention-safe")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", choices=("check", "observe", "prepare", "verify", "finish", "retention-check"))
    parser.add_argument("--run-key", default="")
    parser.add_argument("--state-root", default="/var/lib/meet-test-vps-deploy")
    parser.add_argument("--filesystem-root", "--root", dest="filesystem_root", default="")
    parser.add_argument("--phase", default="")
    parser.add_argument("--outcome", default="")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    try:
        args = _parser().parse_args(list(argv) if argv is not None else None)
        if args.command == "check":
            _check()
        elif args.command == "observe":
            inspect = _inspect(_bounded_stdin(MAX_INSPECTION_BYTES))
            enabled, _ = _provider_state(inspect)
            present, read_only, _ = _provider_mount(inspect, enabled)
            _result(enabled, present, read_only, "observed")
        elif args.command == "prepare":
            _run_key(args.run_key)
            _prepare(args.run_key, args.state_root, args.filesystem_root, _bounded_stdin(MAX_INSPECTION_BYTES))
        elif args.command == "verify":
            _run_key(args.run_key)
            _verify(args.run_key, args.filesystem_root, _bounded_stdin(MAX_INSPECTION_BYTES), args.phase)
        elif args.command == "finish":
            _run_key(args.run_key)
            _finish(args.run_key, args.state_root, args.filesystem_root, args.outcome, _bounded_stdin(MAX_INSPECTION_BYTES))
        else:
            _retention_check(args.filesystem_root, args.state_root)
        return 0
    except ProviderError as exc:
        sys.stderr.write(exc.category + "\n")
        return 1
    except (OSError, ValueError, TypeError, KeyError):
        sys.stderr.write(ERRORS["recovery"] + "\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
