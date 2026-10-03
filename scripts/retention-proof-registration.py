#!/usr/bin/env python3
"""Read the fixed protected-master retention registration without caching."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REGISTRATION_PATH = ".github/retention-proof-registration.json"
REF_PATH = "refs/heads/master"
MAX_RESPONSE = 64 * 1024
MAX_REGISTRATION = 16 * 1024
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REGISTRATION_KEYS = {
    "schemaVersion",
    "enabled",
    "planSha256",
    "workflowPath",
    "workflowRevision",
    "environmentName",
    "environmentId",
    "authorizedReviewerIds",
    "launcherSha256",
    "supervisorSha256",
}
REGISTRATION_IDENTITY_KEYS = {
    "repositoryId",
    "repository",
    "ref",
    "path",
    "commit",
    "rootTree",
    "tree",
    "blob",
    "contentSha256",
    "registration",
}
TUPLE_KEYS = {
    "schemaVersion",
    "repositoryId",
    "runId",
    "attempt",
    "environmentId",
    "sourceSha",
    "planSha256",
    "actualWorkflowSha",
    "trustedWorkflowRevision",
    "launcherRevision",
    "launcherSha256",
    "supervisorSha256",
    "fixtureSha256",
    "helperSha256",
    "toolchainSha256",
    "sourceInventorySha256",
    "imageDigest",
    "registration",
    "ciRunId",
    "ciHeadSha",
}
TOOLCHAIN_KEYS = {
    "schemaVersion",
    "enabled",
    "platform",
    "baseImage",
    "ubuntuSnapshot",
    "packages",
    "dockerfileSha256",
    "preparedImage",
    "provenanceSha256",
    "engineVersion",
    "engineApiVersion",
    "engineLayout",
}
PACKAGE_KEYS = {"name", "version", "sha256"}
REQUIRED_PACKAGES = {
    "acl",
    "bash",
    "coreutils",
    "findutils",
    "gawk",
    "grep",
    "jq",
    "python3",
    "sed",
    "tar",
    "util-linux",
}
PLAN_SHA256 = "a7cf15f7bf1ff2860a3e3716ee986f0543bedac339469756a74ed8830047ce2a"


class Denied(Exception):
    pass


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise Denied("duplicate JSON key")
        result[key] = value
    return result


def decode_json(data: bytes) -> object:
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied("malformed JSON") from error


def validate_registration(data: bytes) -> dict[str, object]:
    if len(data) > MAX_REGISTRATION:
        raise Denied("registration exceeds 16 KiB")
    value = decode_json(data)
    if not isinstance(value, dict) or set(value) != REGISTRATION_KEYS:
        raise Denied("registration schema is not closed")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise Denied("unsupported registration schema")
    if type(value["enabled"]) is not bool:
        raise Denied("enabled must be boolean")
    if not isinstance(value["planSha256"], str) or not HEX64.fullmatch(value["planSha256"]):
        raise Denied("invalid plan digest")
    if value["workflowPath"] != ".github/workflows/prove-test-vps-retention.yml":
        raise Denied("untrusted workflow path")
    if not isinstance(value["workflowRevision"], str) or not HEX40.fullmatch(value["workflowRevision"]):
        raise Denied("invalid workflow revision")
    if value["environmentName"] != "retention-fixture-proof":
        raise Denied("untrusted environment name")
    if type(value["environmentId"]) is not int or value["environmentId"] < 0:
        raise Denied("invalid environment ID")
    reviewers = value["authorizedReviewerIds"]
    if (
        not isinstance(reviewers, list)
        or any(type(reviewer) is not int or reviewer < 1 for reviewer in reviewers)
        or len(reviewers) != len(set(reviewers))
    ):
        raise Denied("invalid reviewer IDs")
    for key in ("launcherSha256", "supervisorSha256"):
        if not isinstance(value[key], str) or not HEX64.fullmatch(value[key]):
            raise Denied(f"invalid {key}")
    if value["enabled"] and (
        value["environmentId"] < 1
        or not reviewers
        or value["workflowRevision"] == "0" * 40
        or value["launcherSha256"] == "0" * 64
        or value["supervisorSha256"] == "0" * 64
    ):
        raise Denied("enabled registration is incomplete")
    return value


def validate_toolchain_lock(
    data: bytes, *, expected_image_digest: str
) -> dict[str, object]:
    if len(data) > MAX_REGISTRATION:
        raise Denied("toolchain lock exceeds 16 KiB")
    value = decode_json(data)
    if not isinstance(value, dict) or set(value) != TOOLCHAIN_KEYS:
        raise Denied("toolchain lock schema is not closed")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise Denied("unsupported toolchain lock schema")
    if value["enabled"] is not True:
        raise Denied("toolchain image is disabled")
    if value["platform"] != "linux/amd64":
        raise Denied("toolchain platform is not linux/amd64")
    if not isinstance(value["baseImage"], str) or not re.fullmatch(
        r"ubuntu:24\.04@sha256:[0-9a-f]{64}", value["baseImage"]
    ):
        raise Denied("Ubuntu base image digest is not pinned")
    if not isinstance(value["ubuntuSnapshot"], str) or not re.fullmatch(
        r"https://snapshot\.ubuntu\.com/ubuntu/[A-Za-z0-9./-]+",
        value["ubuntuSnapshot"],
    ):
        raise Denied("authenticated Ubuntu snapshot is missing")
    packages = value["packages"]
    if not isinstance(packages, list) or not packages or len(packages) > 1024:
        raise Denied("package closure is missing or oversized")
    names: list[str] = []
    for package in packages:
        if not isinstance(package, dict) or set(package) != PACKAGE_KEYS:
            raise Denied("package lock entry schema is not closed")
        if (
            not isinstance(package["name"], str)
            or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]*", package["name"])
            or not isinstance(package["version"], str)
            or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", package["version"])
            or not isinstance(package["sha256"], str)
            or not HEX64.fullmatch(package["sha256"])
        ):
            raise Denied("invalid locked package identity")
        names.append(package["name"])
    if names != sorted(set(names)) or not REQUIRED_PACKAGES <= set(names):
        raise Denied("package closure is incomplete or noncanonical")
    for key in ("dockerfileSha256", "provenanceSha256"):
        if not isinstance(value[key], str) or not HEX64.fullmatch(value[key]):
            raise Denied(f"missing immutable toolchain evidence: {key}")
    if not isinstance(value["preparedImage"], str) or not re.fullmatch(
        r"sha256:[0-9a-f]{64}", value["preparedImage"]
    ):
        raise Denied("prepared image digest is missing")
    if value["preparedImage"] != expected_image_digest:
        raise Denied("prepared image differs from dispatch")
    if not isinstance(value["engineVersion"], str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", value["engineVersion"]
    ):
        raise Denied("Engine version is not pinned")
    if not isinstance(value["engineApiVersion"], str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+", value["engineApiVersion"]
    ):
        raise Denied("Engine API version is not pinned")
    if not isinstance(value["engineLayout"], str) or not re.fullmatch(
        r"[a-z0-9][a-z0-9._-]{0,127}", value["engineLayout"]
    ):
        raise Denied("Engine mount layout is not pinned")
    return value


def canonical_tuple(value: object) -> tuple[bytes, str]:
    if not isinstance(value, dict) or set(value) != TUPLE_KEYS:
        raise Denied("approval tuple schema is not closed")
    for key in ("schemaVersion",):
        if type(value[key]) is not int or value[key] != 1:
            raise Denied("unsupported approval tuple schema")
    for key in ("repositoryId", "runId", "environmentId", "ciRunId"):
        if type(value[key]) is not int or value[key] < 1:
            raise Denied(f"invalid tuple integer: {key}")
    if type(value["attempt"]) is not int or value["attempt"] != 1:
        raise Denied("only attempt 1 is admissible")
    for key in (
        "sourceSha",
        "actualWorkflowSha",
        "trustedWorkflowRevision",
        "launcherRevision",
        "ciHeadSha",
    ):
        if not isinstance(value[key], str) or not HEX40.fullmatch(value[key]):
            raise Denied(f"invalid tuple SHA: {key}")
    for key in (
        "planSha256",
        "launcherSha256",
        "supervisorSha256",
        "fixtureSha256",
        "helperSha256",
        "toolchainSha256",
        "sourceInventorySha256",
    ):
        if not isinstance(value[key], str) or not HEX64.fullmatch(value[key]):
            raise Denied(f"invalid tuple digest: {key}")
    if not isinstance(value["imageDigest"], str) or not re.fullmatch(
        r"sha256:[0-9a-f]{64}", value["imageDigest"]
    ):
        raise Denied("invalid immutable image digest")
    registration = value["registration"]
    if not isinstance(registration, dict):
        raise Denied("registration identity is malformed")
    if set(registration) != REGISTRATION_IDENTITY_KEYS:
        raise Denied("registration identity schema is not closed")
    record = registration["registration"]
    if not isinstance(record, dict):
        raise Denied("registration record is malformed")
    try:
        record_bytes = json.dumps(
            record, sort_keys=True, separators=(",", ":"), ensure_ascii=True
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise Denied("registration record is not canonical JSON") from error
    if (
        type(registration["repositoryId"]) is not int
        or registration["repositoryId"] < 1
        or not isinstance(registration["repository"], str)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", registration["repository"])
        or registration["ref"] != REF_PATH
        or registration["path"] != REGISTRATION_PATH
        or any(
            not isinstance(registration[key], str)
            or not HEX40.fullmatch(registration[key])
            for key in ("commit", "rootTree", "tree", "blob")
        )
        or not isinstance(registration["contentSha256"], str)
        or not HEX64.fullmatch(registration["contentSha256"])
        or record != validate_registration(record_bytes)
        or record["enabled"] is not True
    ):
        raise Denied("registration identity is invalid")
    if (
        registration["repositoryId"] != value["repositoryId"]
        or registration["commit"] != value["actualWorkflowSha"]
    ):
        raise Denied("registration identity does not match tuple")
    body = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return body, hashlib.sha256(body).hexdigest()


def validate_run_metadata(
    run: object,
    *,
    repository_id: int,
    run_id: int,
    attempt: int,
    run_sha: str,
    run_ref: str,
    workflow_path: str,
) -> tuple[int, int]:
    if not isinstance(run, dict):
        raise Denied("current workflow run metadata missing")
    if (
        type(run.get("id")) is not int
        or run["id"] != run_id
        or type(run.get("run_attempt")) is not int
        or run["run_attempt"] != 1
        or type(attempt) is not int
        or attempt != 1
        or run.get("event") != "workflow_dispatch"
        or run_ref != "refs/heads/master"
        or run.get("head_branch") != "master"
        or run.get("head_sha") != run_sha
    ):
        raise Denied("current workflow run identity mismatch")
    path = run.get("path")
    if path != f"{workflow_path}@master":
        raise Denied("current workflow path mismatch")
    repo = run.get("repository")
    if (
        not isinstance(repo, dict)
        or type(repo.get("id")) is not int
        or repo["id"] != repository_id
    ):
        raise Denied("current workflow repository mismatch")
    actor = run.get("actor")
    trigger = run.get("triggering_actor")
    if (
        not isinstance(actor, dict)
        or type(actor.get("id")) is not int
        or actor["id"] < 1
        or not isinstance(trigger, dict)
        or type(trigger.get("id")) is not int
        or trigger["id"] != actor["id"]
    ):
        raise Denied("dispatch actor identity is unresolved")
    return actor["id"], trigger["id"]


def validate_repository_metadata(value: object, *, repository_id: int) -> None:
    if (
        not isinstance(value, dict)
        or type(value.get("id")) is not int
        or value["id"] != repository_id
        or value.get("default_branch") != "master"
    ):
        raise Denied("repository identity or default branch differs")


def validate_exact_ci(
    value: object, *, source_sha: str, repository: str
) -> dict[str, int | str]:
    if (
        not isinstance(value, dict)
        or type(value.get("total_count")) is not int
        or value["total_count"] < 1
        or value["total_count"] > 100
        or not isinstance(value.get("workflow_runs"), list)
        or len(value["workflow_runs"]) != value["total_count"]
    ):
        raise Denied("exact-head CI history is incomplete")
    valid = []
    for run in value["workflow_runs"]:
        if not isinstance(run, dict):
            raise Denied("invalid CI workflow run")
        head_repo = run.get("head_repository")
        event = run.get("event")
        if event == "push":
            authorized_branch = run.get("head_branch") == "dev"
        elif event == "pull_request":
            pull_requests = run.get("pull_requests")
            authorized_branch = (
                isinstance(pull_requests, list)
                and len(pull_requests) == 1
                and isinstance(pull_requests[0], dict)
                and isinstance(pull_requests[0].get("base"), dict)
                and pull_requests[0]["base"].get("ref") == "dev"
                and isinstance(pull_requests[0].get("head"), dict)
                and pull_requests[0]["head"].get("sha") == source_sha
                and pull_requests[0]["head"].get("ref") == run.get("head_branch")
            )
        else:
            authorized_branch = False
        if (
            type(run.get("id")) is int
            and run["id"] > 0
            and type(run.get("run_number")) is int
            and run["run_number"] > 0
            and run.get("path") == ".github/workflows/ci.yml@dev"
            and authorized_branch
            and run.get("head_sha") == source_sha
            and run.get("status") == "completed"
            and run.get("conclusion") == "success"
            and isinstance(head_repo, dict)
            and head_repo.get("full_name") == repository
        ):
            valid.append(run)
    if not valid:
        raise Denied("successful exact-head ordinary CI is missing")
    highest = max(run["run_number"] for run in valid)
    latest = [run for run in valid if run["run_number"] == highest]
    if len(latest) != 1:
        raise Denied("exact-head CI run identity is ambiguous")
    return {"id": latest[0]["id"], "headSha": source_sha}


def build_attempt_tuple(
    registration_identity: dict[str, object],
    *,
    run_id: int,
    source_sha: str,
    actual_workflow_sha: str,
    plan_sha256: str,
    image_digest: str,
    fixture_sha256: str,
    helper_sha256: str,
    toolchain_sha256: str,
    source_inventory_sha256: str,
    ci_identity: dict[str, int | str],
) -> tuple[dict[str, object], bytes, str]:
    record = registration_identity["registration"]
    if not isinstance(record, dict):
        raise Denied("registration schema missing")
    if plan_sha256 != PLAN_SHA256 or record.get("planSha256") != PLAN_SHA256:
        raise Denied("canonical plan identity differs")
    if registration_identity.get("commit") != actual_workflow_sha:
        raise Denied("workflow run SHA differs from live registration commit")
    if ci_identity.get("headSha") != source_sha or type(ci_identity.get("id")) is not int:
        raise Denied("successful exact-head CI identity differs")
    reviewer_revision = record.get("workflowRevision")
    if not isinstance(reviewer_revision, str) or not HEX40.fullmatch(reviewer_revision):
        raise Denied("registered trusted workflow revision is invalid")
    value: dict[str, object] = {
        "schemaVersion": 1,
        "repositoryId": registration_identity["repositoryId"],
        "runId": run_id,
        "attempt": 1,
        "environmentId": record.get("environmentId"),
        "sourceSha": source_sha,
        "planSha256": plan_sha256,
        "actualWorkflowSha": actual_workflow_sha,
        "trustedWorkflowRevision": reviewer_revision,
        "launcherRevision": reviewer_revision,
        "launcherSha256": record.get("launcherSha256"),
        "supervisorSha256": record.get("supervisorSha256"),
        "fixtureSha256": fixture_sha256,
        "helperSha256": helper_sha256,
        "toolchainSha256": toolchain_sha256,
        "sourceInventorySha256": source_inventory_sha256,
        "imageDigest": image_digest,
        "registration": registration_identity,
        "ciRunId": ci_identity["id"],
        "ciHeadSha": ci_identity["headSha"],
    }
    body, digest = canonical_tuple(value)
    return value, body, digest


def validate_environment(
    value: object,
    *,
    environment_id: int,
    environment_name: str,
    authorized_reviewer_ids: list[int],
    branch_policies: object,
) -> None:
    if not isinstance(value, dict):
        raise Denied("protected environment metadata missing")
    if (
        type(value.get("id")) is not int
        or value["id"] != environment_id
        or value.get("name") != environment_name
        or value.get("can_admins_bypass") is not False
    ):
        raise Denied("protected environment identity or bypass policy differs")
    protections = value.get("protection_rules")
    if not isinstance(protections, list) or len(protections) > 32:
        raise Denied("environment protection rules are unavailable")
    reviewer_rules = [
        rule
        for rule in protections
        if isinstance(rule, dict) and rule.get("type") == "required_reviewers"
    ]
    if len(reviewer_rules) != 1:
        raise Denied("required reviewer policy is missing or ambiguous")
    rule = reviewer_rules[0]
    if rule.get("prevent_self_review") is not True:
        raise Denied("environment permits self-review")
    reviewers = rule.get("reviewers")
    if not isinstance(reviewers, list) or not reviewers:
        raise Denied("environment has no required reviewers")
    current_ids: set[int] = set()
    for item in reviewers:
        if (
            not isinstance(item, dict)
            or item.get("type") != "User"
            or not isinstance(item.get("reviewer"), dict)
            or type(item["reviewer"].get("id")) is not int
            or item["reviewer"]["id"] < 1
        ):
            raise Denied("environment reviewer cannot be resolved to a user")
        current_ids.add(item["reviewer"]["id"])
    if not set(authorized_reviewer_ids) <= current_ids:
        raise Denied("registered reviewer is absent from current environment policy")
    if not isinstance(branch_policies, dict):
        raise Denied("environment branch policy is unavailable")
    policies = branch_policies.get("branch_policies")
    if (
        not isinstance(policies, list)
        or len(policies) != 1
        or not isinstance(policies[0], dict)
        or policies[0].get("name") != "master"
        or policies[0].get("type", "branch") != "branch"
        or value.get("deployment_branch_policy")
        != {"protected_branches": False, "custom_branch_policies": True}
    ):
        raise Denied("environment is not protected for exact master only")


def validate_approval_history(
    approvals: object,
    *,
    run_id: int,
    tuple_sha256: str,
    environment_id: int,
    environment_name: str,
    authorized_reviewer_ids: list[int],
    triggering_actor_id: int,
) -> int:
    if not isinstance(approvals, list) or not approvals or len(approvals) > 100:
        raise Denied("workflow approval history is missing or oversized")
    expected_comment = f"retention-proof:{run_id}:1:{tuple_sha256}"
    matching: list[dict[str, object]] = []
    for approval in approvals:
        if not isinstance(approval, dict):
            raise Denied("invalid approval history entry")
        if (
            (set(approval) - {
                "id",
                "node_id",
                "user",
                "state",
                "environments",
                "created_at",
                "comment",
                "reviewer",
            })
            or type(approval.get("id")) is not int
            or approval["id"] < 1
            or not isinstance(approval.get("state"), str)
            or not isinstance(approval.get("user"), dict)
            or not isinstance(approval.get("comment"), str)
            or type(approval["user"].get("id")) is not int
            or approval["user"]["id"] < 1
        ):
            raise Denied("approval history schema is not closed")
        environments = approval.get("environments")
        if not isinstance(environments, list):
            raise Denied("approval environment history missing")
        for environment in environments:
            if (
                not isinstance(environment, dict)
                or set(environment) - {"id", "name", "url", "html_url", "state"}
                or not isinstance(environment.get("name"), str)
                or not isinstance(environment.get("state"), str)
            ):
                raise Denied("invalid approval environment entry")
            if (
                environment.get("id") == environment_id
                or environment.get("name") == environment_name
            ):
                matching.append(approval)
    if len(matching) != 1:
        raise Denied("environment approval is missing, duplicate, or conflicting")
    approval = matching[0]
    user = approval.get("user")
    environment_entries = approval["environments"]
    if (
        approval.get("state") != "approved"
        or approval.get("comment") != expected_comment
        or not isinstance(user, dict)
        or type(user.get("id")) is not int
        or user["id"] not in authorized_reviewer_ids
        or user["id"] == triggering_actor_id
        or len(environment_entries) != 1
        or environment_entries[0].get("id") != environment_id
        or environment_entries[0].get("name") != environment_name
        or environment_entries[0].get("state") != "approved"
    ):
        raise Denied("review approval does not match the exact tuple")
    return user["id"]


class GitHubReader:
    def __init__(
        self,
        repository: str,
        token: str,
        repository_id: int,
        opener: object | None = None,
        api_base: str = "https://api.github.com",
    ) -> None:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise Denied("invalid repository name")
        if not token:
            raise Denied("GITHUB_TOKEN is required")
        if type(repository_id) is not int or repository_id < 1:
            raise Denied("numeric repository ID is required")
        self.repository = repository
        self.token = token
        self.repository_id = repository_id
        self.opener = opener or urllib.request.build_opener(_NoRedirect())
        self.api_base = api_base.rstrip("/")
        self.deadline = 0.0

    def _get(self, route: str) -> bytes:
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise Denied("Git API sequence deadline exceeded")
        if (route and not route.startswith("/")) or "://" in route:
            raise Denied("external API route denied")
        request = urllib.request.Request(
            f"{self.api_base}/repos/{self.repository}{route}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "X-GitHub-Api-Version": "2022-11-28",
                "Cache-Control": "no-cache, no-store, max-age=0",
                "Pragma": "no-cache",
            },
            method="GET",
        )
        try:
            with self.opener.open(
                request, timeout=min(30, remaining)
            ) as response:  # type: ignore[attr-defined]
                if response.status != 200:
                    raise Denied("Git API returned non-200")
                body = response.read(MAX_RESPONSE + 1)
                if len(body) > MAX_RESPONSE:
                    raise Denied("Git API response exceeds 64 KiB")
                return body
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise Denied("Git API request failed") from error

    def _json(self, route: str) -> dict[str, object]:
        value = self._response(route)
        if not isinstance(value, dict):
            raise Denied("Git API object has wrong type")
        return value

    def _response(self, route: str) -> object:
        return decode_json(self._get(route))

    def current_run_authority(self, run_id: int, source_sha: str) -> dict[str, object]:
        if type(run_id) is not int or run_id < 1 or not HEX40.fullmatch(source_sha):
            raise Denied("invalid current-run lookup identity")
        routes = (
            "",
            f"/actions/runs/{run_id}",
            "/environments/retention-fixture-proof",
            "/environments/retention-fixture-proof/deployment-branch-policies?per_page=100",
            f"/actions/runs/{run_id}/approvals",
            "/actions/workflows/ci.yml/runs?"
            f"head_sha={source_sha}&per_page=100",
        )
        allowed = (
            route == ""
            or re.fullmatch(r"/actions/runs/[1-9][0-9]*", route)
            or re.fullmatch(r"/actions/runs/[1-9][0-9]*/approvals", route)
            or route == "/environments/retention-fixture-proof"
            or route
            == "/environments/retention-fixture-proof/deployment-branch-policies?per_page=100"
            or re.fullmatch(
                r"/actions/workflows/ci\.yml/runs\?head_sha=[0-9a-f]{40}&per_page=100",
                route,
            )
            for route in routes
        )
        if not all(allowed):
            raise Denied("GitHub API route is outside the read allowlist")
        self.deadline = time.monotonic() + 30
        return {
            "repository": self._json(routes[0]),
            "run": self._json(routes[1]),
            "environment": self._json(routes[2]),
            "branchPolicies": self._json(routes[3]),
            "approvals": self._response(routes[4]),
            "ci": self._json(routes[5]),
        }

    def read_file_at(self, commit_sha: str, path: str) -> tuple[bytes, dict[str, str]]:
        if not HEX40.fullmatch(commit_sha):
            raise Denied("invalid pinned commit identity")
        parts = path.split("/")
        if (
            not parts
            or any(not part or part in (".", "..") or "\n" in part or "\r" in part for part in parts)
        ):
            raise Denied("invalid pinned file path")
        self.deadline = time.monotonic() + 30
        commit = self._json(f"/git/commits/{commit_sha}")
        if commit.get("sha") != commit_sha:
            raise Denied("pinned commit object identity mismatch")
        root_tree = commit.get("tree")
        if not isinstance(root_tree, dict) or not isinstance(root_tree.get("sha"), str):
            raise Denied("pinned commit tree missing")
        tree_sha = root_tree["sha"]
        if not HEX40.fullmatch(tree_sha):
            raise Denied("invalid pinned root tree")
        selected_tree = tree_sha
        parent_tree = ""
        blob_sha = ""
        for index, part in enumerate(parts):
            response = self._json(f"/git/trees/{selected_tree}")
            if response.get("sha") != selected_tree:
                raise Denied("pinned source tree identity mismatch")
            if response.get("truncated") is not False:
                raise Denied("pinned source tree is truncated")
            entries = response.get("tree")
            if not isinstance(entries, list):
                raise Denied("pinned source tree entries missing")
            if any(not isinstance(entry, dict) or not isinstance(entry.get("path"), str) for entry in entries):
                raise Denied("pinned source tree entry is malformed")
            names = [entry["path"] for entry in entries]
            if len(names) != len(set(names)):
                raise Denied("pinned source tree has duplicate entries")
            matches = [entry for entry in entries if entry["path"] == part]
            if len(matches) != 1:
                raise Denied("pinned source path is missing or ambiguous")
            entry = matches[0]
            mode, kind, sha = entry.get("mode"), entry.get("type"), entry.get("sha")
            if not isinstance(mode, str) or not isinstance(kind, str):
                raise Denied("pinned source entry mode or type missing")
            if not isinstance(sha, str) or not HEX40.fullmatch(sha):
                raise Denied("pinned source object SHA malformed")
            if index < len(parts) - 1:
                if mode != "040000" or kind != "tree":
                    raise Denied("pinned source ancestry is not a directory")
                selected_tree = sha
            else:
                if mode not in ("100644", "100755") or kind != "blob":
                    raise Denied("pinned trusted file is not a regular blob")
                parent_tree = selected_tree
                blob_sha = sha
        blob = self._json(f"/git/blobs/{blob_sha}")
        if blob.get("sha") != blob_sha or blob.get("encoding") != "base64":
            raise Denied("pinned source blob identity or encoding differs")
        content = blob.get("content")
        if not isinstance(content, str):
            raise Denied("pinned source blob content missing")
        try:
            raw = base64.b64decode("".join(content.split()), validate=True)
        except ValueError as error:
            raise Denied("pinned source blob base64 is invalid") from error
        if hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() != blob_sha:
            raise Denied("pinned source Git blob hash mismatch")
        return raw, {
            "mode": mode,
            "rootTree": tree_sha,
            "tree": parent_tree,
            "blob": blob_sha,
            "contentSha256": hashlib.sha256(raw).hexdigest(),
        }

    def _ref(self) -> str:
        ref = self._json("/git/ref/heads/master")
        if ref.get("ref") != REF_PATH:
            raise Denied("protected ref response mismatch")
        obj = ref.get("object")
        if not isinstance(obj, dict) or obj.get("type") != "commit":
            raise Denied("protected ref is not a commit")
        sha = obj.get("sha")
        if not isinstance(sha, str) or not HEX40.fullmatch(sha):
            raise Denied("invalid protected ref commit")
        return sha

    def read(
        self, expected_identity: dict[str, object] | None = None
    ) -> dict[str, object]:
        self.deadline = time.monotonic() + 30
        initial_commit = self._ref()
        commit = self._json(f"/git/commits/{initial_commit}")
        if commit.get("sha") != initial_commit:
            raise Denied("commit object identity mismatch")
        tree = commit.get("tree")
        if not isinstance(tree, dict) or not isinstance(tree.get("sha"), str):
            raise Denied("commit tree missing")
        tree_sha = tree["sha"]
        if not HEX40.fullmatch(tree_sha):
            raise Denied("invalid tree SHA")
        selected_tree = tree_sha
        registration_tree = ""
        blob_sha = ""
        mode = ""
        object_type = ""
        path_parts = REGISTRATION_PATH.split("/")
        for index, part in enumerate(path_parts):
            tree_response = self._json(f"/git/trees/{selected_tree}")
            if tree_response.get("sha") != selected_tree:
                raise Denied("registration tree identity mismatch")
            if tree_response.get("truncated") is not False:
                raise Denied("truncated tree response")
            entries = tree_response.get("tree")
            if not isinstance(entries, list):
                raise Denied("tree entries missing")
            matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("path") == part]
            if len(matches) != 1:
                raise Denied("registration tree path missing or duplicated")
            entry = matches[0]
            mode_value = entry.get("mode")
            type_value = entry.get("type")
            sha_value = entry.get("sha")
            if not isinstance(mode_value, str) or not isinstance(type_value, str):
                raise Denied("invalid tree entry")
            if not isinstance(sha_value, str) or not HEX40.fullmatch(sha_value):
                raise Denied("invalid tree object SHA")
            if index < len(path_parts) - 1:
                if mode_value != "040000" or type_value != "tree":
                    raise Denied("registration ancestry is not a tree")
                selected_tree = sha_value
            else:
                mode = mode_value
                object_type = type_value
                blob_sha = sha_value
                registration_tree = selected_tree
        if mode != "100644" or object_type != "blob":
            raise Denied("registration is not a regular blob")
        names = [entry.get("path") for entry in entries]
        if any(not isinstance(name, str) for name in names) or len(names) != len(set(names)):
            raise Denied("registration tree contains malformed or duplicate entries")
        blob = self._json(f"/git/blobs/{blob_sha}")
        if blob.get("sha") != blob_sha or blob.get("encoding") != "base64":
            raise Denied("blob identity or encoding mismatch")
        content = blob.get("content")
        if not isinstance(content, str):
            raise Denied("blob content missing")
        try:
            raw = base64.b64decode("".join(content.split()), validate=True)
        except ValueError as error:
            raise Denied("invalid blob base64") from error
        if len(raw) > MAX_REGISTRATION:
            raise Denied("registration exceeds 16 KiB")
        computed_blob = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
        if computed_blob != blob_sha:
            raise Denied("Git blob hash mismatch")
        registration = validate_registration(raw)
        final_commit = self._ref()
        if final_commit != initial_commit:
            raise Denied("protected ref moved during registration read")
        if not registration["enabled"]:
            raise Denied("registration is disabled")
        identity = {
            "repositoryId": self.repository_id,
            "repository": self.repository,
            "ref": REF_PATH,
            "path": REGISTRATION_PATH,
            "commit": initial_commit,
            "rootTree": tree_sha,
            "tree": registration_tree,
            "blob": blob_sha,
            "contentSha256": hashlib.sha256(raw).hexdigest(),
            "registration": registration,
        }
        if expected_identity is not None and identity != expected_identity:
            raise Denied("registration identity drifted")
        return identity


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request: object, response: object, code: int, msg: str, headers: object, new_url: str) -> None:
        raise Denied("redirects are not permitted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument(
        "--repository-id",
        type=int,
        default=int(os.environ.get("GITHUB_REPOSITORY_ID", "0")),
    )
    parser.add_argument("--expected-identity")
    args = parser.parse_args()
    try:
        identity = GitHubReader(
            args.repository,
            os.environ.get("GITHUB_TOKEN", ""),
            args.repository_id,
        ).read()
        if args.expected_identity:
            expected = json.loads(args.expected_identity)
            if identity != expected:
                raise Denied("registration identity drifted")
        print(json.dumps(identity, sort_keys=True, separators=(",", ":")))
    except (Denied, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"RETENTION_REGISTRATION_DENIED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
