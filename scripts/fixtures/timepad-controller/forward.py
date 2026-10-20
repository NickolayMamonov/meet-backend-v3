"""Synthetic external facts for the actual normal-forward controller fixture.

This module supplies no admission decisions, leases, requests, state transitions
or completion receipts. The four-method transport is constructor-injected only.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import stat
import sys
import time


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise AssertionError(reason)


def no_socket() -> None:
    require(not os.environ.get("DOCKER_HOST"), "fixture Docker host is not empty")
    require(not any(os.path.lexists(path) for path in (
        "/run/docker.sock", "/var/run/docker.sock",
    )), "fixture can see a Docker socket")


def tooling():
    import test_vps_timepad_create as create

    config = create.canonical({"cliPluginsExtraDirs": ["/opt/pinned"]}, 4096)
    executable = (1, 2, stat.S_IFREG | 0o755, 0, 0, 1, 32, 4, 5)
    return create.ToolingObservation(
        "/opt/pinned/docker", "/opt/pinned/docker-compose",
        (*executable, "c" * 64), (*executable, "d" * 64),
        "Docker version 28.3.3, build fixture", "2.39.4", "Linux", "x86_64",
        (1, 3, stat.S_IFREG | 0o600, 0, 0, 1, len(config), 4, 5),
        config, "/opt/pinned:/usr/bin:/bin",
        (1, 4, stat.S_IFSOCK | 0o660, 0, 0, 1, 0, 4, 5),
    )


def fixture_data(source: Path) -> dict:
    """Reuse independent inventory/inspect shapes, never their history/proof."""
    spec = importlib.util.spec_from_file_location(
        "_forward_external_shapes", source / "test-test-vps-provider-credential.py",
    )
    require(spec is not None and spec.loader is not None, "fixture fact source unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Only external observations leave these builders. In particular their
    # synthetic current/prepared/lease/receipt values never enter this harness.
    resources = module.resource_context("prepared")["observed"]
    _, image, _, _, _, _, _ = module.stopped_create_context(resource_only=True)
    image = copy.deepcopy(image)
    image_labels = image["Config"].get("Labels") or {}
    image["Config"]["Labels"] = {
        key: value for key, value in image_labels.items()
        if not key.startswith("com.docker.compose.")
    }
    require(
        not any(key.startswith("com.docker.compose.") for key in image["Config"]["Labels"]),
        "target image fixture retained runtime-generated Compose labels",
    )
    contract = copy.deepcopy(module.live_context("PREPARED")[1])
    contract["images"][1]["tuple"]["repositoryDigest"] = "0" * 64
    contract["tooling"] = {
        "dockerCliVersion": "28.3.3", "composeVersion": "2.39.4",
        "composeCommit": "a32dc3da722e6b2e4fbfc72e40b1a697c4686460",
        "dockerCliPath": "/opt/pinned/docker", "composePluginPath": "/opt/pinned/docker-compose",
        "dockerCliSha256": "c" * 64, "composePluginSha256": "d" * 64,
        "platform": "linux/amd64", "provenanceRef": "fixed-source-fixture",
    }
    model = resources.pop("targetConfiguration")
    model["services"]["backend"]["environment"].update(
        BACKEND_IMAGE="ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "1" * 64,
        BACKEND_REVISION="3" * 40, BACKEND_VERSION="1.2.3",
    )
    model["services"]["backend"]["healthcheck"]["test"] = [
        "CMD", "curl", "--fail", "--silent", "--show-error", "http://127.0.0.1:8080/meetings",
    ]
    backend = next(item for item in resources["containerInspections"]
                   if item["Config"]["Labels"]["com.docker.compose.service"] == "backend")
    predecessor_image = copy.deepcopy(image)
    predecessor_image["Id"] = "sha256:" + "a" * 64
    predecessor_image["RepoDigests"] = [
        "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "0" * 64,
    ]
    predecessor_image["Config"]["Labels"].update({
        "org.opencontainers.image.revision": "b" * 40,
        "org.opencontainers.image.version": "1.2.2",
    })
    backend["Image"] = predecessor_image["Id"]
    backend["Config"]["Image"] = predecessor_image["RepoDigests"][0]
    backend["Config"]["Labels"].update(predecessor_image["Config"]["Labels"])
    backend["Config"]["Labels"]["com.docker.compose.image"] = predecessor_image["Id"]
    backend["State"]["Health"] = {"Status": "healthy"}
    # These are the actual pre-deploy observations. The fake Docker boundary
    # changes restart policy and connectivity only after the controller has
    # published the corresponding exact runtime intent.
    backend["NetworkSettings"]["Ports"] = {
        "8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "18080"}],
    }
    backend["Config"]["Env"] += [
        "BACKEND_IMAGE=" + predecessor_image["RepoDigests"][0],
        "BACKEND_REVISION=" + "b" * 40, "BACKEND_VERSION=1.2.2",
    ]
    resources["daemonInventory"] = [
        {"Id": item["Id"], "Names": item["Name"].removeprefix("/"),
         "Labels": copy.deepcopy(item["Config"]["Labels"])}
        for item in resources["containerInspections"]
    ]
    return {
        "contract": contract, "model": model, "image": image,
        "predecessorImage": predecessor_image, "resources": resources,
    }


class ForwardTransport:
    """Only external facts and a real fixed no-start child, not a driver."""

    def __init__(
        self, case: Path, facts: dict, *, recovery_runtime: Path | None = None,
        diagnostics: bool = False,
    ):
        self.case, self.facts = case, facts
        self.recovery_runtime = recovery_runtime
        self.diagnostics = diagnostics

    def identity(self, stage, context):
        import test_vps_timepad_create as create

        if self.diagnostics:
            transport_event(self.case, "identity")
        no_socket()
        context.check_time()
        require(isinstance(stage, create.Stage), "unexpected tooling stage")
        return tooling()

    def render(self, view, context):
        import test_vps_timepad_create as create

        no_socket()
        context.check_time()
        require(self.recovery_runtime is None, "historical recovery requested a create model")
        require(isinstance(view, create.View), "unexpected model view")
        model = copy.deepcopy(self.facts["model"])
        override = Path(context.run, "target-runtime.override.yml").read_text()
        tokens = re.findall(r'org\.meet\.timepad\.operation: "([a-f0-9]{32})"', override)
        require(len(tokens) == 1, "operation token is not frozen")
        model["services"]["backend"]["labels"]["org.meet.timepad.operation"] = tokens[0]
        return create.canonical(model, create.MAX_MODEL)

    def observe(self, context):
        import test_vps_timepad_create as create

        if self.diagnostics:
            transport_event(self.case, "observe")
        no_socket()
        context.check_time()
        if self.recovery_runtime is not None:
            require(self.recovery_runtime == self.case / "runtime.json",
                    "historical runtime input is not fixed")
            backend = json.loads(self.recovery_runtime.read_bytes())
            fault = (self.case / "fault").read_text()
            missing = fault in {"missing", "missing-request-proof"} or (
                fault in {"replace", "create-fails", "create-intent"}
                and not (self.case / "created").exists()
            )
            inventory = [] if missing else [backend["Id"]]
            if fault == "unknown-inventory":
                inventory = ["a" * 64]
            return create.canonical({
                "resources": {
                    "containerInspections": [] if missing else [backend],
                    "backendInventory": inventory, "composeInventory": inventory,
                },
                "imageInspection": [],
            }, create.MAX_EVIDENCE)
        value = json.loads((self.case / "forward-runtime.json").read_bytes())
        resources = copy.deepcopy(self.facts["resources"])
        backend = value["backend"]
        resources["containerInspections"] = [
            item for item in resources["containerInspections"]
            if item["Config"]["Labels"]["com.docker.compose.service"] != "backend"
        ] + [backend]
        postgres = resources["containerInspections"][0]
        resources["backendInventory"] = [backend["Id"]]
        resources["projectInventory"] = [postgres["Id"], backend["Id"]]
        resources["composeInventory"] = [backend["Id"], postgres["Id"]]
        resources["daemonInventory"] = [
            {"Id": item["Id"], "Names": item["Name"].removeprefix("/"),
             "Labels": item["Config"]["Labels"]}
            for item in resources["containerInspections"]
        ]
        network = resources["networkInspections"][0]
        network["Containers"] = {
            identity: item for identity, item in network["Containers"].items()
            if identity == postgres["Id"]
        }
        endpoint = backend["NetworkSettings"]["Networks"]["meet-production_default"]
        if endpoint["EndpointID"]:
            network["Containers"][backend["Id"]] = {
                "Name": backend["Name"].removeprefix("/"), "EndpointID": endpoint["EndpointID"],
                "MacAddress": endpoint["MacAddress"],
                "IPv4Address": endpoint["IPAddress"] + "/16", "IPv6Address": "",
            }
        return create.canonical({
            "resources": resources, "imageInspection": [self.facts["image"]],
        }, create.MAX_EVIDENCE)

    def spawn_create(self, context, control_fds):
        import test_vps_timepad_create as create

        if self.diagnostics:
            transport_event(self.case, "spawn_create")
        no_socket()
        context.check_time()
        require(self.recovery_runtime is None, "historical recovery attempted create")
        require(control_fds == (9,), "fixture create inherited unexpected authority")
        model = create.parse(self.render(create.View.FROZEN_TARGET, context), create.MAX_MODEL)
        path = self.case / "forward-runtime.json"
        value = json.loads(path.read_bytes())
        require(not value["created"], "fixture attempted a second initial create")
        backend = copy.deepcopy(value["backend"])
        require(not backend["State"]["Running"], "create raced running predecessor")
        require(backend["HostConfig"]["RestartPolicy"]["Name"] == "no",
                "create raced unsuppressed predecessor")
        endpoint = backend["NetworkSettings"]["Networks"]["meet-production_default"]
        require(not endpoint["EndpointID"], "create raced a connected predecessor")
        backend.update(Id="a" * 64, Image=self.facts["image"]["Id"], RestartCount=0)
        backend["Config"].update(copy.deepcopy(self.facts["image"]["Config"]))
        backend["Config"].update(
            Image=model["services"]["backend"]["image"],
            Env=self.facts["image"]["Config"]["Env"] + [
                key + "=" + item for key, item in model["services"]["backend"]["environment"].items()
            ],
        )
        backend["Config"]["Healthcheck"]["Test"] = model["services"]["backend"]["healthcheck"]["test"]
        backend["HostConfig"]["RestartPolicy"] = {"Name": "unless-stopped", "MaximumRetryCount": 0}
        backend["Config"]["Labels"].update({
            **model["services"]["backend"]["labels"],
            "com.docker.compose.project": "meet-production", "com.docker.compose.service": "backend",
            "com.docker.compose.config-hash": "1" * 64,
            "com.docker.compose.container-number": "1", "com.docker.compose.oneoff": "False",
            "com.docker.compose.version": "2.39.4",
            "com.docker.compose.image": self.facts["image"]["Id"],
        })
        backend["State"] = {
            "Status": "created", "Running": False, "Paused": False, "Restarting": False,
            "Dead": False, "OOMKilled": False, "Pid": 0, "ExitCode": 0, "Error": "",
            "StartedAt": "0001-01-01T00:00:00Z", "FinishedAt": "0001-01-01T00:00:00Z",
        }
        endpoint = backend["NetworkSettings"]["Networks"]["meet-production_default"]
        endpoint.update(EndpointID="", IPAddress="", Gateway="", IPPrefixLen=0, MacAddress="")
        endpoint["DNSNames"] = ["backend", "meet-production-backend-1", backend["Id"][:12]]
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        pid = os.fork()
        if pid == 0:
            try:
                os.close(write_fd)
                # Keep the external command alive until its actual identity
                # is captured. EOF/deadline refuses if the launcher disappears.
                remaining = max(0, (context.end_ns - time.monotonic_ns()) / create.NS)
                require(select.select([read_fd], [], [], remaining)[0]
                        and os.read(read_fd, 1) == b"1", "fixture child startup expired")
                os.close(read_fd)
                null = os.open("/dev/null", os.O_RDWR)
                for fd in (0, 1, 2):
                    os.dup2(null, fd)
                for name in os.listdir("/proc/self/fd"):
                    fd = int(name)
                    if fd > 2 and fd not in control_fds:
                        try:
                            os.close(fd)
                        except OSError:
                            pass
                no_socket()
                with path.open("w") as stream:
                    json.dump({"backend": backend, "created": True}, stream)
                os._exit(0)
            except BaseException:
                os._exit(1)
        os.close(read_fd)
        pidfd = None
        try:
            start = create._process_start(pid)
            pidfd = os.pidfd_open(pid, 0)
            result = create.SpawnedCreate(pid, pidfd, start)
            require(os.write(write_fd, b"1") == 1, "fixture child startup failed")
            return result
        except BaseException:
            if pidfd is not None:
                os.close(pidfd)
            raise
        finally:
            os.close(write_fd)


def trace(case: Path, operation: str) -> None:
    with (case / "forward-effects").open("ab") as stream:
        require(stream.tell() < 65536, "fixture effect trace exceeded bound")
        stream.write(operation.encode("ascii") + b"\n")


def transport_event(case: Path, operation: str) -> None:
    """Bounded fixture-only trace for constructor-injected recovery evidence."""
    path = case / "recovery-transport-events"
    with path.open("ab") as stream:
        require(stream.tell() < 4096, "fixture transport trace exceeded bound")
        stream.write(operation.encode("ascii") + b"\n")


def projection(item: dict, form: str):
    fields = {
        "{{.Id}}": ("Id",), "{{.Image}}": ("Image",),
        "{{.Config.User}}": ("Config", "User"),
        "{{.State.Running}}": ("State", "Running"),
        "{{.State.Health.Status}}": ("State", "Health", "Status"),
        "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}": ("State", "Health", "Status"),
        "{{.HostConfig.ReadonlyRootfs}}": ("HostConfig", "ReadonlyRootfs"),
        "{{.HostConfig.RestartPolicy.Name}}": ("HostConfig", "RestartPolicy", "Name"),
        "{{.HostConfig.LogConfig.Type}}": ("HostConfig", "LogConfig", "Type"),
        "{{.HostConfig.Memory}}": ("HostConfig", "Memory"),
    }
    json_fields = {
        "{{json .Config.Env}}": ("Config", "Env"),
        "{{json .Mounts}}": ("Mounts",),
        "{{json .NetworkSettings.Ports}}": ("NetworkSettings", "Ports"),
        "{{json .NetworkSettings.Networks}}": ("NetworkSettings", "Networks"),
        "{{json .HostConfig.CapDrop}}": ("HostConfig", "CapDrop"),
        "{{json .HostConfig.SecurityOpt}}": ("HostConfig", "SecurityOpt"),
        "{{json .HostConfig.Tmpfs}}": ("HostConfig", "Tmpfs"),
        "{{json .Config.Healthcheck.Test}}": ("Config", "Healthcheck", "Test"),
    }
    if form in fields or form in json_fields:
        value = item
        for key in (fields | json_fields)[form]:
            value = value[key]
        return json.dumps(value) if form in json_fields else (
            str(value).lower() if type(value) is bool else str(value)
        )
    labels = item["Config"].get("Labels", {})
    for key in (
        "org.opencontainers.image.revision", "org.opencontainers.image.version",
        "org.opencontainers.image.source", "com.docker.compose.project",
        "com.docker.compose.service", "com.docker.compose.config-hash",
    ):
        if form == '{{index .Config.Labels "' + key + '"}}':
            return labels[key]
    if form == "{{range .Config.Env}}{{println .}}{{end}}":
        return "\n".join(item["Config"]["Env"])
    for destination in ("/data/uploads", "/var/lib/postgresql/data"):
        if form == ('{{range .Mounts}}{{if eq .Destination "' + destination +
                    '"}}{{printf "%s|%s\\n" .Type .Name}}{{end}}{{end}}'):
            return "\n".join(mount["Type"] + "|" + mount["Name"] for mount in item["Mounts"]
                             if mount["Destination"] == destination)
    if form == ('{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "8080/tcp"}}'
                '{{range $bindings}}{{.HostIp}}:{{.HostPort}}{{println}}{{end}}{{end}}{{end}}'):
        return "127.0.0.1:18080"
    raise AssertionError("fixture rejected unknown inspection format")


def docker(case: Path, arguments: list[str], facts: dict) -> None:
    """Fixed shell-side external facts; no Compose create fallback is admitted."""
    no_socket()
    path = case / "forward-runtime.json"
    value = json.loads(path.read_bytes())
    backend = value["backend"]
    postgres = next(item for item in facts["resources"]["containerInspections"]
                    if item["Config"]["Labels"]["com.docker.compose.service"] == "postgres")
    images = {
        facts["image"]["Id"]: facts["image"],
        facts["predecessorImage"]["Id"]: facts["predecessorImage"],
        facts["model"]["services"]["backend"]["image"]: facts["image"],
        facts["predecessorImage"]["RepoDigests"][0]: facts["predecessorImage"],
    }
    if arguments[:1] == ["compose"]:
        prefix = [
            "compose", "-p", "meet-production", "--project-directory", str(case / "root"),
            "--env-file", ".env.production",
        ]
        require(arguments[:len(prefix)] == prefix, "fixture rejected Compose context")
        tail = arguments[len(prefix):]
        files = []
        while tail[:1] == ["-f"] and len(tail) >= 2:
            files.append(tail[1])
            tail = tail[2:]
        allowed = {
            str(case / "compose.yml"), str(case / "root/docker-compose.production.yml"),
            "/var/lib/meet-production/active-compose.yml",
            "/var/lib/meet-production/active-runtime.override.yml",
        }
        require(1 <= len(files) <= 2 and set(files) <= allowed,
                "fixture rejected Compose input vector")
        if tail in (["ps", "-q", "backend"], ["ps", "-aq", "backend"]):
            print(backend["Id"])
        elif tail == ["ps", "-q", "postgres"]:
            print(postgres["Id"])
        elif tail == ["port", "backend", "8080"]:
            print("127.0.0.1:18080")
        else:
            raise AssertionError("fixture rejected unknown shell Compose action")
        return
    if arguments[:2] == ["image", "inspect"] and len(arguments) in {3, 5}:
        item = images[arguments[2]]
        tail = arguments[3:]
    elif arguments[:1] == ["inspect"] and len(arguments) in {2, 4}:
        require(arguments[1] in {backend["Id"], postgres["Id"]}, "fixture inspected foreign container")
        item = backend if arguments[1] == backend["Id"] else postgres
        tail = arguments[2:]
    else:
        item, tail = None, None
    if item is not None:
        if not tail:
            print(json.dumps([item]))
        else:
            require(len(tail) == 2 and tail[0] == "--format", "fixture rejected inspection arguments")
            print(projection(item, tail[1]))
        return
    if arguments in (
        ["exec", backend["Id"], "id", "-u"], ["exec", backend["Id"], "id", "-g"],
    ):
        print("10001")
        return
    if arguments == ["exec", backend["Id"], "sh", "-ec", "test -w /data/uploads"]:
        return
    if arguments == ["port", postgres["Id"]]:
        return
    if len(arguments) == 3 and arguments[:2] == ["volume", "inspect"]:
        volumes = [item for item in facts["resources"]["volumeInspections"] if item["Name"] == arguments[2]]
        require(len(volumes) == 1, "fixture inspected foreign volume")
        print(json.dumps(volumes))
        return
    operations = {
        ("update", "--restart=no", backend["Id"]): "suppress",
        ("stop", "--time", "10", backend["Id"]): "stop",
        ("start", backend["Id"]): "start",
        ("update", "--restart=unless-stopped", backend["Id"]): "restore-policy",
    }
    operation = operations.get(tuple(arguments))
    require(operation is not None, "fixture rejected unknown Docker action")
    import test_vps_timepad_state as guard

    with guard.deploy_lock(str(case / "state"), 9):
        _, current = guard._read_guard_locked(str(case / "state"))
        request = current["runtimeRequest"]
        require(request is not None and request["lifecycle"] == "intent"
                and request["operation"] == operation and request["containerId"] == backend["Id"],
                "runtime write preceded its exact durable intent")
        if operation == "start":
            require(value["created"] and current["containerId"] == backend["Id"]
                    and current["phase"] == "VERIFYING" and current["ownedChild"] is not None
                    and current["ownedChild"]["lifecycle"] == "released",
                    "candidate start preceded binding or owned-child release")
    trace(case, operation + ":" + backend["Id"])
    scenario = (case / "forward-scenario").read_text()
    if scenario == "stop-refused" and operation == "stop":
        raise SystemExit(90)
    if scenario == "suppress-refused" and operation == "suppress":
        raise SystemExit(90)
    if operation == "suppress":
        if value["created"]:
            require(
                backend["State"]["Status"] == "created"
                and not backend["State"]["Running"]
                and backend["HostConfig"]["RestartPolicy"]["Name"] == "unless-stopped",
                "candidate suppression did not target the stopped no-start candidate",
            )
        else:
            require(
                backend["State"]["Running"]
                and backend["HostConfig"]["RestartPolicy"]["Name"] == "unless-stopped",
                "fixture suppression did not target the running predecessor",
            )
        backend["HostConfig"]["RestartPolicy"]["Name"] = "no"
    elif operation == "stop":
        require(backend["State"]["Running"]
                and backend["HostConfig"]["RestartPolicy"]["Name"] == "no",
                "fixture stop preceded suppression")
        backend["State"].update(Status="exited", Running=False, Pid=0)
        endpoint = backend["NetworkSettings"]["Networks"]["meet-production_default"]
        endpoint.update(EndpointID="", IPAddress="", Gateway="", IPPrefixLen=0, MacAddress="")
    elif operation == "start":
        backend["State"].update(Status="running", Running=True, Pid=456,
                                Health={"Status": "healthy"}, StartedAt="2026-10-01T02:00:00Z")
    else:
        backend["HostConfig"]["RestartPolicy"]["Name"] = "unless-stopped"
    with path.open("w") as stream:
        json.dump(value, stream)
    print(backend["Id"])


def main() -> int:
    require(len(sys.argv) >= 4, "fixture external adapter arguments missing")
    kind, root, *arguments = sys.argv[1:]
    case = Path(root)
    no_socket()
    if kind == "curl":
        require(arguments == ["--fail", "--silent", "--show-error", "http://127.0.0.1:18080/meetings"],
                "fixture rejected unknown HTTP request")
        print("[]")
    else:
        require(kind == "docker", "fixture rejected external adapter kind")
        docker(case, arguments, json.loads((case / "forward-facts.json").read_bytes()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
