#!/usr/bin/env python3
"""Own one isolated retention-proof container and fail closed on teardown."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import posixpath
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Protocol

spec = importlib.util.spec_from_file_location(
    "retention_proof_registration",
    Path(__file__).with_name("retention-proof-registration.py"),
)
assert spec and spec.loader
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
CONTAINER_ID = re.compile(r"^[0-9a-f]{64}$")
OWNER_LABEL = "com.meet.retention-proof.owner"
NAME_PREFIX = "meet-retention-proof-"
OUTPUT_LIMIT = 1024 * 1024
SUMMARY_LIMIT = 64 * 1024
METADATA_HELPER_SHA256 = "c034d42e3cc2b8d9ce5258af671e9da116ab4b62dabb1aeadefa12efb8280c13"
FIXTURE_SECONDS = 300
OUTER_SECONDS = 600
STOP_SECONDS = 30
REMOVE_SECONDS = 30
REQUIRED_CASES = (
    "eligible-owned-terminal-states-removed",
    "active-protected-legacy-unknown-preserved",
    "all-service-mount-references-respected",
    "current-tooling-deleted-last",
    "repeat-run-is-idempotent",
    "only-owned-roots-removed",
    "outside-sentinel-preserved",
    "missing-or-unsafe-root-denied",
    "symlink-hardlink-prefix-collision-denied",
    "top-level-nested-replacement-preserved",
    "malformed-helper-inspection-denied",
    "smtp-transaction-lock-contention-denied",
    "timeout-hup-int-term-denied",
    "cleanup-failure-overrides-pass",
)
ADMISSION_BOOTSTRAP = """\
import json
import os
import stat
import sys

def unescape(value):
    return (value.replace("\\\\040", " ").replace("\\\\011", "\\t")
            .replace("\\\\012", "\\n").replace("\\\\134", "\\\\"))

for path in ("/src", "/fixture"):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise SystemExit(1)
    if path == "/fixture" and (
        info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise SystemExit(1)

evidence = {}
with open("/proc/self/mountinfo", encoding="utf-8") as mountinfo:
    for line in mountinfo:
        before, separator, _after = line.partition(" - ")
        if not separator:
            raise SystemExit(1)
        fields = before.split()
        if len(fields) < 6:
            raise SystemExit(1)
        target = unescape(fields[4])
        if target not in ("/etc/hostname", "/etc/hosts", "/etc/resolv.conf"):
            continue
        info = os.lstat(target)
        options = set(fields[5].split(","))
        if (
            target in evidence
            or "ro" not in options
            or "rw" in options
            or not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_uid != 0
            or not fields[3].startswith("/")
        ):
            raise SystemExit(1)
        evidence[target] = {
            "root": unescape(fields[3]),
            "device": fields[2],
            "readOnly": True,
            "regular": True,
            "uid": info.st_uid,
        }
if set(evidence) != {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}:
    raise SystemExit(1)
print(
    "RETENTION_ADMISSION_READY:"
    + json.dumps(evidence, sort_keys=True, separators=(",", ":")),
    flush=True,
)
while True:
    line = sys.stdin.readline()
    if line == "RELEASE\\n":
        break
    if not line:
        raise SystemExit(1)
os.execv(
    "/bin/bash",
    [
        "/bin/bash",
        "-euo",
        "pipefail",
        "/src/scripts/fixtures/retention-proof/proof-entrypoint.sh",
        "--run-fixture",
    ],
)
"""


class Denied(Exception):
    pass


class Engine(Protocol):
    def info(self) -> dict[str, object]: ...

    def create(
        self,
        *,
        image: str,
        source: str,
        name: str,
        owner: str,
        source_sha: str,
        plan_sha256: str,
        toolchain_sha256: str,
    ) -> str: ...

    def inspect(self, container_id: str) -> dict[str, object]: ...

    def start_attached(self, container_id: str) -> subprocess.Popen[bytes]: ...

    def stop(self, container_id: str) -> None: ...

    def remove(self, container_id: str) -> None: ...

    def absent(self, container_id: str) -> bool: ...

    def host_mountinfo(self) -> bytes: ...

    def collect_host_metadata(self, request: bytes) -> dict[str, object]: ...


class DockerEngine:
    def __init__(self, docker: str = "docker") -> None:
        self.docker = docker
        self.deadline = 0.0

    @staticmethod
    def _environment() -> dict[str, str]:
        return {
            "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", "/home/runner"),
            "LANG": "C.UTF-8",
            "TZ": "UTC",
            "DOCKER_HOST": "unix:///var/run/docker.sock",
        }

    def _run(
        self, arguments: list[str], *, timeout: int, maximum: int = 64 * 1024
    ) -> bytes:
        remaining = self.deadline - time.monotonic() if self.deadline else timeout
        if remaining <= 0:
            raise Denied("overall host proof deadline exceeded")
        try:
            result = subprocess.run(
                [self.docker, *arguments],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=min(timeout, remaining),
                env=self._environment(),
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise Denied("bounded container-engine request failed") from error
        if len(result.stdout) > maximum:
            raise Denied("container-engine response exceeds its bound")
        return result.stdout

    def info(self) -> dict[str, object]:
        raw = self._run(
            ["info", "--format", "{{json .}}"], timeout=30, maximum=64 * 1024
        )
        value = policy.decode_json(raw)
        if not isinstance(value, dict):
            raise Denied("container-engine metadata is malformed")
        version_raw = self._run(
            ["version", "--format", "{{json .Server}}"],
            timeout=30,
            maximum=64 * 1024,
        )
        server = policy.decode_json(version_raw)
        if not isinstance(server, dict):
            raise Denied("container-engine server version metadata is malformed")
        server_version = server.get("Version")
        api_version = server.get("ApiVersion")
        if (
            not isinstance(server_version, str)
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", server_version)
            or not isinstance(api_version, str)
            or not re.fullmatch(r"[0-9]+\.[0-9]+", api_version)
        ):
            raise Denied("container-engine server version or API version is missing")
        value["ServerVersion"] = server_version
        value["ApiVersion"] = api_version
        return value

    def create(
        self,
        *,
        image: str,
        source: str,
        name: str,
        owner: str,
        source_sha: str,
        plan_sha256: str,
        toolchain_sha256: str,
    ) -> str:
        options = [
            "create",
            "--name",
            name,
            "--label",
            f"{OWNER_LABEL}={owner}",
            "--network",
            "none",
            "--log-driver",
            "none",
            "--read-only",
            "--user",
            "0:0",
            "--pid",
            "private",
            "--ipc",
            "private",
            "--cap-drop",
            "ALL",
            "--cap-add",
            "CHOWN",
            "--security-opt",
            "no-new-privileges:true",
            "--security-opt",
            "seccomp=builtin",
            "--pids-limit",
            "256",
            "--cpus",
            "2",
            "--memory",
            "1g",
            "--tmpfs",
            "/fixture:rw,noexec,nosuid,nodev,size=268435456,mode=0700",
            "--tmpfs",
            "/tmp:rw,noexec,nosuid,nodev,size=67108864,mode=1777",
            "--mount",
            f"type=bind,source={source},target=/src,readonly",
            "--entrypoint",
            "python3",
            "--env",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "--env",
            "LANG=C.UTF-8",
            "--env",
            "TZ=UTC",
            "--env",
            f"RETENTION_PROOF_SOURCE_SHA={source_sha}",
            "--env",
            f"RETENTION_PROOF_PLAN_SHA256={plan_sha256}",
            "--env",
            f"RETENTION_PROOF_IMAGE_DIGEST={image}",
            "--env",
            f"RETENTION_PROOF_TOOLCHAIN_SHA256={toolchain_sha256}",
            image,
            "-I",
            "-S",
            "-c",
            ADMISSION_BOOTSTRAP,
        ]
        container_id = self._run(options, timeout=30, maximum=256).decode().strip()
        if not CONTAINER_ID.fullmatch(container_id):
            raise Denied("container engine returned an invalid owned ID")
        return container_id

    def inspect(self, container_id: str) -> dict[str, object]:
        if not CONTAINER_ID.fullmatch(container_id):
            raise Denied("refusing to inspect an unowned container ID")
        raw = self._run(
            ["inspect", "--type", "container", container_id],
            timeout=30,
            maximum=64 * 1024,
        )
        value = policy.decode_json(raw)
        if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
            raise Denied("container inspection is incomplete")
        return value[0]

    def start_attached(self, container_id: str) -> subprocess.Popen[bytes]:
        if not CONTAINER_ID.fullmatch(container_id):
            raise Denied("refusing to start an unowned container ID")
        try:
            return subprocess.Popen(
                [self.docker, "start", "--attach", "--interactive", container_id],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=self._environment(),
                bufsize=0,
            )
        except OSError as error:
            raise Denied("container start failed") from error

    def stop(self, container_id: str) -> None:
        self._run(["stop", "--time", "10", container_id], timeout=STOP_SECONDS)

    def remove(self, container_id: str) -> None:
        self._run(["rm", "--force", container_id], timeout=REMOVE_SECONDS)

    def absent(self, container_id: str) -> bool:
        if not CONTAINER_ID.fullmatch(container_id):
            raise Denied("refusing to verify absence of an unowned container ID")
        try:
            result = subprocess.run(
                [self.docker, "inspect", "--type", "container", container_id],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=min(
                    30,
                    self.deadline - time.monotonic()
                    if self.deadline
                    else 30,
                ),
                env=self._environment(),
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise Denied("bounded container absence check failed") from error
        if len(result.stdout) > 64 * 1024 or len(result.stderr) > 4096:
            raise Denied("container absence response exceeds its bound")
        if result.returncode == 0:
            return False
        # Docker reports this exact error only when inspect completed and the
        # requested full ID does not exist. Permission and daemon failures
        # must never be treated as successful teardown.
        return (
            result.returncode == 1
            and not result.stdout
            and result.stderr == f"Error: No such object: {container_id}\n".encode()
        )

    @staticmethod
    def host_mountinfo() -> bytes:
        try:
            with open("/proc/self/mountinfo", "rb") as mountinfo:
                data = mountinfo.read(1024 * 1024 + 1)
        except OSError as error:
            raise Denied("host mount table is unavailable") from error
        if len(data) > 1024 * 1024:
            raise Denied("host mount table exceeds its bound")
        return data

    @staticmethod
    def _runtime_path(path: str, *, allow_python_symlink: bool = False) -> str:
        if not path.startswith("/") or posixpath.normpath(path) != path:
            raise Denied("root metadata runtime path is not canonical")
        parts = path.split("/")[1:]
        current = "/"
        for index, part in enumerate(parts):
            current = posixpath.join(current, part)
            info = os.lstat(current)
            final = index == len(parts) - 1
            if stat.S_ISLNK(info.st_mode):
                if not (allow_python_symlink and final and current == "/usr/bin/python3"):
                    raise Denied("root metadata runtime path contains a symlink")
                if info.st_uid != 0:
                    raise Denied("root metadata interpreter link is not root-owned")
                continue
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise Denied("root metadata runtime path is writable by an untrusted user")
            if final and not stat.S_ISREG(info.st_mode):
                raise Denied("root metadata executable is not a regular file")
            if not final and not stat.S_ISDIR(info.st_mode):
                raise Denied("root metadata runtime ancestry is not a directory")
        resolved = os.path.realpath(path)
        if allow_python_symlink:
            if not re.fullmatch(r"/usr/bin/python3\.[0-9]+", resolved):
                raise Denied("root metadata interpreter target is outside the admitted system path")
        elif resolved != path:
            raise Denied("root metadata privilege tool path is redirected")
        target = os.stat(path)
        if target.st_uid != 0 or target.st_mode & 0o022 or not stat.S_ISREG(target.st_mode):
            raise Denied("root metadata runtime executable provenance differs")
        return resolved

    @classmethod
    def _verify_metadata_runtime(cls) -> None:
        interpreter = cls._runtime_path("/usr/bin/python3", allow_python_symlink=True)
        cls._runtime_path("/usr/bin/sudo")
        match = re.fullmatch(r"/usr/bin/python3\.([0-9]+)", interpreter)
        assert match
        standard_library = "/usr/lib/python3." + match.group(1)
        for path in (standard_library, standard_library + "/lib-dynload"):
            current = "/"
            for part in path.split("/")[1:]:
                current = posixpath.join(current, part)
                info = os.lstat(current)
                if (
                    stat.S_ISLNK(info.st_mode)
                    or not stat.S_ISDIR(info.st_mode)
                    or info.st_uid != 0
                    or info.st_mode & 0o022
                ):
                    raise Denied("root metadata standard library provenance differs")

    @staticmethod
    def _helper_identity(info: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
        return (
            info.st_dev,
            info.st_ino,
            info.st_mode,
            info.st_uid,
            info.st_gid,
            info.st_size,
            info.st_mtime_ns,
        )

    @classmethod
    def _read_metadata_helper(cls) -> tuple[Path, bytes, tuple[int, int, int, int, int, int, int]]:
        path = Path(__file__).with_name("retention-proof-host-metadata.py")
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags)
            try:
                before = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(before.st_mode)
                    or before.st_size <= 0
                    or before.st_size > 64 * 1024
                ):
                    raise Denied("trusted host metadata helper size or type differs")
                chunks: list[bytes] = []
                size = 0
                while True:
                    chunk = os.read(descriptor, min(8192, 64 * 1024 + 1 - size))
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > 64 * 1024:
                        raise Denied("trusted host metadata helper exceeds its bound")
                    chunks.append(chunk)
                after = os.fstat(descriptor)
                current = os.stat(path, follow_symlinks=False)
            finally:
                os.close(descriptor)
        except OSError as error:
            raise Denied("trusted host metadata helper cannot be read safely") from error
        content = b"".join(chunks)
        identity = cls._helper_identity(before)
        if (
            identity != cls._helper_identity(after)
            or identity != cls._helper_identity(current)
            or len(content) != before.st_size
            or hashlib.sha256(content).hexdigest() != METADATA_HELPER_SHA256
        ):
            raise Denied("trusted host metadata helper identity or digest differs")
        try:
            decoded = content.decode("utf-8", errors="strict")
        except UnicodeDecodeError as error:
            raise Denied("trusted host metadata helper is not UTF-8") from error
        if decoded.encode("utf-8") != content:
            raise Denied("trusted host metadata helper does not round-trip")
        return path, content, identity

    @classmethod
    def _verify_helper_path(cls, path: Path, identity: tuple[int, int, int, int, int, int, int]) -> None:
        try:
            current = os.stat(path, follow_symlinks=False)
        except OSError as error:
            raise Denied("trusted host metadata helper changed before privilege transition") from error
        if cls._helper_identity(current) != identity:
            raise Denied("trusted host metadata helper changed before privilege transition")

    def collect_host_metadata(self, request: bytes) -> dict[str, object]:
        expected = validate_metadata_request(request)
        started = time.monotonic()
        remaining = self.deadline - started if self.deadline else 30
        if remaining <= 0:
            raise Denied("host metadata deadline expired")
        deadline = started + min(30, remaining)
        self._verify_metadata_runtime()
        helper_path, helper_bytes, helper_identity = self._read_metadata_helper()
        self._verify_helper_path(helper_path, helper_identity)
        command = [
            "/usr/bin/sudo",
            "-n",
            "-u",
            "root",
            "--",
            "/usr/bin/python3",
            "-I",
            "-B",
            "-c",
            helper_bytes.decode("utf-8", errors="strict"),
        ]
        environment = {
            "PATH": "/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "TZ": "UTC",
            "HOME": "/",
        }
        if (
            len(command) != 10
            or command[:9]
            != [
                "/usr/bin/sudo",
                "-n",
                "-u",
                "root",
                "--",
                "/usr/bin/python3",
                "-I",
                "-B",
                "-c",
            ]
            or hashlib.sha256(helper_bytes).hexdigest() != METADATA_HELPER_SHA256
            or len(request) > 1024
        ):
            raise Denied("host metadata privilege invocation differs from its fixed contract")
        self._verify_helper_path(helper_path, helper_identity)
        if time.monotonic() >= deadline:
            raise Denied("host metadata deadline expired before privilege transition")
        process: subprocess.Popen[bytes] | None = None
        selector: selectors.BaseSelector | None = None
        output = bytearray()
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                cwd="/",
                env=environment,
                close_fds=True,
                shell=False,
                start_new_session=True,
                bufsize=0,
            )
            assert process.stdin and process.stdout
            process.stdin.write(request)
            process.stdin.close()
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map():
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    raise Denied("root host metadata collection timed out")
                for key, _ in selector.select(min(1.0, timeout)):
                    chunk = os.read(key.fd, 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    output.extend(chunk)
                    if len(output) > 64 * 1024:
                        raise Denied("root host metadata response exceeds its bound")
            return_code = process.wait(timeout=max(0.001, deadline - time.monotonic()))
            if return_code != 0:
                raise Denied("root host metadata collector denied evidence")
        except (OSError, subprocess.SubprocessError) as error:
            raise Denied("bounded root host metadata invocation failed") from error
        finally:
            if selector is not None:
                selector.close()
            if process is not None:
                for stream in (process.stdin, process.stdout):
                    if stream is not None and not stream.closed:
                        stream.close()
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=1)
                    except (OSError, subprocess.SubprocessError):
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                            process.wait(timeout=1)
                        except (OSError, subprocess.SubprocessError):
                            raise Denied("root host metadata process teardown failed")
        return validate_metadata_response(bytes(output), expected)


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


def parse_mountinfo(raw: bytes) -> list[dict[str, str]]:
    if len(raw) > 1024 * 1024:
        raise Denied("mount evidence exceeds its bound")
    try:
        lines = raw.decode("utf-8", errors="strict").splitlines()
    except UnicodeDecodeError as error:
        raise Denied("mount evidence is not UTF-8") from error
    mounts: list[dict[str, str]] = []
    for line in lines:
        before, separator, after = line.partition(" - ")
        left = before.split()
        right = after.split()
        if not separator or len(left) < 6 or len(right) < 3:
            raise Denied("mount evidence row is malformed")
        if not re.fullmatch(r"[0-9]+:[0-9]+", left[2]):
            raise Denied("mount evidence device is malformed")
        mounts.append(
            {
                "root": _mount_unescape(left[3]),
                "mountpoint": _mount_unescape(left[4]),
                "device": left[2],
                "options": left[5],
                "filesystem": right[0],
            }
        )
    if not mounts:
        raise Denied("mount evidence is empty")
    return mounts


def host_backing_mount(path: str, mounts: list[dict[str, str]]) -> dict[str, str]:
    candidates = [
        mount
        for mount in mounts
        if path == mount["mountpoint"]
        or path.startswith(mount["mountpoint"].rstrip("/") + "/")
    ]
    if not candidates:
        raise Denied("engine file has no host mount-table mapping")
    mount = max(candidates, key=lambda item: len(item["mountpoint"]))
    relative = posixpath.relpath(path, mount["mountpoint"])
    mapped_root = (
        mount["root"]
        if relative == "."
        else posixpath.normpath(posixpath.join(mount["root"], relative))
    )
    return {"root": mapped_root, "device": mount["device"]}


def _strict_json(raw: bytes, *, maximum: int) -> object:
    if not raw or len(raw) > maximum:
        raise Denied("metadata JSON is empty or oversized")

    def object_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
        value: dict[str, object] = {}
        for key, item in pairs:
            if key in value:
                raise Denied("metadata JSON contains duplicate keys")
            value[key] = item
        return value

    try:
        return json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=object_pairs)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied("metadata JSON is malformed") from error


def validate_metadata_request(raw: bytes) -> dict[str, object]:
    value = _strict_json(raw, maximum=1024)
    keys = {
        "schemaVersion",
        "containerId",
        "owner",
        "dockerRootDir",
        "engineVersion",
        "engineApiVersion",
    }
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or type(value.get("schemaVersion")) is not int
        or value["schemaVersion"] != 1
        or not isinstance(value.get("containerId"), str)
        or not CONTAINER_ID.fullmatch(value["containerId"])
        or not isinstance(value.get("owner"), str)
        or not re.fullmatch(r"[0-9a-f]{32}", value["owner"])
        or not isinstance(value.get("dockerRootDir"), str)
        or not isinstance(value.get("engineVersion"), str)
        or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value["engineVersion"])
        or not isinstance(value.get("engineApiVersion"), str)
        or not re.fullmatch(r"[0-9]+\.[0-9]+", value["engineApiVersion"])
    ):
        raise Denied("metadata request schema or identity differs")
    root = value["dockerRootDir"]
    if (
        not root.startswith("/")
        or root == "/"
        or len(root.encode("utf-8")) > 4096
        or "\x00" in root
        or "\n" in root
        or "\r" in root
        or posixpath.normpath(root) != root
        or any(part in ("", ".", "..") for part in root.split("/")[1:])
    ):
        raise Denied("metadata request Engine root is not canonical")
    if json.dumps(value, sort_keys=True, separators=(",", ":")).encode() != raw:
        raise Denied("metadata request is not canonical JSON")
    return value


def validate_metadata_response(raw: bytes, expected: dict[str, object]) -> dict[str, object]:
    if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
        raise Denied("root host metadata output framing differs")
    value = _strict_json(raw[:-1], maximum=SUMMARY_LIMIT - 1)
    keys = {
        "schemaVersion",
        "containerId",
        "owner",
        "dockerRootDir",
        "engineVersion",
        "engineApiVersion",
        "files",
    }
    if (
        not isinstance(value, dict)
        or set(value) != keys
        or type(value.get("schemaVersion")) is not int
        or value["schemaVersion"] != 1
        or any(value.get(key) != expected[key] for key in keys - {"schemaVersion", "files"})
        or json.dumps(value, sort_keys=True, separators=(",", ":")).encode() != raw[:-1]
    ):
        raise Denied("root host metadata identity or schema differs")
    files = value["files"]
    targets = {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}
    record_keys = {
        "source",
        "mode",
        "uid",
        "gid",
        "device",
        "inode",
        "mountRoot",
        "mountDevice",
    }
    if not isinstance(files, dict) or set(files) != targets:
        raise Denied("root host metadata file set differs")
    leaves = {
        "/etc/hostname": "hostname",
        "/etc/hosts": "hosts",
        "/etc/resolv.conf": "resolv.conf",
    }
    root = expected["dockerRootDir"]
    container_id = expected["containerId"]
    for target, leaf in leaves.items():
        record = files[target]
        source = f"{root}/containers/{container_id}/{leaf}"
        if (
            not isinstance(record, dict)
            or set(record) != record_keys
            or record.get("source") != source
            or len(source.encode("utf-8")) > 4096
            or any(
                type(record.get(key)) is not int or record[key] < 0
                for key in ("mode", "uid", "gid", "device", "inode")
            )
            or record["inode"] == 0
            or not stat.S_ISREG(record["mode"])
            or record["uid"] != 0
            or not isinstance(record.get("mountRoot"), str)
            or not record["mountRoot"].startswith("/")
            or posixpath.normpath(record["mountRoot"]) != record["mountRoot"]
            or not isinstance(record.get("mountDevice"), str)
            or not re.fullmatch(r"[0-9]+:[0-9]+", record["mountDevice"])
            or device_number(record["device"]) != record["mountDevice"]
        ):
            raise Denied("root host metadata record differs")
    return value


def device_number(device: int) -> str:
    major = (device >> 8) & 0xFFF
    major |= (device >> 32) & 0xFFFFF000
    minor = device & 0xFF
    minor |= (device >> 12) & 0xFFFFFF00
    return f"{major}:{minor}"


def validate_engine_file_evidence(
    inspection: dict[str, object],
    *,
    engine_root: str,
    container_id: str,
    owner: str,
    engine_version: str,
    engine_api_version: str,
    host_metadata: object,
    host_mountinfo_bytes: bytes,
    container_evidence: object,
) -> None:
    host_mounts = parse_mountinfo(host_mountinfo_bytes)
    if (
        not isinstance(container_evidence, dict)
        or set(container_evidence) != {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}
    ):
        raise Denied("container engine-file mount evidence is incomplete")
    expected_identity = {
        "containerId": container_id,
        "owner": owner,
        "dockerRootDir": engine_root,
        "engineVersion": engine_version,
        "engineApiVersion": engine_api_version,
    }
    if not isinstance(host_metadata, dict):
        raise Denied("root host metadata is missing")
    metadata = validate_metadata_response(
        json.dumps(host_metadata, sort_keys=True, separators=(",", ":")).encode() + b"\n",
        expected_identity,
    )
    config = inspection.get("Config")
    labels = config.get("Labels") if isinstance(config, dict) else None
    if (
        inspection.get("Id") != container_id
        or not isinstance(labels, dict)
        or labels.get(OWNER_LABEL) != owner
    ):
        raise Denied("host metadata is not bound to the owned container")
    leaves = {
        "/etc/hostname": ("HostnamePath", "hostname"),
        "/etc/hosts": ("HostsPath", "hosts"),
        "/etc/resolv.conf": ("ResolvConfPath", "resolv.conf"),
    }
    for target, (field, leaf) in leaves.items():
        expected = f"{engine_root}/containers/{container_id}/{leaf}"
        if inspection.get(field) != expected:
            raise Denied("engine file source path differs")
        record = metadata["files"][target]
        host = host_backing_mount(expected, host_mounts)
        inner = container_evidence[target]
        if (
            not isinstance(inner, dict)
            or set(inner) != {"root", "device", "readOnly", "regular", "uid"}
            or inner["readOnly"] is not True
            or inner["regular"] is not True
            or type(inner["uid"]) is not int
            or inner["uid"] != 0
            or inner["root"] != host["root"]
            or inner["device"] != host["device"]
            or record["mountRoot"] != host["root"]
            or record["mountDevice"] != host["device"]
            or device_number(record["device"]) != host["device"]
        ):
            raise Denied("container and host engine-file mount evidence differs")


def validate_engine_info(info: dict[str, object], lock: dict[str, object]) -> str:
    docker_root = info.get("DockerRootDir")
    if (
        not isinstance(info.get("ServerVersion"), str)
        or info["ServerVersion"] != lock["engineVersion"]
        or not isinstance(info.get("ApiVersion"), str)
        or info["ApiVersion"] != lock["engineApiVersion"]
        or lock["engineLayout"] != "moby-v28-root-container-id-v1"
        or not isinstance(docker_root, str)
        or not docker_root.startswith("/")
        or docker_root == "/"
        or "\n" in docker_root
        or "\r" in docker_root
        or posixpath.normpath(docker_root) != docker_root
        or any(part in (".", "..") for part in docker_root.split("/"))
    ):
        raise Denied("container engine version, API, or root differs from lock")
    return docker_root.rstrip("/")


def validate_inspection(
    inspection: dict[str, object],
    *,
    image_digest: str,
    source_sha: str,
    toolchain_sha256: str,
    source_export: str,
    owner: str,
    container_id: str,
    engine_root: str,
    started: bool,
) -> None:
    if not isinstance(inspection, dict):
        raise Denied("container inspection is malformed")
    config = inspection.get("Config")
    host = inspection.get("HostConfig")
    if not isinstance(config, dict) or not isinstance(host, dict):
        raise Denied("container configuration is incomplete")
    labels = config.get("Labels")
    if (
        not isinstance(labels, dict)
        or inspection.get("Id") != container_id
        or not CONTAINER_ID.fullmatch(container_id)
        or labels.get(OWNER_LABEL) != owner
        or config.get("Image") != image_digest
    ):
        raise Denied("container ownership or image identity differs")
    security_options = host.get("SecurityOpt")
    if (
        config.get("User") != "0:0"
        or config.get("Volumes") not in (None, {})
        or config.get("ExposedPorts") not in (None, {})
        or config.get("Cmd") != ["-I", "-S", "-c", ADMISSION_BOOTSTRAP]
        or config.get("Entrypoint") != ["python3"]
        or host.get("NetworkMode") != "none"
        or host.get("Privileged") is not False
        or host.get("ReadonlyRootfs") is not True
        or host.get("PidMode") not in ("", "private")
        or host.get("IpcMode") not in ("", "private")
        or host.get("CapAdd") != ["CHOWN"]
        or host.get("CapDrop") != ["ALL"]
        or not isinstance(security_options, list)
        or len(security_options) != 2
        or set(security_options)
        != {"no-new-privileges:true", "seccomp=builtin"}
        or host.get("Devices") not in (None, [])
        or host.get("DeviceRequests") not in (None, [])
        or host.get("PortBindings") not in (None, {})
        or host.get("Binds") not in (None, [])
        or host.get("AutoRemove") is not False
        or host.get("VolumesFrom") not in (None, [])
        or host.get("LogConfig") != {"Type": "none", "Config": {}}
        or host.get("Memory") != 1024 * 1024 * 1024
        or host.get("NanoCpus") != 2_000_000_000
        or host.get("PidsLimit") != 256
    ):
        raise Denied("container isolation configuration differs")
    expected_env = {
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG=C.UTF-8",
        "TZ=UTC",
        f"RETENTION_PROOF_SOURCE_SHA={source_sha}",
        f"RETENTION_PROOF_PLAN_SHA256={policy.PLAN_SHA256}",
        f"RETENTION_PROOF_IMAGE_DIGEST={image_digest}",
        f"RETENTION_PROOF_TOOLCHAIN_SHA256={toolchain_sha256}",
    }
    toolchain_environment = config.get("Env")
    if (
        not isinstance(toolchain_environment, list)
        or len(toolchain_environment) != len(expected_env)
        or any(not isinstance(value, str) for value in toolchain_environment)
        or len(set(toolchain_environment)) != len(expected_env)
        or set(toolchain_environment) != expected_env
    ):
        raise Denied("container environment is not closed")
    configured_mounts = host.get("Mounts") or []
    if (
        not isinstance(configured_mounts, list)
        or len(configured_mounts) != 1
        or not isinstance(configured_mounts[0], dict)
        or configured_mounts[0].get("Type") != "bind"
        or configured_mounts[0].get("Source") != os.path.realpath(source_export)
        or configured_mounts[0].get("Target") != "/src"
        or configured_mounts[0].get("ReadOnly") is not True
        or configured_mounts[0].get("Consistency") not in (None, "")
    ):
        raise Denied("configured host mounts differ from the source-only bind")
    tmpfs = host.get("Tmpfs")
    expected_tmpfs = {
        "/fixture": "rw,noexec,nosuid,nodev,size=268435456,mode=0700",
        "/tmp": "rw,noexec,nosuid,nodev,size=67108864,mode=1777",
    }
    if tmpfs != expected_tmpfs:
        raise Denied("container tmpfs configuration differs")
    mounts = inspection.get("Mounts")
    if not isinstance(mounts, list):
        raise Denied("container mount inspection is missing")
    expected_source = os.path.realpath(source_export)
    allowed = {"/src", "/fixture", "/tmp"}
    if started:
        allowed |= {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}
    destinations: set[str] = set()
    for mount in mounts:
        if not isinstance(mount, dict):
            raise Denied("container mount entry is malformed")
        destination = mount.get("Destination")
        if not isinstance(destination, str) or destination not in allowed:
            raise Denied("container has an unexpected mount")
        if destination in destinations:
            raise Denied("container has duplicate mount destinations")
        destinations.add(destination)
        if destination == "/src":
            if (
                mount.get("Type") != "bind"
                or mount.get("Source") != expected_source
                or mount.get("RW") is not False
            ):
                raise Denied("source export is not mounted read-only")
        elif destination in ("/fixture", "/tmp"):
            if mount.get("Type") != "tmpfs" or mount.get("RW") is not True:
                raise Denied("fixture tmpfs mount differs")
        elif started:
            expected_path = f"{engine_root}/containers/{container_id}/{destination.rsplit('/', 1)[1]}"
            source = mount.get("Source")
            if (
                mount.get("Type") != "bind"
                or source != expected_path
                or mount.get("RW") is not False
            ):
                raise Denied("engine-managed file mount differs")
    expected_destinations = {"/src", "/fixture", "/tmp"}
    if started:
        expected_destinations |= {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}
    if destinations != expected_destinations:
        raise Denied("container mount set is incomplete or unexpected")
    for leaf in ("HostnamePath", "HostsPath", "ResolvConfPath"):
        filename = {
            "HostnamePath": "hostname",
            "HostsPath": "hosts",
            "ResolvConfPath": "resolv.conf",
        }[leaf]
        expected = f"{engine_root}/containers/{container_id}/{filename}"
        value = inspection.get(leaf)
        if started and value != expected:
            raise Denied("engine file path is absent or substituted")
        if value not in (None, "", expected):
            raise Denied("pre-start engine file path is substituted")
    state = inspection.get("State")
    if not isinstance(state, dict):
        raise Denied("container state inspection is missing")
    expected_state = "running" if started else "created"
    if state.get("Status") != expected_state:
        raise Denied("container lifecycle state differs")


def validate_summary(
    raw: bytes,
    *,
    source_sha: str,
    image_digest: str,
    toolchain_sha256: str,
) -> dict[str, object]:
    if len(raw) > SUMMARY_LIMIT:
        raise Denied("sanitized proof summary exceeds 64 KiB")
    marker = b"RETENTION_FIXTURE_SUMMARY:"
    lines = [line for line in raw.splitlines() if line.startswith(marker)]
    if len(lines) != 1:
        raise Denied("fixture summary is missing or ambiguous")
    try:
        summary = policy.decode_json(lines[0][len(marker) :])
    except policy.Denied as error:
        raise Denied("fixture summary JSON is malformed") from error
    keys = {
        "schemaVersion",
        "outcome",
        "sourceSha",
        "planSha256",
        "imageDigest",
        "toolchainSha256",
        "extractedRetentionBlockSha256",
        "cases",
        "selectiveCleanup",
        "outsideSentinel",
    }
    if not isinstance(summary, dict) or set(summary) != keys:
        raise Denied("fixture summary schema is not closed")
    if (
        type(summary["schemaVersion"]) is not int
        or summary["schemaVersion"] != 1
        or summary["outcome"] != "passed"
        or summary["sourceSha"] != source_sha
        or summary["planSha256"] != policy.PLAN_SHA256
        or summary["imageDigest"] != image_digest
        or summary["toolchainSha256"] != toolchain_sha256
        or not isinstance(summary["extractedRetentionBlockSha256"], str)
        or not HEX64.fullmatch(summary["extractedRetentionBlockSha256"])
        or summary["selectiveCleanup"] is not True
        or summary["outsideSentinel"] is not True
    ):
        raise Denied("fixture summary evidence or cleanup proof differs")
    cases = summary["cases"]
    if not isinstance(cases, list) or len(cases) != len(REQUIRED_CASES):
        raise Denied("fixture case set is incomplete")
    observed: list[str] = []
    for case in cases:
        if (
            not isinstance(case, dict)
            or set(case) != {"id", "outcome"}
            or not isinstance(case["id"], str)
            or case["outcome"] != "passed"
        ):
            raise Denied("fixture case result is malformed")
        observed.append(case["id"])
    if tuple(observed) != REQUIRED_CASES:
        raise Denied("fixture case set is missing, duplicated, or reordered")
    return summary


class RetentionSupervisor:
    def __init__(
        self,
        engine: Engine,
        *,
        authorize: object,
        source_export: str,
        source_sha: str,
        image_digest: str,
        plan_sha256: str,
        toolchain_sha256: str,
        tuple_sha256: str,
        owner: str | None = None,
    ) -> None:
        self.engine = engine
        self.authorize = authorize
        self.source_export = os.path.realpath(source_export)
        self.source_sha = source_sha
        self.image_digest = image_digest
        self.plan_sha256 = plan_sha256
        self.toolchain_sha256 = toolchain_sha256
        self.tuple_sha256 = tuple_sha256
        self.owner = owner or uuid.uuid4().hex
        self.container_name = NAME_PREFIX + uuid.uuid4().hex
        self.container_id = ""
        self.engine_root = ""
        self.process: subprocess.Popen[bytes] | None = None
        self.output = bytearray()

    def _authorize(self, checkpoint: str) -> None:
        result = self.authorize(checkpoint, self.tuple_sha256)
        if not isinstance(result, dict) or result.get("tupleSha256") != self.tuple_sha256:
            raise Denied("fresh authority check did not preserve the approved tuple")

    def _create_and_inspect(self) -> None:
        if isinstance(self.engine, DockerEngine):
            self.engine.deadline = self.deadline
        self.engine_root = validate_engine_info(self.engine.info(), self.lock)
        self._authorize("pre-create")
        self.container_id = self.engine.create(
            image=self.image_digest,
            source=self.source_export,
            name=self.container_name,
            owner=self.owner,
            source_sha=self.source_sha,
            plan_sha256=self.plan_sha256,
            toolchain_sha256=self.toolchain_sha256,
        )
        if not CONTAINER_ID.fullmatch(self.container_id):
            raise Denied("container engine did not return one full owned ID")
        before = self.engine.inspect(self.container_id)
        validate_inspection(
            before,
            image_digest=self.image_digest,
            source_sha=self.source_sha,
            toolchain_sha256=self.toolchain_sha256,
            source_export=self.source_export,
            owner=self.owner,
            container_id=self.container_id,
            engine_root=self.engine_root,
            started=False,
        )

    @staticmethod
    def _engine_file_identity(inspection: dict[str, object]) -> tuple[object, ...]:
        config = inspection.get("Config")
        host = inspection.get("HostConfig")
        labels = config.get("Labels") if isinstance(config, dict) else None
        state = inspection.get("State")
        paths = tuple(
            inspection.get(field)
            for field in ("HostnamePath", "HostsPath", "ResolvConfPath")
        )
        return (
            inspection.get("Id"),
            labels.get(OWNER_LABEL) if isinstance(labels, dict) else None,
            paths,
            config,
            host,
            inspection.get("Mounts"),
            state.get("Running") if isinstance(state, dict) else None,
        )

    def _collect_engine_file_evidence(
        self,
        initial_inspection: dict[str, object],
        container_evidence: object,
    ) -> None:
        expected_engine = (
            self.engine_root,
            self.lock["engineVersion"],
            self.lock["engineApiVersion"],
        )

        def snapshot() -> tuple[tuple[str, str, str], dict[str, object]]:
            info = self.engine.info()
            root = validate_engine_info(info, self.lock)
            identity = (root, info["ServerVersion"], info["ApiVersion"])
            if identity != expected_engine:
                raise Denied("Engine identity changed around host metadata collection")
            inspection = self.engine.inspect(self.container_id)
            validate_inspection(
                inspection,
                image_digest=self.image_digest,
                source_sha=self.source_sha,
                toolchain_sha256=self.toolchain_sha256,
                source_export=self.source_export,
                owner=self.owner,
                container_id=self.container_id,
                engine_root=self.engine_root,
                started=True,
            )
            return identity, inspection

        initial_identity = self._engine_file_identity(initial_inspection)
        before_identity, before_inspection = snapshot()
        if self._engine_file_identity(before_inspection) != initial_identity:
            raise Denied("owned container identity changed before host metadata collection")
        request = json.dumps(
            {
                "schemaVersion": 1,
                "containerId": self.container_id,
                "owner": self.owner,
                "dockerRootDir": before_identity[0],
                "engineVersion": before_identity[1],
                "engineApiVersion": before_identity[2],
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
        validate_metadata_request(request)
        host_metadata = self.engine.collect_host_metadata(request)
        after_identity, after_inspection = snapshot()
        if (
            after_identity != before_identity
            or self._engine_file_identity(after_inspection) != initial_identity
        ):
            raise Denied("owned Engine/container identity changed during host metadata collection")
        validate_engine_file_evidence(
            after_inspection,
            engine_root=self.engine_root,
            container_id=self.container_id,
            owner=self.owner,
            engine_version=after_identity[1],
            engine_api_version=after_identity[2],
            host_metadata=host_metadata,
            host_mountinfo_bytes=self.engine.host_mountinfo(),
            container_evidence=container_evidence,
        )

    def _wait_for_ready(self) -> dict[str, object]:
        assert self.process and self.process.stdout
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        deadline = min(time.monotonic() + 30, self.deadline)
        try:
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise Denied("admission bootstrap exited before barrier")
                events = selector.select(min(1.0, deadline - time.monotonic()))
                for key, _ in events:
                    chunk = os.read(key.fd, 4096)
                    if not chunk:
                        raise Denied("admission bootstrap closed its output")
                    self.output.extend(chunk)
                    if len(self.output) > OUTPUT_LIMIT:
                        raise Denied("container output exceeded 1 MiB")
                    marker = b"RETENTION_ADMISSION_READY:"
                    for line in self.output.splitlines():
                        if line.startswith(marker):
                            evidence = policy.decode_json(line[len(marker) :])
                            if not isinstance(evidence, dict):
                                raise Denied("container mount evidence is malformed")
                            return evidence
            raise Denied("admission bootstrap barrier timed out")
        finally:
            selector.close()

    def _collect_summary(self) -> dict[str, object]:
        assert self.process and self.process.stdout
        deadline = min(time.monotonic() + FIXTURE_SECONDS, self.deadline)
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        eof = False
        try:
            while not eof or self.process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Denied("fixture exceeded its 300-second deadline")
                for key, _ in selector.select(min(1.0, remaining)):
                    chunk = os.read(key.fd, 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        eof = True
                        continue
                    self.output.extend(chunk)
                    if len(self.output) > OUTPUT_LIMIT:
                        raise Denied("container output exceeded 1 MiB")
            if self.process.returncode != 0:
                raise Denied("fixture returned a nonzero or prerequisite status")
        finally:
            selector.close()
        return validate_summary(
            bytes(self.output),
            source_sha=self.source_sha,
            image_digest=self.image_digest,
            toolchain_sha256=self.toolchain_sha256,
        )

    def _cleanup(self) -> bool:
        if not self.container_id:
            return True
        try:
            inspection = self.engine.inspect(self.container_id)
            if not isinstance(inspection, dict):
                return False
            config = inspection.get("Config")
            labels = config.get("Labels") if isinstance(config, dict) else None
            if (
                inspection.get("Id") != self.container_id
                or not isinstance(labels, dict)
                or labels.get(OWNER_LABEL) != self.owner
            ):
                return False
            state = inspection.get("State")
            if not isinstance(state, dict):
                return False
            if state.get("Running") is True:
                self.engine.stop(self.container_id)
                inspection = self.engine.inspect(self.container_id)
                if not isinstance(inspection, dict):
                    return False
                config = inspection.get("Config")
                labels = config.get("Labels") if isinstance(config, dict) else None
                state = inspection.get("State")
                if (
                    inspection.get("Id") != self.container_id
                    or not isinstance(labels, dict)
                    or labels.get(OWNER_LABEL) != self.owner
                    or not isinstance(state, dict)
                    or state.get("Running") is not False
                ):
                    return False
            self.engine.remove(self.container_id)
            return self.engine.absent(self.container_id)
        except Exception:
            return False

    def _close_attached_process(self) -> None:
        process = self.process
        if process is None or process.poll() is not None:
            return
        if process.stdin:
            try:
                process.stdin.close()
            except OSError:
                pass
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired) as error:
                raise Denied("attached container client did not terminate") from error
        except OSError as error:
            raise Denied("attached container client could not be terminated") from error

    def run(self, lock_bytes: bytes) -> dict[str, object]:
        self.lock = policy.validate_toolchain_lock(
            lock_bytes, expected_image_digest=self.image_digest
        )
        if (
            not HEX64.fullmatch(self.tuple_sha256)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", self.image_digest)
            or self.plan_sha256 != policy.PLAN_SHA256
            or not HEX40.fullmatch(self.source_sha)
        ):
            raise Denied("approved supervisor inputs are malformed")
        source_path = Path(self.source_export)
        if (
            source_path.is_symlink()
            or not source_path.is_dir()
            or source_path.resolve(strict=True) != source_path
        ):
            raise Denied("source export is not a canonical owned directory")
        started_at = time.monotonic()
        self.deadline = started_at + OUTER_SECONDS
        summary: dict[str, object] | None = None
        primary_error: BaseException | None = None
        old_handlers: dict[int, object] = {}

        def on_signal(signum: int, _frame: object) -> None:
            raise Denied(f"proof interrupted by signal {signum}")

        for signum in (
            getattr(signal, name)
            for name in ("SIGHUP", "SIGINT", "SIGTERM")
            if hasattr(signal, name)
        ):
            old_handlers[signum] = signal.signal(signum, on_signal)
        try:
            self._create_and_inspect()
            self._authorize("pre-start")
            self.process = self.engine.start_attached(self.container_id)
            self.wait_evidence = self._wait_for_ready()
            after_start = self.engine.inspect(self.container_id)
            validate_inspection(
                after_start,
                image_digest=self.image_digest,
                source_sha=self.source_sha,
                toolchain_sha256=self.toolchain_sha256,
                source_export=self.source_export,
                owner=self.owner,
                container_id=self.container_id,
                engine_root=self.engine_root,
                started=True,
            )
            self._collect_engine_file_evidence(after_start, self.wait_evidence)
            self._authorize("barrier")
            assert self.process.stdin
            self.process.stdin.write(b"RELEASE\n")
            self.process.stdin.flush()
            self.process.stdin.close()
            summary = self._collect_summary()
        except BaseException as error:
            primary_error = error
        try:
            self._close_attached_process()
        except BaseException as error:
            if primary_error is None:
                primary_error = Denied("attached container client cleanup failed")
        destroyed = self._cleanup()
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if not destroyed:
            raise Denied("owned container destruction was not confirmed") from primary_error
        if primary_error:
            raise Denied("retention proof did not produce complete evidence") from primary_error
        if time.monotonic() - started_at > OUTER_SECONDS:
            raise Denied("host proof exceeded its 600-second deadline")
        assert summary is not None
        return {
            "schemaVersion": 1,
            "outcome": "passed",
            "sourceSha": self.source_sha,
            "planSha256": self.plan_sha256,
            "imageDigest": self.image_digest,
            "toolchainSha256": self.toolchain_sha256,
            "extractedRetentionBlockSha256": summary[
                "extractedRetentionBlockSha256"
            ],
            "cases": summary["cases"],
            "selectiveCleanup": summary["selectiveCleanup"],
            "outsideSentinel": summary["outsideSentinel"],
            "containerDestroyed": True,
        }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-export", required=True)
    parser.add_argument("--source-checkout", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--image-digest", required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--toolchain-lock", required=True)
    parser.add_argument("--toolchain-sha256", required=True)
    parser.add_argument("--tuple-sha256", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        source = Path(args.source_export)
        source_checkout = Path(args.source_checkout)
        lock_bytes = Path(args.toolchain_lock).read_bytes()

        def authorize(checkpoint: str, expected_tuple_sha: str) -> dict[str, object]:
            command = [
                sys.executable,
                str(Path(__file__).with_name("retention-proof-authorize.py")),
                "--checkpoint",
                checkpoint,
                "--source-sha",
                args.source_sha,
                "--plan-sha256",
                args.plan_sha256,
                "--image-digest",
                args.image_digest,
                "--source-checkout",
                str(source_checkout),
                "--expected-registration",
                os.environ["EXPECTED_REGISTRATION"],
                "--expected-tuple-sha256",
                expected_tuple_sha,
            ]
            try:
                result = subprocess.run(
                    command,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                    env=os.environ.copy(),
                )
            except (OSError, subprocess.SubprocessError) as error:
                raise Denied("fresh authorization checkpoint failed") from error
            if len(result.stdout) > SUMMARY_LIMIT:
                raise Denied("authorization output exceeded its bound")
            value = policy.decode_json(result.stdout)
            if not isinstance(value, dict):
                raise Denied("authorization output is malformed")
            return value

        supervisor = RetentionSupervisor(
            DockerEngine(),
            authorize=authorize,
            source_export=str(source),
            source_sha=args.source_sha,
            image_digest=args.image_digest,
            plan_sha256=args.plan_sha256,
            toolchain_sha256=args.toolchain_sha256,
            tuple_sha256=args.tuple_sha256,
        )
        result = supervisor.run(lock_bytes)
        encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode()
        if len(encoded) > SUMMARY_LIMIT:
            raise Denied("sanitized host summary exceeds its bound")
        output_path = Path(args.output)
        if output_path.is_symlink() or output_path.exists():
            raise Denied("summary output path is not exclusively owned")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(output_path, flags, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
    except (Denied, policy.Denied, OSError, TypeError, ValueError, KeyError) as error:
        print(f"RETENTION_PROOF_FAILED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
