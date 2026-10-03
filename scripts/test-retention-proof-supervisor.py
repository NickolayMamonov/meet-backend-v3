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
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "retention_proof_supervisor",
    Path(__file__).with_name("retention-proof-supervisor.py"),
)
assert spec and spec.loader
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

CONTAINER_ID = "a" * 64
IMAGE = "sha256:" + "b" * 64
SOURCE = Path(__file__).resolve().parent
SOURCE_PATH = os.path.realpath(SOURCE)
OWNER = "test-owner"
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
        "SecurityOpt": ["no-new-privileges:true", "seccomp=default"],
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
    except supervisor.Denied:
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


def main() -> None:
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
    with patch.object(
        supervisor.os,
        "lstat",
        return_value=SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600,
            st_uid=0,
            st_dev=2049,
        ),
    ):
        supervisor.validate_engine_file_evidence(
            inspection_started,
            engine_root=ROOT,
            container_id=CONTAINER_ID,
            host_mountinfo_bytes=host_mountinfo,
            container_evidence=evidence,
        )
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
                    host_mountinfo_bytes=host_mountinfo,
                    container_evidence=changed,
                ),
                "forged host/container mount evidence",
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
    with patch.object(supervisor, "validate_engine_file_evidence"):
        result = instance.run(LOCK_BYTES)
    assert result["outcome"] == "passed"
    assert result["containerDestroyed"] is True
    assert engine.removed and events.count("absent") == 1
    assert events.index("info") < events.index("pre-create") < events.index("create")
    assert events.index("create") < events.index("pre-start") < events.index("start")
    assert events.index("host-mountinfo") < events.index("barrier")
    assert events.index("barrier") < events.index("release:RELEASE")
    assert events.index("release:RELEASE") < events.index("summary")
    assert events.index("summary") < events.index("remove") < events.index("absent")

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
