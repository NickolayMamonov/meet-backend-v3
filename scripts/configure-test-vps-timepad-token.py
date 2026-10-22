#!/usr/bin/env python3
"""Configure only the Timepad token; never restart or enable ingestion."""

import datetime
import fcntl
import http.client
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import urllib.parse
import zoneinfo

MAX_BYTES = 1_048_576
MAX_TOKEN = 4096
ROOT = Path("/opt/meet-backend")
STATE = Path("/var/lib/meet-test-vps-deploy")
IMAGE = (
    "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:"
    "1b52b464457b2ed7fda02394e27a8d830e7d803fd27e23c63b4410a60f26a8e5"
)


class Rejected(Exception):
    pass


def no_acl(fd: int) -> None:
    # This narrow configurator accepts the existing plain POSIX permissions only.
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


def private_file(parent: int, name: str) -> tuple[int, bytes, os.stat_result]:
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOATIME,
                 dir_fd=parent)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0
                or info.st_gid != 0 or info.st_nlink != 1
                or stat.S_IMODE(info.st_mode) != 0o600):
            raise Rejected("unsafe_private_file")
        no_acl(fd)
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


def validate_token(raw: bytes) -> str:
    if not re.fullmatch(rb"[A-Za-z0-9._~+/-]{1,4096}={0,2}", raw) or len(raw) > MAX_TOKEN:
        raise Rejected("invalid_token_format")
    return raw.decode("ascii")


def candidate(data: bytes, token: str) -> bytes:
    if b"\0" in data or not data.endswith(b"\n"):
        raise Rejected("invalid_environment")
    lines = data.decode("utf-8").splitlines(keepends=True)
    for line in lines:
        match = re.match(r"^\s*(?:export\s+)?(TIMEPAD_TOKEN|TIMEPAD_ENABLED|INGESTION_ENABLED)\s*=", line)
        if match and not line.startswith(match[1] + "="):
            raise Rejected("noncanonical_assignment")
    for key in ("TIMEPAD_ENABLED", "INGESTION_ENABLED"):
        values = [line.rstrip("\r\n").split("=", 1)[1]
                  for line in lines if line.startswith(key + "=")]
        if values != ["false"]:
            raise Rejected("feed_must_be_off")
    positions = [i for i, line in enumerate(lines) if line.startswith("TIMEPAD_TOKEN=")]
    if len(positions) > 1:
        raise Rejected("duplicate_token_assignment")
    if positions:
        i = positions[0]
        ending = "\r\n" if lines[i].endswith("\r\n") else "\n"
        lines[i] = "TIMEPAD_TOKEN=" + token + ending
    else:
        lines.append("TIMEPAD_TOKEN=" + token + "\n")
    return "".join(lines).encode("utf-8")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise Rejected("duplicate_provider_field")
        result[key] = value
    return result


def probe(token: str) -> dict:
    today = datetime.datetime.now(zoneinfo.ZoneInfo("Europe/Moscow")).date()
    query = urllib.parse.urlencode({
        "limit": "100", "skip": "0", "sort": "+starts_at",
        "fields": "location,categories,ends_at,access_status,registration_data,locale",
        "starts_at_min": today.isoformat(),
        "starts_at_max": (today + datetime.timedelta(days=180)).isoformat(),
    }, quote_via=urllib.parse.quote)
    connection = http.client.HTTPSConnection("api.timepad.ru", timeout=3)
    try:
        connection.connect()
        connection.sock.settimeout(10)
        connection.request("GET", "/v1/events.json?" + query, headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/json", "Accept-Encoding": "identity",
        })
        response = connection.getresponse()
        if response.status != 200:
            raise Rejected("provider_http_" + str(response.status))
        if response.getheader("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            raise Rejected("provider_content_type")
        if response.getheader("Content-Encoding", "identity").lower() != "identity":
            raise Rejected("provider_content_encoding")
        data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise Rejected("provider_body_budget")
        value = json.loads(data, object_pairs_hook=unique_object)
        if (not isinstance(value, dict) or type(value.get("total")) is not int
                or value["total"] < 0 or not isinstance(value.get("values"), list)
                or len(value["values"]) != min(value["total"], 100)):
            raise Rejected("provider_schema")
        return {"provider_http": 200, "total": value["total"],
                "within_discovery_budget": value["total"] <= 500}
    finally:
        connection.close()


def runtime() -> tuple[str, str]:
    running = subprocess.run(
        ["docker", "ps", "-q", "--filter", "label=com.docker.compose.service=backend"],
        capture_output=True, check=True, timeout=10,
    ).stdout.splitlines()
    if len(running) != 1:
        raise Rejected("single_backend_required")
    output = subprocess.run(
        ["docker", "inspect", "meet-production-backend-1"],
        capture_output=True, check=True, timeout=10,
    ).stdout
    if len(output) > MAX_BYTES:
        raise Rejected("runtime_budget")
    records = json.loads(output)
    backend = records[0]
    env = dict(item.split("=", 1) for item in backend["Config"]["Env"])
    if (len(records) != 1 or backend["Config"]["Image"] != IMAGE
            or not backend["State"]["Running"]
            or backend["State"]["Health"]["Status"] != "healthy"
            or env.get("TIMEPAD_ENABLED") != "false"
            or env.get("INGESTION_ENABLED") != "false"):
        raise Rejected("unexpected_runtime")
    return backend["Id"], backend["State"]["StartedAt"]


def configure(env_path: Path, state: Path, raw: bytes,
              check_runtime=runtime, check_provider=probe) -> dict:
    token = validate_token(raw)
    parent = directory(env_path.parent)
    state_fd = lock_fd = env_fd = -1
    temporary = None
    committed = False
    try:
        state_fd = directory(state)
        lock_fd, _, _ = private_file(state_fd, ".deploy.lock")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            try:
                os.stat(name, dir_fd=state_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise Rejected("unresolved_transaction")
        env_fd, before, info = private_file(parent, env_path.name)
        after = candidate(before, token)
        previous_runtime = check_runtime()
        result = check_provider(token)
        # Probe first: rejected/blocked credentials never replace the stored token.
        if check_runtime() != previous_runtime:
            raise Rejected("runtime_changed")
        current, data, current_info = private_file(parent, env_path.name)
        os.close(current)
        if identity(info) != identity(current_info) or data != before:
            raise Rejected("environment_changed")
        if after != before:
            fd, temporary = tempfile.mkstemp(prefix=".timepad-token-", dir=env_path.parent)
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(os.dup(fd), "wb") as stream:
                    stream.write(after)
                    stream.flush()
                os.fsync(fd)
            finally:
                os.close(fd)
            os.replace(temporary, env_path.name, dst_dir_fd=parent)
            temporary = None
            committed = True
            os.fsync(parent)
        return {**result, "token_configured": True, "backend_restarted": False,
                "ingestion_enabled": False, "runtime_token_unchanged_until_restart": True}
    except (OSError, Rejected):
        if committed:
            raise Rejected("token_stored_durability_uncertain") from None
        raise
    finally:
        if temporary is not None:
            os.unlink(temporary)
        for fd in (env_fd, lock_fd, state_fd, parent):
            if fd >= 0:
                os.close(fd)


def deadline(_signal, _frame) -> None:
    raise Rejected("deadline")


def main() -> int:
    try:
        if os.geteuid() != 0 or len(sys.argv) != 1:
            raise Rejected("root_no_arguments_required")
        signal.signal(signal.SIGALRM, deadline)
        signal.alarm(40)
        result = configure(ROOT / ".env.production", STATE,
                           sys.stdin.buffer.read(MAX_TOKEN + 1))
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Rejected as error:
        print(json.dumps({"error": error.args[0], "backend_restarted": False}))
        return 1
    except (OSError, ValueError, subprocess.SubprocessError, http.client.HTTPException, RecursionError):
        print('{"error":"configuration_or_transport_failed","backend_restarted":false}')
        return 1
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
