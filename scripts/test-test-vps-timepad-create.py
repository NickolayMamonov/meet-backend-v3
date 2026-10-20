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
import json
import os
from pathlib import Path
import re
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
    def test_owned_run_identity_preserves_the_complete_provider_run_key(self):
        self.assertEqual(
            ("31885558214-1", "final-deploy"),
            create.state_run_identity("31885558214-1-final-deploy"),
        )
        self.assertEqual(
            ("31885558214-1", "rollback-drill"),
            create.state_run_identity("31885558214-1-rollback-drill"),
        )
        with self.assertRaises(create.CreateError):
            create.state_run_identity("31885558214-final-deploy")
        with self.assertRaises(create.CreateError):
            create.state_run_identity("31885558214-1-unrecognized")

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
        endpoint = backend["NetworkSettings"]["Networks"]["meet-production_default"]
        member = facts["resources"]["networkInspections"][0]["Containers"][backend["Id"]]
        self.assertTrue(endpoint["EndpointID"])
        self.assertEqual(endpoint["EndpointID"], member["EndpointID"])
        self.assertEqual(endpoint["MacAddress"], member["MacAddress"])

    def test_forward_fixture_disconnects_predecessor_only_after_exact_stop_intent(self):
        fixture = self.forward_fixture()
        facts = fixture.fixture_data(SCRIPTS)
        backend = next(item for item in facts["resources"]["containerInspections"]
                       if item["Id"] == "f" * 64)
        with tempfile.TemporaryDirectory() as directory:
            case = Path(directory)
            runtime_path = case / "forward-runtime.json"
            runtime_path.write_bytes(create.canonical(
                {"backend": backend, "created": False}, create.MAX_EVIDENCE,
            ))
            (case / "forward-scenario").write_text("forward")
            current = {"runtimeRequest": {
                "lifecycle": "intent", "operation": "suppress", "containerId": backend["Id"],
            }}
            import test_vps_timepad_state as guard

            with mock.patch.object(fixture, "no_socket"), \
                    mock.patch.object(guard, "deploy_lock", side_effect=lambda *args: nullcontext()), \
                    mock.patch.object(guard, "_read_guard_locked",
                                      side_effect=lambda *args: (None, current)):
                fixture.docker(case, ["update", "--restart=no", backend["Id"]], facts)
                suppressed = fixture.ForwardTransport(case, facts).observe(context())
                suppressed = create.parse(suppressed, create.MAX_EVIDENCE)["resources"]
                stopped_backend = suppressed["containerInspections"][1]
                endpoint = stopped_backend["NetworkSettings"]["Networks"]["meet-production_default"]
                self.assertTrue(stopped_backend["State"]["Running"])
                self.assertEqual("no", stopped_backend["HostConfig"]["RestartPolicy"]["Name"])
                self.assertTrue(endpoint["EndpointID"])
                self.assertIn(backend["Id"], suppressed["networkInspections"][0]["Containers"])

                current["runtimeRequest"] = {
                    "lifecycle": "intent", "operation": "stop", "containerId": backend["Id"],
                }
                fixture.docker(case, ["stop", "--time", "10", backend["Id"]], facts)
                stopped = fixture.ForwardTransport(case, facts).observe(context())
                stopped = create.parse(stopped, create.MAX_EVIDENCE)["resources"]
                stopped_backend = stopped["containerInspections"][1]
                endpoint = stopped_backend["NetworkSettings"]["Networks"]["meet-production_default"]
                self.assertFalse(stopped_backend["State"]["Running"])
                self.assertEqual("no", stopped_backend["HostConfig"]["RestartPolicy"]["Name"])
                self.assertFalse(endpoint["EndpointID"])
                self.assertNotIn(backend["Id"], stopped["networkInspections"][0]["Containers"])

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
        # Git Bash truncates long -c arguments on Windows. Keep the script
        # complete while preserving closed stdin for the functions under test.
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "contract.sh"
            script.write_text("set -euo pipefail\n" + source, encoding="utf-8", newline="\n")
            result = subprocess.run(
                [bash, script.as_posix()],
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

    def test_terminal_success_requires_preparation_and_lease_ack_before_result(self):
        function = self.shell_functions("supervisor_complete")
        for outcome in ("", "bootstrapped", "already-completed"):
            for failure in ("none", "prepare-terminal", "publish", "terminal"):
                with self.subTest(outcome=outcome, failure=failure):
                    result = self.run_shell(function + """
supervisor_enabled=true
supervisor_client() { echo "$*" >&2; [ "$1" != "$failure" ]; }
supervisor_publish_lease() { echo publish >&2; [ "$failure" != publish ]; }
fail() { echo "$1" >&2; exit 91; }
""" + f"failure={failure}\n" + """
set +e
( supervisor_complete """ + outcome + """ )
status=$?
if [ "$failure" = none ]; then [ "$status" -eq 0 ]; else [ "$status" -eq 91 ]; fi
""")
                    expected = ["prepare-terminal"]
                    if failure != "prepare-terminal":
                        expected.append("publish")
                    if failure in {"none", "terminal"}:
                        expected.append("terminal 0" + (" --outcome " + outcome if outcome else ""))
                    if failure != "none":
                        expected.append({
                            "prepare-terminal": "EXECUTION_TERMINAL_PREPARE_FAILED",
                            "publish": "EXECUTION_LEASE_PUBLICATION_FAILED",
                            "terminal": "EXECUTION_TERMINAL_ACK_FAILED",
                        }[failure])
                    self.assertEqual(expected, result.stderr.decode().splitlines())

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
        functions = self.shell_functions("fixture_create_stage", "guarded_candidate_start")
        for failure in ("suppress", "stop", "none"):
            with self.subTest(failure=failure):
                result = self.run_shell(functions + """
TIMEPAD_FIXTURE_DIAGNOSTICS=
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

    def test_create_stage_diagnostics_are_opt_in_fixed_bounded_and_non_failing(self):
        function = self.shell_functions("fixture_create_stage")
        source = (SCRIPTS / "deploy-test-vps-provider-release.sh").read_text()
        stages = sorted(set(re.findall(r"^\s*fixture_create_stage ([A-Z_]+)$", source, re.MULTILINE)))
        self.assertGreater(len(stages), 0)
        self.assertLessEqual(len(stages), 64)
        result = self.run_shell(function + """
unset TIMEPAD_FIXTURE_DIAGNOSTICS
fixture_create_stage PREDECESSOR_SUPPRESS
for enabled in '' 0 true 01; do
  TIMEPAD_FIXTURE_DIAGNOSTICS=$enabled fixture_create_stage PREDECESSOR_SUPPRESS
done
TIMEPAD_FIXTURE_DIAGNOSTICS=1
fixture_create_stage
fixture_create_stage PRIVATE_CANARY
fixture_create_stage 'PRIVATE_CANARY=never-print-me
PREDECESSOR_SUPPRESS'
fixture_create_stage '$(echo never-print-me)'
""" + "\n".join("fixture_create_stage " + stage for stage in stages) + """
# A missing diagnostic sink must not become a controller failure.
fixture_create_stage PREDECESSOR_SUPPRESS 2>/dev/null >&- 2>&-
echo diagnostic-status-preserved
""")
        self.assertEqual(b"diagnostic-status-preserved\n", result.stdout)
        self.assertEqual(
            ["fixture_timepad_create_stage=" + stage for stage in stages],
            result.stderr.decode().splitlines(),
        )
        self.assertLessEqual(len(result.stderr), 8192)
        self.assertNotIn(b"PRIVATE_CANARY", result.stdout + result.stderr)
        self.assertNotIn(b"never-print-me", result.stdout + result.stderr)

    def test_create_stage_diagnostics_identify_refused_gate_without_changing_result(self):
        stages = [
            "WORK_BUDGET", "PREDECESSOR_INVENTORY", "PREDECESSOR_INSPECT",
            "PREDECESSOR_IDENTITY", "PREDECESSOR_SUPPRESS", "PREDECESSOR_SUPPRESSED",
            "PREDECESSOR_STOP", "PREDECESSOR_STOPPED", "BARRIER_PUBLICATION",
            "FENCE_READ", "FENCE_PHASE", "FENCE_EPOCH", "FENCE_BINDING", "FENCE_UNBOUND",
            "CREATE_INITIAL", "CANDIDATE_INVENTORY",
        ]
        functions = self.shell_functions("fixture_create_stage", "guarded_candidate_start")
        # This observer only records the next fixed gate for fault injection;
        # the actual helper still controls and sanitizes diagnostic output.
        functions = functions.replace("fixture_create_stage() {", "emit_create_stage() {", 1)
        harness = functions + """
fixture_create_stage() { current_stage=$1; emit_create_stage "$@"; }
previous_container=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
previous_id=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
admission_disposition=pre-barrier-only
timepad_helper=fixed-helper
state_root=fixed-root
unsafe_cutover_latch=false
current_stage=
gate() { [ "$current_stage" != "$fault" ]; }
recovery_work_check() { gate; }
compose() { gate || return 1; echo "$previous_container"; }
docker_container_inspect() {
  gate || return 1
  case "$current_stage:$*" in
    PREDECESSOR_IDENTITY:*Image*) echo "$previous_id";;
    PREDECESSOR_IDENTITY:*Running*) echo true;;
    PREDECESSOR_SUPPRESSED:*) echo no;;
    PREDECESSOR_STOPPED:*) echo false;;
    *) echo matching;;
  esac
}
jq() {
  if [ "$current_stage" = FENCE_UNBOUND ] && [ "$fault" = FENCE_UNBOUND ]; then
    echo unexpected-container
    return 0
  fi
  gate || return 1
  case "$*" in
    *project*) echo meet-production;;
    *service*) echo backend;;
    *current.phase*) echo CUTOVER_POSSIBLE;;
    *current.operationEpoch*) echo 1;;
    *current.predecessorDisposition*) echo "$admission_disposition";;
    *current.containerId*) echo '';;
    *) exit 96;;
  esac
}
timepad_runtime_mutate() {
  echo "mutation:$1" >&2
  gate
}
timepad_advance() {
  echo barrier >&2
  gate || fail GUARD_STATE_LOST
}
timeout() { gate || return 1; echo matching; }
run_owned_child() {
  echo create >&2
  gate || return 23
  candidate_container=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
}
fail() { echo "$1" >&2; exit 95; }
"""
        for index, fault in enumerate(stages):
            traces = []
            for enabled in ("", "1"):
                with self.subTest(fault=fault, diagnostics=enabled):
                    result = self.run_shell(harness + f"""
fault={fault}
TIMEPAD_FIXTURE_DIAGNOSTICS='{enabled}'
set +e
( set -e; guarded_candidate_start )
status=$?
set -e
echo "status=$status"
""")
                    lines = result.stderr.decode().splitlines()
                    diagnostic = [line for line in lines if line.startswith("fixture_timepad_create_stage=")]
                    self.assertEqual(
                        ["fixture_timepad_create_stage=" + stage for stage in stages[:index + 1]]
                        if enabled else [], diagnostic,
                    )
                    effects = [line for line in lines if not line.startswith("fixture_timepad_create_stage=")]
                    self.assertEqual(b"status=23\n" if fault == "CREATE_INITIAL" else b"status=95\n",
                                     result.stdout.splitlines(keepends=True)[-1])
                    if fault != "CREATE_INITIAL":
                        self.assertEqual(
                            "GUARD_STATE_LOST" if fault.startswith("FENCE_") or fault == "BARRIER_PUBLICATION"
                            else "RECOVERY_REQUIRED", effects[-1],
                        )
                    self.assertNotIn("start", effects)
                    if index < stages.index("BARRIER_PUBLICATION"):
                        self.assertNotIn("barrier", effects)
                        self.assertNotIn("create", effects)
                    if index < stages.index("CREATE_INITIAL"):
                        self.assertNotIn("create", effects)
                    traces.append((result.stdout, effects))
            if len(traces) == 2:
                self.assertEqual(traces[0], traces[1], fault)

    def test_predecessor_verification_diagnostics_preserve_failure_contract(self):
        stages = [
            "PREDECESSOR_VERIFY_INVENTORY", "PREDECESSOR_VERIFY_INSPECT",
            "PREDECESSOR_VERIFY_PROVIDER",
        ]
        functions = self.shell_functions("fixture_create_stage", "verify_predecessor_before_writers")
        functions = functions.replace("fixture_create_stage() {", "emit_create_stage() {", 1)
        harness = functions + """
fixture_create_stage() { current_stage=$1; emit_create_stage "$@"; }
previous_inspect=PRIVATE_CANARY
provider_helper=fixed-helper
state_root=fixed-root
run_key=fixed-run
gate() { [ "$current_stage" != "$fault" ]; }
compose() { gate || return 1; echo exact-container; }
docker_container_inspect() { gate || return 1; echo PRIVATE_CANARY; }
timeout() { gate; }
fail() { echo "$1" >&2; exit 95; }
"""
        for index, fault in enumerate(stages):
            for enabled in ("", "1"):
                with self.subTest(fault=fault, diagnostics=enabled):
                    result = self.run_shell(harness + f"""
fault={fault}
TIMEPAD_FIXTURE_DIAGNOSTICS='{enabled}'
set +e
( set -e; verify_predecessor_before_writers )
status=$?
[ "$status" -eq 95 ]
""")
                    self.assertEqual(b"", result.stdout)
                    self.assertEqual(
                        (["fixture_timepad_create_stage=" + stage for stage in stages[:index + 1]]
                         if enabled else []) + ["PROVIDER_STATE_INVALID"],
                        result.stderr.decode().splitlines(),
                    )
                    self.assertNotIn(b"PRIVATE_CANARY", result.stdout + result.stderr)

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
        observed = next(node for node in tree.body if isinstance(node, ast.ClassDef)
                        and node.name == "ObservedForwardTransport")
        self.assertEqual({"__init__", "identity", "render", "observe", "spawn_create"}, {
            node.name for node in observed.body if isinstance(node, ast.FunctionDef)
        })
        for method in ("identity", "render", "observe", "spawn_create"):
            self.assertIn("self.external." + method + "(", ast.unparse(observed))
        snapshot = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                        and node.name == "snapshot")
        self.assertNotIn("publish", ast.unparse(snapshot))
        self.assertIn("environmentDigest", ast.unparse(snapshot))

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
    """Real bootstrap/refusal and first-create rows, not the complete matrix."""

    def assert_initial_create(self, case: Path, result: subprocess.CompletedProcess) -> None:
        self.assertIn(b"ACTUAL_FORWARD_CONTROLLER_PASS: scenario=forward", result.stdout)
        self.assertNotIn(b"PRIVATE_CANARY", result.stdout + result.stderr)
        self.assertNotIn(b"never-print-me", result.stdout + result.stderr)
        order = (case / "observed-order").read_text().splitlines()
        self.assertEqual([
            "predecessor-suppress", "predecessor-stop", "create-spawn",
            "normal-completed", "bound", "candidate-suppress", "candidate-start",
            "candidate-health", "candidate-restore",
        ], order)
        observations = {
            event: create.parse((case / ("observed-" + event + ".json")).read_bytes(), 65536)
            for event in order
        }
        predecessor, candidate = "f" * 64, "a" * 64
        effects = (case / "forward-effects").read_text().splitlines()
        self.assertEqual([
            "suppress:" + predecessor, "stop:" + predecessor,
            "suppress:" + candidate, "start:" + candidate, "restore-policy:" + candidate,
        ], effects)
        suppressed = observations["predecessor-suppress"]["backend"]
        self.assertTrue(suppressed["State"]["Running"])
        self.assertEqual("unless-stopped", suppressed["HostConfig"]["RestartPolicy"]["Name"])
        self.assertTrue(suppressed["NetworkSettings"]["Networks"]["meet-production_default"]["EndpointID"])
        stop_intent = observations["predecessor-stop"]["backend"]
        self.assertTrue(stop_intent["State"]["Running"])
        self.assertEqual("no", stop_intent["HostConfig"]["RestartPolicy"]["Name"])
        self.assertTrue(stop_intent["NetworkSettings"]["Networks"]["meet-production_default"]["EndpointID"])
        quiesced = observations["create-spawn"]["backend"]
        self.assertFalse(quiesced["State"]["Running"])
        self.assertEqual("no", quiesced["HostConfig"]["RestartPolicy"]["Name"])
        self.assertFalse(quiesced["NetworkSettings"]["Networks"]["meet-production_default"]["EndpointID"])
        prepared = observations["predecessor-suppress"]["current"]
        self.assertEqual("PREPARED", prepared["phase"])
        self.assertEqual("pre-barrier-only", prepared["predecessorDisposition"])
        self.assertEqual(1, prepared["operationEpoch"])
        self.assertIsNone(prepared["containerId"])
        self.assertEqual("predecessor", prepared["runtimeRequest"]["role"])
        self.assertEqual(predecessor, prepared["predecessorContainerId"])
        run_path = case / "state" / prepared["ownedRun"]
        prepared_raw = (run_path / "timepad-prepared.json").read_bytes()
        proof = create.parse(prepared_raw, 8192)
        self.assertEqual(prepared["preparedProofDigest"], hashlib.sha256(prepared_raw).hexdigest())
        self.assertEqual(proof["resourcesDigest"], hashlib.sha256(
            (run_path / "timepad-resources.json").read_bytes(),
        ).hexdigest())
        self.assertEqual((run_path / "config.env.target").read_bytes(),
                         (case / "root/.env.production").read_bytes())
        self.assertEqual((run_path / "config.base-compose.yml").read_bytes(),
                         Path("/var/lib/meet-production/active-compose.yml").read_bytes())
        self.assertEqual((run_path / "target-runtime.override.yml").read_bytes(),
                         Path("/var/lib/meet-production/active-runtime.override.yml").read_bytes())

        launch = observations["create-spawn"]
        intent = launch["current"]["runtimeRequest"]
        self.assertEqual("CUTOVER_POSSIBLE", launch["current"]["phase"])
        self.assertEqual("intent", intent["lifecycle"])
        self.assertEqual("initial", intent["role"])
        self.assertIsNone(intent["priorContainerId"])
        self.assertIsNone(intent["containerId"])
        self.assertIsNone(intent["responseId"])
        self.assertIsNone(intent["configHash"])
        self.assertIsNone(intent["completionDigest"])
        self.assertIsNone(launch["receipt"])
        self.assertFalse(launch["backend"]["State"]["Running"])
        self.assertEqual("no", launch["backend"]["HostConfig"]["RestartPolicy"]["Name"])
        for field in ("operationToken", "modelDigest", "toolingDigest", "resourcesDigest"):
            self.assertEqual(proof[field], intent[field], field)
        self.assertEqual(prepared["preparedProofDigest"], intent["preparedProofDigest"])
        for field in ("originDigest", "incidentId", "operationEpoch", "executionAttempt"):
            self.assertEqual(prepared[field], intent[field], field)
        self.assertEqual(hashlib.sha256((run_path / "timepad-resource-request.json").read_bytes()).hexdigest(),
                         intent["resourceRequestDigest"])
        self.assertEqual(intent["childIdentity"], {
            key: launch["current"]["ownedChild"][key] for key in create.guard.CHILD_IDENTITY_FIELDS
        })

        facts = create.parse((case / "forward-facts.json").read_bytes(), create.MAX_EVIDENCE)
        model = facts["model"]
        model["services"]["backend"]["labels"]["org.meet.timepad.operation"] = proof["operationToken"]
        self.assertEqual(proof["modelDigest"], create._provider()._model_digest(model))
        expected_environment = sorted(facts["image"]["Config"]["Env"] + [
            key + "=" + value for key, value in model["services"]["backend"]["environment"].items()
        ])
        environment_digest = hashlib.sha256(json.dumps(
            expected_environment, separators=(",", ":"),
        ).encode()).hexdigest()
        for event, lifecycle in (("normal-completed", "normal-completed"), ("bound", "bound")):
            observation = observations[event]
            current = observation["current"]
            self.assertEqual(lifecycle, current["runtimeRequest"]["lifecycle"])
            self.assertIsNone(current["ownedChild"])
            create.guard.validate_create_completion(
                current, observation["lease"], observation["receipt"].encode(), acknowledged=True,
            )
            self.assertEqual(create.guard.create_request_digest(intent),
                             observation["lease"]["createCompletion"]["requestDigest"])
            backend = observation["backend"]
            self.assertEqual(candidate, backend["Id"])
            self.assertEqual(facts["image"]["Id"], backend["Image"])
            self.assertEqual("created", backend["State"]["Status"])
            self.assertFalse(backend["State"]["Running"])
            self.assertEqual("0001-01-01T00:00:00Z", backend["State"]["StartedAt"])
            self.assertEqual(0, backend["RestartCount"])
            self.assertEqual(proof["operationToken"], backend["Config"]["Labels"]["org.meet.timepad.operation"])
            self.assertEqual(environment_digest, observation["environmentDigest"])
        bound = observations["bound"]["current"]
        self.assertEqual(candidate, bound["containerId"])
        self.assertEqual("1" * 64, bound["configHash"])
        self.assertIsNone(observations["normal-completed"]["current"]["containerId"])

        start = observations["candidate-start"]
        self.assertEqual("VERIFYING", start["current"]["phase"])
        self.assertEqual(candidate, start["current"]["containerId"])
        self.assertEqual("intent", start["current"]["runtimeRequest"]["lifecycle"])
        self.assertEqual("start", start["current"]["runtimeRequest"]["operation"])
        self.assertEqual("released", start["current"]["ownedChild"]["lifecycle"])
        self.assertEqual(observations["bound"]["receipt"], start["receipt"])
        self.assertEqual(observations["bound"]["lease"]["createCompletion"], start["lease"]["createCompletion"])
        self.assertFalse(start["backend"]["State"]["Running"])
        self.assertEqual("no", start["backend"]["HostConfig"]["RestartPolicy"]["Name"])
        self.assertEqual(environment_digest, start["environmentDigest"])
        health = observations["candidate-health"]
        self.assertTrue(health["backend"]["State"]["Running"])
        self.assertEqual("healthy", health["backend"]["State"]["Health"]["Status"])
        restore = observations["candidate-restore"]["current"]
        self.assertEqual("COMMITTING", restore["phase"])
        self.assertEqual("terminal-policy-intent", restore["commitSubstep"])
        self.assertRegex(restore["commitWitnessDigest"], r"^[a-f0-9]{64}$")
        self.assertRegex(restore["providerFinalizationDigest"], r"^[a-f0-9]{64}$")
        self.assertEqual("committed", create.parse((run_path / "terminal.json").read_bytes(), 8192)["outcome"])
        self.assertFalse((case / "state/.provider-transaction.current").exists())
        _, final = create.guard.read_guard(case / "state")
        self.assertEqual("COMMITTED", final["phase"])
        self.assertEqual("policy-restored", final["commitSubstep"])
        self.assertEqual(candidate, final["containerId"])
        self.assertIsNone(final["ownedChild"])
        self.assertEqual("completed", final["runtimeRequest"]["lifecycle"])
        self.assertEqual("restore-policy", final["runtimeRequest"]["operation"])
        with create.guard.deploy_lock(case / "state"):
            lease = create.guard._read_execution_lease_locked(case / "state")
        self.assertEqual("drained", lease["lifecycle"])
        self.assertIsNone(lease["worker"])
        self.assertIsNone(lease["firstFailure"])
        reply = create.parse((case / "forward-relay-result.json").read_bytes(), supervisor.MAX_FRAME)
        self.assertEqual((0, "COMPLETED"), (reply["status"], reply["reason"]))
        self.assertEqual(reply["attempt"], lease["attempt"])
        self.assertEqual(observations["bound"]["lease"]["createCompletion"], lease["createCompletion"])
        for event in order:
            self.assertEqual(lease["t0Ns"], observations[event]["lease"]["t0Ns"])
            self.assertEqual(lease["workEndNs"], observations[event]["lease"]["workEndNs"])
            self.assertEqual(lease["hardEndNs"], observations[event]["lease"]["hardEndNs"])

    def run_case(self, scenario: str):
        if scenario in {"forward", "binding-environment-drift"}:
            self.run_forward_case(scenario)
            return
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
            self.assertFalse(os.path.lexists("/run/docker.sock"))
            self.assertFalse(os.path.lexists("/var/run/docker.sock"))
            self.assertIn(b"create_pipeline=NOT_PROVEN", result.stdout)
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
                self.assertFalse((case / "state/31885558214-1-final-deploy").exists())
                expected = (
                    b"BOOTSTRAP_EVIDENCE_INVALID" if scenario == "bootstrap-mismatch"
                    else b"EXECUTION_CONTROLLER_LIFECYCLE_UNAVAILABLE"
                )
                self.assertIn(expected, result.stderr)

    def run_forward_case(self, scenario: str):
        parent = Path("/var/lib/timepad-fixture")
        parent.mkdir(mode=0o700, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="case-create-worker-", dir=parent) as temporary:
            case = Path(temporary)
            result = subprocess.run([
                "timeout", "--signal=TERM", "--kill-after=5s", "720s",
                sys.executable, "-B", str(SCRIPTS / "fixtures/timepad-controller/create-controller.py"),
                "--case", str(case), "--scenario", scenario,
            ], stdin=subprocess.DEVNULL, capture_output=True, timeout=730)
            self.assertEqual(0, result.returncode, result.stderr.decode(errors="replace"))
            try:
                self.assertLessEqual(len(result.stdout) + len(result.stderr), 65536)
                self.assertFalse(os.path.lexists("/run/docker.sock"))
                self.assertFalse(os.path.lexists("/var/run/docker.sock"))
                if scenario == "forward":
                    self.assert_initial_create(case, result)
                else:
                    order = (case / "observed-order").read_text().splitlines()
                    self.assertEqual([
                        "predecessor-suppress", "predecessor-stop", "create-spawn", "normal-completed",
                    ], order)
                    self.assertEqual(["suppress:" + "f" * 64, "stop:" + "f" * 64],
                                     (case / "forward-effects").read_text().splitlines())
                    self.assertEqual(b"childless;lock-held;not-normal-exit\n",
                                     (case / "passive-keeper-observed").read_bytes())
                    completed = create.parse(
                        (case / "observed-normal-completed.json").read_bytes(), 65536,
                    )
                    create.guard.validate_create_completion(
                        completed["current"], completed["lease"],
                        completed["receipt"].encode(), acknowledged=True,
                    )
                    _, current = create.guard.read_guard(case / "state")
                    self.assertIsNone(current["containerId"])
                    self.assertIsNone(current["configHash"])
                    self.assertIsNone(current["ownedChild"])
                    self.assertEqual("normal-completed", current["runtimeRequest"]["lifecycle"])
                    self.assertEqual(completed["current"]["runtimeRequest"], current["runtimeRequest"])
                    self.assertIn(current["phase"], {"CUTOVER_POSSIBLE", "RECOVERY_REQUIRED"})
                    with create.guard.deploy_lock(case / "state"):
                        lease = create.guard._read_execution_lease_locked(case / "state")
                    self.assertEqual("quiescence-unconfirmed", lease["lifecycle"])
                    self.assertIsNotNone(lease["firstFailure"])
                    self.assertEqual(completed["lease"]["createCompletion"], lease["createCompletion"])
                    reply = create.parse(
                        (case / "forward-relay-result.json").read_bytes(), supervisor.MAX_FRAME,
                    )
                    self.assertNotEqual(0, reply["status"])
                    self.assertEqual("QUIESCENCE_UNCONFIRMED", reply["reason"])
            finally:
                # The fixture has exited and its passive keeper, if any, was
                # explicitly torn down. Only this case's exact active copies
                # may be removed from the already-private namespace.
                run_path = case / "state/31885558214-1-final-deploy"
                for active, source in (
                    ("active-compose.yml", "config.base-compose.yml"),
                    ("active-runtime.override.yml", "target-runtime.override.yml"),
                ):
                    path = Path("/var/lib/meet-production") / active
                    self.assertFalse(path.is_symlink())
                    self.assertEqual((run_path / source).read_bytes(), path.read_bytes())
                    path.unlink()

    def test_actual_bootstrap_worker_grant_publication_and_childless_terminal(self):
        self.run_case("bootstrap")

    def test_actual_bootstrap_worker_rejects_mismatched_authority_before_create(self):
        self.run_case("bootstrap-mismatch")

    def test_actual_deploy_worker_keeps_unintegrated_lifecycle_closed_before_create(self):
        self.run_case("deploy-blocked")

    def test_actual_initial_create_receipt_binding_start_health_and_finalization(self):
        self.run_case("forward")

    def test_actual_completed_create_environment_drift_never_binds_starts_or_retries(self):
        self.run_case("binding-environment-drift")


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
