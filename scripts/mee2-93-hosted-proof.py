#!/usr/bin/env python3
"""Fail-closed orchestration and evidence validation for the MEE2-93 proof.

The immutable subject is deliberately treated as an opaque test subject.  This
module owns only identity checks, bounded supervision, resource observation,
sanitized evidence and the workflow's exact invocation contract.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SCRIPT_DIR = Path(__file__).resolve().parent
INVENTORY_PATH = SCRIPT_DIR / "mee2-93-hosted-cases.json"
INVENTORY = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))

SUBJECT_SHA = INVENTORY["subject"]["commit"]
SUBJECT_TREE = INVENTORY["subject"]["tree"]
SUBJECT_FILES = tuple(INVENTORY["subject"]["files"])
IMAGES = dict(INVENTORY["images"])
PLAN_SHA = "b98e15ab10c3f25d88485112ecb16d7104ec29ebe30e527417dd4c2645473d58"
SUPPLIED_MANIFEST_SHA = "a32f030a2c7aca9e1e7210b15c3ebda09d7e0684dfab365ccfa2a6d02ef44907"
MAX_CAPTURE = 8 * 1024 * 1024
MAX_PROOF = 256 * 1024
MAX_ARCHIVE_MEMBER = 256 * 1024
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
IMAGE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
SAFE_VERSION = re.compile(r"^[A-Za-z0-9_.:+/-]{1,80}$")
SAFE_ARCH = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")
STATUSES = frozenset(("passed", "failed", "not_run", "environment_blocked", "timeout"))
CLEANUP_STATUSES = frozenset(("passed", "failed", "not_run"))
VERDICTS = frozenset(
    ("pass", "failed", "environment_blocked", "timeout", "unsafe_evidence",
     "cleanup_failed", "incomplete")
)
FAILURE_STAGES = frozenset(
    ("none", "startup", "descriptor", "subject", "images", "filesystem",
     "retention", "immutable_runtime", "cleanup", "evidence")
)
FAILURE_CODES = frozenset(
    ("none", "environment", "unsafe_input", "descriptor_coverage",
     "timeout_tree", "subject_identity", "subject_helper",
     "subject_descriptor", "subject_child_admission", "subject_child_success",
     "subject_retention_success", "subject_retention_admission",
     "subject_witness_loop", "subject_retention_loop", "subject_suite",
     "image_identity", "cleanup", "evidence")
)
DESCRIPTOR_KEYS = (
    "transferred_missing",
    "transferred_replaced_regular",
    "transferred_replaced_symlink",
    "retention_post_acquisition",
)


class ProofFailure(Exception):
    def __init__(self, code: str, *, environment: bool = False, timeout: bool = False):
        super().__init__(code)
        self.code = code
        self.environment = environment
        self.timeout = timeout


@dataclass
class RunResult:
    returncode: int | None
    output: bytes
    timed_out: bool = False
    overflow: bool = False


def fail(code: str, *, environment: bool = False, timeout: bool = False) -> None:
    raise ProofFailure(code, environment=environment, timeout=timeout)


def failure_observation(stage: str = "none", code: str = "none") -> dict[str, str]:
    if stage not in FAILURE_STAGES or code not in FAILURE_CODES:
        fail("schema")
    if (stage == "none") != (code == "none"):
        fail("schema")
    return {"stage": stage, "code": code}


def failure_for_phase(phase: str, error: ProofFailure) -> dict[str, str]:
    if error.environment:
        code = "environment"
    elif error.timeout:
        code = "subject_suite"
    elif phase == "startup":
        code = "unsafe_input"
    elif phase == "descriptor":
        code = "descriptor_coverage"
    elif phase in ("images", "filesystem", "retention", "immutable_runtime"):
        code = "image_identity" if phase == "images" else "subject_suite"
    elif phase == "cleanup":
        code = "cleanup"
    elif phase == "evidence":
        code = "evidence"
    else:
        code = "subject_descriptor"
    return failure_observation(phase, code)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_json(path: Path, limit: int = MAX_PROOF) -> Any:
    data = path.read_bytes()
    if len(data) > limit:
        fail("evidence_size")
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("invalid_json")


def exact_keys(value: Any, keys: Iterable[str]) -> None:
    if not isinstance(value, dict) or set(value) != set(keys):
        fail("schema")


def no_symlink_components(path: Path, *, allow_leaf_missing: bool = False) -> None:
    path = Path(os.path.abspath(path))
    current = Path(path.anchor)
    parts = path.parts[1:]
    for index, part in enumerate(parts):
        current /= part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            if allow_leaf_missing and index == len(parts) - 1:
                return
            fail("unsafe_path")
        if stat.S_ISLNK(info.st_mode):
            fail("unsafe_path")


def absolute_dir(path_value: str, *, existing: bool) -> Path:
    path = Path(path_value)
    if not path.is_absolute():
        fail("unsafe_path")
    if any(part in (".", "..") for part in path.parts):
        fail("unsafe_path")
    no_symlink_components(path, allow_leaf_missing=not existing)
    if existing:
        if not path.is_dir() or path.is_symlink():
            fail("unsafe_path")
    return path


def inside(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def validate_roots(
    subject_value: str,
    tooling_value: str,
    private_value: str,
    evidence_value: str,
) -> tuple[Path, Path, Path, Path]:
    subject = absolute_dir(subject_value, existing=True)
    tooling = absolute_dir(tooling_value, existing=True)
    private = absolute_dir(private_value, existing=False)
    evidence = absolute_dir(evidence_value, existing=False)
    if subject == tooling or inside(subject, tooling) or inside(tooling, subject):
        fail("unsafe_path")
    for candidate in (private, evidence):
        if candidate in (subject, tooling) or inside(candidate, subject) or inside(candidate, tooling):
            fail("unsafe_path")
    if private == evidence or inside(private, evidence) or inside(evidence, private):
        fail("unsafe_path")
    no_symlink_components(private.parent)
    no_symlink_components(evidence.parent)
    return subject, tooling, private, evidence


def clean_child_env() -> dict[str, str]:
    forbidden = (
        "PYTHONOPTIMIZE", "PYTHONPATH", "BASH_ENV", "ENV", "DOCKER_HOST",
        "ACTIONS_RUNTIME_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
        "GITHUB_TOKEN", "GH_TOKEN", "SSH_AUTH_SOCK",
    )
    if any(name in os.environ for name in forbidden):
        fail("startup_override")
    return {
        "PATH": os.defpath,
        "HOME": "/root",
        "LANG": "C",
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
        "COMPOSE_PROJECT_NAME": "meet-production",
    }


def bounded_run(
    argv: list[str],
    *,
    cwd: Path,
    timeout_seconds: float,
    env: dict[str, str],
) -> RunResult:
    if not argv or any("\x00" in item for item in argv):
        fail("command")
    try:
        process = subprocess.Popen(
            argv,
            cwd=str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=(os.name == "posix"),
        )
    except (OSError, ValueError):
        fail("prerequisite", environment=True)
    assert process.stdout is not None and process.stderr is not None
    if os.name != "posix":
        try:
            stdout, stderr = process.communicate(timeout=timeout_seconds)
            output = stdout + stderr
            return RunResult(
                process.returncode,
                output[:MAX_CAPTURE],
                overflow=len(output) > MAX_CAPTURE,
            )
        except subprocess.TimeoutExpired as error:
            try:
                process.kill()
            except OSError:
                pass
            stdout, stderr = process.communicate()
            output = (error.output or b"") + (error.stderr or b"") + stdout + stderr
            return RunResult(
                process.returncode,
                output[:MAX_CAPTURE],
                timed_out=True,
                overflow=len(output) > MAX_CAPTURE,
            )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    selector.register(process.stderr, selectors.EVENT_READ)
    retained = bytearray()
    total = 0
    overflow = False
    timed_out = False
    deadline = time.monotonic() + timeout_seconds
    terminated_at: float | None = None
    forced = False

    def terminate(force: bool = False) -> None:
        nonlocal terminated_at, forced
        try:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
            else:
                if process.poll() is not None:
                    return
                (process.kill if force else process.terminate)()
        except (OSError, ProcessLookupError):
            pass
        if terminated_at is None:
            terminated_at = time.monotonic()
        forced = forced or force

    while selector.get_map():
        now = time.monotonic()
        if now >= deadline and process.poll() is None:
            timed_out = True
            terminate()
        if terminated_at is not None and not forced and now - terminated_at >= 5:
            terminate(force=True)
        if terminated_at is not None and now - terminated_at >= 10:
            for key in list(selector.get_map().values()):
                try:
                    selector.unregister(key.fileobj)
                except Exception:
                    pass
            break
        events = selector.select(0.10)
        for key, _ in events:
            try:
                chunk = os.read(key.fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                try:
                    selector.unregister(key.fileobj)
                except Exception:
                    pass
                continue
            total += len(chunk)
            if total > MAX_CAPTURE:
                overflow = True
                terminate()
            elif not overflow:
                retained.extend(chunk)
    returncode = process.wait(timeout=10)
    return RunResult(returncode, bytes(retained), timed_out, overflow)


def git_value(repo: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
            env={"PATH": os.defpath, "LC_ALL": "C"},
        )
    except (OSError, subprocess.SubprocessError):
        fail("subject_identity")
    return result.stdout.strip()


def subject_identity(subject: Path) -> None:
    if git_value(subject, "rev-parse", "HEAD") != SUBJECT_SHA:
        fail("subject_sha")
    if git_value(subject, "rev-parse", "HEAD^{tree}") != SUBJECT_TREE:
        fail("subject_tree")
    if git_value(
        subject, "status", "--porcelain", "--untracked-files=all", "--ignored"
    ):
        fail("subject_dirty")
    for item in SUBJECT_FILES:
        path = subject / item["path"]
        if not path.is_file() or path.is_symlink() or sha256_file(path) != item["sha256"]:
            fail("subject_file")


def fixed_case_statuses(status: str) -> dict[str, dict[str, str]]:
    return {
        suite: {group: status for group in groups}
        for suite, groups in INVENTORY["groups"].items()
    }


def descriptor_records(status: str = "not_run") -> dict[str, dict[str, Any]]:
    return {
        key: {
            "status": status,
            "iterations": 0,
            "maxFdGrowthBeforeRescue": None,
        }
        for key in DESCRIPTOR_KEYS
    }


def initial_evidence(tooling_sha: str, workflow_sha: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "identity": {
            "toolingSha": tooling_sha,
            "subjectSha": SUBJECT_SHA,
            "workflowSha": workflow_sha,
            "suppliedPlanSha256": PLAN_SHA,
            "suppliedManifestSha256": SUPPLIED_MANIFEST_SHA,
            "subjectFiles": [dict(item) for item in SUBJECT_FILES],
        },
        "runtime": {
            "osDistribution": "unknown",
            "osVersion": "unknown",
            "architecture": "unknown",
            "toolVersions": {
                "bash": "unknown",
                "python": "unknown",
                "docker": "unknown",
                "compose": "unknown",
            },
        },
        "images": {
            name: {"ref": ref, "imageId": None}
            for name, ref in IMAGES.items()
        },
        "suites": {
            "filesystem": {
                "status": "not_run",
                "exitCode": None,
                "cases": fixed_case_statuses("not_run")["filesystem"],
                "descriptorFailures": descriptor_records(),
            },
            "retention": {
                "status": "not_run",
                "exitCode": None,
                "cases": fixed_case_statuses("not_run")["retention"],
            },
            "immutableRuntime": {
                "status": "not_run",
                "exitCode": None,
                "cases": fixed_case_statuses("not_run")["immutableRuntime"],
            },
        },
        "cleanup": {
            key: "not_run"
            for key in (
                "processes", "filesystem", "containers", "networks",
                "volumes", "images", "privateCapture",
            )
        },
        "failure": failure_observation(),
        "verdict": "incomplete",
    }


def os_release() -> tuple[str, str]:
    values: dict[str, str] = {}
    try:
        for line in Path("/etc/os-release").read_text(encoding="ascii").splitlines():
            key, separator, value = line.partition("=")
            if separator:
                values[key] = value.strip('"')
    except (OSError, UnicodeError):
        return "unknown", "unknown"
    return values.get("ID", "unknown"), values.get("VERSION_ID", "unknown")


def command_version(argv: list[str], env: dict[str, str], cwd: Path) -> str:
    result = bounded_run(argv, cwd=cwd, timeout_seconds=30, env=env)
    if result.returncode != 0 or result.timed_out or result.overflow:
        return "unavailable"
    first = result.output.decode("utf-8", "replace").splitlines()
    match = re.search(r"\b[0-9]+(?:\.[0-9]+){1,3}\b", first[0] if first else "")
    return match.group(0) if match else "unavailable"


def collect_runtime(subject: Path, env: dict[str, str]) -> dict[str, Any]:
    distribution, version = os_release()
    architecture = platform.machine()
    if not SAFE_VERSION.fullmatch(distribution) or not SAFE_VERSION.fullmatch(version):
        distribution, version = "unknown", "unknown"
    if not SAFE_ARCH.fullmatch(architecture):
        architecture = "unknown"
    return {
        "osDistribution": distribution,
        "osVersion": version,
        "architecture": architecture,
        "toolVersions": {
            "bash": command_version(["bash", "--version"], env, subject),
            "python": command_version(["python3", "--version"], env, subject),
            "docker": command_version(["docker", "--version"], env, subject),
            "compose": command_version(["docker", "compose", "version"], env, subject),
        },
    }


def parse_descriptor_result(output: bytes) -> dict[str, dict[str, Any]] | None:
    for line in output.decode("utf-8", "replace").splitlines():
        prefix = "MEE2_DESCRIPTOR_RESULT="
        if not line.startswith(prefix):
            continue
        try:
            value = json.loads(line[len(prefix):])
        except json.JSONDecodeError:
            return None
        if not isinstance(value, dict) or set(value) != set(DESCRIPTOR_KEYS):
            return None
        try:
            validate_descriptor_records(value)
        except ProofFailure:
            return None
        return value
    return None


def parse_descriptor_failure(output: bytes) -> dict[str, str] | None:
    prefix = "MEE2_DESCRIPTOR_FAILURE="
    for line in output.decode("utf-8", "replace").splitlines():
        if not line.startswith(prefix):
            continue
        try:
            value = json.loads(line[len(prefix):])
        except json.JSONDecodeError:
            return None
        try:
            exact_keys(value, ("stage", "code"))
            return failure_observation(value["stage"], value["code"])
        except ProofFailure:
            return None
    return None


def validate_descriptor_records(value: Any) -> None:
    exact_keys(value, DESCRIPTOR_KEYS)
    for item in value.values():
        exact_keys(item, ("status", "iterations", "maxFdGrowthBeforeRescue"))
        if item["status"] not in STATUSES:
            fail("descriptor_schema")
        if type(item["iterations"]) is not int or not 0 <= item["iterations"] <= 100:
            fail("descriptor_schema")
        growth = item["maxFdGrowthBeforeRescue"]
        if growth is not None and (type(growth) is not int or not 0 <= growth <= 1024):
            fail("descriptor_schema")


def apply_descriptor_result(proof: dict[str, Any], value: dict[str, dict[str, Any]]) -> None:
    validate_descriptor_records(value)
    suite = proof["suites"]["filesystem"]
    suite["descriptorFailures"] = value
    suite["cases"]["descriptor_stability"] = (
        "passed" if all(item["status"] == "passed" for item in value.values()) else "failed"
    )
    if suite["cases"]["descriptor_stability"] != "passed":
        suite["status"] = "failed"


def image_inspect(ref: str, env: dict[str, str], cwd: Path) -> dict[str, Any]:
    result = bounded_run(
        ["docker", "image", "inspect", ref],
        cwd=cwd,
        timeout_seconds=30,
        env=env,
    )
    if result.returncode != 0 or result.timed_out or result.overflow:
        fail("image_unavailable", environment=True)
    try:
        payload = json.loads(result.output.decode("utf-8"))
        value = payload[0]
        if not isinstance(value, dict):
            raise ValueError
    except (ValueError, IndexError, KeyError, TypeError, json.JSONDecodeError):
        fail("image_identity")
    image_id = value.get("Id")
    if not isinstance(image_id, str) or not IMAGE_ID.fullmatch(image_id):
        fail("image_identity")
    repo_digests = value.get("RepoDigests")
    if (
        not isinstance(repo_digests, list)
        or not any(
            isinstance(candidate, str) and repo_digest_matches(ref, candidate)
            for candidate in repo_digests
        )
    ):
        fail("image_identity")
    return value


def normalized_image_repository(ref: str) -> tuple[str, str]:
    repository, digest = ref.rsplit("@sha256:", 1)
    leaf = repository.rsplit("/", 1)[-1]
    if ":" in leaf:
        repository = repository.rsplit(":", 1)[0]
    return repository, digest


def repo_digest_matches(ref: str, candidate: str) -> bool:
    try:
        candidate_repository, candidate_digest = candidate.rsplit("@sha256:", 1)
    except ValueError:
        return False
    expected_repository, expected_digest = normalized_image_repository(ref)
    return (
        candidate_repository == expected_repository
        and candidate_digest == expected_digest
    )


def pull_images(proof: dict[str, Any], subject: Path, env: dict[str, str]) -> None:
    for name, ref in IMAGES.items():
        pulled = bounded_run(
            ["docker", "pull", ref],
            cwd=subject,
            timeout_seconds=300,
            env=env,
        )
        if pulled.returncode != 0 or pulled.timed_out or pulled.overflow:
            fail("image_pull", environment=True)
        inspected = image_inspect(ref, env, subject)
        image_id = inspected["Id"]
        proof["images"][name]["imageId"] = image_id
        if name in ("predecessor", "target"):
            config = inspected.get("Config")
            labels = config.get("Labels") if isinstance(config, dict) else None
            user = config.get("User") if isinstance(config, dict) else None
            if (
                not isinstance(labels, dict)
                or labels.get("org.opencontainers.image.source")
                != "https://github.com/NickolayMamonov/meet-backend-v3"
                or user != "10001:10001"
            ):
                fail("image_identity")
        if name == "postgres" and ref != IMAGES["postgres"]:
            fail("postgres_ref")
    if proof["images"]["predecessor"]["imageId"] == proof["images"]["target"]["imageId"]:
        fail("duplicate_image_id")


def marker_count(output: bytes, marker: bytes) -> int:
    return sum(line.startswith(marker) for line in output.splitlines())


def run_subject_suite(
    proof: dict[str, Any],
    *,
    suite: str,
    argv: list[str],
    subject: Path,
    env: dict[str, str],
    timeout_seconds: float,
    markers: tuple[bytes, ...],
) -> None:
    result = bounded_run(argv, cwd=subject, timeout_seconds=timeout_seconds, env=env)
    target = proof["suites"][suite]
    if result.timed_out:
        target["status"] = "timeout"
        proof["verdict"] = "timeout"
        fail("suite_timeout", timeout=True)
    if result.overflow:
        target["status"] = "failed"
        proof["verdict"] = "failed"
        fail("capture_overflow")
    target["exitCode"] = result.returncode
    if result.returncode == 77:
        target["status"] = "environment_blocked"
        proof["verdict"] = "environment_blocked"
        fail("suite_prerequisite", environment=True)
    if result.returncode != 0 or any(
        marker_count(result.output, marker) != 1 for marker in markers
    ):
        target["status"] = "failed"
        proof["verdict"] = "failed"
        fail("suite_failed")
    target["status"] = "passed"
    for group in target["cases"]:
        target["cases"][group] = "passed"


def lstat_identity(path: Path) -> tuple[int, int] | None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    return info.st_dev, info.st_ino


def remove_owned_tree(path: Path, expected: tuple[int, int]) -> bool:
    if lstat_identity(path) != expected or path.is_symlink():
        return False
    try:
        for child in path.iterdir():
            child_identity = lstat_identity(child)
            if child_identity is None:
                continue
            if child.is_symlink():
                return False
            if child.is_dir():
                if not remove_owned_tree(child, child_identity):
                    return False
            else:
                if lstat_identity(child) != child_identity:
                    return False
                child.unlink()
        if lstat_identity(path) != expected:
            return False
        path.rmdir()
        return True
    except OSError:
        return False


def check_fixed_cleanup() -> bool:
    names = (
        "/var/lib/meet-production",
        "/var/lib/meet-test-vps-deploy",
        "/var/lib/meet-retention-production",
    )
    if any(os.path.lexists(name) for name in names):
        return False
    for parent, pattern in (
        (Path("/var/lib"), "meet-provider-image.*"),
        (Path("/var/lib"), "meet-provider-fixture.*"),
        (Path("/var/lib"), "mee2-95-descriptor.*"),
        (Path("/tmp"), "meet-retention-fixture.*"),
        (Path("/tmp"), "meet-provider-image-map.*"),
    ):
        if any(parent.glob(pattern)):
            return False
    return True


def maybe_image_id(ref: str, env: dict[str, str], cwd: Path) -> str | None:
    result = bounded_run(
        ["docker", "image", "inspect", ref, "--format", "{{.Id}}"],
        cwd=cwd,
        timeout_seconds=30,
        env=env,
    )
    if result.returncode != 0 or result.timed_out or result.overflow:
        return None
    value = result.output.decode("ascii", "ignore").strip()
    return value if IMAGE_ID.fullmatch(value) else None


def cleanup_owned_images(
    image_ids: set[str], subject: Path, env: dict[str, str]
) -> bool:
    for image_id in sorted(image_ids):
        removed = bounded_run(
            ["docker", "image", "rm", image_id],
            cwd=subject,
            timeout_seconds=60,
            env=env,
        )
        if removed.returncode != 0 or removed.timed_out or removed.overflow:
            return False
        if maybe_image_id(image_id, env, subject) is not None:
            return False
    return True


def docker_cleanup_ok(subject: Path, env: dict[str, str]) -> bool:
    checks = (
        ["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=meet-production"],
        ["docker", "network", "ls", "--filter", "name=^meet-production_default$",
         "--format", "{{.Name}}"],
        ["docker", "volume", "ls", "--filter", "name=^meet-production_postgres_data$",
         "--format", "{{.Name}}"],
        ["docker", "volume", "ls", "--filter", "name=^meet-production_uploads_data$",
         "--format", "{{.Name}}"],
    )
    for argv in checks:
        result = bounded_run(argv, cwd=subject, timeout_seconds=30, env=env)
        if result.returncode != 0 or result.timed_out or result.overflow:
            return False
        if result.output.strip():
            return False
    return True


def assert_docker_clean_before(subject: Path, env: dict[str, str]) -> None:
    checks = (
        ["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=meet-production"],
        ["docker", "network", "ls", "--filter", "name=^meet-production_default$",
         "--format", "{{.Name}}"],
        ["docker", "volume", "ls", "--filter", "name=^meet-production_postgres_data$",
         "--format", "{{.Name}}"],
        ["docker", "volume", "ls", "--filter", "name=^meet-production_uploads_data$",
         "--format", "{{.Name}}"],
    )
    for argv in checks:
        result = bounded_run(argv, cwd=subject, timeout_seconds=30, env=env)
        if result.returncode != 0 or result.timed_out or result.overflow:
            fail("docker_prerequisite", environment=True)
        if result.output.strip():
            fail("foreign_resource")


def validate_secret_free(data: bytes) -> None:
    lowered = data.lower()
    forbidden = (
        b"-----begin", b"private_key", b"private key", b"refresh_token",
        b"authorization", b"bearer ", b"ghs_", b"ghp_", b"runtime_fixture",
        b"client_secret", b"db_password", b"jwt_secret",
    )
    if any(token in lowered for token in forbidden):
        fail("unsafe_evidence")


def grant_evidence_read_access(root: Path) -> None:
    if sorted(item.name for item in root.iterdir()) != ["SHA256SUMS", "proof.json"]:
        fail("evidence_files")
    for name in ("proof.json", "SHA256SUMS"):
        path = root / name
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            fail("evidence_files")
        os.chmod(path, 0o644)
    os.chmod(root, 0o755)


def validate_descriptor_sticky(proof: dict[str, Any]) -> None:
    records = proof["suites"]["filesystem"]["descriptorFailures"]
    for record in records.values():
        growth = record["maxFdGrowthBeforeRescue"]
        if growth is not None and growth > 0:
            record["status"] = "failed"
            proof["suites"]["filesystem"]["status"] = "failed"
            proof["suites"]["filesystem"]["cases"]["descriptor_stability"] = "failed"
            proof["verdict"] = "failed"


def write_evidence(root: Path, proof: dict[str, Any]) -> None:
    validate_descriptor_sticky(proof)
    validate_proof(proof)
    data = json.dumps(proof, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    if len(data) > MAX_PROOF:
        fail("unsafe_evidence")
    validate_secret_free(data)
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    proof_path = root / "proof.json"
    sums_path = root / "SHA256SUMS"
    proof_path.write_bytes(data)
    os.chmod(proof_path, 0o600)
    checksum = sha256_bytes(data)
    sums_path.write_text(f"{checksum}  proof.json\n", encoding="ascii")
    os.chmod(sums_path, 0o600)


def validate_proof(proof: Any) -> None:
    exact_keys(
        proof,
        ("schemaVersion", "identity", "runtime", "images", "suites",
         "cleanup", "failure", "verdict"),
    )
    if proof["schemaVersion"] != 1:
        fail("schema")
    identity = proof["identity"]
    exact_keys(identity, ("toolingSha", "subjectSha", "workflowSha", "suppliedPlanSha256",
                          "suppliedManifestSha256", "subjectFiles"))
    for key in ("toolingSha", "subjectSha", "workflowSha"):
        if not isinstance(identity[key], str) or not HEX40.fullmatch(identity[key]):
            fail("schema")
    for key in ("suppliedPlanSha256", "suppliedManifestSha256"):
        if not isinstance(identity[key], str) or not HEX64.fullmatch(identity[key]):
            fail("schema")
    if identity["subjectSha"] != SUBJECT_SHA or identity["suppliedPlanSha256"] != PLAN_SHA:
        fail("schema")
    if identity["suppliedManifestSha256"] != SUPPLIED_MANIFEST_SHA:
        fail("schema")
    if not isinstance(identity["subjectFiles"], list) or identity["subjectFiles"] != list(SUBJECT_FILES):
        fail("schema")
    runtime = proof["runtime"]
    exact_keys(runtime, ("osDistribution", "osVersion", "architecture", "toolVersions"))
    if any(not isinstance(runtime[key], str) or not SAFE_VERSION.fullmatch(runtime[key])
           for key in ("osDistribution", "osVersion", "architecture")):
        fail("schema")
    exact_keys(runtime["toolVersions"], ("bash", "python", "docker", "compose"))
    if any(not isinstance(value, str) or not SAFE_VERSION.fullmatch(value)
           for value in runtime["toolVersions"].values()):
        fail("schema")
    exact_keys(proof["images"], ("predecessor", "target", "postgres"))
    for name, ref in IMAGES.items():
        item = proof["images"][name]
        exact_keys(item, ("ref", "imageId"))
        if item["ref"] != ref or (item["imageId"] is not None and not IMAGE_ID.fullmatch(item["imageId"])):
            fail("schema")
    predecessor_id = proof["images"]["predecessor"]["imageId"]
    target_id = proof["images"]["target"]["imageId"]
    if predecessor_id is not None and predecessor_id == target_id:
        fail("schema")
    suites = proof["suites"]
    exact_keys(suites, ("filesystem", "retention", "immutableRuntime"))
    for suite_name in ("filesystem", "retention", "immutableRuntime"):
        suite = suites[suite_name]
        expected = INVENTORY["groups"][suite_name]
        keys = ("status", "exitCode", "cases", "descriptorFailures") if suite_name == "filesystem" else (
            "status", "exitCode", "cases"
        )
        exact_keys(suite, keys)
        if suite["status"] not in STATUSES:
            fail("schema")
        if suite["exitCode"] is not None and (
            type(suite["exitCode"]) is not int or not 0 <= suite["exitCode"] <= 255
        ):
            fail("schema")
        exact_keys(suite["cases"], expected)
        if any(value not in STATUSES for value in suite["cases"].values()):
            fail("schema")
        if suite["status"] == "passed":
            if suite["exitCode"] != 0 or any(
                value != "passed" for value in suite["cases"].values()
            ):
                fail("schema")
        if suite_name == "filesystem":
            validate_descriptor_records(suite["descriptorFailures"])
            if suite["status"] == "passed" and any(
                item["status"] != "passed"
                or item["iterations"] != 100
                or item["maxFdGrowthBeforeRescue"] != 0
                for item in suite["descriptorFailures"].values()
            ):
                fail("schema")
    exact_keys(proof["cleanup"], (
        "processes", "filesystem", "containers", "networks", "volumes", "images", "privateCapture"
    ))
    if any(value not in CLEANUP_STATUSES for value in proof["cleanup"].values()):
        fail("schema")
    failure = proof["failure"]
    exact_keys(failure, ("stage", "code"))
    failure_observation(failure["stage"], failure["code"])
    if proof["verdict"] not in VERDICTS:
        fail("schema")
    descriptor_growth = any(
        record["maxFdGrowthBeforeRescue"] not in (None, 0)
        for record in proof["suites"]["filesystem"]["descriptorFailures"].values()
    )
    if descriptor_growth and (
        proof["verdict"] == "pass"
        or proof["suites"]["filesystem"]["status"] == "passed"
        or proof["suites"]["filesystem"]["cases"]["descriptor_stability"] == "passed"
    ):
        fail("schema")
    if proof["verdict"] == "pass":
        if any(value != "passed" for value in proof["cleanup"].values()):
            fail("schema")
        if any(
            proof["images"][name]["imageId"] is None
            for name in ("predecessor", "target", "postgres")
        ):
            fail("schema")
        if any(suite["status"] != "passed" for suite in proof["suites"].values()):
            fail("schema")


def validate_evidence_root(root_value: str) -> None:
    root = absolute_dir(root_value, existing=True)
    entries = sorted(item.name for item in root.iterdir())
    if entries != ["SHA256SUMS", "proof.json"]:
        fail("evidence_files")
    for item in root.iterdir():
        if item.is_symlink() or not item.is_file():
            fail("evidence_files")
    proof_path = root / "proof.json"
    sums_path = root / "SHA256SUMS"
    proof_data = proof_path.read_bytes()
    if len(proof_data) > MAX_PROOF:
        fail("evidence_size")
    validate_secret_free(proof_data)
    proof = json.loads(proof_data.decode("utf-8"))
    validate_proof(proof)
    expected = f"{sha256_bytes(proof_data)}  proof.json\n"
    if sums_path.read_text(encoding="ascii") != expected:
        fail("checksum")


def verify_archive(archive_value: str, archive_sha: str, expected_tooling: str) -> None:
    archive = Path(archive_value)
    if not archive.is_absolute() or not archive.is_file() or archive.is_symlink():
        fail("archive")
    if not HEX64.fullmatch(archive_sha) or not HEX40.fullmatch(expected_tooling):
        fail("archive")
    if sha256_file(archive) != archive_sha:
        fail("checksum")
    try:
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            names = [member.filename for member in members]
            if len(names) != 2 or set(names) != {"proof.json", "SHA256SUMS"} or len(set(names)) != 2:
                fail("archive_members")
            payload: dict[str, bytes] = {}
            for member in members:
                if member.filename.startswith("/") or ".." in Path(member.filename).parts:
                    fail("archive_traversal")
                if member.is_dir() or member.file_size > MAX_ARCHIVE_MEMBER:
                    fail("archive_member")
                mode = (member.external_attr >> 16) & 0o170000
                if mode == stat.S_IFLNK:
                    fail("archive_symlink")
                payload[member.filename] = bundle.read(member)
    except (OSError, zipfile.BadZipFile):
        fail("archive")
    with tempfile.TemporaryDirectory(prefix="mee2-93-archive-") as staging:
        root = Path(staging)
        (root / "proof.json").write_bytes(payload["proof.json"])
        (root / "SHA256SUMS").write_bytes(payload["SHA256SUMS"])
        validate_evidence_root(str(root))
    proof = json.loads(payload["proof.json"].decode("utf-8"))
    if proof["identity"]["toolingSha"] != expected_tooling:
        fail("archive_identity")


def safe_failure_proof(tooling_sha: str, workflow_sha: str, verdict: str = "failed") -> dict[str, Any]:
    proof = initial_evidence(tooling_sha, workflow_sha)
    proof["runtime"] = {
        "osDistribution": "unknown",
        "osVersion": "unknown",
        "architecture": "unknown",
        "toolVersions": {
            "bash": "unknown",
            "python": "unknown",
            "docker": "unknown",
            "compose": "unknown",
        },
    }
    proof["cleanup"] = {
        key: "not_run"
        for key in (
            "processes", "filesystem", "containers", "networks",
            "volumes", "images", "privateCapture",
        )
    }
    proof["verdict"] = verdict
    return proof


def run_proof(args: argparse.Namespace) -> int:
    tooling_sha = args.tooling_sha
    workflow_sha = args.workflow_sha
    if not HEX40.fullmatch(tooling_sha) or not HEX40.fullmatch(workflow_sha):
        return 2
    phase = "startup"
    try:
        subject, tooling, private, evidence = validate_roots(
            args.subject, args.tooling, args.private_root, args.evidence_root
        )
        if private.exists() or evidence.exists():
            fail("unsafe_path")
        env = clean_child_env()
        if sys.flags.optimize != 0:
            fail("python_optimized")
        proof = initial_evidence(tooling_sha, workflow_sha)
        proof["runtime"] = collect_runtime(subject, env)
        subject_identity(subject)
        compose = subject / "docker-compose.production.yml"
        if (
            not compose.is_file()
            or f"postgres:16-alpine@sha256:{IMAGES['postgres'].split('@sha256:', 1)[1]}"
            not in compose.read_text(encoding="utf-8")
        ):
            fail("postgres_ref")
        fixed_before = check_fixed_cleanup()
        if not fixed_before:
            fail("foreign_resource")
        private.mkdir(mode=0o700, parents=False, exist_ok=False)
        test_script = tooling / "scripts" / "test-mee2-93-hosted-proof.py"
        if not test_script.is_file() or test_script.is_symlink():
            fail("tooling_missing")
        phase = "descriptor"
        descriptor = bounded_run(
            ["python3", "-B", str(test_script), "--linux-runtime", "--subject", str(subject)],
            cwd=tooling,
            timeout_seconds=900,
            env=env,
        )
        descriptor_value = parse_descriptor_result(descriptor.output)
        descriptor_failure = parse_descriptor_failure(descriptor.output)
        if descriptor_failure is not None and descriptor_failure["stage"] != "none":
            proof["failure"] = descriptor_failure
        if descriptor_value is None:
            fail("descriptor_coverage")
        apply_descriptor_result(proof, descriptor_value)
        if descriptor.returncode != 0 or descriptor.timed_out or descriptor.overflow:
            proof["suites"]["filesystem"]["status"] = (
                "timeout" if descriptor.timed_out else "failed"
            )
            environment_blocked = descriptor.returncode == 77 or all(
                item["status"] == "environment_blocked"
                for item in descriptor_value.values()
            )
            if environment_blocked:
                proof["suites"]["filesystem"]["status"] = "environment_blocked"
            proof["verdict"] = (
                "timeout" if descriptor.timed_out else
                "environment_blocked" if environment_blocked else "failed"
            )
            fail(
                "descriptor_failed",
                environment=environment_blocked,
                timeout=descriptor.timed_out,
            )
        phase = "images"
        owned_images: set[str] = set()
        assert_docker_clean_before(subject, env)
        preexisting_images = {
            name: maybe_image_id(ref, env, subject)
            for name, ref in IMAGES.items()
        }
        pull_images(proof, subject, env)
        owned_images = {
            proof["images"][name]["imageId"]
            for name in IMAGES
            if preexisting_images[name] is None and proof["images"][name]["imageId"] is not None
        }
        phase = "filesystem"
        run_subject_suite(
            proof,
            suite="filesystem",
            argv=["bash", "scripts/test-test-vps-provider-runtime.sh", "--filesystem-only"],
            subject=subject,
            env=env,
            timeout_seconds=900,
            markers=(b"provider filesystem fixture passed:",),
        )
        phase = "retention"
        run_subject_suite(
            proof,
            suite="retention",
            argv=["bash", "scripts/test-test-vps-retention.sh"],
            subject=subject,
            env=env,
            timeout_seconds=900,
            markers=(b"retention fixture passed:",),
        )
        phase = "immutable_runtime"
        run_subject_suite(
            proof,
            suite="immutableRuntime",
            argv=[
                "bash", "scripts/test-test-vps-provider-runtime.sh",
                "--previous-image", IMAGES["predecessor"],
                "--target-image", IMAGES["target"],
            ],
            subject=subject,
            env=env,
            timeout_seconds=7200,
            markers=(
                b"image_runtime case=disabled",
                b"image_runtime case=enabled",
                b"image_runtime_cleanup case=disabled",
                b"image_runtime_cleanup case=enabled",
            ),
        )
        phase = "cleanup"
        subject_identity(subject)
        validate_descriptor_sticky(proof)
        if not check_fixed_cleanup():
            proof["cleanup"]["filesystem"] = "failed"
            proof["verdict"] = "cleanup_failed"
            fail("cleanup_residue")
        if not cleanup_owned_images(owned_images, subject, env):
            proof["cleanup"]["images"] = "failed"
            proof["verdict"] = "cleanup_failed"
            fail("image_cleanup")
        if not docker_cleanup_ok(subject, env):
            proof["cleanup"]["containers"] = "failed"
            proof["cleanup"]["networks"] = "failed"
            proof["cleanup"]["volumes"] = "failed"
            proof["verdict"] = "cleanup_failed"
            fail("docker_cleanup")
        proof["cleanup"] = {
            key: "passed"
            for key in (
                "processes", "filesystem", "containers", "networks",
                "volumes", "images", "privateCapture",
            )
        }
        proof["verdict"] = "pass"
        shutil.rmtree(private)
        proof["cleanup"]["privateCapture"] = "passed"
        phase = "evidence"
        write_evidence(evidence, proof)
        grant_evidence_read_access(evidence)
        return 0
    except ProofFailure as error:
        try:
            if "proof" not in locals():
                proof = safe_failure_proof(tooling_sha, workflow_sha, (
                    "environment_blocked" if error.environment else
                    "timeout" if error.timeout else "failed"
                ))
                proof["failure"] = failure_for_phase(phase, error)
            else:
                if proof["failure"]["stage"] == "none":
                    proof["failure"] = failure_for_phase(phase, error)
                proof["verdict"] = (
                    "environment_blocked" if error.environment else
                    "timeout" if error.timeout else
                    "cleanup_failed" if error.code == "cleanup_residue" else "failed"
                )
                validate_descriptor_sticky(proof)
            if "preexisting_images" in locals() and "subject" in locals() and "env" in locals():
                if "owned_images" not in locals():
                    owned_images = set()
                    if "preexisting_images" in locals():
                        owned_images = {
                            proof["images"][name]["imageId"]
                            for name in IMAGES
                            if (
                                preexisting_images[name] is None
                                and proof["images"][name]["imageId"] is not None
                            )
                        }
                proof["cleanup"]["images"] = (
                    "passed" if cleanup_owned_images(owned_images, subject, env) else "failed"
                )
            if "private" in locals() and private.exists():
                identity = lstat_identity(private)
                proof["cleanup"]["privateCapture"] = (
                    "passed" if identity is not None and remove_owned_tree(private, identity)
                    else "failed"
                )
            if "evidence" in locals() and not evidence.exists():
                write_evidence(evidence, proof)
            if "evidence" in locals() and evidence.exists():
                grant_evidence_read_access(evidence)
        except (ProofFailure, OSError, ValueError):
            return 1
        finally:
            if "private" in locals() and private.exists():
                identity = lstat_identity(private)
                if identity is not None:
                    remove_owned_tree(private, identity)
        return 77 if error.environment else 124 if error.timeout else 1
    except (OSError, ValueError, json.JSONDecodeError):
        return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    proof = subparsers.add_parser("proof")
    proof.add_argument("--subject", required=True)
    proof.add_argument("--tooling", required=True)
    proof.add_argument("--private-root", required=True)
    proof.add_argument("--evidence-root", required=True)
    proof.add_argument("--tooling-sha", required=True)
    proof.add_argument("--workflow-sha", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--evidence-root", required=True)
    archive = subparsers.add_parser("verify-archive")
    archive.add_argument("--archive", required=True)
    archive.add_argument("--archive-sha256", required=True)
    archive.add_argument("--expected-tooling-sha", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "proof":
            return run_proof(args)
        if args.command == "validate":
            validate_evidence_root(args.evidence_root)
            return 0
        verify_archive(args.archive, args.archive_sha256, args.expected_tooling_sha)
        return 0
    except ProofFailure:
        return 1
    except (OSError, ValueError, json.JSONDecodeError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
