#!/usr/bin/env python3
"""Shared-driver contracts and isolated Linux pipe/wait tests.

``--portable`` is evidence for pure validation and public-selector refusal only.
Neither this suite nor its portable mode claims the complete controller matrix.
"""

from __future__ import annotations

import argparse
import ast
from contextlib import ExitStack, nullcontext
from dataclasses import FrozenInstanceError, replace
import hashlib
import importlib.util
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import test_vps_timepad_create as create
import test_vps_timepad_supervisor as supervisor

SCRIPTS = Path(__file__).resolve().parent


def arguments() -> list[str]:
    return [
        "--root", "/opt/meet", "--base-compose", "/opt/tooling/docker-compose.production.yml",
        "--image", "ghcr.io/nickolaymamonov/meet-backend-v3@sha256:" + "a" * 64,
        "--revision", "b" * 40, "--version", "1.3.0", "--run-key", "123-1", "--mode", "deploy",
    ]


def context(*, seconds: float = 3) -> create.CreateContext:
    return create.CreateContext(
        "/var/lib/meet-test-vps-deploy", create.Selection.from_arguments(arguments()),
        time.monotonic_ns() + int(seconds * create.NS), create.Role.INITIAL,
        run_name="123-1-final-deploy",
    )


def tooling() -> tuple[create.ToolingObservation, dict]:
    plugin = "/opt/pinned/docker-compose"
    config = create.canonical({"cliPluginsExtraDirs": ["/opt/pinned"]}, 4096)
    info = (1, 2, stat.S_IFREG | 0o755, 0, 0, 1, 32, 4, 5)
    observation = create.ToolingObservation(
        "/opt/pinned/docker", plugin, (*info, "c" * 64), (*info, "d" * 64),
        "Docker version 28.3.3, build fixture", "2.39.4", "Linux", "x86_64",
        (1, 3, stat.S_IFREG | 0o600, 0, 0, 1, len(config), 4, 5),
        config, "/opt/pinned:/usr/bin:/bin", (1, 4, stat.S_IFSOCK | 0o660, 0, 0, 1, 0, 4, 5),
    )
    return observation, {"tooling": {
        "dockerCliVersion": "28.3.3", "composeVersion": "2.39.4",
        "composeCommit": "a32dc3da722e6b2e4fbfc72e40b1a697c4686460",
        "dockerCliPath": "/opt/pinned/docker", "composePluginPath": plugin,
        "dockerCliSha256": "c" * 64, "composePluginSha256": "d" * 64,
        "platform": "linux/amd64", "provenanceRef": "fixed-source-fixture",
    }}


class Contracts(unittest.TestCase):
    def forward_fixture(self):
        path = SCRIPTS / "fixtures/timepad-controller/forward.py"
        spec = importlib.util.spec_from_file_location("_forward_fixture_contract", path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_forward_external_facts_use_real_pinned_tooling_and_resource_comparators(self):
        fixture = self.forward_fixture()
        facts = fixture.fixture_data(SCRIPTS)
        self.assertEqual({
            "contract", "model", "image", "predecessorImage", "resources",
        }, set(facts))
        self.assertEqual(64, len(create.validate_tooling(fixture.tooling(), facts["contract"])))
        provider = create._provider()
        provider._create_backend_model(facts["model"], "a" * 32)
        envelope = provider._resource_envelope(
            stage="prepared", role={
                "operationToken": "a" * 32, "backendContainerId": "f" * 64,
                "priorBackendContainerId": None, "allowEmptyBackend": False,
            }, observed=dict(facts["resources"], targetConfiguration=facts["model"]),
        )
        result = provider._resource_admission(envelope)
        self.assertEqual(64, len(result["baselineDigest"]))
        self.assertEqual("f" * 64, result["membership"]["backendContainerId"])
        self.assertNotEqual(facts["image"]["Id"], facts["predecessorImage"]["Id"])
        self.assertNotEqual(facts["model"]["services"]["backend"]["image"],
                            facts["predecessorImage"]["RepoDigests"][0])
        backend = next(item for item in facts["resources"]["containerInspections"]
                       if item["Id"] == "f" * 64)
        self.assertTrue(backend["State"]["Running"])
        self.assertEqual("unless-stopped", backend["HostConfig"]["RestartPolicy"]["Name"])

    def test_forward_fixture_keeps_four_method_transport_and_refuses_unknown_external_actions(self):
        fixture = self.forward_fixture()
        facts = fixture.fixture_data(SCRIPTS)
        source = (SCRIPTS / "fixtures/timepad-controller/forward.py").read_text()
        tree = ast.parse(source)
        transport = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                         and node.name == "ForwardTransport")
        self.assertEqual({"__init__", "identity", "render", "observe", "spawn_create"}, {
            node.name for node in transport.body if isinstance(node, ast.FunctionDef)
        })
        for forbidden in ("waitpid", "publish_current", "_atomic_write", "prepare_terminal", "lease-ack"):
            self.assertNotIn(forbidden, source)
        backend = next(item for item in facts["resources"]["containerInspections"]
                       if item["Id"] == "f" * 64)
        with tempfile.TemporaryDirectory() as directory:
            case = Path(directory)
            path = case / "forward-runtime.json"
            path.write_bytes(create.canonical({"backend": backend, "created": False}, create.MAX_EVIDENCE))
            before = path.read_bytes()
            # Pure negative adapter contracts do not need a Linux socket probe.
            with mock.patch.object(fixture, "no_socket"):
                for arguments in (
                    ["compose", "up"], ["start", "foreign"], ["exec", backend["Id"], "sh"],
                    ["inspect", backend["Id"], "--format", "{{unknown}}"],
                    ["volume", "inspect", "foreign"],
                ):
                    with self.subTest(arguments=arguments), self.assertRaises(AssertionError):
                        fixture.docker(case, arguments, facts)
            self.assertEqual(before, path.read_bytes())
            self.assertFalse((case / "forward-effects").exists())

    def recovery_case(self, stack, *, operation="stop", lifecycle="completed"):
        """Portable branch test only; kernel/registration proof is not mocked acceptance."""
        observed_tooling, contract = tooling()
        current = {
            "ownedRun": context().run_name, "phase": "VERIFYING",
            "containerId": "e" * 64, "runtimeRequest": {
                "operation": operation, "lifecycle": lifecycle, "resourceRequestDigest": "f" * 64,
            },
        }
        inspection = {"Id": current["containerId"]}
        resources = {
            "containerInspections": [inspection], "backendInventory": [inspection["Id"]],
            "composeInventory": [inspection["Id"]],
        }
        transport = mock.Mock(spec=create.Transport)
        transport.identity.return_value = observed_tooling
        transport.observe.return_value = create.canonical({
            "resources": resources, "imageInspection": [],
        }, create.MAX_EVIDENCE)
        provider = mock.Mock()
        provider._operation_deadline.side_effect = lambda _: nullcontext()
        stack.enter_context(mock.patch.object(create, "_provider", return_value=provider))
        stack.enter_context(mock.patch.object(create, "_contract", return_value=contract))
        stack.enter_context(mock.patch.object(create.guard, "deploy_lock", return_value=nullcontext()))
        state_read = stack.enter_context(mock.patch.object(
            create.guard, "_read_guard_locked", return_value=({}, current),
        ))
        inputs = stack.enter_context(mock.patch.object(
            create.CreateContext, "input_identities", return_value=("one", "two", "three"),
        ))
        stack.enter_context(mock.patch.object(create.guard, "_open_root", return_value=123))
        stack.enter_context(mock.patch.object(create.guard, "_read_at", return_value=b"authorization"))
        stack.enter_context(mock.patch.object(create.os, "close"))
        binding = stack.enter_context(mock.patch.object(create, "recovery_binding", return_value={"bound": True}))
        driver = create.CreateDriver(context(), transport, mock.Mock(attempt="a" * 32))
        stack.enter_context(mock.patch.object(driver, "_recovery_authority"))
        models = stack.enter_context(mock.patch.object(
            driver, "_models", return_value=({}, create.validate_tooling(observed_tooling, contract)),
        ))
        stack.enter_context(mock.patch.object(driver, "_run_fd", return_value=nullcontext(321)))
        return driver, provider, transport, current, resources, models, inputs, state_read, binding

    def test_legacy_evidence_uses_pinned_observation_and_strict_request_proof_only(self):
        for operation in ("suppress", "stop", "start", "restore-policy"):
            for lifecycle in ("acknowledged", "completed"):
                with self.subTest(operation=operation, lifecycle=lifecycle), ExitStack() as stack:
                    driver, provider, transport, current, resources, models, *_ = self.recovery_case(
                        stack, operation=operation, lifecycle=lifecycle,
                    )
                    binding, raw = driver.recovery_evidence()
                    self.assertEqual({"bound": True}, binding)
                    evidence = create.parse(raw, create.guard.MAX_RECOVERY_RUNTIME_BYTES)
                    self.assertEqual({
                        "inspection": resources["containerInspections"],
                        "backendInventory": resources["backendInventory"],
                        "composeInventory": resources["composeInventory"],
                    }, evidence)
                    provider._recovery_lease_runtime_proof.assert_called_once_with(
                        driver.context.state_root, current, b"authorization", raw, 9, driver.context.check_time,
                    )
                    self.assertEqual(2, transport.identity.call_count)
                    transport.observe.assert_called_once_with(driver.context)
                    models.assert_not_called()
                    transport.render.assert_not_called()
                    transport.spawn_create.assert_not_called()
                    provider._prepared_proof.assert_not_called()
                    provider._prepared_target.assert_not_called()
                    provider._prepared_environment.assert_not_called()
                    provider._read_resource_request.assert_not_called()

    def test_legacy_evidence_refuses_proof_tooling_inputs_state_and_inventory_uncertainty(self):
        for fault in (
            "proof", "missing-pin", "changed-pin", "inputs", "state",
            "missing-request", "prepared", "foreign", "duplicate", "expired",
        ):
            with self.subTest(fault=fault), ExitStack() as stack:
                driver, provider, transport, current, resources, _, inputs, state_read, binding = self.recovery_case(stack)
                if fault == "proof":
                    provider._recovery_lease_runtime_proof.side_effect = create.CreateError("proof refused")
                elif fault == "missing-pin":
                    stack.enter_context(mock.patch.object(create, "_contract", return_value={}))
                elif fault == "changed-pin":
                    first = transport.identity.return_value
                    transport.identity.side_effect = [first, replace(first, socket_identity=(2, *first.socket_identity[1:]))]
                elif fault == "inputs":
                    inputs.side_effect = [("one",), ("changed",)]
                elif fault == "state":
                    state_read.side_effect = [({}, current), ({}, dict(current, phase="COMMITTING"))]
                elif fault == "missing-request":
                    current["runtimeRequest"] = None
                elif fault == "prepared":
                    current["phase"] = "PREPARED"
                elif fault in {"foreign", "duplicate"}:
                    resources["containerInspections"] = (
                        [{"Id": "f" * 64}] if fault == "foreign"
                        else resources["containerInspections"] * 2
                    )
                    transport.observe.return_value = create.canonical({
                        "resources": resources, "imageInspection": [],
                    }, create.MAX_EVIDENCE)
                elif fault == "expired":
                    driver.context = replace(driver.context, end_ns=time.monotonic_ns() - 1)
                with self.assertRaises(create.CreateError):
                    driver.recovery_evidence()
                binding.assert_not_called()
                transport.spawn_create.assert_not_called()
                if fault in {"missing-pin", "missing-request", "prepared", "expired"}:
                    transport.observe.assert_not_called()

    def test_create_evidence_retains_frozen_model_prepared_and_resource_checks(self):
        for lifecycle in ("normal-completed", "bound", "intent"):
            with self.subTest(lifecycle=lifecycle), ExitStack() as stack:
                driver, provider, transport, current, resources, models, *_ = self.recovery_case(
                    stack, operation="create", lifecycle=lifecycle,
                )
                stack.enter_context(mock.patch.object(driver, "_observations", return_value=(resources, [])))
                provider._read_resource_request.return_value = {"membership": "frozen"}
                if lifecycle == "intent":
                    with self.assertRaisesRegex(create.CreateError, "RUNTIME_REQUEST_QUIESCENCE_UNCONFIRMED"):
                        driver.recovery_evidence()
                else:
                    _, raw = driver.recovery_evidence()
                    evidence = create.parse(raw, create.guard.MAX_RECOVERY_RUNTIME_BYTES)
                    self.assertEqual({"membership": "frozen"}, evidence["requestBaseline"])
                    self.assertEqual(resources, evidence["resourceEvidence"])
                    self.assertIn("targetConfiguration", evidence)
                    self.assertIn("imageInspection", evidence)
                models.assert_called_once_with(installed=True, stage=create.Stage.RENDER)
                provider._prepared_proof.assert_called_once_with(321, current)
                provider._prepared_target.assert_called_once_with(321, current, [], {})
                provider._prepared_environment.assert_called_once_with(321, current)
                provider._read_resource_request.assert_called_once_with(321, "f" * 64)
                provider._recovery_lease_runtime_proof.assert_not_called()
                transport.spawn_create.assert_not_called()

    def test_recovery_binding_preserves_legacy_request_context_and_all_frozen_inputs(self):
        value = context()
        current = {
            "ownedRun": value.run_name, "originDigest": "a" * 64, "incidentId": "b" * 32,
            "operationEpoch": 1, "runtimeRequest": {"operation": "stop", "sequence": 1},
            "preparedProofDigest": "c" * 64,
        }
        with mock.patch.object(create.guard, "deploy_lock", return_value=nullcontext()), \
                mock.patch.object(create.guard, "_read_guard_locked", return_value=({}, current)) as read, \
                mock.patch.object(create.CreateContext, "input_identities", return_value=("one", "two", "three")) as inputs:
            original = create.recovery_binding(value, "d" * 32)
            self.assertEqual("a" * 64, original["originDigest"])
            self.assertEqual("b" * 32, original["incidentId"])
            self.assertEqual(1, original["operationEpoch"])
            self.assertEqual("d" * 32, original["attempt"])
            self.assertEqual("c" * 64, original["preparedProofDigest"])
            self.assertEqual(value.end_ns, original["endNs"])
            self.assertEqual(hashlib.sha256(create.canonical(current["runtimeRequest"], 4096)).hexdigest(),
                             original["requestDigest"])
            for index in range(3):
                changed = ["one", "two", "three"]
                changed[index] = "changed"
                inputs.return_value = tuple(changed)
                self.assertNotEqual(original["inputDigest"], create.recovery_binding(value, "d" * 32)["inputDigest"])
            inputs.return_value = ("one", "two", "three")
            changed_context = replace(value, selection=replace(value.selection, recovery_run="other-run"))
            self.assertNotEqual(original["contextDigest"], create.recovery_binding(changed_context, "d" * 32)["contextDigest"])
            inputs.side_effect = [("one", "two", "three"), ("one", "two", "changed")]
            with self.assertRaises(create.CreateError):
                create.recovery_binding(value, "d" * 32)
            inputs.side_effect = None
            read.side_effect = [({}, current), ({}, dict(current, operationEpoch=2))]
            with self.assertRaises(create.CreateError):
                create.recovery_binding(value, "d" * 32)

    def shell_functions(self, *names: str) -> str:
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text()
        # Top-level controller functions end with an unindented brace.
        return "\n".join(
            name + "() {" + source.split(name + "() {", 1)[1].split("\n}", 1)[0] + "\n}"
            for name in names
        )

    def run_shell(self, source: str) -> subprocess.CompletedProcess:
        bash = r"C:\Program Files\Git\bin\bash.exe" if sys.platform == "win32" else "bash"
        result = subprocess.run(
            [bash, "-c", "set -euo pipefail\n" + source],
            stdin=subprocess.DEVNULL, capture_output=True, timeout=20,
        )
        self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
        return result

    def test_runtime_mutation_rejects_invalid_invocation_before_any_intent_or_docker(self):
        functions = self.shell_functions("timepad_runtime_mutate")
        for invocation in (
            "", "stop", "start " + "a" * 64, "stop short",
            "stop " + "A" * 64, "stop " + "a" * 64 + " extra",
        ):
            with self.subTest(invocation=invocation):
                result = self.run_shell(functions + """
timepad_request_begin() { echo unexpected-intent; }
timepad_request_preflight() { echo unexpected-preflight; }
timeout() { echo unexpected-docker; }
timepad_request_acknowledge() { echo unexpected-ack; }
timepad_request_complete() { echo unexpected-completion; }
if timepad_runtime_mutate """ + invocation + """; then exit 90; fi
""")
                self.assertEqual(b"", result.stdout)

    def test_runtime_mutation_requires_ordered_exact_synchronous_response(self):
        functions = self.shell_functions("timepad_runtime_mutate")
        container = "a" * 64
        for operation in ("suppress", "stop", "restore-policy"):
            for failure in ("none", "intent", "preflight", "docker", "wrong-id", "empty", "ack", "proof"):
                with self.subTest(operation=operation, failure=failure):
                    # Stubs are external boundaries only; execute the actual
                    # shell function and record child-command effects via stderr.
                    result = self.run_shell(functions + """
timepad_request_begin() { echo intent >&2; [ "$failure" != intent ]; }
timepad_request_preflight() { echo preflight >&2; [ "$failure" != preflight ]; }
timeout() {
  echo docker >&2
  [ "$failure" != docker ] || return 1
  case "$failure" in wrong-id) echo wrong;; empty) :;; *) echo "$container";; esac
}
timepad_request_acknowledge() {
  [ "$1" = "$container" ] || return 91
  echo ack >&2; [ "$failure" != ack ]
}
timepad_request_complete() { echo proof >&2; [ "$failure" != proof ]; }
""" + f"container={container}\nfailure={failure}\n" + """
if timepad_runtime_mutate """ + operation + """ "$container"; then
  [ "$failure" = none ]
else
  [ "$failure" != none ]
fi
""")
                    trace = result.stderr.decode().splitlines()
                    expected = ["intent"]
                    if failure != "intent":
                        expected.append("preflight")
                    if failure not in ("intent", "preflight"):
                        expected.append("docker")
                    if failure not in ("intent", "preflight", "docker", "wrong-id", "empty"):
                        expected.append("ack")
                    if failure in ("none", "proof"):
                        expected.append("proof")
                    self.assertEqual(expected, trace)

    def test_predecessor_refusal_never_reaches_barrier_create_or_start(self):
        functions = self.shell_functions("guarded_candidate_start")
        for failure in ("suppress", "stop", "none"):
            with self.subTest(failure=failure):
                result = self.run_shell(functions + """
previous_container=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
previous_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
recovery_work_check() { :; }
stopped=false
compose() { echo "$previous_container"; }
jq() { case "$*" in *project*) echo meet-production;; *) echo backend;; esac; }
docker_container_inspect() {
  case "$*" in
    *Image*) echo "$previous_id";;
    *Running*) if [ "$stopped" = true ]; then echo false; else echo true; fi;;
    *RestartPolicy*) echo no;;
    *) echo matching;;
  esac
}
timepad_runtime_mutate() {
  echo "$1" >&2
  [ "$1" != "$failure" ] || return 1
  if [ "$1" = stop ]; then stopped=true; fi
}
timeout() { echo raw-docker >&2; exit 92; }
timepad_advance() { echo barrier >&2; exit 97; }
run_owned_child() { echo create-or-start >&2; exit 94; }
fail() { echo "$1" >&2; exit 95; }
""" + f"failure={failure}\n" + """
set +e
( guarded_candidate_start )
status=$?
if [ "$failure" = none ]; then [ "$status" -eq 97 ]; else [ "$status" -eq 95 ]; fi
""")
                expected = ["suppress"] + (["stop"] if failure != "suppress" else [])
                self.assertEqual(expected + (["barrier"] if failure == "none" else ["RECOVERY_REQUIRED"]),
                                 result.stderr.decode().splitlines())

    def test_state_admission_alone_never_releases_rollback_mutation(self):
        functions = self.shell_functions("rollback_worker_admission")
        for state_admitted in (True, False):
            with self.subTest(state_admitted=state_admitted):
                result = self.run_shell(functions + """
timepad_helper=fixed-helper
state_root=fixed-root
timeout() { return """ + ("0" if state_admitted else "1") + """; }
fail() { echo "$1" >&2; exit 96; }
set +e
( rollback_worker_admission; echo unexpected-rollback-writer )
status=$?
[ "$status" -eq 96 ]
""")
                self.assertEqual(b"", result.stdout)
                self.assertEqual(
                    b"ROLLBACK_NOT_ADMITTED\n", result.stderr,
                )

    def test_actions_and_transport_are_closed_and_evidence_only(self):
        self.assertEqual({
            "admit-target", "publish-prepared", "verify-target", "create", "reconcile-bound",
        }, {action.value for action in create.Action})
        tree = ast.parse((SCRIPTS / "test_vps_timepad_create.py").read_text())
        protocol = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Transport")
        self.assertEqual({"identity", "render", "observe", "spawn_create"}, {
            node.name for node in protocol.body if isinstance(node, ast.FunctionDef)
        })
        self.assertNotIn("__main__", (SCRIPTS / "test_vps_timepad_create.py").read_text())
        imports = [ast.unparse(node) for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom))]
        self.assertFalse(any("supervisor" in line or "fixtures" in line for line in imports))

    def test_fixed_selection_refuses_commands_duplicates_and_transport_selectors(self):
        selected = create.Selection.from_arguments(arguments())
        self.assertEqual("/opt/meet", selected.deployment_root)
        for extra in (
            ["--transport", "fixture"], ["--create-transport", "fixture"],
            ["--argv", "sh"], ["--root", "/other"], ["--", "sh"],
        ):
            with self.subTest(extra=extra), self.assertRaises(create.CreateError):
                create.Selection.from_arguments(arguments() + extra)
        for path in ("/opt/../tmp", "/opt//meet", "relative", "/opt/./meet"):
            changed = arguments()
            changed[1] = path
            with self.subTest(path=path), self.assertRaises(create.CreateError):
                create.Selection.from_arguments(changed)

    def test_context_and_evidence_are_immutable_and_deadline_is_absolute(self):
        value = context()
        with self.assertRaises(FrozenInstanceError):
            value.end_ns += create.NS
        with self.assertRaises(FrozenInstanceError):
            value.selection.image = "other"
        with self.assertRaises(create.CreateError):
            replace(value, lock_fd=8)
        with self.assertRaises(create.CreateError):
            replace(value, run_name="../foreign")
        with self.assertRaisesRegex(create.CreateError, "WAIT_EXPIRED"):
            replace(value, end_ns=time.monotonic_ns() - 1).check_time()
        observed, _ = tooling()
        with self.assertRaises(FrozenInstanceError):
            observed.cli_version = "other"

    def test_shared_tooling_comparator_admits_exact_pins(self):
        observed, contract = tooling()
        digest = create.validate_tooling(observed, contract)
        self.assertRegex(digest, r"^[a-f0-9]{64}$")
        self.assertEqual(digest, create.validate_tooling(observed, contract))
        self.assertNotEqual(digest, create.validate_tooling(
            replace(observed, socket_identity=(*observed.socket_identity[:1], 99, *observed.socket_identity[2:])),
            contract,
        ))

    def test_shared_tooling_comparator_refuses_each_fact_drift(self):
        observed, contract = tooling()
        cases = (
            {"cli_version": "Docker version 29.0.0, build fixture"},
            {"compose_version": "2.40.0"}, {"system": "Windows"}, {"architecture": "ppc64le"},
            {"cli": "/tmp/docker"}, {"plugin": "/tmp/docker-compose"},
            {"cli_identity": (*observed.cli_identity[:-1], "f" * 64)},
            {"plugin_identity": (*observed.plugin_identity[:-1], "f" * 64)},
            {"config": b"{}"}, {"trusted_path": "/tmp:/usr/bin:/bin"},
            {"config_identity": (1, 3, stat.S_IFREG | 0o644, 0, 0, 1, len(observed.config), 4, 5)},
            {"socket_identity": (1, 4, stat.S_IFSOCK | 0o666, 0, 0, 1, 0, 4, 5)},
            {"socket_identity": (1, 4, stat.S_IFREG | 0o600, 0, 0, 1, 0, 4, 5)},
        )
        for changes in cases:
            with self.subTest(changes=tuple(changes)), self.assertRaises(create.CreateError):
                create.validate_tooling(replace(observed, **changes), contract)
        for key in contract["tooling"]:
            changed = {"tooling": dict(contract["tooling"])}
            del changed["tooling"][key]
            with self.subTest(key=key), self.assertRaises(create.CreateError):
                create.validate_tooling(observed, changed)

    def test_model_and_result_bounds_duplicate_keys_and_private_payloads(self):
        for raw in (b'{"a":1,"a":2}', b'{"a":NaN}', b"[" * 1100):
            with self.subTest(raw=raw[:32]), self.assertRaises(create.CreateError):
                create.parse(raw, create.MAX_MODEL)
        with self.assertRaises(create.CreateError):
            create.parse(b" " * (create.MAX_MODEL + 1), create.MAX_MODEL)
        with self.assertRaises(create.CreateError):
            create.canonical({"private": "x" * create.MAX_MODEL}, create.MAX_MODEL)
        result = create.DriverResult(create.Action.CREATE, "a" * 64, "b" * 64, "c" * 64, "d" * 64)
        self.assertLess(len(create.canonical(result.frame(), 4096)), 4096)
        self.assertEqual({"action", "modelDigest", "toolingDigest", "containerId", "configHash"}, set(result.frame()))
        with self.assertRaises(create.CreateError):
            replace(result, container_id="PRIVATE_MODEL_CANARY").frame()

    def test_public_factory_and_internal_stage_do_not_select_or_reexec(self):
        tree = ast.parse((SCRIPTS / "test_vps_timepad_supervisor.py").read_text())
        factory = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "production_supervisor")
        source = ast.unparse(factory)
        self.assertIn("create_transport=RealTransport()", source)
        self.assertNotIn("environ", source)
        self.assertNotIn("getattr", source)
        stage = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "_fixed_create_stage")
        stage_source = ast.unparse(stage)
        self.assertIn("CreateDriver", stage_source)
        self.assertIn("wait_create", stage_source)
        self.assertNotIn("execvpe", stage_source)
        self.assertNotIn("--timepad-private-create", (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text())
        shell = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text()
        for removed in (
            "timepad_create_tooling_check()", "timepad_target_compose()",
            "timepad_resource_observation()", "timepad_private_create_request()",
            "create-launch --role", "create-completion --request-digest",
        ):
            self.assertNotIn(removed, shell)

    def test_driver_and_evidence_forks_fence_signals_and_adopt_descendants(self):
        tree = ast.parse((SCRIPTS / "test_vps_timepad_supervisor.py").read_text())
        implementation = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Supervisor")
        for name in ("_launch_driver", "_launch_recovery_evidence"):
            method = next(node for node in implementation.body if isinstance(node, ast.FunctionDef) and node.name == name)
            source = ast.unparse(method)
            with self.subTest(method=name):
                self.assertIn("self.pending_signals", source)
                self.assertIn("linux_preflight()", source)
                self.assertLess(source.index("self.pending_signals"), source.index("os.fork()"))
        source = ast.unparse(ast.parse((SCRIPTS / "test_vps_timepad_create.py").read_text()))
        self.assertIn("os.waitpid(-1, os.WNOHANG)", source)

    def test_actual_stage_refuses_expired_wrong_or_revoked_grant_before_observation(self):
        value = context()
        grant = {
            "name": "create-execute", "role": "controller-worker", "attempt": "a" * 32,
            "endNs": value.end_ns, "grantId": "b" * 32,
        }

        class NoObservation:
            def identity(self, *args):
                raise AssertionError("unauthorized stage observed tooling")

        class Client:
            attempt = "a" * 32

            def request(self, kind, **fields):
                self.assertion(kind, fields)
                return {}

            @staticmethod
            def assertion(kind, fields):
                if kind != "validate-grant" or fields != {"grantId": "b" * 32, "endNs": value.end_ns}:
                    raise AssertionError("stage attempted an unrelated RPC")

        for stage in ("release-admission", "execute", "completion-admission"):
            for delta in (
                {}, {"name": "provider"}, {"role": "rollback-worker"},
                {"attempt": "f" * 32}, {"endNs": value.end_ns - 1},
            ):
                with self.subTest(stage=stage, delta=delta), self.assertRaises(create.CreateError):
                    create.CreateDriver(value, NoObservation(), Client()).check_stage(
                        stage, dict(grant, **delta), "c" * 64,
                    )
            with self.subTest(stage=stage, expired=True), self.assertRaisesRegex(create.CreateError, "WAIT_EXPIRED"):
                create.CreateDriver(
                    replace(value, end_ns=time.monotonic_ns() - 1), NoObservation(), Client(),
                ).check_stage(stage, grant, "c" * 64)

    def test_actual_worker_fixture_has_only_explicit_constructor_injection(self):
        path = SCRIPTS / "fixtures/timepad-controller/create-controller.py"
        tree = ast.parse(path.read_text())
        source = ast.unparse(tree)
        self.assertIn("create_transport=fake", source)
        self.assertIn("instance.run()", source)
        self.assertNotIn("mock", source)
        self.assertNotIn("Timing(", source)
        self.assertNotIn("clock=", source)
        self.assertNotIn(".spawn =", source)
        self.assertNotIn(".waitpid =", source)
        self.assertNotIn(".publish_current", source)
        self.assertNotIn("docker.sock').bind", source)
        fake = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                    and node.name == "RefusingTransport")
        self.assertEqual({"_unexpected", "identity", "render", "observe", "spawn_create"}, {
            node.name for node in fake.body if isinstance(node, ast.FunctionDef)
        })

    def test_production_main_rejects_crafted_transport_flags_in_subprocess(self):
        for flags in (
            ["--transport", "fake"], ["--create-transport", "fake"], ["--fixture", "true"],
            ["relay", "--root", "/not-created", "--operation", "deploy", "--transport", "fake"],
        ):
            completed = subprocess.run(
                [sys.executable, "-B", str(SCRIPTS / "test_vps_timepad_supervisor.py"), *flags],
                stdin=subprocess.DEVNULL, capture_output=True, timeout=5,
            )
            self.assertEqual(2, completed.returncode, completed.stderr.decode(errors="replace"))
            self.assertNotIn(b"Traceback", completed.stderr)

    def test_public_environment_and_pythonpath_do_not_import_fixture_adapter(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "imported"
            adapter = Path(directory) / "sentinel_adapter.py"
            adapter.write_text("from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n")
            environment = dict(
                os.environ, PYTHONPATH=directory, TIMEPAD_CREATE_TRANSPORT="sentinel_adapter",
                TIMEPAD_FIXTURE="sentinel_adapter", DOCKER_HOST="unix:///nonexistent-selector.sock",
            )
            completed = subprocess.run([
                sys.executable, "-B", str(SCRIPTS / "test_vps_timepad_supervisor.py"),
                "relay", "--root", directory, "--operation", "deploy", "--", *arguments(),
            ], env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=8)
            self.assertNotEqual(0, completed.returncode)
            self.assertFalse(marker.exists())
            self.assertNotIn(b"sentinel_adapter", completed.stdout + completed.stderr)

    def test_driver_wait_uses_original_endpoint_and_not_default_short_timeout(self):
        tree = ast.parse((SCRIPTS / "test_vps_timepad_supervisor.py").read_text())
        worker = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "WorkerClient")
        request = next(node for node in worker.body if isinstance(node, ast.FunctionDef) and node.name == "request")
        source = ast.unparse(request)
        self.assertIn("kind == 'create-driver'", source)
        self.assertIn("end = self.end_ns", source)
        self.assertNotIn("self.end_ns =", source)


@unittest.skipUnless(sys.platform == "linux", "Linux pipe, pidfd and ECHILD evidence")
class LinuxBoundaries(unittest.TestCase):
    def _pipe(self, data: bytes, expected: dict, *, seconds: float = 2) -> bytes:
        read_fd, write_fd = os.pipe2(os.O_CLOEXEC)
        try:
            if len(data) > 4096:
                self.fail("fixture record must fit the bounded pipe buffer")
            os.write(write_fd, data)
            os.close(write_fd)
            write_fd = -1
            return create.read_evidence(read_fd, expected, time.monotonic_ns() + int(seconds * create.NS))
        finally:
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def test_exact_pipe_record_and_all_uncertainty_shapes(self):
        expected = {"attempt": "a" * 32, "currentDigest": "b" * 64, "endNs": 12345}
        evidence = b'{"inspection":[]}'
        header = create.canonical(dict(expected, size=len(evidence), digest=hashlib.sha256(evidence).hexdigest()), 4096)
        record = len(header).to_bytes(4, "big") + header + evidence
        self.assertEqual(evidence, self._pipe(record, expected))
        for bad in (b"", record[:3], record[:-1], record + record, record + b"x"):
            with self.subTest(size=len(bad)), self.assertRaises(create.CreateError):
                self._pipe(bad, expected)
        for key in expected:
            changed = dict(expected, **{key: "mismatch"})
            with self.subTest(key=key), self.assertRaises(create.CreateError):
                self._pipe(record, changed)
        with self.assertRaises(create.CreateError):
            self._pipe(record, expected, seconds=-1)

    def test_constructor_injection_survives_a_real_fork(self):
        class Fake:
            pass
        fake = Fake()
        parent, child = supervisor.socket_pair()
        read_fd, write_fd = os.pipe()
        try:
            instance = supervisor.Supervisor("/not-opened", "deploy", arguments(), child, create_transport=fake)
            pid = os.fork()
            if pid == 0:
                os.close(read_fd)
                os.write(write_fd, b"same" if instance.create_transport is fake else b"wrong")
                os._exit(0)
            os.close(write_fd)
            write_fd = -1
            self.assertEqual(b"same", os.read(read_fd, 5))
            self.assertEqual((pid, 0), os.waitpid(pid, 0))
        finally:
            parent.close()
            child.close()
            os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def test_real_wait_requires_zero_status(self):
        # Keep waitpid(-1) proof in an isolated process. Earlier Supervisor
        # tests make this runner a subreaper, so unrelated fixture children
        # must not be adopted by this wait test.
        for status in (0, 7):
            pid = os.fork()
            if pid == 0:
                child_pid = os.fork()
                if child_pid == 0:
                    time.sleep(0.05)
                    os._exit(status)
                start = create._process_start(child_pid)
                child = create.SpawnedCreate(
                    child_pid, os.pidfd_open(child_pid, 0), start,
                )
                try:
                    create.wait_create(child, context())
                except create.CreateError:
                    os._exit(0 if status != 0 else 10)
                os._exit(0 if status == 0 else 11)
            waited, raw = os.waitpid(pid, 0)
            self.assertEqual(pid, waited)
            self.assertEqual(0, os.waitstatus_to_exitcode(raw))


@unittest.skipUnless(sys.platform == "linux", "actual controller requires isolated Linux/root")
class LinuxActualController(unittest.TestCase):
    """Real worker bootstrap/refusals, explicitly not successful create coverage."""

    def run_case(self, scenario: str):
        parent = Path("/var/lib/timepad-fixture")
        parent.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="case-create-worker-", dir=parent) as temporary:
            case = Path(temporary)
            command = [
                "timeout", "--signal=TERM", "--kill-after=5s", "100s",
                sys.executable, "-B", str(SCRIPTS / "fixtures/timepad-controller/create-controller.py"),
                "--case", str(case), "--scenario", scenario,
            ]
            result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=110)
            self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
            self.assertLessEqual(len(result.stdout) + len(result.stderr), 65536)
            self.assertIn(b"create_pipeline=NOT_PROVEN", result.stdout)
            self.assertFalse(os.path.lexists("/run/docker.sock"))
            self.assertFalse(os.path.lexists("/var/run/docker.sock"))
            self.assertFalse((case / "transport-calls").exists(), "refused worker released create")
            fixtures = SCRIPTS / "fixtures/timepad-controller"
            for installed, fixture in (
                (".env.production", "root-env"), ("docker-compose.production.yml", "compose.yml"),
            ):
                self.assertEqual((fixtures / fixture).read_bytes(),
                                 (case / "root" / installed).read_bytes())
            reply = create.parse((case / "relay-result.json").read_bytes(), supervisor.MAX_FRAME)
            lease = create.guard._execution_lease(create.parse(
                (case / "state" / create.guard.EXECUTION_LEASE_NAME).read_bytes(),
                create.guard.MAX_EXECUTION_LEASE_BYTES,
            ))
            self.assertEqual(reply["attempt"], lease["attempt"])
            self.assertIsNone(lease["createCompletion"])
            self.assertFalse(list((case / "state").glob("*/timepad-create-completion*.json")))
            if scenario == "bootstrap":
                self.assertEqual((0, "COMPLETED", "bootstrapped"),
                                 (reply["status"], reply["reason"], reply["outcome"]))
                origin, current = create.guard.read_guard(case / "state")
                self.assertEqual("READY", current["phase"])
                self.assertEqual(0, current["operationEpoch"])
                self.assertEqual(origin["originDigest"], current["originDigest"])
                self.assertIsNone(current["runtimeRequest"])
                self.assertIsNone(current["ownedChild"])
                self.assertEqual("drained", lease["lifecycle"])
                self.assertIsNone(lease["worker"])
                self.assertIsNone(lease["firstFailure"])
                self.assertIsNotNone(lease["t0Ns"])
            else:
                self.assertNotEqual(0, reply["status"])
                self.assertIsNotNone(lease["firstFailure"])
                self.assertFalse((case / "state/timepad-guard").exists())
                self.assertFalse((case / "state/.provider-transaction.current").exists())
                self.assertFalse((case / "state/fixture-channel-1-final-deploy").exists())
                expected = (
                    b"BOOTSTRAP_EVIDENCE_INVALID" if scenario == "bootstrap-mismatch"
                    else b"EXECUTION_CONTROLLER_LIFECYCLE_UNAVAILABLE"
                )
                self.assertIn(expected, result.stderr)

    def test_actual_bootstrap_worker_grant_publication_and_childless_terminal(self):
        self.run_case("bootstrap")

    def test_actual_bootstrap_worker_rejects_mismatched_authority_before_create(self):
        self.run_case("bootstrap-mismatch")

    def test_actual_deploy_worker_keeps_unintegrated_lifecycle_closed_before_create(self):
        self.run_case("deploy-blocked")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portable", action="store_true")
    options = parser.parse_args()
    if not options.portable:
        if sys.platform != "linux" or os.geteuid() != 0:
            print("CREATE_FIXTURES_BLOCKED: isolated Linux/root required", file=sys.stderr)
            return 77
        for kind, name in (("MOUNT", "mnt"), ("NETWORK", "net"), ("PID", "pid")):
            previous = os.environ.get("TIMEPAD_FIXTURE_PARENT_" + kind + "_NS")
            if not previous or previous == os.readlink("/proc/self/ns/" + name):
                print("CREATE_FIXTURES_BLOCKED: isolation launcher required", file=sys.stderr)
                return 77
        supervisor.linux_preflight()
    classes = [Contracts] if options.portable else [Contracts, LinuxBoundaries, LinuxActualController]
    suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(cls) for cls in classes)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if options.portable:
        print("PORTABLE_CREATE_CONTRACTS_ONLY: actual controller pipeline not evaluated")
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
