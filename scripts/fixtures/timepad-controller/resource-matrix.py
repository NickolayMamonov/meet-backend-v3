#!/usr/bin/env python3
"""Resource-only real-observer/validator matrix, not create/receipt acceptance.

The portable mode executes only the actual pure admission validator. Linux mode
also executes the actual shared-driver observer with injected external facts.
No guard state, execution lease, create receipt or success grant is manufactured.
"""

from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import shutil
import stat
import sys
import time

import recovery

sys.path.insert(0, str(recovery.SOURCE))

CASES = pathlib.Path("/var/lib/timepad-fixture/case-resource-matrix")
CANARIES = ("PRIVATE_DATABASE_CANARY", "PRIVATE_HEALTH_CANARY", "never-print-me")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


class Matrix:
    def __init__(self, portable):
        self.portable = portable
        self.fixtures = recovery.load(
            "controller_resource_data", recovery.SOURCE / "test-test-vps-provider-credential.py",
        )
        self.helper = self.fixtures.helper
        self.count = 0
        self.refused = 0
        if not portable:
            recovery.require_isolated(CASES)
            CASES.mkdir(mode=0o700)
        self.observer_digest = hashlib.sha256(
            (recovery.SOURCE / "test_vps_timepad_create.py").read_bytes(),
        ).hexdigest()

    def observe(self, value):
        if self.portable:
            return copy.deepcopy(value["observed"])
        case = CASES / f"row-{self.count}"
        case.mkdir(mode=0o700)
        for directory in ("tools", "run", "root", "docker-config"):
            (case / directory).mkdir(mode=0o700)
        require(not pathlib.Path("/run/docker.sock").exists() and
                not pathlib.Path("/var/run/docker.sock").exists(),
                "resource fixture can see a Docker socket")
        shutil.copyfile(
            recovery.SOURCE / "test_vps_timepad_create.py", case / "tools/test_vps_timepad_create.py",
        )
        # Stage the actual module next to a fixture-only contract. Only external
        # identity/CLI observations are synthetic; no comparator is replaced.
        config = canonical({"cliPluginsExtraDirs": ["/opt/resource-fixture"]})
        contract = json.loads((recovery.SOURCE / "test-vps-timepad-release-contracts.json").read_bytes())
        contract["tooling"] = {
            "dockerCliVersion": "28.3.3", "composeVersion": "2.39.4",
            "composeCommit": "a32dc3da722e6b2e4fbfc72e40b1a697c4686460",
            "dockerCliPath": "/opt/resource-fixture/docker",
            "composePluginPath": "/opt/resource-fixture/docker-compose",
            "dockerCliSha256": "c" * 64, "composePluginSha256": "d" * 64,
            "platform": "linux/amd64", "provenanceRef": "fixture-only-external-facts",
        }
        recovery.private(case / "tools/test-vps-timepad-release-contracts.json", canonical(contract))
        recovery.private(case / "observed.json", canonical(value["observed"]))
        names = ("observed.json", "tools/test-vps-timepad-release-contracts.json")
        before = {name: (case / name).read_bytes() for name in names}
        create = recovery.load("resource_create_" + str(self.count), case / "tools/test_vps_timepad_create.py")
        info = (1, 2, stat.S_IFREG | 0o755, 0, 0, 1, 32, 4, 5)
        identity = create.ToolingObservation(
            contract["tooling"]["dockerCliPath"], contract["tooling"]["composePluginPath"],
            (*info, "c" * 64), (*info, "d" * 64),
            "Docker version 28.3.3, build fixture", "2.39.4", "Linux", "x86_64",
            (1, 3, stat.S_IFREG | 0o600, 0, 0, 1, len(config), 4, 5),
            config, "/opt/resource-fixture:/usr/bin:/bin",
            (1, 4, stat.S_IFSOCK | 0o600, 0, 0, 1, 0, 4, 5),
        )
        selection = create.Selection(
            str(case / "root"), str(case / "root/compose.yml"),
            value["observed"]["targetConfiguration"]["services"]["backend"]["image"],
            "b" * 40, "1.4.1", "run", "deploy", "deploy",
        )
        context = create.CreateContext(
            str(case), selection, time.monotonic_ns() + 30 * create.NS,
            create.Role.INITIAL, run_name="run",
        )
        observed = value["observed"]
        calls = []

        class ExternalFacts(create.RealTransport):
            def identity(self, stage, context):
                context.check_time()
                return identity

            def _run(self, command, environment, context, limit, **kwargs):
                context.check_time()
                require(command[0] == identity.cli, "resource observer selected an unknown executable")
                arguments = command[1:]
                calls.append(arguments)
                compose = self._compose(context, identity)[1:] + ["ps", "--all", "--quiet"]
                if arguments == ["ps", "--all", "--quiet", "--no-trunc", "--filter",
                                 "label=com.docker.compose.project=meet-production"]:
                    result = "\n".join(observed["projectInventory"]).encode()
                elif arguments == ["ps", "--all", "--quiet", "--no-trunc"]:
                    result = "\n".join(item["Id"] for item in observed["daemonInventory"]).encode()
                elif arguments == compose or arguments == compose + ["backend"]:
                    result = "\n".join(observed[
                        "composeInventory" if arguments == compose else "backendInventory"
                    ]).encode()
                elif arguments == ["network", "ls", "--quiet", "--no-trunc"]:
                    result = "\n".join(item["ID"] for item in observed["networkInventory"]).encode()
                elif arguments == ["volume", "ls", "--quiet"]:
                    result = "\n".join(item["Name"] for item in observed["volumeInventory"]).encode()
                elif arguments[:2] in (["container", "inspect"], ["network", "inspect"], ["volume", "inspect"]):
                    field, key = {
                        "container": ("containerInspections", "Id"),
                        "network": ("networkInspections", "Id"),
                        "volume": ("volumeInspections", "Name"),
                    }[arguments[0]]
                    result = canonical([item for item in observed[field] if item[key] in arguments[2:]])
                elif arguments == ["image", "inspect", observed["postgresImageInspection"]["Id"]]:
                    result = canonical([observed["postgresImageInspection"]])
                elif arguments == ["image", "inspect", context.selection.image]:
                    # Target image admission is not under test in this matrix.
                    result = canonical([{"Id": "sha256:" + "1" * 64}])
                else:
                    raise AssertionError("resource observer attempted a non-read-only command")
                require(len(result) <= limit, "external observation exceeded supplied bound")
                return result

        failure = None
        try:
            result = create.parse(ExternalFacts().observe(context), create.MAX_EVIDENCE)
        except create.CreateError as error:
            failure = error
        require(all((case / name).read_bytes() == data for name, data in before.items()),
                "resource observation changed frozen inputs")
        require(all(not any((case / name).iterdir()) for name in ("run", "root", "docker-config")),
                "resource observation wrote configuration or client state")
        require(0 < len(calls) <= 16, "resource observation command inventory is unbounded/empty")
        for call in calls:
            require(
                call[0] == "ps" or call[:2] in (
                    ["container", "inspect"], ["network", "inspect"], ["network", "ls"],
                    ["volume", "inspect"], ["volume", "ls"], ["image", "inspect"],
                ) or call[0] == "compose" and call[-3:] in (
                    ["ps", "--all", "--quiet"], ["--all", "--quiet", "backend"],
                ),
                "resource matrix attempted a create/start/write/prompt/unrelated mutation",
            )
        require(not pathlib.Path("/run/docker.sock").exists() and
                not pathlib.Path("/var/run/docker.sock").exists(),
                "resource fixture exposed a Docker socket")
        if failure is not None:
            require(not any(secret in str(failure) for secret in CANARIES),
                    "resource observer failure leaked private evidence")
            raise self.helper.ProviderError("RESOURCE_EVIDENCE_UNAVAILABLE")
        return dict(result["resources"], targetConfiguration=copy.deepcopy(observed["targetConfiguration"]))

    def row(self, name, value, *, refuse=False):
        self.count += 1
        before = canonical(value)
        result = None
        try:
            observed = self.observe(value)
            result = self.helper._resource_admission(dict(value, observed=observed))
        except self.helper.ProviderError as error:
            require(refuse, "unexpected resource refusal: " + name)
            require(not any(secret in str(error) for secret in CANARIES),
                    "resource refusal leaked a private canary")
            self.refused += 1
        else:
            require(not refuse, "resource fault accepted: " + name)
            require(result is not None, "resource admission produced no result")
            require(not any(secret in json.dumps(result) for secret in CANARIES),
                    "resource admission leaked a private canary")
        require(canonical(value) == before, "resource admission mutated caller evidence")
        print(f"CONTROLLER_RESOURCE_ROW_PASS: {name} expected={'refuse' if refuse else 'admit'} "
              f"mode={'portable-validator' if self.portable else 'controller-observer-validator'}",
              flush=True)
        return result

    def run(self):
        initial = self.row("prepared", self.fixtures.resource_context())
        request = self.row("pre-release", self.fixtures.resource_context(
            "pre-release", baseline=initial["baseline"],
        ))
        post = self.fixtures.resource_context(
            "post-create", baseline=initial["baseline"], request_baseline=request["membership"],
        )
        for stage in ("post-create", "completion", "recovery"):
            value = self.fixtures.resource_context(
                stage, baseline=initial["baseline"], request_baseline=request["membership"],
            )
            admitted = self.row(stage, value)
            require(admitted["baselineDigest"] == initial["baselineDigest"],
                    "create/completion/recovery changed postgres/resource baseline")

        def change(value, path, replacement):
            target = value
            for part in path[:-1]:
                target = target[part]
            target[path[-1]] = replacement

        # These are external observations only, not invented state/receipts.
        faults = [
            ("compose-project-disagreement", ("composeInventory",), ["a" * 64]),
            ("duplicate-compose-backend", ("composeInventory",), ["a" * 64, "a" * 64, "9" * 64]),
            ("duplicate-project", ("projectInventory",), ["a" * 64, "a" * 64, "9" * 64]),
            ("extra-project-orphan", ("projectInventory",), ["a" * 64, "9" * 64, "b" * 64]),
            ("zero-backend", ("backendInventory",), []),
            ("two-backends", ("backendInventory",), ["a" * 64, "b" * 64]),
            ("truncated-id", ("backendInventory",), ["a" * 12]),
            ("overbound-inventory", ("composeInventory",), [f"{i:064x}" for i in range(257)]),
            ("wrong-operation-token", ("containerInspections", 1, "Config", "Labels",
                                       "org.meet.timepad.operation"), "b" * 32),
            ("started-before-bind", ("containerInspections", 1, "State", "Running"), True),
            ("postgres-restart-drift", ("containerInspections", 0, "RestartCount"), 1),
            ("postgres-policy-drift", ("containerInspections", 0, "HostConfig",
                                       "RestartPolicy", "Name"), "no"),
            ("postgres-start-identity", ("containerInspections", 0, "State", "StartedAt"), "2026-10-02T00:00:00Z"),
            ("foreign-network", ("networkInspections", 0, "Labels", "com.docker.compose.project"), "foreign"),
            ("network-driver", ("networkInspections", 0, "Driver"), "overlay"),
            ("network-options", ("networkInspections", 0, "Options"), {"fixture": "drift"}),
            ("network-ipam", ("networkInspections", 0, "IPAM", "Driver"), "foreign"),
            ("network-internal", ("networkInspections", 0, "Internal"), True),
            ("missing-network", ("networkInventory",), []),
            ("missing-uploads-volume", ("volumeInspections",), [post["observed"]["volumeInspections"][1]]),
            ("foreign-uploads-volume", ("volumeInspections", 0, "Labels", "com.docker.compose.project"), "foreign"),
            ("volume-driver", ("volumeInspections", 0, "Driver"), "foreign"),
            ("volume-options", ("volumeInspections", 0, "Options"), {"fixture": "drift"}),
            ("volume-replaced", ("volumeInspections", 0, "CreatedAt"), "2026-10-02T00:00:00Z"),
        ]
        for name, path, replacement in faults:
            value = copy.deepcopy(post)
            change(value["observed"], path, replacement)
            self.row(name, value, refuse=True)
        for running in (False, True):
            value = copy.deepcopy(post)
            observed = value["observed"]
            foreign = copy.deepcopy(observed["containerInspections"][1])
            foreign.update(Id="b" * 64, Name="/foreign-volume-consumer")
            foreign["State"]["Running"] = running
            foreign["Config"]["Labels"] = {}
            observed["containerInspections"].append(foreign)
            observed["daemonInventory"].append({
                "Id": foreign["Id"], "Names": foreign["Name"][1:], "Labels": {},
            })
            self.row("foreign-volume-consumer-" + ("running" if running else "stopped"),
                     value, refuse=True)
        for kind, collection in (("network", "networkInventory"), ("volume", "volumeInventory")):
            value = copy.deepcopy(post)
            value["observed"][collection].append(copy.deepcopy(value["observed"][collection][0]))
            self.row("duplicate-" + kind, value, refuse=True)
        value = copy.deepcopy(post)
        value["observed"]["targetConfiguration"]["services"]["postgres"]["environment"]["POSTGRES_DB"] = "drift"
        self.row("postgres-model-drift", value, refuse=True)
        for kind, name, expected in (
            ("network", "meet-production_default", "651a5af4f59f899aca7027226897ea961dc4ba78e1393476a384a4c1fae14b93"),
            ("volume", "meet-production_uploads_data", "78a0524f844d4a7831e437be30f8c0796c6961fff0747ffefccaa04e539210d8"),
            ("volume", "meet-production_postgres_data", "c9794a292b1aa7332d8a736ead7de859b448c36f30412cc70375f35806251a74"),
        ):
            require(self.helper._resource_hash(kind, name) == expected,
                    "pinned fixed-resource hash bytes changed: " + name)
        for kind, collection, index in (
            ("network", "networkInspections", 0),
            ("volume", "volumeInspections", 0),
            ("volume", "volumeInspections", 1),
        ):
            for variant in ("absent", "empty", "equal", "divergent"):
                value = self.fixtures.resource_context()
                observed = value["observed"]
                inspected = observed[collection][index]
                key = "com.docker.compose.config-hash"
                if variant != "absent":
                    inspected["Labels"][key] = {
                        "empty": "", "equal": self.helper._resource_hash(kind, inspected["Name"]),
                        "divergent": "f" * 64,
                    }[variant]
                    inventory = "networkInventory" if kind == "network" else "volumeInventory"
                    observed[inventory][index]["Labels"][key] = inspected["Labels"][key]
                self.row(f"{kind}-{index}-hash-{variant}", value,
                         refuse=variant == "divergent" or kind == "volume" and variant == "empty")
        print(f"CONTROLLER_RESOURCE_MATRIX_PASS: rows={self.count} refused={self.refused} "
              f"observer_sha256={self.observer_digest} "
              "scope=resource-evidence-only create_receipt_binding_success=NOT_PROVEN",
              flush=True)


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--portable"]):
        raise SystemExit(2)
    Matrix(portable=sys.argv[1:] == ["--portable"]).run()
