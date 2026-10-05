#!/usr/bin/env python3
"""Inspect a docker-save stream without extracting or running the image."""

from __future__ import annotations

import json
import re
import sys
import tarfile
from pathlib import PurePosixPath

MAX_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
EXPECTED_ENTRYPOINT = ["/src/scripts/fixtures/retention-proof/proof-entrypoint.sh"]
SENSITIVE_PARTS = {
    ".aws",
    ".docker",
    ".git",
    ".gnupg",
    ".kube",
    ".ssh",
    "credentials",
}
FORBIDDEN_BINARIES = {"containerd", "dockerd", "docker", "podman", "runc"}


class InvalidImage(Exception):
    """The image archive is not the reviewed tools-only image."""


class Budget:
    def __init__(self) -> None:
        self.uncompressed_bytes = 0

    def consume(self, amount: int) -> None:
        self.uncompressed_bytes += amount
        if self.uncompressed_bytes > MAX_UNCOMPRESSED_BYTES:
            raise InvalidImage("image exceeds the 2 GiB inspection budget")


def safe_archive_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        normalized = name.removeprefix("./")
        path = PurePosixPath(normalized)
    if path.is_absolute() or any(part in {"..", ""} for part in path.parts):
        raise InvalidImage("archive contains an unsafe path")
    return path


def validate_layer(stream: object) -> None:
    try:
        with tarfile.open(fileobj=stream, mode="r|") as layer:
            for member in layer:
                path = safe_archive_path(member.name)
                if any(part.lower() in SENSITIVE_PARTS for part in path.parts):
                    raise InvalidImage("layer contains a credential/configuration path")
                if path.name.lower() in FORBIDDEN_BINARIES:
                    raise InvalidImage("layer contains a container runtime binary")
                if re.search(
                    r"(^|/)(src|workspace|workspaces)/.*"
                    r"(retention-proof|\.kt$|\.java$|\.py$|\.sh$)",
                    str(path),
                    re.IGNORECASE,
                ):
                    raise InvalidImage("layer contains source or fixture files")
                if member.isreg():
                    source = layer.extractfile(member)
                    if source is None:
                        raise InvalidImage("regular layer entry is unreadable")
                    remaining = member.size
                    while remaining:
                        block = source.read(min(1024 * 1024, remaining))
                        if not block:
                            raise InvalidImage("layer entry is truncated")
                        remaining -= len(block)
    except (tarfile.TarError, OSError) as error:
        raise InvalidImage("image layer is malformed") from error


def inspect(stream: object) -> None:
    budget = Budget()
    manifest: list[dict[str, object]] | None = None
    config_bytes: bytes | None = None
    layer_names: set[str] | None = None
    config_name: str | None = None
    layers_seen: set[str] = set()
    try:
        with tarfile.open(fileobj=stream, mode="r|") as archive:
            for member in archive:
                budget.consume(512 + max(member.size, 0))
                path = safe_archive_path(member.name)
                if not member.isreg():
                    raise InvalidImage("outer archive contains a non-regular entry")
                content = archive.extractfile(member)
                if content is None:
                    raise InvalidImage("outer archive entry is unreadable")
                if path == PurePosixPath("manifest.json"):
                    if manifest is not None or member.size > 64 * 1024:
                        raise InvalidImage("invalid image archive manifest")
                    manifest = json.loads(content.read(64 * 1024 + 1))
                    if (
                        not isinstance(manifest, list)
                        or len(manifest) != 1
                        or not isinstance(manifest[0], dict)
                        or set(manifest[0]) != {"Config", "RepoTags", "Layers"}
                        or not isinstance(manifest[0]["Config"], str)
                        or not isinstance(manifest[0]["Layers"], list)
                        or not all(isinstance(name, str) for name in manifest[0]["Layers"])
                        or not manifest[0]["Layers"]
                    ):
                        raise InvalidImage("image archive manifest schema differs")
                    config_name = manifest[0]["Config"]
                    layer_names = set(manifest[0]["Layers"])
                    if len(layer_names) != len(manifest[0]["Layers"]):
                        raise InvalidImage("image archive contains duplicate layers")
                    for name in [config_name, *layer_names]:
                        safe_archive_path(name)
                elif layer_names is not None and config_name == str(path):
                    if config_bytes is not None or member.size > 4 * 1024 * 1024:
                        raise InvalidImage("invalid image config archive entry")
                    config_bytes = content.read(4 * 1024 * 1024 + 1)
                    if len(config_bytes) > 4 * 1024 * 1024:
                        raise InvalidImage("image config exceeds its byte limit")
                elif layer_names is not None and str(path) in layer_names:
                    validate_layer(content)
                    layers_seen.add(str(path))
                elif (
                    layer_names is not None
                    and f"{path.parent.as_posix()}/layer.tar" in layer_names
                    and path.name in {"VERSION", "json"}
                ):
                    if member.size > 1024 * 1024:
                        raise InvalidImage("layer metadata exceeds its byte limit")
                    content.read(member.size)
                elif path != PurePosixPath("repositories"):
                    raise InvalidImage("unexpected outer image archive entry")
    except (tarfile.TarError, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidImage("image archive is malformed") from error

    if (
        manifest is None
        or config_name is None
        or layer_names is None
        or layers_seen != layer_names
        or not isinstance(config_bytes, bytes)
    ):
        raise InvalidImage("image archive must contain exactly one image")
    try:
        config = json.loads(config_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidImage("image config is malformed") from error
    image_config = config.get("config")
    if (
        not isinstance(image_config, dict)
        or image_config.get("Volumes") not in (None, {})
        or image_config.get("Entrypoint") != EXPECTED_ENTRYPOINT
        or image_config.get("ExposedPorts") not in (None, {})
    ):
        raise InvalidImage("image config contains an unexpected runtime contract")
    labels = image_config.get("Labels")
    if (
        not isinstance(labels, dict)
        or "org.opencontainers.image.source" in labels
    ):
        raise InvalidImage("image config has source or malformed labels")
    if (
        labels.get("org.opencontainers.image.base.name") != (
            "ubuntu:24.04@sha256:"
            "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
        )
        or labels.get("com.meet.retention-proof.snapshot") != "20260918T000000Z"
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            labels.get("com.meet.retention-proof.packages-sha256", ""),
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            labels.get("com.meet.retention-proof.dockerfile-sha256", ""),
        )
    ):
        raise InvalidImage("image labels do not match the locked toolchain")
    history = config.get("history")
    if not isinstance(history, list) or not history:
        raise InvalidImage("image history is missing")
    for item in history:
        if not isinstance(item, dict):
            raise InvalidImage("image history is malformed")
        command = item.get("created_by", "")
        if not isinstance(command, str):
            raise InvalidImage("image history command is malformed")
        if re.search(r"(^|\s)(COPY|ADD)\s", command, re.IGNORECASE):
            raise InvalidImage("image history contains a copy instruction")
    rootfs = config.get("rootfs")
    if not isinstance(rootfs, dict) or rootfs.get("type") != "layers":
        raise InvalidImage("image rootfs metadata is malformed")
    diff_ids = rootfs.get("diff_ids")
    if not isinstance(diff_ids, list) or len(diff_ids) != len(layers_seen):
        raise InvalidImage("image rootfs layer identity differs")


def main() -> int:
    try:
        inspect(sys.stdin.buffer)
    except InvalidImage as error:
        print(f"RETENTION_TOOLS_IMAGE_DENIED: {error}", file=sys.stderr)
        return 1
    print("retention tools image inspection passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
