"""Shared file trust boundary for the bounded test-VPS helpers."""

import os
from pathlib import Path
import stat

MAX_BYTES = 1_048_576


class Rejected(Exception):
    pass


def no_acl(fd: int) -> None:
    # Accept the existing plain POSIX permissions only.
    if any(name.startswith("system.posix_acl_") for name in os.listxattr(fd)):
        raise Rejected("unexpected_acl")


def directory(path: Path) -> int:
    if not path.is_absolute() or ".." in path.parts:
        raise Rejected("unsafe_path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in path.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
            info = os.fstat(fd)
            if info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
                raise Rejected("unsafe_directory")
            no_acl(fd)
        return fd
    except BaseException:
        os.close(fd)
        raise


def private_file(parent: int, name: str, *, deployment_lock: bool = False
                 ) -> tuple[int, bytes, os.stat_result]:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOATIME,
                 dir_fd=parent)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or info.st_gid != 0 or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) not in (
                    (0o600, 0o644) if deployment_lock else (0o600,))):
            raise Rejected("unsafe_private_file")
        no_acl(fd)
        # The existing coordinator lock contains no secrets and may be world-readable.
        if deployment_lock and info.st_size != 0:
            raise Rejected("nonempty_deployment_lock")
        with os.fdopen(os.dup(fd), "rb") as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise Rejected("file_budget")
        if identity(info) != identity(os.fstat(fd)):
            raise Rejected("file_changed")
        return fd, data, info
    except BaseException:
        os.close(fd)
        raise


def identity(info: os.stat_result) -> tuple[int, ...]:
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
