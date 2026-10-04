#!/usr/bin/env python3
"""Collect bounded, read-only metadata for the three owned Engine files."""

from __future__ import annotations

import json
import os
import posixpath
import re
import stat
import sys
import time

MAX_REQUEST = 1024
MAX_RESPONSE = 64 * 1024
MAX_MOUNTINFO = 1024 * 1024
MAX_PATH = 4096
DEADLINE_SECONDS = 30
DENIAL = b"HOST_METADATA_DENIED\n"
ENVIRONMENT = {
    "PATH": "/usr/bin:/bin",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "TZ": "UTC",
    "HOME": "/",
}
LEAVES = {
    "/etc/hostname": "hostname",
    "/etc/hosts": "hosts",
    "/etc/resolv.conf": "resolv.conf",
}
HEX32 = re.compile(r"^[0-9a-f]{32}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
API_VERSION = re.compile(r"^[0-9]+\.[0-9]+$")


class Denied(Exception):
    pass


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise Denied()
        result[key] = value
    return result


def validate_request(raw: bytes) -> dict[str, object]:
    if not raw or len(raw) > MAX_REQUEST:
        raise Denied()
    try:
        value = json.loads(
            raw.decode("utf-8", errors="strict"),
            object_pairs_hook=_unique_object,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, Denied) as error:
        raise Denied() from error
    if (
        not isinstance(value, dict)
        or set(value)
        != {
            "schemaVersion",
            "containerId",
            "owner",
            "dockerRootDir",
            "engineVersion",
            "engineApiVersion",
        }
        or type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != 1
        or not isinstance(value["containerId"], str)
        or not HEX64.fullmatch(value["containerId"])
        or not isinstance(value["owner"], str)
        or not HEX32.fullmatch(value["owner"])
        or not isinstance(value["dockerRootDir"], str)
        or not isinstance(value["engineVersion"], str)
        or not VERSION.fullmatch(value["engineVersion"])
        or not isinstance(value["engineApiVersion"], str)
        or not API_VERSION.fullmatch(value["engineApiVersion"])
    ):
        raise Denied()
    root = value["dockerRootDir"]
    if (
        not root.startswith("/")
        or root == "/"
        or len(root.encode("utf-8")) > MAX_PATH
        or "\x00" in root
        or "\n" in root
        or "\r" in root
        or posixpath.normpath(root) != root
        or any(part in ("", ".", "..") for part in root.split("/")[1:])
    ):
        raise Denied()
    if json.dumps(value, sort_keys=True, separators=(",", ":")).encode() != raw:
        raise Denied()
    return value


def _mount_unescape(value: str) -> str:
    return re.sub(
        r"\\(040|011|012|134)",
        lambda match: {
            "040": " ",
            "011": "\t",
            "012": "\n",
            "134": "\\",
        }[match.group(1)],
        value,
    )


def _read_mountinfo(ops: object) -> bytes:
    descriptor = ops.open(
        "/proc/self/mountinfo",
        ops.O_RDONLY | ops.O_CLOEXEC | ops.O_NOFOLLOW,
    )
    chunks: list[bytes] = []
    size = 0
    try:
        while True:
            chunk = ops.read(descriptor, min(65536, MAX_MOUNTINFO + 1 - size))
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_MOUNTINFO:
                raise Denied()
            chunks.append(chunk)
    finally:
        ops.close(descriptor)
    if not chunks:
        raise Denied()
    return b"".join(chunks)


def _parse_mountinfo(raw: bytes) -> list[dict[str, str]]:
    try:
        lines = raw.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as error:
        raise Denied() from error
    mounts: list[dict[str, str]] = []
    for line in lines:
        before, separator, after = line.partition(" - ")
        left = before.split()
        right = after.split()
        if (
            not separator
            or len(left) < 6
            or len(right) < 3
            or not re.fullmatch(r"[0-9]+:[0-9]+", left[2])
        ):
            raise Denied()
        mounts.append(
            {
                "root": _mount_unescape(left[3]),
                "mountpoint": _mount_unescape(left[4]),
                "device": left[2],
            }
        )
    if not mounts:
        raise Denied()
    return mounts


def _device_number(device: int) -> str:
    major = (device >> 8) & 0xFFF
    major |= (device >> 32) & 0xFFFFF000
    minor = device & 0xFF
    minor |= (device >> 12) & 0xFFFFFF00
    return f"{major}:{minor}"


def _backing_mount(path: str, mounts: list[dict[str, str]]) -> dict[str, str]:
    candidates = [
        mount
        for mount in mounts
        if path == mount["mountpoint"]
        or path.startswith(mount["mountpoint"].rstrip("/") + "/")
    ]
    if not candidates:
        raise Denied()
    depth = max(len(mount["mountpoint"]) for mount in candidates)
    deepest = [mount for mount in candidates if len(mount["mountpoint"]) == depth]
    if len(deepest) != 1:
        raise Denied()
    mount = deepest[0]
    relative = posixpath.relpath(path, mount["mountpoint"])
    root = (
        mount["root"]
        if relative == "."
        else posixpath.normpath(posixpath.join(mount["root"], relative))
    )
    return {"root": root, "device": mount["device"]}


def _identity(info: object) -> tuple[int, int, int, int, int]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid)


def _directory(
    ops: object, parent: int, component: str
) -> tuple[int, tuple[str, int, int, int, int, int]]:
    before = ops.stat(component, dir_fd=parent, follow_symlinks=False)
    if (
        not stat.S_ISDIR(before.st_mode)
        or before.st_uid != 0
        or before.st_mode & 0o022
    ):
        raise Denied()
    descriptor = ops.open(
        component,
        ops.O_RDONLY | ops.O_DIRECTORY | ops.O_CLOEXEC | ops.O_NOFOLLOW,
        dir_fd=parent,
    )
    after = ops.fstat(descriptor)
    if _identity(before) != _identity(after):
        ops.close(descriptor)
        raise Denied()
    return descriptor, (component, *_identity(after))


def _walk(
    ops: object, request: dict[str, object]
) -> tuple[list[int], list[tuple[str, int, int, int, int, int]], dict[str, dict[str, int]]]:
    descriptors: list[int] = []
    directories: list[tuple[str, int, int, int, int, int]] = []
    try:
        current = ops.open(
            "/",
            ops.O_RDONLY | ops.O_DIRECTORY | ops.O_CLOEXEC | ops.O_NOFOLLOW,
        )
        descriptors.append(current)
        root_info = ops.fstat(current)
        if (
            not stat.S_ISDIR(root_info.st_mode)
            or root_info.st_uid != 0
            or root_info.st_mode & 0o022
        ):
            raise Denied()
        directories.append(("/", *_identity(root_info)))
        components = request["dockerRootDir"].split("/")[1:]
        components.extend(("containers", request["containerId"]))
        for component in components:
            current, identity = _directory(ops, current, component)
            descriptors.append(current)
            directories.append(identity)

        files: dict[str, dict[str, int]] = {}
        for target, leaf in LEAVES.items():
            before = ops.stat(leaf, dir_fd=current, follow_symlinks=False)
            descriptor = ops.open(
                leaf,
                ops.O_PATH | ops.O_CLOEXEC | ops.O_NOFOLLOW,
                dir_fd=current,
            )
            descriptors.append(descriptor)
            after = ops.fstat(descriptor)
            if (
                _identity(before) != _identity(after)
                or not stat.S_ISREG(after.st_mode)
                or after.st_uid != 0
            ):
                raise Denied()
            files[target] = {
                "mode": after.st_mode,
                "uid": after.st_uid,
                "gid": after.st_gid,
                "device": after.st_dev,
                "inode": after.st_ino,
            }
        return descriptors, directories, files
    except BaseException:
        for descriptor in reversed(descriptors):
            try:
                ops.close(descriptor)
            except OSError:
                pass
        raise


def _close_all(ops: object, descriptors: list[int]) -> None:
    for descriptor in reversed(descriptors):
        try:
            ops.close(descriptor)
        except OSError:
            pass


def collect_metadata(raw_request: bytes, *, ops: object = os) -> dict[str, object]:
    request = validate_request(raw_request)
    deadline = time.monotonic() + DEADLINE_SECONDS
    mountinfo_before = _read_mountinfo(ops)
    first_fds: list[int] = []
    second_fds: list[int] = []
    try:
        first_fds, first_directories, first_files = _walk(ops, request)
        before_mounts = _parse_mountinfo(mountinfo_before)
        paths = {
            target: (
                request["dockerRootDir"]
                + "/containers/"
                + request["containerId"]
                + "/"
                + leaf
            )
            for target, leaf in LEAVES.items()
        }
        if any(len(path.encode("utf-8")) > MAX_PATH for path in paths.values()):
            raise Denied()
        mappings = {
            target: _backing_mount(path, before_mounts)
            for target, path in paths.items()
        }
        mountinfo_after = _read_mountinfo(ops)
        second_fds, second_directories, second_files = _walk(ops, request)
        after_mounts = _parse_mountinfo(mountinfo_after)
        if (
            time.monotonic() > deadline
            or first_directories != second_directories
            or first_files != second_files
            or mountinfo_before != mountinfo_after
        ):
            raise Denied()
        files: dict[str, dict[str, object]] = {}
        for target in LEAVES:
            metadata = first_files[target]
            mapping = mappings[target]
            if (
                _device_number(metadata["device"]) != mapping["device"]
                or _backing_mount(paths[target], after_mounts) != mapping
            ):
                raise Denied()
            files[target] = {
                "source": paths[target],
                **metadata,
                "mountRoot": mapping["root"],
                "mountDevice": mapping["device"],
            }
        result: dict[str, object] = {
            "schemaVersion": 1,
            "containerId": request["containerId"],
            "owner": request["owner"],
            "dockerRootDir": request["dockerRootDir"],
            "engineVersion": request["engineVersion"],
            "engineApiVersion": request["engineApiVersion"],
            "files": files,
        }
        if (
            len(json.dumps(result, sort_keys=True, separators=(",", ":")).encode())
            + 1
            > MAX_RESPONSE
        ):
            raise Denied()
        return result
    finally:
        _close_all(ops, second_fds)
        _close_all(ops, first_fds)


def main() -> int:
    os.environ.clear()
    os.environ.update(ENVIRONMENT)
    try:
        if os.geteuid() != 0:
            raise Denied()
        request = sys.stdin.buffer.read(MAX_REQUEST + 1)
        if len(request) > MAX_REQUEST:
            raise Denied()
        result = collect_metadata(request)
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
        if len(encoded) + 1 > MAX_RESPONSE:
            raise Denied()
        remaining = memoryview(encoded + b"\n")
        while remaining:
            remaining = remaining[os.write(sys.stdout.fileno(), remaining) :]
    except BaseException:
        try:
            os.write(sys.stderr.fileno(), DENIAL)
        except BaseException:
            pass
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
