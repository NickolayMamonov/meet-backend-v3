#!/usr/bin/env python3
"""Deliver one LocationIQ key with persistent explicit OFF; never activate."""

import sys

sys.dont_write_bytecode = True

import fcntl
import json
import os
from pathlib import Path
import re
import resource
import selectors
import signal
import stat
import subprocess
import tempfile
import time

from test_vps_file_trust import Rejected, directory, identity, private_file

ROOT = Path("/opt/meet-backend")
STATE = Path("/var/lib/meet-test-vps-deploy")
MAX_KEY = 4096
MAX_BYTES = 1_048_576
CONTROLLED = ("LOCATIONIQ_KEY", "GEOCODER_ENABLED")
OVERRIDES = ("APP_GEOCODER_ENABLED", "APP_GEOCODER_API_KEY",
             "SPRING_APPLICATION_JSON", "JDK_JAVA_OPTIONS",
             "JAVA_OPTS", "SPRING_CONFIG_LOCATION", "SPRING_CONFIG_ADDITIONAL_LOCATION")
DEFAULT_JAVA_OPTIONS = "-XX:MaxRAMPercentage=75.0 -XX:+ExitOnOutOfMemoryError"


def ambiguous(name: str, value: str) -> bool:
    return bool(value) and (name in OVERRIDES or name.startswith("APP_GEOCODER_") or
                           (name == "JAVA_TOOL_OPTIONS" and value != DEFAULT_JAVA_OPTIONS))


def validate_key(raw: bytes) -> str:
    if len(raw) > MAX_KEY or not re.fullmatch(rb"[A-Za-z0-9._~+/-]+={0,2}", raw):
        raise Rejected("invalid_key_format")
    return raw.decode("ascii")


def candidate(before: bytes, key: str) -> bytes:
    if (not before.endswith(b"\n") or b"\0" in before or b"$" in before
            or b"\r" in before.replace(b"\r\n", b"")
            or any(byte < 32 and byte not in (10, 13) for byte in before)):
        raise Rejected("invalid_environment")
    lines = before.decode("utf-8").splitlines(keepends=True)
    assignments = {}
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", line.rstrip("\r\n"))
        if not match:
            raise Rejected("noncanonical_environment")
        name, value = match.groups()
        if ambiguous(name, value):
            raise Rejected("ambiguous_geocoder_configuration")
        if name in CONTROLLED:
            if name in assignments:
                raise Rejected("duplicate_assignment")
            assignments[name] = (index, value)
    if "LOCATIONIQ_KEY" in assignments:
        existing = assignments["LOCATIONIQ_KEY"][1]
        if existing and existing != key:
            raise Rejected("key_conflict")
    if ("GEOCODER_ENABLED" in assignments
            and assignments["GEOCODER_ENABLED"][1] not in ("true", "false")):
        raise Rejected("invalid_enabled_flag")
    for name, value in (("LOCATIONIQ_KEY", key), ("GEOCODER_ENABLED", "false")):
        if name in assignments:
            index = assignments[name][0]
            ending = "\r\n" if lines[index].endswith("\r\n") else "\n"
            lines[index] = name + "=" + value + ending
        else:
            ending = "\r\n" if before.endswith(b"\r\n") else "\n"
            lines.append(name + "=" + value + ending)
    return "".join(lines).encode("utf-8")


def command(arguments: list[str]) -> bytes:
    """Bound Docker inspection in memory and time; never persist its secret env."""
    child = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    output = bytearray()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            end = time.monotonic() + 10
            while True:
                remaining = end - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise Rejected("runtime_deadline")
                chunk = os.read(child.stdout.fileno(), min(65536, MAX_BYTES + 1 - len(output)))
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > MAX_BYTES:
                    raise Rejected("runtime_budget")
            if child.wait(timeout=max(0.001, end - time.monotonic())) != 0:
                raise Rejected("runtime_command_failed")
        return bytes(output)
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
        child.stdout.close()


def unique_object(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise Rejected("ambiguous_runtime")
        result[name] = value
    return result


def runtime() -> tuple[str, str]:
    running = command(["docker", "ps", "--no-trunc", "-q", "--filter",
                       "label=com.docker.compose.service=backend"]).splitlines()
    if len(running) != 1 or not re.fullmatch(rb"[0-9a-f]{64}", running[0]):
        raise Rejected("single_backend_required")
    container_id = running[0].decode("ascii")
    records = json.loads(command(["docker", "inspect", container_id]),
                         object_pairs_hook=unique_object)
    if not isinstance(records, list) or len(records) != 1:
        raise Rejected("unexpected_runtime")
    backend = records[0]
    labels = backend["Config"]["Labels"]
    if (backend["Id"] != container_id
            or labels["com.docker.compose.project"] != "meet-production"
            or labels["com.docker.compose.service"] != "backend"
            or backend["State"]["Running"] is not True
            or backend["State"]["Health"]["Status"] != "healthy"
            or backend["Config"].get("Entrypoint") != ["java", "-jar", "app.jar"]
            or backend["Config"].get("Cmd") not in (None, [])
            or not isinstance(backend["State"]["StartedAt"], str)):
        raise Rejected("unexpected_runtime")
    env = {}
    for item in backend["Config"]["Env"]:
        name, value = item.split("=", 1)
        if name in env:
            raise Rejected("ambiguous_runtime")
        env[name] = value
    if any(ambiguous(name, value) for name, value in env.items()):
        raise Rejected("ambiguous_geocoder_configuration")
    enabled = env.get("GEOCODER_ENABLED", "true")
    if enabled not in ("true", "false"):
        raise Rejected("invalid_runtime_enabled_flag")
    if enabled == "true" and env.get("LOCATIONIQ_KEY", "").strip():
        raise Rejected("active_usable_geocoder")
    return backend["Id"], backend["State"]["StartedAt"]


def configure(env_path: Path, state: Path, raw: bytes, check_runtime=runtime) -> dict:
    key = validate_key(raw)
    parent = directory(env_path.parent)
    state_fd = lock_fd = env_fd = -1
    temporary = None
    published = False
    try:
        state_fd = directory(state)
        lock_fd, _, _ = private_file(state_fd, ".deploy.lock", deployment_lock=True)
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for name in (".provider-transaction.current", ".smtp-transaction.current"):
            try:
                os.stat(name, dir_fd=state_fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise Rejected("unresolved_transaction")
        env_fd, before, info = private_file(parent, env_path.name)
        after = candidate(before, key)
        previous = check_runtime()

        def unchanged():
            current, data, current_info = private_file(parent, env_path.name)
            os.close(current)
            if data != before or identity(current_info) != identity(info):
                raise Rejected("environment_changed")

        unchanged()
        if after != before:
            fd, temporary = tempfile.mkstemp(prefix=".locationiq-off-", dir=env_path.parent)
            try:
                os.fchmod(fd, stat.S_IMODE(info.st_mode))
                os.fchown(fd, info.st_uid, info.st_gid)
                with os.fdopen(os.dup(fd), "wb") as stream:
                    stream.write(after)
                    stream.flush()
                os.fsync(fd)
            finally:
                os.close(fd)
            if check_runtime() != previous:
                raise Rejected("runtime_changed")
            unchanged()
            # An alarm after rename must report publication uncertainty, not a
            # prepublication deadline. Keep the bookkeeping in the same boundary.
            previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
            try:
                os.replace(temporary, env_path.name, dst_dir_fd=parent)
                published = True
                temporary = None
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
            os.fsync(parent)
        if check_runtime() != previous:
            raise Rejected("runtime_changed")
        current, data, _ = private_file(parent, env_path.name)
        os.close(current)
        if data != after:
            raise Rejected("environment_changed")
        return {"key_configured": True, "persistent_geocoder_enabled": False,
                "backend_restarted": False, "runtime_environment_unchanged": True}
    except BaseException:
        if published:
            raise Rejected("configuration_published_durability_uncertain") from None
        raise
    finally:
        if temporary is not None:
            os.unlink(temporary)
        for fd in (env_fd, lock_fd, state_fd, parent):
            if fd >= 0:
                os.close(fd)


def deadline(_signal, _frame):
    raise Rejected("deadline")


def main() -> int:
    try:
        if os.geteuid() != 0 or len(sys.argv) != 1:
            raise Rejected("root_no_arguments_required")
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        signal.signal(signal.SIGALRM, deadline)
        signal.alarm(40)
        result = configure(ROOT / ".env.production", STATE, sys.stdin.buffer.read(MAX_KEY + 1))
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Rejected as error:
        print(json.dumps({"error": error.args[0], "backend_restarted": False}))
        return 1
    except (OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError,
            subprocess.SubprocessError):
        print('{"error":"configuration_or_runtime_failed","backend_restarted":false}')
        return 1
    finally:
        signal.alarm(0)


if __name__ == "__main__":
    sys.exit(main())
