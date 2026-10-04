#!/usr/bin/env python3
"""Network-free retention proof supervisor, barrier, and teardown tests."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import time
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "retention_proof_supervisor",
    Path(__file__).with_name("retention-proof-supervisor.py"),
)
assert spec and spec.loader
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

helper_spec = importlib.util.spec_from_file_location(
    "retention_proof_host_metadata",
    Path(__file__).with_name("retention-proof-host-metadata.py"),
)
assert helper_spec and helper_spec.loader
host_metadata_helper = importlib.util.module_from_spec(helper_spec)
helper_spec.loader.exec_module(host_metadata_helper)

CONTAINER_ID = "a" * 64
IMAGE = "sha256:" + "b" * 64
SOURCE = Path(__file__).resolve().parent
SOURCE_PATH = os.path.realpath(SOURCE)
OWNER = "f" * 32
ROOT = "/var/lib/docker"
SOURCE_SHA = "c" * 40
PLAN_SHA = supervisor.policy.PLAN_SHA256
TOOLCHAIN_SHA = "d" * 64
TUPLE_SHA = "e" * 64
LOCK = {
    "schemaVersion": 1,
    "enabled": True,
    "platform": "linux/amd64",
    "baseImage": "ubuntu:24.04@sha256:" + "1" * 64,
    "ubuntuSnapshot": "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z",
    "packages": [
        {"name": name, "version": "1.2.3-1", "sha256": "a" * 64}
        for name in sorted(supervisor.policy.REQUIRED_PACKAGES)
    ],
    "dockerfileSha256": "2" * 64,
    "preparedImage": IMAGE,
    "provenanceSha256": "3" * 64,
    "engineVersion": "28.0.0",
    "engineApiVersion": "1.51",
    "engineLayout": "moby-v28-root-container-id-v1",
}
LOCK_BYTES = json.dumps(LOCK, sort_keys=True, separators=(",", ":")).encode()
LOCK_DIGEST = hashlib.sha256(LOCK_BYTES).hexdigest()
EXPECTED_ENV = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG=C.UTF-8",
    "TZ=UTC",
    f"RETENTION_PROOF_SOURCE_SHA={SOURCE_SHA}",
    f"RETENTION_PROOF_PLAN_SHA256={PLAN_SHA}",
    f"RETENTION_PROOF_IMAGE_DIGEST={IMAGE}",
    f"RETENTION_PROOF_TOOLCHAIN_SHA256={TOOLCHAIN_SHA}",
}
MOUNT_EVIDENCE = {
    target: {
        "root": f"{ROOT}/containers/{CONTAINER_ID}/{leaf}",
        "device": "8:1",
        "readOnly": True,
        "regular": True,
        "uid": 0,
    }
    for target, leaf in (
        ("/etc/hostname", "hostname"),
        ("/etc/hosts", "hosts"),
        ("/etc/resolv.conf", "resolv.conf"),
    )
}


class FakeMetadataOS:
    O_RDONLY = 1
    O_DIRECTORY = 2
    O_CLOEXEC = 4
    O_NOFOLLOW = 8
    O_PATH = 16

    def __init__(self) -> None:
        self.mountinfo = b"1 0 8:1 / / rw - ext4 /dev/root rw\n"
        self.trace: list[tuple[object, ...]] = []
        self.nodes: dict[str, SimpleNamespace] = {}
        self.descriptors: dict[int, str] = {}
        self.offsets: dict[int, int] = {}
        self.next_descriptor = 10
        self.root_opens = 0
        self.replace_on_second_walk = False
        self.replace_directory_on_second_walk = False
        self.mount_reads = 0
        self.change_mount_between_reads = False
        path = ""
        for index, component in enumerate(("", "var", "lib", "docker", "containers", CONTAINER_ID)):
            path = "/" if index == 0 else (path.rstrip("/") + "/" + component)
            self.nodes[path] = self._info(stat.S_IFDIR | 0o755, 0, index + 1)
        container_dir = f"{ROOT}/containers/{CONTAINER_ID}"
        for index, leaf in enumerate(("hostname", "hosts", "resolv.conf"), start=20):
            self.nodes[f"{container_dir}/{leaf}"] = self._info(
                stat.S_IFREG | 0o644, 0, index
            )

    @staticmethod
    def _info(mode: int, uid: int, inode: int) -> SimpleNamespace:
        return SimpleNamespace(
            st_mode=mode,
            st_uid=uid,
            st_gid=0,
            st_dev=2049,
            st_ino=inode,
        )

    def _path(self, path: str, dir_fd: int | None) -> str:
        if dir_fd is None:
            return path
        base = self.descriptors[dir_fd]
        return (base.rstrip("/") + "/" + path) if base != "/" else "/" + path

    def open(self, path: str, flags: int, *, dir_fd: int | None = None) -> int:
        self.trace.append(("open", path, flags, dir_fd))
        if path == "/":
            self.root_opens += 1
            if self.replace_on_second_walk and self.root_opens == 2:
                file_path = f"{ROOT}/containers/{CONTAINER_ID}/hosts"
                self.nodes[file_path].st_ino += 100
            if self.replace_directory_on_second_walk and self.root_opens == 2:
                self.nodes[f"{ROOT}/containers"].st_ino += 100
            resolved = "/"
        elif path == "/proc/self/mountinfo":
            self.mount_reads += 1
            if self.change_mount_between_reads and self.mount_reads == 2:
                self.mountinfo = b"1 0 8:2 / / rw - ext4 /dev/root rw\n"
            resolved = path
        else:
            resolved = self._path(path, dir_fd)
        if resolved not in self.nodes and resolved != "/proc/self/mountinfo":
            raise FileNotFoundError(resolved)
        if resolved == "/proc/self/mountinfo":
            self.offsets[self.next_descriptor] = 0
        if flags & self.O_DIRECTORY and resolved != "/proc/self/mountinfo":
            if not stat.S_ISDIR(self.nodes[resolved].st_mode):
                raise NotADirectoryError(resolved)
        descriptor = self.next_descriptor
        self.next_descriptor += 1
        self.descriptors[descriptor] = resolved
        return descriptor

    def stat(
        self, path: str, *, dir_fd: int | None = None, follow_symlinks: bool = True
    ) -> SimpleNamespace:
        resolved = self._path(path, dir_fd)
        self.trace.append(("stat", resolved, follow_symlinks))
        if resolved not in self.nodes:
            raise FileNotFoundError(resolved)
        return self.nodes[resolved]

    def fstat(self, descriptor: int) -> SimpleNamespace:
        path = self.descriptors[descriptor]
        self.trace.append(("fstat", path))
        if path == "/proc/self/mountinfo":
            return self._info(stat.S_IFREG | 0o444, 0, 500)
        return self.nodes[path]

    def read(self, descriptor: int, maximum: int) -> bytes:
        path = self.descriptors[descriptor]
        self.trace.append(("read", path, maximum))
        if path != "/proc/self/mountinfo":
            raise AssertionError("collector attempted to read a backing-file content")
        offset = self.offsets[descriptor]
        chunk = self.mountinfo[offset : offset + maximum]
        self.offsets[descriptor] = offset + len(chunk)
        return chunk

    def close(self, descriptor: int) -> None:
        path = self.descriptors.pop(descriptor)
        self.trace.append(("close", path))
        self.offsets.pop(descriptor, None)

    def write(self, *_args: object) -> None:
        raise AssertionError("metadata collector must not write")


def metadata_request() -> bytes:
    return json.dumps(
        {
            "schemaVersion": 1,
            "containerId": CONTAINER_ID,
            "owner": OWNER,
            "dockerRootDir": ROOT,
            "engineVersion": LOCK["engineVersion"],
            "engineApiVersion": LOCK["engineApiVersion"],
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def host_metadata_value() -> dict[str, object]:
    files: dict[str, dict[str, object]] = {}
    for target, leaf in (
        ("/etc/hostname", "hostname"),
        ("/etc/hosts", "hosts"),
        ("/etc/resolv.conf", "resolv.conf"),
    ):
        source = f"{ROOT}/containers/{CONTAINER_ID}/{leaf}"
        files[target] = {
            "source": source,
            "mode": stat.S_IFREG | 0o644,
            "uid": 0,
            "gid": 0,
            "device": 2049,
            "inode": 20 + ("hostname", "hosts", "resolv.conf").index(leaf),
            "mountRoot": source,
            "mountDevice": "8:1",
        }
    return {
        "schemaVersion": 1,
        "containerId": CONTAINER_ID,
        "owner": OWNER,
        "dockerRootDir": ROOT,
        "engineVersion": LOCK["engineVersion"],
        "engineApiVersion": LOCK["engineApiVersion"],
        "files": files,
    }


def docker_info_from_cli(version_payload: dict[str, object]) -> dict[str, object]:
    info_payload = {"DockerRootDir": ROOT, "ServerVersion": "untrusted-info-value"}
    results = [
        subprocess.CompletedProcess(
            ["docker", "info"],
            0,
            json.dumps(info_payload).encode(),
            b"",
        ),
        subprocess.CompletedProcess(
            ["docker", "version"],
            0,
            json.dumps(version_payload).encode(),
            b"",
        ),
    ]
    with patch.object(supervisor.subprocess, "run", side_effect=results) as run:
        value = supervisor.DockerEngine().info()
    calls = run.call_args_list
    assert calls[0].args[0] == ["docker", "info", "--format", "{{json .}}"]
    assert calls[1].args[0] == [
        "docker",
        "version",
        "--format",
        "{{json .Server}}",
    ]
    assert all(call.kwargs["timeout"] == 30 for call in calls)
    return value


def inspection(*, started: bool, owner: str = OWNER) -> dict[str, object]:
    configured_mount = {
        "Type": "bind",
        "Source": SOURCE_PATH,
        "Target": "/src",
        "ReadOnly": True,
        "Consistency": "",
    }
    mounts = [
        {
            "Type": "bind",
            "Source": SOURCE_PATH,
            "Destination": "/src",
            "RW": False,
        },
        {"Type": "tmpfs", "Source": "", "Destination": "/fixture", "RW": True},
        {"Type": "tmpfs", "Source": "", "Destination": "/tmp", "RW": True},
    ]
    paths: dict[str, str | None] = {
        "HostnamePath": None,
        "HostsPath": None,
        "ResolvConfPath": None,
    }
    if started:
        for destination, filename, field in (
            ("/etc/hostname", "hostname", "HostnamePath"),
            ("/etc/hosts", "hosts", "HostsPath"),
            ("/etc/resolv.conf", "resolv.conf", "ResolvConfPath"),
        ):
            source = f"{ROOT}/containers/{CONTAINER_ID}/{filename}"
            paths[field] = source
            mounts.append(
                {
                    "Type": "bind",
                    "Source": source,
                    "Destination": destination,
                    "RW": False,
                }
            )
    config = {
        "User": "0:0",
        "Volumes": {},
        "ExposedPorts": {},
        "Cmd": ["-I", "-S", "-c", supervisor.ADMISSION_BOOTSTRAP],
        "Entrypoint": ["python3"],
        "Labels": {supervisor.OWNER_LABEL: owner},
        "Image": IMAGE,
        "Env": sorted(EXPECTED_ENV),
    }
    host = {
        "NetworkMode": "none",
        "Privileged": False,
        "ReadonlyRootfs": True,
        "PidMode": "private",
        "IpcMode": "private",
        "CapAdd": ["CHOWN"],
        "CapDrop": ["ALL"],
        "SecurityOpt": ["no-new-privileges:true", "seccomp=builtin"],
        "Devices": [],
        "DeviceRequests": [],
        "PortBindings": {},
        "Binds": [],
        "Mounts": [configured_mount],
        "AutoRemove": False,
        "VolumesFrom": [],
        "LogConfig": {"Type": "none", "Config": {}},
        "Memory": 1024 * 1024 * 1024,
        "NanoCpus": 2_000_000_000,
        "PidsLimit": 256,
        "Tmpfs": {
            "/fixture": "rw,noexec,nosuid,nodev,size=268435456,mode=0700",
            "/tmp": "rw,noexec,nosuid,nodev,size=67108864,mode=1777",
        },
    }
    value: dict[str, object] = {
        "Id": CONTAINER_ID,
        "Config": config,
        "HostConfig": host,
        "Mounts": mounts,
        "State": {
            "Status": "running" if started else "created",
            "Running": started,
        },
    }
    value.update(paths)
    return value


def denied(callable_, label: str) -> None:
    try:
        callable_()
    except (supervisor.Denied, host_metadata_helper.Denied):
        return
    raise AssertionError(f"accepted invalid supervisor case: {label}")


def summary() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "outcome": "passed",
        "sourceSha": SOURCE_SHA,
        "planSha256": PLAN_SHA,
        "imageDigest": IMAGE,
        "toolchainSha256": LOCK_DIGEST,
        "extractedRetentionBlockSha256": "f" * 64,
        "cases": [
            {"id": case_id, "outcome": "passed"}
            for case_id in supervisor.REQUIRED_CASES
        ],
        "selectiveCleanup": True,
        "outsideSentinel": True,
    }


class RecordingInput:
    def __init__(self, events: list[str]) -> None:
        self.events = events
        self.closed = False

    def write(self, value: bytes) -> int:
        self.events.append("release:" + value.decode().strip())
        return len(value)

    def flush(self) -> None:
        self.events.append("flush")

    def close(self) -> None:
        self.closed = True
        self.events.append("stdin-close")


class FakeProcess:
    def __init__(self, events: list[str]) -> None:
        self.events = events
        self.stdin = RecordingInput(events)
        self.stdout = None
        self.returncode: int | None = None

    def poll(self) -> int | None:
        return self.returncode

    def terminate(self) -> None:
        self.events.append("process-terminate")
        self.returncode = -15

    def kill(self) -> None:
        self.events.append("process-kill")
        self.returncode = -9

    def wait(self, timeout: int) -> int:
        self.events.append("process-wait")
        if self.returncode is None:
            self.returncode = -15
        return self.returncode


class FakeEngine:
    def __init__(self, events: list[str]) -> None:
        self.events = events
        self.started = False
        self.removed = False
        self.absence_confirmed = True
        self.stop_fails = False
        self.invalid_after_start = False
        self.metadata_failure = False
        self.identity_drift_after_metadata = False
        self.path_drift_after_metadata = False
        self.metadata_collected = False
        self.created_image = ""
        self.created_source = ""
        self.process: FakeProcess | None = None

    def info(self) -> dict[str, object]:
        self.events.append("info")
        return {
            "DockerRootDir": ROOT,
            "ServerVersion": LOCK["engineVersion"],
            "ApiVersion": LOCK["engineApiVersion"],
        }

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
        assert source_sha == SOURCE_SHA
        assert plan_sha256 == PLAN_SHA
        assert toolchain_sha256 == TOOLCHAIN_SHA
        self.events.append("create")
        self.created_image = image
        self.created_source = source
        return CONTAINER_ID

    def inspect(self, container_id: str) -> dict[str, object]:
        assert container_id == CONTAINER_ID
        self.events.append("inspect")
        value = inspection(started=self.started)
        if self.invalid_after_start and self.started:
            value["Mounts"].append(value["Mounts"][0])
        if self.path_drift_after_metadata and self.metadata_collected and self.started:
            value["HostsPath"] = f"{ROOT}/containers/{CONTAINER_ID}/substituted"
        return value

    def start_attached(self, container_id: str) -> FakeProcess:
        assert container_id == CONTAINER_ID
        self.events.append("start")
        self.started = True
        self.process = FakeProcess(self.events)
        return self.process

    def host_mountinfo(self) -> bytes:
        self.events.append("host-mountinfo")
        return b"1 0 8:1 / / rw - ext4 /dev/root rw\n"

    def collect_host_metadata(self, request: bytes) -> dict[str, object]:
        self.events.append("metadata")
        parsed = supervisor.validate_metadata_request(request)
        assert parsed["containerId"] == CONTAINER_ID
        assert parsed["owner"] == OWNER
        if self.metadata_failure:
            raise supervisor.Denied("injected host metadata failure")
        self.metadata_collected = True
        if self.identity_drift_after_metadata:
            self.info = lambda: {
                "DockerRootDir": "/changed",
                "ServerVersion": LOCK["engineVersion"],
                "ApiVersion": LOCK["engineApiVersion"],
            }
        return host_metadata_value()

    def stop(self, container_id: str) -> None:
        assert container_id == CONTAINER_ID
        self.events.append("stop")
        if self.stop_fails:
            raise supervisor.Denied("injected stop failure")
        self.started = False

    def remove(self, container_id: str) -> None:
        assert container_id == CONTAINER_ID
        self.events.append("remove")
        self.removed = True

    def absent(self, container_id: str) -> bool:
        assert container_id == CONTAINER_ID
        self.events.append("absent")
        return self.absence_confirmed and self.removed


def new_supervisor(
    engine: FakeEngine,
    events: list[str],
    *,
    authorize=None,
) -> supervisor.RetentionSupervisor:
    def allow(checkpoint: str, digest: str) -> dict[str, str]:
        events.append(checkpoint)
        return {"tupleSha256": digest}

    instance = supervisor.RetentionSupervisor(
        engine,
        authorize=authorize or allow,
        source_export=SOURCE_PATH,
        source_sha=SOURCE_SHA,
        image_digest=IMAGE,
        plan_sha256=PLAN_SHA,
        toolchain_sha256=TOOLCHAIN_SHA,
        tuple_sha256=TUPLE_SHA,
        owner=OWNER,
    )
    instance._wait_for_ready = lambda: MOUNT_EVIDENCE

    def collect() -> dict[str, object]:
        events.append("summary")
        assert engine.process is not None
        engine.process.returncode = 0
        return summary()

    instance._collect_summary = collect
    return instance


def test_host_metadata_helper() -> None:
    request = metadata_request()
    fake_os = FakeMetadataOS()
    result = host_metadata_helper.collect_metadata(request, ops=fake_os)
    assert result == host_metadata_value()
    assert not fake_os.descriptors
    assert all(event[0] in {"open", "stat", "fstat", "read", "close"} for event in fake_os.trace)
    assert all(
        event[1] == "/proc/self/mountinfo"
        for event in fake_os.trace
        if event[0] == "read"
    )
    opened_paths = [event[1] for event in fake_os.trace if event[0] == "open"]
    assert opened_paths.count("/proc/self/mountinfo") == 2
    assert not any(event[0] == "write" for event in fake_os.trace)

    duplicate = request.replace(
        b'"schemaVersion":1',
        b'"schemaVersion":1,"schemaVersion":1',
        1,
    )
    unknown = request[:-1] + b',"unexpected":true}'
    for invalid in (duplicate, unknown, b"x" * 1025):
        fake = FakeMetadataOS()
        denied(
            lambda invalid=invalid, fake=fake: host_metadata_helper.collect_metadata(
                invalid, ops=fake
            ),
            "invalid collector request",
        )
        assert not fake.trace

    for mutate, label in (
        (
            lambda fake: setattr(
                fake.nodes["/var"], "st_mode", stat.S_IFLNK | 0o777
            ),
            "symlinked ancestry",
        ),
        (
            lambda fake: setattr(
                fake.nodes[f"{ROOT}/containers/{CONTAINER_ID}/hostname"],
                "st_uid",
                1000,
            ),
            "non-root-owned leaf",
        ),
        (
            lambda fake: setattr(
                fake.nodes[f"{ROOT}/containers/{CONTAINER_ID}/hostname"],
                "st_mode",
                stat.S_IFLNK | 0o777,
            ),
            "symlink leaf",
        ),
        (
            lambda fake: setattr(
                fake.nodes[f"{ROOT}/containers/{CONTAINER_ID}/hostname"],
                "st_mode",
                stat.S_IFDIR | 0o755,
            ),
            "non-regular leaf",
        ),
        (
            lambda fake: setattr(fake, "replace_on_second_walk", True),
            "replaced file inode",
        ),
        (
            lambda fake: setattr(fake, "replace_directory_on_second_walk", True),
            "replaced ancestry",
        ),
        (
            lambda fake: setattr(
                fake,
                "mountinfo",
                b"1 0 8:2 / / rw - ext4 /dev/root rw\n",
            ),
            "device mismatch",
        ),
        (
            lambda fake: setattr(fake, "change_mount_between_reads", True),
            "mount-table change",
        ),
        (
            lambda fake: setattr(fake, "mountinfo", b"x" * (1024 * 1024 + 1)),
            "oversized mount table",
        ),
    ):
        fake = FakeMetadataOS()
        mutate(fake)
        denied(
            lambda fake=fake: host_metadata_helper.collect_metadata(
                request, ops=fake
            ),
            label,
        )


def test_root_collector_invocation() -> None:
    request = metadata_request()
    result = host_metadata_helper.collect_metadata(request, ops=FakeMetadataOS())
    encoded = json.dumps(result, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    processes: list[object] = []

    class CapturedInput(io.BytesIO):
        captured = b""

        def close(self) -> None:
            self.captured = self.getvalue()
            super().close()

    class CapturedOutput:
        def __init__(self) -> None:
            self.closed = False

        @staticmethod
        def fileno() -> int:
            return 77

        def close(self) -> None:
            self.closed = True

    class FakeSelector:
        def __init__(self) -> None:
            self.files: dict[int, object] = {}

        def register(self, fileobj: object, _events: int) -> None:
            self.files[fileobj.fileno()] = fileobj

        def unregister(self, fileobj: object) -> None:
            self.files.pop(fileobj.fileno())

        def get_map(self) -> dict[int, object]:
            return self.files

        def select(self, timeout: float) -> list[tuple[object, int]]:
            assert timeout > 0
            if keep_open:
                time.sleep(min(timeout, 0.01))
                return []
            return [
                (
                    SimpleNamespace(fd=descriptor, fileobj=fileobj),
                    supervisor.selectors.EVENT_READ,
                )
                for descriptor, fileobj in self.files.items()
            ]

        def close(self) -> None:
            self.files.clear()

    class CollectorProcess:
        def __init__(self, return_code: int | None) -> None:
            self.stdin = CapturedInput()
            self.stdout = CapturedOutput()
            self.stderr = None
            self.pid = 999999
            self.return_code = return_code

        def poll(self) -> int | None:
            return self.return_code

        def wait(self, timeout: float) -> int:
            assert timeout > 0
            if self.return_code is None:
                self.return_code = -15
            return self.return_code

    def spawn(command: list[str], **kwargs: object) -> CollectorProcess:
        process = CollectorProcess(exit_code)
        processes.append(process)
        assert kwargs["shell"] is False
        assert kwargs["cwd"] == "/"
        assert kwargs["close_fds"] is True
        assert kwargs["start_new_session"] is True
        assert kwargs["env"] == {
            "PATH": "/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "TZ": "UTC",
            "HOME": "/",
        }
        assert command[:9] == [
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
        helper_bytes = Path(__file__).with_name(
            "retention-proof-host-metadata.py"
        ).read_bytes()
        assert command[9].encode("utf-8") == helper_bytes
        assert hashlib.sha256(command[9].encode("utf-8")).hexdigest() == (
            supervisor.METADATA_HELPER_SHA256
        )
        return process

    output = bytearray(encoded)
    exit_code: int | None = 0
    keep_open = False
    real_read = os.read

    def fake_read(descriptor: int, maximum: int) -> bytes:
        if descriptor != 77:
            return real_read(descriptor, maximum)
        chunk = bytes(output[:maximum])
        del output[:maximum]
        return chunk

    engine = supervisor.DockerEngine()
    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(supervisor.subprocess, "Popen", side_effect=spawn) as popen,
        patch.object(supervisor.selectors, "DefaultSelector", FakeSelector),
        patch.object(supervisor.os, "read", side_effect=fake_read),
    ):
        assert engine.collect_host_metadata(request) == result
    assert popen.call_count == 1
    assert processes[0].stdin.captured == request
    assert processes[0].stdout.closed

    exit_code = 1
    output = bytearray(encoded)
    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(supervisor.subprocess, "Popen", side_effect=spawn),
        patch.object(supervisor.selectors, "DefaultSelector", FakeSelector),
        patch.object(supervisor.os, "read", side_effect=fake_read),
    ):
        denied(
            lambda: engine.collect_host_metadata(request),
            "collector nonzero exit",
        )

    exit_code = 0
    output = bytearray(b"x" * (64 * 1024 + 1))
    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(supervisor.subprocess, "Popen", side_effect=spawn),
        patch.object(supervisor.selectors, "DefaultSelector", FakeSelector),
        patch.object(supervisor.os, "read", side_effect=fake_read),
    ):
        denied(
            lambda: engine.collect_host_metadata(request),
            "oversized collector output",
        )

    output = bytearray()
    keep_open = True
    exit_code = None
    engine.deadline = time.monotonic() + 0.05
    terminated: list[tuple[int, int]] = []
    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(supervisor.subprocess, "Popen", side_effect=spawn),
        patch.object(supervisor.selectors, "DefaultSelector", FakeSelector),
        patch.object(supervisor.os, "read", side_effect=fake_read),
        patch.object(
            supervisor.os,
            "killpg",
            create=True,
            side_effect=lambda pid, signum: terminated.append((pid, signum)),
        ),
    ):
        denied(lambda: engine.collect_host_metadata(request), "collector timeout")
    assert terminated == [(999999, signal.SIGTERM)]
    assert processes[-1].return_code == -15
    engine.deadline = 0
    keep_open = False

    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(
            supervisor,
            "METADATA_HELPER_SHA256",
            "0" * 64,
        ),
        patch.object(supervisor.subprocess, "Popen") as popen,
    ):
        denied(lambda: engine.collect_host_metadata(request), "bad helper digest")
        popen.assert_not_called()

    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(
            supervisor.DockerEngine,
            "_verify_helper_path",
            side_effect=[None, supervisor.Denied("replacement before transition")],
        ),
        patch.object(supervisor.subprocess, "Popen") as popen,
    ):
        denied(
            lambda: engine.collect_host_metadata(request),
            "helper replacement before privilege",
        )
        popen.assert_not_called()

    with (
        patch.object(supervisor.DockerEngine, "_verify_metadata_runtime"),
        patch.object(supervisor.subprocess, "Popen") as popen,
    ):
        denied(
            lambda: engine.collect_host_metadata(request[:-1] + b',"path":"/etc/passwd"}'),
            "caller-selected path",
        )
        popen.assert_not_called()


def main() -> None:
    test_host_metadata_helper()
    test_root_collector_invocation()

    server_version = {
        "Platform": {"Name": "Docker Engine - Community"},
        "Version": LOCK["engineVersion"],
        "ApiVersion": LOCK["engineApiVersion"],
        "MinAPIVersion": "1.24",
    }
    live_format = docker_info_from_cli(server_version)
    assert live_format["ServerVersion"] == LOCK["engineVersion"]
    assert live_format["ApiVersion"] == LOCK["engineApiVersion"]
    assert supervisor.validate_engine_info(live_format, LOCK) == ROOT
    for invalid_version, label in (
        (
            {
                key: value
                for key, value in server_version.items()
                if key != "ApiVersion"
            },
            "missing Docker server API version",
        ),
        (
            {**server_version, "ApiVersion": "1.52"},
            "mismatched Docker server API version",
        ),
        (
            {**server_version, "Version": "29.0.0"},
            "mismatched Docker server version",
        ),
    ):
        denied(
            lambda invalid_version=invalid_version: supervisor.validate_engine_info(
                docker_info_from_cli(invalid_version), LOCK
            ),
            label,
        )

    for started in (False, True):
        supervisor.validate_inspection(
            inspection(started=started),
            image_digest=IMAGE,
            source_sha=SOURCE_SHA,
            toolchain_sha256=TOOLCHAIN_SHA,
            source_export=SOURCE_PATH,
            owner=OWNER,
            container_id=CONTAINER_ID,
            engine_root=ROOT,
            started=started,
        )

    for mutation, label in (
        (lambda item: item["Mounts"].append(item["Mounts"][0]), "duplicate mount"),
        (
            lambda item: item["Mounts"][0].update(Source="/untrusted/source"),
            "substituted source",
        ),
        (
            lambda item: item.update(
                ResolvConfPath=f"{ROOT}/containers/{CONTAINER_ID}/resolvconf"
            ),
            "resolv.conf leaf",
        ),
        (
            lambda item: item["HostConfig"].update(NetworkMode="host"),
            "host networking",
        ),
        (
            lambda item: item["HostConfig"].update(Mounts=[]),
            "missing source bind",
        ),
        (
            lambda item: item["HostConfig"]["Mounts"][0].update(ReadOnly=False),
            "writable source",
        ),
        (
            lambda item: item["Config"].update(Env=["GITHUB_TOKEN=secret"]),
            "secret environment",
        ),
        (lambda item: item["Config"].update(Volumes={"/etc/hosts": {}}), "image volume"),
        (
            lambda item: item["HostConfig"].update(Privileged=True),
            "privileged container",
        ),
    ):
        invalid = inspection(started=label == "resolv.conf leaf")
        mutation(invalid)
        denied(
            lambda: supervisor.validate_inspection(
                invalid,
                image_digest=IMAGE,
                source_sha=SOURCE_SHA,
                toolchain_sha256=TOOLCHAIN_SHA,
                source_export=SOURCE_PATH,
                owner=OWNER,
                container_id=CONTAINER_ID,
                engine_root=ROOT,
                started=label == "resolv.conf leaf",
            ),
            label,
        )

    valid_summary = summary()
    raw = (
        b"RETENTION_ADMISSION_READY:{}\nRETENTION_FIXTURE_SUMMARY:"
        + json.dumps(valid_summary, separators=(",", ":")).encode()
        + b"\n"
    )
    assert supervisor.validate_summary(
        raw,
        source_sha=SOURCE_SHA,
        image_digest=IMAGE,
        toolchain_sha256=LOCK_DIGEST,
    ) == valid_summary
    for invalid in (
        raw + raw,
        raw.replace(b'"outcome":"passed"', b'"outcome":"failed"'),
        raw.replace(b'"outsideSentinel":true', b'"unexpected":true,"outsideSentinel":true'),
        raw.replace(
            b'"id":"smtp-transaction-lock-contention-denied"',
            b'"id":"smtp-transaction-lock-contention-denied","id":"duplicate"',
        ),
        raw + b"x" * supervisor.SUMMARY_LIMIT,
    ):
        denied(
            lambda invalid=invalid: supervisor.validate_summary(
                invalid,
                source_sha=SOURCE_SHA,
                image_digest=IMAGE,
                toolchain_sha256=LOCK_DIGEST,
            ),
            "malformed, incomplete, duplicate, or oversized summary",
        )

    host_mountinfo = b"1 0 8:1 / / rw - ext4 /dev/root rw\n"
    inspection_started = inspection(started=True)
    evidence = {
        target: {
            **values,
            "root": values["root"],
        }
        for target, values in MOUNT_EVIDENCE.items()
    }
    metadata = host_metadata_value()
    with patch.object(
        supervisor.os,
        "lstat",
        side_effect=PermissionError(13, "permission denied"),
    ) as denied_unprivileged_lstat:
        supervisor.validate_engine_file_evidence(
            inspection_started,
            engine_root=ROOT,
            container_id=CONTAINER_ID,
            owner=OWNER,
            engine_version=LOCK["engineVersion"],
            engine_api_version=LOCK["engineApiVersion"],
            host_metadata=metadata,
            host_mountinfo_bytes=host_mountinfo,
            container_evidence=evidence,
        )
        denied_unprivileged_lstat.assert_not_called()
        for changed in (
            {**evidence, "/etc/hosts": {**evidence["/etc/hosts"], "readOnly": False}},
            {**evidence, "/etc/hosts": {**evidence["/etc/hosts"], "device": "8:2"}},
            {**evidence, "/etc/hosts": {**evidence["/etc/hosts"], "root": "/substitute"}},
            {**evidence, "/etc/extra": {}},
        ):
            denied(
                lambda changed=changed: supervisor.validate_engine_file_evidence(
                    inspection_started,
                    engine_root=ROOT,
                    container_id=CONTAINER_ID,
                    owner=OWNER,
                    engine_version=LOCK["engineVersion"],
                    engine_api_version=LOCK["engineApiVersion"],
                    host_metadata=metadata,
                    host_mountinfo_bytes=host_mountinfo,
                    container_evidence=changed,
                ),
                "forged host/container mount evidence",
            )
        for changed_metadata in (
            {**metadata, "owner": "0" * 32},
            {**metadata, "dockerRootDir": "/changed"},
            {**metadata, "containerId": "0" * 64},
            {**metadata, "engineVersion": "29.0.0"},
            {**metadata, "engineApiVersion": "1.52"},
            {
                **metadata,
                "files": {
                    **metadata["files"],
                    "/etc/hosts": {
                        **metadata["files"]["/etc/hosts"],
                        "source": "/etc/passwd",
                    },
                },
            },
            {
                **metadata,
                "files": {
                    **metadata["files"],
                    "/etc/hosts": {
                        **metadata["files"]["/etc/hosts"],
                        "uid": 1000,
                    },
                },
            },
            {
                **metadata,
                "files": {
                    **metadata["files"],
                    "/etc/hosts": {
                        **metadata["files"]["/etc/hosts"],
                        "mountRoot": "/wrong",
                    },
                },
            },
        ):
            denied(
                lambda changed_metadata=changed_metadata: supervisor.validate_engine_file_evidence(
                    inspection_started,
                    engine_root=ROOT,
                    container_id=CONTAINER_ID,
                    owner=OWNER,
                    engine_version=LOCK["engineVersion"],
                    engine_api_version=LOCK["engineApiVersion"],
                    host_metadata=changed_metadata,
                    host_mountinfo_bytes=host_mountinfo,
                    container_evidence=evidence,
                ),
                "unbound or substituted host metadata",
            )
    for invalid_mountinfo in (
        b"",
        b"bad mount row\n",
        b"1 0 8:x / / rw - ext4 /dev/root rw\n",
    ):
        denied(
            lambda invalid_mountinfo=invalid_mountinfo: supervisor.parse_mountinfo(
                invalid_mountinfo
            ),
            "malformed host mount table",
        )

    events: list[str] = []
    engine = FakeEngine(events)
    instance = new_supervisor(engine, events)
    result = instance.run(LOCK_BYTES)
    assert result["outcome"] == "passed"
    assert result["containerDestroyed"] is True
    assert engine.removed and events.count("absent") == 1
    assert events.index("info") < events.index("pre-create") < events.index("create")
    assert events.index("create") < events.index("pre-start") < events.index("start")
    assert events.index("metadata") < events.index("host-mountinfo")
    assert events.index("host-mountinfo") < events.index("barrier")
    assert events.index("barrier") < events.index("release:RELEASE")
    assert events.index("release:RELEASE") < events.index("summary")
    assert events.index("summary") < events.index("remove") < events.index("absent")

    for attribute, label in (
        ("metadata_failure", "collector denial"),
        ("identity_drift_after_metadata", "Engine identity drift"),
        ("path_drift_after_metadata", "Engine path drift"),
    ):
        events = []
        engine = FakeEngine(events)
        setattr(engine, attribute, True)
        instance = new_supervisor(engine, events)
        denied(lambda: instance.run(LOCK_BYTES), label)
        assert "metadata" in events
        assert "release:RELEASE" not in events
        assert engine.removed and events[-1] == "absent"

    for point in ("pre-create", "pre-start", "barrier"):
        events = []
        engine = FakeEngine(events)

        def reject(checkpoint: str, digest: str) -> dict[str, str]:
            events.append(checkpoint)
            if checkpoint == point:
                raise supervisor.Denied("injected authority drift")
            return {"tupleSha256": digest}

        instance = new_supervisor(engine, events, authorize=reject)
        with patch.object(supervisor, "validate_engine_file_evidence"):
            denied(lambda: instance.run(LOCK_BYTES), point + " authorization")
        assert "release:RELEASE" not in events
        if point == "pre-create":
            assert "create" not in events and "start" not in events
            assert not engine.removed and "absent" not in events
        else:
            assert engine.removed and events[-1] == "absent"
        if point == "pre-create":
            continue
        if point == "pre-start":
            assert "start" not in events
        else:
            assert "start" in events and "stop" in events

    for caught in (
        getattr(signal, name)
        for name in ("SIGHUP", "SIGINT", "SIGTERM")
        if hasattr(signal, name)
    ):
        events = []
        engine = FakeEngine(events)

        def interrupt(checkpoint: str, digest: str) -> dict[str, str]:
            events.append(checkpoint)
            if checkpoint == "barrier":
                signal.raise_signal(caught)
            return {"tupleSha256": digest}

        instance = new_supervisor(engine, events, authorize=interrupt)
        with patch.object(supervisor, "validate_engine_file_evidence"):
            denied(lambda: instance.run(LOCK_BYTES), f"signal {caught}")
        assert "release:RELEASE" not in events
        assert engine.removed and events[-1] == "absent"

    for change, label in (
        (lambda fake: setattr(fake, "stop_fails", True), "stop failure"),
        (
            lambda fake: setattr(fake, "absence_confirmed", False),
            "absence failure",
        ),
        (
            lambda fake: setattr(fake, "invalid_after_start", True),
            "container identity drift",
        ),
    ):
        events = []
        engine = FakeEngine(events)
        change(engine)
        instance = new_supervisor(engine, events)
        with patch.object(supervisor, "validate_engine_file_evidence"):
            denied(lambda: instance.run(LOCK_BYTES), label)
        if label == "container identity drift":
            assert "release:RELEASE" not in events
        if label == "stop failure":
            assert not engine.removed and "absent" not in events
        else:
            assert engine.removed and events[-1] == "absent"

    docker = supervisor.DockerEngine()
    missing = subprocess.CompletedProcess(
        ["docker", "inspect"],
        1,
        b"",
        f"Error: No such object: {CONTAINER_ID}\n".encode(),
    )
    with patch.object(supervisor.subprocess, "run", return_value=missing):
        assert docker.absent(CONTAINER_ID)
    permission_error = subprocess.CompletedProcess(
        ["docker", "inspect"], 1, b"", b"permission denied\n"
    )
    with patch.object(supervisor.subprocess, "run", return_value=permission_error):
        assert not docker.absent(CONTAINER_ID)
    daemon_error = subprocess.CompletedProcess(
        ["docker", "inspect"],
        2,
        b"",
        f"Error: No such object: {CONTAINER_ID}\n".encode(),
    )
    with patch.object(supervisor.subprocess, "run", return_value=daemon_error):
        assert not docker.absent(CONTAINER_ID)

    print("retention proof supervisor barrier, authority, summary, and teardown fakes passed")


if __name__ == "__main__":
    main()
