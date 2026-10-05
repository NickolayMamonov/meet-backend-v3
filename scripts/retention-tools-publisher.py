#!/usr/bin/env python3
"""Read-only admission and exact B-input materialization for the tools publisher."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "NickolayMamonov/meet-backend-v3"
REPOSITORY_ID = 1146014865
WORKFLOW_PATH = ".github/workflows/prepare-retention-proof-tools.yml"
LOCK_PATH = "scripts/fixtures/retention-proof/toolchain.lock.json"
DOCKERFILE_PATH = "scripts/fixtures/retention-proof/Dockerfile"
BUILD_INPUT_SHA = "cfea146e7d72b85177cb1e42adf3b4cf8e6c7d10"
BUILD_CI_RUN_ID = "37246504835"
PLAN_SHA256 = "da21be2bc38466fc8322a1c4fc53cf853130cc50ac3de4ae2950116475479215"
LOCK_SHA256 = "a0e3187dc11eb32503e572363955f66c9681b7b9f397866d03724b5c1925f71b"
DOCKERFILE_SHA256 = "60eb7d6e54b20468668fa1be3ec024f06907b4fea89eaa3c82747c335aae9621"
API_BASE = "https://api.github.com"
API_LIMIT = 64 * 1024
LOCK_LIMIT = 16 * 1024
DOCKERFILE_LIMIT = 64 * 1024
PIN_PATTERNS = {
    "BUILD_INPUT_SHA": re.compile(r"(?m)^  BUILD_INPUT_SHA: ([0-9a-f]{40})$"),
    "BUILD_CI_RUN_ID": re.compile(r"(?m)^  BUILD_CI_RUN_ID: ([1-9][0-9]*)$"),
    "TOOLCHAIN_LOCK_SHA256": re.compile(
        r"(?m)^  TOOLCHAIN_LOCK_SHA256: ([0-9a-f]{64})$"
    ),
    "TOOLCHAIN_DOCKERFILE_SHA256": re.compile(
        r"(?m)^  TOOLCHAIN_DOCKERFILE_SHA256: ([0-9a-f]{64})$"
    ),
}
LOCK_KEYS = {
    "schemaVersion", "enabled", "platform", "baseImage", "ubuntuSnapshot",
    "packages", "dockerfileSha256", "preparedImage", "provenanceSha256",
    "engineVersion", "engineApiVersion", "engineLayout",
}
REQUIRED_PACKAGES = {
    "acl", "bash", "ca-certificates", "coreutils", "findutils", "gawk",
    "grep", "jq", "python3", "python3-minimal", "sed", "tar", "util-linux",
}
BASE_IMAGE = (
    "ubuntu:24.04@sha256:"
    "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
)
SNAPSHOT = "https://snapshot.ubuntu.com/ubuntu/20260918T000000Z"


class Denied(Exception):
    """A required publisher admission check failed closed."""


def decode_object(data: bytes, limit: int, label: str) -> dict[str, object]:
    if len(data) > limit:
        raise Denied(f"{label} exceeds its byte limit")

    def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise Denied(f"{label} contains a duplicate key")
            result[key] = value
        return result

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied(f"{label} is malformed") from error
    if not isinstance(value, dict):
        raise Denied(f"{label} is not an object")
    return value


def git_blob_sha(data: bytes) -> str:
    header = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(header + data).hexdigest()


class GitHubReader:
    """A bounded GET-only client restricted to Contents and Actions reads."""

    def __init__(self, repository: str, repository_id: int, token: str) -> None:
        if repository != REPOSITORY or repository_id != REPOSITORY_ID or not token:
            raise Denied("authenticated repository identity is unavailable")
        self.repository = repository
        self.repository_id = repository_id
        self.token = token

    def get(self, path: str, query: dict[str, str] | None = None) -> dict[str, object]:
        allowed = {
            f"repos/{REPOSITORY}",
            f"repos/{REPOSITORY}/git/ref/heads/master",
        }
        actions_prefix = f"repos/{REPOSITORY}/actions/runs/"
        is_action_run = (
            path.startswith(actions_prefix)
            and bool(re.fullmatch(r"[1-9][0-9]*", path.removeprefix(actions_prefix)))
        )
        workflows_list = path == f"repos/{REPOSITORY}/actions/workflows"
        prefix = f"repos/{REPOSITORY}/contents/"
        relative = path.removeprefix(prefix)
        is_content = path.startswith(prefix) and relative in {
            WORKFLOW_PATH, LOCK_PATH, DOCKERFILE_PATH,
        }
        if (
            path not in allowed and not is_content and not is_action_run
            and not workflows_list
        ):
            raise Denied("GitHub route is not an allowlisted read")
        if is_content:
            if (
                query is None or set(query) != {"ref"}
                or not re.fullmatch(r"[0-9a-f]{40}", query["ref"])
            ):
                raise Denied("Contents read must name one exact commit")
        elif workflows_list:
            if query != {"per_page": "100"}:
                raise Denied("workflow registry read must use the fixed page bound")
        elif query is not None:
            raise Denied("metadata read does not accept query parameters")
        url = f"{API_BASE}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Cache-Control": "no-cache",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            method="GET",
        )

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(
                self, req: object, fp: object, code: int, msg: str,
                headers: object, newurl: str,
            ) -> None:
                return None

        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(request, timeout=15) as response:
                if (
                    response.status != 200
                    or response.geturl() != url
                    or response.headers.get_content_type() != "application/json"
                ):
                    raise Denied("GitHub read returned an unexpected response")
                length = response.headers.get("Content-Length")
                if length is not None and (
                    not length.isdecimal() or int(length) > API_LIMIT
                ):
                    raise Denied("GitHub response exceeds its byte limit")
                data = response.read(API_LIMIT + 1)
        except (OSError, urllib.error.URLError, urllib.error.HTTPError) as error:
            raise Denied("bounded GitHub read failed") from error
        return decode_object(data, API_LIMIT, "GitHub response")

    def read_file(self, path: str, revision: str, limit: int) -> bytes:
        if path not in {WORKFLOW_PATH, LOCK_PATH, DOCKERFILE_PATH}:
            raise Denied("GitHub file path is not allowlisted")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise Denied("GitHub file revision is malformed")
        encoded_path = urllib.parse.quote(path, safe="/")
        value = self.get(
            f"repos/{REPOSITORY}/contents/{encoded_path}", {"ref": revision}
        )
        content = value.get("content")
        blob_sha = value.get("sha")
        if (
            value.get("type") != "file" or value.get("path") != path
            or value.get("encoding") != "base64"
            or not isinstance(content, str)
            or not isinstance(blob_sha, str)
            or not re.fullmatch(r"[0-9a-f]{40}", blob_sha)
        ):
            raise Denied("GitHub Contents response identity is malformed")
        try:
            compact = re.sub(rb"[ \t\r\n]", b"", content.encode("ascii"))
            data = base64.b64decode(compact, validate=True)
        except (UnicodeEncodeError, ValueError) as error:
            raise Denied("GitHub Contents base64 is malformed") from error
        if (
            len(data) > limit
            or type(value.get("size")) is not int
            or value.get("size") != len(data)
            or git_blob_sha(data) != blob_sha
        ):
            raise Denied("GitHub Contents bytes fail size or blob identity")
        return data


def validate_lock(lock_bytes: bytes) -> None:
    lock = decode_object(lock_bytes, LOCK_LIMIT, "toolchain lock")
    packages = lock.get("packages")
    if (
        set(lock) != LOCK_KEYS
        or type(lock.get("schemaVersion")) is not int
        or lock.get("schemaVersion") != 1
        or lock.get("enabled") is not False
        or lock.get("platform") != "linux/amd64"
        or lock.get("baseImage") != BASE_IMAGE
        or lock.get("ubuntuSnapshot") != SNAPSHOT
        or lock.get("preparedImage") != ""
        or lock.get("provenanceSha256") != ""
        or lock.get("dockerfileSha256") != DOCKERFILE_SHA256
        or lock.get("engineVersion") != "28.0.4"
        or lock.get("engineApiVersion") != "1.48"
        or lock.get("engineLayout") != "moby-v28-root-container-id-v1"
        or not isinstance(packages, list) or len(packages) != 115
    ):
        raise Denied("build-input lock is not the exact closed disabled schema")
    required = {"name", "version", "sha256"}
    names: list[str] = []
    for package in packages:
        if (
            not isinstance(package, dict) or set(package) != required
            or not isinstance(package.get("name"), str)
            or not isinstance(package.get("version"), str)
            or not isinstance(package.get("sha256"), str)
            or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package["name"])
            or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", package["version"])
            or not re.fullmatch(r"[0-9a-f]{64}", package["sha256"])
        ):
            raise Denied("build-input package lock entry is malformed")
        names.append(package["name"])
    if names != sorted(set(names)) or not REQUIRED_PACKAGES <= set(names):
        raise Denied("build-input package closure is incomplete or noncanonical")


def validate_dockerfile(dockerfile_bytes: bytes) -> None:
    try:
        dockerfile = dockerfile_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Denied("build-input Dockerfile is not UTF-8") from error
    commands = list(re.finditer(r"\bapt-get\b[^;]*", dockerfile))
    snapshot = dockerfile.find("Snapshot: ${UBUNTU_SNAPSHOT}")
    lock_check = dockerfile.find(
        "cmp --silent /tmp/retention-locked-pins.tsv /tmp/retention-package-pins.tsv"
    )
    archive_check = dockerfile.find(
        '[[ "$actual_sha256" == "$expected_sha256" ]]'
    )
    download = dockerfile.find("--download-only")
    install = dockerfile.find("--no-download")
    forbidden = (
        "[trusted=yes]", "AllowUnauthenticated", "--allow-unauthenticated",
        "--allow-insecure-repositories", "Acquire::https::Verify-Peer=false",
        "Acquire::https::Verify-Host=false", "Acquire::Check-Valid-Until=false",
    )
    if (
        len(commands) < 4 or snapshot < 0 or lock_check < 0 or archive_check < 0
        or snapshot > commands[0].start()
        or "update" not in commands[0].group()
        or "--download-only" not in commands[1].group()
        or "--no-download" not in commands[2].group()
        or not lock_check < commands[0].start() < download < archive_check < install
        or any(token in dockerfile for token in forbidden)
    ):
        raise Denied("Dockerfile does not authenticate locked packages before install")


def derive_build_args(lock_path: Path, dockerfile_path: Path) -> list[str]:
    lock_bytes = read_regular(lock_path, LOCK_LIMIT)
    dockerfile_bytes = read_regular(dockerfile_path, DOCKERFILE_LIMIT)
    if (
        hashlib.sha256(lock_bytes).hexdigest() != LOCK_SHA256
        or hashlib.sha256(dockerfile_bytes).hexdigest() != DOCKERFILE_SHA256
    ):
        raise Denied("materialized build inputs differ from reviewed pins")
    validate_lock(lock_bytes)
    validate_dockerfile(dockerfile_bytes)
    lock = decode_object(lock_bytes, LOCK_LIMIT, "toolchain lock")
    packages = lock["packages"]
    package_array = json.dumps(
        packages, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    package_pins = "".join(
        f"{package['name']}\t{package['version']}\t{package['sha256']}\n"
        for package in packages
    ).encode("ascii")
    return [
        f"UBUNTU_BASE_IMAGE={BASE_IMAGE}",
        "UBUNTU_SNAPSHOT=20260918T000000Z",
        f"PACKAGE_LOCK_BASE64={base64.b64encode(package_array).decode('ascii')}",
        f"PACKAGE_LOCK_SHA256={hashlib.sha256(package_array).hexdigest()}",
        f"PACKAGE_PINS_BASE64={base64.b64encode(package_pins).decode('ascii')}",
        f"PACKAGE_PINS_SHA256={hashlib.sha256(package_pins).hexdigest()}",
        f"DOCKERFILE_SHA256={DOCKERFILE_SHA256}",
    ]


def _master_sha(reader: GitHubReader) -> str:
    value = reader.get(f"repos/{REPOSITORY}/git/ref/heads/master")
    target = value.get("object")
    if (
        not isinstance(target, dict) or target.get("type") != "commit"
        or not isinstance(target.get("sha"), str)
        or not re.fullmatch(r"[0-9a-f]{40}", target["sha"])
    ):
        raise Denied("master ref response is malformed")
    return target["sha"]


def verify_repository_identity(reader: GitHubReader) -> None:
    repository = reader.get(f"repos/{REPOSITORY}")
    if (
        type(repository.get("id")) is not int
        or repository.get("id") != REPOSITORY_ID
        or repository.get("full_name") != REPOSITORY
        or repository.get("default_branch") != "master"
    ):
        raise Denied("repository identity or default branch differs")


def verify_successful_run(
    run: dict[str, object],
    *,
    run_id: str,
    commit_sha: str,
    branch: str,
    workflow_path: str,
    event: str,
) -> None:
    repository = run.get("repository")
    if (
        not isinstance(repository, dict)
        or type(repository.get("id")) is not int
        or repository.get("id") != REPOSITORY_ID
        or repository.get("full_name") != REPOSITORY
        or type(run.get("id")) is not int
        or run.get("id") != int(run_id)
        or run.get("head_sha") != commit_sha
        or run.get("head_branch") != branch
        or run.get("path") != workflow_path
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("event") != event
        or type(run.get("run_attempt")) is not int
        or run.get("run_attempt") != 1
    ):
        raise Denied("exact-head successful CI run identity differs")


def has_manual_only_trigger(workflow_bytes: bytes) -> bool:
    try:
        source = workflow_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Denied("publisher workflow is not UTF-8") from error
    match = re.search(r"(?m)^on:\n((?:[ \t].*\n)+)", source)
    if match is None:
        return False
    events = re.findall(r"(?m)^  ([A-Za-z0-9_-]+):\s*$", match.group(1))
    inputs = re.findall(r"(?m)^      ([A-Za-z0-9_-]+):\s*$", match.group(1))
    return events == ["workflow_dispatch"] and inputs == ["expected_workflow_sha"]


def preflight(
    reader: GitHubReader,
    *,
    approved_workflow_sha: str,
    workflow_ci_run_id: str,
    local_workflow: bytes,
) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", approved_workflow_sha):
        raise Denied("separately approved W assertion is malformed")
    if not re.fullmatch(r"[1-9][0-9]*", workflow_ci_run_id):
        raise Denied("publisher workflow CI run ID is malformed")
    verify_repository_identity(reader)
    if _master_sha(reader) != approved_workflow_sha:
        raise Denied("current protected master differs from approved W")
    workflow_bytes = reader.read_file(
        WORKFLOW_PATH, approved_workflow_sha, API_LIMIT
    )
    if workflow_bytes != local_workflow or not has_manual_only_trigger(workflow_bytes):
        raise Denied("registered workflow bytes or manual-only trigger differs")
    workflows = reader.get(
        f"repos/{REPOSITORY}/actions/workflows", {"per_page": "100"}
    )
    workflow_list = workflows.get("workflows")
    registered = [
        item for item in workflow_list
        if isinstance(item, dict) and item.get("path") == WORKFLOW_PATH
    ] if isinstance(workflow_list, list) else []
    if len(registered) != 1 or registered[0].get("state") != "active":
        raise Denied("publisher workflow is not registered exactly once and active")
    workflow_ci = reader.get(
        f"repos/{REPOSITORY}/actions/runs/{workflow_ci_run_id}"
    )
    verify_successful_run(
        workflow_ci,
        run_id=workflow_ci_run_id,
        commit_sha=approved_workflow_sha,
        branch="master",
        workflow_path=".github/workflows/validate-retention-tools-publisher.yml",
        event="push",
    )
    build_ci = reader.get(
        f"repos/{REPOSITORY}/actions/runs/{BUILD_CI_RUN_ID}"
    )
    verify_successful_run(
        build_ci,
        run_id=BUILD_CI_RUN_ID,
        commit_sha=BUILD_INPUT_SHA,
        branch="MEE2-63",
        workflow_path=".github/workflows/ci.yml",
        event="pull_request",
    )
    lock_bytes = reader.read_file(LOCK_PATH, BUILD_INPUT_SHA, LOCK_LIMIT)
    dockerfile_bytes = reader.read_file(
        DOCKERFILE_PATH, BUILD_INPUT_SHA, DOCKERFILE_LIMIT
    )
    if (
        hashlib.sha256(lock_bytes).hexdigest() != LOCK_SHA256
        or hashlib.sha256(dockerfile_bytes).hexdigest() != DOCKERFILE_SHA256
    ):
        raise Denied("B Dockerfile or lock differs from approved input hashes")
    validate_lock(lock_bytes)
    validate_dockerfile(dockerfile_bytes)
    if _master_sha(reader) != approved_workflow_sha:
        raise Denied("master moved during operator-side preflight")
    verify_repository_identity(reader)
    return {
        "repository": REPOSITORY,
        "repositoryId": str(REPOSITORY_ID),
        "workflowPath": WORKFLOW_PATH,
        "workflowSha": approved_workflow_sha,
        "workflowCiRunId": workflow_ci_run_id,
        "buildInputSha": BUILD_INPUT_SHA,
        "buildCiRunId": BUILD_CI_RUN_ID,
        "toolchainLockSha256": LOCK_SHA256,
        "dockerfileSha256": DOCKERFILE_SHA256,
        "planSha256": PLAN_SHA256,
        "publicImage": "ghcr.io/nickolaymamonov/retention-proof-tools",
        "readOnlyChecks": "passed",
        "operatorApproval": "external exact-revision approval must be verified separately",
    }


def admit(
    reader: GitHubReader,
    *,
    workflow_sha: str,
    local_workflow: bytes,
    event: str,
    ref: str,
    sha: str,
    attempt: str,
    run_id: str,
    require_actions_read: bool = True,
) -> tuple[bytes, bytes]:
    verify_repository_identity(reader)
    if (
        event != "workflow_dispatch" or ref != "refs/heads/master"
        or sha != workflow_sha or attempt != "1"
        or not re.fullmatch(r"[0-9a-f]{40}", workflow_sha)
        or not re.fullmatch(r"[1-9][0-9]*", run_id)
    ):
        raise Denied("publisher run is not attempt 1 on the exact master ref")
    if _master_sha(reader) != workflow_sha:
        raise Denied("master no longer points at this publisher revision")
    remote_workflow = reader.read_file(WORKFLOW_PATH, workflow_sha, API_LIMIT)
    if (
        remote_workflow != local_workflow
        or not has_manual_only_trigger(remote_workflow)
    ):
        raise Denied("trusted workflow checkout differs from master bytes")
    if require_actions_read:
        run = reader.get(f"repos/{REPOSITORY}/actions/runs/{run_id}")
        run_repo = run.get("repository")
        if (
            not isinstance(run_repo, dict)
            or type(run_repo.get("id")) is not int
            or run_repo.get("id") != REPOSITORY_ID
            or run_repo.get("full_name") != REPOSITORY
            or type(run.get("id")) is not int
            or run.get("id") != int(run_id)
            or run.get("event") != "workflow_dispatch"
            or run.get("head_branch") != "master"
            or run.get("head_sha") != workflow_sha
            or type(run.get("run_attempt")) is not int
            or run.get("run_attempt") != 1
            or run.get("path") != WORKFLOW_PATH + "@master"
        ):
            raise Denied("Actions run identity differs from trusted workflow context")
    try:
        workflow_text = remote_workflow.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Denied("workflow bytes are not UTF-8") from error
    pins: dict[str, str] = {}
    for name, pattern in PIN_PATTERNS.items():
        matches = pattern.findall(workflow_text)
        if len(matches) != 1:
            raise Denied(f"workflow does not contain exactly one pinned {name}")
        pins[name] = matches[0]
    if (
        pins["BUILD_INPUT_SHA"] != BUILD_INPUT_SHA
        or pins["BUILD_CI_RUN_ID"] != BUILD_CI_RUN_ID
        or pins["TOOLCHAIN_LOCK_SHA256"] != LOCK_SHA256
        or pins["TOOLCHAIN_DOCKERFILE_SHA256"] != DOCKERFILE_SHA256
    ):
        raise Denied("publisher workflow inputs differ from reviewed constants")
    if require_actions_read:
        ci_run = reader.get(f"repos/{REPOSITORY}/actions/runs/{BUILD_CI_RUN_ID}")
        ci_repository = ci_run.get("repository")
        if (
            not isinstance(ci_repository, dict)
            or type(ci_repository.get("id")) is not int
            or ci_repository.get("id") != REPOSITORY_ID
            or ci_repository.get("full_name") != REPOSITORY
            or type(ci_run.get("id")) is not int
            or ci_run.get("id") != int(BUILD_CI_RUN_ID)
            or ci_run.get("head_sha") != BUILD_INPUT_SHA
            or ci_run.get("head_branch") != "MEE2-63"
            or ci_run.get("path") != ".github/workflows/ci.yml"
            or ci_run.get("status") != "completed"
            or ci_run.get("conclusion") != "success"
            or ci_run.get("event") != "pull_request"
            or type(ci_run.get("run_attempt")) is not int
            or ci_run.get("run_attempt") != 1
        ):
            raise Denied("build-input exact-head Ubuntu CI is not successful")
    lock_bytes = reader.read_file(LOCK_PATH, BUILD_INPUT_SHA, LOCK_LIMIT)
    dockerfile_bytes = reader.read_file(DOCKERFILE_PATH, BUILD_INPUT_SHA, DOCKERFILE_LIMIT)
    if (
        hashlib.sha256(lock_bytes).hexdigest() != LOCK_SHA256
        or hashlib.sha256(dockerfile_bytes).hexdigest() != DOCKERFILE_SHA256
    ):
        raise Denied("build-input file hash differs from reviewed pins")
    validate_lock(lock_bytes)
    validate_dockerfile(dockerfile_bytes)
    if _master_sha(reader) != workflow_sha:
        raise Denied("master moved during exact-revision admission")
    verify_repository_identity(reader)
    return lock_bytes, dockerfile_bytes


def read_regular(path: Path, limit: int) -> bytes:
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise Denied("publisher workflow is not a bounded regular file")
        with path.open("rb") as source:
            opened = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                raise Denied("publisher workflow identity changed while opening")
            data = source.read(limit + 1)
            opened_after = os.fstat(source.fileno())
        after = path.lstat()
    except OSError as error:
        raise Denied("publisher workflow is unavailable") from error
    if (
        len(data) > limit
        or (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
        ) != (
            opened_after.st_dev, opened_after.st_ino,
            opened_after.st_size, opened_after.st_mtime_ns,
        )
        or (
            before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns
        ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    ):
        raise Denied("publisher workflow changed while reading")
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--derive-build-args", action="store_true")
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--approved-workflow-sha")
    parser.add_argument("--workflow-ci-run-id")
    parser.add_argument("--lock", type=Path)
    parser.add_argument("--dockerfile", type=Path)
    parser.add_argument("--workflow-file", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--workflow-sha")
    parser.add_argument("--event")
    parser.add_argument("--ref")
    parser.add_argument("--sha")
    parser.add_argument("--attempt")
    parser.add_argument("--run-id")
    parser.add_argument("--recheck-only", action="store_true")
    parser.add_argument("--repository")
    parser.add_argument("--repository-id", type=int)
    args = parser.parse_args()
    try:
        if args.preflight:
            if (
                args.workflow_file is None or args.repository is None
                or args.repository_id is None
                or args.approved_workflow_sha is None
                or args.workflow_ci_run_id is None
            ):
                raise Denied("operator-side preflight inputs are incomplete")
            workflow = read_regular(args.workflow_file, API_LIMIT)
            reader = GitHubReader(
                args.repository, args.repository_id, os.environ.get("GH_TOKEN", "")
            )
            print(json.dumps(
                preflight(
                    reader,
                    approved_workflow_sha=args.approved_workflow_sha,
                    workflow_ci_run_id=args.workflow_ci_run_id,
                    local_workflow=workflow,
                ),
                sort_keys=True,
                separators=(",", ":"),
            ))
            return 0
        if args.approved_workflow_sha is not None or args.workflow_ci_run_id is not None:
            raise Denied("preflight approvals are accepted only in preflight mode")
        if args.derive_build_args:
            if args.lock is None or args.dockerfile is None:
                raise Denied("build-argument derivation needs exact admitted files")
            for item in derive_build_args(args.lock, args.dockerfile):
                print(item)
            return 0
        if args.lock is not None or args.dockerfile is not None:
            raise Denied("build inputs are accepted only in derivation mode")
        if (
            args.workflow_file is None or args.output_dir is None
            or args.workflow_sha is None or args.event is None or args.ref is None
            or args.sha is None or args.attempt is None or args.run_id is None
            or args.repository is None or args.repository_id is None
        ):
            raise Denied("publisher admission context is incomplete")
        workflow = read_regular(args.workflow_file, API_LIMIT)
        reader = GitHubReader(
            args.repository, args.repository_id, os.environ.get("GH_TOKEN", "")
        )
        lock_bytes, dockerfile_bytes = admit(
            reader,
            workflow_sha=args.workflow_sha,
            local_workflow=workflow,
            event=args.event,
            ref=args.ref,
            sha=args.sha,
            attempt=args.attempt,
            run_id=args.run_id,
            require_actions_read=not args.recheck_only,
        )
        output_dir = args.output_dir
        output_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        (output_dir / "toolchain.lock.json").write_bytes(lock_bytes)
        (output_dir / "Dockerfile").write_bytes(dockerfile_bytes)
    except (Denied, OSError, ValueError) as error:
        print(f"RETENTION_TOOLS_PUBLISHER_DENIED: {error}", file=sys.stderr)
        return 1
    print("exact W/B admission passed; build inputs materialized outside checkout")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
