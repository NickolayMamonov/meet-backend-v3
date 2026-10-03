#!/usr/bin/env python3
"""Permission-faithful, network-free tests for RP-003 registration reads."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request

spec = importlib.util.spec_from_file_location(
    "retention_proof_registration",
    Path(__file__).with_name("retention-proof-registration.py"),
)
assert spec and spec.loader
registration = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registration)


def git_sha(kind: str, data: bytes) -> str:
    return hashlib.sha1(kind.encode() + b" " + str(len(data)).encode() + b"\0" + data).hexdigest()


class Response:
    status = 200

    def __init__(self, value: object) -> None:
        self.body = json.dumps(value, separators=(",", ":")).encode()

    def __enter__(self) -> "Response":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def read(self, length: int = -1) -> bytes:
        return self.body if length < 0 else self.body[:length]


class FakeAPI:
    def __init__(self, raw: bytes | None = None) -> None:
        self.raw = raw or json.dumps(
            {
                "schemaVersion": 1,
                "enabled": True,
                "planSha256": "a" * 64,
                "workflowPath": ".github/workflows/prove-test-vps-retention.yml",
                "workflowRevision": "b" * 40,
                "environmentName": "retention-fixture-proof",
                "environmentId": 27,
                "authorizedReviewerIds": [9],
                "launcherSha256": "c" * 64,
                "supervisorSha256": "d" * 64,
            },
            separators=(",", ":"),
        ).encode()
        self.blob = git_sha("blob", self.raw)
        self.file_tree = git_sha("tree", b"file-tree")
        self.root_tree = git_sha("tree", b"root-tree")
        self.commit = "1" * 40
        self.routes: list[str] = []
        self.refs = [self.commit, self.commit]
        self.fail: str | None = None
        self.fail_status = 403
        self.timeout = False
        self.truncate = False
        self.mode = "100644"
        self.object_type = "blob"
        self.blob_response_sha: str | None = None
        self.oversize = False
        self.duplicate_tree_path = False
        self.bad_commit_sha: str | None = None

    def set_raw(self, raw: bytes) -> None:
        self.raw = raw
        self.blob = git_sha("blob", self.raw)

    def open(self, request: urllib.request.Request, timeout: int) -> Response:
        assert 0 < timeout <= 30
        assert request.get_method() == "GET"
        assert request.get_header("Authorization") == "Bearer fake-token"
        assert set(dict(request.header_items())) == {
            "Accept",
            "Authorization",
            "Cache-control",
            "Pragma",
            "X-github-api-version",
        }
        assert request.get_header("Cache-control") == "no-cache, no-store, max-age=0"
        assert request.get_header("Pragma") == "no-cache"
        path = urllib.parse.urlparse(request.full_url).path
        self.routes.append(path)
        if self.timeout and path.endswith("/git/blobs/" + self.blob):
            raise TimeoutError("injected deadline")
        if self.fail == path:
            raise urllib.error.HTTPError(
                request.full_url, self.fail_status, "denied", {}, None
            )
        if path.endswith("/git/ref/heads/master"):
            sha = self.refs.pop(0) if self.refs else self.commit
            return Response({"ref": "refs/heads/master", "object": {"type": "commit", "sha": sha}})
        if path.endswith(f"/git/commits/{self.commit}"):
            return Response(
                {
                    "sha": self.bad_commit_sha or self.commit,
                    "tree": {"sha": self.root_tree},
                }
            )
        if path.endswith(f"/git/trees/{self.root_tree}"):
            return Response(
                {
                    "truncated": self.truncate,
                    "tree": [{"path": ".github", "mode": "040000", "type": "tree", "sha": self.file_tree}],
                }
            )
        if path.endswith(f"/git/trees/{self.file_tree}"):
            entry = {
                "path": "retention-proof-registration.json",
                "mode": self.mode,
                "type": self.object_type,
                "sha": self.blob,
            }
            entries = [entry, entry] if self.duplicate_tree_path else [entry]
            return Response({"truncated": False, "tree": entries})
        if path.endswith(f"/git/blobs/{self.blob}"):
            value = {
                    "sha": self.blob_response_sha or self.blob,
                    "encoding": "base64",
                    "content": base64.b64encode(self.raw).decode(),
                }
            if self.oversize:
                value["content"] += " " * 70_000
            return Response(value)
        raise AssertionError(f"forbidden API route accessed: {path}")


class FakeLiveAuthority:
    def __init__(self, values: dict[str, object]) -> None:
        self.values = values
        self.routes: list[str] = []

    def open(self, request: urllib.request.Request, timeout: float) -> Response:
        assert 0 < timeout <= 30
        assert request.get_method() == "GET"
        assert request.get_header("Authorization") == "Bearer fake-token"
        assert request.get_header("Cache-control") == "no-cache, no-store, max-age=0"
        assert request.get_header("Pragma") == "no-cache"
        parsed = urllib.parse.urlparse(request.full_url)
        route = parsed.path.removeprefix("/repos/owner/repository")
        if not route:
            route = ""
        if parsed.query:
            route += "?" + parsed.query
        self.routes.append(route)
        if route not in self.values:
            raise AssertionError(f"forbidden live API route accessed: {route}")
        return Response(self.values[route])


def denied(api: FakeAPI, label: str) -> None:
    try:
        registration.GitHubReader(
            "owner/repository", "fake-token", 123, opener=api
        ).read()
    except registration.Denied:
        return
    raise AssertionError(f"accepted invalid registration case: {label}")


def main() -> None:
    for filename in (
        "retention-proof-registration.py",
        "retention-proof-authorize.py",
        "retention-proof-supervisor.py",
        "test-retention-proof-registration.py",
        "test-retention-proof-supervisor.py",
    ):
        source = Path(__file__).with_name(filename).read_bytes()
        compile(source, filename, "exec")

    success = FakeAPI()
    identity = registration.GitHubReader(
        "owner/repository", "fake-token", 123, opener=success
    ).read()
    assert identity["repositoryId"] == 123
    assert identity["commit"] == success.commit
    assert identity["rootTree"] == success.root_tree
    assert identity["tree"] == success.file_tree
    assert identity["blob"] == success.blob
    assert identity["contentSha256"] == hashlib.sha256(success.raw).hexdigest()
    assert success.routes == [
        "/repos/owner/repository/git/ref/heads/master",
        f"/repos/owner/repository/git/commits/{success.commit}",
        f"/repos/owner/repository/git/trees/{success.root_tree}",
        f"/repos/owner/repository/git/trees/{success.file_tree}",
        f"/repos/owner/repository/git/blobs/{success.blob}",
        "/repos/owner/repository/git/ref/heads/master",
    ]
    assert not any("variables" in route or route.endswith(("/contents", "/actions")) for route in success.routes)
    assert all(
        "/git/ref/" in route
        or "/git/commits/" in route
        or "/git/trees/" in route
        or "/git/blobs/" in route
        for route in success.routes
    )
    tuple_value = {
        "schemaVersion": 1,
        "repositoryId": 123,
        "runId": 77,
        "attempt": 1,
        "environmentId": 27,
        "sourceSha": "e" * 40,
        "planSha256": "a" * 64,
        "actualWorkflowSha": success.commit,
        "trustedWorkflowRevision": "b" * 40,
        "launcherRevision": "b" * 40,
        "launcherSha256": "c" * 64,
        "supervisorSha256": "d" * 64,
        "fixtureSha256": "1" * 64,
        "helperSha256": "2" * 64,
        "toolchainSha256": "3" * 64,
        "sourceInventorySha256": "4" * 64,
        "imageDigest": "sha256:" + "5" * 64,
        "registration": identity,
        "ciRunId": 88,
        "ciHeadSha": "e" * 40,
    }
    canonical, tuple_digest = registration.canonical_tuple(tuple_value)
    assert canonical == json.dumps(
        tuple_value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()
    assert not canonical.endswith(b"\n")
    assert tuple_digest == hashlib.sha256(canonical).hexdigest()
    assert registration.canonical_tuple(tuple_value) == (canonical, tuple_digest)
    for mutation in (
        {"unexpected": True},
        {"attempt": 2},
        {"imageDigest": "ubuntu:latest"},
        {"sourceSha": "not-a-sha"},
    ):
        invalid_tuple = {**tuple_value, **mutation}
        try:
            registration.canonical_tuple(invalid_tuple)
        except registration.Denied:
            pass
        else:
            raise AssertionError(f"accepted invalid tuple mutation: {mutation}")

    disabled_lock = Path(
        "scripts/fixtures/retention-proof/toolchain.lock.json"
    ).read_bytes()
    try:
        registration.validate_toolchain_lock(
            disabled_lock,
            expected_image_digest="sha256:" + "5" * 64,
        )
    except registration.Denied:
        pass
    else:
        raise AssertionError("accepted disabled image/toolchain lock")
    package_lock = [
        {"name": name, "version": "1.2.3-1", "sha256": "a" * 64}
        for name in sorted(registration.REQUIRED_PACKAGES)
    ]
    valid_lock = {
        "schemaVersion": 1,
        "enabled": True,
        "platform": "linux/amd64",
        "baseImage": "ubuntu:24.04@sha256:" + "1" * 64,
        "ubuntuSnapshot": "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z",
        "packages": package_lock,
        "dockerfileSha256": "2" * 64,
        "preparedImage": "sha256:" + "5" * 64,
        "provenanceSha256": "3" * 64,
        "engineVersion": "28.0.0",
        "engineApiVersion": "1.51",
        "engineLayout": "moby-v28-root-container-id-v1",
    }
    assert registration.validate_toolchain_lock(
        json.dumps(valid_lock).encode(),
        expected_image_digest=valid_lock["preparedImage"],
    ) == valid_lock
    for changed in (
        {**valid_lock, "preparedImage": "sha256:" + "6" * 64},
        {**valid_lock, "packages": package_lock[:-1]},
        {**valid_lock, "engineLayout": ""},
        {**valid_lock, "unexpected": True},
    ):
        try:
            registration.validate_toolchain_lock(
                json.dumps(changed).encode(),
                expected_image_digest=valid_lock["preparedImage"],
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError("accepted incomplete or mismatched toolchain lock")

    run = {
        "id": 77,
        "run_attempt": 1,
        "event": "workflow_dispatch",
        "head_branch": "master",
        "head_sha": success.commit,
        "path": ".github/workflows/prove-test-vps-retention.yml@master",
        "repository": {"id": 123},
        "actor": {"id": 10},
        "triggering_actor": {"id": 10},
    }
    assert registration.validate_run_metadata(
        run,
        repository_id=123,
        run_id=77,
        attempt=1,
        run_sha=success.commit,
        run_ref="refs/heads/master",
        workflow_path=".github/workflows/prove-test-vps-retention.yml",
    ) == (10, 10)
    for field, value in (
        ("id", 78),
        ("run_attempt", 2),
        ("event", "push"),
        ("head_branch", "dev"),
        ("head_sha", "f" * 40),
        ("path", ".github/workflows/other.yml@master"),
    ):
        invalid_run = {**run, field: value}
        try:
            registration.validate_run_metadata(
                invalid_run,
                repository_id=123,
                run_id=77,
                attempt=1,
                run_sha=success.commit,
                run_ref="refs/heads/master",
                workflow_path=".github/workflows/prove-test-vps-retention.yml",
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError(f"accepted invalid run metadata field: {field}")
    for context_attempt, api_attempt in ((2, 1), (1, 2)):
        invalid_attempt_run = {**run, "run_attempt": api_attempt}
        try:
            registration.validate_run_metadata(
                invalid_attempt_run,
                repository_id=123,
                run_id=77,
                attempt=context_attempt,
                run_sha=success.commit,
                run_ref="refs/heads/master",
                workflow_path=".github/workflows/prove-test-vps-retention.yml",
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError("accepted disagreeing attempt context and API")

    environment = {
        "id": 27,
        "name": "retention-fixture-proof",
        "can_admins_bypass": False,
        "protection_rules": [
            {
                "type": "required_reviewers",
                "prevent_self_review": True,
                "reviewers": [{"type": "User", "reviewer": {"id": 9}}],
            }
        ],
        "deployment_branch_policy": {
            "protected_branches": False,
            "custom_branch_policies": True,
        },
    }
    branch_policies = {
        "branch_policies": [{"name": "master", "type": "branch"}]
    }
    registration.validate_environment(
        environment,
        environment_id=27,
        environment_name="retention-fixture-proof",
        authorized_reviewer_ids=[9],
        branch_policies=branch_policies,
    )
    for invalid_environment in (
        {**environment, "id": 28},
        {**environment, "can_admins_bypass": True},
        {
            **environment,
            "protection_rules": [
                {
                    "type": "required_reviewers",
                    "prevent_self_review": False,
                    "reviewers": [{"type": "User", "reviewer": {"id": 9}}],
                }
            ],
        },
        {
            **environment,
            "protection_rules": [
                {
                    "type": "required_reviewers",
                    "prevent_self_review": True,
                    "reviewers": [{"type": "Team", "reviewer": {"id": 9}}],
                }
            ],
        },
        {
            **environment,
            "deployment_branch_policy": {
                "protected_branches": True,
                "custom_branch_policies": False,
            },
        },
    ):
        try:
            registration.validate_environment(
                invalid_environment,
                environment_id=27,
                environment_name="retention-fixture-proof",
                authorized_reviewer_ids=[9],
                branch_policies=branch_policies,
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError("accepted unsafe protected environment policy")
    approval = [
        {
            "id": 5,
            "state": "approved",
            "user": {"id": 9},
            "comment": f"retention-proof:77:1:{tuple_digest}",
            "environments": [
                {
                    "id": 27,
                    "name": "retention-fixture-proof",
                    "state": "approved",
                }
            ],
        }
    ]
    assert registration.validate_approval_history(
        approval,
        run_id=77,
        tuple_sha256=tuple_digest,
        environment_id=27,
        environment_name="retention-fixture-proof",
        authorized_reviewer_ids=[9],
        triggering_actor_id=10,
    ) == 9
    ci_response = {
        "total_count": 1,
        "workflow_runs": [
            {
                "id": 88,
                "run_number": 2000,
                "path": ".github/workflows/ci.yml@dev",
                "event": "push",
                "head_branch": "dev",
                "head_sha": "e" * 40,
                "status": "completed",
                "conclusion": "success",
                "head_repository": {"full_name": "owner/repository"},
            }
        ],
    }
    repository_metadata = {"id": 123, "default_branch": "master"}
    registration.validate_repository_metadata(
        repository_metadata, repository_id=123
    )
    ci_identity = registration.validate_exact_ci(
        ci_response, source_sha="e" * 40, repository="owner/repository"
    )
    assert ci_identity == {"id": 88, "headSha": "e" * 40}
    pull_request_ci = json.loads(json.dumps(ci_response))
    pull_request_ci["workflow_runs"][0].update(
        {
            "event": "pull_request",
            "head_branch": "MEE2-63",
            "pull_requests": [
                {
                    "base": {"ref": "dev"},
                    "head": {"sha": "e" * 40, "ref": "MEE2-63"},
                }
            ],
        }
    )
    assert registration.validate_exact_ci(
        pull_request_ci, source_sha="e" * 40, repository="owner/repository"
    ) == {"id": 88, "headSha": "e" * 40}
    for base_ref, head_sha in (("master", "e" * 40), ("dev", "f" * 40)):
        invalid_ci = json.loads(json.dumps(pull_request_ci))
        invalid_ci["workflow_runs"][0]["pull_requests"][0]["base"]["ref"] = base_ref
        invalid_ci["workflow_runs"][0]["pull_requests"][0]["head"]["sha"] = head_sha
        try:
            registration.validate_exact_ci(
                invalid_ci, source_sha="e" * 40, repository="owner/repository"
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError("accepted unrelated pull-request CI")
    authority = FakeLiveAuthority(
        {
            "": repository_metadata,
            "/actions/runs/77": run,
            "/environments/retention-fixture-proof": environment,
            "/environments/retention-fixture-proof/deployment-branch-policies?per_page=100": branch_policies,
            "/actions/runs/77/approvals": approval,
            "/actions/workflows/ci.yml/runs?head_sha="
            + "e" * 40
            + "&per_page=100": ci_response,
        }
    )
    live = registration.GitHubReader(
        "owner/repository", "fake-token", 123, opener=authority
    ).current_run_authority(77, "e" * 40)
    assert live["repository"] == repository_metadata
    assert live["approvals"] == approval
    assert authority.routes == list(authority.values)
    assert not any(
        "variables" in route or any(method in route for method in ("POST", "PATCH", "PUT", "DELETE"))
        for route in authority.routes
    )
    for invalid_approval in (
        [{**approval[0], "comment": "approved"}],
        [
            {
                **approval[0],
                "comment": f"retention-proof:76:1:{tuple_digest}",
            }
        ],
        [
            {
                **approval[0],
                "comment": f"retention-proof:77:2:{tuple_digest}",
            }
        ],
        [{**approval[0], "user": {"id": 10}}],
        [{**approval[0], "user": {"id": 20}}],
        [{**approval[0], "state": "rejected"}],
        [*approval, *approval],
        [
            {
                **approval[0],
                "environments": [
                    {
                        "id": 28,
                        "name": "different-environment",
                        "state": "approved",
                    }
                ],
            }
        ],
        [
            {
                **approval[0],
                "environments": [
                    {
                        "id": 27,
                        "name": "retention-fixture-proof",
                        "state": "approved",
                    },
                    {
                        "id": 28,
                        "name": "other",
                        "state": "approved",
                    },
                ],
            }
        ],
        [
            {
                **approval[0],
                "environments": [
                    {
                        "id": 27,
                        "name": "retention-fixture-proof",
                        "state": "rejected",
                    }
                ],
            }
        ],
    ):
        try:
            registration.validate_approval_history(
                invalid_approval,
                run_id=77,
                tuple_sha256=tuple_digest,
                environment_id=27,
                environment_name="retention-fixture-proof",
                authorized_reviewer_ids=[9],
                triggering_actor_id=10,
            )
        except registration.Denied:
            pass
        else:
            raise AssertionError("accepted stale, ambiguous, or untrusted approval")
    for _ in ("first protected-job step", "pre-start", "barrier"):
        registration.GitHubReader(
            "owner/repository", "fake-token", 123, opener=success
        ).read(expected_identity=identity)

    starts = 0
    releases = 0
    teardown = 0
    changed_after_initialization = FakeAPI()
    changed_after_initialization.set_raw(
        changed_after_initialization.raw.replace(
            b'"enabled":true', b'"enabled":false'
        )
    )
    try:
        registration.GitHubReader(
            "owner/repository",
            "fake-token",
            123,
            opener=changed_after_initialization,
        ).read(expected_identity=identity)
    except registration.Denied:
        pass
    else:
        raise AssertionError("registration disable after initialization was accepted")
    assert starts == 0 and releases == 0 and teardown == 0

    changed_before_start = FakeAPI()
    changed_value = changed_before_start.raw.replace(
        b'"authorizedReviewerIds":[9]', b'"authorizedReviewerIds":[10]'
    )
    changed_before_start.set_raw(changed_value)
    try:
        registration.GitHubReader(
            "owner/repository",
            "fake-token",
            123,
            opener=changed_before_start,
        ).read(expected_identity=identity)
    except registration.Denied:
        pass
    else:
        raise AssertionError("registration change before start was accepted")
    assert starts == 0 and releases == 0 and teardown == 0

    starts = 1
    changed_at_barrier = FakeAPI()
    changed_at_barrier.fail = (
        f"/repos/owner/repository/git/trees/{changed_at_barrier.file_tree}"
    )
    try:
        registration.GitHubReader(
            "owner/repository",
            "fake-token",
            123,
            opener=changed_at_barrier,
        ).read(expected_identity=identity)
    except registration.Denied:
        teardown = 1
    else:
        releases = 1
    assert starts == 1 and releases == 0 and teardown == 1

    same_content_new_commit = FakeAPI(success.raw)
    same_content_new_commit.commit = "2" * 40
    same_content_new_commit.refs = [
        same_content_new_commit.commit,
        same_content_new_commit.commit,
    ]
    new_identity = registration.GitHubReader(
        "owner/repository", "fake-token", 123, opener=same_content_new_commit
    ).read()
    assert new_identity["contentSha256"] == identity["contentSha256"]
    assert new_identity["commit"] != identity["commit"]
    try:
        registration.GitHubReader(
            "owner/repository", "fake-token", 123, opener=same_content_new_commit
        ).read(expected_identity=identity)
    except registration.Denied:
        pass
    else:
        raise AssertionError("accepted unchanged content under a new registration commit")

    moved = FakeAPI()
    moved.refs = [moved.commit, "2" * 40]
    denied(moved, "ref movement")
    disabled_raw = success.raw.replace(b'"enabled":true', b'"enabled":false')
    denied(FakeAPI(disabled_raw), "disabled registration")
    denied(FakeAPI(success.raw + b" " * (16 * 1024)), "oversize registration")

    duplicate = b'{"schemaVersion":1,"schemaVersion":1}'
    denied(FakeAPI(duplicate), "duplicate keys")
    denied(FakeAPI(b"\xff"), "invalid UTF-8")
    unknown = success.raw.replace(b'"enabled":true', b'"enabled":true,"unknown":false')
    denied(FakeAPI(unknown), "unknown keys")
    truncated = FakeAPI()
    truncated.truncate = True
    denied(truncated, "truncated tree")
    wrong_mode = FakeAPI()
    wrong_mode.mode = "120000"
    denied(wrong_mode, "symlink mode")
    wrong_type = FakeAPI()
    wrong_type.object_type = "commit"
    denied(wrong_type, "wrong blob type")
    duplicate_path = FakeAPI()
    duplicate_path.duplicate_tree_path = True
    denied(duplicate_path, "duplicate registration tree path")
    bad_commit = FakeAPI()
    bad_commit.bad_commit_sha = "2" * 40
    denied(bad_commit, "wrong commit response identity")
    missing = FakeAPI()
    missing.fail = f"/repos/owner/repository/git/trees/{missing.file_tree}"
    denied(missing, "403 missing registration")
    missing.fail_status = 404
    denied(missing, "404 missing registration")
    wrong_blob = FakeAPI()
    wrong_blob.blob_response_sha = "2" * 40
    denied(wrong_blob, "wrong blob identity")
    oversized_response = FakeAPI()
    oversized_response.oversize = True
    denied(oversized_response, "oversize API response")
    timed_out = FakeAPI()
    timed_out.timeout = True
    denied(timed_out, "API timeout")
    print("RP-003 registration fake API cases passed")


if __name__ == "__main__":
    main()
