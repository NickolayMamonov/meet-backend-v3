#!/usr/bin/env python3
"""Deterministic tests for the signed W -> B -> image evidence chain."""

from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "scripts/fixtures/retention-proof/toolchain.lock.json"
DOCKERFILE_PATH = ROOT / "scripts/fixtures/retention-proof/Dockerfile"
MODULE_PATH = ROOT / "scripts/retention-tools-provenance.py"

spec = importlib.util.spec_from_file_location("retention_tools_provenance", MODULE_PATH)
assert spec and spec.loader
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)


def make_statement() -> dict[str, object]:
    repository_uri = f"https://github.com/{provenance.REPOSITORY}"
    signer = f"{repository_uri}/{provenance.WORKFLOW_PATH}@refs/heads/master"
    return {
        "_type": "https://in-toto.io/Statement/v1",
        "predicateType": "https://slsa.dev/provenance/v1",
        "subject": [
            {
                "name": provenance.IMAGE,
                "digest": {"sha256": "d" * 64},
            }
        ],
        "predicate": {
            "buildDefinition": {
                "externalParameters": {
                    "workflow": {
                        "repository": repository_uri,
                        "ref": "refs/heads/master",
                    }
                },
                "resolvedDependencies": [
                    {
                        "uri": f"git+{repository_uri}@refs/heads/master",
                        "digest": {"gitCommit": "a" * 40},
                    }
                ],
            },
            "runDetails": {"builder": {"id": signer}},
        },
    }


def make_inputs() -> dict[str, object]:
    build_lock = LOCK_PATH.read_bytes()
    dockerfile = DOCKERFILE_PATH.read_bytes()
    build_input_sha = "b" * 40
    workflow_sha = "a" * 40
    image_digest = "sha256:" + "d" * 64
    signed_statement = json.dumps(
        make_statement(), sort_keys=True, separators=(",", ":")
    ).encode()
    bundle = json.dumps(
        {
            "mediaType": "application/vnd.dev.sigstore.bundle.v0.3+json",
            "dsseEnvelope": {
                "payload": base64.b64encode(signed_statement).decode("ascii"),
                "signatures": [{"keyid": "fixture", "sig": "fixture-signature"}],
            },
        },
        separators=(",", ":"),
    ).encode()
    bundle_sha256 = hashlib.sha256(bundle).hexdigest()
    lock_value = json.loads(build_lock)
    lock_value["preparedImage"] = image_digest
    lock_value["provenanceSha256"] = bundle_sha256
    current_lock = json.dumps(lock_value, separators=(",", ":")).encode()
    workflow = (
        "name: Prepare retention tools\n"
        "env:\n"
        f"  BUILD_INPUT_SHA: {build_input_sha}\n"
        f"  TOOLCHAIN_LOCK_SHA256: {hashlib.sha256(build_lock).hexdigest()}\n"
        f"  TOOLCHAIN_DOCKERFILE_SHA256: {hashlib.sha256(dockerfile).hexdigest()}\n"
    ).encode()
    statement = {
        "schemaVersion": 1,
        "image": provenance.IMAGE,
        "imageDigest": image_digest,
        "bundleSha256": bundle_sha256,
        "sourceSha": build_input_sha,
        "workflow": provenance.WORKFLOW_PATH,
        "runId": "12345",
    }
    return {
        "expected_workflow_sha": workflow_sha,
        "observed_workflow_sha": workflow_sha,
        "workflow_bytes": workflow,
        "provenance_bytes": json.dumps(statement, separators=(",", ":")).encode(),
        "bundle_bytes": bundle,
        "build_lock_bytes": build_lock,
        "build_dockerfile_bytes": dockerfile,
        "current_lock_bytes": current_lock,
        "current_dockerfile_bytes": dockerfile,
    }


def expect_denied(label: str, **changes: object) -> None:
    values = make_inputs()
    values.update(changes)
    try:
        provenance.verify_chain(**values)
    except provenance.Denied:
        return
    raise AssertionError(f"accepted invalid provenance case: {label}")


def make_verified_attestation(values: dict[str, object]) -> bytes:
    bundle = json.loads(values["bundle_bytes"])
    repository_uri = f"https://github.com/{provenance.REPOSITORY}"
    signer = f"{repository_uri}/{provenance.WORKFLOW_PATH}@refs/heads/master"
    statement = make_statement()
    certificate = {
        "sourceRepositoryURI": repository_uri,
        "sourceRepositoryDigest": "a" * 40,
        "sourceRepositoryRef": "refs/heads/master",
        "buildSignerURI": signer,
        "buildSignerDigest": "a" * 40,
        "subjectAlternativeName": signer,
        "issuer": "https://token.actions.githubusercontent.com",
        "runInvocationURI": (
            f"{repository_uri}/actions/runs/12345/attempts/1"
        ),
    }
    return json.dumps(
        [
            {
                "attestation": {"bundle": bundle},
                "verificationResult": {
                    "statement": statement,
                    "signature": {"certificate": certificate},
                },
            }
        ],
        separators=(",", ":"),
    ).encode()


class ReadOnlyFakeReader:
    """Permission-faithful Contents/Actions GET fixture for the remote chain."""

    repository = provenance.REPOSITORY
    repository_id = 123456

    def __init__(self, values: dict[str, object]) -> None:
        self.requests: list[tuple[str, str]] = []
        self.run: dict[str, object] = {
            "id": 12345,
            "event": "workflow_dispatch",
            "head_branch": "master",
            "run_attempt": 1,
            "status": "completed",
            "conclusion": "success",
            "path": provenance.WORKFLOW_RUN_PATH,
            "head_sha": "a" * 40,
            "repository": {
                "id": self.repository_id,
                "full_name": provenance.REPOSITORY,
            },
        }
        statement = json.loads(values["provenance_bytes"])
        self.files = {
            (provenance.WORKFLOW_PATH, "a" * 40): values["workflow_bytes"],
            (
                "scripts/fixtures/retention-proof/toolchain.lock.json",
                statement["sourceSha"],
            ): values["build_lock_bytes"],
            (
                "scripts/fixtures/retention-proof/Dockerfile",
                statement["sourceSha"],
            ): values["build_dockerfile_bytes"],
        }

    def fetch_run(self, run_id: str) -> dict[str, object]:
        self.requests.append(("actions-read", run_id))
        assert run_id == "12345"
        return self.run

    def fetch_file(self, path: str, revision: str, *, limit: int) -> bytes:
        assert path in {
            provenance.WORKFLOW_PATH,
            "scripts/fixtures/retention-proof/toolchain.lock.json",
            "scripts/fixtures/retention-proof/Dockerfile",
        }
        self.requests.append(("contents-read", f"{revision}:{path}"))
        content = self.files.get((path, revision))
        if not isinstance(content, bytes) or len(content) > limit:
            raise provenance.Denied("permission-faithful fake denied file read")
        return content


def main() -> None:
    values = make_inputs()
    result = provenance.verify_chain(**values)
    assert result == {
        "workflowSha": "a" * 40,
        "buildInputSha": "b" * 40,
        "imageDigest": "sha256:" + "d" * 64,
        "bundleSha256": hashlib.sha256(values["bundle_bytes"]).hexdigest(),
        "runId": "12345",
    }

    reader_client = provenance.GitHubReader(
        provenance.REPOSITORY, "fake-read-token", 123456
    )
    content_path = "scripts/fixtures/retention-proof/Dockerfile"
    content_bytes = b"locked dockerfile bytes\n"
    encoded = base64.b64encode(content_bytes).decode("ascii")

    def wrapped_content_response(path: str, query: dict[str, str]) -> dict[str, object]:
        assert path == (
            f"repos/{provenance.REPOSITORY}/contents/{content_path}"
        )
        assert query == {"ref": "b" * 40}
        return {
            "type": "file",
            "path": content_path,
            "encoding": "base64",
            "sha": provenance.git_blob_sha(content_bytes),
            "size": len(content_bytes),
            "content": encoded[:12] + "\n" + encoded[12:],
        }

    reader_client._get_json = wrapped_content_response
    assert reader_client.fetch_file(
        content_path, "b" * 40, limit=provenance.DOCKERFILE_LIMIT
    ) == content_bytes
    try:
        reader_client.fetch_file(
            "scripts/unapproved.py", "b" * 40, limit=provenance.DOCKERFILE_LIMIT
        )
    except provenance.Denied:
        pass
    else:
        raise AssertionError("GitHub reader accepted a non-allowlisted path")

    provenance.APPROVED_WORKFLOW_SHA = "a" * 40
    reader = ReadOnlyFakeReader(values)
    assert provenance.verify_remote_chain(
        reader,
        expected_workflow_sha="a" * 40,
        provenance_bytes=values["provenance_bytes"],
        bundle_bytes=values["bundle_bytes"],
        current_lock_bytes=values["current_lock_bytes"],
        current_dockerfile_bytes=values["current_dockerfile_bytes"],
    ) == result
    assert [kind for kind, _ in reader.requests] == [
        "actions-read",
        "contents-read",
        "contents-read",
        "contents-read",
    ]

    verified = make_verified_attestation(values)
    verification_args = {
        "workflow_sha": "a" * 40,
        "image_digest": "sha256:" + "d" * 64,
        "run_id": "12345",
        "run_attempt": 1,
    }
    provenance.verify_signed_attestation(
        verified, values["bundle_bytes"], **verification_args
    )
    verified_rows = json.loads(verified)
    provenance.verify_signed_attestation(
        json.dumps(verified_rows + verified_rows, separators=(",", ":")).encode(),
        values["bundle_bytes"],
        **verification_args,
    )

    def deny_attestation(label: str, mutate: object) -> None:
        rows = json.loads(verified)
        mutate(rows)
        try:
            provenance.verify_signed_attestation(
                json.dumps(rows, separators=(",", ":")).encode(),
                values["bundle_bytes"],
                **verification_args,
            )
        except provenance.Denied:
            return
        raise AssertionError(f"accepted invalid signed attestation: {label}")

    deny_attestation(
        "wrong run ID",
        lambda rows: rows[0]["verificationResult"]["signature"]["certificate"].update(
            runInvocationURI=(
                f"https://github.com/{provenance.REPOSITORY}/"
                "actions/runs/999/attempts/1"
            )
        ),
    )
    deny_attestation(
        "wrong attempt",
        lambda rows: rows[0]["verificationResult"]["signature"]["certificate"].update(
            runInvocationURI=(
                f"https://github.com/{provenance.REPOSITORY}/"
                "actions/runs/12345/attempts/2"
            )
        ),
    )
    deny_attestation(
        "wrong predicate",
        lambda rows: rows[0]["verificationResult"]["statement"].update(
            predicateType="https://example.invalid/predicate"
        ),
    )
    deny_attestation(
        "wrong subject",
        lambda rows: rows[0]["verificationResult"]["statement"]["subject"][0][
            "digest"
        ].update(sha256="e" * 64),
    )
    deny_attestation(
        "wrong workflow commit",
        lambda rows: rows[0]["verificationResult"]["statement"]["predicate"][
            "buildDefinition"
        ]["resolvedDependencies"][0]["digest"].update(gitCommit="e" * 40),
    )
    conflicting = json.loads(verified)
    conflicting.append(json.loads(json.dumps(conflicting[0])))
    conflicting[1]["verificationResult"]["statement"]["predicateType"] = (
        "https://example.invalid/conflict"
    )
    try:
        provenance.verify_signed_attestation(
            json.dumps(conflicting, separators=(",", ":")).encode(),
            values["bundle_bytes"],
            **verification_args,
        )
    except provenance.Denied:
        pass
    else:
        raise AssertionError("accepted conflicting attestation result")

    for field, invalid in (
        ("run_attempt", 2),
        ("event", "push"),
        ("head_branch", "dev"),
        ("conclusion", "failure"),
        ("path", ".github/workflows/prepare-retention-proof-tools.yml@dev"),
    ):
        changed_run = ReadOnlyFakeReader(values)
        changed_run.run[field] = invalid
        try:
            provenance.verify_remote_chain(
                changed_run,
                expected_workflow_sha="a" * 40,
                provenance_bytes=values["provenance_bytes"],
                bundle_bytes=values["bundle_bytes"],
                current_lock_bytes=values["current_lock_bytes"],
                current_dockerfile_bytes=values["current_dockerfile_bytes"],
            )
        except provenance.Denied:
            assert len(changed_run.requests) == 1
            continue
        raise AssertionError(f"accepted invalid publisher run field {field}")

    changed_repo = ReadOnlyFakeReader(values)
    changed_repo.run["repository"]["id"] = 654321
    try:
        provenance.verify_remote_chain(
            changed_repo,
            expected_workflow_sha="a" * 40,
            provenance_bytes=values["provenance_bytes"],
            bundle_bytes=values["bundle_bytes"],
            current_lock_bytes=values["current_lock_bytes"],
            current_dockerfile_bytes=values["current_dockerfile_bytes"],
        )
    except provenance.Denied:
        assert len(changed_repo.requests) == 1
    else:
        raise AssertionError("accepted publisher run from a different repository ID")
    provenance.APPROVED_WORKFLOW_SHA = ""

    expect_denied("unapproved publisher workflow", observed_workflow_sha="c" * 40)
    expect_denied(
        "unapproved publisher workflow identity",
        expected_workflow_sha="",
        observed_workflow_sha="a" * 40,
    )
    changed_source = json.loads(values["provenance_bytes"])
    changed_source["sourceSha"] = "c" * 40
    expect_denied(
        "substituted build-input SHA",
        provenance_bytes=json.dumps(changed_source, separators=(",", ":")).encode(),
    )
    changed_bundle = values["bundle_bytes"] + b"changed"
    expect_denied("changed signed bundle", bundle_bytes=changed_bundle)
    duplicate_key = values["provenance_bytes"].replace(
        b'"schemaVersion":1,',
        b'"schemaVersion":1,"schemaVersion":1,',
    )
    expect_denied("duplicate provenance key", provenance_bytes=duplicate_key)
    unknown_key = json.loads(values["provenance_bytes"])
    unknown_key["extra"] = "not allowed"
    expect_denied(
        "unknown provenance key",
        provenance_bytes=json.dumps(unknown_key, separators=(",", ":")).encode(),
    )
    changed_workflow_pin = values["workflow_bytes"].replace(
        b"  BUILD_INPUT_SHA: " + b"b" * 40,
        b"  BUILD_INPUT_SHA: " + b"c" * 40,
    )
    expect_denied("substituted workflow build pin", workflow_bytes=changed_workflow_pin)
    changed_lock = json.loads(values["build_lock_bytes"])
    changed_lock["baseImage"] = "ubuntu:24.04"
    expect_denied(
        "build lock changed after W pin",
        build_lock_bytes=json.dumps(changed_lock, separators=(",", ":")).encode(),
    )
    expect_denied(
        "build Dockerfile changed after W pin",
        build_dockerfile_bytes=values["build_dockerfile_bytes"] + b"\n",
    )
    changed_current = json.loads(values["current_lock_bytes"])
    changed_current["enabled"] = True
    expect_denied(
        "toolchain lock enabled",
        current_lock_bytes=json.dumps(changed_current, separators=(",", ":")).encode(),
    )
    changed_packages = json.loads(values["current_lock_bytes"])
    changed_packages["packages"][0]["sha256"] = "e" * 64
    expect_denied(
        "current package closure drift",
        current_lock_bytes=json.dumps(changed_packages, separators=(",", ":")).encode(),
    )
    print("retention tools provenance chain tests passed")


if __name__ == "__main__":
    main()
