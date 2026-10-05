#!/usr/bin/env python3
"""Synthetic admission and image-inspection tests; never access the network or Docker."""

from __future__ import annotations

import base64
from email.message import Message
import hashlib
import importlib.util
from io import BytesIO
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import tarfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load("retention_tools_publisher", "scripts/retention-tools-publisher.py")
inspector = load("retention_tools_image_inspector", "scripts/inspect-retention-tools-image.py")


def make_lock(dockerfile: bytes) -> bytes:
    required = {
        "acl", "bash", "ca-certificates", "coreutils", "findutils", "gawk",
        "grep", "jq", "python3", "python3-minimal", "sed", "tar", "util-linux",
    }
    names = sorted(required | {f"fixture-pkg-{index:03d}" for index in range(102)})
    packages = [
        {"name": name, "version": "1.0-1", "sha256": hashlib.sha256(name.encode()).hexdigest()}
        for name in names
    ]
    value = {
        "schemaVersion": 1,
        "enabled": False,
        "platform": "linux/amd64",
        "baseImage": publisher.BASE_IMAGE,
        "ubuntuSnapshot": publisher.SNAPSHOT,
        "packages": packages,
        "dockerfileSha256": hashlib.sha256(dockerfile).hexdigest(),
        "preparedImage": "",
        "provenanceSha256": "",
        "engineVersion": "28.0.4",
        "engineApiVersion": "1.48",
        "engineLayout": "moby-v28-root-container-id-v1",
    }
    return json.dumps(value, separators=(",", ":")).encode()


DOCKERFILE = (
    b"# Snapshot: ${UBUNTU_SNAPSHOT}\n"
    b"RUN cmp --silent /tmp/retention-locked-pins.tsv /tmp/retention-package-pins.tsv; "
    b"apt-get update;\n"
    b"RUN apt-get install --download-only locked;\n"
    b"RUN [[ \"$actual_sha256\" == \"$expected_sha256\" ]]; "
    b"apt-get install --no-download locked;\n"
    b"RUN apt-get clean;\n"
)


def archive(files: dict[str, bytes]) -> bytes:
    output = BytesIO()
    with tarfile.open(fileobj=output, mode="w") as tar:
        for name, data in files.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            tar.addfile(entry, BytesIO(data))
    return output.getvalue()


def image_archive(
    layer_files: dict[str, bytes],
    *,
    config_update: dict[str, object] | None = None,
) -> bytes:
    layer = archive(layer_files)
    config: dict[str, object] = {
        "config": {
            "Entrypoint": inspector.EXPECTED_ENTRYPOINT,
            "Labels": {
                "org.opencontainers.image.base.name": publisher.BASE_IMAGE,
                "com.meet.retention-proof.snapshot": "20260918T000000Z",
                "com.meet.retention-proof.packages-sha256": "a" * 64,
                "com.meet.retention-proof.dockerfile-sha256": "b" * 64,
            },
        },
        "history": [{"created_by": "RUN apt-get install locked packages"}],
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "c" * 64]},
    }
    if config_update:
        config["config"].update(config_update)
    manifest = json.dumps(
        [{
            "Config": "image.json",
            "RepoTags": ["tools:synthetic"],
            "Layers": ["layer-id/layer.tar"],
        }],
        separators=(",", ":"),
    ).encode()
    return archive({
        "manifest.json": manifest,
        "image.json": json.dumps(config, separators=(",", ":")).encode(),
        "layer-id/VERSION": b"1.0",
        "layer-id/json": b"{}",
        "layer-id/layer.tar": layer,
    })


class FakeReader:
    def __init__(
        self,
        workflow_sha: str,
        workflow_bytes: bytes,
        lock_bytes: bytes,
        dockerfile_bytes: bytes,
        *,
        conclusion: str = "success",
        move_master: bool = False,
        bad_run: bool = False,
        workflow_ci_conclusion: str = "success",
        registered_state: str = "active",
        bad_workflow_ci: bool = False,
        default_branch: str = "master",
        repository_id: int | None = None,
        registration_count: int = 1,
    ) -> None:
        self.workflow_sha = workflow_sha
        self.workflow_bytes = workflow_bytes
        self.lock_bytes = lock_bytes
        self.dockerfile_bytes = dockerfile_bytes
        self.conclusion = conclusion
        self.move_master = move_master
        self.bad_run = bad_run
        self.workflow_ci_conclusion = workflow_ci_conclusion
        self.registered_state = registered_state
        self.bad_workflow_ci = bad_workflow_ci
        self.default_branch = default_branch
        self.repository_id = (
            publisher.REPOSITORY_ID if repository_id is None else repository_id
        )
        self.registration_count = registration_count
        self.master_reads = 0
        self.requests: list[tuple[str, str]] = []

    def get(self, path: str, query: dict[str, str] | None = None) -> dict[str, object]:
        if path == f"repos/{publisher.REPOSITORY}/actions/workflows":
            assert query == {"per_page": "100"}
            self.requests.append(("GET", path))
            return {
                "total_count": self.registration_count,
                "workflows": [
                    {
                        "path": publisher.WORKFLOW_PATH,
                        "state": self.registered_state,
                    }
                    for _ in range(self.registration_count)
                ],
            }
        assert query is None
        self.requests.append(("GET", path))
        if path == f"repos/{publisher.REPOSITORY}":
            return {
                "id": self.repository_id,
                "full_name": publisher.REPOSITORY,
                "default_branch": self.default_branch,
            }
        if path == f"repos/{publisher.REPOSITORY}/git/ref/heads/master":
            self.master_reads += 1
            sha = self.workflow_sha
            if self.move_master and self.master_reads > 1:
                sha = "d" * 40
            return {"object": {"type": "commit", "sha": sha}}
        if path.endswith("/actions/runs/12345"):
            run = {
                "id": 12345,
                "event": "workflow_dispatch",
                "head_branch": "master",
                "head_sha": self.workflow_sha,
                "run_attempt": 1,
                "path": publisher.WORKFLOW_PATH + "@master",
                "repository": {
                    "id": publisher.REPOSITORY_ID,
                    "full_name": publisher.REPOSITORY,
                },
            }
            if self.bad_run:
                run["head_sha"] = "f" * 40
            return run
        if path.endswith("/actions/runs/24680"):
            run = {
                "id": 24680,
                "event": "push",
                "head_branch": "master",
                "head_sha": self.workflow_sha,
                "run_attempt": 1,
                "path": ".github/workflows/validate-retention-tools-publisher.yml",
                "status": "completed",
                "conclusion": self.workflow_ci_conclusion,
                "repository": {
                    "id": publisher.REPOSITORY_ID,
                    "full_name": publisher.REPOSITORY,
                },
            }
            if self.bad_workflow_ci:
                run["head_sha"] = "f" * 40
            return run
        if path.endswith("/actions/runs/67890"):
            return {
                "id": 67890,
                "event": "pull_request",
                "head_branch": "MEE2-63",
                "head_sha": publisher.BUILD_INPUT_SHA,
                "run_attempt": 1,
                "path": ".github/workflows/ci.yml",
                "status": "completed",
                "conclusion": self.conclusion,
                "repository": {
                    "id": publisher.REPOSITORY_ID,
                    "full_name": publisher.REPOSITORY,
                },
            }
        raise AssertionError(f"unexpected API route: {path}")

    def read_file(self, path: str, revision: str, limit: int) -> bytes:
        assert revision in {self.workflow_sha, publisher.BUILD_INPUT_SHA}
        self.requests.append(("GET", f"contents/{path}@{revision}"))
        if path == publisher.WORKFLOW_PATH:
            return self.workflow_bytes
        if path == publisher.LOCK_PATH:
            return self.lock_bytes
        if path == publisher.DOCKERFILE_PATH:
            return self.dockerfile_bytes
        raise AssertionError(f"unexpected file: {path}")


def workflow_fixture() -> bytes:
    return (
        "on:\n"
        "  workflow_dispatch:\n"
        "    inputs:\n"
        "      expected_workflow_sha:\n"
        "        required: true\n"
        "        type: string\n\n"
        f"  BUILD_INPUT_SHA: {publisher.BUILD_INPUT_SHA}\n"
        f"  BUILD_CI_RUN_ID: {publisher.BUILD_CI_RUN_ID}\n"
        f"  TOOLCHAIN_LOCK_SHA256: {publisher.LOCK_SHA256}\n"
        f"  TOOLCHAIN_DOCKERFILE_SHA256: {publisher.DOCKERFILE_SHA256}\n"
    ).encode()


def expect_denied(label: str, action) -> None:
    try:
        action()
    except publisher.Denied:
        return
    raise AssertionError(f"accepted denied case: {label}")


def test_admission() -> None:
    old_values = (
        publisher.BUILD_INPUT_SHA,
        publisher.BUILD_CI_RUN_ID,
        publisher.LOCK_SHA256,
        publisher.DOCKERFILE_SHA256,
    )
    try:
        publisher.BUILD_INPUT_SHA = "b" * 40
        publisher.BUILD_CI_RUN_ID = "67890"
        publisher.DOCKERFILE_SHA256 = hashlib.sha256(DOCKERFILE).hexdigest()
        lock_bytes = make_lock(DOCKERFILE)
        publisher.LOCK_SHA256 = hashlib.sha256(lock_bytes).hexdigest()
        workflow_sha = "a" * 40
        workflow = workflow_fixture()

        def admit(reader: FakeReader, **changes: str):
            context = {
                "event": "workflow_dispatch",
                "ref": "refs/heads/master",
                "sha": workflow_sha,
                "attempt": "1",
                "run_id": "12345",
            }
            context.update(changes)
            return publisher.admit(
                reader,
                workflow_sha=workflow_sha,
                local_workflow=workflow,
                event=context["event"],
                ref=context["ref"],
                sha=context["sha"],
                attempt=context["attempt"],
                run_id=context["run_id"],
            )

        reader = FakeReader(workflow_sha, workflow, lock_bytes, DOCKERFILE)
        assert admit(reader) == (lock_bytes, DOCKERFILE)
        assert all(method == "GET" for method, _ in reader.requests)
        assert any(route.endswith("/actions/runs/67890") for _, route in reader.requests)
        assert any(route.endswith("/actions/runs/12345") for _, route in reader.requests)
        assert reader.master_reads == 2

        for label, changes in (
            ("wrong event", {"event": "push"}),
            ("wrong ref", {"ref": "refs/heads/dev"}),
            ("tag ref", {"ref": "refs/tags/master"}),
            ("wrong commit", {"sha": "c" * 40}),
            ("retry attempt", {"attempt": "2"}),
        ):
            expect_denied(
                label,
                lambda changes=changes: admit(
                    FakeReader(workflow_sha, workflow, lock_bytes, DOCKERFILE),
                    **changes,
                ),
            )
        expect_denied(
            "master moves between fresh ref checks",
            lambda: admit(FakeReader(
                workflow_sha, workflow, lock_bytes, DOCKERFILE, move_master=True
            )),
        )
        expect_denied(
            "B CI failed",
            lambda: admit(FakeReader(
                workflow_sha, workflow, lock_bytes, DOCKERFILE, conclusion="failure"
            )),
        )
        expect_denied(
            "invalid workflow-run identity",
            lambda: admit(FakeReader(
                workflow_sha, workflow, lock_bytes, DOCKERFILE, bad_run=True
            )),
        )
        expect_denied(
            "workflow checkout bytes differ from live W",
            lambda: publisher.admit(
                FakeReader(workflow_sha, workflow, lock_bytes, DOCKERFILE),
                workflow_sha=workflow_sha,
                local_workflow=workflow + b"# substituted workflow",
                event="workflow_dispatch",
                ref="refs/heads/master",
                sha=workflow_sha,
                attempt="1",
                run_id="12345",
            ),
        )
        source_override = workflow.replace(
            f"BUILD_INPUT_SHA: {publisher.BUILD_INPUT_SHA}".encode(),
            b"BUILD_INPUT_SHA: " + b"c" * 40,
            1,
        )
        expect_denied(
            "caller/source override differs from hard pin",
            lambda: publisher.admit(
                FakeReader(workflow_sha, source_override, lock_bytes, DOCKERFILE),
                workflow_sha=workflow_sha,
                local_workflow=source_override,
                event="workflow_dispatch",
                ref="refs/heads/master",
                sha=workflow_sha,
                attempt="1",
                run_id="12345",
            ),
        )
        enabled = json.loads(lock_bytes)
        enabled["enabled"] = True
        changed_lock = json.dumps(enabled, separators=(",", ":")).encode()
        expect_denied(
            "activation enabled or lock bytes drift",
            lambda: admit(FakeReader(
                workflow_sha, workflow, changed_lock, DOCKERFILE
            )),
        )
        expect_denied(
            "Dockerfile content drift at pinned B",
            lambda: admit(FakeReader(
                workflow_sha, workflow, lock_bytes, DOCKERFILE + b"\n"
            )),
        )

        preflight_reader = FakeReader(workflow_sha, workflow, lock_bytes, DOCKERFILE)
        report = publisher.preflight(
            preflight_reader,
            approved_workflow_sha=workflow_sha,
            workflow_ci_run_id="24680",
            local_workflow=workflow,
        )
        assert report["workflowSha"] == workflow_sha
        assert report["buildInputSha"] == publisher.BUILD_INPUT_SHA
        assert report["planSha256"] == publisher.PLAN_SHA256
        assert report["readOnlyChecks"] == "passed"
        assert report["operatorApproval"] == (
            "external exact-revision approval must be verified separately"
        )
        assert preflight_reader.master_reads == 2
        expect_denied(
            "operator W assertion does not match master",
            lambda: publisher.preflight(
                FakeReader(workflow_sha, workflow, lock_bytes, DOCKERFILE),
                approved_workflow_sha="f" * 40,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "repository default branch is not master",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    default_branch="dev",
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "repository ID mismatch",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    repository_id=publisher.REPOSITORY_ID + 1,
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "W ordinary CI did not pass",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    workflow_ci_conclusion="failure",
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "publisher workflow not registered active",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    registered_state="disabled_manually",
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "publisher workflow registration is absent",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    registration_count=0,
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "duplicate publisher workflow registrations",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    registration_count=2,
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
        expect_denied(
            "W CI run not bound to W",
            lambda: publisher.preflight(
                FakeReader(
                    workflow_sha, workflow, lock_bytes, DOCKERFILE,
                    bad_workflow_ci=True,
                ),
                approved_workflow_sha=workflow_sha,
                workflow_ci_run_id="24680",
                local_workflow=workflow,
            ),
        )
    finally:
        (
            publisher.BUILD_INPUT_SHA,
            publisher.BUILD_CI_RUN_ID,
            publisher.LOCK_SHA256,
            publisher.DOCKERFILE_SHA256,
        ) = old_values


def test_github_reader_is_get_only() -> None:
    reader = publisher.GitHubReader(
        publisher.REPOSITORY, publisher.REPOSITORY_ID, "synthetic-read-token"
    )
    for forbidden in (
        f"repos/{publisher.REPOSITORY}/actions/variables",
        f"repos/{publisher.REPOSITORY}/variables",
        f"repos/{publisher.REPOSITORY}/contents",
        f"repos/{publisher.REPOSITORY}/actions/workflows/1/dispatches",
        "https://example.invalid/",
    ):
        expect_denied(
            forbidden,
            lambda path=forbidden: reader.get(path),
        )
    assert not hasattr(reader, "post")
    assert not hasattr(reader, "write")
    assert set(reader.__dict__) == {"repository", "repository_id", "token"}

    file_bytes = b"synthetic trusted workflow bytes"
    response_value = {
        "type": "file",
        "path": publisher.WORKFLOW_PATH,
        "encoding": "base64",
        "content": (
            base64.b64encode(file_bytes).decode("ascii")[:8]
            + "\n"
            + base64.b64encode(file_bytes).decode("ascii")[8:]
        ),
        "sha": publisher.git_blob_sha(file_bytes),
        "size": len(file_bytes),
    }
    observed: list[tuple[str, str, float, str | None, bytes | None]] = []

    class FakeResponse:
        status = 200

        def __init__(self, url: str, payload: bytes) -> None:
            self.url = url
            self.payload = payload
            self.headers = Message()
            self.headers["Content-Type"] = "application/json"
            self.headers["Content-Length"] = str(len(payload))

        def geturl(self) -> str:
            return self.url

        def read(self, size: int) -> bytes:
            return self.payload[:size]

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    class FakeOpener:
        def open(self, request, timeout: float):
            assert request.get_method() == "GET"
            assert request.data is None
            authorization = request.get_header("Authorization")
            assert authorization == "Bearer synthetic-read-token"
            assert request.get_header("X-github-api-version") == "2022-11-28"
            assert "variables" not in request.full_url
            if "/contents/" in request.full_url:
                payload = json.dumps(response_value).encode()
            elif "/actions/runs/999" in request.full_url:
                payload = b'{"id":999}'
            else:
                raise AssertionError(f"unexpected fake API URL: {request.full_url}")
            category = "Contents" if "/contents/" in request.full_url else "Actions"
            observed.append(
                (category, request.full_url, timeout, authorization, request.data)
            )
            return FakeResponse(request.full_url, payload)

    with patch.object(publisher.urllib.request, "build_opener", return_value=FakeOpener()):
        assert reader.read_file(publisher.WORKFLOW_PATH, "a" * 40, 1024) == file_bytes
        assert reader.get(
            f"repos/{publisher.REPOSITORY}/actions/runs/999"
        ) == {"id": 999}
    assert [item[0] for item in observed] == ["Contents", "Actions"]
    assert all(item[2] == 15 for item in observed)
    assert all(item[3] == "Bearer synthetic-read-token" for item in observed)
    assert all(item[4] is None for item in observed)
    response_value["sha"] = "0" * 40
    with patch.object(publisher.urllib.request, "build_opener", return_value=FakeOpener()):
        expect_denied(
            "wrong Git blob identity",
            lambda: reader.read_file(publisher.WORKFLOW_PATH, "a" * 40, 1024),
        )

    class ForbiddenOpener:
        def open(self, request, timeout: float):
            raise publisher.urllib.error.HTTPError(
                request.full_url, 403, "forbidden", {}, None
            )

    with patch.object(
        publisher.urllib.request,
        "build_opener",
        return_value=ForbiddenOpener(),
    ):
        expect_denied(
            "Contents API 403",
            lambda: reader.read_file(publisher.WORKFLOW_PATH, "a" * 40, 1024),
        )

    class TimeoutOpener:
        def open(self, request, timeout: float):
            raise TimeoutError("synthetic bounded timeout")

    with patch.object(
        publisher.urllib.request,
        "build_opener",
        return_value=TimeoutOpener(),
    ):
        expect_denied(
            "Contents API timeout",
            lambda: reader.read_file(publisher.WORKFLOW_PATH, "a" * 40, 1024),
        )
    assert publisher.has_manual_only_trigger(workflow_fixture())
    assert not publisher.has_manual_only_trigger(
        workflow_fixture().replace(
            b"  workflow_dispatch:\n",
            b"  push:\n  workflow_dispatch:\n",
            1,
        )
    )


def test_preparation_and_inspection() -> None:
    original_hashes = publisher.LOCK_SHA256, publisher.DOCKERFILE_SHA256
    lock_bytes = make_lock(DOCKERFILE)
    try:
        publisher.LOCK_SHA256 = hashlib.sha256(lock_bytes).hexdigest()
        publisher.DOCKERFILE_SHA256 = hashlib.sha256(DOCKERFILE).hexdigest()
        publisher.validate_lock(lock_bytes)
        publisher.validate_dockerfile(DOCKERFILE)
        with TemporaryDirectory(prefix="retention-tools-fixture-") as temp:
            lock_path = Path(temp) / "toolchain.lock.json"
            dockerfile_path = Path(temp) / "Dockerfile"
            lock_path.write_bytes(lock_bytes)
            dockerfile_path.write_bytes(DOCKERFILE)
            args = publisher.derive_build_args(lock_path, dockerfile_path)
            assert args[0] == f"UBUNTU_BASE_IMAGE={publisher.BASE_IMAGE}"
            assert args[1] == "UBUNTU_SNAPSHOT=20260918T000000Z"
            assert args[-1] == f"DOCKERFILE_SHA256={publisher.DOCKERFILE_SHA256}"
    finally:
        publisher.LOCK_SHA256, publisher.DOCKERFILE_SHA256 = original_hashes
    expect_denied(
        "ordinary archive bootstrap",
        lambda: publisher.validate_dockerfile(
            b"RUN apt-get install jq;\n" + DOCKERFILE
        ),
    )
    expect_denied(
        "missing archive checksum verification",
        lambda: publisher.validate_dockerfile(
            DOCKERFILE.replace(
                b'RUN [[ "$actual_sha256" == "$expected_sha256" ]]; ', b""
            )
        ),
    )

    inspector.inspect(BytesIO(image_archive({"usr/bin/jq": b"tool"})))
    for label, files, update in (
        ("credentials", {"root/.aws/credentials": b"synthetic"}, None),
        ("fixture source", {"src/scripts/fixtures/retention-proof/x.py": b"x"}, None),
        ("container runtime", {"usr/bin/dockerd": b"x"}, None),
        ("volume", {"usr/bin/jq": b"tool"}, {"Volumes": {"/data": {}}}),
        (
            "empty source label",
            {"usr/bin/jq": b"tool"},
            {"Labels": {
                "org.opencontainers.image.source": "",
                "org.opencontainers.image.base.name": publisher.BASE_IMAGE,
                "com.meet.retention-proof.snapshot": "20260918T000000Z",
                "com.meet.retention-proof.packages-sha256": "a" * 64,
                "com.meet.retention-proof.dockerfile-sha256": "b" * 64,
            }},
        ),
    ):
        try:
            inspector.inspect(BytesIO(image_archive(files, config_update=update)))
        except inspector.InvalidImage:
            continue
        raise AssertionError(f"image inspector accepted {label}")
    try:
        inspector.safe_path("../escape")
    except inspector.InvalidImage:
        pass
    else:
        raise AssertionError("image inspector accepted a traversal path")


def test_workflow_boundaries() -> None:
    publisher_workflow = (
        ROOT / ".github/workflows/prepare-retention-proof-tools.yml"
    ).read_text(encoding="utf-8")
    test_workflow = (
        ROOT / ".github/workflows/validate-retention-tools-publisher.yml"
    ).read_text(encoding="utf-8")
    assert "workflow_dispatch:" in publisher_workflow
    assert "pull_request:" not in publisher_workflow
    assert "pull_request_target:" not in publisher_workflow
    assert "schedule:" not in publisher_workflow
    assert "workflow_call:" not in publisher_workflow
    assert "github.workflow_sha == inputs.expected_workflow_sha" in publisher_workflow
    assert "github.sha == inputs.expected_workflow_sha" in publisher_workflow
    assert "ref: ${{ github.workflow_sha }}" in publisher_workflow
    assert "actions: read" in publisher_workflow
    assert "packages: write" in publisher_workflow
    assert "attestations: write" in publisher_workflow
    assert "id-token: write" in publisher_workflow
    assert "actions: write" not in publisher_workflow
    assert "contents: write" not in publisher_workflow
    assert "--ref \"$GITHUB_REF\"" in publisher_workflow
    assert "--workflow-sha \"$WORKFLOW_SHA\"" in publisher_workflow
    assert "persist-credentials: false" in publisher_workflow
    assert "scripts/retention-tools-publisher.py" in publisher_workflow
    assert "scripts/inspect-retention-tools-image.py" in publisher_workflow
    assert "needs.admit.outputs.admitted == 'true'" in publisher_workflow
    assert "scripts/retention-tools-provenance.py" not in publisher_workflow
    assert "scripts/fixtures/retention-proof/proof-entrypoint.sh" not in publisher_workflow
    assert "enabled: true" not in publisher_workflow
    assert "pull_request:" in test_workflow
    assert "branches: [master]" in test_workflow
    assert "docker build" not in test_workflow
    assert "docker push" not in test_workflow
    assert "docker pull" not in test_workflow
    assert "scripts/test-retention-tools-publisher.py" in test_workflow


def main() -> None:
    test_admission()
    test_github_reader_is_get_only()
    test_preparation_and_inspection()
    test_workflow_boundaries()
    print("retention tools publisher synthetic tests passed")


if __name__ == "__main__":
    main()
