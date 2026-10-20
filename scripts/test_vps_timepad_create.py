"""Private guarded-create driver. There is deliberately no executable entry point.

Only external observations and the fixed no-start process cross ``Transport``.
Admission, intent, wait evidence, completion publication and binding remain in
the real guard/provider/supervisor implementations.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager, redirect_stdout
from dataclasses import dataclass, replace
from enum import Enum
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import posixpath
import re
import selectors
import stat
import subprocess
import sys
import time
import traceback
from typing import Any, Iterator, Protocol

import test_vps_timepad_state as guard

NS = 1_000_000_000
MAX_MODEL = 256 * 1024
MAX_EVIDENCE = 8 * 1024 * 1024
MAX_ITEMS = 256
SCRIPTS = Path(__file__).resolve().parent
ACTIVE_COMPOSE = "/var/lib/meet-production/active-compose.yml"
ACTIVE_RUNTIME = "/var/lib/meet-production/active-runtime.override.yml"
INPUT_NAMES = ("config.env.target", "config.base-compose.yml", "target-runtime.override.yml")
TOOLING_NAMES = (
    "deploy-test-vps-provider-release.sh", "test-vps-runtime-invariants.sh",
    "test_vps_timepad_state.py", "test-vps-timepad-release-contracts.json",
    "test_vps_timepad_supervisor.py", "test_vps_timepad_create.py",
    "test-vps-provider-credential.py",
)


class CreateError(Exception):
    """A fixed private refusal; never includes a model, path or subprocess log."""


def refuse(reason: str = "PRIVATE_CREATE_ADMISSION_REFUSED") -> None:
    raise CreateError(reason)


class Action(str, Enum):
    ADMIT_TARGET = "admit-target"
    PUBLISH_PREPARED = "publish-prepared"
    VERIFY_TARGET = "verify-target"
    CREATE = "create"
    RECONCILE_BOUND = "reconcile-bound"


class Role(str, Enum):
    INITIAL = "initial"
    REPLACEMENT = "replacement"


class View(str, Enum):
    FROZEN_TARGET = "frozen-target"
    INSTALLED_WRAPPER = "installed-wrapper"


class Stage(str, Enum):
    PREPARE = "prepare"
    RENDER = "render"
    LAUNCH = "launch"
    COMPLETE = "complete"


def state_run_identity(owned_run: str) -> tuple[str, str]:
    for suffix, state_kind in (
        ("-rollback-drill", "rollback-drill"),
        ("-final-deploy", "final-deploy"),
    ):
        if owned_run.endswith(suffix):
            run_key = owned_run[:-len(suffix)]
            if re.fullmatch(r"[0-9]+-[0-9]+", run_key) is None:
                refuse()
            return run_key, state_kind
    refuse()


def canonical(value: Any, limit: int) -> bytes:
    try:
        data = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    except (ValueError, TypeError, RecursionError):
        refuse()
    if len(data) > limit:
        refuse()
    return data


def parse(data: bytes, limit: int) -> Any:
    if len(data) > limit:
        refuse()

    def unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result = {}
        for key, value in pairs:
            if key in result:
                refuse()
            result[key] = value
        return result

    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: refuse())
    except (ValueError, TypeError, RecursionError):
        refuse()


def stable(info: os.stat_result) -> tuple[int, ...]:
    return (
        info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
        info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns,
    )


def protected(path: str, *, directory: bool = False, private: bool = False) -> os.stat_result:
    if not isinstance(path, str) or not path.startswith("/") or os.path.normpath(path) != path:
        refuse()
    current = path
    while True:
        info = os.lstat(current)
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            refuse()
        if current != path and not stat.S_ISDIR(info.st_mode):
            refuse()
        if any(name in os.listxattr(current) for name in (
            "system.posix_acl_access", "system.posix_acl_default",
        )):
            refuse()
        if current == "/":
            break
        current = os.path.dirname(current)
    info = os.lstat(path)
    if directory:
        if not stat.S_ISDIR(info.st_mode):
            refuse()
    elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        refuse()
    if private and stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        refuse()
    return info


def read_protected(path: str, limit: int, *, private: bool = True) -> bytes:
    before = protected(path, private=private)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if stable(os.fstat(fd)) != stable(before) or before.st_size > limit:
            refuse()
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) != before.st_size or stable(os.fstat(fd)) != stable(before) or \
                stable(os.lstat(path)) != stable(before):
            refuse()
        return bytes(data)
    finally:
        os.close(fd)


def file_identity(path: str, *, private: bool = True) -> str:
    before = protected(path, private=private)
    data = read_protected(path, 1024 * 1024, private=private)
    if stable(os.lstat(path)) != stable(before):
        refuse()
    return ":".join(str(part) for part in (
        before.st_dev, before.st_ino, before.st_mode, before.st_uid, before.st_gid,
        before.st_size, before.st_mtime_ns, before.st_ctime_ns,
        hashlib.sha256(data).hexdigest(),
    ))


def tooling_digest() -> str:
    # Preserve the controller's sha256sum-vector format, including fixed paths.
    vector = b"".join(
        hashlib.sha256(read_protected(str(SCRIPTS / name), 1024 * 1024, private=False))
        .hexdigest().encode() + b"  " + str(SCRIPTS / name).encode() + b"\n"
        for name in TOOLING_NAMES
    )
    return hashlib.sha256(vector).hexdigest()


@dataclass(frozen=True)
class Selection:
    deployment_root: str
    base_compose: str
    image: str
    revision: str
    version: str
    run_key: str
    mode: str
    operation: str
    recovery_run: str = ""
    recovery_incident: str = ""
    recovery_epoch: str = ""
    recovery_binding: str = ""

    @classmethod
    def from_arguments(cls, arguments: list[str]) -> Selection:
        # This is the already-admitted controller vector, not a driver RPC API.
        valued = {
            "--root", "--base-compose", "--image", "--revision", "--version", "--run-key",
            "--mode", "--operation", "--rollout-domain", "--initial-proof-id", "--bootstrap-id",
            "--recovery-run-key", "--recovery-incident", "--recovery-epoch",
            "--recovery-binding-digest", "--recovery-action", "--state-mode", "--public-url",
        }
        values: dict[str, str] = {}
        index = 0
        while index < len(arguments):
            key = arguments[index]
            if key == "--closed-beta-safety" and key not in values:
                values[key] = "true"
                index += 1
                continue
            if key not in valued or key in values or index + 1 >= len(arguments):
                refuse()
            values[key] = arguments[index + 1]
            index += 2
        required = {"--root", "--base-compose", "--image", "--revision", "--version", "--run-key", "--mode"}
        if not required <= values.keys():
            refuse()
        for key in ("--root", "--base-compose"):
            path = values[key]
            if re.fullmatch(r"/[A-Za-z0-9._/-]+", path) is None or ".." in path or \
                    posixpath.normpath(path) != path:
                refuse()
        if re.fullmatch(r"ghcr\.io/nickolaymamonov/meet-backend-v3@sha256:[a-f0-9]{64}", values["--image"]) is None \
                or re.fullmatch(r"[a-f0-9]{40}", values["--revision"]) is None \
                or re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", values["--version"]) is None \
                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", values["--run-key"]) is None \
                or values["--mode"] not in {"deploy", "rollback-drill"} \
                or values.get("--operation", "deploy") not in {"deploy", "forward-recover"}:
            refuse()
        selection = cls(
            values["--root"], values["--base-compose"], values["--image"], values["--revision"],
            values["--version"], values["--run-key"], values["--mode"],
            values.get("--operation", "deploy"), values.get("--recovery-run-key", ""),
            values.get("--recovery-incident", "").lower(), values.get("--recovery-epoch", ""),
            values.get("--recovery-binding-digest", ""),
        )
        if selection.operation == "forward-recover" and (
            re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", selection.recovery_run) is None
            or re.fullmatch(r"[a-f0-9]{32}", selection.recovery_incident) is None
            or re.fullmatch(r"[1-9][0-9]{0,19}", selection.recovery_epoch) is None
            or re.fullmatch(r"[a-f0-9]{64}", selection.recovery_binding) is None
            or values.get("--recovery-action") != "retry-exact-candidate"
        ):
            refuse()
        return selection


@dataclass(frozen=True)
class CreateContext:
    state_root: str
    selection: Selection
    end_ns: int
    role: Role
    lock_fd: int = 9
    run_name: str = ""

    def __post_init__(self) -> None:
        if not isinstance(self.role, Role) or type(self.end_ns) is not int or self.end_ns <= 0 or \
                self.lock_fd != 9 or not self.state_root.startswith("/") or \
                posixpath.normpath(self.state_root) != self.state_root:
            refuse()
        if self.run_name and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", self.run_name) is None:
            refuse()

    @property
    def run(self) -> str:
        if not self.run_name:
            refuse()
        return self.state_root + "/" + self.run_name

    def check_time(self) -> None:
        if time.monotonic_ns() >= self.end_ns:
            refuse("WAIT_EXPIRED")

    def input_identities(self) -> tuple[str, ...]:
        self.check_time()
        return tuple(file_identity(self.run + "/" + name) for name in INPUT_NAMES)


@dataclass(frozen=True)
class ToolingObservation:
    cli: str
    plugin: str
    cli_identity: tuple[int | str, ...]
    plugin_identity: tuple[int | str, ...]
    cli_version: str
    compose_version: str
    system: str
    architecture: str
    config_identity: tuple[int, ...]
    config: bytes
    trusted_path: str
    socket_identity: tuple[int, ...]

    def environment(self, context: CreateContext) -> dict[str, str]:
        return {
            "PATH": self.trusted_path, "HOME": "/root",
            "DOCKER_CONFIG": context.run + "/docker-client",
            "DOCKER_HOST": "unix:///run/docker.sock",
        }


@dataclass(frozen=True)
class SpawnedCreate:
    pid: int
    pidfd: int
    start_ticks: int

    def __post_init__(self) -> None:
        if type(self.pid) is not int or self.pid <= 1 or type(self.pidfd) is not int or \
                self.pidfd < 0 or type(self.start_ticks) is not int or self.start_ticks <= 0:
            refuse()


class Transport(Protocol):
    def identity(self, stage: Stage, context: CreateContext) -> ToolingObservation: ...
    def render(self, view: View, context: CreateContext) -> bytes: ...
    def observe(self, context: CreateContext) -> bytes: ...
    def spawn_create(self, context: CreateContext, control_fds: tuple[int, ...]) -> SpawnedCreate: ...


class SupervisorClient(Protocol):
    attempt: str
    supervisor: dict[str, Any]
    role: str

    def request(self, kind: str, **fields: Any) -> dict[str, Any]: ...


def _provider() -> Any:
    # The hyphenated, checksum-bound sibling is fixed, never a selector.
    spec = importlib.util.spec_from_file_location(
        "_timepad_create_provider", SCRIPTS / "test-vps-provider-credential.py",
    )
    if spec is None or spec.loader is None:
        refuse()
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _contract() -> dict[str, Any]:
    return guard.parse_contract(read_protected(
        str(SCRIPTS / "test-vps-timepad-release-contracts.json"), guard.MAX_CONTRACT_BYTES, private=False,
    ))


def validate_tooling(observed: ToolingObservation, contract: dict[str, Any]) -> str:
    tooling = contract.get("tooling")
    keys = {
        "dockerCliVersion", "composeVersion", "composeCommit", "dockerCliPath",
        "composePluginPath", "dockerCliSha256", "composePluginSha256", "platform", "provenanceRef",
    }
    if not isinstance(observed, ToolingObservation) or not isinstance(tooling, dict) or set(tooling) != keys \
            or any(not isinstance(value, str) or not 1 <= len(value) <= 512 for value in tooling.values()):
        refuse("TOOLING_OR_MODEL_UNAVAILABLE")
    if (tooling["dockerCliVersion"], tooling["composeVersion"], tooling["composeCommit"]) != (
        "28.3.3", "2.39.4", "a32dc3da722e6b2e4fbfc72e40b1a697c4686460",
    ) or observed.system != "Linux" or \
            tooling["platform"] != "linux/" + {"x86_64": "amd64", "aarch64": "arm64"}.get(observed.architecture, "") \
            or observed.cli != tooling["dockerCliPath"] or observed.plugin != tooling["composePluginPath"] \
            or os.path.basename(observed.cli) != "docker" or os.path.basename(observed.plugin) != "docker-compose" \
            or re.fullmatch(r"Docker version 28\.3\.3, build [A-Za-z0-9._-]+", observed.cli_version) is None \
            or observed.compose_version not in {"2.39.4", "v2.39.4"}:
        refuse("TOOLING_OR_MODEL_UNAVAILABLE")
    for identity, key in (
        (observed.cli_identity, "dockerCliSha256"), (observed.plugin_identity, "composePluginSha256"),
    ):
        if len(identity) != 10 or re.fullmatch(r"[a-f0-9]{64}", tooling[key]) is None or \
                identity[-1] != tooling[key] or any(type(part) is not int for part in identity[:-1]) or \
                not stat.S_ISREG(identity[2]) or not identity[2] & 0o111 or identity[2] & 0o022 or \
                identity[3] != 0 or identity[5] != 1 or not 0 < identity[6] <= 256 * 1024 * 1024:
            refuse("TOOLING_OR_MODEL_UNAVAILABLE")
    expected_config = canonical({"cliPluginsExtraDirs": [os.path.dirname(observed.plugin)]}, 4096)
    if observed.config != expected_config or len(observed.config_identity) != 9 or \
            len(observed.socket_identity) != 9:
        refuse("TOOLING_OR_MODEL_UNAVAILABLE")
    if any(type(part) is not int for part in (*observed.config_identity, *observed.socket_identity)) or \
            not stat.S_ISREG(observed.config_identity[2]) or stat.S_IMODE(observed.config_identity[2]) != 0o600 or \
            observed.config_identity[3] != 0 or observed.config_identity[5] != 1 or \
            observed.config_identity[6] != len(expected_config) or \
            not stat.S_ISSOCK(observed.socket_identity[2]) or observed.socket_identity[3] != 0 or \
            observed.socket_identity[2] & 0o002 or \
            observed.trusted_path != ":".join(dict.fromkeys((os.path.dirname(observed.cli), "/usr/bin", "/bin"))):
        refuse("TOOLING_OR_MODEL_UNAVAILABLE")
    return hashlib.sha256(canonical([
        tooling, [observed.cli_identity, observed.plugin_identity],
        [observed.config_identity[index] for index in (0, 1, 7, 8)], observed.config.decode(),
        observed.socket_identity,
    ], 16384)).hexdigest()


def _process_start(pid: int) -> int:
    with open(f"/proc/{pid}/stat", "rb", buffering=0) as stream:
        raw = stream.read(4097)
    if len(raw) > 4096 or b")" not in raw:
        refuse("OWNERSHIP_UNCERTAIN")
    fields = raw.rsplit(b")", 1)[1].split()
    if len(fields) < 20 or int(fields[1]) != os.getpid():
        refuse("OWNERSHIP_UNCERTAIN")
    return int(fields[19])


class RealTransport:
    """The production boundary: exact pinned binaries, clean env, bounded I/O."""

    def _executable(self, path: str, context: CreateContext) -> tuple[int | str, ...]:
        before = protected(path)
        if not before.st_mode & 0o111 or before.st_size > 256 * 1024 * 1024:
            refuse()
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            if stable(os.fstat(fd)) != stable(before):
                refuse()
            digest = hashlib.sha256()
            while True:
                context.check_time()
                chunk = os.read(fd, 1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
            if stable(os.fstat(fd)) != stable(before) or stable(os.lstat(path)) != stable(before):
                refuse()
            return (*stable(before), digest.hexdigest())
        finally:
            os.close(fd)

    def _run(
        self, command: list[str], environment: dict[str, str], context: CreateContext,
        limit: int, *, seconds: int = 30,
    ) -> bytes:
        context.check_time()
        end = min(context.end_ns, time.monotonic_ns() + seconds * NS)
        process = subprocess.Popen(
            command, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True,
        )
        assert process.stdout is not None
        data = bytearray()
        try:
            os.set_blocking(process.stdout.fileno(), False)
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while time.monotonic_ns() < end:
                    if not selector.select(min(0.05, max(0, (end - time.monotonic_ns()) / NS))):
                        continue
                    chunk = os.read(process.stdout.fileno(), min(65536, limit + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > limit:
                        refuse()
                else:
                    refuse("WAIT_EXPIRED")
            if process.wait(timeout=max(0.001, (end - time.monotonic_ns()) / NS)) != 0 or \
                    time.monotonic_ns() >= end:
                refuse()
            # Each observation runs in a subreaper with no other local work.
            # A CLI grandchild must not outlive evidence collection and race
            # the subsequent mutation boundary.
            try:
                os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                pass
            else:
                refuse("OWNERSHIP_UNCERTAIN")
            return bytes(data)
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=0.5)

    def identity(self, stage: Stage, context: CreateContext) -> ToolingObservation:
        if not isinstance(stage, Stage):
            refuse()
        tooling = _contract().get("tooling")
        if tooling is None:
            refuse("TOOLING_OR_MODEL_UNAVAILABLE")
        cli, plugin = tooling["dockerCliPath"], tooling["composePluginPath"]
        identities = (self._executable(cli, context), self._executable(plugin, context))
        protected(context.run, private=True, directory=True)
        config_dir = context.run + "/docker-client"
        config = canonical({"cliPluginsExtraDirs": [os.path.dirname(plugin)]}, 4096)
        if stage == Stage.PREPARE and not os.path.lexists(config_dir):
            os.mkdir(config_dir, 0o700)
            fd = os.open(config_dir + "/config.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                context.check_time()
                if os.write(fd, config) != len(config):
                    refuse()
                os.fsync(fd)
            finally:
                os.close(fd)
            for path in (config_dir, context.run):
                fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    context.check_time()
                    os.fsync(fd)
                finally:
                    os.close(fd)
        protected(config_dir, private=True, directory=True)
        if set(os.listdir(config_dir)) != {"config.json"} or \
                read_protected(config_dir + "/config.json", 4096) != config:
            refuse()
        config_info = protected(config_dir + "/config.json", private=True)
        trusted_dirs = tuple(dict.fromkeys((os.path.dirname(cli), "/usr/bin", "/bin")))
        for path in trusted_dirs:
            protected(os.path.realpath(path), directory=True)
        protected("/run", directory=True)
        socket_info = os.lstat("/run/docker.sock")
        if not stat.S_ISSOCK(socket_info.st_mode) or socket_info.st_uid != 0 or socket_info.st_mode & 0o002:
            refuse("TOOLING_OR_MODEL_UNAVAILABLE")
        environment = {
            "PATH": ":".join(trusted_dirs), "HOME": "/root",
            "DOCKER_CONFIG": config_dir, "DOCKER_HOST": "unix:///run/docker.sock",
        }
        cli_version = self._run([cli, "--version"], environment, context, 4096, seconds=5).decode("ascii").strip()
        compose_version = self._run([plugin, "version", "--short"], environment, context, 4096, seconds=5).decode("ascii").strip()
        if identities != (self._executable(cli, context), self._executable(plugin, context)) or \
                stable(protected(config_dir + "/config.json", private=True)) != stable(config_info) or \
                stable(os.lstat("/run/docker.sock")) != stable(socket_info):
            refuse()
        return ToolingObservation(
            cli, plugin, *identities, cli_version, compose_version, platform.system(),
            platform.machine(), stable(config_info), config, environment["PATH"], stable(socket_info),
        )

    def _compose(self, context: CreateContext, identity: ToolingObservation) -> list[str]:
        return [
            identity.cli, "compose", "-p", "meet-production",
            "--project-directory", context.selection.deployment_root,
            "--env-file", context.run + "/config.env.target",
            "-f", context.run + "/config.base-compose.yml",
            "-f", context.run + "/target-runtime.override.yml",
        ]

    def render(self, view: View, context: CreateContext) -> bytes:
        if not isinstance(view, View):
            refuse()
        identity = self.identity(Stage.RENDER, context)
        validate_tooling(identity, _contract())
        before = context.input_identities()
        environment = identity.environment(context)
        if view == View.FROZEN_TARGET:
            base = self._compose(context, identity)[:-2]
            raw = parse(self._run([
                *base, "config", "--no-interpolate", "--no-env-resolution", "--format", "json",
            ], environment, context, MAX_MODEL), MAX_MODEL)
            services = raw["services"]
            if services["backend"].get("env_file") != [
                {"path": context.selection.deployment_root + "/.env.production", "required": True},
            ] or any("env_file" in service for name, service in services.items() if name != "backend"):
                refuse()
            command = [*self._compose(context, identity), "config", "--format", "json"]
        else:
            wrapper = str(SCRIPTS / "production-compose.sh")
            info = protected(wrapper)
            if not info.st_mode & 0o111:
                refuse()
            environment["PRODUCTION_ROOT"] = context.selection.deployment_root
            command = [wrapper, "config", "--format", "json"]
        result = canonical(parse(self._run(command, environment, context, MAX_MODEL), MAX_MODEL), MAX_MODEL)
        if context.input_identities() != before:
            refuse()
        return result

    def observe(self, context: CreateContext) -> bytes:
        identity = self.identity(Stage.RENDER, context)
        validate_tooling(identity, _contract())
        used = 0
        end = min(context.end_ns, time.monotonic_ns() + 29 * NS)
        bounded = replace(context, end_ns=end)

        def run(arguments: list[str]) -> bytes:
            nonlocal used
            value = self._run([identity.cli, *arguments], identity.environment(context), bounded, MAX_EVIDENCE - used)
            used += len(value)
            if used > MAX_EVIDENCE:
                refuse()
            return value

        def identities(arguments: list[str], *, names: bool = False) -> list[str]:
            values = run(arguments).decode("ascii").splitlines()
            pattern = r"[a-zA-Z0-9][a-zA-Z0-9_.-]*" if names else r"[a-f0-9]{64}"
            if len(values) > MAX_ITEMS or len(set(values)) != len(values) or \
                    any(re.fullmatch(pattern, value) is None for value in values):
                refuse()
            return values

        def inspect(kind: str, values: list[str]) -> list[dict[str, Any]]:
            if not values:
                return []
            result = parse(run([kind, "inspect", *values]), MAX_EVIDENCE)
            key = "Name" if kind == "volume" else "Id"
            if not isinstance(result, list) or len(result) > MAX_ITEMS or \
                    any(not isinstance(item, dict) for item in result) or \
                    sorted(item.get(key, "") for item in result) != sorted(values):
                refuse()
            return result

        project = identities(["ps", "--all", "--quiet", "--no-trunc", "--filter", "label=com.docker.compose.project=meet-production"])
        daemon_ids = identities(["ps", "--all", "--quiet", "--no-trunc"])
        daemon_details = inspect("container", daemon_ids)
        daemon = [{"Id": item["Id"], "Names": item["Name"].removeprefix("/"),
                   "Labels": item["Config"].get("Labels") or {}} for item in daemon_details]
        consumer_ids = identities(["ps", "--all", "--quiet", "--no-trunc"])
        if sorted(consumer_ids) != sorted(daemon_ids):
            refuse()
        containers = inspect("container", consumer_ids)
        compose = [*self._compose(context, identity)[1:], "ps", "--all", "--quiet"]
        compose_ids, backend_ids = identities(compose), identities([*compose, "backend"])
        network_ids = identities(["network", "ls", "--quiet", "--no-trunc"])
        networks = inspect("network", network_ids)
        relevant_networks = [item["Id"] for item in networks if item["Name"] == "meet-production_default"]
        if len(relevant_networks) != 1:
            refuse()
        network_inspections = inspect("network", relevant_networks)
        volume_names = identities(["volume", "ls", "--quiet"], names=True)
        volumes = inspect("volume", volume_names)
        required_volumes = ["meet-production_uploads_data", "meet-production_postgres_data"]
        if not set(required_volumes) <= set(volume_names):
            refuse()
        volume_inspections = inspect("volume", required_volumes)
        postgres = [item for item in containers if item["Id"] in project and
                    item["Config"].get("Labels", {}).get("com.docker.compose.service") == "postgres"]
        if len(postgres) != 1 or re.fullmatch(r"sha256:[a-f0-9]{64}", postgres[0]["Image"]) is None:
            refuse()
        postgres_image = parse(run(["image", "inspect", postgres[0]["Image"]]), MAX_EVIDENCE)
        target_image = parse(run(["image", "inspect", context.selection.image]), MAX_EVIDENCE)
        if not isinstance(postgres_image, list) or len(postgres_image) != 1 or \
                not isinstance(target_image, list) or len(target_image) != 1:
            refuse()
        return canonical({
            "resources": {
                "postgresImageInspection": postgres_image[0],
                "projectInventory": project, "daemonInventory": daemon,
                "composeInventory": compose_ids, "backendInventory": backend_ids,
                "containerInspections": containers,
                "networkInventory": [{"ID": item["Id"], "Name": item["Name"],
                                      "Labels": item.get("Labels") or {}} for item in networks],
                "networkInspections": network_inspections,
                "volumeInventory": [{"Name": item["Name"], "Driver": item["Driver"],
                                     "Labels": item.get("Labels") or {}} for item in volumes],
                "volumeInspections": volume_inspections,
            },
            "imageInspection": target_image,
        }, MAX_EVIDENCE)

    def spawn_create(self, context: CreateContext, control_fds: tuple[int, ...]) -> SpawnedCreate:
        if control_fds != (9,):
            refuse()
        identity = self.identity(Stage.LAUNCH, context)
        validate_tooling(identity, _contract())
        command = [
            *self._compose(context, identity), "up", "--no-start", "--no-deps", "--no-build",
            "--pull", "never", "--force-recreate", "backend",
        ]
        pid = os.fork()
        if pid == 0:
            try:
                null = os.open("/dev/null", os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(null, fd)
                for name in os.listdir("/proc/self/fd"):
                    fd = int(name)
                    if fd > 2 and fd not in control_fds:
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                os.execve(identity.cli, command, identity.environment(context))
            except BaseException:
                os._exit(1)
        start = _process_start(pid)
        pidfd = os.pidfd_open(pid, 0)
        try:
            if _process_start(pid) != start:
                refuse("OWNERSHIP_UNCERTAIN")
            return SpawnedCreate(pid, pidfd, start)
        except BaseException:
            os.close(pidfd)
            raise


def wait_create(child: SpawnedCreate, context: CreateContext) -> None:
    """Only the launcher derives exact wait/ECHILD evidence; never the transport."""
    status = None
    try:
        while True:
            context.check_time()
            try:
                pid, raw = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                if status != 0:
                    refuse("OWNERSHIP_UNCERTAIN")
                return
            if pid:
                if pid != child.pid or status is not None:
                    refuse("OWNERSHIP_UNCERTAIN")
                status = os.waitstatus_to_exitcode(raw)
                if status != 0:
                    refuse("OWNERSHIP_UNCERTAIN")
            else:
                time.sleep(0.01)
    finally:
        os.close(child.pidfd)


@dataclass(frozen=True)
class DriverResult:
    action: Action
    model_digest: str
    tooling_digest: str
    container_id: str | None = None
    config_hash: str | None = None
    prepared_digest: str | None = None

    def frame(self) -> dict[str, Any]:
        value = {"action": self.action.value, "modelDigest": self.model_digest, "toolingDigest": self.tooling_digest}
        for name, item in (
            ("containerId", self.container_id), ("configHash", self.config_hash),
            ("preparedProofDigest", self.prepared_digest),
        ):
            if item is not None:
                value[name] = item
        if any(re.fullmatch(r"[a-f0-9]{64}", item) is None for key, item in value.items() if key != "action"):
            refuse()
        canonical(value, 4096)
        return value


class CreateDriver:
    def __init__(self, context: CreateContext, transport: Transport, supervisor_client: SupervisorClient):
        self.context, self.transport, self.client = context, transport, supervisor_client
        self.provider = _provider()

    def _lease(self, *, registered: bool = False) -> dict[str, Any]:
        self.context.check_time()
        live = guard._execution_lease(self.client.request("lease"))
        lease = guard._read_execution_lease_locked(self.context.state_root)
        if live != lease or live["attempt"] != self.client.attempt or \
                live["supervisor"] != self.client.supervisor or live["workerMode"] != "controller-worker" or \
                live["firstFailure"] is not None or live["lifecycle"] not in (
                    {"registered", "armed"} if registered else {"armed"}
                ) or live["workEndNs"] is not None and self.context.end_ns > live["workEndNs"]:
            refuse()
        return live

    def _state(self, *, pending: bool = False, registered: bool = False) -> tuple[dict[str, Any], dict[str, Any]]:
        self._lease(registered=pending or registered)
        origin, current = guard._read_guard_locked(self.context.state_root)
        selection = self.context.selection
        if pending:
            run = selection.run_key + ("-rollback-drill" if selection.mode == "rollback-drill" else "-final-deploy")
            self.context = replace(self.context, run_name=run)
            return origin, current
        target = current["target"]["tuple"]
        if selection.image != "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + target["repositoryDigest"] or \
                selection.revision != target["revision"] or selection.version != target["version"] or \
                current["executionAttempt"] != self.client.attempt:
            refuse()
        if selection.operation == "deploy":
            if current["runId"] != selection.run_key or current["operation"] != selection.mode:
                refuse()
        else:
            self._recovery_authority(origin, current)
        if current["ownedRun"] != current["runId"] + (
            "-rollback-drill" if current["operation"] == "rollback-drill" else "-final-deploy"
        ):
            refuse()
        self.context = replace(self.context, run_name=current["ownedRun"])
        return origin, current

    def _recovery_authority(self, origin: dict[str, Any], current: dict[str, Any]) -> None:
        selection = self.context.selection
        root_fd = guard._open_root(self.context.state_root)
        try:
            authorization = guard._read_at(root_fd, "timepad-recovery-authorization.json", guard.MAX_AUTHORIZATION_BYTES)
        finally:
            os.close(root_fd)
        guard._recovery_registration_authority(origin, current, _contract(), authorization, {
            "runId": selection.recovery_run, "incidentId": selection.recovery_incident,
            "operationEpoch": int(selection.recovery_epoch), "evidenceDigest": selection.recovery_binding,
            "repositoryDigest": selection.image.rsplit("sha256:", 1)[1],
            "revision": selection.revision, "version": selection.version,
        })

    @contextmanager
    def _run_fd(self) -> Iterator[int]:
        root_fd = self.provider._open_deploy_state_root(self.context.state_root)
        try:
            fd = os.open(self.context.run_name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            try:
                self.provider._validate_state_directory_fd(fd, self.context.run_name)
                yield fd
            finally:
                os.close(fd)
        finally:
            os.close(root_fd)

    @contextmanager
    def _grant(self, name: str, seconds: int = 30) -> Iterator[guard.ExecutionGrant]:
        diagnostic = os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1"
        stage = "deadline"
        try:
            self.context.check_time()
            stage = "request"
            frame = self.client.request(
                "grant", name=name, localNs=seconds * NS,
                parentEndNs=self.context.end_ns,
            )
            stage = "schema"
            if set(frame) != {"attempt", "grantId", "endNs", "role", "name"}:
                if diagnostic:
                    print("fixture_timepad_create=grant_refusal stage=schema", file=sys.stderr, flush=True)
                refuse()
            stage = "correlation"
            if frame["attempt"] != self.client.attempt or frame["name"] != name or \
                    frame["role"] != self.client.role:
                if diagnostic:
                    print("fixture_timepad_create=grant_refusal stage=correlation", file=sys.stderr, flush=True)
                refuse()
            stage = "deadline"
            if frame["endNs"] > self.context.end_ns:
                if diagnostic:
                    print("fixture_timepad_create=grant_refusal stage=deadline", file=sys.stderr, flush=True)
                refuse()
            stage = "grant-record"
            grant = guard.ExecutionGrant(frame["attempt"], frame["grantId"], frame["endNs"])
            stage = "body"
            yield grant
            stage = "complete"
            self.client.request("complete", grantId=grant.grant_id)
        except BaseException as error:
            if diagnostic:
                error_name = type(error).__name__
                if not error_name.isascii() or not error_name.isidentifier() or len(error_name) > 64:
                    error_name = "Exception"
                safe_reason = (
                    str(error) if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", str(error))
                    else "OTHER"
                )
                print(
                    "fixture_timepad_create=grant_failure stage=" + stage +
                    " exception=" + error_name + " reason=" + safe_reason,
                    file=sys.stderr, flush=True,
                )
            raise

    def _provider_call(self, command: str, value: dict[str, Any]) -> dict[str, Any]:
        if command not in {"prepare-transition-proof", "resource-admission", "runtime-request-proof", "absence-resume"}:
            refuse()
        data = canonical(value, guard.MAX_RECOVERY_RUNTIME_BYTES)
        live = self.client.request("lease")
        name = "recovery-admission" if live["operation"] == "forward-recover" and live["lifecycle"] == "registered" else "provider"
        with self._grant(name) as grant:
            args = argparse.Namespace(
                command=command, state_root=self.context.state_root, deploy_lock_fd=9,
                execution_attempt=grant.attempt, execution_grant=grant.grant_id, deadline_ns=grant.end_ns,
            )
            stream = io.StringIO()
            try:
                with self.provider._operation_deadline(grant.end_ns):
                    lease = self.provider._execution_interlock(args, 9)
                    with self.provider._execution_mutation(args, lease), redirect_stdout(stream):
                        run_key, state_kind = state_run_identity(self.context.run_name)
                        if command == "prepare-transition-proof":
                            self.provider._prepare_transition_proof(run_key, self.context.state_root, state_kind, data, 9)
                        elif command == "resource-admission":
                            self.provider._resource_admission_command(run_key, self.context.state_root, state_kind, data, 9)
                        elif command == "absence-resume":
                            self.provider._absence_resume(run_key, self.context.state_root, state_kind, data, 9)
                        else:
                            self.provider._runtime_request_completion(run_key, self.context.state_root, state_kind, data, 9)
            except BaseException as error:
                if os.environ.get("TIMEPAD_FIXTURE_DIAGNOSTICS") == "1":
                    safe_symbols = {
                        "_execution_interlock", "_execution_mutation",
                        "_prepare_transition_proof", "_resource_admission_command",
                        "_absence_resume", "_runtime_request_completion",
                        "state_run_identity", "_operation_deadline",
                    }
                    symbols = [
                        frame.name if frame.name in safe_symbols else "other"
                        for frame in traceback.extract_tb(error.__traceback__)[-6:]
                    ]
                    safe_name = type(error).__name__
                    if not safe_name.isascii() or not safe_name.isidentifier() or len(safe_name) > 64:
                        safe_name = "Exception"
                    safe_reason = (
                        str(error) if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", str(error))
                        else "OTHER"
                    )
                    print(
                        "fixture_timepad_create=provider_failure exception=" +
                        safe_name + " reason=" + safe_reason +
                        " symbols=" + ",".join(symbols),
                        file=sys.stderr, flush=True,
                    )
                raise
            return parse(stream.getvalue().encode(), 32768)

    def _models(self, *, installed: bool, stage: Stage) -> tuple[dict[str, Any], str]:
        first = self.transport.identity(stage, self.context)
        identity = validate_tooling(first, _contract())
        before = self.context.input_identities()
        model = parse(self.transport.render(View.FROZEN_TARGET, self.context), MAX_MODEL)
        canonical(model, MAX_MODEL)
        if installed:
            installed_model = parse(self.transport.render(View.INSTALLED_WRAPPER, self.context), MAX_MODEL)
            if canonical(installed_model, MAX_MODEL) != canonical(model, MAX_MODEL):
                refuse("TOOLING_OR_MODEL_UNAVAILABLE")
            root = self.context.selection.deployment_root
            for path, snapshot, identity_file in (
                (root + "/.env.production", "config.env.target", "config.env.target.identity"),
                (self.context.selection.base_compose, "config.base-compose.yml", "config.base-compose.yml.identity"),
            ):
                if read_protected(path, 1024 * 1024, private=False) != read_protected(self.context.run + "/" + snapshot, 1024 * 1024) \
                        or file_identity(path, private=False) != read_protected(self.context.run + "/" + identity_file, 4096).decode().strip():
                    refuse()
            for active, snapshot in ((ACTIVE_COMPOSE, "config.base-compose.yml"), (ACTIVE_RUNTIME, "target-runtime.override.yml")):
                if read_protected(active, 1024 * 1024, private=False) != read_protected(self.context.run + "/" + snapshot, 1024 * 1024):
                    refuse()
        if before != self.context.input_identities() or \
                validate_tooling(self.transport.identity(stage, self.context), _contract()) != identity:
            refuse("TOOLING_OR_MODEL_UNAVAILABLE")
        return model, identity

    def _observations(self, model: dict[str, Any]) -> tuple[dict[str, Any], Any]:
        value = parse(self.transport.observe(self.context), MAX_EVIDENCE)
        if not isinstance(value, dict) or set(value) != {"resources", "imageInspection"} or \
                not isinstance(value["resources"], dict):
            refuse()
        resources = dict(value["resources"], targetConfiguration=model)
        canonical(resources, MAX_EVIDENCE)
        return resources, value["imageInspection"]

    def _frozen(self, current: dict[str, Any], model: dict[str, Any], image: Any) -> dict[str, Any]:
        contract = _contract()
        origin = guard._read_guard_locked(self.context.state_root)[0]
        admission = guard.admit(
            contract, root_id=origin["rootId"], target_id=current["target"]["id"],
            predecessor_id=current["predecessor"]["id"], transition_id=current["transitionId"],
            target_tuple=current["target"]["tuple"], predecessor_tuple=current["predecessor"]["tuple"],
        )
        if admission.disposition not in {"pre-barrier-only", "post-barrier-compatible"} or \
                admission.disposition != current["predecessorDisposition"] or \
                admission.contract_digest != current["evidenceDigest"] or current["toolingDigest"] != tooling_digest():
            refuse()
        with self._run_fd() as fd:
            proof, _ = self.provider._prepared_target(fd, current, image, model)
            self.provider._prepared_environment(fd, current)
        return proof

    def _resource(self, stage: str, current: dict[str, Any], proof: dict[str, Any],
                  observed: dict[str, Any], expected: str | None = None) -> dict[str, Any]:
        with self._run_fd() as fd:
            baseline = self.provider._read_resource_baseline(fd, proof["resourcesDigest"])
            request = current.get("runtimeRequest")
            membership = (
                self.provider._read_resource_request(fd, request["resourceRequestDigest"])
                if stage in {"post-create", "completion", "recovery"} and request is not None and request["operation"] == "create"
                else None
            )
            if stage == "recovery" and request is not None and request["operation"] in {"suppress", "stop"}:
                membership = self.provider._retained_create_completion(
                    fd, current, proof, guard, self.context.state_root,
                )
        role = (
            self.provider._resource_recovery_role(current, proof, request_baseline=membership)
            if stage == "recovery" and current["phase"] != "PREPARED"
            else self.provider._resource_role(current, proof)
        )
        return self._provider_call("resource-admission", self.provider._resource_envelope(
            stage=stage, role=role, observed=observed, baseline=baseline,
            request_baseline=membership, expected_membership_digest=expected,
        ))

    def _pending(self) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], Any, dict[str, Any]]:
        origin, previous = self._state(pending=True)
        if self.context.selection.operation != "deploy" or previous["phase"] not in {"READY", "COMMITTED", "ROLLED_BACK"}:
            refuse()
        evidence = parse(read_protected(self.context.run + "/.timepad-prepare.json", 32768), 32768)
        if set(evidence) != {
            "rootId", "targetId", "predecessorId", "predecessorContainerId", "transitionId",
            "target", "predecessor", "operation", "runId", "incidentId", "ownedRun", "toolingDigest",
        } or evidence["rootId"] != origin["rootId"] or evidence["runId"] != self.context.selection.run_key or \
                evidence["ownedRun"] != self.context.run_name or evidence["operation"] != self.context.selection.mode or \
                evidence["toolingDigest"] != tooling_digest():
            refuse()
        contract = _contract()
        admission = guard.admit(
            contract, root_id=origin["rootId"], target_id=evidence["targetId"],
            predecessor_id=evidence["predecessorId"], transition_id=evidence["transitionId"],
            target_tuple=evidence["target"], predecessor_tuple=evidence["predecessor"],
        )
        if admission.disposition not in {"pre-barrier-only", "post-barrier-compatible"} or \
                evidence["operation"] == "rollback-drill" and admission.disposition != "post-barrier-compatible":
            refuse()
        bindings = {item["id"]: item for item in contract["images"]}
        current = dict(
            evidence, target=bindings[evidence["targetId"]], predecessor=bindings[evidence["predecessorId"]],
            originDigest=origin["originDigest"], operationEpoch=previous["operationEpoch"] + 1,
            phase="PREPARED", containerId=None, configHash=None, ownedChild=None,
            providerFinalizationDigest=None, evidenceDigest=admission.contract_digest,
            predecessorDisposition=admission.disposition,
        )
        target = current["target"]["tuple"]
        selection = self.context.selection
        if selection.image.rsplit("sha256:", 1)[1] != target["repositoryDigest"] or \
                selection.revision != target["revision"] or selection.version != target["version"]:
            refuse()
        model, _ = self._models(installed=False, stage=Stage.PREPARE)
        token = model["services"]["backend"]["labels"]["org.meet.timepad.operation"]
        if not isinstance(token, str) or re.fullmatch(r"[a-f0-9]{32}", token) is None:
            refuse()
        self.provider._create_backend_model(model, token)
        observed, image = self._observations(model)
        inspection = [
            item for item in observed["containerInspections"]
            if item["Id"] == evidence["predecessorContainerId"]
        ]
        if len(inspection) != 1:
            refuse()
        effective = self.provider._absence_target_tuple(self.provider._inspect(canonical(image, MAX_EVIDENCE)), model, current)
        if effective != self.provider._effective_tuple(inspection[0]):
            refuse("PROVIDER_STATE_INVALID")
        return evidence, current, model, image, observed

    def _publish_prepared(self) -> DriverResult:
        evidence, current, model, image, observed = self._pending()
        token = model["services"]["backend"]["labels"]["org.meet.timepad.operation"]
        inspection = [item for item in observed["containerInspections"] if item["Id"] == current["predecessorContainerId"]]
        output = self._provider_call("prepare-transition-proof", {
            "schema": self.provider.PREPARED_INPUT_SCHEMA, "evidence": evidence,
            "predecessorInspection": inspection, "imageInspection": image,
            "targetConfiguration": model, "operationToken": token,
            "toolingDigest": evidence["toolingDigest"], "resourceEvidence": observed,
        })
        contract = _contract()
        with self._grant("state-publish", 10) as grant, guard._execution_mutation(self.context.state_root, 9, grant):
            origin, previous = guard._read_guard_locked(self.context.state_root)
            admission = guard.admit(
                contract, root_id=origin["rootId"], target_id=evidence["targetId"],
                predecessor_id=evidence["predecessorId"], transition_id=evidence["transitionId"],
                target_tuple=evidence["target"], predecessor_tuple=evidence["predecessor"],
            )
            prepared = guard.new_prepared_state(
                previous, operation=evidence["operation"], run_id=evidence["runId"], incident_id=evidence["incidentId"],
                admission=admission, target=current["target"], predecessor=current["predecessor"],
                predecessor_container_id=evidence["predecessorContainerId"], transition_id=evidence["transitionId"],
                owned_run=self.context.run_name, tooling_digest=evidence["toolingDigest"],
                prepared_proof_digest=output["preparedProofDigest"], execution_attempt=self.client.attempt,
            )
            guard._publish_current_locked(self.context.state_root, prepared)
        return DriverResult(Action.PUBLISH_PREPARED, self.provider._model_digest(model),
                            evidence["toolingDigest"], prepared_digest=output["preparedProofDigest"])

    def check_stage(self, stage: str, grant: dict[str, Any], request_digest: str) -> dict[str, Any]:
        """Read-only admission used by the actual release/completion workers."""
        if stage not in {"release-admission", "execute", "completion-admission"}:
            refuse()
        self.context.check_time()
        if grant["name"] != "create-execute" or grant["role"] != "controller-worker" or \
                grant["attempt"] != self.client.attempt or grant["endNs"] < self.context.end_ns or \
                self.client.request("validate-grant", grantId=grant["grantId"], endNs=grant["endNs"]) != grant:
            refuse()
        _, current = self._state()
        model, _ = self._models(installed=True, stage=Stage.COMPLETE if stage == "completion-admission" else Stage.LAUNCH)
        observed, image = self._observations(model)
        proof = self._frozen(current, model, image)
        request = guard.runtime_request(current["runtimeRequest"])
        if request["operation"] != "create" or request["lifecycle"] != "intent" or \
                request["executionAttempt"] != self.client.attempt or \
                guard.create_request_digest(request) != request_digest or \
                current["latestAttemptId"] != request["childAttemptId"] or \
                current["ownedChild"] != dict(request["childIdentity"], lifecycle="waiting") or \
                any(request[key] != proof[key] for key in ("operationToken", "modelDigest", "toolingDigest", "resourcesDigest")):
            refuse()
        if request["role"] == "initial":
            if current["phase"] != "CUTOVER_POSSIBLE" or current["commitSubstep"] is not None:
                refuse()
        elif current["phase"] != "FORWARD_RECOVERING" or current["commitSubstep"] != "replacement-create-intent":
            refuse()
        with self._run_fd() as fd:
            baseline = self.provider._read_resource_baseline(fd, request["resourcesDigest"])
            membership = self.provider._read_resource_request(fd, request["resourceRequestDigest"])
        completing = stage == "completion-admission"
        self.provider._resource_admission(self.provider._resource_envelope(
            stage="completion" if completing else "pre-release",
            role=self.provider._resource_role(current, proof), observed=observed, baseline=baseline,
            request_baseline=membership if completing else None,
            expected_membership_digest=None if completing else request["resourceRequestDigest"],
        ))
        if guard._read_guard_locked(self.context.state_root)[1] != current or \
                self.client.request("validate-grant", grantId=grant["grantId"], endNs=grant["endNs"]) != grant:
            refuse()
        self.context.check_time()
        return {"request": request}

    def _advance(self, current: dict[str, Any], **changes: Any) -> dict[str, Any]:
        with self._grant("state-publish", 10) as grant, guard._execution_mutation(self.context.state_root, 9, grant):
            if guard._read_guard_locked(self.context.state_root)[1] != current:
                refuse()
            updated = guard.advance_state(current, current["phase"], **changes)
            guard._publish_current_locked(self.context.state_root, updated)
            return updated

    def _membership(self, current: dict[str, Any], proof: dict[str, Any], admission: dict[str, Any]) -> None:
        data = canonical(admission["membership"], 4096)
        if hashlib.sha256(data).hexdigest() != admission["membershipDigest"] or \
                admission["baselineDigest"] != proof["resourcesDigest"] or current["ownedChild"] is not None:
            refuse()
        if current["runtimeRequest"] is not None:
            guard.require_runtime_request_completion(current)
        with self._grant("state-publish", 10) as grant, guard._execution_mutation(self.context.state_root, 9, grant), self._run_fd() as fd:
            if guard._read_guard_locked(self.context.state_root)[1] != current or self.provider._prepared_proof(fd, current) != proof:
                refuse()
            try:
                guard._read_at(fd, "timepad-resource-request.json", 4096)
            except FileNotFoundError:
                replacing = False
            else:
                replacing = True
            guard._atomic_write(fd, "timepad-resource-request.json", data, 4096, replace=replacing)
            if guard._read_at(fd, "timepad-resource-request.json", 4096) != data:
                refuse()

    def _create(self) -> DriverResult:
        _, current = self._state()
        role = self.context.role.value
        if (current["phase"], role) not in {("CUTOVER_POSSIBLE", "initial"), ("FORWARD_RECOVERING", "replacement")}:
            refuse()
        model, _ = self._models(installed=True, stage=Stage.LAUNCH)
        observed, image = self._observations(model)
        proof = self._frozen(current, model, image)
        admission = self._resource("pre-release", current, proof, observed)
        self._membership(current, proof, admission)
        sequence = 1 if current["latestAttemptId"] is None else int(current["latestAttemptId"].split(":")[1]) + 1
        if sequence > guard.MAX_U64:
            refuse()
        attempt = current["incidentId"] + ":" + str(sequence)
        launch = self.client.request("create-launch", createRole=role, attemptId=attempt)
        identity = launch["childIdentity"]
        child = guard._owned_child(dict(identity, lifecycle="waiting"))
        request = guard.runtime_request({
            "nonce": os.urandom(16).hex(), "sequence": (current["runtimeRequest"] or {}).get("sequence", 0) + 1,
            "executionAttempt": self.client.attempt, "operation": "create", "containerId": None,
            "imageId": current["target"]["tuple"]["platformImageId"], "configHash": None,
            "childAttemptId": attempt, "lifecycle": "intent", "responseId": None, "completionDigest": None,
            **{key: current[key] for key in ("originDigest", "operationEpoch", "incidentId", "preparedProofDigest", "toolingDigest")},
            "operationToken": proof["operationToken"], "modelDigest": proof["modelDigest"],
            "resourcesDigest": proof["resourcesDigest"], "resourceRequestDigest": admission["membershipDigest"],
            "role": role, "priorContainerId": current["containerId"] if role == "replacement" else None,
            "childIdentity": identity,
        })
        current = self._advance(current, runtimeRequest=request, ownedChild=child, latestAttemptId=attempt)
        digest = guard.create_request_digest(request)
        # The outer release helper independently repeats the same comparison.
        # The driver holds no shell-side cached authorization.
        self.client.request("create-release", requestDigest=digest, childIdentity=identity)
        while True:
            self.context.check_time()
            result = self.client.request("create-result", requestDigest=digest)
            if result == {"status": "ready"}:
                break
            if result != {"status": "pending"}:
                refuse()
            time.sleep(0.05)
        receipt = self.client.request("create-completion", requestDigest=digest, childIdentity=identity)
        _, completed = self._state()
        normal = guard.require_create_normal_completion(completed)
        if completed["ownedChild"] is not None or normal["sequence"] != request["sequence"] or \
                normal["childIdentity"] != identity or normal["completionDigest"] != receipt.get("receiptDigest"):
            refuse()
        return self._reconcile()

    def _reconcile(self) -> DriverResult:
        _, current = self._state()
        request = guard.require_create_normal_completion(current)
        model, _ = self._models(installed=True, stage=Stage.COMPLETE)
        observed, image = self._observations(model)
        proof = self._frozen(current, model, image)
        admission = self._resource("post-create", current, proof, observed)
        identity = admission["membership"]["backendContainerId"]
        inspection = [item for item in observed["containerInspections"] if item["Id"] == identity]
        if len(inspection) != 1:
            refuse()
        with self._run_fd() as fd:
            membership = self.provider._read_resource_request(fd, request["resourceRequestDigest"])
        binding = self._provider_call("runtime-request-proof", {
            "requestNonce": request["nonce"], "inspection": inspection, "imageInspection": image,
            "targetConfiguration": model, "backendInventory": observed["backendInventory"],
            "composeInventory": observed["composeInventory"], "resourceEvidence": observed,
            "requestBaseline": membership,
        })
        if binding["requestNonce"] != request["nonce"] or binding["containerId"] != identity or \
                binding["completionDigest"] != request["completionDigest"] or \
                any(binding[key] != request[key] for key in ("resourcesDigest", "resourceRequestDigest")):
            refuse()
        bound = dict(request, lifecycle="bound", containerId=identity, responseId=identity, configHash=binding["configHash"])
        if bound != request:
            changes: dict[str, Any] = {"runtimeRequest": bound, "containerId": identity, "configHash": binding["configHash"]}
            if request["role"] == "replacement":
                changes["commitSubstep"] = "replacement-container-authorized"
            self._advance(current, **changes)
        return DriverResult(Action.RECONCILE_BOUND, proof["modelDigest"], proof["toolingDigest"], identity, binding["configHash"])

    def run(self, action: Action) -> DriverResult:
        if not isinstance(action, Action):
            refuse()
        with guard.deploy_lock(self.context.state_root, 9), self.provider._operation_deadline(self.context.end_ns):
            if action == Action.ADMIT_TARGET:
                evidence, _, model, _, _ = self._pending()
                return DriverResult(action, self.provider._model_digest(model), evidence["toolingDigest"])
            if action == Action.PUBLISH_PREPARED:
                return self._publish_prepared()
            if action == Action.CREATE:
                return replace(self._create(), action=action)
            if action == Action.RECONCILE_BOUND:
                return self._reconcile()
            _, current = self._state(registered=True)
            model, _ = self._models(installed=current["phase"] != "PREPARED", stage=Stage.RENDER)
            observed, image = self._observations(model)
            proof = self._frozen(current, model, image)
            if not observed["backendInventory"]:
                if self.context.selection.operation != "forward-recover" or self.context.role != Role.REPLACEMENT:
                    refuse()
                root_fd = guard._open_root(self.context.state_root)
                try:
                    authorization = guard.parse_json(guard._read_at(
                        root_fd, "timepad-recovery-authorization.json", guard.MAX_AUTHORIZATION_BYTES,
                    ), guard.MAX_AUTHORIZATION_BYTES)
                finally:
                    os.close(root_fd)
                self._provider_call("absence-resume", {
                    "schema": self.provider.ABSENCE_RESUME_SCHEMA, "authorization": authorization,
                    "imageInspection": image, "targetConfiguration": model, "backendInventory": [],
                })
                return DriverResult(action, proof["modelDigest"], proof["toolingDigest"])
            request = current["runtimeRequest"]
            stage = (
                "post-create" if request is not None and request["operation"] == "create" and request["lifecycle"] == "bound"
                else "pre-release" if current["containerId"] is None and current["phase"] != "PREPARED"
                else "recovery"
            )
            self._resource(stage, current, proof, observed)
            return DriverResult(action, proof["modelDigest"], proof["toolingDigest"], current["containerId"], current["configHash"])

    def recovery_evidence(self) -> tuple[dict[str, Any], bytes]:
        """Read-only collection; register-recovery remains the only adopter/writer."""
        self.context.check_time()
        with guard.deploy_lock(self.context.state_root, 9), self.provider._operation_deadline(self.context.end_ns):
            origin, current = guard._read_guard_locked(self.context.state_root)
            self._recovery_authority(origin, current)
            self.context = replace(self.context, run_name=current["ownedRun"])
            before = self.context.input_identities()
            request = current["runtimeRequest"]
            creating = request is not None and request["operation"] == "create"
            if creating:
                model, tooling = self._models(installed=current["phase"] != "PREPARED", stage=Stage.RENDER)
                observed, image = self._observations(model)
                with self._run_fd() as fd:
                    self.provider._prepared_proof(fd, current)
                    self.provider._prepared_target(fd, current, image, model)
                    self.provider._prepared_environment(fd, current)
                    membership = self.provider._read_resource_request(fd, request["resourceRequestDigest"])
                if request["lifecycle"] not in {"normal-completed", "bound"}:
                    refuse("RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED")
                identity = observed["backendInventory"][0] if len(observed["backendInventory"]) == 1 else None
            else:
                # Historical synchronous requests have live-resume proofs, not
                # create model/resource receipts. Registration still repeats
                # their request-specific proof before adopting ownership.
                if request is None or current["phase"] == "PREPARED":
                    refuse("RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED")
                tooling = validate_tooling(self.transport.identity(Stage.RENDER, self.context), _contract())
                value = parse(self.transport.observe(self.context), MAX_EVIDENCE)
                if not isinstance(value, dict) or set(value) != {"resources", "imageInspection"} or \
                        not isinstance(value["resources"], dict):
                    refuse()
                observed = value["resources"]
                identity = current["containerId"]
            inspection = [item for item in observed["containerInspections"] if item["Id"] == identity]
            if len(inspection) != 1:
                refuse()
            evidence = {
                "inspection": inspection, "backendInventory": observed["backendInventory"],
                "composeInventory": observed["composeInventory"],
            }
            if creating:
                evidence.update(
                    imageInspection=image, targetConfiguration=model,
                    resourceEvidence=observed, requestBaseline=membership,
                )
            else:
                root_fd = guard._open_root(self.context.state_root)
                try:
                    authorization = guard._read_at(
                        root_fd, "timepad-recovery-authorization.json", guard.MAX_AUTHORIZATION_BYTES,
                    )
                finally:
                    os.close(root_fd)
                self.provider._recovery_lease_runtime_proof(
                    self.context.state_root, current, authorization,
                    canonical(evidence, guard.MAX_RECOVERY_RUNTIME_BYTES), 9, self.context.check_time,
                )
            if validate_tooling(self.transport.identity(Stage.RENDER, self.context), _contract()) != tooling:
                refuse("TOOLING_OR_MODEL_UNAVAILABLE")
            if guard._read_guard_locked(self.context.state_root)[1] != current or before != self.context.input_identities():
                refuse()
            self.context.check_time()
            binding = recovery_binding(self.context, self.client.attempt)
            return binding, canonical(evidence, guard.MAX_RECOVERY_RUNTIME_BYTES)


def recovery_binding(context: CreateContext, attempt: str) -> dict[str, Any]:
    """Reconstructed independently by the pipe sender and its authenticated reader."""
    with guard.deploy_lock(context.state_root, 9):
        _, current = guard._read_guard_locked(context.state_root)
        context = replace(context, run_name=current["ownedRun"])
        before = context.input_identities()
        result = {
            "originDigest": current["originDigest"], "incidentId": current["incidentId"],
            "operationEpoch": current["operationEpoch"], "attempt": attempt,
            "requestDigest": hashlib.sha256(canonical(current["runtimeRequest"], 4096)).hexdigest(),
            "currentDigest": hashlib.sha256(guard._canonical(current)).hexdigest(),
            "contextDigest": hashlib.sha256(canonical({
                "root": context.state_root, "deploymentRoot": context.selection.deployment_root,
                "ownedRun": context.run_name, "selection": {
                    "image": context.selection.image, "revision": context.selection.revision,
                    "version": context.selection.version, "run": context.selection.recovery_run,
                    "incident": context.selection.recovery_incident, "epoch": context.selection.recovery_epoch,
                    "binding": context.selection.recovery_binding,
                },
            }, 4096)).hexdigest(),
            "inputDigest": hashlib.sha256(canonical(before, 4096)).hexdigest(),
            "preparedProofDigest": current["preparedProofDigest"], "endNs": context.end_ns,
        }
        if guard._read_guard_locked(context.state_root)[1] != current or before != context.input_identities():
            refuse()
        return result


def write_evidence(fd: int, binding: dict[str, Any], evidence: bytes, context: CreateContext) -> None:
    """A bounded one-shot pipe record, never an RPC model payload or disk snapshot."""
    header = canonical(dict(binding, size=len(evidence), digest=hashlib.sha256(evidence).hexdigest()), 4096)
    data = memoryview(len(header).to_bytes(4, "big") + header + evidence)
    os.set_blocking(fd, False)
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_WRITE)
        while data:
            context.check_time()
            if selector.select(min(0.05, max(0, (context.end_ns - time.monotonic_ns()) / NS))):
                count = os.write(fd, data[:65536])
                if count <= 0:
                    refuse()
                data = data[count:]


def read_evidence(fd: int, expected: dict[str, Any], end_ns: int) -> bytes:
    if not stat.S_ISFIFO(os.fstat(fd).st_mode):
        refuse()
    data = bytearray()
    maximum = guard.MAX_RECOVERY_RUNTIME_BYTES + 4100
    os.set_blocking(fd, False)
    with selectors.DefaultSelector() as selector:
        selector.register(fd, selectors.EVENT_READ)
        while time.monotonic_ns() < end_ns:
            if not selector.select(min(0.05, max(0, (end_ns - time.monotonic_ns()) / NS))):
                continue
            chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > maximum:
                refuse()
        else:
            refuse("WAIT_EXPIRED")
    if len(data) < 4:
        refuse()
    size = int.from_bytes(data[:4], "big")
    if not 1 <= size <= 4096 or len(data) < size + 4:
        refuse()
    header = parse(bytes(data[4:4 + size]), 4096)
    if not isinstance(header, dict) or set(header) != set(expected) | {"size", "digest"} or \
            any(type(header[key]) is not type(value) or header[key] != value for key, value in expected.items()):
        refuse()
    evidence = bytes(data[4 + size:])
    if type(header["size"]) is not int or len(evidence) != header["size"] or \
            len(evidence) > guard.MAX_RECOVERY_RUNTIME_BYTES or \
            hashlib.sha256(evidence).hexdigest() != header["digest"] or time.monotonic_ns() >= end_ns:
        refuse()
    parse(evidence, guard.MAX_RECOVERY_RUNTIME_BYTES)
    return evidence
