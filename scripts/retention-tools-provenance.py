#!/usr/bin/env python3
"""Verify the signed-provenance evidence's pinned W -> B -> image chain."""

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

LOCK_LIMIT = 16 * 1024
DOCKERFILE_LIMIT = 64 * 1024
PROVENANCE_LIMIT = 16 * 1024
BUNDLE_LIMIT = 64 * 1024
WORKFLOW_LIMIT = 64 * 1024
REPOSITORY = "NickolayMamonov/meet-backend-v3"
IMAGE = "ghcr.io/nickolaymamonov/retention-proof-tools"
WORKFLOW_PATH = ".github/workflows/prepare-retention-proof-tools.yml"
WORKFLOW_RUN_PATH = WORKFLOW_PATH + "@master"
PROVENANCE_KEYS = {
    "schemaVersion",
    "image",
    "imageDigest",
    "bundleSha256",
    "sourceSha",
    "workflow",
    "runId",
}
LOCK_KEYS = {
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
PIN_PATTERNS = {
    "BUILD_INPUT_SHA": re.compile(r"(?m)^  BUILD_INPUT_SHA: ([0-9a-f]{40})$"),
    "TOOLCHAIN_LOCK_SHA256": re.compile(
        r"(?m)^  TOOLCHAIN_LOCK_SHA256: ([0-9a-f]{64})$"
    ),
    "TOOLCHAIN_DOCKERFILE_SHA256": re.compile(
        r"(?m)^  TOOLCHAIN_DOCKERFILE_SHA256: ([0-9a-f]{64})$"
    ),
}
API_LIMIT = 64 * 1024
APPROVED_WORKFLOW_SHA = ""
API_VERSION = "2022-11-28"
API_BASE = "https://api.github.com"


class Denied(Exception):
    """The committed preparation evidence does not form the approved chain."""


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise Denied("duplicate JSON key")
        result[key] = value
    return result


def decode_object(data: bytes, *, limit: int, label: str) -> dict[str, object]:
    if len(data) > limit:
        raise Denied(f"{label} exceeds its byte limit")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied(f"{label} is malformed") from error
    if not isinstance(value, dict):
        raise Denied(f"{label} is not an object")
    return value


def read_regular(path: Path, *, limit: int, label: str) -> bytes:
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise Denied(f"{label} is not a bounded regular file")
        with path.open("rb") as source:
            opened = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                raise Denied(f"{label} identity changed while opening")
            data = source.read(limit + 1)
            after_open = os.fstat(source.fileno())
        after = path.lstat()
    except OSError as error:
        raise Denied(f"{label} is unavailable") from error
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if (
        len(data) > limit
        or (
            after_open.st_dev,
            after_open.st_ino,
            after_open.st_size,
            after_open.st_mtime_ns,
        )
        != identity
        or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != identity
    ):
        raise Denied(f"{label} changed while being read")
    return data


def pinned_value(workflow_bytes: bytes, name: str) -> str:
    try:
        workflow = workflow_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Denied("publisher workflow is not UTF-8") from error
    matches = PIN_PATTERNS[name].findall(workflow)
    if len(matches) != 1:
        raise Denied(f"publisher workflow does not contain one fixed {name}")
    return matches[0]


def verify_chain(
    *,
    expected_workflow_sha: str,
    observed_workflow_sha: str,
    workflow_bytes: bytes,
    provenance_bytes: bytes,
    bundle_bytes: bytes,
    build_lock_bytes: bytes,
    build_dockerfile_bytes: bytes,
    current_lock_bytes: bytes,
    current_dockerfile_bytes: bytes,
) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", expected_workflow_sha):
        raise Denied("approved publisher workflow digest is not pinned")
    if observed_workflow_sha != expected_workflow_sha:
        raise Denied("publisher workflow run differs from its approved digest")
    if len(workflow_bytes) > WORKFLOW_LIMIT:
        raise Denied("publisher workflow exceeds its byte limit")

    provenance = decode_object(
        provenance_bytes, limit=PROVENANCE_LIMIT, label="provenance"
    )
    if set(provenance) != PROVENANCE_KEYS:
        raise Denied("provenance schema is not closed")
    if type(provenance["schemaVersion"]) is not int or provenance["schemaVersion"] != 1:
        raise Denied("unsupported provenance schema")
    if provenance["image"] != IMAGE or provenance["workflow"] != WORKFLOW_PATH:
        raise Denied("provenance package or workflow identity differs")
    if (
        not isinstance(provenance["imageDigest"], str)
        or not re.fullmatch(r"sha256:[0-9a-f]{64}", provenance["imageDigest"])
        or not isinstance(provenance["bundleSha256"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", provenance["bundleSha256"])
        or not isinstance(provenance["sourceSha"], str)
        or not re.fullmatch(r"[0-9a-f]{40}", provenance["sourceSha"])
        or not isinstance(provenance["runId"], str)
        or not re.fullmatch(r"[1-9][0-9]*", provenance["runId"])
    ):
        raise Denied("provenance values are malformed")
    if len(bundle_bytes) > BUNDLE_LIMIT:
        raise Denied("signed bundle exceeds 64 KiB")
    bundle_sha256 = hashlib.sha256(bundle_bytes).hexdigest()
    if bundle_sha256 != provenance["bundleSha256"]:
        raise Denied("signed bundle digest differs from provenance")

    build_lock = decode_object(build_lock_bytes, limit=LOCK_LIMIT, label="build lock")
    current_lock = decode_object(current_lock_bytes, limit=LOCK_LIMIT, label="current lock")
    if set(build_lock) != LOCK_KEYS or set(current_lock) != LOCK_KEYS:
        raise Denied("toolchain lock schema is not closed")
    if build_lock["enabled"] is not False or current_lock["enabled"] is not False:
        raise Denied("toolchain proof activation must remain disabled")
    if (
        build_lock["preparedImage"] != ""
        or build_lock["provenanceSha256"] != ""
        or current_lock["preparedImage"] != provenance["imageDigest"]
        or current_lock["provenanceSha256"] != bundle_sha256
    ):
        raise Denied("build and evidence lock states differ")

    build_input_sha = pinned_value(workflow_bytes, "BUILD_INPUT_SHA")
    lock_sha256 = pinned_value(workflow_bytes, "TOOLCHAIN_LOCK_SHA256")
    dockerfile_sha256 = pinned_value(workflow_bytes, "TOOLCHAIN_DOCKERFILE_SHA256")
    if provenance["sourceSha"] != build_input_sha:
        raise Denied("provenance build-input SHA differs from publisher workflow pin")
    if hashlib.sha256(build_lock_bytes).hexdigest() != lock_sha256:
        raise Denied("build lock differs from publisher workflow pin")
    if hashlib.sha256(build_dockerfile_bytes).hexdigest() != dockerfile_sha256:
        raise Denied("build Dockerfile differs from publisher workflow pin")
    if build_lock["dockerfileSha256"] != dockerfile_sha256:
        raise Denied("build lock Dockerfile digest differs from publisher workflow pin")
    if (
        current_lock["packages"] != build_lock["packages"]
        or current_lock["platform"] != build_lock["platform"]
        or current_lock["baseImage"] != build_lock["baseImage"]
        or current_lock["ubuntuSnapshot"] != build_lock["ubuntuSnapshot"]
        or current_lock["engineVersion"] != build_lock["engineVersion"]
        or current_lock["engineApiVersion"] != build_lock["engineApiVersion"]
        or current_lock["engineLayout"] != build_lock["engineLayout"]
        or current_lock["dockerfileSha256"] != dockerfile_sha256
        or hashlib.sha256(current_dockerfile_bytes).hexdigest() != dockerfile_sha256
    ):
        raise Denied("current source does not preserve the admitted build inputs")
    return {
        "workflowSha": expected_workflow_sha,
        "buildInputSha": build_input_sha,
        "imageDigest": provenance["imageDigest"],
        "bundleSha256": bundle_sha256,
        "runId": provenance["runId"],
    }


class GitHubReader:
    """Read only bounded GitHub Actions metadata and exact Git files."""

    def __init__(self, repository: str, token: str, repository_id: int) -> None:
        if (
            repository != REPOSITORY
            or not token
            or type(repository_id) is not int
            or repository_id < 1
        ):
            raise Denied("GitHub repository or read token is unavailable")
        self.repository = repository
        self.repository_id = repository_id
        self.token = token

    def _get_json(self, path: str, query: dict[str, str] | None = None) -> dict[str, object]:
        run_prefix = f"repos/{self.repository}/actions/runs/"
        content_prefix = f"repos/{self.repository}/contents/"
        is_run = path.startswith(run_prefix) and bool(
            re.fullmatch(r"[1-9][0-9]*", path.removeprefix(run_prefix))
        )
        content_path = path.removeprefix(content_prefix)
        is_content = path.startswith(content_prefix) and content_path in {
            WORKFLOW_PATH,
            "scripts/fixtures/retention-proof/toolchain.lock.json",
            "scripts/fixtures/retention-proof/Dockerfile",
        }
        if not (is_run or is_content):
            raise Denied("GitHub API route is not an allowed read")
        if query and (not is_content or set(query) != {"ref"}):
            raise Denied("GitHub API query is not an allowed read")
        if is_content and (
            not query or not re.fullmatch(r"[0-9a-f]{40}", query["ref"])
        ):
            raise Denied("Git file revision is malformed")
        url = f"{API_BASE}/{path}"
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "Cache-Control": "no-cache",
                "X-GitHub-Api-Version": API_VERSION,
            },
            method="GET",
        )

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req: object, fp: object, code: int,
                                 msg: str, headers: object, newurl: str) -> None:
                return None

        opener = urllib.request.build_opener(NoRedirect)
        try:
            with opener.open(request, timeout=30) as response:
                if response.status != 200 or response.geturl() != url:
                    raise Denied("GitHub read returned a non-success response")
                if response.headers.get_content_type() != "application/json":
                    raise Denied("GitHub read returned an unexpected content type")
                content_length = response.headers.get("Content-Length")
                if content_length is not None and (
                    not content_length.isdecimal() or int(content_length) > API_LIMIT
                ):
                    raise Denied("GitHub response exceeds its byte limit")
                payload = response.read(API_LIMIT + 1)
        except (OSError, urllib.error.URLError, urllib.error.HTTPError) as error:
            raise Denied("bounded GitHub read failed") from error
        if len(payload) > API_LIMIT:
            raise Denied("GitHub response exceeds its byte limit")
        return decode_object(payload, limit=API_LIMIT, label="GitHub response")

    def fetch_run(self, run_id: str) -> dict[str, object]:
        if not re.fullmatch(r"[1-9][0-9]*", run_id):
            raise Denied("publisher run ID is malformed")
        return self._get_json(
            f"repos/{self.repository}/actions/runs/{run_id}"
        )

    def fetch_file(self, path: str, revision: str, *, limit: int) -> bytes:
        if path not in {
            WORKFLOW_PATH,
            "scripts/fixtures/retention-proof/toolchain.lock.json",
            "scripts/fixtures/retention-proof/Dockerfile",
        }:
            raise Denied("GitHub file path is not allowlisted")
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise Denied("Git file revision is malformed")
        encoded_path = urllib.parse.quote(path, safe="/")
        response = self._get_json(
            f"repos/{self.repository}/contents/{encoded_path}",
            {"ref": revision},
        )
        if (
            response.get("type") != "file"
            or response.get("path") != path
            or response.get("encoding") != "base64"
            or not isinstance(response.get("sha"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", response["sha"])
            or not isinstance(response.get("content"), str)
        ):
            raise Denied("GitHub file response identity is invalid")
        try:
            encoded_content = response["content"].encode("ascii")
            compact_content = re.sub(rb"[ \t\r\n]", b"", encoded_content)
            content = base64.b64decode(compact_content, validate=True)
        except (UnicodeEncodeError, ValueError, TypeError) as error:
            raise Denied("GitHub file content is malformed") from error
        if len(content) > limit or git_blob_sha(content) != response["sha"]:
            raise Denied("GitHub file bytes exceed limit or fail blob identity")
        if type(response.get("size")) is not int or response["size"] != len(content):
            raise Denied("GitHub file size differs from decoded bytes")
        return content


def git_blob_sha(data: bytes) -> str:
    header = b"blob " + str(len(data)).encode("ascii") + b"\0"
    return hashlib.sha1(header + data).hexdigest()


def verify_remote_chain(
    reader: GitHubReader,
    *,
    expected_workflow_sha: str,
    provenance_bytes: bytes,
    bundle_bytes: bytes,
    current_lock_bytes: bytes,
    current_dockerfile_bytes: bytes,
) -> dict[str, str]:
    provenance = decode_object(
        provenance_bytes, limit=PROVENANCE_LIMIT, label="provenance"
    )
    if (
        set(provenance) != PROVENANCE_KEYS
        or not isinstance(provenance.get("runId"), str)
    ):
        raise Denied("provenance schema is not closed")
    run = reader.fetch_run(provenance["runId"])
    run_repository = run.get("repository")
    if (
        not isinstance(run_repository, dict)
        or type(run_repository.get("id")) is not int
        or run_repository.get("full_name") != reader.repository
        or run_repository.get("id") != reader.repository_id
        or run.get("id") != int(provenance["runId"])
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "master"
        or type(run.get("run_attempt")) is not int
        or run.get("run_attempt") != 1
        or run.get("status") != "completed"
        or run.get("conclusion") != "success"
        or run.get("path") != WORKFLOW_RUN_PATH
        or run_repository.get("full_name") != REPOSITORY
        or not re.fullmatch(r"[0-9a-f]{40}", str(run.get("head_sha", "")))
    ):
        raise Denied("publisher run is not the exact successful master attempt")
    workflow_sha = str(run["head_sha"])
    if expected_workflow_sha != APPROVED_WORKFLOW_SHA or not expected_workflow_sha:
        raise Denied("approved publisher workflow W is not pinned")
    workflow_bytes = reader.fetch_file(
        WORKFLOW_PATH, workflow_sha, limit=WORKFLOW_LIMIT
    )
    build_sha = provenance.get("sourceSha")
    if not isinstance(build_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", build_sha):
        raise Denied("build-input revision B is malformed")
    build_lock_bytes = reader.fetch_file(
        "scripts/fixtures/retention-proof/toolchain.lock.json",
        build_sha,
        limit=LOCK_LIMIT,
    )
    build_dockerfile_bytes = reader.fetch_file(
        "scripts/fixtures/retention-proof/Dockerfile",
        build_sha,
        limit=DOCKERFILE_LIMIT,
    )
    return verify_chain(
        expected_workflow_sha=expected_workflow_sha,
        observed_workflow_sha=workflow_sha,
        workflow_bytes=workflow_bytes,
        provenance_bytes=provenance_bytes,
        bundle_bytes=bundle_bytes,
        build_lock_bytes=build_lock_bytes,
        build_dockerfile_bytes=build_dockerfile_bytes,
        current_lock_bytes=current_lock_bytes,
        current_dockerfile_bytes=current_dockerfile_bytes,
    )


def verify_signed_attestation(
    attestation_bytes: bytes,
    bundle_bytes: bytes,
    *,
    workflow_sha: str,
    image_digest: str,
    run_id: str,
    run_attempt: int,
) -> None:
    if len(attestation_bytes) > 256 * 1024:
        raise Denied("verified attestation result exceeds its byte limit")
    try:
        rows = json.loads(
            attestation_bytes.decode("utf-8"), object_pairs_hook=unique_object
        )
        bundle = json.loads(bundle_bytes.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied("verified attestation or bundle is malformed") from error
    if not isinstance(rows, list) or not rows or not isinstance(bundle, dict):
        raise Denied("verified attestation result is empty or malformed")
    envelope = bundle.get("dsseEnvelope")
    payload = envelope.get("payload") if isinstance(envelope, dict) else None
    if not isinstance(payload, str):
        raise Denied("signed bundle does not contain a DSSE payload")
    try:
        signed_statement = json.loads(
            base64.b64decode(payload, validate=True).decode("utf-8"),
            object_pairs_hook=unique_object,
        )
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied("signed bundle payload is malformed") from error
    try:
        run_number = int(run_id)
    except ValueError as error:
        raise Denied("publisher run ID is malformed") from error
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or run_attempt != 1:
        raise Denied("publisher attempt must be exactly one")

    repository_uri = f"https://github.com/{REPOSITORY}"
    signer = f"{repository_uri}/{WORKFLOW_PATH}@refs/heads/master"
    invocation = (
        f"{repository_uri}/actions/runs/{run_number}/attempts/{run_attempt}"
    )
    subject_sha = image_digest.removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", subject_sha):
        raise Denied("image digest is malformed")

    canonical_records: set[bytes] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise Denied("verified attestation entry is malformed")
        attestation = row.get("attestation")
        verification = row.get("verificationResult")
        statement = verification.get("statement") if isinstance(verification, dict) else None
        signature = verification.get("signature") if isinstance(verification, dict) else None
        certificate = signature.get("certificate") if isinstance(signature, dict) else None
        if (
            not isinstance(attestation, dict)
            or attestation.get("bundle") != bundle
            or not isinstance(statement, dict)
            or not isinstance(certificate, dict)
            or signed_statement != statement
        ):
            raise Denied("verified result does not bind the reviewed bundle")
        subjects = statement.get("subject")
        predicate = statement.get("predicate")
        build_definition = predicate.get("buildDefinition") if isinstance(predicate, dict) else None
        external = (
            build_definition.get("externalParameters")
            if isinstance(build_definition, dict)
            else None
        )
        workflow = external.get("workflow") if isinstance(external, dict) else None
        dependencies = (
            build_definition.get("resolvedDependencies")
            if isinstance(build_definition, dict)
            else None
        )
        run_details = predicate.get("runDetails") if isinstance(predicate, dict) else None
        builder = run_details.get("builder") if isinstance(run_details, dict) else None
        if (
            statement.get("_type") != "https://in-toto.io/Statement/v1"
            or statement.get("predicateType") != "https://slsa.dev/provenance/v1"
            or not isinstance(subjects, list)
            or len(subjects) != 1
            or not isinstance(subjects[0], dict)
            or subjects[0].get("name") != IMAGE
            or subjects[0].get("digest") != {"sha256": subject_sha}
            or not isinstance(workflow, dict)
            or workflow.get("repository") != repository_uri
            or workflow.get("ref") != "refs/heads/master"
            or not isinstance(dependencies, list)
            or sum(
                1
                for dependency in dependencies
                if isinstance(dependency, dict)
                and dependency.get("uri")
                == "git+" + repository_uri + "@refs/heads/master"
                and isinstance(dependency.get("digest"), dict)
                and dependency["digest"].get("gitCommit") == workflow_sha
            )
            != 1
            or not isinstance(builder, dict)
            or builder.get("id") != signer
            or certificate.get("sourceRepositoryURI") != repository_uri
            or certificate.get("sourceRepositoryDigest") != workflow_sha
            or certificate.get("sourceRepositoryRef") != "refs/heads/master"
            or certificate.get("buildSignerURI") != signer
            or certificate.get("buildSignerDigest") != workflow_sha
            or certificate.get("subjectAlternativeName") != signer
            or certificate.get("issuer") != "https://token.actions.githubusercontent.com"
            or certificate.get("runInvocationURI") != invocation
        ):
            raise Denied("signed statement or certificate differs from the admitted run")
        canonical_records.add(
            json.dumps(
                {"statement": statement, "bundle": attestation["bundle"]},
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=True,
            ).encode("utf-8")
        )
    if len(canonical_records) != 1:
        raise Denied("verified attestations contain conflicting statements")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-workflow-sha", required=True)
    parser.add_argument("--provenance", required=True, type=Path)
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--current-lock", required=True, type=Path)
    parser.add_argument("--current-dockerfile", required=True, type=Path)
    parser.add_argument("--verified-attestation", required=True, type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--repository-id", required=True, type=int)
    args = parser.parse_args()
    try:
        if args.repository_id < 1:
            raise Denied("GitHub repository ID is malformed")
        reader = GitHubReader(
            args.repository,
            os.environ.get("GH_TOKEN", ""),
            args.repository_id,
        )
        result = verify_remote_chain(
            reader,
            expected_workflow_sha=args.expected_workflow_sha,
            provenance_bytes=read_regular(
                args.provenance, limit=PROVENANCE_LIMIT, label="provenance"
            ),
            bundle_bytes=read_regular(
                args.bundle, limit=BUNDLE_LIMIT, label="signed bundle"
            ),
            current_lock_bytes=read_regular(
                args.current_lock, limit=LOCK_LIMIT, label="current lock"
            ),
            current_dockerfile_bytes=read_regular(
                args.current_dockerfile, limit=DOCKERFILE_LIMIT, label="current Dockerfile"
            ),
        )
        verify_signed_attestation(
            read_regular(
                args.verified_attestation,
                limit=256 * 1024,
                label="verified attestation result",
            ),
            read_regular(args.bundle, limit=BUNDLE_LIMIT, label="signed bundle"),
            workflow_sha=result["workflowSha"],
            image_digest=result["imageDigest"],
            run_id=result["runId"],
            run_attempt=1,
        )
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    except Denied as error:
        print(f"RETENTION_TOOLS_PROVENANCE_DENIED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
