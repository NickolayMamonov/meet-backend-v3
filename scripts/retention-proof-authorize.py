#!/usr/bin/env python3
"""Fail-closed tuple and current-run authorization for the retention proof."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "retention_proof_registration",
    Path(__file__).with_name("retention-proof-registration.py"),
)
assert spec and spec.loader
authority = importlib.util.module_from_spec(spec)
spec.loader.exec_module(authority)

HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
MAX_TREE_INVENTORY = 16 * 1024 * 1024
SUPERVISOR_FILE = "scripts/retention-proof-supervisor.py"
LAUNCHER_BUNDLE_FILES = {
    "scripts/run-test-vps-retention-proof.sh": "100755",
    "scripts/retention-proof-registration.py": "100644",
    "scripts/retention-proof-authorize.py": "100644",
    "scripts/retention-proof-host-metadata.py": "100644",
}


def fail(message: str) -> None:
    raise authority.Denied(message)


def local_file(path: Path, maximum: int = 64 * 1024) -> bytes:
    if path.is_symlink() or not path.is_file():
        fail("required source artifact is not a regular file")
    try:
        with path.open("rb") as stream:
            content = stream.read(maximum + 1)
    except OSError as error:
        raise authority.Denied("required source artifact is unavailable") from error
    if len(content) > maximum:
        fail("required source artifact exceeds its bound")
    return content


def git(
    checkout: Path, *args: str, maximum: int = MAX_TREE_INVENTORY
) -> bytes:
    environment = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GCM_INTERACTIVE": "Never",
    }
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=30,
            env=environment,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise authority.Denied("bounded local Git provenance check failed") from error
    if len(result.stdout) > maximum:
        fail("local Git provenance response exceeds its bound")
    return result.stdout


def source_inventory(checkout: Path, source_sha: str) -> str:
    if not HEX40.fullmatch(source_sha) or not checkout.is_dir() or checkout.is_symlink():
        fail("exact source checkout is unavailable")
    head = git(checkout, "rev-parse", "HEAD", maximum=128).decode().strip()
    if head != source_sha:
        fail("source checkout does not match the requested commit")
    status = git(
        checkout,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
        maximum=1024 * 1024,
    )
    if status:
        fail("source checkout is dirty")
    records = git(
        checkout,
        "ls-tree",
        "-rz",
        "--full-tree",
        source_sha,
        maximum=MAX_TREE_INVENTORY,
    )
    entries: list[tuple[bytes, bytes]] = []
    seen: set[bytes] = set()
    for record in records.split(b"\0"):
        if not record:
            continue
        metadata, separator, path = record.partition(b"\t")
        fields = metadata.split(b" ")
        if not separator or len(fields) != 3:
            fail("source tree entry is malformed")
        mode, kind, object_id = fields
        if mode not in (b"100644", b"100755") or kind != b"blob":
            fail("source tree contains a symlink, submodule, or unsupported object")
        if not HEX40.fullmatch(object_id.decode("ascii", errors="ignore")):
            fail("source tree object identity is malformed")
        if not path or path.startswith(b"/") or b"\0" in path:
            fail("source tree path is invalid")
        components = path.split(b"/")
        if any(component in (b"", b".", b"..") for component in components):
            fail("source tree path is not canonical")
        if path in seen:
            fail("source tree has duplicate paths")
        seen.add(path)
        entries.append((path, record))
    if not entries:
        fail("source tree inventory is empty")
    inventory = b"".join(record + b"\0" for _, record in sorted(entries))
    return hashlib.sha256(inventory).hexdigest()


def trusted_tooling(
    reader: object, registration_identity: dict[str, object], actual_workflow_sha: str
) -> tuple[str, str]:
    registration = registration_identity["registration"]
    if registration_identity["commit"] != actual_workflow_sha:
        fail("workflow SHA differs from the live registration commit")
    trusted_revision = registration["workflowRevision"]
    if not HEX40.fullmatch(trusted_revision):
        fail("trusted tooling revision is invalid")
    workflow_path = registration["workflowPath"]
    current_workflow, current_workflow_identity = reader.read_file_at(
        actual_workflow_sha, workflow_path
    )
    trusted_workflow, trusted_workflow_identity = reader.read_file_at(
        trusted_revision, workflow_path
    )
    if current_workflow != trusted_workflow:
        fail("workflow bytes differ from the registered reviewed revision")
    if (
        current_workflow_identity["mode"] != "100644"
        or trusted_workflow_identity["mode"] != "100644"
    ):
        fail("registered workflow mode differs")
    launcher_bundle = hashlib.sha256()
    for path, expected_mode in sorted(LAUNCHER_BUNDLE_FILES.items()):
        content, identity = reader.read_file_at(trusted_revision, path)
        if identity["mode"] != expected_mode:
            fail("registered launcher bundle mode differs")
        launcher_bundle.update(path.encode("utf-8"))
        launcher_bundle.update(b"\0")
        launcher_bundle.update(hashlib.sha256(content).hexdigest().encode("ascii"))
        launcher_bundle.update(b"\0")
    launcher_digest = launcher_bundle.hexdigest()
    supervisor, supervisor_identity = reader.read_file_at(
        trusted_revision, SUPERVISOR_FILE
    )
    if supervisor_identity["mode"] != "100644":
        fail("registered supervisor mode differs")
    supervisor_digest = hashlib.sha256(supervisor).hexdigest()
    if (
        launcher_digest != registration["launcherSha256"]
        or supervisor_digest != registration["supervisorSha256"]
    ):
        fail("registered launcher or supervisor digest differs")
    return launcher_digest, supervisor_digest


def authorize(args: argparse.Namespace) -> dict[str, object]:
    environment = os.environ
    required = (
        "GITHUB_REPOSITORY",
        "GITHUB_REPOSITORY_ID",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_SHA",
        "GITHUB_REF",
        "GITHUB_TOKEN",
    )
    if any(not environment.get(key) for key in required):
        fail("required trusted GitHub run context is incomplete")
    if environment.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        fail("event is not a manual workflow dispatch")
    if environment["GITHUB_REF"] != "refs/heads/master":
        fail("run is not bound to protected master")
    if environment["GITHUB_RUN_ATTEMPT"] != "1":
        fail("only a fresh attempt-1 run is admissible")
    repository_id = int(environment["GITHUB_REPOSITORY_ID"])
    run_id = int(environment["GITHUB_RUN_ID"])
    actual_workflow_sha = environment["GITHUB_SHA"]
    source_sha = args.source_sha
    if not HEX40.fullmatch(source_sha):
        fail("source SHA is malformed")
    if args.plan_sha256 != authority.PLAN_SHA256:
        fail("canonical plan identity differs")
    image_digest = args.image_digest
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_digest):
        fail("immutable image digest is malformed")

    requested_checkout = Path(args.source_checkout)
    if requested_checkout.is_symlink() or not requested_checkout.is_dir():
        fail("source checkout path is not a trusted directory")
    checkout = requested_checkout.resolve(strict=True)
    lock_path = checkout / "scripts/fixtures/retention-proof/toolchain.lock.json"
    lock_bytes = local_file(lock_path, authority.MAX_REGISTRATION)
    lock = authority.validate_toolchain_lock(
        lock_bytes, expected_image_digest=image_digest
    )
    dockerfile = local_file(
        checkout / "scripts/fixtures/retention-proof/Dockerfile"
    )
    if hashlib.sha256(dockerfile).hexdigest() != lock["dockerfileSha256"]:
        fail("Dockerfile differs from the reviewed toolchain lock")
    inventory_sha256 = source_inventory(checkout, source_sha)
    fixture_sha256 = hashlib.sha256(
        local_file(checkout / "scripts/test-test-vps-retention.sh")
    ).hexdigest()
    helper_sha256 = hashlib.sha256(
        local_file(
            checkout / "scripts/test-vps-provider-credential.py",
            maximum=8 * 1024 * 1024,
        )
    ).hexdigest()
    toolchain_sha256 = hashlib.sha256(lock_bytes).hexdigest()

    reader = authority.GitHubReader(
        environment["GITHUB_REPOSITORY"],
        environment["GITHUB_TOKEN"],
        repository_id,
    )
    expected_registration = None
    if args.expected_registration:
        parsed = authority.decode_json(args.expected_registration.encode())
        if not isinstance(parsed, dict):
            fail("expected registration identity is malformed")
        expected_registration = parsed
    registration_identity = reader.read(expected_registration)
    registration = registration_identity["registration"]
    if registration["planSha256"] != authority.PLAN_SHA256:
        fail("live registration approves a different plan")
    launcher_digest, supervisor_digest = trusted_tooling(
        reader, registration_identity, actual_workflow_sha
    )
    current = reader.current_run_authority(run_id, source_sha)
    authority.validate_repository_metadata(
        current["repository"], repository_id=repository_id
    )
    actor_id, triggering_actor_id = authority.validate_run_metadata(
        current["run"],
        repository_id=repository_id,
        run_id=run_id,
        attempt=int(environment["GITHUB_RUN_ATTEMPT"]),
        run_sha=actual_workflow_sha,
        run_ref=environment["GITHUB_REF"],
        workflow_path=registration["workflowPath"],
    )
    if (
        actor_id != triggering_actor_id
        or registration["environmentId"] < 1
    ):
        fail("dispatch actor or protected environment identity is invalid")
    authority.validate_environment(
        current["environment"],
        environment_id=registration["environmentId"],
        environment_name=registration["environmentName"],
        authorized_reviewer_ids=registration["authorizedReviewerIds"],
        branch_policies=current["branchPolicies"],
    )
    ci_identity = authority.validate_exact_ci(
        current["ci"], source_sha=source_sha, repository=environment["GITHUB_REPOSITORY"]
    )
    tuple_value, tuple_bytes, tuple_sha256 = authority.build_attempt_tuple(
        registration_identity,
        run_id=run_id,
        source_sha=source_sha,
        actual_workflow_sha=actual_workflow_sha,
        plan_sha256=args.plan_sha256,
        image_digest=image_digest,
        fixture_sha256=fixture_sha256,
        helper_sha256=helper_sha256,
        toolchain_sha256=toolchain_sha256,
        source_inventory_sha256=inventory_sha256,
        ci_identity=ci_identity,
    )
    if (
        tuple_value["launcherSha256"] != launcher_digest
        or tuple_value["supervisorSha256"] != supervisor_digest
    ):
        fail("trusted tooling tuple differs from registration")
    if args.checkpoint != "admission":
        if not args.expected_tuple_sha256 or not HEX64.fullmatch(
            args.expected_tuple_sha256
        ):
            fail("fresh tuple digest from admission is required")
        if tuple_sha256 != args.expected_tuple_sha256:
            fail("approved tuple drifted")
        authority.validate_approval_history(
            current["approvals"],
            run_id=run_id,
            tuple_sha256=tuple_sha256,
            environment_id=registration["environmentId"],
            environment_name=registration["environmentName"],
            authorized_reviewer_ids=registration["authorizedReviewerIds"],
            triggering_actor_id=triggering_actor_id,
        )
    return {
        "checkpoint": args.checkpoint,
        "tuple": tuple_value,
        "tupleBytes": tuple_bytes.decode("utf-8"),
        "tupleSha256": tuple_sha256,
        "registration": registration_identity,
        "ciRunId": ci_identity["id"],
        "reviewerApproved": args.checkpoint != "admission",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint",
        choices=("admission", "job", "pre-create", "pre-start", "barrier"),
        required=True,
    )
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--image-digest", required=True)
    parser.add_argument("--source-checkout", required=True)
    parser.add_argument("--expected-registration")
    parser.add_argument("--expected-tuple-sha256")
    args = parser.parse_args()
    try:
        print(json.dumps(authorize(args), sort_keys=True, separators=(",", ":")))
    except (
        authority.Denied,
        OSError,
        TypeError,
        ValueError,
        KeyError,
        json.JSONDecodeError,
    ) as error:
        print(f"RETENTION_PROOF_DENIED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
