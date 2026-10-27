#!/usr/bin/env python3
"""Pure, bounded admission for one approved pending LocationIQ OFF transition."""
import sys

sys.dont_write_bytecode = True

import argparse
import importlib.util
import json
import os
from pathlib import Path
import re

from test_vps_file_trust import Rejected, directory, private_file

SPEC = importlib.util.spec_from_file_location(
    "locationiq_off", Path(__file__).with_name("configure-test-vps-locationiq.py"))
off = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(off)
IMAGE = ("ghcr.io/nickolaymamonov/meet-backend-v3@"
         "sha256:1f2c56da34fa905553739f79bf91647d0087ec72159efc40828ba91622033d4b")
REVISION = "462b52b403c73027a262e183d1bd9ae4964938d8"
VERSION = "1.6.0"
LIMIT = 1_048_576
CONTROLLED = {"LOCATIONIQ_KEY", "GEOCODER_ENABLED"}


def approved(image, revision, version, image_id):
    if ((image, revision, version) != (IMAGE, REVISION, VERSION)
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id)):
        raise Rejected("unapproved_target")


def private_bytes(path):
    path = Path(path)
    parent = directory(path.parent)
    try:
        fd, data, _ = private_file(parent, path.name)
        os.close(fd)
        return data
    finally:
        os.close(parent)


def entries(items):
    result = {}
    for item in items:
        if not isinstance(item, str) or "=" not in item:
            raise Rejected("invalid_environment")
        name, value = item.split("=", 1)
        if (not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name)
                or name in result or off.ambiguous(name, value)):
            raise Rejected("ambiguous_environment")
        result[name] = value
    return result


def file_environment(data):
    if (len(data) > LIMIT or not data.endswith(b"\n") or b"$" in data
            or b"\r" in data.replace(b"\r\n", b"")
            or any(c < 32 and c not in (10, 13) for c in data)):
        raise Rejected("invalid_environment")
    lines = [line for line in data.decode("utf-8").splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    values = entries(lines)
    if values.get("GEOCODER_ENABLED") != "false":
        raise Rejected("explicit_off_required")
    off.validate_key(values.get("LOCATIONIQ_KEY", "").encode("utf-8"))
    return values


def compare_predecessor_environment(data, backend):
    """Apply the same narrow pending-key/OFF exception to a stopped record."""
    values = file_environment(data)
    observed = entries(backend["Config"]["Env"])
    for name, value in values.items():
        if name not in CONTROLLED and observed.get(name) != value:
            raise Rejected("unrelated_environment_changed")
    flag = observed.get("GEOCODER_ENABLED", "true")
    key = observed.get("LOCATIONIQ_KEY", "")
    if flag not in ("true", "false"):
        raise Rejected("invalid_runtime_flag")
    if key:
        off.validate_key(key.encode("utf-8"))
        if key != values["LOCATIONIQ_KEY"] or flag == "true":
            raise Rejected("predecessor_key_or_activation_conflict")
    return values


def one_record(value):
    if not isinstance(value, list) or len(value) != 1:
        raise Rejected("single_backend_required")
    backend = value[0]
    if (not re.fullmatch(r"[0-9a-f]{64}", backend["Id"])
            or backend["State"]["Running"] is not True
            or backend["State"]["Health"]["Status"] != "healthy"
            or not isinstance(backend["State"]["StartedAt"], str)
            or not backend["State"]["StartedAt"]
            or backend["Config"]["Labels"]["com.docker.compose.project"] != "meet-production"
            or backend["Config"]["Labels"]["com.docker.compose.service"] != "backend"
            or backend["Config"].get("Entrypoint") != ["java", "-jar", "app.jar"]
            or backend["Config"].get("Cmd") not in (None, [])):
        raise Rejected("unexpected_runtime")
    return backend


def stopped_predecessor_record(value, expected_id, expected_finished):
    """Validate a sole stopped Compose backend without claiming runtime health."""
    if not isinstance(value, list) or len(value) != 1:
        raise Rejected("single_backend_required")
    backend = value[0]
    state = backend.get("State")
    labels = backend.get("Config", {}).get("Labels", {})
    if (not isinstance(backend.get("Id"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", backend["Id"])
            or not isinstance(expected_id, str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected_id)
            or backend["Id"] != expected_id
            or not isinstance(state, dict)
            or state.get("Running") is not False
            or state.get("Status") != "exited"
            or type(state.get("ExitCode")) is not int
            or state.get("ExitCode") != 143
            or not isinstance(expected_finished, str)
            or state.get("FinishedAt") != expected_finished
            or state.get("Paused") is not False
            or state.get("Restarting") is not False
            or state.get("Dead") is not False
            or labels.get("com.docker.compose.project") != "meet-production"
            or labels.get("com.docker.compose.service") != "backend"
            or backend.get("Config", {}).get("Entrypoint") != ["java", "-jar", "app.jar"]
            or backend.get("Config", {}).get("Cmd") not in (None, [])):
        raise Rejected("unexpected_stopped_runtime")
    return backend


def verify(phase, data, records, image_id, previous_id="", previous_started="",
           pending=None, expected_id="", expected_started=""):
    values = file_environment(data)
    if phase == "stopped-predecessor":
        if (not previous_id or
                not re.fullmatch(r"[0-9a-f]{64}", previous_id)):
            raise Rejected("missing_stopped_identity")
        backend = stopped_predecessor_record(
            records, previous_id, "2026-10-26T17:30:24.669192243Z"
        )
        compare_predecessor_environment(data, backend)
        return
    backend = one_record(records)
    observed = entries(backend["Config"]["Env"])
    for name, value in values.items():
        if phase == "predecessor" and name in CONTROLLED:
            continue
        if observed.get(name) != value:
            raise Rejected("unrelated_environment_changed")
    if phase == "predecessor":
        compare_predecessor_environment(data, backend)
        if previous_id and (backend["Id"] != previous_id
                            or backend["State"]["StartedAt"] != previous_started):
            raise Rejected("predecessor_changed")
    elif phase == "candidate":
        if (not previous_id or not previous_started or pending is None
                or not expected_id or not expected_started):
            raise Rejected("missing_predecessor_binding")
        before = file_environment(pending)
        replacements = {"BACKEND_IMAGE": IMAGE, "BACKEND_REVISION": REVISION,
                        "BACKEND_VERSION": VERSION}
        lines = []
        for line in pending.decode("utf-8").splitlines(keepends=True):
            name = line.split("=", 1)[0]
            if name in replacements:
                ending = line[len(line.rstrip("\r\n")):]
                line = name + "=" + replacements[name] + ending
            lines.append(line)
        if (not set(replacements).issubset(before)
                or data != "".join(lines).encode("utf-8")
                or before["LOCATIONIQ_KEY"] != observed.get("LOCATIONIQ_KEY")
                or observed.get("GEOCODER_ENABLED") != "false"
                or backend["Id"] != expected_id
                or backend["State"]["StartedAt"] != expected_started
                or backend["Id"] == previous_id
                or backend["Image"] != image_id
                or backend["Config"]["Image"] != IMAGE
                or backend["Config"]["User"] != "10001:10001"):
            raise Rejected("candidate_changed")
        labels = backend["Config"]["Labels"]
        if (labels.get("org.opencontainers.image.revision") != REVISION
                or labels.get("org.opencontainers.image.version") != VERSION
                or labels.get("org.opencontainers.image.source") !=
                "https://github.com/NickolayMamonov/meet-backend-v3"):
            raise Rejected("candidate_image_changed")
    else:
        raise Rejected("invalid_phase")


def main():
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument("--phase", choices=("predecessor", "stopped-predecessor",
                                                 "candidate"), required=True)
        for name in ("env-file", "image", "revision", "version", "image-id"):
            parser.add_argument("--" + name, required=True)
        for name in ("previous-id", "previous-started", "pending-file",
                     "expected-stopped-id",
                     "expected-id", "expected-started"):
            parser.add_argument("--" + name, default="")
        args = parser.parse_args()
        approved(args.image, args.revision, args.version, args.image_id)
        raw = sys.stdin.buffer.read(LIMIT + 1)
        if len(raw) > LIMIT:
            raise Rejected("inspection_budget")
        records = json.loads(raw, object_pairs_hook=off.unique_object)
        verify(args.phase, private_bytes(args.env_file), records, args.image_id,
               args.previous_id, args.previous_started,
               private_bytes(args.pending_file) if args.pending_file else None,
               args.expected_id, args.expected_started)
        print('{"pendingLocationiqOff":true,"verified":true}')
        return 0
    except (Rejected, OSError, ValueError, KeyError, TypeError, AttributeError,
            RecursionError):
        print('{"pendingLocationiqOff":true,"verified":false}')
        return 1


if __name__ == "__main__":
    sys.exit(main())
