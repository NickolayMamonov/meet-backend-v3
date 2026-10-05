#!/usr/bin/env python3
"""Validate locked retention-tool inputs and derive bounded Docker build args."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

LOCK_LIMIT = 16 * 1024
DOCKERFILE_LIMIT = 64 * 1024
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
PACKAGE_KEYS = {"name", "version", "sha256"}
REQUIRED_PACKAGES = {
    "acl",
    "bash",
    "ca-certificates",
    "coreutils",
    "findutils",
    "gawk",
    "grep",
    "jq",
    "python3",
    "python3-minimal",
    "sed",
    "tar",
    "util-linux",
}
PACKAGE_COUNT = 115
BASE_IMAGE = (
    "ubuntu:24.04@sha256:"
    "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
)
SNAPSHOT_URL = "https://snapshot.ubuntu.com/ubuntu/20260918T000000Z"
SNAPSHOT_REVISION = "20260918T000000Z"
ENGINE_LAYOUT = "moby-v28-root-container-id-v1"


class Denied(Exception):
    """A bounded preparation input did not satisfy the reviewed contract."""


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise Denied("duplicate JSON key")
        result[key] = value
    return result


def decode_lock(data: bytes) -> dict[str, object]:
    if len(data) > LOCK_LIMIT:
        raise Denied("toolchain lock exceeds 16 KiB")
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise Denied("toolchain lock is malformed") from error
    if not isinstance(value, dict) or set(value) != LOCK_KEYS:
        raise Denied("toolchain lock schema is not closed")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise Denied("unsupported toolchain lock schema")
    if value["enabled"] is not False:
        raise Denied("toolchain proof activation must remain disabled")
    if value["platform"] != "linux/amd64" or value["baseImage"] != BASE_IMAGE:
        raise Denied("toolchain platform or base image differs")
    if value["ubuntuSnapshot"] != SNAPSHOT_URL:
        raise Denied("toolchain snapshot differs")
    if value["preparedImage"] != "" or value["provenanceSha256"] != "":
        raise Denied("preparation inputs already contain publication evidence")
    if value["engineVersion"] != "28.0.4":
        raise Denied("pinned Docker Engine version differs")
    if value["engineApiVersion"] != "1.48" or value["engineLayout"] != ENGINE_LAYOUT:
        raise Denied("pinned Docker Engine layout differs")
    packages = value["packages"]
    if not isinstance(packages, list) or len(packages) != PACKAGE_COUNT:
        raise Denied("locked package closure differs")
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
            or not re.fullmatch(r"[0-9a-f]{64}", package["sha256"])
        ):
            raise Denied("invalid locked package identity")
        names.append(package["name"])
    if names != sorted(set(names)) or not REQUIRED_PACKAGES <= set(names):
        raise Denied("package closure is incomplete or noncanonical")
    if not isinstance(value["dockerfileSha256"], str) or not re.fullmatch(
        r"[0-9a-f]{64}", value["dockerfileSha256"]
    ):
        raise Denied("Dockerfile digest is malformed")
    return value


def read_regular(path: Path, *, limit: int) -> bytes:
    try:
        before = path.lstat()
        if not stat.S_ISREG(before.st_mode):
            raise Denied("preparation input is not a regular file")
        if before.st_size > limit:
            raise Denied("preparation input exceeds its byte limit")
        with path.open("rb") as source:
            opened = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(opened.st_mode)
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                raise Denied("preparation input identity changed")
            data = source.read(limit + 1)
            after_open = os.fstat(source.fileno())
        after = path.lstat()
    except OSError as error:
        raise Denied("preparation input is unavailable") from error
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    if (
        len(data) > limit
        or (after_open.st_dev, after_open.st_ino, after_open.st_size, after_open.st_mtime_ns)
        != identity
        or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != identity
    ):
        raise Denied("preparation input changed while being read")
    return data


def validate_inputs(
    lock_bytes: bytes,
    dockerfile_bytes: bytes,
    *,
    build_input_sha: str,
    expected_lock_sha256: str,
    expected_dockerfile_sha256: str,
) -> dict[str, object]:
    if not re.fullmatch(r"[0-9a-f]{40}", build_input_sha):
        raise Denied("build-input commit is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_lock_sha256):
        raise Denied("pinned toolchain lock digest is malformed")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_dockerfile_sha256):
        raise Denied("pinned Dockerfile digest is malformed")
    if len(dockerfile_bytes) > DOCKERFILE_LIMIT:
        raise Denied("Dockerfile exceeds 64 KiB")
    if hashlib.sha256(lock_bytes).hexdigest() != expected_lock_sha256:
        raise Denied("toolchain lock differs from its independently pinned digest")
    dockerfile_sha256 = hashlib.sha256(dockerfile_bytes).hexdigest()
    if dockerfile_sha256 != expected_dockerfile_sha256:
        raise Denied("Dockerfile differs from its independently pinned digest")
    lock = decode_lock(lock_bytes)
    validate_dockerfile_install_order(dockerfile_bytes)
    if lock["dockerfileSha256"] != dockerfile_sha256:
        raise Denied("Dockerfile differs from its locked digest")
    packages = lock["packages"]
    if not isinstance(packages, list):
        raise Denied("package closure is malformed")
    package_bytes = json.dumps(
        packages, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    package_pins = "".join(
        f"{package['name']}\t{package['version']}\t{package['sha256']}\n"
        for package in packages
    ).encode("ascii")
    return {
        "schemaVersion": 1,
        "buildInputSha": build_input_sha,
        "baseImage": lock["baseImage"],
        "snapshotRevision": SNAPSHOT_REVISION,
        "packageCount": PACKAGE_COUNT,
        "packageArrayBase64": base64.b64encode(package_bytes).decode("ascii"),
        "packageArraySha256": hashlib.sha256(package_bytes).hexdigest(),
        "packagePinsBase64": base64.b64encode(package_pins).decode("ascii"),
        "packagePinsSha256": hashlib.sha256(package_pins).hexdigest(),
        "dockerfileSha256": dockerfile_sha256,
    }


def validate_dockerfile_install_order(dockerfile_bytes: bytes) -> None:
    try:
        dockerfile = dockerfile_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise Denied("Dockerfile is not UTF-8") from error

    snapshot = dockerfile.find("Snapshot: ${UBUNTU_SNAPSHOT}")
    apt_commands = list(re.finditer(r"\bapt-get\b[^;]*", dockerfile))
    download = dockerfile.find("--download-only")
    archive_hash_check = dockerfile.find(
        '[[ "$actual_sha256" == "$expected_sha256" ]]'
    )
    lock_to_pins = dockerfile.find(
        "cmp --silent /tmp/retention-locked-pins.tsv /tmp/retention-package-pins.tsv"
    )
    install = dockerfile.find("--no-download")
    insecure_options = (
        "[trusted=yes]",
        "AllowUnauthenticated",
        "--allow-unauthenticated",
        "--allow-insecure-repositories",
        "Acquire::https::Verify-Peer=false",
        "Acquire::https::Verify-Host=false",
        "Acquire::Check-Valid-Until=false",
    )
    if (
        snapshot < 0
        or len(apt_commands) < 4
        or snapshot > apt_commands[0].start()
        or "update" not in apt_commands[0].group()
        or "--download-only" not in apt_commands[1].group()
        or "install" not in apt_commands[1].group()
        or "--no-download" not in apt_commands[2].group()
        or "install" not in apt_commands[2].group()
        or not (
            lock_to_pins
            < apt_commands[0].start()
            < download
            < archive_hash_check
            < install
        )
        or any(option in dockerfile for option in insecure_options)
    ):
        raise Denied("Dockerfile does not authenticate packages before install")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--dockerfile", required=True, type=Path)
    parser.add_argument("--build-input-sha", required=True)
    parser.add_argument("--expected-lock-sha256", required=True)
    parser.add_argument("--expected-dockerfile-sha256", required=True)
    args = parser.parse_args()
    try:
        lock_bytes = read_regular(args.lock, limit=LOCK_LIMIT)
        dockerfile_bytes = read_regular(args.dockerfile, limit=DOCKERFILE_LIMIT)
        result = validate_inputs(
            lock_bytes,
            dockerfile_bytes,
            build_input_sha=args.build_input_sha,
            expected_lock_sha256=args.expected_lock_sha256,
            expected_dockerfile_sha256=args.expected_dockerfile_sha256,
        )
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    except Denied as error:
        print(f"RETENTION_TOOLS_PREPARATION_DENIED: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
