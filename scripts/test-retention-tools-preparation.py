#!/usr/bin/env python3
"""Deterministic admission tests for the tools-only retention image inputs."""

from __future__ import annotations

import base64
import hashlib
import io
import importlib.util
import json
from pathlib import Path
import tarfile

ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "scripts/fixtures/retention-proof/toolchain.lock.json"
DOCKERFILE_PATH = ROOT / "scripts/fixtures/retention-proof/Dockerfile"
MODULE_PATH = ROOT / "scripts/prepare-retention-proof-tools.py"

spec = importlib.util.spec_from_file_location("retention_tools_preparation", MODULE_PATH)
assert spec and spec.loader
preparation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparation)

inspector_spec = importlib.util.spec_from_file_location(
    "retention_tools_image_inspector",
    ROOT / "scripts/inspect-retention-tools-image.py",
)
assert inspector_spec and inspector_spec.loader
inspector = importlib.util.module_from_spec(inspector_spec)
inspector_spec.loader.exec_module(inspector)


def validate(
    lock: bytes,
    dockerfile: bytes,
    build_sha: str = "a" * 40,
    *,
    expected_lock_sha256: str | None = None,
    expected_dockerfile_sha256: str | None = None,
) -> dict[str, object]:
    return preparation.validate_inputs(
        lock,
        dockerfile,
        build_input_sha=build_sha,
        expected_lock_sha256=expected_lock_sha256 or hashlib.sha256(lock).hexdigest(),
        expected_dockerfile_sha256=(
            expected_dockerfile_sha256 or hashlib.sha256(dockerfile).hexdigest()
        ),
    )


def expect_denied(
    label: str,
    lock: bytes,
    dockerfile: bytes,
    build_sha: str = "a" * 40,
    *,
    expected_lock_sha256: str | None = None,
    expected_dockerfile_sha256: str | None = None,
) -> None:
    try:
        validate(
            lock,
            dockerfile,
            build_sha,
            expected_lock_sha256=expected_lock_sha256,
            expected_dockerfile_sha256=expected_dockerfile_sha256,
        )
    except preparation.Denied:
        return
    raise AssertionError(f"accepted invalid preparation case: {label}")


def lock_bytes(lock: dict[str, object], dockerfile: bytes) -> bytes:
    lock["dockerfileSha256"] = hashlib.sha256(dockerfile).hexdigest()
    return json.dumps(lock, separators=(",", ":")).encode("utf-8")


def archive(files: dict[str, bytes]) -> bytes:
    target = io.BytesIO()
    with tarfile.open(fileobj=target, mode="w") as container:
        for name, content in files.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(content)
            container.addfile(entry, io.BytesIO(content))
    return target.getvalue()


def image_archive(layer_files: dict[str, bytes], config_changes: dict[str, object] | None = None) -> bytes:
    layer = archive(layer_files)
    config: dict[str, object] = {
        "config": {
            "Entrypoint": inspector.EXPECTED_ENTRYPOINT,
            "Labels": {
                "org.opencontainers.image.base.name": (
                    "ubuntu:24.04@sha256:"
                    "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
                ),
                "com.meet.retention-proof.snapshot": "20260918T000000Z",
                "com.meet.retention-proof.packages-sha256": "a" * 64,
                "com.meet.retention-proof.dockerfile-sha256": "b" * 64,
            },
        },
        "history": [{"created_by": "RUN apt-get install locked packages"}],
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "c" * 64]},
    }
    if config_changes:
        config["config"].update(config_changes)
    config_bytes = json.dumps(config, separators=(",", ":")).encode()
    manifest = json.dumps(
        [{"Config": "image.json", "RepoTags": ["tools:test"], "Layers": ["layer-id/layer.tar"]}],
        separators=(",", ":"),
    ).encode()
    return archive(
        {
            "manifest.json": manifest,
            "image.json": config_bytes,
            "layer-id/VERSION": b"1.0",
            "layer-id/json": b"{}",
            "layer-id/layer.tar": layer,
        }
    )


def expect_image_denied(label: str, image_bytes: bytes) -> None:
    try:
        inspector.inspect(io.BytesIO(image_bytes))
    except inspector.InvalidImage:
        return
    raise AssertionError(f"accepted unsafe tools image: {label}")


def main() -> None:
    lock_raw = LOCK_PATH.read_bytes()
    dockerfile = DOCKERFILE_PATH.read_bytes()
    lock = preparation.decode_lock(lock_raw)
    lock_value = json.loads(lock_raw)
    lock_value["dockerfileSha256"] = hashlib.sha256(dockerfile).hexdigest()
    valid_lock = json.dumps(lock_value, separators=(",", ":")).encode("utf-8")

    result = validate(valid_lock, dockerfile)
    pinned_lock_sha256 = hashlib.sha256(valid_lock).hexdigest()
    pinned_dockerfile_sha256 = hashlib.sha256(dockerfile).hexdigest()
    assert result["packageCount"] == 115
    assert result["buildInputSha"] == "a" * 40
    assert result["dockerfileSha256"] == hashlib.sha256(dockerfile).hexdigest()
    assert result["packageArraySha256"] == hashlib.sha256(
        base64.b64decode(result["packageArrayBase64"])
    ).hexdigest()
    assert result["packagePinsSha256"] == hashlib.sha256(
        base64.b64decode(result["packagePinsBase64"])
    ).hexdigest()
    expected_pins = "".join(
        f"{package['name']}\t{package['version']}\t{package['sha256']}\n"
        for package in lock["packages"]
    ).encode("ascii")
    assert base64.b64decode(result["packagePinsBase64"]) == expected_pins

    duplicate = valid_lock.replace(b'"schemaVersion":1', b'"schemaVersion":1,"schemaVersion":1')
    expect_denied("duplicate lock key", duplicate, dockerfile)
    unknown = json.loads(valid_lock)
    unknown["unexpected"] = True
    expect_denied("unknown lock key", json.dumps(unknown).encode(), dockerfile)
    malformed_package = json.loads(valid_lock)
    malformed_package["packages"][0]["unexpected"] = True
    expect_denied("unknown package key", json.dumps(malformed_package).encode(), dockerfile)
    unsorted = json.loads(valid_lock)
    unsorted["packages"][0], unsorted["packages"][1] = (
        unsorted["packages"][1],
        unsorted["packages"][0],
    )
    expect_denied("noncanonical package order", json.dumps(unsorted).encode(), dockerfile)
    duplicate_package = json.loads(valid_lock)
    duplicate_package["packages"][1]["name"] = duplicate_package["packages"][0]["name"]
    expect_denied("duplicate package", json.dumps(duplicate_package).encode(), dockerfile)
    missing_package = json.loads(valid_lock)
    missing_package["packages"].pop()
    expect_denied("incomplete package closure", json.dumps(missing_package).encode(), dockerfile)
    extra_package = json.loads(valid_lock)
    extra_package["packages"].append(dict(extra_package["packages"][-1]))
    expect_denied("extra package closure", json.dumps(extra_package).encode(), dockerfile)
    changed_base = json.loads(valid_lock)
    changed_base["baseImage"] = "ubuntu:24.04"
    expect_denied("changed base", json.dumps(changed_base).encode(), dockerfile)
    changed_snapshot = json.loads(valid_lock)
    changed_snapshot["ubuntuSnapshot"] = "https://snapshot.ubuntu.com/ubuntu/20260919T000000Z"
    expect_denied("changed snapshot", json.dumps(changed_snapshot).encode(), dockerfile)
    enabled = json.loads(valid_lock)
    enabled["enabled"] = True
    expect_denied("enabled lock", json.dumps(enabled).encode(), dockerfile)
    bad_digest = json.loads(valid_lock)
    bad_digest["packages"][0]["sha256"] = "g" * 64
    expect_denied("malformed package checksum", json.dumps(bad_digest).encode(), dockerfile)
    wrong_version = json.loads(valid_lock)
    wrong_version["packages"][0]["version"] += "-wrong"
    expect_denied(
        "wrong pinned package version",
        json.dumps(wrong_version).encode(),
        dockerfile,
        expected_lock_sha256=pinned_lock_sha256,
        expected_dockerfile_sha256=pinned_dockerfile_sha256,
    )
    wrong_checksum = json.loads(valid_lock)
    wrong_checksum["packages"][0]["sha256"] = "b" * 64
    expect_denied(
        "wrong pinned package checksum",
        json.dumps(wrong_checksum).encode(),
        dockerfile,
        expected_lock_sha256=pinned_lock_sha256,
        expected_dockerfile_sha256=pinned_dockerfile_sha256,
    )
    expect_denied("Dockerfile hash drift", valid_lock, dockerfile + b"\n")
    expect_denied("malformed build input revision", valid_lock, dockerfile, "a" * 39)

    old_bootstrap = (
        dockerfile.replace(
            b"    sed -i ",
            b"    apt-get -y install ca-certificates jq python3-minimal; \\\n    sed -i ",
            1,
        )
    )
    expect_denied(
        "ordinary archive bootstrap before snapshot selection",
        lock_bytes(json.loads(valid_lock), old_bootstrap),
        old_bootstrap,
    )
    unverified_install = dockerfile.replace(
        b"    [[ \"$actual_sha256\" == \"$expected_sha256\" ]]; \\\n",
        b"",
        1,
    )
    expect_denied(
        "install without archive checksum verification",
        lock_bytes(json.loads(valid_lock), unverified_install),
        unverified_install,
    )
    unsigned_metadata = dockerfile.replace(
        b"APT::Update::Error-Mode=any",
        b"APT::Update::Error-Mode=any -o Acquire::https::Verify-Peer=false",
    )
    expect_denied(
        "disabled TLS peer verification",
        lock_bytes(json.loads(valid_lock), unsigned_metadata),
        unsigned_metadata,
    )
    changed_pins = json.loads(valid_lock)
    changed_pins["packages"][0]["sha256"] = "b" * 64
    expect_denied(
        "package pin drift",
        lock_bytes(changed_pins, dockerfile),
        dockerfile,
        expected_lock_sha256=pinned_lock_sha256,
        expected_dockerfile_sha256=pinned_dockerfile_sha256,
    )

    inspector.inspect(
        io.BytesIO(image_archive({"usr/bin/jq": b"tool", "etc/os-release": b"Ubuntu"}))
    )
    expect_image_denied(
        "credential material in a layer",
        image_archive({"root/.aws/credentials": b"not-a-secret"}),
    )
    expect_image_denied(
        "source or fixture content in a layer",
        image_archive({"src/scripts/fixtures/retention-proof/test.py": b"fixture"}),
    )
    expect_image_denied(
        "container runtime binary in a layer",
        image_archive({"usr/bin/dockerd": b"daemon"}),
    )
    expect_image_denied(
        "declared image volume",
        image_archive({"usr/bin/jq": b"tool"}, {"Volumes": {"/data": {}}}),
    )
    expect_image_denied(
        "present but empty source label",
        image_archive(
            {"usr/bin/jq": b"tool"},
            {
                "Labels": {
                    "org.opencontainers.image.source": "",
                    "org.opencontainers.image.base.name": (
                        "ubuntu:24.04@sha256:"
                        "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
                    ),
                    "com.meet.retention-proof.snapshot": "20260918T000000Z",
                    "com.meet.retention-proof.packages-sha256": "a" * 64,
                    "com.meet.retention-proof.dockerfile-sha256": "b" * 64,
                }
            },
        ),
    )
    expect_image_denied(
        "unsafe outer archive path",
        archive(
            {
                "../escape": b"bad",
                "manifest.json": b"[]",
            }
        ),
    )
    print("retention tools preparation admission tests passed")


if __name__ == "__main__":
    main()
