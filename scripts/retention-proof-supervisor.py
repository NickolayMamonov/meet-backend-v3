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
            "seccomp=default",
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
    host_mountinfo_bytes: bytes,
    container_evidence: object,
) -> None:
    host_mounts = parse_mountinfo(host_mountinfo_bytes)
    if (
        not isinstance(container_evidence, dict)
        or set(container_evidence) != {"/etc/hostname", "/etc/hosts", "/etc/resolv.conf"}
    ):
        raise Denied("container engine-file mount evidence is incomplete")
    leaves = {
        "/etc/hostname": ("HostnamePath", "hostname"),
        "/etc/hosts": ("HostsPath", "hosts"),
        "/etc/resolv.conf": ("ResolvConfPath", "resolv.conf"),
    }
    for target, (field, leaf) in leaves.items():
        expected = f"{engine_root}/containers/{container_id}/{leaf}"
        if inspection.get(field) != expected:
            raise Denied("engine file source path differs")
        try:
            info = os.lstat(expected)
        except OSError as error:
            raise Denied("engine file source is unavailable") from error
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0:
            raise Denied("engine file source is not a root-owned regular file")
        host = host_backing_mount(expected, host_mounts)
        device = device_number(info.st_dev)
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
            or device != host["device"]
        ):
            raise Denied("container and host engine-file mount evidence differs")


def validate_engine_info(info: dict[str, object], lock: dict[str, object]) -> str:
    docker_root = info.get("DockerRootDir")
    if (
        info.get("ServerVersion") != lock["engineVersion"]
        or info.get("ApiVersion") != lock["engineApiVersion"]
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
        != {"no-new-privileges:true", "seccomp=default"}
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
            validate_engine_file_evidence(
                after_start,
                engine_root=self.engine_root,
                container_id=self.container_id,
                host_mountinfo_bytes=self.engine.host_mountinfo(),
                container_evidence=self.wait_evidence,
            )
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
