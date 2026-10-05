#!/usr/bin/env python3
"""Inspect a docker-save stream without extracting or executing the image."""

from __future__ import annotations

import json
import re
import sys
import tarfile
from pathlib import PurePosixPath

MAX_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024
EXPECTED_ENTRYPOINT = ["/src/scripts/fixtures/retention-proof/proof-entrypoint.sh"]
SENSITIVE_PARTS = {
    ".aws", ".docker", ".git", ".gnupg", ".kube", ".ssh", "credentials",
}
FORBIDDEN_BINARIES = {"containerd", "dockerd", "docker", "podman", "runc"}
BASE_IMAGE = (
    "ubuntu:24.04@sha256:"
    "f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b"
)


class InvalidImage(Exception):
    """The inspected archive violates the tools-only image contract."""


def safe_path(name: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        path = PurePosixPath(name.removeprefix("./"))
    if path.is_absolute() or any(part in {"..", ""} for part in path.parts):
        raise InvalidImage("archive contains an unsafe path")
    return path


def read_json(member: tarfile.TarInfo, archive: tarfile.TarFile, limit: int) -> bytes:
    if member.size > limit:
        raise InvalidImage("metadata exceeds its byte limit")
    stream = archive.extractfile(member)
    if stream is None:
        raise InvalidImage("archive metadata is unreadable")
    value = stream.read(limit + 1)
    if len(value) != member.size or len(value) > limit:
        raise InvalidImage("archive metadata is truncated")
    return value


def inspect_layer(stream: object) -> None:
    try:
        with tarfile.open(fileobj=stream, mode="r|") as layer:
            for member in layer:
                path = safe_path(member.name)
                if any(part.lower() in SENSITIVE_PARTS for part in path.parts):
                    raise InvalidImage("layer contains credential/configuration content")
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
                        raise InvalidImage("layer member is unreadable")
                    remaining = member.size
                    while remaining:
                        block = source.read(min(1024 * 1024, remaining))
                        if not block:
                            raise InvalidImage("layer member is truncated")
                        remaining -= len(block)
    except (tarfile.TarError, OSError) as error:
        raise InvalidImage("image layer is malformed") from error


def inspect(stream: object) -> None:
    total = 0
    manifest: list[dict[str, object]] | None = None
    config_name: str | None = None
    config_bytes: bytes | None = None
    layer_names: set[str] | None = None
    seen_layers: set[str] = set()
    try:
        with tarfile.open(fileobj=stream, mode="r|") as archive:
            for member in archive:
                total += 512 + max(member.size, 0)
                if total > MAX_UNCOMPRESSED_BYTES:
                    raise InvalidImage("image exceeds the 2 GiB inspection budget")
                path = safe_path(member.name)
                if not member.isreg():
                    raise InvalidImage("outer archive contains a non-regular entry")
                if path == PurePosixPath("manifest.json"):
                    if manifest is not None:
                        raise InvalidImage("outer archive has duplicate manifests")
                    try:
                        manifest = json.loads(read_json(member, archive, 64 * 1024))
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        raise InvalidImage("image manifest is malformed") from error
                    if (
                        not isinstance(manifest, list) or len(manifest) != 1
                        or not isinstance(manifest[0], dict)
                        or set(manifest[0]) != {"Config", "RepoTags", "Layers"}
                        or not isinstance(manifest[0].get("Config"), str)
                        or not isinstance(manifest[0].get("Layers"), list)
                        or not manifest[0]["Layers"]
                        or not all(isinstance(item, str) for item in manifest[0]["Layers"])
                    ):
                        raise InvalidImage("image manifest schema differs")
                    config_name = manifest[0]["Config"]
                    layer_names = set(manifest[0]["Layers"])
                    if len(layer_names) != len(manifest[0]["Layers"]):
                        raise InvalidImage("image contains duplicate layers")
                    safe_path(config_name)
                    for name in layer_names:
                        safe_path(name)
                elif layer_names is not None and str(path) == config_name:
                    if config_bytes is not None:
                        raise InvalidImage("image config is duplicated")
                    config_bytes = read_json(member, archive, 4 * 1024 * 1024)
                elif layer_names is not None and str(path) in layer_names:
                    layer = archive.extractfile(member)
                    if layer is None:
                        raise InvalidImage("image layer is unreadable")
                    inspect_layer(layer)
                    seen_layers.add(str(path))
                elif (
                    layer_names is not None
                    and f"{path.parent.as_posix()}/layer.tar" in layer_names
                    and path.name in {"VERSION", "json"}
                ):
                    read_json(member, archive, 1024 * 1024)
                elif path != PurePosixPath("repositories"):
                    raise InvalidImage("outer archive contains an unexpected file")
    except (tarfile.TarError, OSError) as error:
        raise InvalidImage("image archive is malformed") from error

    if (
        manifest is None or config_name is None or layer_names is None
        or seen_layers != layer_names or not isinstance(config_bytes, bytes)
    ):
        raise InvalidImage("archive must contain one complete image")
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
        raise InvalidImage("image config has an unexpected runtime contract")
    labels = image_config.get("Labels")
    if (
        not isinstance(labels, dict)
        or "org.opencontainers.image.source" in labels
        or labels.get("org.opencontainers.image.base.name") != BASE_IMAGE
        or labels.get("com.meet.retention-proof.snapshot") != "20260918T000000Z"
        or not re.fullmatch(
            r"[0-9a-f]{64}", labels.get("com.meet.retention-proof.packages-sha256", "")
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}", labels.get("com.meet.retention-proof.dockerfile-sha256", "")
        )
    ):
        raise InvalidImage("image labels do not match the locked tools contract")
    history = config.get("history")
    if not isinstance(history, list) or not history:
        raise InvalidImage("image build history is missing")
    for entry in history:
        if not isinstance(entry, dict) or not isinstance(entry.get("created_by", ""), str):
            raise InvalidImage("image build history is malformed")
        if re.search(r"(^|\s)(COPY|ADD)\s", entry.get("created_by", ""), re.IGNORECASE):
            raise InvalidImage("image history copies unadmitted files")
    rootfs = config.get("rootfs")
    if (
        not isinstance(rootfs, dict) or rootfs.get("type") != "layers"
        or not isinstance(rootfs.get("diff_ids"), list)
        or len(rootfs["diff_ids"]) != len(seen_layers)
    ):
        raise InvalidImage("image root filesystem layer identity differs")


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
