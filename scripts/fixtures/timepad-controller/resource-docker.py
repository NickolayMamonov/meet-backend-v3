#!/usr/bin/python3
"""Read-only Docker boundary for the real controller's resource observer.

Installed as CASE/bin/docker. Configuration is selected by the executable path,
not environment variables: the production observer intentionally clears its env.
"""

from __future__ import annotations

import json
import pathlib
import sys


def main() -> None:
    case = pathlib.Path(__file__).resolve().parent.parent
    observed = json.loads((case / "observed.json").read_bytes())
    arguments = sys.argv[1:]
    log = case / "docker-arguments.jsonl"
    if log.exists() and log.stat().st_size > 65536:
        raise SystemExit(90)
    with log.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(arguments, separators=(",", ":")) + "\n")

    def emit(value):
        print(json.dumps(value, separators=(",", ":")))

    def identities(values):
        for value in values:
            print(value)

    if arguments[:1] == ["ps"]:
        if arguments not in (
            ["ps", "--all", "--quiet", "--no-trunc"],
            ["ps", "--all", "--quiet", "--no-trunc", "--filter",
             "label=com.docker.compose.project=meet-production"],
        ):
            raise SystemExit(90)
        if "--filter" in arguments:
            identities(observed["projectInventory"])
        else:
            identities(item["Id"] for item in observed["daemonInventory"])
    elif arguments[:1] == ["compose"]:
        expected = [
            "compose", "-p", "meet-production", "--project-directory", str(case / "root"),
            "--env-file", str(case / "run/config.env.target"),
            "-f", str(case / "run/config.base-compose.yml"),
            "-f", str(case / "run/target-runtime.override.yml"),
            "ps", "--all", "--quiet",
        ]
        if arguments == expected:
            identities(observed["composeInventory"])
        elif arguments == expected + ["backend"]:
            identities(observed["backendInventory"])
        else:
            raise SystemExit(90)
    elif arguments == ["network", "ls", "--quiet", "--no-trunc"]:
        identities(item["ID"] for item in observed["networkInventory"])
    elif arguments == ["volume", "ls", "--quiet"]:
        identities(item["Name"] for item in observed["volumeInventory"])
    elif arguments[:2] in (
        ["container", "inspect"], ["network", "inspect"], ["volume", "inspect"],
    ):
        kind = arguments[0]
        field, key = {
            "container": ("containerInspections", "Id"),
            "network": ("networkInspections", "Id"),
            "volume": ("volumeInspections", "Name"),
        }[kind]
        emit([item for item in observed[field] if item[key] in arguments[2:]])
    elif arguments == ["image", "inspect", observed["postgresImageInspection"]["Id"]]:
        emit([observed["postgresImageInspection"]])
    else:
        # Includes all network/volume/container writes, Compose create/up,
        # prompt-producing commands and unrelated-service operations.
        raise SystemExit(90)


if __name__ == "__main__":
    main()
